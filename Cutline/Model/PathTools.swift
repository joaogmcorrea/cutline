// Path tools, as in Illustrator: Add and Delete Anchor Point (the Pen's group), the Eyedropper, Smooth (the nodes of
// a finished path, as the Trace window rounds them) and Offset Path (as in Silhouette Studio's Offset panel: a new
// outline around or inside the shape).
import CoreGraphics
import SwiftUI

/// A Bézier segment between two nodes (in page mm); without handles, a straight line.
nonisolated struct Segment {
    let p0, p1, p2, p3: CGPoint

    init(_ a: Node, _ b: Node) {
        (p0, p1, p2, p3) = (a.point, a.output ?? a.point, b.input ?? b.point, b.point)
    }

    func point(_ t: Double) -> CGPoint {
        let u = 1 - t
        let (a, b, c, d) = (u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t)
        return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x, y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }

    /// The point of the segment nearest to `p`: its `t` and the distance (samples, then narrows down).
    func nearest(to p: CGPoint) -> (t: Double, distance: Double) {
        let distance = { (t: Double) in let q = point(t); return hypot(q.x - p.x, q.y - p.y) }
        var best = (0...64).map { Double($0) / 64 }.min { distance($0) < distance($1) } ?? 0
        var step = 1.0 / 64
        for _ in 0..<20 {
            step /= 2
            best = [best - step, best, best + step].map { min(max($0, 0), 1) }.min { distance($0) < distance($1) } ?? best
        }
        return (best, distance(best))
    }

    /// de Casteljau: the two halves at `t` — the handles of the start, of the new node (input, output) and of the end.
    func split(_ t: Double) -> (startOut: CGPoint, point: CGPoint, input: CGPoint, output: CGPoint, endIn: CGPoint) {
        let lerp = { (a: CGPoint, b: CGPoint) in CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
        let p01 = lerp(p0, p1), p12 = lerp(p1, p2), p23 = lerp(p2, p3)
        let p012 = lerp(p01, p12), p123 = lerp(p12, p23)
        return (p01, lerp(p012, p123), p012, p123, p23)
    }
}

nonisolated enum OffsetCorner: String, CaseIterable, Identifiable, Sendable {
    case round, sharp

    var id: Self { self }

    var name: String {
        switch self {
        case .round: String(localized: "Round")
        case .sharp: String(localized: "Sharp")
        }
    }
}

extension Document {
    /// Add Anchor Point: on the outline of `id` nearest to `p` (mm), up to `tolerance` mm away. The segment is split
    /// where it is, so the shape doesn't change (a parametric shape becomes a path). False when it isn't on the outline.
    @discardableResult
    func addNode(to id: CanvasObject.ID, at p: CGPoint, tolerance: Double) -> Bool {
        guard let i = objects.firstIndex(where: { $0.id == id }) else { return false }
        var subs = objects[i].absoluteNodes
        var best: (sub: Int, node: Int, t: Double, distance: Double)?
        for (s, sub) in subs.enumerated() where sub.nodes.count >= 2 {
            for n in 0..<(sub.closed ? sub.nodes.count : sub.nodes.count - 1) {
                let found = Segment(sub.nodes[n], sub.nodes[(n + 1) % sub.nodes.count]).nearest(to: p)
                if found.distance <= best?.distance ?? tolerance { best = (s, n, found.t, found.distance) }
            }
        }
        guard let best, best.t > 0.001, best.t < 0.999 else { return false }
        var nodes = subs[best.sub].nodes
        let next = (best.node + 1) % nodes.count
        let line = nodes[best.node].output == nil && nodes[next].input == nil
        let half = Segment(nodes[best.node], nodes[next]).split(best.t)
        // A missing handle stays missing (its half would be the node itself).
        if nodes[best.node].output != nil { nodes[best.node].output = half.startOut }
        if nodes[next].input != nil { nodes[next].input = half.endIn }
        nodes.insert(line ? Node(point: half.point) : Node(point: half.point, input: half.input, output: half.output), at: best.node + 1)
        subs[best.sub].nodes = nodes
        registrar()
        objects[i].setNodes(subs)
        return true
    }

    /// Delete Anchor Point: the neighbors join, with their handles as they were. A subpath left with one node goes,
    /// and so does an object left with nothing.
    func deleteNode(of id: CanvasObject.ID, sub: Int, node: Int) {
        guard let i = objects.firstIndex(where: { $0.id == id }) else { return }
        var subs = objects[i].absoluteNodes
        guard subs.indices.contains(sub), subs[sub].nodes.indices.contains(node) else { return }
        registrar()
        subs[sub].nodes.remove(at: node)
        if subs[sub].nodes.count < 2 { subs.remove(at: sub) }
        if subs.isEmpty {
            objects.remove(at: i)
            selection.remove(id)
        } else {
            objects[i].setNodes(subs)
        }
    }

    /// Eyedropper: on an image, the pixel's color goes where X points (fill or stroke); on another object, its fill,
    /// stroke (the cut), width and line style go to the other selected objects — without them, to the next objects.
    func eyedrop(from id: CanvasObject.ID, at p: CGPoint) {
        guard let source = objects.first(where: { $0.id == id }) else { return }
        if let picked = pixelColor(of: source, at: p) {
            setColor(colorTarget, picked)
            return
        }
        let targets = selection.subtracting([id])
        guard !targets.isEmpty else {
            defaultFill = source.fill
            if source.cutsLine { defaultStroke = source.strokeColor }
            defaultStrokeWidth = source.strokeWidth
            defaultStyle = source.style
            return
        }
        registrar()
        for i in objects.indices where targets.contains(objects[i].id) {
            objects[i].fill = source.fill
            objects[i].strokeColor = source.strokeColor
            objects[i].cutsLine = source.cutsLine
            objects[i].strokeWidth = source.strokeWidth
            objects[i].style = source.style
        }
        if let fill = source.fill { remember(fill) }
        if source.cutsLine { remember(source.strokeColor) }
    }

    /// The color of the image's pixel under `p` (mm); nil outside the image or on a transparent pixel.
    func pixelColor(of object: CanvasObject, at p: CGPoint) -> CMYK? {
        guard let placed = object.image, let cg = image(placed.key) else { return nil }
        let q = p.applying(placed.transform.cg.concatenating(object.frameToPage).inverted())
        let x = Int(q.x.rounded(.down)), y = Int(q.y.rounded(.down))
        guard x >= 0, y >= 0, x < cg.width, y < cg.height, let pixel = cg.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var rgba = [UInt8](repeating: 0, count: 4)
        let ok = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let ctx = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard ok, rgba[3] > 0 else { return nil }
        let channel = { (v: UInt8) in min(Double(v) / Double(rgba[3]), 1) }
        return CMYK(red: channel(rgba[0]), green: channel(rgba[1]), blue: channel(rgba[2]))
    }

    /// Offset Path: a new outline `distance` mm from each selected object — outside (> 0) or inside (< 0) —, with
    /// round or sharp corners. It keeps the object's stroke color (it cuts) and comes in on top, selected; the
    /// originals stay. Images are left out (offset their contour). Returns a notice when nothing comes out.
    func offsetSelection(_ distance: Double, corner: OffsetCorner) -> String? {
        let objs = objectsInOrder.filter { selection.contains($0.id) && $0.image == nil }
        guard !objs.isEmpty else { return String(localized: "Select the shapes to offset (images are left out: offset their contour).") }
        guard distance != 0 else { return nil }
        let newItems: [CanvasObject] = objs.compactMap { object in
            // Both normalized before the boolean: the stroke's outline loops over itself at the concave corners and
            // only fills right by the winding rule (by even-odd, the loops became holes and fans), while the shape's
            // holes are even-odd.
            let path = object.shapePath.cgPath.normalized(using: .evenOdd)
            let band = object.shapePath.cgPath.copy(strokingWithWidth: 2 * abs(distance), lineCap: .round,
                                                    lineJoin: corner == .round ? .round : .miter, miterLimit: 10).normalized(using: .winding)
            // An open line has no inside: outwards, the band around it; inwards, nothing.
            let open = object.absoluteNodes.allSatisfy { !$0.closed }
            let result = open ? (distance > 0 ? band : nil) : distance > 0 ? path.union(band) : path.subtracting(band)
            let box = result?.boundingBoxOfPath ?? .null
            guard let result, !result.isEmpty, box.width * box.height > 0.0001, let free = CanvasObject.freePath(result) else { return nil }
            var outline = object
            outline.id = UUID()
            outline.shape = .shapePath(free.subpaths)
            outline.frame = free.frame
            outline.fill = nil
            outline.cutsLine = true
            outline.groups = []
            outline.label = String(localized: "Offset")
            return outline
        }
        guard !newItems.isEmpty else { return String(localized: "Nothing is left at this distance — try a smaller inset.") }
        registrar()
        let position = (objects.indices.filter { selection.contains(objects[$0].id) }.max() ?? objects.count - 1) + 1
        objects.insert(contentsOf: newItems, at: min(position, objects.count))
        selection = Set(newItems.map(\.id))
        return nil
    }
}

extension Subpath {
    /// The nodes rounded off as the Trace window does (smoothing 0–100: up to which turn a node becomes smooth); the
    /// handles there were are replaced. The ends of an open path stay corners.
    nonisolated func smoothed(_ smoothing: Double) -> Subpath {
        var smooth = Tracer.smoothPoints(nodes.map(\.point), smoothing)
        if !closed, let last = smooth.indices.last {
            smooth[0] = Node(point: smooth[0].point)
            smooth[last] = Node(point: smooth[last].point)
        }
        return Subpath(nodes: smooth, closed: closed)
    }
}

extension Document {
    /// The selected paths' nodes as they are, for Smooth to start from each time (the slider goes back and forth).
    var pathsToSmooth: [CanvasObject.ID: [Subpath]] {
        Dictionary(uniqueKeysWithValues: selectedObjects.compactMap { o in
            if case .shapePath = o.shape { (o.id, o.absoluteNodes) } else { nil }
        })
    }

    /// Smooth: the paths from `originals`, rounded off; dragging the slider is a single undo step.
    func smoothNodes(_ smoothing: Double, from originals: [CanvasObject.ID: [Subpath]]) {
        guard !originals.isEmpty else { return }
        registerAdjustment("smooth nodes")
        for i in objects.indices {
            if let subs = originals[objects[i].id] { objects[i].setNodes(subs.map { $0.smoothed(smoothing) }) }
        }
    }
}
