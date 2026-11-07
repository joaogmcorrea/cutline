// The document's file: its own format (.cutline, a binary property list with the images inside)
// and opening Silhouette Studio files (.studio3). macOS never writes the .studio3: ⌘S asks whether to
// write over it (Model/StudioSave.swift) or as a Cutline document.
import CutlineKit
import SwiftUI
import UniformTypeIdentifiers

nonisolated extension UTType {
    /// Declared in Cutline-Info.plist.
    static let cutlineDocument = UTType(exportedAs: "io.github.joaogmcorrea.cutline.documento")
    /// The identifier Silhouette Studio itself declares.
    static let studio3 = UTType(importedAs: "public.studio3")
}

/// What goes to disk. Incompatible changes bump `version`.
nonisolated struct DocumentFile: Codable, Sendable {
    /// The keys stored on disk keep the names of the 1.0 format (Portuguese), so older files still open.
    enum CodingKeys: String, CodingKey {
        case version = "versao", objects = "objetos", cuts = "cortes", cutOrder = "ordemCortes", images = "imagens", layers = "camadas", activeLayer = "camadaAtiva", recent = "recentes", guides = "guias", marks = "marcas", marksConfig = "configMarcas", withMat = "comBase", cuttingMatSetting = "baseDeCorte", bleed = "sangria", trackEnhancing = "melhorarTracao", colorProfile = "perfilCor", links = "vinculos", artboards = "pranchetas"
    }

    static let currentVersion = 1

    struct CutByColor: Codable, Sendable {

        /// The keys stored on disk keep the names of the 1.0 format (Portuguese), so older files still open.

        enum CodingKeys: String, CodingKey {

            case color = "cor", config

        }

        var color: CMYK
        var config: CutConfig
    }

    var version = currentVersion
    var objects: [CanvasObject]
    var cuts: [CutByColor]
    var cutOrder: [CMYK]
    var images: [String: Data]
    var layers: [Layer] = []
    var activeLayer: UUID?
    var recent: [CMYK] = []
    var guides = Guides()
    var marks = false
    var marksConfig = MarksConfig.defaultValue
    var withMat = true
    var cuttingMatSetting: CuttingMat?
    /// Print bleed; nil when it is the default (off, 1 mm), so files that don't use it stay as before.
    var bleed: PrintBleed?
    /// Track enhancing in the Send window; nil when off, so files that don't use it stay as before.
    var trackEnhancing: Bool?
    /// The document's own CMYK profile (Edit › Assign Profile…); nil = the app's, so files that don't have one stay as before.
    var colorProfile: ColorProfile?
    /// Linked images (where the file is and the preview); nil when there are none, so files without them stay as before.
    var links: [String: ImageLink]?
    /// The artboards (Model/Artboards.swift), the 1st at the origin; nil for the one A4 at the origin, so files without
    /// artboards stay as before (and open with that A4).
    var artboards: [Artboard]?

    static func read(_ payload: Data) throws -> DocumentFile {
        let file = try PropertyListDecoder().decode(DocumentFile.self, from: payload)
        guard file.version <= currentVersion else { throw DocumentFileError.newerVersion }
        return file
    }

    func payload() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }
}

/// Tolerant reading: whatever is missing (files from earlier versions) stays empty.
extension DocumentFile {
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        objects = try c.decodeIfPresent([CanvasObject].self, forKey: .objects) ?? []
        cuts = try c.decodeIfPresent([CutByColor].self, forKey: .cuts) ?? []
        cutOrder = try c.decodeIfPresent([CMYK].self, forKey: .cutOrder) ?? []
        images = try c.decodeIfPresent([String: Data].self, forKey: .images) ?? [:]
        layers = try c.decodeIfPresent([Layer].self, forKey: .layers) ?? []
        activeLayer = try c.decodeIfPresent(UUID.self, forKey: .activeLayer)
        recent = try c.decodeIfPresent([CMYK].self, forKey: .recent) ?? []
        guides = try c.decodeIfPresent(Guides.self, forKey: .guides) ?? Guides()
        marks = try c.decodeIfPresent(Bool.self, forKey: .marks) ?? false
        marksConfig = try c.decodeIfPresent(MarksConfig.self, forKey: .marksConfig) ?? .defaultValue
        withMat = try c.decodeIfPresent(Bool.self, forKey: .withMat) ?? true
        cuttingMatSetting = try c.decodeIfPresent(CuttingMat.self, forKey: .cuttingMatSetting)
        bleed = try c.decodeIfPresent(PrintBleed.self, forKey: .bleed)
        trackEnhancing = try c.decodeIfPresent(Bool.self, forKey: .trackEnhancing)
        colorProfile = try c.decodeIfPresent(ColorProfile.self, forKey: .colorProfile)
        links = try? c.decodeIfPresent([String: ImageLink].self, forKey: .links)
        artboards = (try? c.decodeIfPresent([Artboard].self, forKey: .artboards)).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Where a Cutline object came from in the .studio3.
nonisolated struct StudioPiece: Sendable {
    /// `StudioDocument.Object.source`: where it is in the file's tree.
    var shapePath: [Int]
    /// How it was when opened (or at the last save): equal = unchanged.
    var object: CanvasObject
    /// The line color as it is in the file (Cutline's goes through CMYK and rounds).
    var line: StudioDocument.Color
}

/// The opened .studio3: the bytes (the template for writing) and where each object came from.
nonisolated struct StudioOrigin: Sendable {
    var payload: Data
    var url: URL?
    var pieces: [CanvasObject.ID: StudioPiece]
    var images: Set<String>
    /// The file's page size (it stays: Cutline doesn't change it in the .studio3).
    var pageSize: CGSize
    /// Already chose to write to the .studio3: the next ⌘S write directly.
    var confirmed = false
    var copyInTrash = false
}

nonisolated enum DocumentFileError: LocalizedError {
    case empty
    case newerVersion
    case readOnly
    case studioChanged
    case newStudioImage

    var errorDescription: String? {
        switch self {
        case .empty: String(localized: "The file is empty.")
        case .newerVersion: String(localized: "This document was saved by a newer version of Cutline.")
        case .readOnly: String(localized: "The Silhouette Studio file isn’t changed. Use File › Save As… to keep it as a Cutline document.")
        case .studioChanged: String(localized: "The .studio3 file changed since it was opened (was it saved by another app?). To keep those changes, it wasn't saved; save as a Cutline document or open the file again.")
        case .newStudioImage: String(localized: "The document has new images, which Cutline can't put in a .studio3 yet. Save it as a Cutline document.")
        }
    }
}

// macOS creates and reads the document off the main thread (and writes the file off it too): reading
// builds the data first and only then creates the Document; the snapshot (`snapshot`) is taken on the main thread.
nonisolated extension Document: ReferenceFileDocument {
    static var readableContentTypes: [UTType] { [.cutlineDocument, .studio3] }
    static var writableContentTypes: [UTType] { [.cutlineDocument] }

    convenience init(configuration: ReadConfiguration) throws {
        guard let payload = configuration.file.regularFileContents, !payload.isEmpty else { throw DocumentFileError.empty }
        if configuration.contentType.conforms(to: .studio3) {
            let studio = try StudioDocument(data: payload)
            let (objects, cuts, images, notice, pieces) = Self.importResult(studio, colors: ColorSettings.shared.converter())
            // Print & Cut as Studio left it: on or not, and the marks at the same spot on the sheet it prints.
            let marks = studio.registrationMarks
            // One artboard, the size of Studio's page (Letter, 12 × 12 in…).
            self.init(objects: objects, cuts: cuts, images: images, artboards: [Artboard(rect: CGRect(origin: .zero, size: studio.pageSize))],
                      marks: marks?.on ?? false,
                      marksConfig: marks.map(MarksConfig.init) ?? .defaultValue, notice: notice, cameFromStudio: true)
            self.studio = StudioOrigin(payload: payload, pieces: pieces, images: Set(studio.images.keys), pageSize: studio.pageSize)
        } else {
            let file = try DocumentFile.read(payload)
            self.init(objects: file.objects,
                      cuts: Dictionary(file.cuts.map { ($0.color, $0.config) }, uniquingKeysWith: { _, last in last }),
                      cutOrder: file.cutOrder, images: file.images, links: file.links ?? [:], layers: file.layers,
                      activeLayer: file.activeLayer, recent: file.recent, guides: file.guides, artboards: file.artboards ?? [],
                      marks: file.marks, marksConfig: file.marksConfig, bleed: file.bleed ?? PrintBleed(), withMat: file.withMat,
                      cuttingMatSetting: .some(file.cuttingMatSetting), trackEnhancing: file.trackEnhancing ?? false,
                      colorProfile: file.colorProfile)
            // A file whose 1st artboard isn't at the origin (not written by Cutline): it goes there, with everything.
            anchorFirstArtboard()
            anchor = .zero
        }
    }

    func snapshot(contentType: UTType) throws -> Data {
        // Never writes over the Studio file, even if macOS tries to save in place.
        guard contentType.conforms(to: .cutlineDocument) else { throw DocumentFileError.readOnly }
        // Empty text only exists while typing on the canvas: it doesn't go into the file. An image inside a shape that
        // repeats or is transparent goes in already drawn too, for the versions before it (Model/ImageFitting.swift).
        let (saved, flatImages) = ImageFlattening.forFile(objects.filter { !$0.emptyText }, images: images, links: links)
        let used = Set(saved.compactMap { $0.image?.key } + saved.compactMap { $0.imageFit?.fileKey })
        // A linked image's file stays where it is: only the link (with the path relative to where the document is now).
        let linked = links.filter { used.contains($0.key) }.mapValues { $0.relative(to: documentURL) }
        return try DocumentFile(objects: saved, cuts: cuts.map { DocumentFile.CutByColor(color: $0.key, config: $0.value) },
                           cutOrder: cutOrder, images: images.filter { used.contains($0.key) && linked[$0.key] == nil }.merging(flatImages) { _, flat in flat },
                           layers: layers, activeLayer: activeLayer, recent: recent, guides: guides, marks: marks,
                           marksConfig: marksConfig, withMat: withMat, cuttingMatSetting: cuttingMatSetting,
                           bleed: bleed == PrintBleed() ? nil : bleed, trackEnhancing: trackEnhancing ? true : nil,
                           colorProfile: colorProfile, links: linked.isEmpty ? nil : linked,
                           artboards: Self.artboardsToSave(artboards)).payload()
    }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        guard configuration.contentType.conforms(to: .cutlineDocument) else { throw DocumentFileError.readOnly }
        return FileWrapper(regularFileWithContents: snapshot)
    }
}

nonisolated extension Document {
    /// Objects of a Silhouette Studio document: each contour becomes a path with the line color
    /// (which defines the cut), the fill and the clipped image; groups come already undone. A turn in the object's matrix
    /// (Studio keeps rotations there) becomes its angle, so it opens turned, with its box turned; a mirrored or slanted
    /// matrix stays in the points. Studio's
    /// colors are RGB: the fills become CMYK with `colors` (the RGB working space → the CMYK profile); the line colors,
    /// which pick the cut settings, with the simple conversion, so they keep the CMYK (and the settings remembered for
    /// it) they always had (the owner's choice).
    /// Also returns the colors turned off in Studio's send settings, the images used, the summary for the window and
    /// where each object came from (to write over it).
    static func importResult(_ studio: StudioDocument, colors: ColorConverter) -> ([CanvasObject], [CMYK: CutConfig], [String: Data], String, [CanvasObject.ID: StudioPiece]) {
        var newItems: [CanvasObject] = []
        var pieces: [CanvasObject.ID: StudioPiece] = [:]
        var cuts: [CMYK: CutConfig] = [:]
        var images: [String: Data] = [:]
        var outside = 0
        for o in studio.objects {
            let onPage = o.path.boundingBoxOfPath
            guard !onPage.isNull else { continue }
            if !onPage.intersects(CGRect(origin: .zero, size: studio.pageSize)) { outside += 1 }
            // The turn: the points go back to before it (around the page's origin), the box is theirs, turned back after.
            let turn = studioAngle(o.transform)
            let back = turn.map { CanvasObject.rotation(-$0, around: .zero) } ?? .identity
            var local = o
            if turn != nil {
                local.subpaths = o.subpaths.map { nodes in
                    nodes.map { StudioDocument.Node(point: $0.point.applying(back), controlIn: $0.controlIn?.applying(back),
                                                    controlOut: $0.controlOut?.applying(back)) }
                }
            }
            let box = local.path.boundingBoxOfPath
            guard !box.isNull else { continue }
            let width = box.width > 0 ? box.width : 1, height = box.height > 0 ? box.height : 1
            let relative = { (p: CGPoint) in CGPoint(x: (p.x - box.minX) / width, y: (p.y - box.minY) / height) }
            let subpaths = local.subpaths.map { nodes in
                Subpath(nodes: nodes.map { Node(point: relative($0.point), input: $0.controlIn.map(relative),
                                             output: $0.controlOut.map(relative)) })
            }
            var object = CanvasObject(shape: .shapePath(subpaths), frame: box,
                                strokeColor: ColorConverter.simpleCMYK(red: o.line.red, green: o.line.green, blue: o.line.blue),
                                cutsLine: o.cuts)
            object.label = ["Rectangle": String(localized: "Rectangle"), "Ellipse": String(localized: "Ellipse"),
                             "Rounded Rectangle": String(localized: "Rounded Rectangle")][o.kind]
            if studio.lineColorCuts[o.line.hex] == false, cuts[object.strokeColor] == nil {
                var config = defaultConfig(object.strokeColor)
                config.enabled = false
                cuts[object.strokeColor] = config
            }
            switch o.fill {
            case .none:
                break
            case .color(let c):
                object.fill = colors.cmyk(red: c.red, green: c.green, blue: c.blue)
            case .image(let key, let pixelToPage):
                guard let image = studio.images[key] else { break }
                let pageToFrame = back.concatenating(CGAffineTransform(translationX: -box.minX, y: -box.minY))
                    .concatenating(CGAffineTransform(scaleX: 1 / width, y: 1 / height))
                images[key] = image.data
                object.image = ImageInShape(key: key, transform: Transform(pixelToPage.concatenating(pageToFrame)))
            }
            if let turn {
                object.rotation = turn
                let c = CGPoint(x: box.midX, y: box.midY).applying(CanvasObject.rotation(turn, around: .zero))
                object.frame = CGRect(x: c.x - box.width / 2, y: c.y - box.height / 2, width: box.width, height: box.height)
            }
            // Studio keeps every image as a shape filled with it. One whose outline isn't the image's own box (a sticker's
            // cut line around a photo, a fill pattern) opens as an image inside a shape, where it is (Model/ImageFitting.swift).
            if let placed = object.image, let picture = studio.images[placed.key], picture.pixelWidth > 0, picture.pixelHeight > 0 {
                object.imageFit = insideShape(placed, in: object.frame.standardized, pixels: CGSize(width: picture.pixelWidth, height: picture.pixelHeight))
            }
            newItems.append(object)
            pieces[object.id] = StudioPiece(shapePath: o.source, object: object, line: o.line)
        }
        let noCutLine = newItems.filter { !$0.cutsLine }.count
        var parts = [String(localized: "\(newItems.count) objects")]
        if studio.images.count > 0 { parts.append(String(localized: "\(studio.images.count) images")) }
        if noCutLine > 0 { parts.append(String(localized: "\(noCutLine) not cut")) }
        if !cuts.isEmpty { parts.append(String(localized: "\(cuts.count) colors turned off as in Studio")) }
        if outside > 0 { parts.append(String(localized: "\(outside) off the page")) }
        if studio.skipped > 0 { parts.append(String(localized: "\(studio.skipped) not read")) }
        if studio.registrationMarks?.on == true { parts.append(String(localized: "Print & Cut on")) }
        let notice = String(localized: "Imported from Silhouette Studio: \(parts.joined(separator: " · ")). ⌘S saves over the .studio3 or as a Cutline document.")
        return (newItems, cuts, images, notice, pieces)
    }

    /// The fitting of a Studio image whose outline doesn't just frame it (nil when the image fills its own box: an image on
    /// its own, as Import… makes it): Fill, with the image exactly where Studio has it.
    static func insideShape(_ placed: ImageInShape, in frame: CGRect, pixels: CGSize) -> ImageFitting? {
        let local = placed.transform.cg.concatenating(CGAffineTransform(a: frame.width, b: 0, c: 0, d: frame.height, tx: frame.minX, ty: frame.minY))
        let box = CGRect(origin: .zero, size: pixels).applying(local)
        let tolerance = 0.05
        if abs(box.minX - frame.minX) < tolerance, abs(box.minY - frame.minY) < tolerance, abs(box.maxX - frame.maxX) < tolerance,
           abs(box.maxY - frame.maxY) < tolerance {
            return nil
        }
        var fitting = ImageFitting(mode: .fill, pixels: pixels)
        fitting.adopt(local, in: frame)
        return fitting
    }

    /// The angle (degrees, counterclockwise) of a Studio matrix that turns without mirroring or slanting (a stretch along
    /// its own axes is fine: it stays in the points); nil when it doesn't turn, or mirrors or slants.
    static func studioAngle(_ t: CGAffineTransform) -> Double? {
        let lengthX = hypot(t.a, t.b), lengthY = hypot(t.c, t.d)
        guard lengthX > 1e-9, lengthY > 1e-9, t.a * t.d - t.b * t.c > 0,
              abs(t.a * t.c + t.b * t.d) <= 1e-4 * lengthX * lengthY else { return nil }
        // Studio's numbers are 32-bit floats: an angle within 1e-4° of a round one is that one.
        var angle = atan2(-t.b, t.a) * 180 / .pi
        if abs(angle - angle.rounded()) < 1e-4 { angle = angle.rounded() }
        angle = CanvasObject.normalizedAngle(angle)
        return angle == 0 ? nil : angle
    }
}

nonisolated extension ImageLink {
    /// The same link with the path relative to a document at `documentURL` (unchanged without one).
    func relative(to documentURL: URL?) -> ImageLink {
        guard let documentURL else { return self }
        var link = self
        link.relativePath = Self.relativePath(of: URL(fileURLWithPath: path), from: documentURL.deletingLastPathComponent())
        return link
    }

    /// "../Images/photo.png": from a folder to a file.
    static func relativePath(of file: URL, from folder: URL) -> String {
        let a = folder.standardizedFileURL.pathComponents, b = file.standardizedFileURL.pathComponents
        var common = 0
        while common < min(a.count, b.count - 1), a[common] == b[common] { common += 1 }
        return (Array(repeating: "..", count: a.count - common) + b[common...]).joined(separator: "/")
    }
}
