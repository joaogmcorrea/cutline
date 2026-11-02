// Reading Silhouette Studio's .studio3 files (a closed format, with no public documentation).
// Structure deduced only from the files' data (interoperability), without using Studio's program. Writing
// (which rebuilds only the object list) is in Studio3Writer.swift.
//
// File: "silhouette05;" + 16 sizes (u64) from 0x10; the sections start at 0x400.
//   0 = document (object tree) · 1 = images (PNG) · 2 = 512 × 512 thumbnail
//   5/6 = last commands sent to the machine (GPGL with XOR 0xA9) · 9 = cut conditions (CSV)
// Document: blocks [marker u8][size u32, counted from the field itself]; lists store
// "count − 1". Object = body (type + style + data) + 3 × 3 matrix + box + path already on the
// page (cache) + name. Unit: mm; origin at the page's top-left corner, y down.
import CoreGraphics
import Foundation
import ImageIO

public struct StudioDocument: Sendable {
    public struct Color: Sendable, Hashable {
        public var red, green, blue, alpha: Double

        public init(red: Double, green: Double, blue: Double, alpha: Double) {
            (self.red, self.green, self.blue, self.alpha) = (red, green, blue, alpha)
        }

        /// "RRGGBB", as Studio names the line colors in its send panel.
        public var hex: String {
            let channel = { (v: Double) in Int((min(max(v, 0), 1) * 255).rounded()) }
            return String(format: "%02X%02X%02X", channel(red), channel(green), channel(blue))
        }
    }

    /// Bézier node in page mm; the control points are absolute (nil = no handle).
    public struct Node: Sendable, Equatable {
        public var point: CGPoint
        public var controlIn: CGPoint?
        public var controlOut: CGPoint?

        public init(point: CGPoint, controlIn: CGPoint? = nil, controlOut: CGPoint? = nil) {
            (self.point, self.controlIn, self.controlOut) = (point, controlIn, controlOut)
        }
    }

    public enum Fill: Sendable {
        case none
        case color(Color)
        /// `transform` takes the image pixel to page mm; the image is clipped by the outline.
        case image(key: String, transform: CGAffineTransform)
    }

    public struct Object: Sendable {
        /// Name in Studio: "Polygon", "Rectangle", "Ellipse", "Rounded Rectangle"…
        public var kind: String
        /// Subpaths always closed (the format doesn't mark open paths).
        public var subpaths: [[Node]]
        /// The line color defines the cut (as in Cutline).
        public var line: Color
        public var fill: Fill
        /// False when the object is marked not to cut in Studio (likely).
        public var cuts: Bool
        /// Where it is in the file's tree: the index in the top-level list and, inside groups, in the children.
        public var source: [Int] = []

        public var path: CGPath {
            let path = CGMutablePath()
            for nodes in subpaths where !nodes.isEmpty {
                path.move(to: nodes[0].point)
                for (i, a) in nodes.enumerated() {
                    let b = nodes[(i + 1) % nodes.count]
                    if a.controlOut == nil, b.controlIn == nil {
                        path.addLine(to: b.point)
                    } else {
                        path.addCurve(to: b.point, control1: a.controlOut ?? a.point, control2: b.controlIn ?? b.point)
                    }
                }
                path.closeSubpath()
            }
            return path
        }
    }

    public struct Image: Sendable {
        /// PNG or JPEG, as it came in the file.
        public var data: Data
        public var pixelWidth: Int
        public var pixelHeight: Int
    }

    /// Print & Cut registration marks, as Studio stores them in the page (mm).
    public struct RegistrationMarks: Sendable, Equatable {
        public init(on: Bool, left: Double, top: Double, right: Double, bottom: Double, length: Double, thickness: Double) {
            (self.on, self.left, self.top, self.right, self.bottom) = (on, left, top, right, bottom)
            (self.length, self.thickness) = (length, thickness)
        }

        /// On in the document (Studio reads the marks before cutting).
        public var on: Bool
        /// From the page edge to the marks' outer corner.
        public var left, top, right, bottom: Double
        /// Length of the corner marks and width of the lines.
        public var length, thickness: Double
    }

    public var pageSize: CGSize
    public var registrationMarks: RegistrationMarks?
    public var objects: [Object]
    public var images: [String: Image]
    /// Objects that couldn't be read (a type with no known outline, a missing image…).
    public var skipped: Int
    /// Line colors turned on (true) or off in Studio's send panel, by `Color.hex`.
    /// Only the colors the file stores show up.
    public var lineColorCuts: [String: Bool]

    public init(data: Data) throws {
        let file = Bytes(Array(data))
        guard file.count >= 0x400, file.starts(with: Self.magic) else { throw StudioError.notStudio }
        var sections: [Bytes] = []
        var offset = 0x400
        for i in 0..<16 {
            let size = try file.u64(0x10 + 8 * i)
            guard offset + size <= file.count else { throw StudioError.damaged("section \(i) runs past the end of the file") }
            sections.append(Bytes(Array(file.b[offset..<(offset + size)])))
            offset += size
        }
        let doc = sections[0]
        guard doc.starts(with: Self.magic) else { throw StudioError.damaged("document without a header") }

        let page = try? doc.pageSetup()
        pageSize = page?.size ?? CGSize(width: 210, height: 297)
        registrationMarks = page?.marks
        images = (try? sections[1].images()) ?? [:]
        objects = []
        skipped = 0
        lineColorCuts = doc.lineColorCuts()
        let raw = try doc.objectList(at: try doc.findObjectList())
        flatten(raw, in: doc, transform: .identity, path: [])
    }

    static let magic = Array("silhouette05;".utf8)

    /// Undoes the groups (composing the matrices) and takes everything to page mm.
    private mutating func flatten(_ list: [RawObject], in doc: Bytes, transform parent: CGAffineTransform, path: [Int]) {
        for (index, raw) in list.enumerated() {
            let t = raw.matrix.concatenating(parent)
            switch raw.type {
            case 5:   // grupo
                flatten(raw.children, in: doc, transform: t, path: path + [index])
                continue
            case 36:  // Studio's internal markers, with no drawing
                continue
            default:
                break
            }
            guard let style = try? doc.style(at: raw.base.lowerBound, limit: raw.base.upperBound) else {
                skipped += 1
                continue
            }
            let subpaths: [[Node]]
            if raw.type == 1 || raw.type == 2 {
                // 1 = tool shape (rectangle, ellipse), 2 = polygon/path: local outline × matrix.
                guard let local = try? doc.localPath(at: raw.base.upperBound, limit: raw.bodyEnd) else {
                    skipped += 1
                    continue
                }
                subpaths = local.map { nodes in
                    nodes.map { n in
                        Node(point: n.point.applying(t),
                             controlIn: n.controlIn.map { CGPoint(x: n.point.x + $0.x, y: n.point.y + $0.y).applying(t) },
                             controlOut: n.controlOut.map { CGPoint(x: n.point.x + $0.x, y: n.point.y + $0.y).applying(t) })
                    }
                }
            } else if let cache = raw.cache, let cached = try? doc.cachedPath(at: cache.lowerBound, limit: cache.upperBound) {
                // Other types (e.g. a rounded rectangle stores only parameters): the path Studio
                // left ready, already on the page. For types 1 and 2 it matches the computed one (< 0.0001 mm).
                subpaths = cached
            } else {
                skipped += 1
                continue
            }
            guard subpaths.contains(where: { !$0.isEmpty }) else { continue }
            var fill = Fill.none
            switch style.fill {
            case .none: break
            case .color(let c): fill = .color(c)
            case .image(let key, let toLocal):
                if images[key] != nil { fill = .image(key: key, transform: toLocal.concatenating(t)) }
            }
            objects.append(Object(kind: raw.name, subpaths: subpaths, line: style.line, fill: fill, cuts: raw.flag != 1,
                                  source: path + [index]))
        }
    }
}

public enum StudioError: Error, LocalizedError, Equatable {
    case notStudio
    case damaged(String)

    public var errorDescription: String? {
        switch self {
        case .notStudio: localized("The file isn’t a Silhouette Studio document (.studio3).")
        case .damaged(let detail): localized("The Silhouette Studio file couldn’t be read (\(detail)).")
        }
    }
}

// MARK: - Reading the bytes

/// Object as it is in the file, before flattening groups and applying matrices.
struct RawObject {
    /// The whole object in the document.
    var range: Range<Int>
    var type: UInt8
    /// Base block (type + style); the type's own content comes right after, up to `bodyEnd`.
    var base: Range<Int>
    var bodyEnd: Int
    var matrix: CGAffineTransform
    /// 1 for objects that don't cut (background, pieces off the page…), 2 for the others.
    var flag: Int
    var cache: Range<Int>?
    var name: String
    var children: [RawObject]
}

struct LocalNode {
    var point: CGPoint
    /// Handles relative to the point.
    var controlIn: CGPoint?
    var controlOut: CGPoint?
}

enum RawFill {
    case none
    case color(StudioDocument.Color)
    /// Image pixel → the object's local coordinates.
    case image(key: String, toLocal: CGAffineTransform)
}

struct Bytes {
    let b: [UInt8]
    init(_ b: [UInt8]) { self.b = b }

    var count: Int { b.count }

    func starts(with prefix: [UInt8]) -> Bool { b.count >= prefix.count && Array(b[0..<prefix.count]) == prefix }

    func check(_ o: Int, _ n: Int) throws {
        guard o >= 0, n >= 0, o + n <= b.count else { throw StudioError.damaged("read out of bounds at \(o)") }
    }

    func u8(_ o: Int) throws -> UInt8 {
        try check(o, 1)
        return b[o]
    }

    func u32(_ o: Int) throws -> Int {
        try check(o, 4)
        return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
    }

    func u64(_ o: Int) throws -> Int {
        try check(o, 8)
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(b[o + i]) << (8 * UInt64(i)) }
        guard v <= UInt64(Int32.max) else { throw StudioError.damaged("invalid size at \(o)") }
        return Int(v)
    }

    func f32(_ o: Int) throws -> Double { Double(Float(bitPattern: UInt32(try u32(o)))) }

    func color(_ o: Int) throws -> StudioDocument.Color {
        StudioDocument.Color(red: try f32(o), green: try f32(o + 4), blue: try f32(o + 8), alpha: try f32(o + 12))
    }

    /// String with a u32 size in front; also returns where it ends.
    func string(_ o: Int) throws -> (String, Int) {
        let n = try u32(o)
        try check(o + 4, n)
        return (String(decoding: b[(o + 4)..<(o + 4 + n)], as: UTF8.self), o + 4 + n)
    }

    /// Block [marker][size u32]: returns the end (exclusive). The size counts from the field itself.
    func block(_ o: Int, marker: UInt8 = 1, limit: Int) throws -> Int {
        guard try u8(o) == marker else { throw StudioError.damaged("block expected at \(o)") }
        let end = o + 1 + (try u32(o + 1))
        guard end >= o + 5, end <= limit else { throw StudioError.damaged("block with an invalid size at \(o)") }
        return end
    }

    /// 3 × 3 matrix by rows (x' = m0·x + m1·y + m2; y' = m3·x + m4·y + m5).
    func matrix(_ o: Int) throws -> CGAffineTransform {
        let m = try (0..<9).map { try f32(o + 4 * $0) }
        return CGAffineTransform(a: m[0], b: m[3], c: m[1], d: m[4], tx: m[2], ty: m[5])
    }

    func firstIndex(of pattern: [UInt8], from start: Int = 0, to end: Int? = nil) -> Int? {
        let endPos = min(end ?? b.count, b.count) - pattern.count
        guard start <= endPos else { return nil }
        for i in start...endPos where b[i] == pattern[0] && b[i..<(i + pattern.count)].elementsEqual(pattern) { return i }
        return nil
    }

    // MARK: Document (section 0)

    /// Where the page fields start: in the header's second block, after the base's 60-byte block
    /// and the paper size name (a string, empty in the files seen).
    func pageFields() throws -> Int {
        let doc = try block(13, limit: count)
        let first = try block(18, limit: doc)
        _ = try block(first, limit: doc)
        return try string(first + 5).1
    }

    /// Page (the same Studio reads, in order): [u8 marks on] [f32 margins left, top, right,
    /// bottom] [i32] [i32] [f32 length] [f32 thickness] [f32 border] [f32 width] [f32 height].
    func pageSetup() throws -> (size: CGSize, marks: StudioDocument.RegistrationMarks) {
        let p = try pageFields()
        let size = CGSize(width: try f32(p + 37), height: try f32(p + 41))
        guard (10...3000).contains(size.width), (10...3000).contains(size.height) else {
            throw StudioError.damaged("unexpected page size")
        }
        let marks = StudioDocument.RegistrationMarks(
            on: try u8(p) != 0, left: try f32(p + 1), top: try f32(p + 5), right: try f32(p + 9), bottom: try f32(p + 13),
            length: try f32(p + 25), thickness: try f32(p + 29))
        return (size, marks)
    }

    /// Cuts by line color: ["@line:RRGGBB"][16–64 character string (material)][u8 on].
    func lineColorCuts() -> [String: Bool] {
        let markerBytes = Array("@line:".utf8)
        var colors: [String: Bool] = [:]
        var i = 4
        while let j = firstIndex(of: markerBytes, from: i) {
            i = j + 1
            guard (try? u32(j - 4)) == 12, j + 16 <= count else { continue }
            let hex = String(decoding: b[(j + 6)..<(j + 12)], as: UTF8.self)
            guard hex.allSatisfy(\.isHexDigit), let n = try? u32(j + 12), (16...64).contains(n), j + 16 + n < count,
                  b[(j + 16)..<(j + 16 + n)].allSatisfy({ (0x30..<0x7F).contains($0) }), b[j + 16 + n] <= 1 else { continue }
            colors[hex.uppercased()] = b[j + 16 + n] == 1
        }
        return colors
    }

    /// The object list comes after the document settings, which end with "auto", "auto".
    func findObjectList() throws -> Int {
        let auto = Array("auto".utf8)
        let markerBytes = [4, 0, 0, 0] + auto + [4, 0, 0, 0] + auto
        if let i = firstIndex(of: markerBytes, to: 1 << 16), (try? objectList(at: i + markerBytes.count)) != nil {
            return i + markerBytes.count
        }
        // Plan B: the first block from the start of the file that reads whole as an object list.
        for p in 18..<min(count, 1 << 16) where b[p] == 1 {
            if (try? objectList(at: p)) != nil { return p }
        }
        throw StudioError.damaged("object list not found")
    }

    func objectList(at p: Int, limit: Int? = nil, depth: Int = 0) throws -> [RawObject] {
        guard depth < 64 else { throw StudioError.damaged("groups nested too deeply") }
        let end = try block(p, limit: limit ?? count)
        let itemCount = (try u32(p + 5) + 1) & 0xFFFF_FFFF
        var rawObjects: [RawObject] = []
        var q = p + 9
        while q < end {
            let (rawObject, endPos) = try object(at: q, limit: end, depth: depth)
            rawObjects.append(rawObject)
            q = endPos
        }
        guard q == end, rawObjects.count == itemCount else { throw StudioError.damaged("inconsistent object list at \(p)") }
        return rawObjects
    }

    func object(at p: Int, limit: Int, depth: Int) throws -> (RawObject, Int) {
        let end = try block(p, limit: limit)
        let q = p + 6                                   // [01][size][u8]
        let bodyEnd = try block(q, limit: end)
        let type = try u8(q + 5)
        let baseEnd = q + 6 + (try u32(q + 6))          // [type][size]
        guard baseEnd <= bodyEnd else { throw StudioError.damaged("inconsistent object at \(p)") }
        let children = type == 5 ? try objectList(at: baseEnd, limit: bodyEnd, depth: depth + 1) : []
        let matrix = try matrix(bodyEnd)
        var k = bodyEnd + 36 + 24                       // matriz + caixa (centro e semieixos)
        let flag = try u32(k)
        k += 5
        var cache: Range<Int>?
        if try u8(k) == 1 {
            let endPos = try block(k, limit: end)
            cache = k..<endPos
            k = endPos
        } else {
            k += 1
        }
        // [01 id][u32][01 size 12 …][name]
        var name = ""
        if (try? u8(k)) == 1, (try? u8(k + 9)) == 1, let endPos = try? block(k + 9, limit: end) {
            name = (try? string(endPos).0) ?? ""
        }
        return (RawObject(range: p..<end, type: type, base: (q + 5)..<baseEnd, bodyEnd: bodyEnd, matrix: matrix, flag: flag,
                          cache: cache, name: name, children: children), end)
    }

    /// Style in the base block: line color, cut style, join/cap and fill.
    func style(at base: Int, limit: Int) throws -> (line: StudioDocument.Color, fill: RawFill) {
        let st = base + 6                               // [type][size][u8] → style block
        let endPos = try block(st, limit: limit)
        let line = try color(st + 7)
        var k = try block(st + 31, limit: endPos)          // cut style ("cut", "Cut", "0", color)
        k += 1
        k = try string(k).1                             // join ("rounded")
        if try u8(k) == 1 { k = try string(k + 1).1 } else { k += 1 }   // ponta
        let styleKind = try u8(k)
        switch styleKind {
        case 0:
            return (line, .none)
        case 1:
            return (line, .color(try color(k + 1)))
        case 5:
            let (key, afterString) = try string(k + 1)
            // Three matrices after [01 00 01]: the 2nd takes the image pixel to the object.
            guard let j = firstIndex(of: [1, 0, 1], from: afterString, to: endPos), try u8(j + 39) == 1 else {
                throw StudioError.damaged("image position not found")
            }
            return (line, .image(key: key, toLocal: try matrix(j + 40)))
        default:
            return (line, .none)
        }
    }

    /// Outline in local coordinates: [01 size][u32 subpaths − 1] { [01 size][01 points − 1] { [01 size] x y handles flags } }.
    func localPath(at p: Int, limit: Int) throws -> [[LocalNode]] {
        let end = try block(p, limit: limit)
        let itemCount = try u32(p + 5) + 1
        var q = p + 9
        var subpathList: [[LocalNode]] = []
        for _ in 0..<itemCount {
            let subEnd = try block(q, limit: end)
            q += 5
            guard try u8(q) == 1 else { throw StudioError.damaged("invalid subpath at \(q)") }
            let pointCount = try u32(q + 1) + 1
            q += 5
            var nodeList: [LocalNode] = []
            nodeList.reserveCapacity(pointCount)
            for _ in 0..<pointCount {
                let pointEnd = try block(q, limit: subEnd)
                var x = q + 5
                let pt = CGPoint(x: try f32(x), y: try f32(x + 4))
                x += 8
                let handleIn = try handle(&x), handleOut = try handle(&x)
                nodeList.append(LocalNode(point: pt, controlIn: handleIn, controlOut: handleOut))
                q = pointEnd
            }
            guard q == subEnd else { throw StudioError.damaged("inconsistent subpath at \(q)") }
            subpathList.append(nodeList)
        }
        guard q == end else { throw StudioError.damaged("inconsistent path at \(p)") }
        return subpathList
    }

    /// Path already on the page (without markers or per-point sizes): [01 size][u32 n − 1] { [u32 size][01 points − 1] { x y handles } }.
    func cachedPath(at p: Int, limit: Int) throws -> [[StudioDocument.Node]] {
        let end = try block(p, limit: limit)
        let itemCount = try u32(p + 5) + 1
        var q = p + 9
        var subpathList: [[StudioDocument.Node]] = []
        for _ in 0..<itemCount {
            let subEnd = q + (try u32(q))
            guard subEnd <= end, try u8(q + 4) == 1 else { throw StudioError.damaged("invalid subpath at \(q)") }
            let pointCount = try u32(q + 5) + 1
            q += 9
            var nodeList: [StudioDocument.Node] = []
            for _ in 0..<pointCount {
                let pt = CGPoint(x: try f32(q), y: try f32(q + 4))
                q += 8
                let handleIn = try handle(&q), handleOut = try handle(&q)
                nodeList.append(StudioDocument.Node(point: pt,
                                               controlIn: handleIn.map { CGPoint(x: pt.x + $0.x, y: pt.y + $0.y) },
                                               controlOut: handleOut.map { CGPoint(x: pt.x + $0.x, y: pt.y + $0.y) }))
            }
            guard q == subEnd else { throw StudioError.damaged("inconsistent subpath at \(q)") }
            subpathList.append(nodeList)
        }
        return subpathList
    }

    /// Optional handle: [00] or [01 dx dy].
    private func handle(_ o: inout Int) throws -> CGPoint? {
        switch try u8(o) {
        case 0:
            o += 1
            return nil
        case 1:
            let h = CGPoint(x: try f32(o + 1), y: try f32(o + 5))
            o += 9
            return h
        default:
            throw StudioError.damaged("invalid handle at \(o)")
        }
    }

    // MARK: Images (section 1)

    /// [01 size][u32][u64 n − 1] { [u64 size][u64 + key][…][u64 size][PNG/JPEG][…] }
    func images() throws -> [String: StudioDocument.Image] {
        guard count > 17 else { return [:] }
        let itemCount = try u64(9) + 1
        var q = 17
        var output: [String: StudioDocument.Image] = [:]
        for _ in 0..<itemCount {
            let endPos = q + (try u64(q))
            guard endPos > q, endPos <= count else { throw StudioError.damaged("inconsistent image at \(q)") }
            let keyLength = try u64(q + 8)
            try check(q + 16, keyLength)
            let imageKey = String(decoding: b[(q + 16)..<(q + 16 + keyLength)], as: UTF8.self)
            let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], jpeg: [UInt8] = [0xFF, 0xD8, 0xFF]
            if let startPos = firstIndex(of: png, from: q + 16, to: endPos) ?? firstIndex(of: jpeg, from: q + 16, to: endPos) {
                let byteCount = try u64(startPos - 8)
                if startPos + byteCount <= endPos {
                    let imageData = Data(b[startPos..<(startPos + byteCount)])
                    if let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
                       let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                       let width = props[kCGImagePropertyPixelWidth] as? Int,
                       let height = props[kCGImagePropertyPixelHeight] as? Int {
                        output[imageKey] = StudioDocument.Image(data: imageData, pixelWidth: width, pixelHeight: height)
                    }
                }
            }
            q = endPos
        }
        return output
    }
}
