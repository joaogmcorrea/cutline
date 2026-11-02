// Import PDF and AI (Illustrator saved "PDF compatible"): the vector paths of the 1st page become
// objects, at the same position on the page, with the common painting rule (Model/VectorImport.swift); the file's
// CMYK colors go in as they are. The PDF's texts and images don't go in (count and report them). Read with
// CGPDFScanner (the page content's operators).
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
        return VectorImport(objects: reader.objects, texts: reader.texts, images: reader.images)
    }

    /// Interpreter state (CGPDFScanner calls C functions; the state goes through the `info` pointer).
    nonisolated final class Reader {
        static let mm = 25.4 / 72

        struct ConnectionState {
            var ctm = CGAffineTransform.identity
            var strokeColor: CMYK? = CMYK(c: 0, m: 0, y: 0, k: 100)
            var fill: CMYK? = CMYK(c: 0, m: 0, y: 0, k: 100)
            var strokeWidth = 1.0
        }

        var state = ConnectionState()
        var stack: [ConnectionState] = []
        var shapePath = CGMutablePath()
        var objects: [CanvasObject] = []
        var texts = 0
        var images = 0
        var contents: [CGPDFContentStreamRef] = []
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

        func paintPath(strokeColor: Bool, fill: Bool, close: Bool = false) {
            if close { shapePath.closeSubpath() }
            defer { shapePath = CGMutablePath() }
            guard !shapePath.isEmpty, strokeColor || fill else { return }
            let t = state.ctm.concatenating(toPage)
            guard let page = shapePath.copy(using: [t]) else { return }
            // Width at the page's scale (pt).
            let scale = sqrt(abs(state.ctm.a * state.ctm.d - state.ctm.b * state.ctm.c))
            if let object = VectorImporter.object(page, strokeColor: strokeColor ? state.strokeColor : nil, strokeWidth: state.strokeWidth * scale,
                                                 fill: fill ? state.fill : nil) {
                objects.append(object)
            }
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
            for op in ["f", "F", "f*"] {
                CGPDFOperatorTableSetCallback(t, op) { _, info in reader(info)?.paintPath(strokeColor: false, fill: true) }
            }
            for op in ["B", "B*"] {
                CGPDFOperatorTableSetCallback(t, op) { _, info in reader(info)?.paintPath(strokeColor: true, fill: true) }
            }
            for op in ["b", "b*"] {
                CGPDFOperatorTableSetCallback(t, op) { _, info in reader(info)?.paintPath(strokeColor: true, fill: true, close: true) }
            }
            // Clipping (W/W* + n) and a path without painting: discarded.
            CGPDFOperatorTableSetCallback(t, "n") { _, info in reader(info)?.shapePath = CGMutablePath() }
            // Colors.
            CGPDFOperatorTableSetCallback(t, "G") { s, info in reader(info)?.state.strokeColor = numbers(s, 1).flatMap(color) }
            CGPDFOperatorTableSetCallback(t, "g") { s, info in reader(info)?.state.fill = numbers(s, 1).flatMap(color) }
            CGPDFOperatorTableSetCallback(t, "RG") { s, info in reader(info)?.state.strokeColor = numbers(s, 3).flatMap(color) }
            CGPDFOperatorTableSetCallback(t, "rg") { s, info in reader(info)?.state.fill = numbers(s, 3).flatMap(color) }
            CGPDFOperatorTableSetCallback(t, "K") { s, info in reader(info)?.state.strokeColor = numbers(s, 4).flatMap(color) }
            CGPDFOperatorTableSetCallback(t, "k") { s, info in reader(info)?.state.fill = numbers(s, 4).flatMap(color) }
            for op in ["SC", "SCN"] {
                CGPDFOperatorTableSetCallback(t, op) { s, info in
                    guard let l = reader(info) else { return }
                    if let c = color(allNumbers(s)) { l.state.strokeColor = c }
                }
            }
            for op in ["sc", "scn"] {
                CGPDFOperatorTableSetCallback(t, op) { s, info in
                    guard let l = reader(info) else { return }
                    if let c = color(allNumbers(s)) { l.state.fill = c }
                }
            }
            // Text and images: only counted.
            for op in ["Tj", "TJ", "'", "\""] {
                CGPDFOperatorTableSetCallback(t, op) { _, info in reader(info)?.texts += 1 }
            }
            CGPDFOperatorTableSetCallback(t, "BI") { _, info in reader(info)?.images += 1 }
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
                    l.images += 1
                case "Form":
                    let previous = l.state
                    var matrix: CGPDFArrayRef?
                    if CGPDFDictionaryGetArray(dictionary, "Matrix", &matrix), let matrix, CGPDFArrayGetCount(matrix) == 6 {
                        var m = [CGFloat](repeating: 0, count: 6)
                        for i in 0..<6 { var x: CGPDFReal = 0; CGPDFArrayGetNumber(matrix, i, &x); m[i] = x }
                        l.state.ctm = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]).concatenating(l.state.ctm)
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
