// File › Print… (⌘P): one page per artboard (all of them, or the range chosen in the print panel), at actual size, with
// what gets printed — fills, images and strokes with width — and, with Print & Cut, each artboard's registration marks
// and print bleed (Model/PrintBleed.swift). The paper is the one chosen in the panel (the 1st artboard's size to
// start); each page goes against its top-left corner, turned to landscape for a landscape artboard (macOS can't
// change the paper size between pages, only the orientation).
// The bleed is in the print and on the canvas; the Finder's previews leave it out. 0 pt strokes only mark the cut
// and are not printed. Colors go in CMYK with the document's CMYK profile (Model/ColorConversion.swift), with the
// perceptual intent, as the canvas shows them; ColorSync converts them for the printer. Without a profile, in Generic
// CMYK, as Cutline always printed.
import AppKit
import SwiftUI

enum Printing {
    static let pointsPerMM = 72 / 25.4

    /// The system print panel (as a sheet over the window). With `pdf`, writes straight to the file, without a panel.
    static func printDocument(_ doc: Document, in nsWindow: NSWindow?, pdf: URL? = nil) {
        let info = NSPrintInfo()
        // The 1st artboard's paper, upright (each landscape page turns on its own), no margins or centering: the page
        // comes out at the same position and scale as the document.
        let first = doc.artboards[0].size
        info.paperSize = NSSize(width: min(first.width, first.height) * pointsPerMM, height: max(first.width, first.height) * pointsPerMM)
        info.orientation = .portrait
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        if let pdf {
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL.rawValue] = pdf
        }
        let operation = NSPrintOperation(view: PrintedSheets(doc: doc), printInfo: info)
        operation.jobTitle = nsWindow?.title ?? "Cutline"
        if pdf != nil {
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            operation.run()
        } else if let nsWindow {
            operation.runModal(for: nsWindow, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    /// Draws the canvas in mm (y down) in a context in points. `marks` false leaves the registration marks out (the
    /// print bleed's source); `sheets` = the artboards whose marks go in (nil = all); `bleed` goes under everything;
    /// `screenColors` paints with the canvas's colors instead of the print's CMYK (the bleed's canvas preview);
    /// `opaqueImages` leaves the images' opacity out (the bleed's coverage: a transparent image still inks its pixels).
    static func render(_ doc: Document, in cg: CGContext, marks: Bool = true, sheets: [SheetFrame]? = nil,
                       bleed: [PrintBleed.Piece] = [], screenColors: Bool = false, opaqueImages: Bool = false) {
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.scaleBy(x: pointsPerMM, y: pointsPerMM)
        let colors = doc.colors
        cg.setRenderingIntent(colors.intent)
        PrintBleed.draw(bleed, in: cg)
        // A layer with opacity or a blending mode is drawn as a group (a PDF transparency group), mixed with what is under it.
        for run in doc.layerRuns {
            let grouped = !run.layer.isPlain
            if grouped {
                cg.saveGState()
                cg.setAlpha(run.layer.alpha)
                cg.setBlendMode((run.layer.blend ?? .normal).cg)
                cg.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            for object in run.objects {
                let shapePath = object.shapePath.cgPath
                if let gradient = object.gradient, object.fill != nil {
                    gradient.fill(object, outline: shapePath, in: cg, colors: colors, screen: screenColors)
                } else if let color = object.fill {
                    cg.addPath(shapePath)
                    cg.setFillColor(screenColors ? colors.screen(color) : colors.printColor(color))
                    cg.fillPath(using: .evenOdd)
                }
                if let image = object.image, let cgImage = doc.image(image.key) {
                    // Clipped by the outline (even-odd rule, as on the canvas); an image inside a shape repeats (Tile) and
                    // has its opacity (Model/ImageFitting.swift). A missing linked image's preview covers the same pixels
                    // as the file.
                    cg.saveGState()
                    cg.addPath(shapePath)
                    cg.clip(using: .evenOdd)
                    var fitting = object.imageFit
                    if opaqueImages { fitting?.opacity = 1 }
                    ImageFillDrawing.draw(cgImage, pixels: doc.pixelSize(image.key, of: cgImage),
                                          pixelToPage: image.transform.cg.concatenating(object.frameToPage), fitting: fitting, in: cg)
                    cg.restoreGState()
                }
                if object.strokeWidth > 0 {
                    trace(object, shapePath, in: cg, color: screenColors ? colors.screen(object.strokeColor) : colors.printColor(object.strokeColor))
                }
            }
            if grouped {
                cg.endTransparencyLayer()
                cg.restoreGState()
            }
        }
        if marks, doc.marks {
            let black = colors.printColor(CMYK(c: 0, m: 0, y: 0, k: 100))
            cg.setFillColor(black)
            for sheet in sheets ?? doc.artboards.map(doc.sheetFrame) {
                cg.fill(doc.marksConfig.rectangles(on: sheet))
                // The 50 mm line to check the sheet was printed at 100 % (Model/RegistrationMarks.swift).
                doc.marksConfig.scaleCheck(on: sheet)?.draw(in: cg, color: black)
            }
        }
    }

    /// Stroke with width (pt → mm), cap, join, dashes and alignment — as on the canvas.
    private static func trace(_ object: CanvasObject, _ shapePath: CGPath, in cg: CGContext, color: CGColor) {
        let e = object.style
        cg.saveGState()
        defer { cg.restoreGState() }
        var width = object.strokeWidth / pointsPerMM
        if e.alignment != .center {
            // Inside/outside: twice the width, clipped by the outline itself (or by its outside).
            if e.alignment == .outside { cg.addRect(shapePath.boundingBoxOfPath.insetBy(dx: -(50 + width), dy: -(50 + width))) }
            cg.addPath(shapePath)
            cg.clip(using: .evenOdd)
            width *= 2
        }
        cg.setStrokeColor(color)
        cg.setLineWidth(width)
        cg.setLineCap(e.cap.cg)
        cg.setLineJoin(e.join.cg)
        cg.setMiterLimit(e.miterLimit)
        if let defaultValue = e.line.defaultValue { cg.setLineDash(phase: 0, lengths: defaultValue.map { CGFloat($0) }) }
        cg.addPath(shapePath)
        cg.strokePath()
    }
}

extension GradientFill {
    /// For the print: the stops as they are, CMYK in the document's profile (CoreGraphics mixes them in CMYK, and a PDF
    /// gets a CMYK shading). For the screen: 65 samples mixed in CMYK and shown as the canvas shows solid colors, so a
    /// gradient and a solid fill of the same CMYK look the same.
    func cgGradient(_ colors: ColorConverter, screen: Bool) -> CGGradient? {
        guard stops.count >= 2 else { return nil }
        if !screen {
            let components = stops.flatMap { [$0.color.c / 100, $0.color.m / 100, $0.color.y / 100, $0.color.k / 100, 1].map { CGFloat($0) } }
            return CGGradient(colorSpace: colors.cmykSpace, colorComponents: components, locations: stops.map { CGFloat($0.location) },
                              count: stops.count)
        }
        let samples = 64
        let points = (0...samples).map { Double($0) / Double(samples) }
        let shown = points.map { t -> CGColor in
            let c = color(at: t)
            // Whole percents: the converter caches each color it shows.
            return colors.screen(CMYK(c: c.c.rounded(), m: c.m.rounded(), y: c.y.rounded(), k: c.k.rounded()))
        }
        return CGGradient(colorsSpace: shown[0].colorSpace, colors: shown as CFArray, locations: points.map { CGFloat($0) })
    }

    /// Paints the gradient over `box` (the object's outline's box, page mm) in a context already clipped by the outline.
    /// Fills an object's outline (`outline`, page mm, already turned) with the gradient, even-odd: a rotated object's
    /// gradient turns with it (it is laid over the outline before the rotation).
    func fill(_ object: CanvasObject, outline: CGPath, in cg: CGContext, colors: ColorConverter, screen: Bool) {
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.addPath(outline)
        cg.clip(using: .evenOdd)
        guard object.rotation != 0 else { return draw(in: cg, box: outline.boundingBoxOfPath, colors: colors, screen: screen) }
        let turn = object.rotationTransform
        var back = turn.inverted()
        let box = outline.copy(using: &back)?.boundingBoxOfPath ?? object.frame.standardized
        cg.concatenate(turn)
        draw(in: cg, box: box, colors: colors, screen: screen)
    }

    func draw(in cg: CGContext, box: CGRect, colors: ColorConverter, screen: Bool) {
        guard let shading = cgGradient(colors, screen: screen), !box.isNull else { return }
        let g = geometry(in: box)
        let options: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        switch kind {
        case .linear: cg.drawLinearGradient(shading, start: g.start, end: g.end, options: options)
        case .radial: cg.drawRadialGradient(shading, startCenter: g.start, startRadius: 0, endCenter: g.end, endRadius: g.radius, options: options)
        }
    }
}

/// The artboards to print, one under the other in points, with y down; each one is a page.
private final class PrintedSheets: NSView {
    let doc: Document
    /// Each page's place in this view (points) and its artboard.
    private let pages: [(rect: NSRect, artboard: Artboard)]
    /// Made once per page (the print calls `draw` more than once).
    private var bleed: [UUID: [PrintBleed.Piece]] = [:]

    init(doc: Document) {
        self.doc = doc
        let k = Printing.pointsPerMM
        var y = 0.0
        pages = doc.artboards.map { a in
            defer { y += a.size.height * k }
            return (NSRect(x: 0, y: y, width: a.size.width * k, height: a.size.height * k), a)
        }
        super.init(frame: NSRect(x: 0, y: 0, width: pages.map(\.rect.width).max() ?? 0, height: y))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // One page per artboard, the whole sheet, against the paper edge. Without this, AppKit paginates by the printer's
    // printable area and puts it in its corner (3 mm inward on the default one): the drawing comes out shifted.
    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: pages.count)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        guard pages.indices.contains(page - 1) else { return .zero }
        let rect = pages[page - 1].rect
        // A landscape artboard prints on the paper turned (the only per-page change macOS takes).
        NSPrintOperation.current?.printInfo.orientation = rect.width > rect.height ? .landscape : .portrait
        return rect
    }

    // The page's top-left corner at the paper's (the machine looks for the marks from there). The paper's origin is its
    // bottom-left corner: a page taller or shorter than the paper moves by the difference. Under 1 pt (A4 is 841.89 pt and
    // the printers' A4 841.8) it stays where it always was.
    override func locationOfPrintRect(_ rect: NSRect) -> NSPoint {
        guard let paper = NSPrintOperation.current?.printInfo.paperSize, abs(paper.height - rect.height) >= 1 else { return .zero }
        return NSPoint(x: 0, y: paper.height - rect.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let k = Printing.pointsPerMM
        for (rect, artboard) in pages where rect.intersects(dirtyRect) {
            let pieces = bleed[artboard.id] ?? PrintBleed.pieces(for: doc, on: artboard, pixelsPerMM: PrintBleed.printPixelsPerMM)
            bleed[artboard.id] = pieces
            cg.saveGState()
            // Only this artboard's art on its page (with a single artboard the page is the whole print, as it always was).
            if pages.count > 1 { cg.clip(to: rect) }
            // The artboard's top-left corner at the page's.
            cg.translateBy(x: rect.minX - artboard.rect.minX * k, y: rect.minY - artboard.rect.minY * k)
            Printing.render(doc, in: cg, sheets: [doc.sheetFrame(artboard)], bleed: pieces)
            cg.restoreGState()
        }
    }
}
