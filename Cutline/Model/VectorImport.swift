// Import vector files (File › Import…): PDF, AI, SVG and EPS become free paths in the active layer.
// The format is recognized by the content, not the extension (the modern .ai is a PDF; the old one, PostScript).
// The painting rule is the same for all four: stroke → cut color (thin strokes, up to 0.5 pt, become 0 pt: cut
// only); fill only → printed color, no cut; texts and images don't go in (they're counted for the notice).
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

    /// Reads any of the formats (by the content).
    static func read(_ payload: Data) throws -> VectorImport {
        switch format(payload) {
        case .pdf:
            let result = try PDFImport.read(payload)
            // AI saved without "PDF compatible": the page only has Illustrator's message (text, no drawing or image).
            if result.objects.isEmpty, result.images == 0, result.texts > 0,
               payload.range(of: Data("AIPrivateData".utf8)) != nil { throw Failure.aiWithoutPDF }
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

    /// Color with 1 (gray, 1 = white), 3 (RGB) or 4 (CMYK) components from 0 to 1.
    static func color(_ v: [Double]) -> CMYK? {
        let limit = { (x: Double) in min(max(x, 0), 1) }
        switch v.count {
        case 1: return CMYK(c: 0, m: 0, y: 0, k: ((1 - limit(v[0])) * 100).rounded())
        case 3: return CMYK(red: v[0], green: v[1], blue: v[2])
        case 4:
            return CMYK(c: (limit(v[0]) * 100).rounded(), m: (limit(v[1]) * 100).rounded(),
                        y: (limit(v[2]) * 100).rounded(), k: (limit(v[3]) * 100).rounded())
        default: return nil
        }
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
