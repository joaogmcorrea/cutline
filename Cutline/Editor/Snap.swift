// Snap to point (as in Illustrator): snaps to the active artboard's corners, midpoints and center, to the points of
// other objects and to guides; Snap to Grid (on its own, as in Illustrator), to the grid's lines (its smallest step,
// from the active artboard's corner).
// Targets are computed once per gesture.
import SwiftUI

struct SnapTargets {
    private(set) var pointsList: [CGPoint] = []
    let guides: Guides
    /// The grid's smallest step, in mm (nil = Snap to Grid off), and where it starts (the active artboard's corner).
    let grid: Double?
    let gridOrigin: CGPoint

    /// `points` = Snap (to points and guides); `grid` = Snap to Grid's step; `artboards` = whose corners and middles
    /// attract (nil = the active one).
    @MainActor
    init(doc: Document, exclude: Set<CanvasObject.ID>, artboards: [Artboard]? = nil, guides withGuides: Bool = true,
         points: Bool = true, grid: Double? = nil) {
        self.grid = grid
        gridOrigin = doc.activeArtboard.rect.origin
        // Hidden guides don't attract.
        guides = withGuides && points ? doc.guides : Guides()
        guard points else { return }
        for page in (artboards ?? [doc.activeArtboard]).map(\.rect) {
            pointsList += [CGPoint(x: page.minX, y: page.minY), CGPoint(x: page.midX, y: page.minY), CGPoint(x: page.maxX, y: page.minY),
                           CGPoint(x: page.minX, y: page.midY), CGPoint(x: page.midX, y: page.midY), CGPoint(x: page.maxX, y: page.midY),
                           CGPoint(x: page.minX, y: page.maxY), CGPoint(x: page.midX, y: page.maxY), CGPoint(x: page.maxX, y: page.maxY)]
        }
        for object in doc.objectsInOrder where doc.visible(object) && !exclude.contains(object.id) {
            pointsList.append(contentsOf: object.anchors)
        }
    }

    /// The nearest grid line to `v` on one axis, if it is within the tolerance.
    private func gridLine(_ v: Double, from origin: Double, tolerance: Double) -> Double? {
        guard let grid else { return nil }
        let line = origin + ((v - origin) / grid).rounded() * grid
        return abs(line - v) < tolerance ? line : nil
    }

    /// Snapped point (or the point itself) and where to show the snap mark. Tolerance in mm.
    func snap(_ p: CGPoint, tolerance: Double) -> (point: CGPoint, mark: CGPoint?) {
        var best: CGPoint?, distance = tolerance
        for q in pointsList {
            let d = hypot(q.x - p.x, q.y - p.y)
            if d < distance { distance = d; best = q }
        }
        if let best { return (best, best) }
        // Guides, then the grid: snap per axis.
        var q = p, didFind = false
        if let x = guides.verticals.min(by: { abs($0 - p.x) < abs($1 - p.x) }), abs(x - p.x) < tolerance {
            q.x = x
            didFind = true
        } else if let x = gridLine(p.x, from: gridOrigin.x, tolerance: tolerance) {
            q.x = x
            didFind = true
        }
        if let y = guides.horizontals.min(by: { abs($0 - p.y) < abs($1 - p.y) }), abs(y - p.y) < tolerance {
            q.y = y
            didFind = true
        } else if let y = gridLine(p.y, from: gridOrigin.y, tolerance: tolerance) {
            q.y = y
            didFind = true
        }
        return (q, didFind ? q : nil)
    }

    /// Offset that snaps one of the moving points to a target (or to a guide, per axis).
    func snap(_ movable: [CGPoint], dx: Double, dy: Double, tolerance: Double) -> (dx: Double, dy: Double, mark: CGPoint?) {
        var best: (Double, Double, CGPoint)?, distance = tolerance
        for m in movable {
            let x = m.x + dx, y = m.y + dy
            for q in pointsList {
                let d = hypot(q.x - x, q.y - y)
                if d < distance { distance = d; best = (q.x - m.x, q.y - m.y, q) }
            }
        }
        if let best { return (best.0, best.1, best.2) }
        var bx: Double?, by: Double?, mx = tolerance, my = tolerance
        for m in movable {
            for x in guides.verticals where abs(m.x + dx - x) < mx { mx = abs(m.x + dx - x); bx = x - m.x }
            for y in guides.horizontals where abs(m.y + dy - y) < my { my = abs(m.y + dy - y); by = y - m.y }
        }
        // The grid only on an axis where no guide snapped (guides first, as with a single point).
        if grid != nil {
            let (guideX, guideY) = (bx != nil, by != nil)
            for m in movable {
                if !guideX, let x = gridLine(m.x + dx, from: gridOrigin.x, tolerance: mx) { mx = abs(m.x + dx - x); bx = x - m.x }
                if !guideY, let y = gridLine(m.y + dy, from: gridOrigin.y, tolerance: my) { my = abs(m.y + dy - y); by = y - m.y }
            }
        }
        return (bx ?? dx, by ?? dy, nil)
    }
}

extension CanvasObject {
    /// Points that pull the snap while moving: the object's, or just the box when there are many.
    static func movablePoints(_ objects: [CanvasObject]) -> [CGPoint] {
        let all = objects.flatMap(\.anchors)
        guard all.count > 64, let first = objects.first else { return all }
        let box = objects.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
        return CanvasObject(shape: .ellipse, frame: box).anchors
    }
}
