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
        case version = "versao", objects = "objetos", cuts = "cortes", cutOrder = "ordemCortes", images = "imagens", layers = "camadas", activeLayer = "camadaAtiva", recent = "recentes", guides = "guias", marks = "marcas", marksConfig = "configMarcas", withMat = "comBase", cuttingMatSetting = "baseDeCorte"
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
            let (objects, cuts, images, notice, pieces) = Self.importResult(studio)
            // Print & Cut as Studio left it: on or not, and the marks at the same spot on the sheet it prints.
            let marks = studio.registrationMarks
            self.init(objects: objects, cuts: cuts, images: images, marks: marks?.on ?? false,
                      marksConfig: marks.map(MarksConfig.init) ?? .defaultValue, notice: notice, cameFromStudio: true)
            self.studio = StudioOrigin(payload: payload, pieces: pieces, images: Set(studio.images.keys))
        } else {
            let file = try DocumentFile.read(payload)
            self.init(objects: file.objects,
                      cuts: Dictionary(file.cuts.map { ($0.color, $0.config) }, uniquingKeysWith: { _, last in last }),
                      cutOrder: file.cutOrder, images: file.images, layers: file.layers,
                      activeLayer: file.activeLayer, recent: file.recent, guides: file.guides,
                      marks: file.marks, marksConfig: file.marksConfig, withMat: file.withMat,
                      cuttingMatSetting: .some(file.cuttingMatSetting))
        }
    }

    func snapshot(contentType: UTType) throws -> Data {
        // Never writes over the Studio file, even if macOS tries to save in place.
        guard contentType.conforms(to: .cutlineDocument) else { throw DocumentFileError.readOnly }
        let used = Set(objects.compactMap { $0.image?.key })
        // Empty text only exists while typing on the canvas: it doesn't go into the file.
        return try DocumentFile(objects: objects.filter { !$0.emptyText }, cuts: cuts.map { DocumentFile.CutByColor(color: $0.key, config: $0.value) },
                           cutOrder: cutOrder, images: images.filter { used.contains($0.key) },
                           layers: layers, activeLayer: activeLayer, recent: recent, guides: guides, marks: marks,
                           marksConfig: marksConfig, withMat: withMat, cuttingMatSetting: cuttingMatSetting).payload()
    }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        guard configuration.contentType.conforms(to: .cutlineDocument) else { throw DocumentFileError.readOnly }
        return FileWrapper(regularFileWithContents: snapshot)
    }
}

nonisolated extension Document {
    /// Objects of a Silhouette Studio document: each contour becomes a path with the line color
    /// (which defines the cut), the fill and the clipped image; groups and rotations come already undone.
    /// Also returns the colors turned off in Studio's send settings, the images used, the summary for the window and
    /// where each object came from (to write over it).
    static func importResult(_ studio: StudioDocument) -> ([CanvasObject], [CMYK: CutConfig], [String: Data], String, [CanvasObject.ID: StudioPiece]) {
        var newItems: [CanvasObject] = []
        var pieces: [CanvasObject.ID: StudioPiece] = [:]
        var cuts: [CMYK: CutConfig] = [:]
        var images: [String: Data] = [:]
        for o in studio.objects {
            let box = o.path.boundingBoxOfPath
            guard !box.isNull else { continue }
            let width = box.width > 0 ? box.width : 1, height = box.height > 0 ? box.height : 1
            let relative = { (p: CGPoint) in CGPoint(x: (p.x - box.minX) / width, y: (p.y - box.minY) / height) }
            let subpaths = o.subpaths.map { nodes in
                Subpath(nodes: nodes.map { Node(point: relative($0.point), input: $0.controlIn.map(relative),
                                             output: $0.controlOut.map(relative)) })
            }
            var object = CanvasObject(shape: .shapePath(subpaths), frame: box,
                                strokeColor: CMYK(red: o.line.red, green: o.line.green, blue: o.line.blue), cutsLine: o.cuts)
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
                object.fill = CMYK(red: c.red, green: c.green, blue: c.blue)
            case .image(let key, let pixelToPage):
                guard let image = studio.images[key] else { break }
                let pageToFrame = CGAffineTransform(translationX: -box.minX, y: -box.minY)
                    .concatenating(CGAffineTransform(scaleX: 1 / width, y: 1 / height))
                images[key] = image.data
                object.image = ImageInShape(key: key, transform: Transform(pixelToPage.concatenating(pageToFrame)))
            }
            newItems.append(object)
            pieces[object.id] = StudioPiece(shapePath: o.source, object: object, line: o.line)
        }
        let outside = newItems.filter { !$0.frame.intersects(CGRect(origin: .zero, size: Self.page)) }.count
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
}
