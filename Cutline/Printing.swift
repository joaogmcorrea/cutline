// File › Print… (⌘P): the A4 page at actual size with what gets printed — fills, images
// and strokes with width — and, with Print & Cut, the registration marks. 0 pt strokes only mark the cut
// and are not printed. Colors go in CMYK (the system's generic CMYK profile; ColorSync converts for the printer).
import AppKit
import SwiftUI

enum Printing {
    static let pointsPerMM = 72 / 25.4

    /// The system print panel (as a sheet over the window). With `pdf`, writes straight to the file, without a panel.
    static func printDocument(_ doc: Document, in nsWindow: NSWindow?, pdf: URL? = nil) {
        let info = NSPrintInfo()
        // A4, no margins or centering: the page comes out at the same position and scale as the document.
        info.paperSize = NSSize(width: Document.page.width * pointsPerMM, height: Document.page.height * pointsPerMM)
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
        let operation = NSPrintOperation(view: PrintedSheet(doc: doc), printInfo: info)
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

    /// Draws the page in mm (y down) in a context in points.
    static func render(_ doc: Document, in cg: CGContext) {
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.scaleBy(x: pointsPerMM, y: pointsPerMM)
        for object in doc.objectsInOrder where doc.visible(object) {
            let shapePath = object.shapePath.cgPath
            if let color = object.fill {
                cg.addPath(shapePath)
                cg.setFillColor(color.cgCMYK)
                cg.fillPath(using: .evenOdd)
            }
            if let image = object.image, let cgImage = doc.image(image.key) {
                // Clipped by the outline (even-odd rule, as on the canvas).
                cg.saveGState()
                cg.addPath(shapePath)
                cg.clip(using: .evenOdd)
                cg.concatenate(image.transform.cg.concatenating(object.frameToPage))
                // Pixels with y down: flip the image back (CoreGraphics draws with y up).
                cg.translateBy(x: 0, y: CGFloat(cgImage.height))
                cg.scaleBy(x: 1, y: -1)
                cg.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
                cg.restoreGState()
            }
            if object.strokeWidth > 0 { trace(object, shapePath, in: cg) }
        }
        if doc.marks {
            cg.setFillColor(CMYK(c: 0, m: 0, y: 0, k: 100).cgCMYK)
            cg.fill(doc.marksConfig.rectangles)
        }
    }

    /// Stroke with width (pt → mm), cap, join, dashes and alignment — as on the canvas.
    private static func trace(_ object: CanvasObject, _ shapePath: CGPath, in cg: CGContext) {
        let e = object.style
        cg.saveGState()
        defer { cg.restoreGState() }
        var width = object.strokeWidth / pointsPerMM
        if e.alignment != .center {
            // Inside/outside: twice the width, clipped by the outline itself (or by its outside).
            if e.alignment == .outside { cg.addRect(CGRect(origin: .zero, size: Document.page).insetBy(dx: -50, dy: -50)) }
            cg.addPath(shapePath)
            cg.clip(using: .evenOdd)
            width *= 2
        }
        cg.setStrokeColor(object.strokeColor.cgCMYK)
        cg.setLineWidth(width)
        cg.setLineCap(e.cap.cg)
        cg.setLineJoin(e.join.cg)
        cg.setMiterLimit(e.miterLimit)
        if let defaultValue = e.line.defaultValue { cg.setLineDash(phase: 0, lengths: defaultValue.map { CGFloat($0) }) }
        cg.addPath(shapePath)
        cg.strokePath()
    }
}

extension CMYK {
    /// Color in the system's generic CMYK profile (for printing).
    var cgCMYK: CGColor {
        let space = CGColorSpace(name: CGColorSpace.genericCMYK)!
        return CGColor(colorSpace: space, components: [c / 100, m / 100, y / 100, k / 100, 1])!
    }
}

/// The page to print, paper-sized (A4 in points), with y down.
private final class PrintedSheet: NSView {
    let doc: Document

    init(doc: Document) {
        self.doc = doc
        super.init(frame: NSRect(x: 0, y: 0, width: Document.page.width * Printing.pointsPerMM,
                                 height: Document.page.height * Printing.pointsPerMM))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // One page, the whole sheet, against the paper edge. Without this, AppKit paginates by the printer's
    // printable area and puts it in its corner (3 mm inward on the default one): the drawing comes out shifted.
    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: 1)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect { bounds }

    override func locationOfPrintRect(_ rect: NSRect) -> NSPoint { .zero }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        Printing.render(doc, in: cg)
    }
}
