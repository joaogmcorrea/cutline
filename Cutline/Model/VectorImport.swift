// Import vector files (File › Import…): PDF, AI, SVG and EPS become free paths in the active layer.
// The format is recognized by the content, not the extension (the modern .ai is a PDF; the old one, PostScript).
// The painting rule is the same for all four: stroke → cut color (thin strokes, up to 0.5 pt, become 0 pt: cut
// only); fill only → printed color, no cut. A PDF's text comes in as paths and its images as image objects; SVG and
// EPS text and images don't go in (they're counted for the notice), nor what a PDF has that can't be read.
// Readers: Model/PDFImport.swift, Model/SVGImport.swift and Model/EPSImport.swift.
import Compression
import CoreGraphics
import Foundation

/// What a vector file brought.
nonisolated struct VectorImport {
    var objects: [CanvasObject] = []
    /// Texts and images found and left out.
    var texts = 0
    var images = 0
    /// The data of the image objects' images, by key (`Document.images`).
    var imageData: [String: Data] = [:]
    /// How many of the objects are letters (text that came in as paths).
    var textObjects = 0
}

extension VectorImport {
    /// The notice after the import: "Imported from “x.pdf”: 12 paths · 3 images · 2 images not imported." `lead` takes the
    /// place of the counts (a flattened or simplified file says what went in). `fromCanva`: Canva has no outlines to
    /// convert the text to, so the notice doesn't send the person to Illustrator.
    func notice(from name: String, lead: [String]? = nil, fromCanva: Bool = false) -> String {
        var parts: [String] = []
        if texts > 0 {
            parts.append(fromCanva ? String(localized: "text not imported")
                         : String(localized: "text not imported (convert it to outlines in Illustrator)"))
        }
        if images > 0 { parts.append(String(localized: "\(images) images not imported")) }
        if objects.isEmpty {
            return parts.isEmpty ? String(localized: "No paths to import in “\(name)”.")
                : String(localized: "No paths to import in “\(name)”: \(parts.joined(separator: " · ")).")
        }
        let pictures = objects.count { $0.image != nil }
        var counts = pictures < objects.count ? [String(localized: "\(objects.count - pictures) paths")] : []
        if pictures > 0 { counts.append(String(localized: "\(pictures) images")) }
        parts.insert(contentsOf: lead ?? counts, at: 0)
        return String(localized: "Imported from “\(name)”: \(parts.joined(separator: " · ")).")
    }
}

nonisolated enum VectorImporter {
    nonisolated enum Format {
        case pdf, postscript, svg
    }

    nonisolated enum Failure: LocalizedError {
        case unknownValue, pdf, aiWithoutPDF, svg, postscript

        var errorDescription: String? {
            switch self {
            case .unknownValue: String(localized: "The file isn’t a PDF, AI, SVG or EPS that Cutline can read.")
            case .pdf: String(localized: "The file couldn’t be opened as a PDF.")
            case .aiWithoutPDF:
                String(localized: "This Illustrator file was saved without PDF content. In Illustrator, save it again with “Create PDF Compatible File” turned on.")
            case .svg: String(localized: "The SVG couldn’t be read: the file seems incomplete or damaged.")
            case .postscript: String(localized: "The EPS couldn’t be read.")
            }
        }
    }

    /// The conversion of the document the file goes into (its RGB working space → its CMYK profile), bound by
    /// `read(_:colors:)` while the readers run (they reach it through `color(_:)` and `rgb(_:_:_:)`).
    @TaskLocal static var colors: ColorConverter?

    /// The artboard the file goes on (canvas mm), bound by `read(_:colors:sheet:)`: an EPS goes in its center.
    @TaskLocal static var sheet = CGRect(origin: .zero, size: PagePreset.a4.size)

    /// Reads any of the formats (by the content). The file's RGB colors become CMYK with `colors`. The file's page goes on
    /// `sheet` (the active artboard): its top-left corner at the artboard's.
    static func read(_ payload: Data, colors: ColorConverter, sheet: CGRect = CGRect(origin: .zero, size: PagePreset.a4.size)) throws -> VectorImport {
        var result = try $colors.withValue(colors) { try $sheet.withValue(sheet) { try read(payload) } }
        if sheet.origin != .zero {
            result.objects = result.objects.map { o in
                var o = o
                o.frame = o.frame.offsetBy(dx: sheet.minX, dy: sheet.minY)
                return o
            }
        }
        return result
    }

    private static func read(_ payload: Data) throws -> VectorImport {
        switch format(payload) {
        case .pdf:
            let result = try PDFImport.read(payload)
            // AI saved without "PDF compatible": the page only has Illustrator's message (text, no drawing or image).
            if result.objects.count == result.textObjects, result.images == 0, result.imageData.isEmpty,
               result.texts + result.textObjects > 0, payload.range(of: Data("AIPrivateData".utf8)) != nil { throw Failure.aiWithoutPDF }
            return result
        case .postscript:
            return try EPSImport.read(payload)
        case .svg:
            return try SVGImport.read(gunzip(payload) ?? payload)
        case nil:
            throw Failure.unknownValue
        }
    }

    /// PDF (also the modern .ai), PostScript (EPS and the old .ai) or SVG (also .svgz); nil = something else
    /// (an image, for example).
    static func format(_ payload: Data) -> Format? {
        let start = payload.prefix(1024)
        if start.starts(with: [0xC5, 0xD0, 0xD3, 0xC6]) || start.starts(with: Array("%!".utf8)) { return .postscript }
        // The PDF header can come after some junk, up to byte 1024.
        if start.range(of: Data("%PDF-".utf8)) != nil { return .pdf }
        if start.starts(with: [0x1F, 0x8B]) {
            return gunzip(payload).flatMap { format($0) == .svg ? .svg : nil }
        }
        let text = String(decoding: payload.prefix(8192), as: UTF8.self)
        if text.drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" }).hasPrefix("<"), text.contains("<svg") { return .svg }
        return nil
    }

    /// Object with an outline in page mm. `strokeWidth` in pt, already at the page's scale.
    static func object(_ shapePath: CGPath, strokeColor: CMYK?, strokeWidth: Double, fill: CMYK?) -> CanvasObject? {
        guard strokeColor != nil || fill != nil, let free = CanvasObject.freePath(shapePath) else { return nil }
        var object = CanvasObject(shape: .shapePath(free.subpaths), frame: free.frame)
        if let strokeColor {
            object.strokeColor = strokeColor
            object.strokeWidth = strokeWidth <= 0.5 ? 0 : (strokeWidth * 100).rounded() / 100
        } else {
            object.cutsLine = false
        }
        object.fill = fill
        return object
    }

    /// Color with 1 (gray, 1 = white: black ink only), 3 (RGB, through the profiles) or 4 (CMYK, the numbers as they
    /// are) components from 0 to 1.
    static func color(_ v: [Double]) -> CMYK? {
        let limit = { (x: Double) in min(max(x, 0), 1) }
        switch v.count {
        case 1: return CMYK(c: 0, m: 0, y: 0, k: ((1 - limit(v[0])) * 100).rounded())
        case 3: return rgb(v[0], v[1], v[2])
        case 4:
            return CMYK(c: (limit(v[0]) * 100).rounded(), m: (limit(v[1]) * 100).rounded(),
                        y: (limit(v[2]) * 100).rounded(), k: (limit(v[3]) * 100).rounded())
        default: return nil
        }
    }

    /// An RGB color of the file (0–1) in the document's CMYK.
    static func rgb(_ r: Double, _ g: Double, _ b: Double) -> CMYK {
        (colors ?? ColorSettings.shared.converter()).cmyk(red: r, green: g, blue: b)
    }

    /// Content of a gzip file (the .svgz); nil if it isn't gzip.
    static func gunzip(_ payload: Data) -> Data? {
        let b = [UInt8](payload)
        guard b.count > 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 4 != 0, i + 2 <= b.count { i += 2 + Int(b[i]) + Int(b[i + 1]) << 8 }
        if flags & 8 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 16 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 2 != 0 { i += 2 }
        guard i < b.count - 8 else { return nil }
        let n = b.count
        let size = Int(b[n - 4]) | Int(b[n - 3]) << 8 | Int(b[n - 2]) << 16 | Int(b[n - 1]) << 24
        guard size > 0, size < 512 << 20 else { return nil }
        var output = [UInt8](repeating: 0, count: size)
        let readOnes = b[i..<(n - 8)].withUnsafeBufferPointer { input in
            output.withUnsafeMutableBufferPointer { destination in
                // COMPRESSION_ZLIB is raw deflate (without the zlib header), which is what gzip carries.
                compression_decode_buffer(destination.baseAddress!, size, input.baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        return readOnes > 0 ? Data(output.prefix(readOnes)) : nil
    }
}
