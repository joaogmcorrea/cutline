// Control bar (as in the prototype): align, position and size of the selection — one or several objects —
// and convert a parametric shape into a path.
import SwiftUI

nonisolated enum AlignMode: String, CaseIterable, Identifiable, Sendable {
    case left, centerH, right, center, top, centerV, base

    var id: Self { self }

    /// In Assets.xcassets (prototype icons).
    var icon: String {
        switch self {
        case .left: "alignLeft"
        case .centerH: "alignCenterH"
        case .right: "alignRight"
        case .center: "alignCenter"
        case .top: "alignTop"
        case .centerV: "alignCenterV"
        case .base: "alignBottom"
        }
    }

    var name: String {
        switch self {
        case .left: String(localized: "left")
        case .centerH: String(localized: "center (horizontal)")
        case .right: String(localized: "right")
        case .center: String(localized: "center (horizontal and vertical)")
        case .top: String(localized: "top")
        case .centerV: String(localized: "center (vertical)")
        case .base: String(localized: "bottom")
        }
    }
}

/// Equal gaps between 3 or more pieces (Silhouette Studio's Space Horizontally/Vertically, Illustrator's
/// Distribute Spacing).
nonisolated enum SpacingAxis: CaseIterable, Identifiable, Sendable {
    case horizontal, vertical

    var id: Self { self }

    /// In Assets.xcassets (Tabler).
    var icon: String { self == .horizontal ? "spaceHorizontally" : "spaceVertically" }

    var name: String {
        switch self {
        case .horizontal: String(localized: "Space Horizontally")
        case .vertical: String(localized: "Space Vertically")
        }
    }
}

extension ShapeKind {
    /// Rectangle, ellipse and star: they have parameters and turn into a path to edit the nodes.
    nonisolated var parametric: Bool {
        switch self {
        case .rectangle, .ellipse, .star: true
        case .shapePath, .text: false
        }
    }
}

extension CanvasObject {
    /// Rectangle, ellipse, star and polygon: they have parameters and turn into a path to edit the nodes.
    var isParametric: Bool { shape.parametric || polygonSides != nil }
}

extension Document {
    /// Selection box, in mm, square with the page: what the objects cover (a rotated one, its turned outline).
    var selectionBox: CGRect? {
        let frames = selectedObjects.map(\.bounds)
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    /// One piece (an object, or a whole group): aligns to the sheet; several: to the selection box (as in the prototype
    /// and in Illustrator). A group moves as a whole.
    func align(_ mode: AlignMode) {
        guard let box = selectionBox else { return }
        let pieces = selectedPieces
        let target = pieces.count == 1 ? activeArtboard.rect : box
        registrar()
        for piece in pieces {
            let b = piece.dropFirst().reduce(piece[0].bounds) { $0.union($1.bounds) }
            let dx: Double = switch mode {
            case .left: target.minX - b.minX
            case .centerH, .center: target.midX - b.midX
            case .right: target.maxX - b.maxX
            default: 0
            }
            let dy: Double = switch mode {
            case .top: target.minY - b.minY
            case .centerV, .center: target.midY - b.midY
            case .base: target.maxY - b.maxY
            default: 0
            }
            let ids = Set(piece.map(\.id))
            for i in objects.indices where ids.contains(objects[i].id) {
                objects[i].frame = objects[i].frame.standardized.offsetBy(dx: dx, dy: dy)
            }
        }
    }

    /// Space needs at least three pieces (a group counts as one).
    var canDistribute: Bool { selectedPieces.count >= 3 }

    /// The same gap between the pieces along the axis. The first and the last (by their centers) stay put; the others
    /// move between them in the same order, keeping their sizes. With more width than room, the gap is negative
    /// and they overlap evenly (as in Studio and Illustrator).
    func distribute(_ axis: SpacingAxis) {
        let horizontal = axis == .horizontal
        let pieces = selectedPieces.map { piece in
            (ids: Set(piece.map(\.id)), box: piece.dropFirst().reduce(piece[0].bounds) { $0.union($1.bounds) })
        }
        guard pieces.count >= 3 else { return }
        let start = { (r: CGRect) in horizontal ? r.minX : r.minY }
        let length = { (r: CGRect) in horizontal ? r.width : r.height }
        let center = { (r: CGRect) in horizontal ? r.midX : r.midY }
        let sorted = pieces.sorted { (center($0.box), start($0.box)) < (center($1.box), start($1.box)) }
        let first = sorted[0].box, last = sorted[sorted.count - 1].box
        let room = start(last) + length(last) - start(first)
        let gap = (room - sorted.reduce(0) { $0 + length($1.box) }) / Double(sorted.count - 1)
        var moves: [CanvasObject.ID: Double] = [:]
        var position = start(first) + length(first) + gap
        for piece in sorted.dropFirst().dropLast() {
            let delta = position - start(piece.box)
            if abs(delta) > 1e-9 { for id in piece.ids { moves[id] = delta } }
            position += length(piece.box) + gap
        }
        guard !moves.isEmpty else { return }
        registrar()
        for i in objects.indices {
            guard let delta = moves[objects[i].id] else { continue }
            objects[i].frame = objects[i].frame.standardized.offsetBy(dx: horizontal ? delta : 0, dy: horizontal ? 0 : delta)
        }
    }

    /// Takes the selection box to `newOne`: moves and stretches each object in the same proportion.
    func fitSelection(to newOne: CGRect) {
        guard let old = selectionBox, old != newOne else { return }
        modifySelection { o in o.frame = Self.stretch(o.frame.standardized, of: old, to: newOne) }
    }

    /// Where frame `q` ends up when box `old` (which contains it) becomes `newOne`.
    static func stretch(_ q: CGRect, of old: CGRect, to newOne: CGRect) -> CGRect {
        let sx = old.width > 0 ? newOne.width / old.width : 1
        let sy = old.height > 0 ? newOne.height / old.height : 1
        return CGRect(x: newOne.minX + (q.minX - old.minX) * sx, y: newOne.minY + (q.minY - old.minY) * sy,
                      width: max(q.width * sx, 0.1), height: max(q.height * sy, 0.1))
    }

    /// Rectangle, ellipse, star or polygon → free path (same outline), already in direct selection.
    func convertToPath() {
        guard selectedObjects.contains(where: \.isParametric) else { return }
        modifySelection { o in if o.isParametric { o.setNodes(o.absoluteNodes) } }
        tool = .direct
    }

    /// Some text with letters in the selection (or being typed) to convert to outlines.
    var hasTextToOutline: Bool {
        if objectBeingEdited.map({ !$0.emptyText }) == true { return true }
        return selectedObjects.contains { if case .text = $0.shape { !$0.emptyText } else { false } }
    }

    /// Text → outlines (Illustrator's Create Outlines, ⇧⌘O): each selected text, or the one being typed, becomes
    /// a free path with the letters' outline, the same the machine would cut. It stays at the same place in the stack,
    /// with the same colors, and the name is still the text; the points are edited with direct selection. It doesn't go back
    /// to being text (only with ⌘Z). Returns how many texts it converted.
    @discardableResult
    func convertTextToOutlines() -> Int {
        if textEditing != nil {
            finishText()
            tool = .selection
        }
        var curves: [CanvasObject.ID: (frame: CGRect, subpaths: [Subpath], name: String)] = [:]
        for object in selectedObjects {
            // A rotated text keeps its angle (and its box turned): the letters before the rotation.
            guard case .text(let text) = object.shape, let free = CanvasObject.freePath(object.localPath.cgPath) else { continue }
            let name = text.content.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            curves[object.id] = (free.frame, free.subpaths, name)
        }
        guard !curves.isEmpty else { return 0 }
        registrar()
        for i in objects.indices {
            guard let curve = curves[objects[i].id] else { continue }
            objects[i].shape = .shapePath(curve.subpaths)
            objects[i].setLocalFrame(curve.frame)
            objects[i].textPath = nil
            if objects[i].label == nil, !curve.name.isEmpty { objects[i].label = curve.name }
        }
        if tool == .text || tool == .typeOnPath { tool = .selection }
        return curves.count
    }

    /// Closes the selection's open subpaths (pen).
    func closePaths() {
        modifySelection { o in
            guard case .shapePath(var subs) = o.shape else { return }
            for i in subs.indices { subs[i].closed = true }
            o.shape = .shapePath(subs)
        }
    }
}
