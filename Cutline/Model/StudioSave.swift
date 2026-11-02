// Saving over the .studio3. A Silhouette Studio file opened in Cutline has no Cutline file
// (MainWindow), and ⌘S asks whether to write over the .studio3 or as a Cutline document. The .studio3 is
// rebuilt by CutlineKit (Studio3Writer.swift): the top-level objects that didn't change go back as they were, the
// others are rebuilt from the object they came from. Before the first save, a copy of the original
// goes to the Trash; if the file changed since it was opened (saved by Studio), it doesn't save.
import AppKit
import CutlineKit
import ImageIO
import UniformTypeIdentifiers

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

extension Document {
    struct StudioWriting {
        var payload: Data
        var pieces: [CanvasObject.ID: StudioPiece]
        /// Open paths (the .studio3 only has closed contours).
        var openOnes: Int
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
        var doneOnes = Set<Int>(), openOnes = 0
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
        return StudioWriting(payload: payload, pieces: pieces, openOnes: openOnes)
    }

    /// What the .studio3 keeps of an object: outline, line color, fill or image, "doesn't cut".
    private static func equal(_ a: CanvasObject, _ b: CanvasObject) -> Bool {
        a.shape == b.shape && a.frame == b.frame && a.strokeColor == b.strokeColor && a.fill == b.fill
            && a.image == b.image && a.cutsLine == b.cutsLine
    }

    private func studioShape(_ object: CanvasObject, _ subpaths: [Subpath], _ origin: StudioOrigin) throws -> StudioWriter.Shape {
        let piece = origin.pieces[object.id]
        let nodes = subpaths.map { $0.nodes.map { StudioDocument.Node(point: $0.point, controlIn: $0.input, controlOut: $0.output) } }
        let line = piece.map { $0.object.strokeColor == object.strokeColor } == true ? piece!.line : Self.color(object.strokeColor)
        var font = piece?.shapePath, copy = false, imageOnPage: CGAffineTransform?
        let fill: StudioWriter.FillChange
        if let image = object.image {
            guard origin.images.contains(image.key) else { throw DocumentFileError.newStudioImage }
            if piece?.object.image?.key != image.key {
                // A copy (⌘D, paste) of an object with that image: the style and the image come from it.
                guard let model = origin.pieces.values.first(where: { $0.object.image?.key == image.key }) else {
                    throw DocumentFileError.newStudioImage
                }
                (font, copy) = (model.shapePath, true)
            }
            imageOnPage = image.transform.cg.concatenating(object.frameToPage)
            fill = .keep
        } else if let piece, piece.object.fill == object.fill, piece.object.image == nil {
            fill = .keep
        } else {
            fill = object.fill.map { .color(Self.color($0)) } ?? .none
        }
        return StudioWriter.Shape(subpaths: nodes, line: line, fill: fill, imageToPage: imageOnPage,
                                  cuts: object.cutsLine, source: font, copy: copy)
    }

    private static func color(_ c: CMYK) -> StudioDocument.Color {
        let rgb = c.rgb255.map { Double($0) / 255 }
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
        for (object, shapePath) in paths {
            if let color = object.fill {
                cg.addPath(shapePath)
                cg.setFillColor(color.cgCMYK)
                cg.fillPath(using: .evenOdd)
            }
            if let inShape = object.image, let pixels = image(inShape.key) {
                cg.saveGState()
                cg.addPath(shapePath)
                cg.clip(using: .evenOdd)
                cg.concatenate(inShape.transform.cg.concatenating(object.frameToPage))
                cg.translateBy(x: 0, y: CGFloat(pixels.height))
                cg.scaleBy(x: 1, y: -1)
                cg.draw(pixels, in: CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
                cg.restoreGState()
            }
            cg.addPath(shapePath)
            cg.setStrokeColor(object.strokeColor.cgCMYK)
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
            doc.notice = writing.openOnes > 0
                ? String(localized: "Saved to “\(url.lastPathComponent)”. \(writing.openOnes) open paths were closed (a .studio3 has no open paths).")
                : String(localized: "Saved to “\(url.lastPathComponent)”.")
        } catch {
            #if DEBUG
            NSLog("CUTLINE_TEST write studio3: %@", String(describing: error))
            #endif
            NSAlert(error: error).beginSheetModal(for: nsWindow)
        }
    }
}
