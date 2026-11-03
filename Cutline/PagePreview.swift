// A file's page drawn from the file itself: what gets printed (fills, images, printed strokes, marks) plus the cut
// lines. The start screen's recent files use it, and so does the Finder's Quick Look (space bar), through the
// CutlinePreview extension, which compiles this file and the model files it needs.
import CoreGraphics
import CutlineKit
import Foundation
import UniformTypeIdentifiers

enum PagePreview {
    /// The document in a .cutline or .studio3, with only what drawing needs; nil if it can't be read.
    static func document(at url: URL) -> Document? {
        guard let payload = try? Data(contentsOf: url) else { return nil }
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .studio3) == true {
            guard let studio = try? StudioDocument(data: payload) else { return nil }
            let (objects, _, images, _, _) = Document.importResult(studio)
            return Document(objects: objects, images: images, marks: studio.registrationMarks?.on ?? false,
                            marksConfig: studio.registrationMarks.map(MarksConfig.init) ?? .defaultValue)
        }
        guard let file = try? DocumentFile.read(payload) else { return nil }
        return Document(objects: file.objects, images: file.images, layers: file.layers, marks: file.marks,
                        marksConfig: file.marksConfig)
    }

    /// The page (mm, y down) in a context in points. The 0 pt cut lines don't print, but they are most of a sticker
    /// sheet: they go on top, in their color, `cutLineWidth` mm wide.
    static func draw(_ doc: Document, in ctx: CGContext, cutLineWidth: CGFloat) {
        Printing.render(doc, in: ctx)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.scaleBy(x: Printing.pointsPerMM, y: Printing.pointsPerMM)
        ctx.setLineWidth(cutLineWidth)
        for object in doc.objectsInOrder where doc.visible(object) && object.cutsLine && object.strokeWidth == 0 {
            ctx.addPath(object.shapePath.cgPath)
            ctx.setStrokeColor(object.strokeColor.cgCMYK)
            ctx.strokePath()
        }
    }

    /// The page `width` pixels wide, on white.
    static func image(of url: URL, width: Int) -> CGImage? {
        guard let doc = document(at: url) else { return nil }
        let scale = Double(width) / (Document.page.width * Printing.pointsPerMM)
        let height = Int((Document.page.height * Printing.pointsPerMM * scale).rounded())
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // The page is drawn y down, as in the print view.
        ctx.translateBy(x: 0, y: Double(height))
        ctx.scaleBy(x: scale, y: -scale)
        draw(doc, in: ctx, cutLineWidth: 0.4)
        return ctx.makeImage()
    }

    /// The page as a one-page PDF at actual size (A4 in points), on white. The cut lines get a real width: PDF viewers
    /// skip a 0 width line (the canvas's 1-pixel thread).
    static func pdf(of url: URL) -> Data? {
        guard let doc = document(at: url) else { return nil }
        var page = CGRect(x: 0, y: 0, width: Document.page.width * Printing.pointsPerMM,
                          height: Document.page.height * Printing.pointsPerMM)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: &page, nil)
        else { return nil }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(.white)
        ctx.fill(page)
        ctx.translateBy(x: 0, y: page.height)
        ctx.scaleBy(x: 1, y: -1)
        draw(doc, in: ctx, cutLineWidth: 0.25)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }
}
