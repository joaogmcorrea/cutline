// Import PDF and AI (Illustrator saved "PDF compatible"): the vector paths of the 1st page become
// objects, at the same position on the page, with the common painting rule (Model/VectorImport.swift); the file's
// CMYK colors go in as they are. The text comes in as paths, from the fonts embedded in the PDF (Model/PDFText.swift,
// Model/PDFFonts.swift), and the images as image objects (Model/PDFImages.swift); what can't be read is counted and
// reported. Read with CGPDFScanner (the page content's operators).
// Cutline has no clipping masks and paints every fill even-odd (like Silhouette Studio), so the import bakes both into
// the geometry (Model/ImportClipping.swift): what a clipping path (W/W* n, a form's /BBox) hides is cut away from the
// paths, and a nonzero fill (f, B) whose overlaps even-odd would paint as holes becomes its outline.
import CoreGraphics
import Foundation

nonisolated enum PDFImport {
    static func read(_ payload: Data) throws -> VectorImport {
        guard let provider = CGDataProvider(data: payload as CFData), let pdf = CGPDFDocument(provider), let page = pdf.page(at: 1)
        else { throw VectorImporter.Failure.pdf }
        let box = page.getBoxRect(.cropBox)
        let reader = Reader(box: box)
        let content = CGPDFContentStreamCreateWithPage(page)
        reader.read(content)
        reader.flushText()
        return VectorImport(objects: reader.objects, texts: reader.texts, images: reader.images, imageData: reader.imageData,
                            textObjects: reader.textObjects)
    }

    /// Interpreter state (CGPDFScanner calls C functions; the state goes through the `info` pointer).
    nonisolated final class Reader {
        static let mm = 25.4 / 72

        struct ConnectionState {
            var ctm = CGAffineTransform.identity
            var strokeColor: CMYK? = CMYK(c: 0, m: 0, y: 0, k: 100)
            var fill: CMYK? = CMYK(c: 0, m: 0, y: 0, k: 100)
            var strokeWidth = 1.0
            /// What the clipping paths leave visible, in page mm; nil = nothing clipped.
            var clip: ImportClipping.Region?
            /// The text state (Model/PDFText.swift); the font is nil when its glyphs can't be had.
            var font: PDFFont?
            var fontSize = 0.0
            var charSpacing = 0.0
            var wordSpacing = 0.0
            var horizontalScale = 1.0
            var leading = 0.0
            var rise = 0.0
            var renderMode = 0
            /// The ExtGState's ca and CA: text and images painted fully transparent stay out (Chrome writes outlined
            /// text as a transparent text with the outline on top).
            var fillAlpha = 1.0
            var strokeAlpha = 1.0
        }

        var state = ConnectionState()
        var stack: [ConnectionState] = []
        var shapePath = CGMutablePath()
        /// W or W* seen: the current path also clips, from the next painting operator on (usually n).
        var pendingClip: CGPathFillRule?
        var objects: [CanvasObject] = []
        /// Texts and images left out (unreadable font or image).
        var texts = 0
        var images = 0
        var contents: [CGPDFContentStreamRef] = []
        // Text (Model/PDFText.swift): the text object, the letters waiting to become an object, the fonts read and the
        // Type 3 glyph being run.
        var text = TextObject()
        var run: TextRun?
        var fonts: [CGPDFDictionaryRef: PDFFont?] = [:]
        var glyph: GlyphCapture?
        var textObjects = 0
        // Images (Model/PDFImages.swift): the data by key, and each image XObject's key (an image drawn many times is
        // stored once).
        var imageData: [String: Data] = [:]
        var imageKeys: [CGPDFStreamRef: PDFImages.Placed] = [:]
        let toPage: CGAffineTransform
        private var depth = 0

        init(box: CGRect) {
            // PDF space (pt, y up) → page mm with y down.
            toPage = CGAffineTransform(translationX: -box.minX, y: -box.maxY)
                .concatenating(CGAffineTransform(scaleX: Self.mm, y: -Self.mm))
        }

        func read(_ content: CGPDFContentStreamRef) {
            guard depth < 12, let table = CGPDFOperatorTableCreate() else { return }
            depth += 1
            defer { depth -= 1 }
            Self.registrar(table)
            contents.append(content)
            let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(self).toOpaque())
            CGPDFScannerScan(scanner)
            CGPDFScannerRelease(scanner)
            contents.removeLast()
            CGPDFOperatorTableRelease(table)
        }

        // MARK: Painting

        /// A painting operator (n paints nothing). `evenOdd`: the fill's rule (f*, B*, b*); the others are nonzero.
        func paintPath(strokeColor: Bool, fill: Bool, evenOdd: Bool = false, close: Bool = false) {
            if close { shapePath.closeSubpath() }
            defer {
                shapePath = CGMutablePath()
                pendingClip = nil
            }
            guard !shapePath.isEmpty, let page = shapePath.copy(using: [state.ctm.concatenating(toPage)]) else { return }
            if strokeColor || fill, ignoresColor {
                // Inside an uncolored Type 3 glyph: the shape is part of the letter.
                capture(page, stroke: strokeColor, fill: fill, evenOdd: evenOdd)
            } else if strokeColor || fill {
                flushText()
                // Width at the page's scale (pt).
                let scale = sqrt(abs(state.ctm.a * state.ctm.d - state.ctm.b * state.ctm.c))
                objects += ImportClipping.objects(page, strokeColor: strokeColor ? state.strokeColor : nil,
                                                  strokeWidth: state.strokeWidth * scale, fill: fill ? state.fill : nil,
                                                  evenOdd: evenOdd, clip: state.clip)
            }
            // The painting above still used the old clip (PDF: W/W* take effect after the painting operator).
            if let rule = pendingClip { clip(to: page, rule: rule) }
        }

        /// W/W*: from now on only what's inside both the current clip and this path (with its rule) shows.
        func clip(to page: CGPath, rule: CGPathFillRule) {
            state.clip = ImportClipping.clip(state.clip, to: page, rule: rule)
        }

        // MARK: Operators

        private static func registrar(_ t: CGPDFOperatorTableRef) {
            CGPDFOperatorTableSetCallback(t, "q") { _, info in
                guard let l = reader(info) else { return }
                l.stack.append(l.state)
            }
            CGPDFOperatorTableSetCallback(t, "Q") { _, info in
                guard let l = reader(info), let previous = l.stack.popLast() else { return }
                l.state = previous
            }
            CGPDFOperatorTableSetCallback(t, "cm") { s, info in
                guard let l = reader(info), let v = numbers(s, 6) else { return }
                l.state.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(l.state.ctm)
            }
            CGPDFOperatorTableSetCallback(t, "w") { s, info in
                guard let l = reader(info), let v = numbers(s, 1) else { return }
                l.state.strokeWidth = v[0]
            }
            CGPDFOperatorTableSetCallback(t, "m") { s, info in
                guard let l = reader(info), let v = numbers(s, 2) else { return }
                l.shapePath.move(to: CGPoint(x: v[0], y: v[1]))
            }
            CGPDFOperatorTableSetCallback(t, "l") { s, info in
                guard let l = reader(info), let v = numbers(s, 2), !l.shapePath.isEmpty else { return }
                l.shapePath.addLine(to: CGPoint(x: v[0], y: v[1]))
            }
            CGPDFOperatorTableSetCallback(t, "c") { s, info in
                guard let l = reader(info), let v = numbers(s, 6), !l.shapePath.isEmpty else { return }
                l.shapePath.addCurve(to: CGPoint(x: v[4], y: v[5]), control1: CGPoint(x: v[0], y: v[1]), control2: CGPoint(x: v[2], y: v[3]))
            }
            CGPDFOperatorTableSetCallback(t, "v") { s, info in
                guard let l = reader(info), let v = numbers(s, 4), !l.shapePath.isEmpty else { return }
                l.shapePath.addCurve(to: CGPoint(x: v[2], y: v[3]), control1: l.shapePath.currentPoint, control2: CGPoint(x: v[0], y: v[1]))
            }
            CGPDFOperatorTableSetCallback(t, "y") { s, info in
                guard let l = reader(info), let v = numbers(s, 4), !l.shapePath.isEmpty else { return }
                let end = CGPoint(x: v[2], y: v[3])
                l.shapePath.addCurve(to: end, control1: CGPoint(x: v[0], y: v[1]), control2: end)
            }
            CGPDFOperatorTableSetCallback(t, "h") { _, info in reader(info)?.shapePath.closeSubpath() }
            CGPDFOperatorTableSetCallback(t, "re") { s, info in
                guard let l = reader(info), let v = numbers(s, 4) else { return }
                l.shapePath.addRect(CGRect(x: v[0], y: v[1], width: v[2], height: v[3]))
            }
            // Painting.
            CGPDFOperatorTableSetCallback(t, "S") { _, info in reader(info)?.paintPath(strokeColor: true, fill: false) }
            CGPDFOperatorTableSetCallback(t, "s") { _, info in reader(info)?.paintPath(strokeColor: true, fill: false, close: true) }
            for op in ["f", "F"] {
                CGPDFOperatorTableSetCallback(t, op) { _, info in reader(info)?.paintPath(strokeColor: false, fill: true) }
            }
            CGPDFOperatorTableSetCallback(t, "f*") { _, info in reader(info)?.paintPath(strokeColor: false, fill: true, evenOdd: true) }
            CGPDFOperatorTableSetCallback(t, "B") { _, info in reader(info)?.paintPath(strokeColor: true, fill: true) }
            CGPDFOperatorTableSetCallback(t, "B*") { _, info in reader(info)?.paintPath(strokeColor: true, fill: true, evenOdd: true) }
            CGPDFOperatorTableSetCallback(t, "b") { _, info in reader(info)?.paintPath(strokeColor: true, fill: true, close: true) }
            CGPDFOperatorTableSetCallback(t, "b*") { _, info in
                reader(info)?.paintPath(strokeColor: true, fill: true, evenOdd: true, close: true)
            }
            // Clipping: W/W* mark the path, the painting operator after them (usually n, which paints nothing) applies it.
            CGPDFOperatorTableSetCallback(t, "W") { _, info in reader(info)?.pendingClip = .winding }
            CGPDFOperatorTableSetCallback(t, "W*") { _, info in reader(info)?.pendingClip = .evenOdd }
            CGPDFOperatorTableSetCallback(t, "n") { _, info in reader(info)?.paintPath(strokeColor: false, fill: false) }
            // Colors (inside an uncolored Type 3 glyph they don't count: the letter takes the text's).
            CGPDFOperatorTableSetCallback(t, "G") { s, info in painter(info)?.state.strokeColor = numbers(s, 1).flatMap(color) }
            CGPDFOperatorTableSetCallback(t, "g") { s, info in painter(info)?.state.fill = numbers(s, 1).flatMap(color) }
            CGPDFOperatorTableSetCallback(t, "RG") { s, info in painter(info)?.state.strokeColor = numbers(s, 3).flatMap(color) }
            CGPDFOperatorTableSetCallback(t, "rg") { s, info in painter(info)?.state.fill = numbers(s, 3).flatMap(color) }
            CGPDFOperatorTableSetCallback(t, "K") { s, info in painter(info)?.state.strokeColor = numbers(s, 4).flatMap(color) }
            CGPDFOperatorTableSetCallback(t, "k") { s, info in painter(info)?.state.fill = numbers(s, 4).flatMap(color) }
            for op in ["SC", "SCN"] {
                CGPDFOperatorTableSetCallback(t, op) { s, info in
                    guard let l = painter(info) else { return }
                    if let c = color(allNumbers(s)) { l.state.strokeColor = c }
                }
            }
            for op in ["sc", "scn"] {
                CGPDFOperatorTableSetCallback(t, op) { s, info in
                    guard let l = painter(info) else { return }
                    if let c = color(allNumbers(s)) { l.state.fill = c }
                }
            }
            // The graphics state's transparency (ca, CA), for text and images.
            CGPDFOperatorTableSetCallback(t, "gs") { s, info in
                guard let l = reader(info), let content = l.contents.last else { return }
                var name: UnsafePointer<CChar>?
                guard CGPDFScannerPopName(s, &name), let name,
                      let parameters = PDFDict(CGPDFContentStreamGetResource(content, "ExtGState", name)) else { return }
                if let alpha = parameters.number("ca") { l.state.fillAlpha = alpha }
                if let alpha = parameters.number("CA") { l.state.strokeAlpha = alpha }
            }
            // Text (Model/PDFText.swift).
            registerText(t)
            // An inline image (BI … ID … EI): CGPDFScanner hands it over at EI, as a stream.
            CGPDFOperatorTableSetCallback(t, "EI") { s, info in
                var stream: CGPDFStreamRef?
                guard let l = reader(info) else { return }
                guard CGPDFScannerPopStream(s, &stream), let stream else { return l.images += 1 }
                l.paintImage(PDFStream(stream, inline: true))
            }
            // XObject: form (nested content, common in Illustrator) or image.
            CGPDFOperatorTableSetCallback(t, "Do") { s, info in
                guard let l = reader(info), let content = l.contents.last else { return }
                var name: UnsafePointer<CChar>?
                guard CGPDFScannerPopName(s, &name), let name,
                      let object = CGPDFContentStreamGetResource(content, "XObject", name) else { return }
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream) else { return }
                var subtype: UnsafePointer<CChar>?
                guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }
                switch String(cString: subtype) {
                case "Image":
                    l.paintImage(PDFStream(stream))
                case "Form":
                    let previous = l.state
                    var matrix: CGPDFArrayRef?
                    if CGPDFDictionaryGetArray(dictionary, "Matrix", &matrix), let matrix, CGPDFArrayGetCount(matrix) == 6 {
                        var m = [CGFloat](repeating: 0, count: 6)
                        for i in 0..<6 { var x: CGPDFReal = 0; CGPDFArrayGetNumber(matrix, i, &x); m[i] = x }
                        l.state.ctm = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]).concatenating(l.state.ctm)
                    }
                    // The form's box clips what it draws.
                    var bbox: CGPDFArrayRef?
                    if CGPDFDictionaryGetArray(dictionary, "BBox", &bbox), let bbox, CGPDFArrayGetCount(bbox) == 4 {
                        var b = [CGFloat](repeating: 0, count: 4)
                        for i in 0..<4 { var x: CGPDFReal = 0; CGPDFArrayGetNumber(bbox, i, &x); b[i] = x }
                        let box = CGRect(x: min(b[0], b[2]), y: min(b[1], b[3]), width: abs(b[2] - b[0]), height: abs(b[3] - b[1]))
                        l.clip(to: CGPath(rect: box, transform: [l.state.ctm.concatenating(l.toPage)]), rule: .winding)
                    }
                    var features: CGPDFDictionaryRef?
                    CGPDFDictionaryGetDictionary(dictionary, "Resources", &features)
                    let nested = CGPDFContentStreamCreateWithStream(stream, features ?? dictionary, content)
                    l.read(nested)
                    CGPDFContentStreamRelease(nested)
                    l.state = previous
                default:
                    break
                }
            }
        }
    }
}

// Free functions: CGPDFScanner's callbacks are C function pointers and can't capture anything.
private nonisolated func reader(_ info: UnsafeMutableRawPointer?) -> PDFImport.Reader? {
    info.map { Unmanaged<PDFImport.Reader>.fromOpaque($0).takeUnretainedValue() }
}

/// The reader for a color operator; nil inside an uncolored Type 3 glyph, where colors don't count.
private nonisolated func painter(_ info: UnsafeMutableRawPointer?) -> PDFImport.Reader? {
    reader(info).flatMap { $0.ignoresColor ? nil : $0 }
}

private nonisolated func numbers(_ scanner: CGPDFScannerRef, _ n: Int) -> [Double]? {
    var v = [Double](repeating: 0, count: n)
    for i in stride(from: n - 1, through: 0, by: -1) {
        var x: CGPDFReal = 0
        guard CGPDFScannerPopNumber(scanner, &x) else { return nil }
        v[i] = Double(x)
    }
    return v
}

/// All the numbers on the stack (colors with a variable number of components).
private nonisolated func allNumbers(_ scanner: CGPDFScannerRef) -> [Double] {
    var v: [Double] = []
    var x: CGPDFReal = 0
    while CGPDFScannerPopNumber(scanner, &x) { v.insert(Double(x), at: 0) }
    return v
}

private nonisolated func color(_ v: [Double]) -> CMYK? { VectorImporter.color(v) }
