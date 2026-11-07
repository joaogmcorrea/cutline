// Import EPS (and the old .ai, which is PostScript): macOS 26 no longer interprets PostScript (CGPSConverter
// returns nothing, NSEPSImageRep doesn't open, there is no pstopdf), so Cutline has a mini interpreter of its own.
// Painted paths become objects with the common painting rule (Model/VectorImport.swift); EPS has no
// page, so the artwork (the %%BoundingBox) goes in the center of the artboard (an A4 by default). Three dialects:
// - Modern Illustrator (Adobe_AGM_Core prolog, version 9 onward): the prolog is skipped and only the page runs,
//   with the AGM shortcuts (mo li cv cp f ef @ clp ct cmyk rgb sep…) defined here. A gradient (shfill) becomes the
//   clipping outline with the average color.
// - Classic Illustrator (up to version 8, "Illustrator 3" etc.): the body after %%EndSetup runs with the
//   AI format's operators (m L C f S B, k K x X, *u … *U for compound paths).
// - Any other program: the whole file runs in the interpreter.
// Texts and images don't go in (counted). An error in one command doesn't bring down the rest; there is an operation limit.
// Cutline has no clipping masks and paints every fill even-odd, so the clip (clip, eoclip, rectclip; clp/eclp/nclp in
// AGM; W in classic AI) and the nonzero rule of fill (eofill, ef and XR 1 are even-odd) are baked into the geometry
// (Model/ImportClipping.swift). A clip made of text (charpath, which isn't read) clips nothing.
import CoreGraphics
import Foundation

nonisolated enum EPSImport {
    nonisolated enum Dialect {
        case agm, classic, generic
    }

    static func read(_ payload: Data) throws -> VectorImport {
        var b = [UInt8](payload)
        // EPS with a binary header (TIFF/WMF preview): the PostScript is at the offset and size in bytes 4–11.
        if b.starts(with: [0xC5, 0xD0, 0xD3, 0xC6]), b.count >= 12 {
            let start = le32(b, 4), size = le32(b, 8)
            guard start < b.count, size > 0 else { throw VectorImporter.Failure.postscript }
            b = Array(b[start..<min(start + size, b.count)])
        }
        guard b.starts(with: Array("%!".utf8)) else { throw VectorImporter.Failure.postscript }
        let dialect: Dialect = discover(b, "Adobe_AGM_Core") != nil ? .agm
            : (discover(b, "procset Adobe_Illustrator") != nil || discover(b, "%AI5_") != nil || discover(b, "%AI3_") != nil) ? .classic
            : .generic
        let (start, end) = run(b, dialect)
        let interpreter = Interpreter(font: FontChoice(b, start: start, end: end), dialect: dialect)
        interpreter.rotate()

        // Artwork box (pt, y up): the header's or the drawings'.
        // Math with absurd numbers can give infinity: those drawings are left out.
        let paints = interpreter.paints.filter { p in
            let c = p.shapePath.boundingBoxOfPath
            return c.minX.isFinite && c.minY.isFinite && c.width.isFinite && c.height.isFinite
        }
        var box = headerBox(b)
        if box == nil || box!.width <= 0 || box!.height <= 0 {
            box = paints.reduce(CGRect.null) { $0.union($1.shapePath.boundingBoxOfPath) }
        }
        var result = VectorImport(texts: interpreter.texts, images: interpreter.images + interpreter.font.skippedImages)
        guard let box, !box.isNull, !box.isInfinite else { return result }
        let mm = 25.4 / 72
        let sheet = VectorImporter.sheet.size
        let dx = (sheet.width - box.width * mm) / 2, dy = (sheet.height - box.height * mm) / 2
        let toPage = CGAffineTransform(translationX: -box.minX, y: -box.maxY)
            .concatenating(CGAffineTransform(scaleX: mm, y: -mm))
            .concatenating(CGAffineTransform(translationX: dx, y: dy))
        result.objects = paints.flatMap { p -> [CanvasObject] in
            guard let page = p.shapePath.copy(using: [toPage]) else { return [] }
            return ImportClipping.objects(page, strokeColor: p.strokeColor, strokeWidth: p.strokeWidth, fill: p.fill,
                                          evenOdd: p.evenOdd, clip: p.clip?.applying(toPage))
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["CUTLINE_TEST_EPS"] != nil {
            print("EPS \(dialect): \(paints.count) paints, \(interpreter.errors) errors, unknown:",
                  interpreter.unknownOnes.sorted { $0.value > $1.value }.prefix(30).map { "\($0.key)×\($0.value)" })
        }
        #endif
        return result
    }

    static func le32(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24
    }

    /// Position of `text` in `b` from `since` (nil if there is none).
    static func discover(_ b: [UInt8], _ text: String, since: Int = 0, until: Int? = nil) -> Int? {
        let needle = Array(text.utf8), end = min(until ?? b.count, b.count)
        guard since < end, needle.count <= end - since else { return nil }
        return b.withUnsafeBufferPointer { p -> Int? in
            needle.withUnsafeBufferPointer { a -> Int? in
                guard let didFind = memmem(p.baseAddress! + since, end - since, a.baseAddress!, a.count) else { return nil }
                return p.baseAddress!.distance(to: didFind.assumingMemoryBound(to: UInt8.self))
            }
        }
    }

    /// DSC comment at the start of a line.
    static func line(_ b: [UInt8], _ mark: String, since: Int = 0) -> Int? {
        var i = since
        while let didFind = discover(b, mark, since: i) {
            if didFind == 0 || b[didFind - 1] == 10 || b[didFind - 1] == 13 { return didFind }
            i = didFind + 1
        }
        return nil
    }

    static func afterLine(_ b: [UInt8], _ i: Int) -> Int {
        var j = i
        while j < b.count, b[j] != 10, b[j] != 13 { j += 1 }
        return j
    }

    /// Part of the file that runs: in Illustrator, only the page (its prologs are huge and not needed).
    static func run(_ b: [UInt8], _ dialect: Dialect) -> (Int, Int) {
        let marks: [String] = switch dialect {
        case .agm: ["%%EndPageSetup", "%%EndSetup", "%%EndProlog"]
        case .classic: ["%%EndSetup", "%%EndProlog"]
        case .generic: []
        }
        var start = 0
        for mark in marks {
            if let i = line(b, mark) { start = afterLine(b, i); break }
        }
        var end = b.count
        if dialect != .generic {
            for mark in ["%%PageTrailer", "%%Trailer", "%%EOF"] {
                if let i = line(b, mark, since: start) { end = i; break }
            }
        }
        return (start, end)
    }

    /// %%HiResBoundingBox or %%BoundingBox (also at the end of the file, with "(atend)").
    static func headerBox(_ b: [UInt8]) -> CGRect? {
        for mark in ["%%HiResBoundingBox:", "%%BoundingBox:"] {
            var i = 0
            while let didFind = line(b, mark, since: i) {
                let end = afterLine(b, didFind)
                let text = String(decoding: b[(didFind + mark.utf8.count)..<end], as: UTF8.self)
                let v = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Double($0) }
                if v.count == 4, v[2] > v[0], v[3] > v[1] { return CGRect(x: v[0], y: v[1], width: v[2] - v[0], height: v[3] - v[1]) }
                i = end
            }
        }
        return nil
    }

    /// A painted path, in pt (PostScript's default space, y up).
    nonisolated struct Paint {
        var shapePath: CGPath
        var strokeColor: CMYK?
        /// In pt.
        var strokeWidth: Double
        var fill: CMYK?
        /// The fill's rule (eofill); the others are nonzero.
        var evenOdd = false
        /// What the clip left visible when it was painted, in pt; nil = nothing clipped.
        var clip: ImportClipping.Region?
    }
}

// MARK: - Values

extension EPSImport {
    nonisolated final class Chain {
        var b: [UInt8]
        init(_ b: [UInt8]) { self.b = b }
        var text: String { String(decoding: b, as: UTF8.self) }
    }

    nonisolated final class PSArray {
        var v: [Value]
        init(_ v: [Value]) { self.v = v }
    }

    nonisolated final class PSDictionary {
        var d: [String: (key: Value, value: Value)] = [:]

        subscript(_ name: String) -> Value? {
            get { d[name]?.value }
            set { d[name] = newValue.map { (key: Value.name(name, executable: false), value: $0) } }
        }
    }

    nonisolated indirect enum Value {
        case int(Int), real(Double), bool(Bool), null, mark
        case name(String, executable: Bool)
        case text(Chain, executable: Bool)
        case list(PSArray, executable: Bool)
        case dictionary(PSDictionary)
        case op(String)
        case file(DocumentFile)
        case saved(Int)

        var number: Double? {
            switch self {
            case .int(let i): Double(i)
            case .real(let r): r
            default: nil
            }
        }

        /// Dictionary key (names and strings count by their text, as in PostScript).
        var key: String {
            switch self {
            case .name(let n, _): n
            case .text(let c, _): c.text
            case .int(let i): "#\(i)"
            case .real(let r): r == r.rounded() && abs(r) < 1e15 ? "#\(Int(r))" : "#r\(r)"
            case .bool(let b): "#b\(b)"
            case .op(let n): "#o\(n)"
            default: "#?"
            }
        }
    }
}

// MARK: - Reading the file (tokens and currentfile)

extension EPSImport {
    nonisolated final class FontChoice {
        let b: [UInt8]
        var i: Int
        let end: Int
        var finished = false
        /// Data blocks skipped (%%BeginData, embedded documents): images, almost always.
        var skippedImages = 0

        init(_ b: [UInt8], start: Int, end: Int) {
            self.b = b
            i = start
            self.end = end
        }

        static func space(_ c: UInt8) -> Bool { c == 32 || c == 10 || c == 13 || c == 9 || c == 12 || c == 0 }
        static func delimiter(_ c: UInt8) -> Bool {
            c == 40 || c == 41 || c == 60 || c == 62 || c == 91 || c == 93 || c == 123 || c == 125 || c == 47 || c == 37
        }

        func byte() -> UInt8? {
            guard i < end else { return nil }
            i += 1
            return b[i - 1]
        }

        func peek(_ d: Int = 0) -> UInt8? { i + d < end ? b[i + d] : nil }

        nonisolated enum Token {
            case value(Value)
            case immediate(String)
            case closesProcedure
        }

        /// Next token (nil at the end).
        func token() -> Token? {
            while true {
                guard !finished, let c = peek() else { return nil }
                if Self.space(c) { i += 1; continue }
                if c == 37 { comment(); continue }
                break
            }
            let c = b[i]
            switch c {
            case 40:
                i += 1
                return .value(.text(Chain(readText()), executable: false))
            case 60:
                if peek(1) == 60 { i += 2; return .value(.name("<<", executable: true)) }
                if peek(1) == 126 { i += 2; return .value(.text(Chain(readASCII85()), executable: false)) }
                i += 1
                return .value(.text(Chain(readHex()), executable: false))
            case 62:
                if peek(1) == 62 { i += 2; return .value(.name(">>", executable: true)) }
                i += 1
                return token()
            case 91, 93:
                i += 1
                return .value(.name(c == 91 ? "[" : "]", executable: true))
            case 123:
                i += 1
                return .value(.list(PSArray([]), executable: true))   // the interpreter reads the rest (see procedure)
            case 125:
                i += 1
                return .closesProcedure
            case 41:
                i += 1
                return token()
            case 47:
                i += 1
                if peek() == 47 {
                    i += 1
                    return .immediate(readWord())
                }
                return .value(.name(readWord(), executable: false))
            default:
                let word = readWord()
                return .value(Self.number(word) ?? .name(word, executable: true))
            }
        }

        private func readWord() -> String {
            let start = i
            while i < end, !Self.space(b[i]), !Self.delimiter(b[i]) { i += 1 }
            let word = String(decoding: b[start..<i], as: UTF8.self)
            // PostScript consumes one space after the name (currentfile reads from there).
            if i < end, Self.space(b[i]) {
                if b[i] == 13, i + 1 < end, b[i + 1] == 10 { i += 2 } else { i += 1 }
            }
            return word
        }

        static func number(_ s: String) -> Value? {
            guard let first = s.utf8.first, (first >= 48 && first <= 57) || first == 43 || first == 45 || first == 46
            else { return nil }
            if let n = Int(s) { return .int(n) }
            if let hashIndex = s.firstIndex(of: "#"), let base = Int(s[..<hashIndex]), (2...36).contains(base),
               let n = Int(s[s.index(after: hashIndex)...], radix: base) { return .int(n) }
            guard s.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || $0 == 43 || $0 == 45 || $0 == 46 || $0 == 101 || $0 == 69 }),
                  let r = Double(s), r.isFinite else { return nil }
            return .real(r)
        }

        private func comment() {
            let start = i
            let lineStart = i == 0 || b[i - 1] == 10 || b[i - 1] == 13
            while i < end, b[i] != 10, b[i] != 13 { i += 1 }
            guard lineStart, i - start >= 5, b[start + 1] == 37 else { return }
            let text = String(decoding: b[start..<min(i, start + 20)], as: UTF8.self)
            func skipTo(_ mark: String) {
                if let j = EPSImport.line(b, mark, since: i), j < end { i = EPSImport.afterLine(b, j) } else { i = end }
            }
            if text.hasPrefix("%%EOF") {
                finished = true
            } else if text.hasPrefix("%%BeginData") {
                skipTo("%%EndData")
                skippedImages += 1
            } else if text.hasPrefix("%%BeginDocument") {
                skipTo("%%EndDocument")
                skippedImages += 1
            } else if text.hasPrefix("%%BeginBinary") {
                skipTo("%%EndBinary")
            }
        }

        private func readText() -> [UInt8] {
            var output: [UInt8] = [], level = 1
            while let c = byte() {
                switch c {
                case 40: level += 1; output.append(c)
                case 41:
                    level -= 1
                    if level == 0 { return output }
                    output.append(c)
                case 92:
                    guard let e = byte() else { return output }
                    switch e {
                    case 110: output.append(10)
                    case 114: output.append(13)
                    case 116: output.append(9)
                    case 98: output.append(8)
                    case 102: output.append(12)
                    case 13: if peek() == 10 { i += 1 }
                    case 10: break
                    case 48...55:
                        var v = Int(e - 48)
                        for _ in 0..<2 {
                            guard let d = peek(), d >= 48, d <= 55 else { break }
                            v = v * 8 + Int(d - 48)
                            i += 1
                        }
                        output.append(UInt8(v & 255))
                    default: output.append(e)
                    }
                default: output.append(c)
                }
            }
            return output
        }

        static func hex(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: c - 48
            case 65...70: c - 55
            case 97...102: c - 87
            default: nil
            }
        }

        private func readHex() -> [UInt8] {
            var output: [UInt8] = [], tall: UInt8?
            while let c = byte(), c != 62 {
                guard let v = Self.hex(c) else { continue }
                if let a = tall { output.append(a << 4 | v); tall = nil } else { tall = v }
            }
            if let a = tall { output.append(a << 4) }
            return output
        }

        private func readASCII85() -> [UInt8] {
            var output: [UInt8] = [], group: [UInt32] = []
            func drop(_ n: Int) {
                var v: UInt32 = 0
                for k in 0..<5 { v = v &* 85 &+ (k < group.count ? group[k] : 84) }
                let bytes = [UInt8(v >> 24), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)]
                output += bytes.prefix(n)
            }
            while let c = byte() {
                if c == 126 { if peek() == 62 { i += 1 }; break }
                if c == 122, group.isEmpty { output += [0, 0, 0, 0]; continue }
                guard c >= 33, c <= 117 else { continue }
                group.append(UInt32(c - 33))
                if group.count == 5 { drop(4); group = [] }
            }
            if group.count > 1 { drop(group.count - 1) }
            return output
        }

        // currentfile

        func readLine() -> [UInt8]? {
            guard i < end else { return nil }
            let start = i
            while i < end, b[i] != 10, b[i] != 13 { i += 1 }
            let line = Array(b[start..<i])
            if i < end { if b[i] == 13, i + 1 < end, b[i + 1] == 10 { i += 2 } else { i += 1 } }
            return line
        }

        /// Skips the encrypted eexec part (fonts): goes to its closing cleartomark.
        func skipEexec() {
            if let j = EPSImport.discover(b, "cleartomark", since: i, until: end) { i = j } else { i = end }
        }
    }

    /// PostScript file: the program itself (currentfile) or a filter over it.
    nonisolated final class DocumentFile {
        nonisolated enum ResourceKind {
            case font, ascii85, asciiHex, subFile(count: Int, end: [UInt8]), other
        }

        let kind: ResourceKind
        let base: DocumentFile?
        let font: FontChoice
        private var didFinish = false
        private var pending: [UInt8] = []
        /// SubFileDecode: bytes left (without a marker) or occurrences of the marker to let through.
        private var remaining = 0

        init(font: FontChoice, kind: ResourceKind = .font, base: DocumentFile? = nil) {
            self.font = font
            self.kind = kind
            self.base = base
            if case .subFile(let n, _) = kind { remaining = n }
        }

        private func raw() -> UInt8? { base?.readByte() ?? (base == nil ? font.byte() : nil) }

        func readByte() -> UInt8? {
            if !pending.isEmpty { return pending.removeFirst() }
            guard !didFinish else { return nil }
            switch kind {
            case .font:
                return font.byte()
            case .other:
                return raw()
            case .asciiHex:
                var tall: UInt8?
                while let c = raw() {
                    if c == 62 { didFinish = true; return tall.map { $0 << 4 } }
                    guard let v = FontChoice.hex(c) else { continue }
                    if let a = tall { return a << 4 | v }
                    tall = v
                }
                didFinish = true
                return nil
            case .ascii85:
                var group: [UInt32] = []
                while group.count < 5, let c = raw() {
                    if c == 126 { _ = raw(); didFinish = true; break }
                    if c == 122, group.isEmpty { pending = [0, 0, 0]; return 0 }
                    guard c >= 33, c <= 117 else { continue }
                    group.append(UInt32(c - 33))
                }
                if group.count < 5 { didFinish = true }
                guard group.count >= 2 else { return nil }
                var v: UInt32 = 0
                for k in 0..<5 { v = v &* 85 &+ (k < group.count ? group[k] : 84) }
                let bytes = [UInt8(v >> 24), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)]
                pending = Array(bytes.prefix(group.count == 5 ? 4 : group.count - 1))
                return pending.removeFirst()
            case .subFile(_, let end):
                if end.isEmpty {
                    guard remaining > 0 else { didFinish = true; return nil }
                    remaining -= 1
                    return raw()
                }
                // Over the program itself: checks the end marker before each byte.
                if base.map({ if case .font = $0.kind { true } else { false } }) ?? true {
                    let f = font
                    if f.i + end.count <= f.end, Array(f.b[f.i..<(f.i + end.count)]) == end {
                        if remaining == 0 { f.i += end.count; didFinish = true; return nil }
                        remaining -= 1
                    }
                }
                return raw()
            }
        }

        /// Reads (and discards) to the end of the filter, or `bytes` bytes of the program.
        func skip(bytes: Int) {
            switch kind {
            case .font: font.i = min(font.i + min(bytes, font.end), font.end)
            case .other:
                if let base { base.skip(bytes: bytes) } else { font.i = min(font.i + min(bytes, font.end), font.end) }
            default:
                var n = 0
                while readByte() != nil, n < 64 << 20 { n += 1 }
            }
        }
    }
}

// MARK: - Interpreter

extension EPSImport {
    nonisolated enum Fault: Error {
        case emptyStack, kind, undefined(String), interval, quit, stop, limitValue, end
    }

    nonisolated indirect enum ColorSpaceKind {
        case gray, rgb, cmyk, defaultValue
        case separation(name: String, alternative: ColorSpaceKind, transform: Value)
        case deviceN(n: Int, alternative: ColorSpaceKind, transform: Value)
        case indexed(base: ColorSpaceKind, table: Value)
        /// AGM special color without a transform: the full color in the alternate space, times the tint.
        case ink(name: String, full: [Double], alternative: ColorSpaceKind)
        case other(Int)

        var components: Int {
            switch self {
            case .gray, .separation, .indexed, .ink: 1
            case .rgb: 3
            case .cmyk: 4
            case .defaultValue: 0
            case .deviceN(let n, _, _), .other(let n): n
            }
        }
    }

    nonisolated struct Graphic {
        var ctm = CGAffineTransform.identity
        var shapePath = CGMutablePath()
        /// What the clip leaves visible (pt, like the paths); nil = nothing clipped.
        var clip: ImportClipping.Region?
        /// charpath added text to the path (only counted, so the path is missing it).
        var textInPath = false
        var space = ColorSpaceKind.gray
        /// Current color (PostScript: the same for filling and stroking).
        var color: CMYK? = CMYK(c: 0, m: 0, y: 0, k: 100)
        /// AI format: separate fill and stroke colors.
        var fill: CMYK? = CMYK(c: 0, m: 0, y: 0, k: 100)
        var strokeColor: CMYK? = CMYK(c: 0, m: 0, y: 0, k: 100)
        var strokeWidth = 1.0
        var fontPointSize = 12.0

        func copy() -> Graphic {
            var g = self
            g.shapePath = shapePath.mutableCopy() ?? CGMutablePath()
            return g
        }
    }

    nonisolated final class Interpreter {
        let font: FontChoice
        let dialect: Dialect
        var stack: [Value] = []
        var dicts: [PSDictionary]
        let system = PSDictionary(), global = PSDictionary(), user = PSDictionary()
        var g = Graphic()
        var graphicsStack: [Graphic] = []
        var paints: [Paint] = []
        var texts = 0, images = 0, errors = 0
        var unknownOnes: [String: Int] = [:]
        private var operations = 0, depth = 0
        private var features: [String: Value] = [:]
        /// AI format compound path (*u … *U): the subpaths join into one object.
        private var compound: (shapePath: CGMutablePath, fillDemo: Bool, trace: Bool)?
        /// AI format: W marks the path as a clip, applied by the next painting operator (at *U, in a compound path).
        private var aiClip = false
        /// AI format fill rule (XR: 0 nonzero, 1 even-odd), for the fill and the clip.
        private var aiEvenOdd = false
        private let currentFile: DocumentFile
        static let limitValue = 40_000_000

        init(font: FontChoice, dialect: Dialect) {
            self.font = font
            self.dialect = dialect
            currentFile = DocumentFile(font: font)
            dicts = [system, global, user]
            for name in Self.ops { system[name] = .op(name) }
            let native: [String] = switch dialect {
            case .agm: Self.agmOperators
            case .classic: Self.aiOperators
            case .generic: []
            }
            for name in native { system[name] = .op(name) }
            system["systemdict"] = .dictionary(system)
            system["userdict"] = .dictionary(user)
            system["globaldict"] = .dictionary(global)
            for name in ["statusdict", "errordict", "$error", "FontDirectory", "GlobalFontDirectory", "SharedFontDirectory", "serverdict"] {
                system[name] = .dictionary(PSDictionary())
            }
            let encoding = Value.list(PSArray(Array(repeating: .name(".notdef", executable: false), count: 256)), executable: false)
            system["StandardEncoding"] = encoding
            system["ISOLatin1Encoding"] = encoding
        }

        // MARK: Execution

        func rotate() {
            while let token = font.token() {
                do {
                    switch token {
                    case .closesProcedure: continue
                    case .immediate(let name): stack.append(discover(name) ?? .name(name, executable: false))
                    case .value(let v):
                        if case .list(_, true) = v { stack.append(.list(procedure(), executable: true)) } else { try execute(v) }
                    }
                } catch Fault.limitValue {
                    break
                } catch Fault.end {
                    break
                } catch {
                    errors += 1
                }
                if operations > Self.limitValue { break }
            }
        }

        /// Reads a procedure up to the closing brace (the opening one was already read).
        private func procedure(of f: FontChoice? = nil) -> PSArray {
            let font = f ?? self.font
            var items: [Value] = []
            while let token = font.token() {
                switch token {
                case .closesProcedure: return PSArray(items)
                case .immediate(let name): items.append(discover(name) ?? .name(name, executable: false))
                case .value(let v):
                    if case .list(_, true) = v { items.append(.list(procedure(of: font), executable: true)) } else { items.append(v) }
                }
            }
            return PSArray(items)
        }

        func discover(_ name: String) -> Value? {
            for d in dicts.reversed() { if let v = d[name] { return v } }
            return nil
        }

        func execute(_ v: Value) throws {
            operations += 1
            if operations > Self.limitValue { throw Fault.limitValue }
            switch v {
            case .name(let name, true):
                guard let value = discover(name) else {
                    unknownOnes[name, default: 0] += 1
                    throw Fault.undefined(name)
                }
                switch value {
                case .list(let l, true): try rotate(l)
                case .op(let n): try op(n)
                case .name(_, true): try execute(value)
                default: stack.append(value)
                }
            case .list(let l, true): try rotate(l)
            case .op(let n): try op(n)
            case .text(let c, true):
                let sub = FontChoice(c.b, start: 0, end: c.b.count)
                while let token = sub.token() {
                    switch token {
                    case .closesProcedure: continue
                    case .immediate(let name): stack.append(discover(name) ?? .name(name, executable: false))
                    case .value(let v):
                        if case .list(_, true) = v { stack.append(.list(procedure(of: sub), executable: true)) } else { try execute(v) }
                    }
                }
            default:
                stack.append(v)
            }
        }

        func rotate(_ proc: PSArray) throws {
            depth += 1
            defer { depth -= 1 }
            // Endless recursion (or a hostile file) only fails that command; the limit fits in the main thread's stack.
            guard depth < 120 else { throw Fault.interval }
            for item in proc.v {
                switch item {
                case .list(_, true): stack.append(item)
                case .name(_, true), .op: try execute(item)
                default: stack.append(item)
                }
            }
        }

        // MARK: Stack

        func pop() throws -> Value {
            guard let v = stack.popLast() else { throw Fault.emptyStack }
            return v
        }

        func num() throws -> Double {
            guard let n = try pop().number else { throw Fault.kind }
            guard n.isFinite else { throw Fault.interval }
            return n
        }

        func integer() throws -> Int { try Self.toInteger(try num()) }

        /// Malformed files bring absurd numbers: out of range is an error (never a conversion that crashes the app).
        static func toInteger(_ n: Double) throws -> Int {
            guard n.isFinite, abs(n) < 1e15 else { throw Fault.interval }
            return Int(n)
        }

        func logical() throws -> Bool {
            guard case .bool(let b) = try pop() else { throw Fault.kind }
            return b
        }

        func list() throws -> PSArray {
            guard case .list(let l, _) = try pop() else { throw Fault.kind }
            return l
        }

        func dictionary() throws -> PSDictionary {
            guard case .dictionary(let d) = try pop() else { throw Fault.kind }
            return d
        }

        func chain() throws -> Chain {
            guard case .text(let c, _) = try pop() else { throw Fault.kind }
            return c
        }

        func procedureOnStack() throws -> Value {
            let v = try pop()
            guard case .list = v else { throw Fault.kind }
            return v
        }

        func numbers(_ n: Int) throws -> [Double] {
            guard stack.count >= n else { throw Fault.emptyStack }
            var v = [Double](repeating: 0, count: n)
            for k in stride(from: n - 1, through: 0, by: -1) { v[k] = try num() }
            return v
        }

        func nudge(_ x: Double) { stack.append(.real(x)) }

        static func matrix(_ l: PSArray) throws -> CGAffineTransform {
            let v = l.v.compactMap(\.number)
            guard v.count == 6 else { throw Fault.kind }
            return CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
        }

        static func list(_ t: CGAffineTransform) -> [Value] { [t.a, t.b, t.c, t.d, t.tx, t.ty].map { .real($0) } }

        /// Optional matrix on top (the forms "x y matrix transform", "tx ty matrix translate").
        func matrixOnTop() -> PSArray? {
            if case .list(let l, _) = stack.last, l.v.count == 6, l.v.allSatisfy({ $0.number != nil }) {
                stack.removeLast()
                return l
            }
            return nil
        }

        func equal(_ a: Value, _ b: Value) -> Bool {
            switch (a, b) {
            case (.int, _), (.real, _): if let x = a.number, let y = b.number { return x == y }; return false
            case (.bool(let x), .bool(let y)): return x == y
            case (.null, .null), (.mark, .mark): return true
            case (.name, .name), (.name, .text), (.text, .name), (.text, .text): return a.key == b.key
            case (.list(let x, _), .list(let y, _)): return x === y
            case (.dictionary(let x), .dictionary(let y)): return x === y
            case (.op(let x), .op(let y)): return x == y
            default: return false
            }
        }

        // MARK: Painting

        private var currentScale: Double { sqrt(abs(g.ctm.a * g.ctm.d - g.ctm.b * g.ctm.c)) }

        func emit(_ shapePath: CGPath, strokeColor: CMYK?, fill: CMYK?, evenOdd: Bool = false) {
            guard !shapePath.isEmpty, strokeColor != nil || fill != nil else { return }
            let strokeWidth = g.strokeWidth * currentScale
            // Fill and then stroke the same path (as PostScript makes one object with both): a single object.
            if let strokeColor, fill == nil, let lastOne = paints.last, lastOne.strokeColor == nil, lastOne.shapePath == shapePath,
               lastOne.clip?.path == g.clip?.path {
                paints[paints.count - 1].strokeColor = strokeColor
                paints[paints.count - 1].strokeWidth = strokeWidth
                return
            }
            paints.append(Paint(shapePath: shapePath.copy() ?? shapePath, strokeColor: strokeColor, strokeWidth: strokeWidth, fill: fill,
                                evenOdd: evenOdd, clip: g.clip))
        }

        func newPath() {
            g.shapePath = CGMutablePath()
            g.textInPath = false
        }

        /// clip/eoclip: from now on only what's inside both the clip and the current path shows. A path with text in
        /// it (charpath) can't be worked out and clips nothing, so what it would hide stays.
        func clipToPath(_ rule: CGPathFillRule) {
            guard !g.textInPath else { return }
            g.clip = ImportClipping.clip(g.clip, to: g.shapePath, rule: rule)
        }

        func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y).applying(g.ctm) }

        func currentUserPoint() throws -> CGPoint {
            guard !g.shapePath.isEmpty else { throw Fault.interval }
            return g.shapePath.currentPoint.applying(g.ctm.inverted())
        }

        /// AI format painting: `close` (lowercase), fill and stroke; inside *u … *U, joins. After a W, the path also clips
        /// (painted first, as Illustrator's procset does); in a compound path, the whole path at *U.
        func paintAIPath(close: Bool, fillDemo: Bool, trace: Bool) {
            if close, !g.shapePath.isEmpty { g.shapePath.closeSubpath() }
            if var c = compound {
                c.shapePath.addPath(g.shapePath)
                c.fillDemo = c.fillDemo || fillDemo
                c.trace = c.trace || trace
                compound = c
            } else {
                emit(g.shapePath, strokeColor: trace ? g.strokeColor : nil, fill: fillDemo ? g.fill : nil, evenOdd: aiEvenOdd)
                if aiClip {
                    clipToPath(aiEvenOdd ? .evenOdd : .winding)
                    aiClip = false
                }
            }
            newPath()
            stack.removeAll()
        }

        // MARK: Colors

        func space(of v: Value) -> ColorSpaceKind {
            func byName(_ n: String) -> ColorSpaceKind {
                switch n {
                case "DeviceGray", "CalGray", "G", "CIEBasedA": .gray
                case "DeviceRGB", "CalRGB", "RGB", "CIEBasedABC", "CIEBasedDEF": .rgb
                case "DeviceCMYK", "CMYK", "CIEBasedDEFG": .cmyk
                case "Pattern": .defaultValue
                default: .gray
                }
            }
            switch v {
            case .name(let n, _): return byName(n)
            case .list(let l, _):
                guard let first = l.v.first, case .name(let kind, _) = first else { return .gray }
                switch kind {
                case "Separation" where l.v.count >= 4:
                    let name = l.v[1].key
                    return .separation(name: name, alternative: space(of: l.v[2]), transform: l.v[3])
                case "DeviceN" where l.v.count >= 4:
                    var n = 1
                    if case .list(let names, _) = l.v[1] { n = names.v.count }
                    return .deviceN(n: n, alternative: space(of: l.v[2]), transform: l.v[3])
                case "Indexed" where l.v.count >= 4:
                    return .indexed(base: space(of: l.v[1]), table: l.v[3])
                case "ICCBased":
                    if l.v.count >= 2, case .dictionary(let d) = l.v[1], let n = d["N"]?.number, let i = try? Self.toInteger(n) {
                        return .other(min(max(i, 1), 32))
                    }
                    return .rgb
                default:
                    return byName(kind)
                }
            default:
                return .gray
            }
        }

        /// Color of the space with these components, in CMYK (runs the tint transforms of special colors).
        func resolver(_ space: ColorSpaceKind, _ v: [Double], level: Int = 0) -> CMYK? {
            guard level < 5 else { return nil }
            func transformAction(_ input: [Double], _ proc: Value, _ alternative: ColorSpaceKind) -> CMYK? {
                let before = stack.count
                input.forEach(nudge)
                if (try? execute(proc)) == nil { stack.removeLast(max(0, stack.count - before)); return nil }
                let n = alternative.components
                guard stack.count - before >= n else { stack.removeLast(max(0, stack.count - before)); return nil }
                let output = stack.suffix(n).compactMap(\.number)
                stack.removeLast(stack.count - before)
                return output.count == n ? resolver(alternative, output, level: level + 1) : nil
            }
            switch space {
            case .gray: return v.first.flatMap { VectorImporter.color([$0]) }
            case .rgb: return v.count >= 3 ? VectorImporter.color(Array(v.prefix(3))) : nil
            case .cmyk: return v.count >= 4 ? VectorImporter.color(Array(v.prefix(4))) : nil
            case .defaultValue: return CMYK(c: 0, m: 0, y: 0, k: 50)
            case .other(let n): return v.count >= n ? VectorImporter.color(Array(v.prefix(n))) : nil
            case .separation(let name, let alternative, let proc):
                let ink = v.first ?? 1
                if name == "None" { return nil }
                if name == "All" { return CMYK(c: 0, m: 0, y: 0, k: (min(max(ink, 0), 1) * 100).rounded()) }
                return transformAction([ink], proc, alternative)
            case .deviceN(let n, let alternative, let proc):
                return transformAction(Array((v + Array(repeating: 1, count: n)).prefix(n)), proc, alternative)
            case .ink(let name, let full, let alternative):
                let t = min(max(v.first ?? 1, 0), 1)
                if name == "All" || full.isEmpty { return CMYK(c: 0, m: 0, y: 0, k: (t * 100).rounded()) }
                // Subtractive (CMYK, gray as ink): proportional; additive (RGB): from white to the color.
                let additive = if case .rgb = alternative { true } else { false }
                return resolver(alternative, full.map { additive ? 1 - (1 - $0) * t : $0 * t }, level: level + 1)
            case .indexed(let base, let table):
                guard let index = try? Self.toInteger(v.first ?? 0), index >= 0, index < 65536 else { return nil }
                let i = index, n = base.components
                switch table {
                case .text(let c, _):
                    guard n > 0, (i + 1) * n <= c.b.count else { return nil }
                    return resolver(base, c.b[(i * n)..<((i + 1) * n)].map { Double($0) / 255 }, level: level + 1)
                case .list:
                    return transformAction([Double(i)], table, base)
                default: return nil
                }
            }
        }

        func setSpacing(_ e: ColorSpaceKind) {
            g.space = e
            let initial: [Double] = switch e {
            case .cmyk: [0, 0, 0, 1]
            case .separation: [1]
            case .deviceN(let n, _, _): Array(repeating: 1, count: n)
            default: Array(repeating: 0, count: e.components)
            }
            g.color = resolver(e, initial)
        }

        /// Average color of a gradient (shfill): the functions' C0/C1.
        func gradientColor(_ d: PSDictionary) -> CMYK? {
            let space = d["ColorSpace"].map(space(of:)) ?? g.space
            var swatches: [[Double]] = []
            func visit(_ v: Value?, level: Int) {
                guard level < 6, let v else { return }
                switch v {
                case .dictionary(let f):
                    for key in ["C0", "C1"] {
                        if case .list(let l, _) = f[key] { swatches.append(l.v.compactMap(\.number)) }
                    }
                    visit(f["Functions"], level: level + 1)
                case .list(let l, _):
                    for item in l.v { visit(item, level: level + 1) }
                default: break
                }
            }
            visit(d["Function"], level: 0)
            let n = space.components
            let valid = swatches.filter { $0.count == n }
            guard !valid.isEmpty else { return CMYK(c: 0, m: 0, y: 0, k: 50) }
            let media = (0..<n).map { k in valid.map { $0[k] }.reduce(0, +) / Double(valid.count) }
            return resolver(space, media)
        }

        // MARK: Images

        /// Skips an image's data (string, procedure that reads from the file, or filter).
        func skipData(_ fonts: [Value], bytes: Int) {
            images += 1
            for font in fonts {
                switch font {
                case .list(_, true):
                    var readOnes = 0, turns = 0
                    while readOnes < bytes, turns < 1_000_000 {
                        turns += 1
                        let before = stack.count
                        guard (try? execute(font)) != nil, stack.count > before, case .text(let c, _) = stack.removeLast(),
                              !c.b.isEmpty else { break }
                        readOnes += c.b.count
                        stack.removeLast(max(0, stack.count - before))
                    }
                case .file(let a):
                    a.skip(bytes: bytes)
                default:
                    break
                }
            }
        }

        /// Size of an image's data, capped (absurd dimensions don't overflow the math).
        private static func size(_ w: Double, _ h: Double, _ bpc: Double, _ n: Double) -> Int {
            let lim = { (x: Double) in x.isFinite ? min(max(x, 0), 100_000) : 0 }
            return Int(min(((lim(w) * lim(bpc) * lim(n) + 7) / 8).rounded(.down) * lim(h), 1e12))
        }

        func image(mask: Bool, colored: Bool = false) throws {
            if case .dictionary(let d) = stack.last {
                stack.removeLast()
                let n = mask ? 1 : max(g.space.components, 1)
                skipData([d["DataSource"] ?? .null], bytes: Self.size(d["Width"]?.number ?? 0, d["Height"]?.number ?? 0,
                                                                         d["BitsPerComponent"]?.number ?? 1, Double(n)))
                return
            }
            if colored {
                let ncomp = try integer(), multi = try logical()
                guard (1...4).contains(ncomp) else { throw Fault.interval }
                var fonts: [Value] = []
                for _ in 0..<(multi ? ncomp : 1) { fonts.insert(try pop(), at: 0) }
                _ = try pop()   // matrix
                let bpc = try num(), h = try num(), w = try num()
                skipData(fonts, bytes: Self.size(w, h, bpc, Double(multi ? 1 : ncomp)))
                return
            }
            let font = try pop()
            _ = try pop()   // matrix
            let third = try pop()   // bits per component (or the mask's polarity)
            let h = try num(), w = try num()
            skipData([font], bytes: Self.size(w, h, mask ? 1 : third.number ?? 8, 1))
        }

        // MARK: Operators

        static let agmOperators = ["mo", "li", "cv", "cp", "np", "f", "ef", "@", "clp", "eclp", "nclp", "ct", "pgsv", "pgrs", "sop",
                                    "lw", "lc", "lj", "ml", "dsh", "sadj", "gry", "rgb", "cmyk", "nzopmsc", "sep", "sepcs", "devn",
                                    "devncs", "idx", "idxcs", "colr", "csacrd", "level3", "add_res", "get_res", "del_res", "clonedict",
                                    "gx", "cf", "fl", "rs"]

        static let aiOperators = ["m", "l", "L", "c", "C", "v", "V", "y", "Y", "N", "n", "F", "f", "S", "s", "B", "b", "H", "h", "*u",
                                   "*U", "u", "U", "q", "Q", "W", "D", "A", "O", "R", "XR", "J", "j", "w", "M", "d", "Ar", "i", "k", "K",
                                   "g", "G", "x", "X", "Xa", "XA", "Xx", "XX", "Xk", "XK", "To", "XI", "XG", "Ln", "LB", "p", "P"]

        static let ops: [String] = """
        pop exch dup copy index roll clear count mark cleartomark counttomark [ ] << >> \
        add sub mul div idiv mod neg abs ceiling floor round truncate sqrt atan cos sin exp ln log rand srand rrand cvi cvr \
        eq ne gt ge lt le and or xor not bitshift true false null \
        exec if ifelse for repeat loop exit forall stop stopped quit countexecstack execstack \
        type cvn cvs cvrs cvlit cvx xcheck rcheck wcheck readonly executeonly noaccess \
        dict begin end def load store known where undef currentdict countdictstack dictstack cleardictstack maxlength \
        array string length get put getinterval putinterval aload astore search anchorsearch token packedarray \
        bind version languagelevel product revision serialnumber realtime usertime vmstatus vmreclaim setvmthreshold \
        currentglobal setglobal gcheck currentpacking setpacking internaldict \
        save restore gsave grestore grestoreall initgraphics \
        setlinewidth currentlinewidth setlinecap currentlinecap setlinejoin currentlinejoin setmiterlimit currentmiterlimit \
        setdash currentdash setflat currentflat setstrokeadjust currentstrokeadjust setoverprint currentoverprint setsmoothness \
        setscreen currentscreen setcolorscreen settransfer currenttransfer setcolortransfer currentcolortransfer \
        setblackgeneration currentblackgeneration setundercolorremoval currentundercolorremoval sethalftone currenthalftone \
        setcolorrendering currentcolorrendering setgray currentgray setrgbcolor currentrgbcolor setcmykcolor currentcmykcolor \
        sethsbcolor currenthsbcolor setcolorspace currentcolorspace setcolor currentcolor setpattern makepattern \
        matrix identmatrix defaultmatrix currentmatrix setmatrix initmatrix concat concatmatrix translate scale rotate \
        transform itransform dtransform idtransform invertmatrix \
        newpath moveto rmoveto lineto rlineto curveto rcurveto closepath arc arcn arct arcto currentpoint pathbbox \
        flattenpath reversepath strokepath clippath initclip clip eoclip rectclip rectfill rectstroke fill eofill stroke \
        ufill ueofill ustroke shfill pathforall \
        image imagemask colorimage \
        findfont scalefont makefont setfont currentfont definefont undefinefont selectfont rootfont stringwidth \
        show ashow widthshow awidthshow xshow xyshow yshow kshow cshow glyphshow charpath setcachedevice setcachedevice2 \
        setcharwidth findencoding \
        findresource defineresource undefineresource resourcestatus resourceforall \
        currentfile readstring readhexstring readline read flushfile closefile filter eexec bytesavailable status file run \
        print = == stack pstack flush echo write writestring setfileposition fileposition \
        setpagedevice currentpagedevice showpage copypage erasepage nulldevice setcachelimit
        """.split(whereSeparator: \.isWhitespace).map(String.init)

        private func circular(_ n: Int, _ k: Int) -> Int { ((k % n) + n) % n }

        func op(_ name: String) throws {
            // Illustrator dialects' shortcuts first.
            if dialect == .agm, try agmOperator(name) { return }
            if dialect == .classic, try aiOperator(name) { return }
            switch name {
            // Stack
            case "pop": _ = try pop()
            case "exch":
                let b = try pop(), a = try pop()
                stack += [b, a]
            case "dup":
                guard let v = stack.last else { throw Fault.emptyStack }
                stack.append(v)
            case "copy":
                if case .int = stack.last {
                    let n = try integer()
                    guard n >= 0, n <= stack.count else { throw Fault.interval }
                    stack += stack.suffix(n)
                } else {
                    let destination = try pop(), origin = try pop()
                    switch (origin, destination) {
                    case (.list(let a, _), .list(let b, let x)):
                        guard a.v.count <= b.v.count else { throw Fault.interval }
                        b.v.replaceSubrange(0..<a.v.count, with: a.v)
                        stack.append(.list(a.v.count == b.v.count ? b : PSArray(Array(b.v.prefix(a.v.count))), executable: x))
                    case (.text(let a, _), .text(let b, let x)):
                        guard a.b.count <= b.b.count else { throw Fault.interval }
                        b.b.replaceSubrange(0..<a.b.count, with: a.b)
                        stack.append(.text(a.b.count == b.b.count ? b : Chain(Array(b.b.prefix(a.b.count))), executable: x))
                    case (.dictionary(let a), .dictionary(let b)):
                        b.d.merge(a.d) { _, updated in updated }
                        stack.append(.dictionary(b))
                    default: throw Fault.kind
                    }
                }
            case "index":
                let n = try integer()
                guard n >= 0, n < stack.count else { throw Fault.interval }
                stack.append(stack[stack.count - 1 - n])
            case "roll":
                let j = try integer(), n = try integer()
                guard n >= 0, n <= stack.count else { throw Fault.interval }
                guard n > 0 else { break }
                let top = Array(stack.suffix(n))
                stack.removeLast(n)
                let k = circular(n, j)
                stack += Array(top[(n - k)...] + top[..<(n - k)])
            case "clear": stack.removeAll()
            case "count": stack.append(.int(stack.count))
            case "mark", "[", "<<": stack.append(.mark)
            case "cleartomark":
                guard let i = stack.lastIndex(where: { if case .mark = $0 { true } else { false } }) else { throw Fault.emptyStack }
                stack.removeSubrange(i...)
            case "counttomark":
                guard let i = stack.lastIndex(where: { if case .mark = $0 { true } else { false } }) else { throw Fault.emptyStack }
                stack.append(.int(stack.count - 1 - i))
            case "]":
                guard let i = stack.lastIndex(where: { if case .mark = $0 { true } else { false } }) else { throw Fault.emptyStack }
                let items = Array(stack[(i + 1)...])
                stack.removeSubrange(i...)
                stack.append(.list(PSArray(items), executable: false))
            case ">>":
                guard let i = stack.lastIndex(where: { if case .mark = $0 { true } else { false } }) else { throw Fault.emptyStack }
                let items = Array(stack[(i + 1)...])
                stack.removeSubrange(i...)
                let d = PSDictionary()
                for k in stride(from: 0, to: items.count - 1, by: 2) { d.d[items[k].key] = (items[k], items[k + 1]) }
                stack.append(.dictionary(d))

            // Arithmetic
            case "add", "sub", "mul":
                let b = try pop(), a = try pop()
                if case .int(let x) = a, case .int(let y) = b {
                    let (r, overflowed) = name == "add" ? x.addingReportingOverflow(y) : name == "sub" ? x.subtractingReportingOverflow(y)
                        : x.multipliedReportingOverflow(by: y)
                    if !overflowed { stack.append(.int(r)); break }
                }
                guard let x = a.number, let y = b.number else { throw Fault.kind }
                stack.append(.real(name == "add" ? x + y : name == "sub" ? x - y : x * y))
            case "div":
                let b = try num(), a = try num()
                guard b != 0 else { throw Fault.interval }
                stack.append(.real(a / b))
            case "idiv", "mod":
                let b = try integer(), a = try integer()
                guard b != 0 else { throw Fault.interval }
                stack.append(.int(name == "idiv" ? a / b : a % b))
            case "neg":
                guard let x = try pop().number else { throw Fault.kind }
                stack.append(x == x.rounded() && abs(x) < 1e15 ? .int(Int(-x)) : .real(-x))
            case "abs":
                guard let x = try pop().number else { throw Fault.kind }
                stack.append(x == x.rounded() && abs(x) < 1e15 ? .int(Int(abs(x))) : .real(abs(x)))
            case "ceiling", "floor", "round", "truncate":
                let a = try pop()
                if case .int = a { stack.append(a); break }
                guard let x = a.number else { throw Fault.kind }
                let r: Double = switch name {
                case "ceiling": x.rounded(.up)
                case "floor": x.rounded(.down)
                case "round": (x + 0.5).rounded(.down)
                default: x.rounded(.towardZero)
                }
                stack.append(.real(r))
            case "sqrt": stack.append(.real(sqrt(max(try num(), 0))))
            case "atan":
                let den = try num(), numr = try num()
                var a = atan2(numr, den) * 180 / .pi
                if a < 0 { a += 360 }
                stack.append(.real(a))
            case "cos": stack.append(.real(cos(try num() * .pi / 180)))
            case "sin": stack.append(.real(sin(try num() * .pi / 180)))
            case "exp":
                let e = try num(), b = try num()
                stack.append(.real(pow(b, e)))
            case "ln": stack.append(.real(log(max(try num(), 1e-300))))
            case "log": stack.append(.real(log10(max(try num(), 1e-300))))
            case "rand": stack.append(.int(Int.random(in: 0...Int(Int32.max))))
            case "srand": _ = try pop()
            case "rrand": stack.append(.int(0))
            case "cvi":
                let a = try pop()
                if case .text(let c, _) = a { stack.append(.int(try Self.toInteger(Double(c.text.trimmingCharacters(in: .whitespaces)) ?? 0))) }
                else if let x = a.number { stack.append(.int(try Self.toInteger(x.rounded(.towardZero)))) } else { throw Fault.kind }
            case "cvr":
                let a = try pop()
                if case .text(let c, _) = a { stack.append(.real(Double(c.text.trimmingCharacters(in: .whitespaces)) ?? 0)) }
                else if let x = a.number { stack.append(.real(x)) } else { throw Fault.kind }

            // Relations and logic
            case "eq", "ne":
                let b = try pop(), a = try pop()
                stack.append(.bool(equal(a, b) == (name == "eq")))
            case "gt", "ge", "lt", "le":
                let b = try pop(), a = try pop()
                let r: Bool
                if let x = a.number, let y = b.number {
                    r = name == "gt" ? x > y : name == "ge" ? x >= y : name == "lt" ? x < y : x <= y
                } else if case .text(let x, _) = a, case .text(let y, _) = b {
                    r = name == "gt" ? x.b.lexicographicallyPrecedes(y.b) == false && x.b != y.b
                        : name == "ge" ? !x.b.lexicographicallyPrecedes(y.b)
                        : name == "lt" ? x.b.lexicographicallyPrecedes(y.b) : (x.b.lexicographicallyPrecedes(y.b) || x.b == y.b)
                } else { throw Fault.kind }
                stack.append(.bool(r))
            case "and", "or", "xor":
                let b = try pop(), a = try pop()
                if case .bool(let x) = a, case .bool(let y) = b {
                    stack.append(.bool(name == "and" ? x && y : name == "or" ? x || y : x != y))
                } else if case .int(let x) = a, case .int(let y) = b {
                    stack.append(.int(name == "and" ? x & y : name == "or" ? x | y : x ^ y))
                } else { throw Fault.kind }
            case "not":
                let a = try pop()
                if case .bool(let x) = a { stack.append(.bool(!x)) } else if case .int(let x) = a { stack.append(.int(~x)) } else { throw Fault.kind }
            case "bitshift":
                let s = try integer(), x = try integer()
                stack.append(.int(s >= 0 ? x << s : x >> -s))
            case "true": stack.append(.bool(true))
            case "false": stack.append(.bool(false))
            case "null": stack.append(.null)

            // Control
            case "exec": try execute(try pop())
            case "if":
                let p = try procedureOnStack(), c = try logical()
                if c { try execute(p) }
            case "ifelse":
                let node = try procedureOnStack(), ifTrue = try procedureOnStack(), c = try logical()
                try execute(c ? ifTrue : node)
            case "for":
                let p = try procedureOnStack(), limitValue = try pop(), step = try pop(), start = try pop()
                guard let l = limitValue.number, let s = step.number, var x = start.number, s != 0 else { throw Fault.kind }
                let integers: Bool = if case .int = start, case .int = step { true } else { false }
                do {
                    while s > 0 ? x <= l : x >= l {
                        stack.append(integers ? .int(try Self.toInteger(x)) : .real(x))
                        try execute(p)
                        x += s
                    }
                } catch Fault.quit {}
            case "repeat":
                let p = try procedureOnStack(), n = try integer()
                do { for _ in 0..<max(n, 0) { try execute(p) } } catch Fault.quit {}
            case "loop":
                let p = try procedureOnStack()
                do { while true { try execute(p) } } catch Fault.quit {}
            case "exit": throw Fault.quit
            case "forall":
                let p = try procedureOnStack(), target = try pop()
                do {
                    switch target {
                    case .list(let l, _): for item in l.v { stack.append(item); try execute(p) }
                    case .text(let c, _): for b in c.b { stack.append(.int(Int(b))); try execute(p) }
                    case .dictionary(let d): for (_, pair) in d.d { stack += [pair.key, pair.value]; try execute(p) }
                    default: throw Fault.kind
                    }
                } catch Fault.quit {}
            case "stop": throw Fault.stop
            case "stopped":
                let p = try pop()
                do {
                    try execute(p)
                    stack.append(.bool(false))
                } catch Fault.limitValue {
                    throw Fault.limitValue
                } catch Fault.end {
                    throw Fault.end
                } catch {
                    stack.append(.bool(true))
                }
            case "quit": throw Fault.end
            case "countexecstack": stack.append(.int(depth))
            case "execstack": _ = try pop(); stack.append(.list(PSArray([]), executable: false))

            // Types
            case "type":
                let a = try pop()
                let t: String = switch a {
                case .int: "integertype"
                case .real: "realtype"
                case .bool: "booleantype"
                case .null: "nulltype"
                case .mark: "marktype"
                case .name: "nametype"
                case .text: "stringtype"
                case .list: "arraytype"
                case .dictionary: "dicttype"
                case .op: "operatortype"
                case .file: "filetype"
                case .saved: "savetype"
                }
                stack.append(.name(t, executable: true))
            case "cvn":
                let c = try chain()
                stack.append(.name(c.text, executable: false))
            case "cvs", "cvrs":
                let destination = try chain()
                if name == "cvrs" { _ = try pop() }
                let a = try pop()
                let text: String = switch a {
                case .int(let i): "\(i)"
                case .real(let r): r == r.rounded() && abs(r) < 1e15 ? "\(Int(r)).0" : "\(r)"
                case .bool(let b): b ? "true" : "false"
                case .name(let n, _), .op(let n): n
                case .text(let c, _): c.text
                default: "--nostringval--"
                }
                let bytes = Array(text.utf8)
                let n = min(bytes.count, destination.b.count)
                destination.b.replaceSubrange(0..<n, with: bytes.prefix(n))
                stack.append(.text(Chain(Array(bytes.prefix(max(n, 0)))), executable: false))
            case "cvlit":
                let a = try pop()
                switch a {
                case .name(let n, _): stack.append(.name(n, executable: false))
                case .list(let l, _): stack.append(.list(l, executable: false))
                case .text(let c, _): stack.append(.text(c, executable: false))
                default: stack.append(a)
                }
            case "cvx":
                let a = try pop()
                switch a {
                case .name(let n, _): stack.append(.name(n, executable: true))
                case .list(let l, _): stack.append(.list(l, executable: true))
                case .text(let c, _): stack.append(.text(c, executable: true))
                default: stack.append(a)
                }
            case "xcheck":
                let a = try pop()
                let x: Bool = switch a {
                case .name(_, let e), .list(_, let e), .text(_, let e): e
                case .op: true
                default: false
                }
                stack.append(.bool(x))
            case "rcheck", "wcheck": _ = try pop(); stack.append(.bool(true))
            case "readonly", "executeonly", "noaccess": break

            // Dictionaries
            case "dict": _ = try pop(); stack.append(.dictionary(PSDictionary()))
            case "begin": dicts.append(try dictionary())
            case "end": if dicts.count > 3 { dicts.removeLast() }
            case "def":
                let value = try pop(), key = try pop()
                dicts.last!.d[key.key] = (key, value)
            case "load":
                let key = try pop()
                guard let v = discover(key.key) else { throw Fault.undefined(key.key) }
                stack.append(v)
            case "store":
                let value = try pop(), key = try pop()
                let target = dicts.last { $0.d[key.key] != nil } ?? dicts.last!
                target.d[key.key] = (key, value)
            case "known":
                let key = try pop(), d = try dictionary()
                stack.append(.bool(d.d[key.key] != nil))
            case "where":
                let key = try pop()
                if let d = dicts.last(where: { $0.d[key.key] != nil }) { stack += [.dictionary(d), .bool(true)] } else { stack.append(.bool(false)) }
            case "undef":
                let key = try pop(), d = try dictionary()
                d.d[key.key] = nil
            case "currentdict": stack.append(.dictionary(dicts.last!))
            case "countdictstack": stack.append(.int(dicts.count))
            case "dictstack":
                _ = try pop()
                stack.append(.list(PSArray(dicts.map { .dictionary($0) }), executable: false))
            case "cleardictstack": dicts = Array(dicts.prefix(3))
            case "maxlength": _ = try pop(); stack.append(.int(1000))

            // Arrays and strings
            case "array", "packedarray":
                if name == "packedarray" {
                    let n = try integer()
                    guard n >= 0, n <= stack.count else { throw Fault.interval }
                    let items = Array(stack.suffix(n))
                    stack.removeLast(n)
                    stack.append(.list(PSArray(items), executable: false))
                } else {
                    let n = try integer()
                    guard n >= 0, n < 10_000_000 else { throw Fault.interval }
                    stack.append(.list(PSArray(Array(repeating: .null, count: n)), executable: false))
                }
            case "string":
                let n = try integer()
                guard n >= 0, n < 16_000_000 else { throw Fault.interval }
                stack.append(.text(Chain([UInt8](repeating: 0, count: n)), executable: false))
            case "length":
                let a = try pop()
                switch a {
                case .list(let l, _): stack.append(.int(l.v.count))
                case .text(let c, _): stack.append(.int(c.b.count))
                case .dictionary(let d): stack.append(.int(d.d.count))
                case .name(let n, _): stack.append(.int(n.utf8.count))
                default: throw Fault.kind
                }
            case "get":
                let key = try pop(), target = try pop()
                switch target {
                case .list(let l, _):
                    guard let i = key.number.flatMap({ try? Self.toInteger($0) }), i >= 0, i < l.v.count else { throw Fault.interval }
                    stack.append(l.v[i])
                case .text(let c, _):
                    guard let i = key.number.flatMap({ try? Self.toInteger($0) }), i >= 0, i < c.b.count else { throw Fault.interval }
                    stack.append(.int(Int(c.b[i])))
                case .dictionary(let d):
                    guard let v = d.d[key.key]?.value else { throw Fault.undefined(key.key) }
                    stack.append(v)
                default: throw Fault.kind
                }
            case "put":
                let value = try pop(), key = try pop(), target = try pop()
                switch target {
                case .list(let l, _):
                    guard let i = key.number.flatMap({ try? Self.toInteger($0) }), i >= 0, i < l.v.count else { throw Fault.interval }
                    l.v[i] = value
                case .text(let c, _):
                    guard let i = key.number.flatMap({ try? Self.toInteger($0) }), i >= 0, i < c.b.count, let x = value.number else { throw Fault.interval }
                    c.b[i] = UInt8(try Self.toInteger(x) & 255)
                case .dictionary(let d): d.d[key.key] = (key, value)
                default: throw Fault.kind
                }
            case "getinterval":
                let n = try integer(), i = try integer(), target = try pop()
                switch target {
                case .list(let l, let x):
                    guard i >= 0, n >= 0, i + n <= l.v.count else { throw Fault.interval }
                    stack.append(.list(PSArray(Array(l.v[i..<(i + n)])), executable: x))
                case .text(let c, let x):
                    guard i >= 0, n >= 0, i + n <= c.b.count else { throw Fault.interval }
                    stack.append(.text(Chain(Array(c.b[i..<(i + n)])), executable: x))
                default: throw Fault.kind
                }
            case "putinterval":
                let origin = try pop(), i = try integer(), destination = try pop()
                switch (destination, origin) {
                case (.list(let d, _), .list(let o, _)):
                    guard i >= 0, i + o.v.count <= d.v.count else { throw Fault.interval }
                    d.v.replaceSubrange(i..<(i + o.v.count), with: o.v)
                case (.text(let d, _), .text(let o, _)):
                    guard i >= 0, i + o.b.count <= d.b.count else { throw Fault.interval }
                    d.b.replaceSubrange(i..<(i + o.b.count), with: o.b)
                default: throw Fault.kind
                }
            case "aload":
                let l = try list()
                stack += l.v
                stack.append(.list(l, executable: false))
            case "astore":
                let l = try list()
                guard stack.count >= l.v.count else { throw Fault.emptyStack }
                l.v = Array(stack.suffix(l.v.count))
                stack.removeLast(l.v.count)
                stack.append(.list(l, executable: false))
            case "search", "anchorsearch":
                let searchFor = try chain(), target = try chain()
                let p = searchFor.b, t = target.b
                var didFind: Int?
                if name == "anchorsearch" {
                    if t.starts(with: p) { didFind = 0 }
                } else if p.count <= t.count {
                    didFind = (0...(t.count - p.count)).first { Array(t[$0..<($0 + p.count)]) == p }
                }
                if let k = didFind {
                    stack.append(.text(Chain(Array(t[(k + p.count)...])), executable: false))
                    stack.append(.text(Chain(p), executable: false))
                    if name == "search" { stack.append(.text(Chain(Array(t[..<k])), executable: false)) }
                    stack.append(.bool(true))
                } else {
                    stack += [.text(target, executable: false), .bool(false)]
                }
            case "token":
                let a = try pop()
                guard case .text(let c, _) = a else { stack.append(.bool(false)); break }
                let sub = FontChoice(c.b, start: 0, end: c.b.count)
                guard let t = sub.token() else { stack.append(.bool(false)); break }
                var value: Value = .null
                switch t {
                case .value(let v):
                    if case .list(_, true) = v { value = .list(procedure(of: sub), executable: true) } else { value = v }
                case .immediate(let n): value = discover(n) ?? .null
                case .closesProcedure: break
                }
                stack += [.text(Chain(Array(c.b[sub.i...])), executable: false), value, .bool(true)]

            // System
            case "bind":
                guard case .list(let l, _) = stack.last else { break }
                turnOn(l, level: 0)
            case "version": stack.append(.text(Chain(Array("3011".utf8)), executable: false))
            case "languagelevel": stack.append(.int(3))
            case "product": stack.append(.text(Chain(Array("Cutline".utf8)), executable: false))
            case "revision", "serialnumber", "realtime", "usertime": stack.append(.int(0))
            case "vmstatus": stack += [.int(0), .int(0), .int(100_000_000)]
            case "vmreclaim", "setvmthreshold", "setglobal", "setpacking": _ = try pop()
            case "currentglobal", "currentpacking": stack.append(.bool(false))
            case "gcheck": _ = try pop(); stack.append(.bool(false))
            case "internaldict": _ = try pop(); stack.append(.dictionary(PSDictionary()))

            // Graphics state
            case "gsave": graphicsStack.append(g.copy())
            case "grestore": if let previous = graphicsStack.popLast() { g = previous }
            case "grestoreall": if let first = graphicsStack.first { g = first; graphicsStack.removeAll() }
            case "save":
                graphicsStack.append(g.copy())
                stack.append(.saved(graphicsStack.count))
            case "restore":
                guard case .saved(let level) = try pop() else { throw Fault.kind }
                if level >= 1, level <= graphicsStack.count {
                    g = graphicsStack[level - 1]
                    graphicsStack.removeSubrange((level - 1)...)
                }
            case "initgraphics": g = Graphic()
            case "setlinewidth": g.strokeWidth = abs(try num())
            case "currentlinewidth": stack.append(.real(g.strokeWidth))
            case "setlinecap", "setlinejoin", "setmiterlimit", "setflat", "setstrokeadjust", "setoverprint", "setsmoothness",
                 "settransfer", "setblackgeneration", "setundercolorremoval", "sethalftone", "setcolorrendering":
                _ = try pop()
            case "currentlinecap", "currentlinejoin": stack.append(.int(0))
            case "currentmiterlimit": stack.append(.real(10))
            case "currentflat": stack.append(.real(1))
            case "currentstrokeadjust", "currentoverprint": stack.append(.bool(false))
            case "setdash": _ = try pop(); _ = try pop()
            case "currentdash": stack += [.list(PSArray([]), executable: false), .int(0)]
            case "setscreen": _ = try numbersOrAny(3)
            case "setcolorscreen": _ = try numbersOrAny(12)
            case "setcolortransfer": _ = try numbersOrAny(4)
            case "currentscreen": stack += [.real(60), .real(45), .list(PSArray([]), executable: true)]
            case "currenttransfer", "currentblackgeneration", "currentundercolorremoval": stack.append(.list(PSArray([]), executable: true))
            case "currentcolortransfer": for _ in 0..<4 { stack.append(.list(PSArray([]), executable: true)) }
            case "currenthalftone", "currentcolorrendering": stack.append(.dictionary(PSDictionary()))
            case "setgray":
                g.space = .gray
                g.color = VectorImporter.color([try num()])
            case "currentgray": stack.append(.real(1 - (g.color?.k ?? 0) / 100))
            case "setrgbcolor":
                g.space = .rgb
                g.color = VectorImporter.color(try numbers(3))
            case "currentrgbcolor": stack += [.real(0), .real(0), .real(0)]
            case "setcmykcolor":
                g.space = .cmyk
                g.color = VectorImporter.color(try numbers(4))
            case "currentcmykcolor":
                let c = g.color ?? CMYK(c: 0, m: 0, y: 0, k: 0)
                stack += [.real(c.c / 100), .real(c.m / 100), .real(c.y / 100), .real(c.k / 100)]
            case "sethsbcolor":
                let v = try numbers(3)
                let (h, s, b) = (v[0] * 6, v[1], v[2])
                let i = Int(h.rounded(.down)) % 6, f = h - h.rounded(.down)
                let p = b * (1 - s), q = b * (1 - s * f), t = b * (1 - s * (1 - f))
                let rgb: [Double] = [[b, t, p], [q, b, p], [p, b, t], [p, q, b], [t, p, b], [b, p, q]][max(i, 0)]
                g.space = .rgb
                g.color = VectorImporter.color(rgb)
            case "currenthsbcolor": stack += [.real(0), .real(0), .real(0)]
            case "setcolorspace": setSpacing(space(of: try pop()))
            case "currentcolorspace": stack.append(.list(PSArray([.name("DeviceGray", executable: false)]), executable: false))
            case "setcolor":
                if case .defaultValue = g.space {
                    _ = try pop()
                    g.color = CMYK(c: 0, m: 0, y: 0, k: 50)
                } else {
                    g.color = resolver(g.space, try numbers(g.space.components))
                }
            case "currentcolor": stack.append(.real(0))
            case "setpattern":
                _ = try pop()
                g.space = .defaultValue
                g.color = CMYK(c: 0, m: 0, y: 0, k: 50)
            case "makepattern":
                _ = try pop()
                let d = try pop()
                stack.append(d)

            // Matrices
            case "matrix": stack.append(.list(PSArray(Self.list(.identity)), executable: false))
            case "identmatrix", "defaultmatrix":
                let l = try list()
                l.v = Self.list(.identity)
                stack.append(.list(l, executable: false))
            case "currentmatrix":
                let l = try list()
                l.v = Self.list(g.ctm)
                stack.append(.list(l, executable: false))
            case "setmatrix": g.ctm = try Self.matrix(try list())
            case "initmatrix": g.ctm = .identity
            case "concat": g.ctm = try Self.matrix(try list()).concatenating(g.ctm)
            case "concatmatrix":
                let destination = try list(), b = try Self.matrix(try list()), a = try Self.matrix(try list())
                destination.v = Self.list(a.concatenating(b))
                stack.append(.list(destination, executable: false))
            case "invertmatrix":
                let destination = try list(), a = try Self.matrix(try list())
                destination.v = Self.list(a.inverted())
                stack.append(.list(destination, executable: false))
            case "translate", "scale", "rotate":
                let m = matrixOnTop()
                let t: CGAffineTransform
                if name == "rotate" {
                    t = CGAffineTransform(rotationAngle: try num() * .pi / 180)
                } else {
                    let y = try num(), x = try num()
                    t = name == "translate" ? CGAffineTransform(translationX: x, y: y) : CGAffineTransform(scaleX: x, y: y)
                }
                if let m {
                    m.v = Self.list(t)
                    stack.append(.list(m, executable: false))
                } else {
                    g.ctm = t.concatenating(g.ctm)
                }
            case "transform", "itransform", "dtransform", "idtransform":
                let m = try matrixOnTop().map(Self.matrix) ?? g.ctm
                let y = try num(), x = try num()
                let t = name.hasPrefix("i") ? m.inverted() : m
                let p = name.contains("d")
                    ? CGPoint(x: x * t.a + y * t.c, y: x * t.b + y * t.d)
                    : CGPoint(x: x, y: y).applying(t)
                stack += [.real(p.x), .real(p.y)]

            // Path
            case "newpath": newPath()
            case "moveto":
                let v = try numbers(2)
                g.shapePath.move(to: point(v[0], v[1]))
            case "rmoveto":
                let v = try numbers(2), p = try currentUserPoint()
                g.shapePath.move(to: point(p.x + v[0], p.y + v[1]))
            case "lineto":
                let v = try numbers(2)
                guard !g.shapePath.isEmpty else { throw Fault.interval }
                g.shapePath.addLine(to: point(v[0], v[1]))
            case "rlineto":
                let v = try numbers(2), p = try currentUserPoint()
                g.shapePath.addLine(to: point(p.x + v[0], p.y + v[1]))
            case "curveto":
                let v = try numbers(6)
                guard !g.shapePath.isEmpty else { throw Fault.interval }
                g.shapePath.addCurve(to: point(v[4], v[5]), control1: point(v[0], v[1]), control2: point(v[2], v[3]))
            case "rcurveto":
                let v = try numbers(6), p = try currentUserPoint()
                g.shapePath.addCurve(to: point(p.x + v[4], p.y + v[5]), control1: point(p.x + v[0], p.y + v[1]),
                                   control2: point(p.x + v[2], p.y + v[3]))
            case "closepath": if !g.shapePath.isEmpty { g.shapePath.closeSubpath() }
            case "arc", "arcn":
                let v = try numbers(5)
                guard v[2] > 0 else { break }
                g.shapePath.addArc(center: CGPoint(x: v[0], y: v[1]), radius: v[2], startAngle: v[3] * .pi / 180,
                                 endAngle: v[4] * .pi / 180, clockwise: name == "arcn", transform: g.ctm)
            case "arct", "arcto":
                let v = try numbers(5)
                if g.shapePath.isEmpty { throw Fault.interval }
                g.shapePath.addArc(tangent1End: CGPoint(x: v[0], y: v[1]), tangent2End: CGPoint(x: v[2], y: v[3]), radius: v[4], transform: g.ctm)
                if name == "arcto" { stack += [.real(v[0]), .real(v[1]), .real(v[0]), .real(v[1])] }
            case "currentpoint":
                let p = try currentUserPoint()
                stack += [.real(p.x), .real(p.y)]
            case "pathbbox":
                let box = g.shapePath.isEmpty ? CGRect.zero : g.shapePath.boundingBoxOfPath.applying(g.ctm.inverted())
                stack += [.real(box.minX), .real(box.minY), .real(box.maxX), .real(box.maxY)]
            case "flattenpath", "reversepath", "strokepath": break
            case "clippath":
                g.shapePath = (g.clip?.path.mutableCopy()) ?? CGMutablePath()
                g.textInPath = false
            case "initclip": g.clip = nil
            case "clip": clipToPath(.winding)
            case "eoclip": clipToPath(.evenOdd)
            case "rectclip":
                let p = CGMutablePath()
                for r in try rectangles() { p.addRect(r, transform: g.ctm) }
                g.shapePath = p
                g.textInPath = false
                clipToPath(.winding)
                newPath()
            case "rectfill", "rectstroke":
                if name == "rectstroke" { _ = matrixOnTop() }
                let p = CGMutablePath()
                for r in try rectangles() { p.addRect(r, transform: g.ctm) }
                emit(p, strokeColor: name == "rectstroke" ? g.color : nil, fill: name == "rectfill" ? g.color : nil)
            case "fill", "eofill":
                emit(g.shapePath, strokeColor: nil, fill: g.color, evenOdd: name == "eofill")
                newPath()
            case "stroke":
                emit(g.shapePath, strokeColor: g.color, fill: nil)
                newPath()
            case "ufill", "ueofill", "ustroke": _ = try pop()
            case "shfill":
                let d = try dictionary()
                if let clip = g.clip { emit(clip.path, strokeColor: nil, fill: gradientColor(d)) }
            case "pathforall": for _ in 0..<4 { _ = try pop() }

            // Images
            case "image": try image(mask: false)
            case "imagemask": try image(mask: true)
            case "colorimage": try image(mask: false, colored: true)

            // Fonts and text
            case "findfont":
                let n = try pop()
                let d = PSDictionary()
                d["FontName"] = n
                d["FontType"] = .int(1)
                d["FontMatrix"] = .list(PSArray([.real(0.001), .real(0), .real(0), .real(0.001), .real(0), .real(0)]), executable: false)
                stack.append(.dictionary(d))
            case "scalefont":
                let s = try num()
                g.fontPointSize = s
            case "makefont": _ = try pop()
            case "setfont", "undefinefont": _ = try pop()
            case "currentfont", "rootfont": stack.append(.dictionary(PSDictionary()))
            case "definefont":
                let f = try pop()
                _ = try pop()
                stack.append(f)
            case "selectfont":
                g.fontPointSize = (try? num()) ?? 12
                _ = try pop()
            case "stringwidth":
                let c = try chain()
                stack += [.real(Double(c.b.count) * g.fontPointSize * 0.5), .real(0)]
            case "show", "charpath", "glyphshow":
                if name == "charpath" {
                    _ = try pop()
                    g.textInPath = true
                }
                _ = try pop()
                texts += 1
            case "ashow": _ = try pop(); _ = try numbers(2); texts += 1
            case "widthshow": _ = try pop(); _ = try numbers(3); texts += 1
            case "awidthshow": _ = try pop(); _ = try numbers(5); texts += 1
            case "xshow", "yshow", "xyshow", "kshow", "cshow": _ = try pop(); _ = try pop(); texts += 1
            case "setcachedevice": _ = try numbers(6)
            case "setcachedevice2": _ = try numbers(10)
            case "setcharwidth": _ = try numbers(2)
            case "findencoding":
                _ = try pop()
                stack.append(discover("StandardEncoding") ?? .null)
            case "setcachelimit": _ = try pop()

            // Resources
            case "findresource":
                let category = try pop(), key = try pop()
                if let v = features[category.key + "/" + key.key] { stack.append(v); break }
                if category.key == "Font" { stack.append(key); try op("findfont"); break }
                stack.append(.dictionary(PSDictionary()))
            case "defineresource":
                let category = try pop(), instance = try pop(), key = try pop()
                features[category.key + "/" + key.key] = instance
                stack.append(instance)
            case "undefineresource": _ = try pop(); _ = try pop()
            case "resourcestatus": _ = try pop(); _ = try pop(); stack.append(.bool(false))
            case "resourceforall": for _ in 0..<4 { _ = try pop() }

            // Files (the program itself)
            case "currentfile": stack.append(.file(currentFile))
            case "readstring", "readhexstring":
                let c = try chain()
                guard case .file(let a) = try pop() else { throw Fault.kind }
                var readOnes: [UInt8] = []
                readOnes.reserveCapacity(c.b.count)
                while readOnes.count < c.b.count {
                    if name == "readhexstring" {
                        var tall: UInt8?, pair: UInt8?
                        while let x = a.readByte() {
                            guard let v = FontChoice.hex(x) else { if x == 62 { break } else { continue } }
                            if let h = tall { pair = h << 4 | v; break }
                            tall = v
                        }
                        guard let pair else { break }
                        readOnes.append(pair)
                    } else {
                        guard let x = a.readByte() else { break }
                        readOnes.append(x)
                    }
                }
                c.b.replaceSubrange(0..<readOnes.count, with: readOnes)
                stack += [.text(Chain(readOnes), executable: false), .bool(readOnes.count == c.b.count)]
            case "readline":
                let c = try chain()
                guard case .file(let a) = try pop() else { throw Fault.kind }
                if case .font = a.kind, let line = a.font.readLine() {
                    stack += [.text(Chain(line), executable: false), .bool(true)]
                } else {
                    var line: [UInt8] = [], didFind = false
                    while let x = a.readByte() {
                        didFind = true
                        if x == 10 || x == 13 { break }
                        line.append(x)
                    }
                    stack += [.text(Chain(line), executable: false), .bool(didFind)]
                }
            case "read":
                guard case .file(let a) = try pop() else { throw Fault.kind }
                if let x = a.readByte() { stack += [.int(Int(x)), .bool(true)] } else { stack.append(.bool(false)) }
            case "flushfile", "closefile":
                guard case .file(let a) = try pop() else { break }
                if case .font = a.kind { if name == "flushfile" { break } } else { a.skip(bytes: 0) }
            case "filter":
                guard case .name(let kind, _) = try pop() else { throw Fault.kind }
                if case .dictionary = stack.last { stack.removeLast() }
                var count = 0, mark: [UInt8] = []
                if kind == "SubFileDecode" {
                    mark = try chain().b
                    count = try integer()
                }
                let origin = try pop()
                let base: DocumentFile? = if case .file(let a) = origin { a } else { nil }
                let t: DocumentFile.ResourceKind = switch kind {
                case "ASCII85Decode": .ascii85
                case "ASCIIHexDecode": .asciiHex
                case "SubFileDecode": .subFile(count: count, end: mark)
                default: .other
                }
                stack.append(.file(DocumentFile(font: font, kind: t, base: base ?? currentFile)))
            case "eexec":
                _ = try pop()
                font.skipEexec()
            case "bytesavailable": _ = try pop(); stack.append(.int(-1))
            case "status": _ = try pop(); stack.append(.bool(true))
            case "file": _ = try pop(); _ = try pop(); throw Fault.kind
            case "run", "print", "=", "==", "echo", "setfileposition": _ = try pop()
            case "write", "writestring": _ = try pop(); _ = try pop()
            case "fileposition": _ = try pop(); stack.append(.int(0))
            case "stack", "pstack", "flush": break

            // Page
            case "setpagedevice": _ = try pop()
            case "currentpagedevice":
                let d = PSDictionary()
                d["PageSize"] = .list(PSArray([.real(612), .real(792)]), executable: false)
                stack.append(.dictionary(d))
            case "showpage", "copypage", "erasepage", "nulldevice": break

            default:
                unknownOnes[name, default: 0] += 1
                throw Fault.undefined(name)
            }
        }

        /// Pops `n` values (of any type).
        private func numbersOrAny(_ n: Int) throws -> [Value] {
            guard stack.count >= n else { throw Fault.emptyStack }
            let v = Array(stack.suffix(n))
            stack.removeLast(n)
            return v
        }

        /// Operands of rectfill/rectstroke/rectclip: x y w h or an array of numbers.
        private func rectangles() throws -> [CGRect] {
            if case .list(let l, _) = stack.last {
                stack.removeLast()
                let v = l.v.compactMap(\.number)
                return stride(from: 0, to: v.count - 3, by: 4).map { CGRect(x: v[$0], y: v[$0 + 1], width: v[$0 + 2], height: v[$0 + 3]) }
            }
            let v = try numbers(4)
            return [CGRect(x: v[0], y: v[1], width: v[2], height: v[3])]
        }

        /// bind: names that are already operators become the operator itself (also in nested procedures).
        private func turnOn(_ l: PSArray, level: Int) {
            guard level < 50 else { return }
            for (i, item) in l.v.enumerated() {
                switch item {
                case .name(let n, true): if case .op = discover(n) { l.v[i] = discover(n)! }
                case .list(let internalOne, true): turnOn(internalOne, level: level + 1)
                default: break
                }
            }
        }

        // MARK: AGM dialect (Illustrator 9 onward)

        private func agmOperator(_ name: String) throws -> Bool {
            switch name {
            case "mo": try op("moveto")
            case "li": try op("lineto")
            case "cv": try op("curveto")
            case "cp": try op("closepath")
            case "np": newPath()
            case "f", "ef":
                emit(g.shapePath, strokeColor: nil, fill: g.color, evenOdd: name == "ef")
                newPath()
            case "@":
                emit(g.shapePath, strokeColor: g.color, fill: nil)
                newPath()
            // As in AGM's prolog: clp = clip newpath, eclp = eoclip newpath, nclp = newpath clip (clips everything away).
            case "clp", "eclp":
                clipToPath(name == "eclp" ? .evenOdd : .winding)
                newPath()
            case "nclp":
                newPath()
                clipToPath(.winding)
            case "ct": try op("concat")
            case "pgsv": try op("gsave")
            case "pgrs": try op("grestore")
            case "sop", "sadj", "lc", "lj", "ml": _ = try pop()
            case "lw": try op("setlinewidth")
            case "dsh": try op("setdash")
            case "gry": try op("setgray")
            case "rgb": try op("setrgbcolor")
            case "cmyk", "nzopmsc": try op("setcmykcolor")
            case "sepcs", "devncs", "idxcs", "csacrd":
                // AGM passes a dictionary (Name, CSA, TintTransform or Components) instead of PostScript's array.
                let v = try pop()
                guard case .dictionary(let d) = v else { setSpacing(space(of: v)); break }
                let alternative = csaSpace(d["CSA"]) ?? .cmyk
                if name == "csacrd" { setSpacing(alternative); break }
                let transform = d["TintTransform"] ?? d["TintProc"]
                let hasProc = if case .list(_, true) = transform { true } else { false }
                if name == "devncs" {
                    var n = 1
                    if case .list(let names, _) = d["Names"] { n = max(names.v.count, 1) }
                    setSpacing(hasProc ? .deviceN(n: n, alternative: alternative, transform: transform!) : alternative)
                } else if name == "sepcs" {
                    let full: [Double] = if case .list(let l, _) = d["Components"] { l.v.compactMap(\.number) } else { [] }
                    let colorName = d["Name"]?.key ?? ""
                    setSpacing(hasProc ? .separation(name: colorName, alternative: alternative, transform: transform!)
                                  : .ink(name: colorName, full: full, alternative: alternative))
                } else {
                    setSpacing(alternative)
                }
            case "sep", "devn", "idx", "colr": try op("setcolor")
            case "level3": stack.append(.bool(true))
            case "add_res":
                let category = try pop(), value = try pop(), key = try pop()
                features[category.key + "/" + key.key] = value
            case "get_res":
                let category = try pop(), key = try pop()
                stack.append(features[category.key + "/" + key.key] ?? .null)
            case "del_res": _ = try pop()
            case "clonedict":
                let d = try dictionary(), copy = PSDictionary()
                copy.d = d.d
                stack.append(.dictionary(copy))
            case "gx":
                let key = try pop(), d = try pop()
                if case .dictionary(let dict) = d, let v = dict[key.key] { try execute(v) }
            case "cf": try op("currentfile")
            case "fl": try op("filter")
            case "rs": try op("readstring")
            default: return false
            }
            return true
        }

        /// Color space of an AGM CSA resource (the resource name or the array itself).
        private func csaSpace(_ v: Value?) -> ColorSpaceKind? {
            guard let v else { return nil }
            if case .name(let n, _) = v, let feature = features["CSA/" + n] { return space(of: feature) }
            if case .list = v { return space(of: v) }
            if case .name = v { return space(of: v) }
            return nil
        }

        // MARK: Classic AI dialect (up to Illustrator 8)

        private func aiOperator(_ name: String) throws -> Bool {
            switch name {
            case "m": try op("moveto")
            case "l", "L": try op("lineto")
            case "c", "C": try op("curveto")
            case "v", "V":
                let v = try numbers(4)
                guard !g.shapePath.isEmpty else { throw Fault.interval }
                g.shapePath.addCurve(to: point(v[2], v[3]), control1: g.shapePath.currentPoint, control2: point(v[0], v[1]))
            case "y", "Y":
                let v = try numbers(4)
                guard !g.shapePath.isEmpty else { throw Fault.interval }
                let end = point(v[2], v[3])
                g.shapePath.addCurve(to: end, control1: point(v[0], v[1]), control2: end)
            case "N": paintAIPath(close: false, fillDemo: false, trace: false)
            case "n": paintAIPath(close: true, fillDemo: false, trace: false)
            // As in Illustrator's procset: h only closes the path, H does nothing (neither paints nor ends the path).
            case "h": if !g.shapePath.isEmpty { g.shapePath.closeSubpath() }
            case "H": break
            case "F": paintAIPath(close: false, fillDemo: true, trace: false)
            case "f": paintAIPath(close: true, fillDemo: true, trace: false)
            case "S": paintAIPath(close: false, fillDemo: false, trace: true)
            case "s": paintAIPath(close: true, fillDemo: false, trace: true)
            case "B": paintAIPath(close: false, fillDemo: true, trace: true)
            case "b": paintAIPath(close: true, fillDemo: true, trace: true)
            case "*u": compound = (CGMutablePath(), false, false)
            case "*U":
                if let c = compound {
                    compound = nil
                    emit(c.shapePath, strokeColor: c.trace ? g.strokeColor : nil, fill: c.fillDemo ? g.fill : nil, evenOdd: aiEvenOdd)
                    if aiClip {
                        let path = g.shapePath
                        g.shapePath = c.shapePath
                        clipToPath(aiEvenOdd ? .evenOdd : .winding)
                        g.shapePath = path
                        aiClip = false
                    }
                }
            // Clip group: q and Q are gsave and grestore in Illustrator's procset (not inside a compound path).
            case "q": if compound == nil { graphicsStack.append(g.copy()) }
            case "Q": if compound == nil, let previous = graphicsStack.popLast() { g = previous }
            case "W": aiClip = true
            case "XR": aiEvenOdd = try num() != 0
            case "u", "U", "LB": break
            case "D", "A", "O", "R", "J", "j", "M", "Ar", "i", "Ln": _ = try pop()
            case "w": try op("setlinewidth")
            case "d": _ = try pop(); _ = try pop()
            case "g": g.fill = VectorImporter.color([try num()])
            case "G": g.strokeColor = VectorImporter.color([try num()])
            case "k": g.fill = VectorImporter.color(try numbers(4))
            case "K": g.strokeColor = VectorImporter.color(try numbers(4))
            case "x", "X":
                // c m y k (name) tint: tint 0 is the full color.
                let ink = try num()
                _ = try pop()
                let v = try numbers(4)
                let color = VectorImporter.color(v.map { $0 * (1 - ink) })
                if name == "x" { g.fill = color } else { g.strokeColor = color }
            case "Xa", "XA":
                let color = VectorImporter.color(try numbers(3))
                if name == "Xa" { g.fill = color } else { g.strokeColor = color }
            case "Xx", "XX", "Xk", "XK":
                // c m y k (name) tint 0, or r g b (name) tint 1.
                let kind = try integer(), ink = try num()
                _ = try pop()
                let v = try numbers(kind == 1 ? 3 : 4)
                let color = kind == 1 ? VectorImporter.color(v.map { 1 - (1 - $0) * (1 - ink) }) : VectorImporter.color(v.map { $0 * (1 - ink) })
                if name == "Xx" || name == "Xk" { g.fill = color } else { g.strokeColor = color }
            case "p", "P":
                // Pattern fill or stroke: a middle gray.
                stack.removeAll()
                if name == "p" { g.fill = CMYK(c: 0, m: 0, y: 0, k: 50) } else { g.strokeColor = CMYK(c: 0, m: 0, y: 0, k: 50) }
            case "To":
                texts += 1
                stack.removeAll()
            case "XI", "XG":
                images += 1
                stack.removeAll()
            default: return false
            }
            return true
        }
    }
}
