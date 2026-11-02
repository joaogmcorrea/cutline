// Tracing (as in the prototype): the image's outer contour, with a margin — what's inside the artwork is
// ignored —, or also the inner contours (the holes, like the middle of an O). Mask (transparency or
// distance from the background color) → fill the holes (outer only) → dilate by the margin (chamfer
// distance) → marching squares → simplification (Douglas–Peucker, by the number of nodes) → smooth nodes or corners
// (by the smoothing).
import CoreGraphics
import Foundation

nonisolated struct TraceParameters: Equatable, Sendable {
    /// Also the inner contours (the artwork's holes); otherwise, only the outer one.
    var inners = false
    /// Width of the image on the page, in mm (the initial one; it's resized on the canvas later).
    var width = 60.0
    /// Distance from the contour to the artwork, in mm.
    var margin = 2.0
    /// Number of nodes, from 0 (the minimum that holds the shape) to 100 (every detail of the image).
    var nodes = 50.0
    /// How much the nodes round off, from 0 (all corners, straight lines between them) to 100 (all smooth).
    var smoothing = 40.0
    /// Color difference to separate the artwork from the background (images without transparency).
    var tolerance = 40.0

    /// Douglas–Peucker tolerance, in pixels of the reduced image: from 8 (few nodes) to 0.5 (every
    /// detail; below that, the pixels' steps would remain).
    var simplification: Double { 0.5 * pow(16, 1 - min(max(nodes, 0), 100) / 100) }
}

nonisolated struct TraceResult: Sendable {
    /// Closed loops in mm, with the origin at the image's top-left corner.
    var loops: [[CGPoint]]
    /// The image had transparency (otherwise, the background was detected by the border color).
    var transparent: Bool
    var pointsList: Int { loops.reduce(0) { $0 + $1.count } }
}

nonisolated enum Tracer {
    /// RGBA pixels (not premultiplied) of the image reduced to at most `maximum` px on the longer side.
    struct Pixels: Sendable {
        let width: Int, height: Int
        let rgba: [UInt8]
    }

    static func pixels(_ image: CGImage, maximum: Int = 500) -> Pixels? {
        let scale = min(1, Double(maximum) / Double(max(image.width, image.height)))
        let w = max(1, Int((Double(image.width) * scale).rounded())), h = max(1, Int((Double(image.height) * scale).rounded()))
        var payload = [UInt8](repeating: 0, count: w * h * 4)
        let ok = payload.withUnsafeMutableBytes { bytes -> Bool in
            guard let ctx = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? Pixels(width: w, height: h, rgba: payload) : nil
    }

    static func traceImage(_ px: Pixels, _ prm: TraceParameters) -> TraceResult {
        let iw = px.width, ih = px.height, d = px.rgba
        let pxmm = Double(iw) / max(prm.width, 1), r = prm.margin * pxmm
        let pad = Int(r.rounded(.up)) + 2
        let W = iw + 2 * pad, H = ih + 2 * pad

        // 1. Mask: transparency, if there is any; otherwise, distance from the border's average color.
        var transparent = false
        for i in stride(from: 3, to: d.count, by: 4) where d[i] < 250 { transparent = true; break }
        var background = (0.0, 0.0, 0.0), n = 0.0
        if !transparent {
            for y in 0..<ih { for x in 0..<iw where x == 0 || y == 0 || x == iw - 1 || y == ih - 1 {
                let i = (y * iw + x) * 4
                background.0 += Double(d[i]); background.1 += Double(d[i + 1]); background.2 += Double(d[i + 2]); n += 1
            } }
            background = (background.0 / max(n, 1), background.1 / max(n, 1), background.2 / max(n, 1))
        }
        var mask = [Bool](repeating: false, count: W * H)
        for y in 0..<ih { for x in 0..<iw {
            let i = (y * iw + x) * 4
            let inside = transparent
                ? d[i + 3] > 100
                : sqrt(pow(Double(d[i]) - background.0, 2) + pow(Double(d[i + 1]) - background.1, 2) + pow(Double(d[i + 2]) - background.2, 2)) > prm.tolerance
            if inside { mask[(y + pad) * W + x + pad] = true }
        } }

        // 2. Outer only: fill the holes — what can't be reached from the border becomes "inside".
        //    With the inner ones, the holes stay (and the margin narrows them).
        var outside = mask.map { !$0 }
        if !prm.inners {
            outside = [Bool](repeating: false, count: W * H)
            var stack = [0]
            outside[0] = true
            while let k = stack.popLast() {
                let x = k % W, y = k / W
                for (nx, ny) in [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)] where nx >= 0 && ny >= 0 && nx < W && ny < H {
                    let j = ny * W + nx
                    if !outside[j], !mask[j] { outside[j] = true; stack.append(j) }
                }
            }
        }

        // 3. Margin: dilate by the distance (chamfer 1 / √2), in two passes.
        var dist = outside.map { $0 ? 1e9 : 0 }
        if r > 0 {
            let s = 2.0.squareRoot()
            for y in 0..<H { for x in 0..<W {
                let i = y * W + x
                var v = dist[i]
                if x > 0 { v = min(v, dist[i - 1] + 1) }
                if y > 0 {
                    v = min(v, dist[i - W] + 1)
                    if x > 0 { v = min(v, dist[i - W - 1] + s) }
                    if x < W - 1 { v = min(v, dist[i - W + 1] + s) }
                }
                dist[i] = v
            } }
            for y in stride(from: H - 1, through: 0, by: -1) { for x in stride(from: W - 1, through: 0, by: -1) {
                let i = y * W + x
                var v = dist[i]
                if x < W - 1 { v = min(v, dist[i + 1] + 1) }
                if y < H - 1 {
                    v = min(v, dist[i + W] + 1)
                    if x < W - 1 { v = min(v, dist[i + W + 1] + s) }
                    if x > 0 { v = min(v, dist[i + W - 1] + s) }
                }
                dist[i] = v
            } }
        }
        let g = dist.map { $0 <= r }

        // 4. Marching squares → loops (doubled coordinates: pixel midpoints become integers).
        let table: [Int: [(Character, Character)]] = [
            1: [("L", "B")], 2: [("B", "R")], 3: [("L", "R")], 4: [("T", "R")], 5: [("L", "B"), ("T", "R")], 6: [("T", "B")],
            7: [("T", "L")], 8: [("T", "L")], 9: [("T", "B")], 10: [("T", "L"), ("B", "R")], 11: [("T", "R")], 12: [("L", "R")],
            13: [("B", "R")], 14: [("L", "B")],
        ]
        var neighbors: [Int: [Int]] = [:]
        let key = { (x: Int, y: Int) in x * 1_000_003 + y }
        for y in 0..<(H - 1) { for x in 0..<(W - 1) {
            let caso = (g[y * W + x] ? 8 : 0) + (g[y * W + x + 1] ? 4 : 0) + (g[(y + 1) * W + x + 1] ? 2 : 0) + (g[(y + 1) * W + x] ? 1 : 0)
            guard let segments = table[caso] else { continue }
            let point: [Character: (Int, Int)] = ["T": (2 * x + 1, 2 * y), "R": (2 * x + 2, 2 * y + 1), "B": (2 * x + 1, 2 * y + 2), "L": (2 * x, 2 * y + 1)]
            for (a, b) in segments {
                let pa = point[a]!, pb = point[b]!
                neighbors[key(pa.0, pa.1), default: []].append(key(pb.0, pb.1))
                neighbors[key(pb.0, pb.1), default: []].append(key(pa.0, pa.1))
            }
        } }
        var seen = Set<Int>()
        var loops: [[CGPoint]] = []
        for start in neighbors.keys where !seen.contains(start) {
            var loop: [CGPoint] = []
            var previous: Int?, current: Int? = start
            while let k = current, !seen.contains(k) {
                seen.insert(k)
                loop.append(CGPoint(x: Double(k / 1_000_003) / 2, y: Double(k % 1_000_003) / 2))
                let next = neighbors[k]?.first { $0 != previous && !seen.contains($0) }
                previous = k
                current = next
            }
            if loop.count > 8 { loops.append(loop) }
        }
        let area = { (l: [CGPoint]) -> Double in
            abs(zip(l, l.dropFirst() + [l[0]]).reduce(0) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y }) / 2
        }
        // Drops dirt: loops too small next to the largest (with the inner ones, accepts smaller holes).
        let larger = max(1, loops.map(area).max() ?? 1)
        let minimum = larger * (prm.inners ? 0.0005 : 0.004)
        // Once simplified, a narrow hole can become a sliver (2 nodes): it goes too.
        let finals = loops.filter { area($0) > minimum }.map { loop in
            Array(simplify(loop + [loop[0]], prm.simplification).dropLast())
                .map { CGPoint(x: ($0.x - Double(pad)) / pxmm, y: ($0.y - Double(pad)) / pxmm) }
        }.filter { $0.count >= 3 }
        return TraceResult(loops: finals, transparent: transparent)
    }

    /// Douglas–Peucker.
    static func simplify(_ pts: [CGPoint], _ eps: Double) -> [CGPoint] {
        guard pts.count >= 3, let a = pts.first, let b = pts.last else { return pts }
        let length = hypot(b.x - a.x, b.y - a.y)
        var maximum = 0.0, index = 0
        for i in 1..<(pts.count - 1) {
            let p = pts[i]
            let dd = length == 0 ? hypot(p.x - a.x, p.y - a.y)
                : abs((b.y - a.y) * p.x - (b.x - a.x) * p.y + b.x * a.y - b.y * a.x) / length
            if dd > maximum { maximum = dd; index = i }
        }
        guard maximum > eps else { return [a, b] }
        return Array(simplify(Array(pts[...index]), eps).dropLast()) + simplify(Array(pts[index...]), eps)
    }

    /// Nodes of a closed loop: smooth where the curve turns up to the angle the smoothing allows (0 = none,
    /// 100 = all, even the sharp corners), corner elsewhere. The handles go in the direction of the neighbors, with a third of the
    /// segment on each side (so a polygon with many sides becomes a circle, without loops).
    static func smoothPoints(_ pts: [CGPoint], _ smoothing: Double) -> [Node] {
        let limitValue = min(max(smoothing, 0), 100) / 100 * .pi
        let n = pts.count
        return pts.enumerated().map { i, p in
            let a = pts[(i - 1 + n) % n], b = pts[(i + 1) % n]
            let spin = abs(remainder(atan2(b.y - p.y, b.x - p.x) - atan2(p.y - a.y, p.x - a.x), 2 * .pi))
            let d = hypot(b.x - a.x, b.y - a.y)
            guard limitValue > 0, spin <= limitValue, d > 0 else { return Node(point: p) }
            let ux = (b.x - a.x) / d, uy = (b.y - a.y) / d
            let before = hypot(p.x - a.x, p.y - a.y) / 3, after = hypot(b.x - p.x, b.y - p.y) / 3
            return Node(point: p, input: CGPoint(x: p.x - ux * before, y: p.y - uy * before),
                      output: CGPoint(x: p.x + ux * after, y: p.y + uy * after))
        }
    }
}
