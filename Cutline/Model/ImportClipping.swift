// Clipping and fill rules baked into the imported geometry, the same for PDF, SVG and EPS. Cutline has no clipping
// masks and paints every fill even-odd (like Silhouette Studio), so what a clipping path hides is cut away from the
// paths, and a nonzero fill whose overlaps even-odd would paint as holes becomes its outline. Everything else keeps the
// file's nodes. A cut line that crosses a clip keeps only its visible part.
import CoreGraphics

nonisolated enum ImportClipping {
    /// What the clipping paths leave visible, normalized (any fill rule paints it the same).
    struct Region {
        var path: CGPath
        var box: CGRect
        /// An upright rectangle (the artboard's, almost always): a path whose box fits in it is all visible.
        var isRect: Bool

        init(path: CGPath, isRect: Bool = false) {
            self.path = path
            box = path.boundingBoxOfPath
            self.isRect = isRect
        }

        /// Nothing visible (an empty clipping path).
        static var nothing: Region { Region(path: CGMutablePath(), isRect: true) }

        /// The same region after `t` (an upright rectangle stays one only if `t` keeps the axes).
        func applying(_ t: CGAffineTransform) -> Region {
            let keepsAxes = (t.b == 0 && t.c == 0) || (t.a == 0 && t.d == 0)
            return Region(path: path.isEmpty ? path : (path.copy(using: [t]) ?? path), isRect: isRect && keepsAxes)
        }
    }

    /// The region inside both `current` (nil = nothing clipped yet) and `path` filled with `rule`.
    static func clip(_ current: Region?, to path: CGPath, rule: CGPathFillRule) -> Region {
        let rect = uprightRect(path)
        if let current {
            if current.isRect, let rect {
                let both = current.box.intersection(rect)
                return both.isNull ? .nothing : Region(path: CGPath(rect: both, transform: nil), isRect: true)
            }
            return Region(path: current.path.intersection(path.normalized(using: rule), using: .evenOdd))
        }
        if let rect { return Region(path: CGPath(rect: rect, transform: nil), isRect: true) }
        return Region(path: path.normalized(using: rule))
    }

    /// A painted path (page mm) as objects: one, or two when the fill and the line end up with different outlines
    /// (overlaps redrawn as an outline, or a path that crosses the clip's edge), so the fill prints what the file
    /// shows and the line still cuts along the file's stroke. None when the clip hides it all. `evenOdd`: the fill's
    /// rule (the others are nonzero); `strokeWidth` in pt, at the page's scale.
    static func objects(_ path: CGPath, strokeColor: CMYK?, strokeWidth: Double, fill: CMYK?, evenOdd: Bool,
                        clip: Region?) -> [CanvasObject] {
        var area: CGPath? = fill != nil ? path : nil
        var line: CGPath? = strokeColor != nil ? path : nil
        var split = false
        if area != nil, !evenOdd, let outline = nonzeroOutline(path) {
            area = outline
            split = true
        }
        if let clip {
            let box = path.boundingBoxOfPath
            if !(clip.isRect && clip.box.insetBy(dx: -tolerance, dy: -tolerance).contains(box)) {
                // Nothing of it can show: leave it out.
                guard !box.intersection(clip.box).isNull else { return [] }
                if let a = area, let visible = visible(a, in: clip.path, line: false) {
                    area = visible.isEmpty ? nil : visible
                    split = true
                }
                if let l = line, let visible = visible(l, in: clip.path, line: true) {
                    line = visible.isEmpty ? nil : visible
                    split = true
                }
            }
        }
        guard split else {
            return VectorImporter.object(path, strokeColor: strokeColor, strokeWidth: strokeWidth, fill: fill).map { [$0] } ?? []
        }
        return [area.flatMap { VectorImporter.object($0, strokeColor: nil, strokeWidth: strokeWidth, fill: fill) },
                line.flatMap { VectorImporter.object($0, strokeColor: strokeColor, strokeWidth: strokeWidth, fill: nil) }]
            .compactMap { $0 }
    }

    /// Below this (mm), a box overhang or a leftover of a boolean operation is rounding.
    static let tolerance = 0.001

    /// The part of `path` inside `clip` (the region, for a fill; the pieces of the line, for a stroke), or nil when
    /// it is all inside and keeps its nodes. Empty = all outside.
    static func visible(_ path: CGPath, in clip: CGPath, line: Bool) -> CGPath? {
        let outside = line ? path.lineSubtracting(clip, using: .evenOdd) : path.subtracting(clip, using: .evenOdd)
        if negligible(outside) { return nil }
        let inside = line ? path.lineIntersection(clip, using: .evenOdd) : path.intersection(clip, using: .evenOdd)
        return negligible(inside) ? CGMutablePath() : inside
    }

    static func negligible(_ path: CGPath) -> Bool {
        let box = path.boundingBoxOfPath
        return path.isEmpty || box.isNull || max(box.width, box.height) < tolerance
    }

    /// A nonzero fill's outline when even-odd (how Cutline paints) would paint it differently: subpaths that
    /// overlap in the same direction (letters of a variable font turned into outlines, shapes put together
    /// without uniting). nil = even-odd already paints it right, and the path keeps its nodes.
    static func nonzeroOutline(_ path: CGPath) -> CGPath? {
        var subpaths = 0
        path.applyWithBlock { if $0.pointee.type == .moveToPoint { subpaths += 1 } }
        guard subpaths > 1 else { return nil }
        let nonzero = path.normalized(using: .winding)
        let difference = nonzero.symmetricDifference(path.normalized(using: .evenOdd), using: .evenOdd).boundingBoxOfPath
        guard !difference.isNull, difference.width * difference.height > tolerance * tolerance * 100 else { return nil }
        return nonzero
    }

    /// The rectangle, if the path is one upright rectangle (re, or four lines along the axes).
    static func uprightRect(_ path: CGPath) -> CGRect? {
        var points: [CGPoint] = []
        var plain = true
        var moves = 0
        path.applyWithBlock { e in
            switch e.pointee.type {
            case .moveToPoint:
                moves += 1
                points.append(e.pointee.points[0])
            case .addLineToPoint: points.append(e.pointee.points[0])
            case .closeSubpath: break
            default: plain = false
            }
        }
        if points.count == 5, let first = points.first, let last = points.last,
           abs(first.x - last.x) < tolerance, abs(first.y - last.y) < tolerance { points.removeLast() }
        guard plain, moves == 1, points.count == 4 else { return nil }
        for i in 0..<4 {
            let a = points[i], b = points[(i + 1) % 4]
            guard abs(a.x - b.x) < tolerance || abs(a.y - b.y) < tolerance else { return nil }
        }
        let box = path.boundingBoxOfPath
        return box.width > tolerance && box.height > tolerance ? box : nil
    }
}
