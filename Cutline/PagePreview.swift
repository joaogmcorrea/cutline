// A file's page drawn from the file itself: what gets printed (fills, images, printed strokes, marks) plus the cut
// lines. The start screen's recent files and the Finder's thumbnails show the sheet (the 1st artboard); the Finder's
// Quick Look (space bar) shows the 1st artboard and, when something is off it, everything in the file: the objects off
// it and the other artboards. The CutlinePreview and CutlineThumbnail extensions compile this file and the model files
// it needs.
import CoreGraphics
import CutlineKit
import Foundation
import UniformTypeIdentifiers

enum PagePreview {
    /// The document in a .cutline or .studio3, with only what drawing needs, and the sheet it was made on, in mm: the
    /// 1st artboard (an A4 in files without artboards), or Silhouette Studio's page size for a .studio3 (Letter, 12 × 12
    /// in…). nil if it can't be read.
    static func file(at url: URL) -> (doc: Document, sheet: CGSize)? {
        guard let payload = try? Data(contentsOf: url) else { return nil }
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .studio3) == true {
            guard let studio = try? StudioDocument(data: payload) else { return nil }
            let (objects, _, images, _, _) = Document.importResult(studio, colors: ColorSettings.shared.converter())
            return (Document(objects: objects, images: images, artboards: [Artboard(rect: CGRect(origin: .zero, size: studio.pageSize))],
                             marks: studio.registrationMarks?.on ?? false,
                             marksConfig: studio.registrationMarks.map(MarksConfig.init) ?? .defaultValue), studio.pageSize)
        }
        guard let file = try? DocumentFile.read(payload) else { return nil }
        // A linked image's file can't be read from the extensions' sandbox: its preview shows.
        let doc = Document(objects: file.objects, images: file.images, links: file.links ?? [:], layers: file.layers,
                           artboards: file.artboards ?? [], marks: file.marks, marksConfig: file.marksConfig, colorProfile: file.colorProfile)
        doc.anchorFirstArtboard()
        return (doc, doc.firstSheet)
    }

    /// What the file draws, in mm: the sheet (the 1st artboard) and, when something visible goes past its edge (by more
    /// than 0.5 mm, so a frame drawn right on the edge doesn't count), every visible object and the other artboards, with
    /// a 5 mm margin.
    static func contentBox(_ doc: Document, sheet: CGSize) -> CGRect {
        let page = CGRect(origin: .zero, size: sheet)
        var box = page
        // The other artboards only count with something on them that shows (an empty one is just paper).
        for object in doc.objectsInOrder where doc.visible(object) {
            let width = object.strokeWidth / Printing.pointsPerMM
            let reach = switch object.style.alignment {
            case .center: width / 2
            case .inside: 0.0
            case .outside: width
            }
            box = box.union(object.shapePath.cgPath.boundingBoxOfPath.insetBy(dx: -reach, dy: -reach))
        }
        guard !page.insetBy(dx: -0.5, dy: -0.5).contains(box) else { return page }
        for artboard in doc.artboards.dropFirst() { box = box.union(artboard.rect) }
        return box.insetBy(dx: -5, dy: -5)
    }

    /// The page (mm, y down) in a context in points. The 0 pt cut lines don't print, but they are most of a sticker
    /// sheet: they go on top, in their color, `cutLineWidth` mm wide.
    static func draw(_ doc: Document, in ctx: CGContext, cutLineWidth: CGFloat) {
        Printing.render(doc, in: ctx)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.scaleBy(x: Printing.pointsPerMM, y: Printing.pointsPerMM)
        ctx.setLineWidth(cutLineWidth)
        let colors = doc.colors
        ctx.setRenderingIntent(colors.intent)
        for object in doc.objectsInOrder where doc.visible(object) && object.cutsLine && object.strokeWidth == 0 {
            ctx.addPath(object.shapePath.cgPath)
            ctx.setStrokeColor(colors.printColor(object.strokeColor))
            ctx.strokePath()
        }
    }

    /// The sheet (the 1st artboard) `width` pixels wide, on white.
    static func image(of url: URL, width: Int) -> CGImage? {
        guard let (doc, sheet) = file(at: url) else { return nil }
        let scale = Double(width) / (sheet.width * Printing.pointsPerMM)
        let height = Int((sheet.height * Printing.pointsPerMM * scale).rounded())
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

    /// Everything in the file as a one-page PDF at actual size, and the page's size in points. Only the sheet, on white,
    /// when everything is on it; otherwise the sheet with its edge, on the gray of the desk, and all the objects around
    /// it. The cut lines get a real width: PDF viewers skip a 0 width line (the canvas's 1-pixel thread).
    static func pdf(of url: URL) -> (data: Data, size: CGSize)? {
        guard let (doc, sheet) = file(at: url) else { return nil }
        let k = Printing.pointsPerMM
        let box = contentBox(doc, sheet: sheet)
        let page = CGRect(x: 0, y: 0, width: sheet.width * k, height: sheet.height * k)
        let offSheet = box != CGRect(origin: .zero, size: sheet)
        var media = CGRect(x: 0, y: 0, width: box.width * k, height: box.height * k)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: &media, nil)
        else { return nil }
        ctx.beginPDFPage(nil)
        // y down, with the box's corner at the top left of the PDF page.
        ctx.translateBy(x: 0, y: media.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -box.minX * k, y: -box.minY * k)
        if offSheet {
            ctx.setFillColor(gray: 0.88, alpha: 1)
            ctx.fill(CGRect(x: box.minX * k, y: box.minY * k, width: media.width, height: media.height))
        }
        ctx.setFillColor(.white)
        ctx.fill(page)
        // The other artboards, when they show: paper too.
        let others = offSheet ? doc.artboards.dropFirst().map { $0.rect.applying(CGAffineTransform(scaleX: k, y: k)) } : []
        for sheet in others { ctx.fill(sheet) }
        draw(doc, in: ctx, cutLineWidth: 0.25)
        if offSheet {
            // The sheets' edges on top of the artwork, to tell what is on them from what is off them.
            ctx.setStrokeColor(gray: 0.5, alpha: 1)
            ctx.setLineWidth(0.5)
            ctx.stroke(page)
            for sheet in others { ctx.stroke(sheet) }
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return (data as Data, media.size)
    }
}
