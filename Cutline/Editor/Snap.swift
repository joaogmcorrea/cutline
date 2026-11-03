// Snap to point (as in Illustrator): snaps to corners, midpoints and the page center, to the points of
// other objects and to guides. Targets are computed once per gesture.
import SwiftUI

struct SnapTargets {
    private(set) var pointsList: [CGPoint]
    let guides: Guides

    @MainActor
    init(doc: Document, exclude: Set<CanvasObject.ID>, guides withGuides: Bool = true) {
        let page = CGRect(origin: .zero, size: Document.page)
        pointsList = [CGPoint(x: page.minX, y: page.minY), CGPoint(x: page.midX, y: page.minY), CGPoint(x: page.maxX, y: page.minY),
                  CGPoint(x: page.minX, y: page.midY), CGPoint(x: page.midX, y: page.midY), CGPoint(x: page.maxX, y: page.midY),
                  CGPoint(x: page.minX, y: page.maxY), CGPoint(x: page.midX, y: page.maxY), CGPoint(x: page.maxX, y: page.maxY)]
        for object in doc.objectsInOrder where doc.visible(object) && !exclude.contains(object.id) {
            pointsList.append(contentsOf: object.anchors)
        }
        // Hidden guides don't attract.
        guides = withGuides ? doc.guides : Guides()
    }

    /// Snapped point (or the point itself) and where to show the snap mark. Tolerance in mm.
    func snap(_ p: CGPoint, tolerance: Double) -> (point: CGPoint, mark: CGPoint?) {
        var best: CGPoint?, distance = tolerance
        for q in pointsList {
            let d = hypot(q.x - p.x, q.y - p.y)
            if d < distance { distance = d; best = q }
        }
        if let best { return (best, best) }
        // Guides: snap per axis.
        var q = p, didFind = false
        if let x = guides.verticals.min(by: { abs($0 - p.x) < abs($1 - p.x) }), abs(x - p.x) < tolerance { q.x = x; didFind = true }
        if let y = guides.horizontals.min(by: { abs($0 - p.y) < abs($1 - p.y) }), abs(y - p.y) < tolerance { q.y = y; didFind = true }
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
        return (bx ?? dx, by ?? dy, nil)
    }
}

extension CanvasObject {
    /// Points that pull the snap while moving: the object's, or just the box when there are many.
    static func movablePoints(_ objects: [CanvasObject]) -> [CGPoint] {
        let all = objects.flatMap(\.anchors)
        guard all.count > 64, let first = objects.first else { return all }
        let box = objects.dropFirst().reduce(first.frame.standardized) { $0.union($1.frame.standardized) }
        return CanvasObject(shape: .ellipse, frame: box).anchors
    }
}
