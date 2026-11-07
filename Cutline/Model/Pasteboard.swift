// Copy, cut and paste objects (⌘C, ⌘X, ⌘V; also through the Edit menu and right-click), including from
// one Cutline window to another: they go to the macOS pasteboard in a type of their own, with the images
// they use. Paste puts them in the active layer, at the same spot on the sheet (or 5 mm down and to the right, as many times as
// needed, if an identical one is already there) and selects them. ⌘ + arrow duplicates the selection right next to it, to that
// side, as in Silhouette Studio. Vectors copied in Illustrator (or any app that copies a PDF or an SVG) paste too, with the
// rules of File › Import….
import AppKit

nonisolated struct Clipping: Codable {

    /// The keys stored on disk keep the names of the 1.0 format (Portuguese), so older files still open.

    enum CodingKeys: String, CodingKey {

        case objects = "objetos", images = "imagens", links = "vinculos"

    }

    var objects: [CanvasObject]
    var images: [String: Data]
    /// Linked images go linked (a missing one only with its preview).
    var links: [String: ImageLink]?
}

extension NSPasteboard.PasteboardType {
    static let cutlineObjects = Self("io.github.joaogmcorrea.cutline.objetos")
    static let svgImage = Self("public.svg-image")
}

nonisolated enum Direction: Sendable {
    case left, right, up, bottom
}

extension Document {
    /// The general macOS one (in hidden tests, one of Cutline's own, so the owner's isn't touched).
    var pasteboardArea: NSPasteboard {
        #if DEBUG
        if let test = DebugHooks.testArea { return test }
        #endif
        return .general
    }

    func copySelection() {
        let copied = objectsInOrder.filter { selection.contains($0.id) }
        let keys = Set(copied.compactMap(\.image?.key))
        guard !copied.isEmpty,
              let payload = try? PropertyListEncoder().encode(Clipping(objects: copied, images: images.filter { keys.contains($0.key) },
                                                                       links: links.filter { keys.contains($0.key) }))
        else { return }
        pasteboardArea.clearContents()
        pasteboardArea.setData(payload, forType: .cutlineObjects)
    }

    func cutSelection() {
        copySelection()
        deleteSelection()
    }

    var canPaste: Bool { pasteboardArea.availableType(from: [.cutlineObjects, .pdf, .svgImage]) != nil || copiedSVGText != nil }

    func paste() {
        guard let payload = pasteboardArea.data(forType: .cutlineObjects),
              let clipping = try? PropertyListDecoder().decode(Clipping.self, from: payload), !clipping.objects.isEmpty
        else { return pasteVectors() }
        let equal = { (a: CGRect, b: CGRect) in
            abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01 && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
        }
        var offset = 0.0
        while offset < 250, clipping.objects.contains(where: { pasted in
            objects.contains { equal($0.frame, pasted.frame.offsetBy(dx: offset, dy: offset)) }
        }) { offset += 5 }
        insertImported(CanvasObject.copies(clipping.objects, offset: CGSize(width: offset, height: offset)),
                          images: clipping.images, links: clipping.links ?? [:])
    }

    /// Vectors from another app: Illustrator copies a PDF (and, with "Include SVG Code" in its Clipboard Handling
    /// settings, the SVG as text). Same rules as File › Import… (the stroke sets the cut; fill only is printed, with no
    /// cut; a PDF's text comes in as paths and its images as images; what can't be read stays out, with a notice),
    /// centered on what the window shows.
    private func pasteVectors() {
        guard let payload = pasteboardArea.data(forType: .pdf) ?? pasteboardArea.data(forType: .svgImage) ?? copiedSVGText.map({ Data($0.utf8) })
        else { return }
        let result: VectorImport
        do { result = try VectorImporter.read(payload, colors: colors) } catch {
            notice = error.localizedDescription
            return
        }
        var parts: [String] = []
        if result.texts > 0 { parts.append(String(localized: "text not imported (convert it to outlines in Illustrator)")) }
        if result.images > 0 { parts.append(String(localized: "\(result.images) images not imported")) }
        guard let first = result.objects.first else {
            notice = parts.isEmpty ? String(localized: "No paths to paste.")
                : String(localized: "No paths to paste: \(parts.joined(separator: " · ")).")
            return
        }
        let box = result.objects.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        let center = visibleCenter ?? CGPoint(x: activeArtboard.rect.midX, y: activeArtboard.rect.midY)
        insertImported(CanvasObject.copies(result.objects, offset: CGSize(width: center.x - box.midX, height: center.y - box.midY)),
                       images: result.imageData)
        if !parts.isEmpty {
            let pictures = result.objects.count { $0.image != nil }
            var counts = pictures < result.objects.count ? [String(localized: "\(result.objects.count - pictures) paths")] : []
            if pictures > 0 { counts.append(String(localized: "\(pictures) images")) }
            notice = String(localized: "Pasted: \((counts + parts).joined(separator: " · ")).")
        }
    }

    /// An SVG copied as text.
    private var copiedSVGText: String? {
        guard let text = pasteboardArea.string(forType: .string), VectorImporter.format(Data(text.prefix(8192).utf8)) == .svg else { return nil }
        return text
    }

    /// A copy of the selection right next to it, on the chosen side.
    func duplicateBeside(_ direction: Direction) {
        guard let box = selectionBox else { return }
        switch direction {
        case .left: duplicateSelection(offset: CGSize(width: -box.width, height: 0))
        case .right: duplicateSelection(offset: CGSize(width: box.width, height: 0))
        case .up: duplicateSelection(offset: CGSize(width: 0, height: -box.height))
        case .bottom: duplicateSelection(offset: CGSize(width: 0, height: box.height))
        }
    }
}
