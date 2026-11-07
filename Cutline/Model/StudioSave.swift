// Saving over the .studio3. A Silhouette Studio file opened in Cutline has no Cutline file
// (MainWindow), and ⌘S asks whether to write over the .studio3 or as a Cutline document. The .studio3 is
// rebuilt by CutlineKit (Studio3Writer.swift): the top-level objects that didn't change go back as they were, the
// others are rebuilt from the object they came from. Before the first save, a copy of the original
// goes to the Trash; if the file changed since it was opened (saved by Studio), it doesn't save.
import AppKit
import CutlineKit
import ImageIO
import UniformTypeIdentifiers

extension Document {
    struct StudioWriting {
        var payload: Data
        var pieces: [CanvasObject.ID: StudioPiece]
        /// Open paths (the .studio3 only has closed contours).
        var openOnes: Int
        /// Gradient fills written as their first color (Cutline doesn't know how Studio stores a gradient).
        var solidGradients = 0
        /// Images inside shapes that repeat or are transparent, written as one opaque image (a tiled one covering the shape).
        var plainImageFills = 0
        /// Some layer has opacity or a blending mode (Silhouette Studio's layers have neither).
        var layerEffects = false
        /// Objects on the other artboards: Studio has one page (the 1st artboard), so they are off it there.
        var offFirstArtboard = 0
        /// The 1st artboard's size isn't the .studio3's page, which stays as it was.
        var pageSizeKept = false

        /// The window's notice after saving to `url`.
        func notice(_ url: URL) -> String {
            var text = openOnes > 0
                ? String(localized: "Saved to “\(url.lastPathComponent)”. \(openOnes) open paths were closed (a .studio3 has no open paths).")
                : String(localized: "Saved to “\(url.lastPathComponent)”.")
            if layerEffects {
                text += " " + String(localized: "The layers’ opacity and blending modes don’t go into a .studio3: Silhouette Studio’s layers have neither.")
            }
            if solidGradients > 0 {
                text += " " + String(localized: "\(solidGradients) gradient fills went in as a solid color (their first one): Cutline can’t write Silhouette Studio’s gradients yet.")
            }
            if plainImageFills > 0 {
                text += " " + String(localized: "\(plainImageFills) images inside shapes went in as one opaque image: Cutline can’t write Silhouette Studio’s tiled or transparent patterns yet.")
            }
            if offFirstArtboard > 0 {
                text += " " + String(localized: "Silhouette Studio has one page, the 1st artboard: \(offFirstArtboard) objects on the other artboards went in off the page.")
            }
            if pageSizeKept {
                text += " " + String(localized: "The page size stays the .studio3’s: Cutline can’t change it there yet.")
            }
            return text
        }
    }

    /// The .studio3 with the current document and the objects' new origins.
    func studioWriting(_ origin: StudioOrigin) throws -> StudioWriting {
        let order = objectsInOrder.filter { !$0.emptyText }
        // A top-level object from the file goes back intact when all the ones that came from it are there, unchanged.
        var count: [Int: Int] = [:], sharpOnes: [Int: [CanvasObject]] = [:]
        for piece in origin.pieces.values { count[piece.shapePath[0], default: 0] += 1 }
        for object in order {
            if let piece = origin.pieces[object.id] { sharpOnes[piece.shapePath[0], default: []].append(object) }
        }
        let intact = Set(sharpOnes.compactMap { top, objects in
            objects.count == count[top] && objects.allSatisfy { Self.equal($0, origin.pieces[$0.id]!.object) } ? top : nil
        })

        var items: [StudioWriter.Item] = [], owner: [[CanvasObject]] = [], lines: [StudioDocument.Color?] = []
        var doneOnes = Set<Int>(), openOnes = 0, solidGradients = 0, plainImageFills = 0
        for object in order {
            if let piece = origin.pieces[object.id], intact.contains(piece.shapePath[0]) {
                guard doneOnes.insert(piece.shapePath[0]).inserted else { continue }
                items.append(.original(piece.shapePath[0]))
                owner.append(sharpOnes[piece.shapePath[0]] ?? [])
                lines.append(nil)
                continue
            }
            let subpaths = object.absoluteNodes
            openOnes += subpaths.filter { !$0.closed && $0.nodes.count > 2 }.count
            if object.gradient != nil, object.fill != nil, object.image == nil { solidGradients += 1 }
            if object.image != nil, object.imageFit?.needsFlatImage == true { plainImageFills += 1 }
            let shape = try studioShape(object, subpaths, origin)
            items.append(.shape(shape))
            owner.append([object])
            lines.append(shape.line)
        }

        let c = marksConfig
        let studioMarks = StudioDocument.RegistrationMarks(on: marks, left: c.left, top: c.top, right: c.right,
                                                            bottom: c.bottom, length: c.length, thickness: c.strokeWidth)
        let (payload, indices) = try StudioWriter.writeWithMap(original: origin.payload, items: items, thumbnail: studioThumbnail(order),
                                                             marks: studioMarks)
        var pieces: [CanvasObject.ID: StudioPiece] = [:]
        for (n, objects) in owner.enumerated() {
            guard let top = indices[n] else { continue }
            for object in objects {
                if let line = lines[n] {
                    pieces[object.id] = StudioPiece(shapePath: [top], object: object, line: line)
                } else if let old = origin.pieces[object.id] {
                    pieces[object.id] = StudioPiece(shapePath: [top] + old.shapePath.dropFirst(), object: object, line: old.line)
                }
            }
        }
        let first = artboards[0].size
        return StudioWriting(payload: payload, pieces: pieces, openOnes: openOnes, solidGradients: solidGradients, plainImageFills: plainImageFills,
                             layerEffects: layers.contains { !$0.isPlain && objects(of: $0).contains(where: visible) },
                             offFirstArtboard: objectsOffFirstArtboard,
                             pageSizeKept: abs(origin.pageSize.width - first.width) > 0.05 || abs(origin.pageSize.height - first.height) > 0.05)
    }

    /// What the .studio3 keeps of an object: outline, line color, fill or image, "doesn't cut".
    private static func equal(_ a: CanvasObject, _ b: CanvasObject) -> Bool {
        a.shape == b.shape && a.frame == b.frame && a.rotation == b.rotation && a.strokeColor == b.strokeColor && a.fill == b.fill
            && a.image == b.image && a.cutsLine == b.cutsLine && a.gradient == b.gradient && a.imageFit == b.imageFit
    }

    private func studioShape(_ object: CanvasObject, _ subpaths: [Subpath], _ origin: StudioOrigin) throws -> StudioWriter.Shape {
        let piece = origin.pieces[object.id]
        let nodes = subpaths.map { $0.nodes.map { StudioDocument.Node(point: $0.point, controlIn: $0.input, controlOut: $0.output) } }
        let line = piece.map { $0.object.strokeColor == object.strokeColor } == true ? piece!.line : studioColor(ColorConverter.simpleRGB(object.strokeColor))
        var font = piece?.shapePath, copy = false, imageOnPage: CGAffineTransform?
        // The object `font` points to, as it came from the file (or as the last save wrote it).
        var sourceObject = piece?.object
        let fill: StudioWriter.FillChange
        if let image = object.image {
            guard origin.images.contains(image.key) else { throw DocumentFileError.newStudioImage }
            if piece?.object.image?.key != image.key {
                // A copy (⌘D, paste) of an object with that image: the style and the image come from it.
                guard let model = origin.pieces.values.first(where: { $0.object.image?.key == image.key }) else {
                    throw DocumentFileError.newStudioImage
                }
                (font, copy) = (model.shapePath, true)
                sourceObject = model.object
            }
            // A tiled image goes as one image covering the shape (Fill): the .studio3 gets no pattern (the notice says so).
            var placement = image.transform.cg
            if var fitting = object.imageFit, fitting.mode == .tile {
                fitting.mode = .fill
                fitting.resetContent()
                placement = fitting.pixelToFrame(in: object.frame.standardized)
            }
            imageOnPage = placement.concatenating(object.frameToPage)
            fill = .keep
        } else if let piece, piece.object.fill == object.fill, piece.object.gradient == object.gradient, piece.object.image == nil {
            fill = .keep
        } else {
            fill = object.fill.map { .color(studioColor(colors.rgb($0))) } ?? .none
        }
        // A turn stays in the matrix, as Studio keeps it: an object from the file goes from its matrix by where it went
        // (moved, stretched, turned); a new one gets its turn as its matrix.
        var sourceChange: CGAffineTransform?, localToPage: CGAffineTransform?
        if let source = sourceObject, object.rotation != 0 || source.rotation != 0,
           let before = CanvasObject.inverse(source.frameToPage), CanvasObject.inverse(object.frameToPage) != nil {
            sourceChange = before.concatenating(object.frameToPage)
        } else if font == nil, object.rotation != 0 {
            localToPage = object.rotationTransform
        }
        return StudioWriter.Shape(subpaths: nodes, line: line, fill: fill, imageToPage: imageOnPage,
                                  cuts: object.cutsLine, source: font, copy: copy, sourceChange: sourceChange, localToPage: localToPage)
    }

    /// Studio's colors are RGB 0–1, in steps of 1/255: the fills in the RGB working space (as they are shown), the line
    /// colors by the simple conversion (as they came in: Model/DocumentFile.swift).
    private func studioColor(_ rgb: [Double]) -> StudioDocument.Color {
        let rgb = rgb.map { ($0 * 255).rounded() / 255 }
        return StudioDocument.Color(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
    }

    /// Thumbnail like Studio's: 512 × 512, transparent background, everything framed (also what's off the page).
    private func studioThumbnail(_ objects: [CanvasObject]) -> Data? {
        let paths = objects.map { ($0, $0.shapePath.cgPath) }
        var box = paths.reduce(CGRect.null) { $0.union($1.1.boundingBoxOfPath) }
        guard !box.isNull, max(box.width, box.height) > 0 else { return nil }
        box = box.insetBy(dx: -max(box.width, box.height) * 0.02, dy: -max(box.width, box.height) * 0.02)
        let side = 512.0, scale = side / max(box.width, box.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGContext(data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // y down, as in the document.
        cg.translateBy(x: (side - box.width * scale) / 2, y: side - (side - box.height * scale) / 2)
        cg.scaleBy(x: scale, y: -scale)
        cg.translateBy(x: -box.minX, y: -box.minY)
        // The CMYK as it prints (Model/ColorConversion.swift; without a profile, Generic CMYK, as always).
        let colors = colors
        cg.setRenderingIntent(colors.intent)
        for (object, shapePath) in paths {
            if let gradient = object.gradient, object.fill != nil {
                gradient.fill(object, outline: shapePath, in: cg, colors: colors, screen: false)
            } else if let color = object.fill {
                cg.addPath(shapePath)
                cg.setFillColor(colors.printColor(color))
                cg.fillPath(using: .evenOdd)
            }
            if let inShape = object.image, let pixels = image(inShape.key) {
                cg.saveGState()
                cg.addPath(shapePath)
                cg.clip(using: .evenOdd)
                ImageFillDrawing.draw(pixels, pixels: pixelSize(inShape.key, of: pixels),
                                      pixelToPage: inShape.transform.cg.concatenating(object.frameToPage), fitting: object.imageFit, in: cg)
                cg.restoreGState()
            }
            cg.addPath(shapePath)
            cg.setStrokeColor(colors.printColor(object.strokeColor))
            cg.setLineWidth(1 / scale)
            cg.strokePath()
        }
        guard let image = cg.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

/// ⌘S on a document that came from Studio and hasn't been saved as a Cutline document yet.
@MainActor
enum StudioSave {
    /// Detaches a document opened from a .studio3 from that file: it keeps the location (`doc.studio.url`) and
    /// becomes an untitled Cutline document with the .studio3's name, so macOS never writes the .studio3 itself.
    static func detach(_ doc: Document, from document: NSDocument, nsWindow: NSWindow?) {
        doc.cameFromStudio = false
        guard let kind = document.fileType.flatMap({ UTType($0) }), kind.conforms(to: .studio3) else { return }
        let name = document.fileURL?.deletingPathExtension().lastPathComponent
        doc.studio?.url = document.fileURL
        document.fileURL = nil
        document.fileType = UTType.cutlineDocument.identifier
        if let name {
            document.displayName = name
            nsWindow?.windowController?.synchronizeWindowTitleWithDocumentName()
        }
    }

    /// File › Save As… on a document that came from Studio: the save panel with a format menu, Cutline (.cutline) or
    /// Silhouette Studio (.studio3). The .studio3 is rebuilt from the opened one (the writer needs it as a base), so a
    /// document made in Cutline only gets the usual panel.
    static func saveAs(_ doc: Document, _ document: NSDocument, nsWindow: NSWindow) {
        guard let origin = doc.studio, StudioWriter.canWrite(origin.payload) else { return document.saveAs(nil) }
        let panel = NSSavePanel()
        let base = origin.url ?? document.fileURL
        panel.nameFieldStringValue = base?.deletingPathExtension().lastPathComponent ?? document.displayName
        panel.directoryURL = base?.deletingLastPathComponent()
        panel.canCreateDirectories = true
        let chooser = FormatChooser(panel: panel, studio: document.fileURL == nil)
        panel.accessoryView = chooser.view
        panel.beginSheetModal(for: nsWindow) { response in
            guard response == .OK, let url = panel.url else { return }
            if chooser.studio {
                write(doc, document, to: url, nsWindow: nsWindow)
            } else {
                document.save(to: url, ofType: UTType.cutlineDocument.identifier, for: .saveAsOperation) { error in
                    if let error { NSAlert(error: error).beginSheetModal(for: nsWindow) }
                }
            }
        }
    }

    /// Writes the document as a new .studio3 at `url`, built from the opened one; from then on the document follows
    /// that file (⌘S writes there), detached like an opened .studio3.
    static func write(_ doc: Document, _ document: NSDocument, to url: URL, nsWindow: NSWindow) {
        guard var origin = doc.studio else { return }
        doc.finishText()
        do {
            let writing = try doc.studioWriting(origin)
            try writing.payload.write(to: url, options: .atomic)
            origin.url = url
            origin.payload = writing.payload
            origin.pieces = writing.pieces
            // Chosen in the panel: ⌘S writes over it without asking, and there is no older version to keep a copy of.
            origin.confirmed = true
            origin.copyInTrash = true
            doc.studio = origin
            document.fileURL = nil
            document.fileType = UTType.cutlineDocument.identifier
            document.displayName = url.deletingPathExtension().lastPathComponent
            nsWindow.windowController?.synchronizeWindowTitleWithDocumentName()
            document.updateChangeCount(.changeCleared)
            doc.notice = writing.notice(url)
            #if DEBUG
            NSLog("CUTLINE_TEST notice: %@", doc.notice ?? "")
            #endif
        } catch {
            #if DEBUG
            NSLog("CUTLINE_TEST write studio3 as: %@", String(describing: error))
            #endif
            NSAlert(error: error).beginSheetModal(for: nsWindow)
        }
    }

    /// Still attached to its .studio3 (the window didn't get to detach it).
    static func stillAttached(_ document: NSDocument) -> Bool {
        document.fileURL != nil && document.fileType.flatMap({ UTType($0) })?.conforms(to: .studio3) == true
    }

    static func save(_ doc: Document, _ document: NSDocument, nsWindow: NSWindow) {
        #if DEBUG
        NSLog("CUTLINE_TEST save studio3: url %@", String(describing: doc.studio?.url))
        #endif
        guard let origin = doc.studio, let url = origin.url else { return document.save(nil) }
        if origin.confirmed { return write(doc, document, nsWindow: nsWindow) }
        let writable = StudioWriter.canWrite(origin.payload)
        let alert = NSAlert()
        alert.messageText = String(localized: "Save “\(url.lastPathComponent)”")
        if writable {
            alert.informativeText = String(localized: "This document came from Silhouette Studio. You can save over the .studio3 file, which still opens in Studio, or keep it as a Cutline document. Before saving over it, a copy of the original goes to the Trash.")
            alert.addButton(withTitle: String(localized: "Save to .studio3"))
        } else {
            alert.informativeText = String(localized: "This Silhouette Studio file is laid out in a way Cutline can't rewrite yet. Save it as a Cutline document.")
        }
        alert.addButton(withTitle: String(localized: "Save as Cutline…"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: nsWindow) { response in
            switch (writable, response) {
            case (true, .alertFirstButtonReturn): write(doc, document, nsWindow: nsWindow)
            case (true, .alertSecondButtonReturn), (false, .alertFirstButtonReturn): document.saveAs(nil)
            default: break
            }
        }
        #if DEBUG
        DebugHooks.answerAlertForTest(alert, nsWindow: nsWindow)
        #endif
    }

    static func write(_ doc: Document, _ document: NSDocument, nsWindow: NSWindow) {
        guard var origin = doc.studio, let url = origin.url else { return }
        doc.finishText()
        do {
            guard (try? Data(contentsOf: url)) == origin.payload else { throw DocumentFileError.studioChanged }
            let writing = try doc.studioWriting(origin)
            if !origin.copyInTrash {
                var folder = FileManager.default.temporaryDirectory
                #if DEBUG
                // In hidden tests, the copy stays next to the test file, not in the owner's Trash.
                if DebugHooks.hidden { folder = url.deletingLastPathComponent() }
                #endif
                let copy = folder.appending(path: url.deletingPathExtension().lastPathComponent + String(localized: " (before Cutline)") + ".studio3")
                try? FileManager.default.removeItem(at: copy)
                try origin.payload.write(to: copy)
                #if DEBUG
                if !DebugHooks.hidden { try FileManager.default.trashItem(at: copy, resultingItemURL: nil) }
                #else
                try FileManager.default.trashItem(at: copy, resultingItemURL: nil)
                #endif
                origin.copyInTrash = true
            }
            try writing.payload.write(to: url, options: .atomic)
            origin.payload = writing.payload
            origin.pieces = writing.pieces
            origin.confirmed = true
            doc.studio = origin
            document.updateChangeCount(.changeCleared)
            doc.notice = writing.notice(url)
            #if DEBUG
            NSLog("CUTLINE_TEST notice: %@", doc.notice ?? "")
            #endif
        } catch {
            #if DEBUG
            NSLog("CUTLINE_TEST write studio3: %@", String(describing: error))
            #endif
            NSAlert(error: error).beginSheetModal(for: nsWindow)
        }
    }
}

/// The save panel's format menu (Save As… of a document that came from Studio).
@MainActor
private final class FormatChooser: NSObject {
    private weak var panel: NSSavePanel?
    private let menu = NSPopUpButton(frame: .zero, pullsDown: false)
    let view: NSView
    /// Silhouette Studio (.studio3) chosen.
    var studio: Bool { menu.indexOfSelectedItem == 1 }

    /// `studio`: start with the .studio3 (the document still follows its .studio3).
    init(panel: NSSavePanel, studio: Bool) {
        self.panel = panel
        let label = NSTextField(labelWithString: String(localized: "Format:"))
        menu.addItems(withTitles: [String(localized: "Cutline Document (.cutline)"), String(localized: "Silhouette Studio (.studio3)")])
        menu.selectItem(at: studio ? 1 : 0)
        let row = NSStackView(views: [label, menu])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        view = row
        super.init()
        menu.target = self
        menu.action = #selector(changed(_:))
        changed(nil)
    }

    @objc private func changed(_ sender: Any?) {
        panel?.allowedContentTypes = [studio ? UTType.studio3 : UTType.cutlineDocument]
    }
}

