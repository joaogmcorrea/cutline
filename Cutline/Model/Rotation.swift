// Rotating objects, as in Illustrator: every object keeps an angle (`CanvasObject.rotation`, counterclockwise, around its
// frame's center), so a rectangle stays a rectangle with its radius, a text stays text and a polygon keeps its sides; the
// outline turns in Model/Geometry.swift. The selection's box turns with the objects when they all have the same angle
// (`RotatedBox`), and the handles stretch along it; Object › Transform › Reset Bounding Box puts it back square with the
// page (a path, a shape or an image takes the turn into its points). In the file, the outline goes already turned, with the
// angle beside it (`ObjectRotation`, Model/Document.swift).
import CoreGraphics
import Foundation

/// The selection's box: a rectangle in page mm (`rect`, as it is before the turn) turned by `angle` around its center.
nonisolated struct RotatedBox: Equatable, Sendable {
    var rect: CGRect
    /// Degrees, counterclockwise; 0 = square with the page.
    var angle: Double

    var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    /// The box's own space → the page.
    var transform: CGAffineTransform { angle == 0 ? .identity : CanvasObject.rotation(angle, around: center) }

    /// A point of the box's own space on the page.
    func page(_ p: CGPoint) -> CGPoint { p.applying(transform) }

    /// A page point in the box's own space (where the handles work).
    func local(_ p: CGPoint) -> CGPoint { angle == 0 ? p : p.applying(transform.inverted()) }

    /// A point of the box by fractions (0, 0.5, 1 on each axis: the reference point), on the page.
    func point(_ fx: Double, _ fy: Double) -> CGPoint {
        page(CGPoint(x: rect.minX + rect.width * fx, y: rect.minY + rect.height * fy))
    }

    /// The corners on the page (top-left, top-right, bottom-right, bottom-left).
    var corners: [CGPoint] { [point(0, 0), point(1, 0), point(1, 1), point(0, 1)] }
}

extension CanvasObject {
    /// Turns the object by `degrees` (counterclockwise) around a page point.
    nonisolated mutating func rotate(by degrees: Double, around center: CGPoint) {
        guard degrees != 0 else { return }
        let r = frame.standardized
        let c = pivot.applying(Self.rotation(degrees, around: center))
        frame = CGRect(x: c.x - r.width / 2, y: c.y - r.height / 2, width: r.width, height: r.height)
        rotation = Self.normalizedAngle(rotation + degrees)
    }

    /// The frame in a box's own space (the object has the box's angle): the same size, around its center brought back.
    nonisolated func frame(in box: RotatedBox) -> CGRect {
        let r = frame.standardized
        let c = box.local(pivot)
        return CGRect(x: c.x - r.width / 2, y: c.y - r.height / 2, width: r.width, height: r.height)
    }

    /// Puts the frame worked out in a box's own space back on the page (the angle stays).
    nonisolated mutating func setFrame(_ local: CGRect, in box: RotatedBox) {
        let r = local.standardized
        let c = box.page(CGPoint(x: r.midX, y: r.midY))
        frame = CGRect(x: c.x - r.width / 2, y: c.y - r.height / 2, width: r.width, height: r.height)
    }

    /// Applies a map of the page (a stretch along the page's axes, from the handles of a square box) to the object. Exact
    /// when the object stays a rectangle in some direction (upright, at 90°, or stretched evenly); otherwise the stretch
    /// slants it, as in Illustrator: a path, a shape or an image takes it into its points (the shape becomes a path); a
    /// text, which can't slant, is stretched along its own sides as near as it gets.
    mutating func transform(by m: CGAffineTransform) {
        let (s, c) = Self.sinCos(rotation)
        let r = frame.standardized
        // Where the frame's sides go: the object's own x and y directions, through the map's linear part.
        let ux = CGPoint(x: c * m.a + -s * m.c, y: c * m.b + -s * m.d)
        let uy = CGPoint(x: s * m.a + c * m.c, y: s * m.b + c * m.d)
        let lengthX = hypot(ux.x, ux.y), lengthY = hypot(uy.x, uy.y)
        let center = pivot.applying(m)
        let square = abs(ux.x * uy.x + ux.y * uy.y) <= 1e-9 * max(lengthX * lengthY, 1e-12)
        let turnsBack = ux.x * uy.y - ux.y * uy.x < 0   // a mirror (y down: x × y must stay > 0)
        if case .text = shape, !square || turnsBack {
            // Approximated: the letters keep their shape, stretched along their own sides.
            frame = CGRect(x: center.x - r.width * lengthX / 2, y: center.y - r.height * lengthY / 2,
                           width: r.width * lengthX, height: r.height * lengthY)
            rotation = Self.normalizedAngle(atan2(-ux.y, ux.x) * 180 / .pi)
            return
        }
        if square, !turnsBack {
            frame = CGRect(x: center.x - r.width * lengthX / 2, y: center.y - r.height * lengthY / 2,
                           width: r.width * lengthX, height: r.height * lengthY)
            rotation = Self.normalizedAngle(atan2(-ux.y, ux.x) * 180 / .pi)
            return
        }
        // Slanted (or mirrored): the points take it, the box keeps its angle.
        let pixelToPage = image.map { $0.transform.cg.concatenating(frameToPage).concatenating(m) }
        let nodes = absoluteNodes.map { sub in
            Subpath(nodes: sub.nodes.map { Node(point: $0.point.applying(m), input: $0.input?.applying(m), output: $0.output?.applying(m)) },
                    closed: sub.closed)
        }
        setNodes(nodes)
        if let pixelToPage, let placed = Self.inverse(frameToPage) {
            placeImage(pixelToPage.concatenating(placed))
        }
    }

    /// The inverse of a map, when it has one.
    nonisolated static func inverse(_ t: CGAffineTransform) -> CGAffineTransform? {
        abs(t.a * t.d - t.b * t.c) > 1e-12 ? t.inverted() : nil
    }

    /// Reset Bounding Box can square it with the page (a text can't: its letters only turn with the angle).
    var canResetBox: Bool {
        guard rotation != 0 else { return false }
        if case .text = shape { return false }
        return true
    }

    /// Object › Transform › Reset Bounding Box: the box squares with the page and the turn goes into the points, as
    /// Illustrator does with a path. A rectangle or an ellipse at a multiple of 90° stays one (with the box turned); any
    /// other shape becomes a path; an image keeps its place on the page (its pixels go turned into the new box); a linear
    /// gradient keeps its direction on the page.
    mutating func resetBox() {
        guard canResetBox else { return }
        let pixelToPage = image.map { $0.transform.cg.concatenating(frameToPage) }
        if let g = gradient, g.kind == .linear { gradient?.angle = Self.normalizedAngle(g.angle + rotation) }
        let r = frame.standardized
        let symmetric = switch shape {
        case .rectangle, .ellipse: true
        default: false
        }
        if symmetric, rotation.truncatingRemainder(dividingBy: 90) == 0 {
            // At 90° the same outline is the box with its sides swapped; at 180°, the box itself.
            if abs(rotation) == 90 { frame = CGRect(x: pivot.x - r.height / 2, y: pivot.y - r.width / 2, width: r.height, height: r.width) }
            rotation = 0
        } else {
            let nodes = absoluteNodes
            rotation = 0
            setNodes(nodes)
        }
        if let pixelToPage, let placed = Self.inverse(frameToPage) {
            placeImage(pixelToPage.concatenating(placed))
        }
    }
}

extension Document {
    /// The box the handles show: turned with the selection when every selected object has the same angle (one object:
    /// its own frame); square with the page otherwise, around what they cover.
    var selectionFrame: RotatedBox? {
        let chosen = selectedObjects
        guard let first = chosen.first else { return nil }
        let angle = first.rotation
        if angle != 0, chosen.allSatisfy({ $0.rotation == angle }) {
            // The frames in the space turned by `angle` around the page's origin, then the box back on the page.
            let back = CanvasObject.rotation(-angle, around: .zero)
            var union = CGRect.null
            for o in chosen {
                let r = o.frame.standardized, c = o.pivot.applying(back)
                union = union.union(CGRect(x: c.x - r.width / 2, y: c.y - r.height / 2, width: r.width, height: r.height))
            }
            let c = CGPoint(x: union.midX, y: union.midY).applying(CanvasObject.rotation(angle, around: .zero))
            return RotatedBox(rect: CGRect(x: c.x - union.width / 2, y: c.y - union.height / 2, width: union.width, height: union.height),
                              angle: angle)
        }
        return selectionBox.map { RotatedBox(rect: $0, angle: 0) }
    }

    /// Where `o` ends up when the box `box` (which holds it) becomes `newRect` (in the box's own space): the handles, the
    /// control bar's W and H.
    static func fit(_ o: CanvasObject, from box: RotatedBox, to newRect: CGRect) -> CanvasObject {
        var o = o
        if box.angle != 0 {
            // Every object has the box's angle: stretched in the box's space, as an upright box stretches upright objects.
            o.setFrame(stretch(o.frame(in: box), of: box.rect, to: newRect), in: box)
        } else if o.rotation == 0 {
            o.frame = stretch(o.frame.standardized, of: box.rect, to: newRect)
        } else {
            let old = box.rect
            let sx = old.width > 0 ? newRect.width / old.width : 1, sy = old.height > 0 ? newRect.height / old.height : 1
            o.transform(by: CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: newRect.minX - old.minX * sx, ty: newRect.minY - old.minY * sy))
        }
        return o
    }

    /// Takes the selection's box to `newRect`, worked out in the box's own space (one undo step).
    func fitSelection(_ box: RotatedBox, to newRect: CGRect) {
        guard newRect != box.rect else { return }
        modifySelection { o in o = Self.fit(o, from: box, to: newRect) }
    }

    /// Moves the selection on the page (one undo step).
    func translateSelection(dx: Double, dy: Double) {
        guard dx != 0 || dy != 0 else { return }
        modifySelection { o in o.frame = o.frame.offsetBy(dx: dx, dy: dy) }
    }

    /// Turns the selection by `degrees` (counterclockwise) around a page point (nil = the box's center), in one undo
    /// step; `copy` turns copies and leaves the originals (the Rotate window's Copy).
    func rotateSelection(by degrees: Double, around center: CGPoint? = nil, copy: Bool = false) {
        guard !selection.isEmpty, let box = selectionFrame, degrees != 0 || copy else { return }
        let pivot = center ?? box.center
        if copy {
            let copies = CanvasObject.copies(selectedObjects).map { o in
                var turned = o
                turned.rotate(by: degrees, around: pivot)
                return turned
            }
            registrar()
            objects.append(contentsOf: copies)
            selection = Set(copies.map(\.id))
        } else {
            modifySelection { $0.rotate(by: degrees, around: pivot) }
        }
    }

    /// Some selected object can square its box (Object › Transform › Reset Bounding Box).
    var canResetBoundingBox: Bool { selectedObjects.contains(where: \.canResetBox) }

    func resetBoundingBox() {
        guard canResetBoundingBox else { return }
        modifySelection { $0.resetBox() }
    }
}
