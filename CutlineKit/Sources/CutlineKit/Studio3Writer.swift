// Writing a .studio3 over the original: rebuilds only the document's object list (section 0). The rest of the
// file — page settings, cuts by color, images, machine commands, JSONs — stays as it was, and the
// thumbnail can be replaced. An unchanged top-level object goes back with the same bytes. A changed one is rebuilt
// from itself (style, layer, id and code stay; outline, position, line color, fill and
// "doesn't cut" change), in a local system that follows the offset and the size (the clipped image goes along). A
// new one comes from a polygon of the file itself. The layer markers (type 36, "Layer 1"/"Layer 0") stay
// where they were; each object goes to the stretch between markers it came from.
import CoreGraphics
import Foundation

public enum StudioWriter {
    public enum Item: Sendable {
        /// A top-level object of the file, intact (by index).
        case original(Int)
        /// A new or changed object.
        case shape(Shape)
    }

    public enum FillChange: Sendable {
        /// The source object's fill (also the image).
        case keep
        case none
        case color(StudioDocument.Color)
    }

    public struct Shape: Sendable {
        /// Outlines in page mm (the format only has closed outlines).
        public var subpaths: [[StudioDocument.Node]]
        public var line: StudioDocument.Color
        public var fill: FillChange
        /// The source object's image fill: pixel → page mm.
        public var imageToPage: CGAffineTransform?
        public var cuts: Bool
        /// `StudioDocument.Object.source` of the object it came from; nil = new.
        public var source: [Int]?
        /// Copy of the `source` object (it stays in the file): same style and image, new id and code.
        public var copy: Bool
        /// Page → page: where the `source` object, as it is in the file, went (moved, stretched, turned). With it the local
        /// system is the source's matrix followed by this (a turn stays in the matrix, as Studio keeps it); without it, the
        /// source's box is stretched to the new one.
        public var sourceChange: CGAffineTransform?
        /// A new object's local system (its outline before a turn → page): the turn goes into the matrix. nil = the page.
        public var localToPage: CGAffineTransform?

        public init(subpaths: [[StudioDocument.Node]], line: StudioDocument.Color, fill: FillChange,
                    imageToPage: CGAffineTransform? = nil, cuts: Bool, source: [Int]? = nil, copy: Bool = false,
                    sourceChange: CGAffineTransform? = nil, localToPage: CGAffineTransform? = nil) {
            self.subpaths = subpaths
            self.line = line
            self.fill = fill
            self.imageToPage = imageToPage
            self.cuts = cuts
            self.source = source
            self.copy = copy
            self.sourceChange = sourceChange
            self.localToPage = localToPage
        }
    }

    public enum WriteError: Error, LocalizedError, Equatable {
        case unsupported(String)

        public var errorDescription: String? {
            switch self {
            case .unsupported(let detail): localized("This Silhouette Studio file can't be rewritten by Cutline (\(detail)).")
            }
        }
    }

    /// Can the file be rewritten (is the object list in its usual place)?
    public static func canWrite(_ original: Data) -> Bool {
        let file = Bytes(Array(original))
        guard file.count >= 0x400, file.starts(with: StudioDocument.magic), let byteCount = try? file.u64(0x10),
              0x400 + byteCount <= file.count else { return false }
        let doc = Bytes(Array(file.b[0x400..<(0x400 + byteCount)]))
        guard let start = doc.objectListAfterMarker(), let listEnd = try? doc.block(start, limit: doc.count),
              let documentEnd = try? doc.block(13, limit: doc.count) else { return false }
        return documentEnd >= listEnd
    }

    /// The new file; `thumbnail` (512 × 512 PNG) replaces the thumbnail and `marks`, the page's Print & Cut marks.
    public static func write(original: Data, items: [Item], thumbnail: Data? = nil,
                             marks: StudioDocument.RegistrationMarks? = nil) throws -> Data {
        try writeWithMap(original: original, items: items, thumbnail: thumbnail, marks: marks).data
    }

    /// The new file and, for each item, its index in the new file's top-level list (nil = not written).
    public static func writeWithMap(original: Data, items: [Item], thumbnail: Data? = nil,
                                    marks: StudioDocument.RegistrationMarks? = nil) throws -> (data: Data, indices: [Int?]) {
        let file = Bytes(Array(original))
        guard file.count >= 0x400, file.starts(with: StudioDocument.magic) else { throw StudioError.notStudio }
        var sections: [[UInt8]] = []
        var offset = 0x400
        for i in 0..<16 {
            let size = try file.u64(0x10 + 8 * i)
            guard offset + size <= file.count else { throw StudioError.damaged("section \(i) runs past the end of the file") }
            sections.append(Array(file.b[offset..<(offset + size)]))
            offset += size
        }
        guard offset == file.count else { throw WriteError.unsupported("data after the last section") }

        let doc = Bytes(sections[0])
        guard doc.starts(with: StudioDocument.magic), let start = doc.objectListAfterMarker() else {
            throw WriteError.unsupported("object list outside its usual place")
        }
        let listEnd = try doc.block(start, limit: doc.count)
        // The list is inside the document block (at 13); it's the only size that changes.
        let documentEnd = try doc.block(13, limit: doc.count)
        guard documentEnd >= listEnd else { throw WriteError.unsupported("list outside the document block") }
        let list = try doc.objectList(at: start)
        var assembler = Assembler(doc: doc, list: list)

        // Stretches between markers: each object goes to the one it came from; the new ones, to the last object's.
        var stretch = 0, stretchOf: [Int: Int] = [:], firstClosing: Int?
        for (i, raw) in list.enumerated() {
            if raw.type == 36 {
                if firstClosing == nil, raw.name == "Layer 0" { firstClosing = stretch }
                stretch += 1
            } else {
                stretchOf[i] = stretch
            }
        }
        let newObjectsStretch = stretchOf.max { $0.key < $1.key }?.value ?? firstClosing ?? 0
        var perStretch: [Int: [(item: Int, bytes: [UInt8])]] = [:]
        for (n, item) in items.enumerated() {
            switch item {
            case .original(let i):
                guard list.indices.contains(i), list[i].type != 36 else { throw WriteError.unsupported("object \(i) doesn’t exist") }
                perStretch[stretchOf[i]!, default: []].append((n, Array(doc.b[list[i].range])))
            case .shape(let shapeItem):
                guard shapeItem.subpaths.contains(where: { $0.count >= 2 }) else { continue }
                let destination = shapeItem.source.flatMap { $0.first }.flatMap { stretchOf[$0] } ?? newObjectsStretch
                perStretch[destination, default: []].append((n, try assembler.objectBytes(shapeItem)))
            }
        }

        var body: [UInt8] = []
        var current = 0, total = 0
        var indices = [Int?](repeating: nil, count: items.count)
        let flush = { (stretch: Int) in
            for (n, objectBytes) in perStretch[stretch] ?? [] {
                body += objectBytes
                indices[n] = total
                total += 1
            }
        }
        for raw in list where raw.type == 36 {
            flush(current)
            body += doc.b[raw.range]
            total += 1
            current += 1
        }
        flush(current)
        guard total > 0 else { throw WriteError.unsupported("empty document") }
        var newList: [UInt8] = [1]
        newList += u32(4 + 4 + body.count)
        newList += u32(total - 1)
        newList += body

        var newDoc = Array(doc.b[0..<start]) + newList + Array(doc.b[listEnd...])
        let difference = newList.count - (listEnd - start)
        put(u32(try doc.u32(14) + difference), into: &newDoc, at: 14)
        // Fixed-size page fields, before the list (they don't move): see `Bytes.pageSetup`. A page
        // the reader doesn't understand stays as it was.
        if let marks, (try? doc.pageSetup()) != nil, let p = try? doc.pageFields() {
            newDoc[p] = marks.on ? 1 : 0
            for (i, value) in [marks.left, marks.top, marks.right, marks.bottom, marks.length, marks.thickness].enumerated() {
                put(f32(value), into: &newDoc, at: p + [1, 5, 9, 13, 25, 29][i])
            }
        }
        sections[0] = newDoc
        if let thumbnail { sections[2] = Array(thumbnail) }

        var output = Array(file.b[0..<0x400])
        for (i, section) in sections.enumerated() { put(u64(section.count), into: &output, at: 0x10 + 8 * i) }
        for section in sections { output += section }
        let fileData = Data(output)
        // What was written must read back.
        _ = try StudioDocument(data: fileData)
        return (fileData, indices)
    }
}

extension StudioWriter {
    /// The ids of all the document's objects (for the tests: they must be unique).
    static func objectIDs(_ data: Data) throws -> [Int] {
        let file = Bytes(Array(data))
        let doc = Bytes(Array(file.b[0x400..<(0x400 + (try file.u64(0x10)))]))
        guard let start = doc.objectListAfterMarker() else { return [] }
        var ids: [Int] = []
        func walk(_ rawObjects: [RawObject]) throws {
            for o in rawObjects {
                ids.append(try Assembler.trailer(doc, o).id)
                try walk(o.children)
            }
        }
        try walk(try doc.objectList(at: start))
        return ids
    }
}

// MARK: - Assembling the objects

private struct Assembler {
    let doc: Bytes
    let list: [RawObject]
    /// Next free id (Studio's ids are unique in the document).
    var nextID: Int

    init(doc: Bytes, list: [RawObject]) {
        self.doc = doc
        self.list = list
        var largest = 0
        func walk(_ rawObjects: [RawObject]) {
            for o in rawObjects {
                if let id = try? Assembler.trailer(doc, o).id { largest = max(largest, id) }
                walk(o.children)
            }
        }
        walk(list)
        nextID = largest + 1
    }

    /// Where the object's closing starts ([01][u32 id]…) and the id.
    static func trailer(_ doc: Bytes, _ o: RawObject) throws -> (start: Int, id: Int) {
        var k = o.bodyEnd + 36 + 24 + 4 + 1
        k = try doc.u8(k) == 1 ? try doc.block(k, limit: o.range.upperBound) : k + 1
        guard try doc.u8(k) == 1 else { throw StudioError.damaged("object closing at \(k)") }
        return (k, try doc.u32(k + 1))
    }

    /// The file's object at a tree path and its transform to the page.
    func origin(_ sourcePath: [Int]) -> (RawObject, CGAffineTransform)? {
        var rawObjects = list, t = CGAffineTransform.identity
        var found: RawObject?
        for i in sourcePath {
            guard rawObjects.indices.contains(i) else { return nil }
            let o = rawObjects[i]
            t = o.matrix.concatenating(t)
            found = o
            rawObjects = o.children
        }
        return found.map { ($0, t) }
    }

    /// A polygon (or rectangle) of the file without an image, for the new objects.
    func template() -> RawObject? {
        func find(_ rawObjects: [RawObject]) -> RawObject? {
            for o in rawObjects {
                if o.type == 1 || o.type == 2, let style = try? doc.style(at: o.base.lowerBound, limit: o.base.upperBound) {
                    if case .image = style.fill { continue }
                    return o
                }
                if let r = find(o.children) { return r }
            }
            return nil
        }
        return find(list)
    }

    mutating func objectBytes(_ shapeItem: StudioWriter.Shape) throws -> [UInt8] {
        // `fromOrigin`: rebuilt from the object it came from (changed or a copy); `isNew`: gets an id and a code.
        let raw: RawObject, toPage: CGAffineTransform, fromOrigin: Bool
        if let sourcePath = shapeItem.source, let (o, t) = origin(sourcePath), [1, 2, 8].contains(o.type) {
            (raw, toPage, fromOrigin) = (o, t, true)
        } else if let o = template() {
            (raw, toPage, fromOrigin) = (o, .identity, false)
        } else {
            throw StudioWriter.WriteError.unsupported("no polygon in the file to use as a template")
        }
        let isNew = !fromOrigin || shapeItem.copy

        // Local system: the source object's, taken from the old box to the new one (moving and resizing don't
        // touch the local outline or the image); new object = the page itself.
        let page = cgPath(shapeItem.subpaths)
        let newBox = page.boundingBoxOfPath
        var local = CGAffineTransform.identity
        var originalNodes: [[LocalNode]]?
        if fromOrigin {
            if raw.type == 1 || raw.type == 2 { originalNodes = try? doc.localPath(at: raw.base.upperBound, limit: raw.bodyEnd) }
            let oldBox: CGRect
            if let nodes = originalNodes {
                oldBox = cgPath(nodes.map { $0.map { absolute($0) } }).copy(using: [toPage])?.boundingBoxOfPath ?? .null
            } else if let cache = raw.cache, let nodes = try? doc.cachedPath(at: cache.lowerBound, limit: cache.upperBound) {
                oldBox = cgPath(nodes).boundingBoxOfPath
            } else {
                oldBox = .null
            }
            local = toPage
            if let change = shapeItem.sourceChange {
                local = toPage.concatenating(change)
            } else if !oldBox.isNull, oldBox.width > 1e-6, oldBox.height > 1e-6, newBox.width > 1e-6, newBox.height > 1e-6 {
                let a = CGAffineTransform(translationX: -oldBox.minX, y: -oldBox.minY)
                    .concatenating(CGAffineTransform(scaleX: newBox.width / oldBox.width, y: newBox.height / oldBox.height))
                    .concatenating(CGAffineTransform(translationX: newBox.minX, y: newBox.minY))
                local = toPage.concatenating(a)
            }
            if abs(local.a * local.d - local.b * local.c) < 1e-12 { local = .identity }
        } else if let system = shapeItem.localToPage, abs(system.a * system.d - system.b * system.c) > 1e-12 {
            local = system
        }
        let toLocalTransform = local.inverted()
        let localNodes: [[LocalNode]] = shapeItem.subpaths.filter { $0.count >= 2 }.map { nodes in
            nodes.map { n in
                let p = n.point.applying(toLocalTransform)
                let rel = { (c: CGPoint) in CGPoint(x: c.applying(toLocalTransform).x - p.x, y: c.applying(toLocalTransform).y - p.y) }
                return LocalNode(point: p, controlIn: n.controlIn.map(rel), controlOut: n.controlOut.map(rel))
            }
        }
        // Outline equal to the source's (only moved/resized): the bytes and the type (rectangle…) stay.
        let sameOutline = originalNodes.map { unchanged($0, localNodes) } ?? false
        let kind: UInt8 = sameOutline ? raw.type : 2

        // Base (type + style + layer): line color, fill, image.
        var base = Array(doc.b[raw.base])
        let st = 6
        guard base.count > st + 31, base[st] == 1 else { throw StudioError.damaged("style at \(raw.base.lowerBound)") }
        let styleEnd = st + 1 + Int(le32(base, st + 1))
        let style = Bytes(base)
        if try style.color(st + 7).hex != shapeItem.line.hex || !fromOrigin { put(colorBytes(shapeItem.line), into: &base, at: st + 7) }
        var k = try style.block(st + 31, limit: styleEnd) + 1
        k = try style.string(k).1
        k = try style.u8(k) == 1 ? try style.string(k + 1).1 : k + 1
        var delta = 0
        switch (shapeItem.fill, base[k]) {
        case (.keep, _), (.none, 0):
            break
        case (.none, 1):
            base[k] = 0
            base.removeSubrange((k + 1)..<(k + 17))
            delta = -16
        case (.color(let c), 1):
            put(colorBytes(c), into: &base, at: k + 1)
        case (.color(let c), 0):
            base[k] = 1
            base.insert(contentsOf: colorBytes(c), at: k + 1)
            delta = 16
        default:
            throw StudioWriter.WriteError.unsupported("image fill replaced")
        }
        if let image = shapeItem.imageToPage, base[k] == 5 {
            // 2nd of the three matrices after [01 00 01]: pixel → the object's local system.
            let afterString = try Bytes(base).string(k + 1).1
            guard let j = Bytes(base).firstIndex(of: [1, 0, 1], from: afterString, to: styleEnd + delta), base[j + 39] == 1 else {
                throw StudioWriter.WriteError.unsupported("image position")
            }
            put(matrixBytes(image.concatenating(toLocalTransform)), into: &base, at: j + 40)
        }
        put(u32(styleEnd + delta - (st + 1)), into: &base, at: st + 1)
        base[0] = kind
        put(u32(base.count - 1), into: &base, at: 1)

        let outline = sameOutline ? Array(doc.b[raw.base.upperBound..<raw.bodyEnd]) : localPathBytes(localNodes)
        var body: [UInt8] = [1] + u32(4 + base.count + outline.count)
        body += base
        body += outline

        // Matrix, box (center and semi-axes, in the parent's system = page), "doesn't cut", path on the page.
        let localBox = cgPath(localNodes.map { $0.map { absolute($0) } }).boundingBoxOfPath
        let center = CGPoint(x: localBox.midX, y: localBox.midY).applying(local)
        let (mw, mh) = (localBox.width / 2, localBox.height / 2)
        var afterBody = matrixBytes(local)
        afterBody += [center.x, center.y, local.a * mw, local.b * mw, local.c * mh, local.d * mh].flatMap { f32($0) }
        let flag = try doc.u32(raw.bodyEnd + 60)
        afterBody += u32(shapeItem.cuts == (flag != 1) ? flag : (shapeItem.cuts ? 2 : 1))
        afterBody.append(try doc.u8(raw.bodyEnd + 64))
        afterBody += pagePathBytes(shapeItem.subpaths.filter { $0.count >= 2 })

        // Closing: id, name, code. A new object gets a new id and code; when it becomes a polygon, it loses the "create_…".
        let (closingStart, _) = try Assembler.trailer(doc, raw)
        var closing = Array(doc.b[closingStart..<raw.range.upperBound])
        if isNew {
            put(u32(nextID), into: &closing, at: 1)
            nextID += 1
        }
        let f = Bytes(closing)
        let twelveEnd = try f.block(9, limit: closing.count)
        let (name, nameEnd) = try f.string(twelveEnd)
        let codeEnd = try f.string(nameEnd + 4).1
        if isNew {
            let code = Array(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().utf8)
            closing.replaceSubrange((nameEnd + 8)..<codeEnd, with: code)
        }
        if kind == 2, name != "Polygon" {
            // After the code: [12 bytes][FFFFFFFF][u32][u32 n][tool "create_…"]; without it, n = 0.
            let n = closing.count >= codeEnd + 24 ? Int(le32(closing, codeEnd + 20)) : -1
            guard codeEnd + 24 + n == closing.count else { throw StudioWriter.WriteError.unsupported("object closing") }
            closing.replaceSubrange((codeEnd + 20)..<closing.count, with: u32(0))
            closing.replaceSubrange(twelveEnd..<nameEnd, with: u32(7) + Array("Polygon".utf8))
        }

        var objectBytes: [UInt8] = [1] + u32(4 + 1 + body.count + afterBody.count + closing.count)
        objectBytes.append(try doc.u8(raw.range.lowerBound + 5))
        objectBytes += body
        objectBytes += afterBody
        objectBytes += closing
        return objectBytes
    }
}

// MARK: - Bytes

private func unchanged(_ a: [[LocalNode]], _ b: [[LocalNode]]) -> Bool {
    guard a.count == b.count else { return false }
    let near = { (p: CGPoint?, q: CGPoint?) -> Bool in
        switch (p, q) {
        case (nil, nil): true
        case let (p?, q?): abs(p.x - q.x) < 1e-3 && abs(p.y - q.y) < 1e-3
        default: false
        }
    }
    return zip(a, b).allSatisfy { x, y in
        x.count == y.count && zip(x, y).allSatisfy { near($0.point, $1.point) && near($0.controlIn, $1.controlIn) && near($0.controlOut, $1.controlOut) }
    }
}

private func absolute(_ n: LocalNode) -> StudioDocument.Node {
    StudioDocument.Node(point: n.point,
                        controlIn: n.controlIn.map { CGPoint(x: n.point.x + $0.x, y: n.point.y + $0.y) },
                        controlOut: n.controlOut.map { CGPoint(x: n.point.x + $0.x, y: n.point.y + $0.y) })
}

private func cgPath(_ subpathList: [[StudioDocument.Node]]) -> CGPath {
    StudioDocument.Object(kind: "", subpaths: subpathList, line: StudioDocument.Color(red: 0, green: 0, blue: 0, alpha: 1),
                          fill: .none, cuts: true).path
}

/// [01 size][u32 n − 1] { [01 size][01][u32 points − 1] { [01 size] x y handle handle [00 smooth 00] } }
private func localPathBytes(_ subpathList: [[LocalNode]]) -> [UInt8] {
    var content = u32(subpathList.count - 1)
    for nodes in subpathList {
        var sub: [UInt8] = [1] + u32(nodes.count - 1)
        for n in nodes {
            var point = f32(n.point.x) + f32(n.point.y) + handleBytes(n.controlIn) + handleBytes(n.controlOut)
            point += [0, n.controlIn != nil && n.controlOut != nil ? 1 : 0, 0]
            sub += [1] + u32(4 + point.count) + point
        }
        content += [1] + u32(4 + sub.count) + sub
    }
    return [1] + u32(4 + content.count) + content
}

/// [01 size][u32 n − 1] { [u32 size][01][u32 points − 1] { x y handle handle } } — on the page, relative handles.
private func pagePathBytes(_ subpathList: [[StudioDocument.Node]]) -> [UInt8] {
    var content = u32(subpathList.count - 1)
    for nodes in subpathList {
        var sub: [UInt8] = [1] + u32(nodes.count - 1)
        for n in nodes {
            let rel = { (c: CGPoint) in CGPoint(x: c.x - n.point.x, y: c.y - n.point.y) }
            sub += f32(n.point.x) + f32(n.point.y) + handleBytes(n.controlIn.map(rel)) + handleBytes(n.controlOut.map(rel))
        }
        content += u32(4 + sub.count) + sub
    }
    return [1] + u32(4 + content.count) + content
}

private func handleBytes(_ h: CGPoint?) -> [UInt8] { h.map { [1] + f32($0.x) + f32($0.y) } ?? [0] }

/// 3 × 3 matrix by rows, like the reader (x' = a·x + c·y + tx; y' = b·x + d·y + ty).
private func matrixBytes(_ t: CGAffineTransform) -> [UInt8] {
    [t.a, t.c, t.tx, t.b, t.d, t.ty, 0, 0, 1].flatMap { f32($0) }
}

private func colorBytes(_ c: StudioDocument.Color) -> [UInt8] { [c.red, c.green, c.blue, c.alpha].flatMap { f32($0) } }

private func f32(_ v: Double) -> [UInt8] { u32(Int(Float(v).bitPattern)) }

private func u32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((UInt32(truncatingIfNeeded: v) >> (8 * UInt32($0))) & 0xFF) } }

private func u64(_ v: Int) -> [UInt8] { (0..<8).map { UInt8((UInt64(v) >> (8 * UInt64($0))) & 0xFF) } }

private func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
}

private func put(_ value: [UInt8], into b: inout [UInt8], at o: Int) {
    b.replaceSubrange(o..<(o + value.count), with: value)
}

extension Bytes {
    /// The object list by the usual marker ("auto", "auto"), without the reading's plan B.
    func objectListAfterMarker() -> Int? {
        let auto = Array("auto".utf8)
        let marker = [4, 0, 0, 0] + auto + [4, 0, 0, 0] + auto
        guard let i = firstIndex(of: marker, to: 1 << 16), (try? objectList(at: i + marker.count)) != nil else { return nil }
        return i + marker.count
    }
}
