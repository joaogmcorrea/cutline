// Tracing (as in the prototype): the image's outer contour, with a margin — what's inside the artwork is
// ignored —, or also the inner contours (the holes, like the middle of an O). Level (transparency or
// distance from the background color) → fill the holes (outer only) → distance to the edge, found between the pixels
// (sub-pixel), spread outwards by the margin → marching squares on that distance → simplification
// (Douglas–Peucker, by the number of nodes) → smooth nodes or corners (by the smoothing).
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

    /// Douglas–Peucker tolerance, in pixels of the reduced image: from 8 (few nodes) to 0.5 (every detail).
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
    /// RGBA pixels (premultiplied) of the image reduced to at most `maximum` px on the longer side.
    struct Pixels: Sendable {
        let width: Int, height: Int
        let rgba: [UInt8]
        /// Height ÷ width of the original image: the reduced one rounds each side on its own, so the scale in mm
        /// is worked out for each axis.
        let aspectRatio: Double
    }

    /// 2000 px: on an A4 sheet, a pixel is 0.15 mm (with 500 px it was 0.6 mm, and the cut line came out in steps).
    static func pixels(_ image: CGImage, maximum: Int = 2000) -> Pixels? {
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
        return ok ? Pixels(width: w, height: h, rgba: payload, aspectRatio: Double(image.height) / Double(max(image.width, 1))) : nil
    }

    static func traceImage(_ px: Pixels, _ prm: TraceParameters) -> TraceResult {
        let iw = px.width, ih = px.height, d = px.rgba
        let pxmm = Double(iw) / max(prm.width, 1), r = prm.margin * pxmm
        let pxmmY = Double(ih) / max(prm.width * px.aspectRatio, 1)
        let pad = Int(r.rounded(.up)) + 2
        let W = iw + 2 * pad, H = ih + 2 * pad

        // 1. Level: how far into the artwork each pixel is (> 0) or out of it (≤ 0) — the opacity, if there is
        //    transparency, or the distance from the border's average color, minus the threshold. The edge is where it
        //    crosses zero, between the pixels.
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
        let threshold = transparent ? 100 : prm.tolerance
        var level = [Double](repeating: -threshold, count: W * H)
        for y in 0..<ih { for x in 0..<iw {
            let i = (y * iw + x) * 4
            level[(y + pad) * W + x + pad] = transparent
                ? Double(d[i + 3]) - threshold
                : sqrt(pow(Double(d[i]) - background.0, 2) + pow(Double(d[i + 1]) - background.1, 2) + pow(Double(d[i + 2]) - background.2, 2)) - threshold
        } }
        let mask = level.map { $0 > 0 }

        // 2. Outer only: fill the holes — what can't be reached from the border becomes "inside".
        //    With the inner ones, the holes stay (and the margin narrows them).
        var outside = mask.map { !$0 }
        if !prm.inners {
            outside = [Bool](repeating: false, count: W * H)
            var stack = [0]
            outside[0] = true
            while let k = stack.popLast() {
                let x = k % W, y = k / W
                if x + 1 < W, !outside[k + 1], !mask[k + 1] { outside[k + 1] = true; stack.append(k + 1) }
                if x > 0, !outside[k - 1], !mask[k - 1] { outside[k - 1] = true; stack.append(k - 1) }
                if y + 1 < H, !outside[k + W], !mask[k + W] { outside[k + W] = true; stack.append(k + W) }
                if y > 0, !outside[k - W], !mask[k - W] { outside[k - W] = true; stack.append(k - W) }
            }
        }

        // 3. Distance to the edge, in px. Next to it, it's where the level crosses zero between two pixels
        //    (outside: `dist`, with the crossing point in `near`; inside: `edge`). The margin carries the nearest
        //    crossing point outwards (dead reckoning, two passes): the distance is the real one in every direction.
        var dist = [Double](repeating: 1e9, count: W * H), edge = [Double](repeating: 1, count: W * H)
        var near = [CGPoint](repeating: .zero, count: W * H)
        let pair = { (o: Int, i: Int) in
            let t = level[i] > 0 ? min(max(level[o] / (level[o] - level[i]), 0), 1) : 0.5
            if t < dist[o] {
                dist[o] = t
                near[o] = CGPoint(x: Double(o % W) + Double(i % W - o % W) * t, y: Double(o / W) + Double(i / W - o / W) * t)
            }
            edge[i] = min(edge[i], 1 - t)
        }
        for y in 0..<H { for x in 0..<W {
            let k = y * W + x
            if x + 1 < W, outside[k] != outside[k + 1] { outside[k] ? pair(k, k + 1) : pair(k + 1, k) }
            if y + 1 < H, outside[k] != outside[k + W] { outside[k] ? pair(k, k + W) : pair(k + W, k) }
        } }
        if r > 0 {
            let step = { (i: Int, j: Int) in
                guard dist[j] < 1e9 else { return }
                let p = near[j], v = hypot(Double(i % W) - p.x, Double(i / W) - p.y)
                if v < dist[i] { dist[i] = v; near[i] = p }
            }
            for y in 0..<H { for x in 0..<W where outside[y * W + x] {
                let i = y * W + x
                if x > 0 { step(i, i - 1) }
                if y > 0 {
                    step(i, i - W)
                    if x > 0 { step(i, i - W - 1) }
                    if x < W - 1 { step(i, i - W + 1) }
                }
            } }
            for y in stride(from: H - 1, through: 0, by: -1) { for x in stride(from: W - 1, through: 0, by: -1) where outside[y * W + x] {
                let i = y * W + x
                if x < W - 1 { step(i, i + 1) }
                if y < H - 1 {
                    step(i, i + W)
                    if x < W - 1 { step(i, i + W + 1) }
                    if x > 0 { step(i, i + W - 1) }
                }
            } }
        }
        // > 0 within the margin; zero exactly on the contour.
        var field = [Double](repeating: 0, count: W * H)
        for i in 0..<(W * H) { field[i] = outside[i] ? r - dist[i] : r + edge[i] }
        let g = field.map { $0 > 0 }

        // 4. Marching squares → loops. The keys are the doubled coordinates of the cell sides (pixel midpoints become
        //    integers): they link the segments; the point goes where the field crosses zero along that side.
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
        // Odd x: the side between two pixels of a row; odd y: of a column. Each value is at the pixel's center (+0.5).
        let position = { (k: Int) -> CGPoint in
            let kx = k / 1_000_003, ky = k % 1_000_003
            let (a, b) = kx % 2 == 1 ? ((ky / 2) * W + (kx - 1) / 2, (ky / 2) * W + (kx + 1) / 2)
                                     : (((ky - 1) / 2) * W + kx / 2, ((ky + 1) / 2) * W + kx / 2)
            let t = field[a] == field[b] ? 0.5 : min(max(field[a] / (field[a] - field[b]), 0), 1)
            return CGPoint(x: Double(a % W) + Double(b % W - a % W) * t + 0.5, y: Double(a / W) + Double(b / W - a / W) * t + 0.5)
        }
        var seen = Set<Int>()
        var loops: [[CGPoint]] = []
        for start in neighbors.keys where !seen.contains(start) {
            var loop: [CGPoint] = []
            var previous: Int?, current: Int? = start
            while let k = current, !seen.contains(k) {
                seen.insert(k)
                loop.append(position(k))
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
                .map { CGPoint(x: ($0.x - Double(pad)) / pxmm, y: ($0.y - Double(pad)) / pxmmY) }
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
