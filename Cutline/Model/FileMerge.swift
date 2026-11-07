// File › Save Selection… (part of the document to a new file) and File › Merge… (a file into the document), as in
// Silhouette Studio. Both carry the layers, the line colors and the Send settings the objects use.
import CutlineKit
import SwiftUI
import UniformTypeIdentifiers

extension Document {
    // MARK: Save Selection

    /// A new Cutline document with only the selected objects: their layers (in the same order, with the same names),
    /// the images they use and the Send settings of the colors they cut with, as this document would cut them (the
    /// ones remembered by the app go in too, so the file cuts the same on another Mac). The page settings (mat, marks,
    /// bleed, track enhancing) go as they are; the guides don't. This document doesn't change.
    func selectionFile() throws -> Data? {
        let chosen = objects.filter { selection.contains($0.id) && !$0.emptyText }
        guard !chosen.isEmpty else { return nil }
        let layerIDs = Set(chosen.map { layer(of: $0).id })
        // The artboards the selection is on go too, the first of them at the origin (and the objects with it).
        let onIDs = Set(chosen.compactMap { artboard(of: $0)?.id })
        let boards = artboards.filter { onIDs.contains($0.id) }
        let shift = boards.first?.rect.origin ?? .zero
        // An object without a layer (or with one that no longer exists) belongs to the top one: say so, so it stays there.
        let pieces = chosen.map { o -> CanvasObject in
            var o = o
            o.layer = layer(of: o).id
            o.frame = o.frame.offsetBy(dx: -shift.x, dy: -shift.y)
            return o
        }
        let savedBoards = boards.map { a -> Artboard in
            var a = a
            a.rect = a.rect.offsetBy(dx: -shift.x, dy: -shift.y)
            return a
        }
        // An image inside a shape that repeats or is transparent goes in already drawn too (Model/ImageFitting.swift).
        let (saved, flatImages) = ImageFlattening.forFile(pieces, images: images, links: links)
        let used = Set(saved.compactMap(\.image?.key) + saved.compactMap { $0.imageFit?.fileKey })
        let linked = links.filter { used.contains($0.key) }.mapValues { $0.relative(to: documentURL) }
        let colors = cutColors(pieces)
        return try DocumentFile(objects: saved,
                                cuts: colors.map { DocumentFile.CutByColor(color: $0, config: config($0)) },
                                cutOrder: cutOrder.filter(colors.contains),
                                images: images.filter { used.contains($0.key) && linked[$0.key] == nil }.merging(flatImages) { _, flat in flat },
                                layers: layers.filter { layerIDs.contains($0.id) },
                                activeLayer: layerIDs.contains(activeLayer) ? activeLayer : layers.first { layerIDs.contains($0.id) }?.id,
                                recent: recent, marks: marks, marksConfig: marksConfig, withMat: withMat,
                                cuttingMatSetting: cuttingMatSetting, bleed: bleed == PrintBleed() ? nil : bleed,
                                trackEnhancing: trackEnhancing ? true : nil, colorProfile: colorProfile,
                                links: linked.isEmpty ? nil : linked,
                                artboards: savedBoards.isEmpty ? nil : Self.artboardsToSave(savedBoards)).payload()
    }

    /// The line colors that go to the machine, in the order they appear.
    private func cutColors(_ list: [CanvasObject]) -> [CMYK] {
        var seen = Set<CMYK>()
        return list.filter(\.cutsLine).map(\.strokeColor).filter { seen.insert($0).inserted }
    }

    // MARK: Merge

    /// Types File › Merge… opens (and that dropping on the window merges).
    nonisolated static let mergeable: [UTType] = [.cutlineDocument, .studio3]

    /// File › Merge…: the objects of a Cutline or Silhouette Studio document come into this one, in one undo step, in
    /// the same places on the page, selected. Its layers come too, on top of this document's (a .studio3 has none: its
    /// objects come in a new layer with the file's name). The Send settings of the colors this document doesn't have yet
    /// come with them; for a color it already has, its own settings stay. The page (mat, marks, bleed) stays this
    /// document's. Returns the notice for the window.
    func merge(_ url: URL) throws -> String {
        let payload = try Data(contentsOf: url)
        guard !payload.isEmpty else { throw DocumentFileError.empty }
        let name = url.deletingPathExtension().lastPathComponent
        var incoming: [CanvasObject], incomingLayers: [Layer], incomingCuts: [CMYK: CutConfig], order: [CMYK]
        var incomingImages: [String: Data], incomingLinks: [String: ImageLink] = [:]
        if (UTType(filenameExtension: url.pathExtension) ?? .data).conforms(to: .studio3) {
            let studio = try StudioDocument(data: payload)
            let (objects, cuts, images, _, _) = Self.importResult(studio, colors: colors)
            let layer = Layer(name: name, color: 0)
            incoming = objects.map { var o = $0; o.layer = layer.id; return o }
            incomingLayers = [layer]
            (incomingCuts, order, incomingImages) = (cuts, [], images)
        } else {
            let file = try DocumentFile.read(payload)
            let fileLayers = file.layers.isEmpty ? [Layer(name: name, color: 0)] : file.layers
            // Without a layer (or with one the file doesn't have): the file's top one.
            incoming = file.objects.map { o in
                var o = o
                if !fileLayers.contains(where: { $0.id == o.layer }) { o.layer = fileLayers[0].id }
                return o
            }
            incomingLayers = fileLayers
            incomingCuts = Dictionary(file.cuts.map { ($0.color, $0.config) }, uniquingKeysWith: { _, last in last })
            (order, incomingImages) = (file.cutOrder, file.images)
            // The linked images are found from the merged file (its relative paths), then followed by this document.
            incomingLinks = (file.links ?? [:]).mapValues { link in
                var link = link
                if let url = link.resolve(documentURL: url) { link.path = url.standardizedFileURL.path }
                return link
            }
        }
        guard !incoming.isEmpty else { return String(localized: "“\(url.lastPathComponent)” has no objects to merge.") }

        // New ids for the objects, the groups and the layers, so the same file can be merged twice. A layer whose name
        // this document already has gets the file's name after it ("Layer 1 (Stickers)").
        var layerIDs: [UUID: UUID] = [:]
        let names = Set(layers.map(\.name))
        let newLayers = incomingLayers.enumerated().map { i, layer in
            var copy = layer
            copy.id = UUID()
            copy.color = layers.count + i
            if names.contains(layer.name), layer.name != name { copy.name = String(localized: "\(layer.name) (\(name))") }
            layerIDs[layer.id] = copy.id
            return copy
        }
        var newObjects = CanvasObject.copies(incoming).map { o in
            var o = o
            o.layer = o.layer.flatMap { layerIDs[$0] } ?? newLayers[0].id
            return o
        }
        // An image key already used for another image gets a new key.
        var newImages: [String: Data] = [:]
        var newLinks: [String: ImageLink] = [:]
        for key in Set(incomingImages.keys).union(incomingLinks.keys) {
            let data = incomingImages[key], link = incomingLinks[key]
            guard images[key] != nil || links[key] != nil, images[key] != data || links[key] != link else {
                newImages[key] = data
                newLinks[key] = link
                continue
            }
            let renamed = UUID().uuidString
            newImages[renamed] = data
            newLinks[renamed] = link
            for i in newObjects.indices where newObjects[i].image?.key == key { newObjects[i].image?.key = renamed }
        }

        registrar()
        pinLayers()
        layers.insert(contentsOf: newLayers, at: 0)
        objects.append(contentsOf: newObjects)
        images.merge(newImages) { _, newOne in newOne }
        links.merge(newLinks) { _, newOne in newOne }
        for (color, config) in incomingCuts where cuts[color] == nil { cuts[color] = config }
        // With an order chosen here, the new colors go after it (in the file's order); without one, all go by force.
        if !cutOrder.isEmpty { for color in order where !cutOrder.contains(color) { cutOrder.append(color) } }
        activeLayer = newLayers[0].id
        selection = Set(newObjects.map(\.id))
        let summary = [String(localized: "\(newObjects.count) objects"), String(localized: "\(newLayers.count) layers")]
        return String(localized: "Merged “\(url.lastPathComponent)”: \(summary.joined(separator: " · ")).")
    }
}
