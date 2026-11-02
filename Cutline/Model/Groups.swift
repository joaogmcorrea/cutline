// Groups and object order, as in Illustrator. ⌘G groups the selection: the objects go to the layer of the one
// most in front and stay together in the stack, in its place. ⇧⌘G undoes the outermost group. Groups nest:
// `CanvasObject.groups` keeps the ids from the outermost to the innermost. Clicking an object in a group selects the whole
// group (the outermost); double click, direct selection and the Layers panel take only it. Arrange (⇧⌘] ⌘]
// ⌘[ ⇧⌘[) moves the selection in its own layer's stack, each group as a single piece.
import Foundation

nonisolated enum Arrangement: CaseIterable, Identifiable, Sendable {
    case front, forward, backward, back

    var id: Self { self }

    var name: String {
        switch self {
        case .front: String(localized: "Bring to Front")
        case .forward: String(localized: "Bring Forward")
        case .backward: String(localized: "Send Backward")
        case .back: String(localized: "Send to Back")
        }
    }
}

/// A whole outermost group (or a loose object) in a layer's stack.
nonisolated struct StackPiece {
    var objects: [CanvasObject]
    var selected: Bool
}

extension CanvasObject {
    /// Copies with new ids, offset; groups also get new ids (the copies of a group form another one).
    static func copies(_ originals: [CanvasObject], offset: CGSize = .zero) -> [CanvasObject] {
        var newItems: [UUID: UUID] = [:]
        return originals.map { original in
            var copy = original
            copy.id = UUID()
            copy.groups = original.groups.map { group in
                if let updated = newItems[group] { return updated }
                let updated = UUID()
                newItems[group] = updated
                return updated
            }
            copy.frame = original.frame.offsetBy(dx: offset.width, dy: offset.height)
            return copy
        }
    }
}

extension Document {
    /// What a click on the object selects: its whole outermost group (without hidden and locked ones), or just it.
    func unit(of id: CanvasObject.ID) -> Set<CanvasObject.ID> {
        guard let group = objects.first(where: { $0.id == id })?.groups.first else { return [id] }
        return Set(objects.filter { $0.groups.first == group && !untouchable($0) }.map(\.id)).union([id])
    }

    /// The objects and their whole outermost groups (area selection).
    func withGroups(_ ids: Set<CanvasObject.ID>) -> Set<CanvasObject.ID> {
        let groups = Set(objects.filter { ids.contains($0.id) }.compactMap(\.groups.first))
        return ids.union(objects.filter { $0.groups.first.map(groups.contains) == true && !untouchable($0) }.map(\.id))
    }

    /// The selection in pieces: each outermost group is one; each loose object, another.
    var selectedPieces: [[CanvasObject]] {
        var order: [UUID] = [], pieces: [UUID: [CanvasObject]] = [:]
        for object in selectedObjects {
            let key = object.groups.first ?? object.id
            if pieces[key] == nil { order.append(key) }
            pieces[key, default: []].append(object)
        }
        return order.map { pieces[$0]! }
    }

    /// The selection is a single (outermost) group.
    var selectionIsAGroup: Bool {
        let pieces = selectedPieces
        return pieces.count == 1 && pieces[0].first?.groups.isEmpty == false
    }

    var canGroup: Bool { selectedPieces.count > 1 }
    var canUngroup: Bool { selectedObjects.contains { !$0.groups.isEmpty } }

    func groupSelected() {
        guard canGroup, let front = objectsInOrder.last(where: { selection.contains($0.id) }) else { return }
        registrar()
        let group = UUID()
        for i in objects.indices where selection.contains(objects[i].id) {
            objects[i].groups.insert(group, at: 0)
            objects[i].layer = front.layer
        }
        objects = stack { $0 }
    }

    /// Undoes the selected objects' outermost group (the inner ones remain); the selection stays.
    func ungroupSelected() {
        guard canUngroup else { return }
        registrar()
        for i in objects.indices where selection.contains(objects[i].id) && !objects[i].groups.isEmpty {
            objects[i].groups.removeFirst()
        }
    }

    func arrange(_ mode: Arrangement) {
        guard !selection.isEmpty else { return }
        let newOne = stack { pieces in
            var p = pieces
            switch mode {
            case .front: return p.filter { !$0.selected } + p.filter(\.selected)
            case .back: return p.filter(\.selected) + p.filter { !$0.selected }
            case .forward:
                // Front to back, each selected piece becomes the top one (its neighbors move up together).
                for i in stride(from: p.count - 2, through: 0, by: -1) where p[i].selected && !p[i + 1].selected {
                    p.swapAt(i, i + 1)
                }
            case .backward:
                for i in p.indices.dropFirst() where p[i].selected && !p[i - 1].selected {
                    p.swapAt(i, i - 1)
                }
            }
            return p
        }
        guard newOne.map(\.id) != objects.map(\.id) else { return }
        registrar()
        objects = newOne
    }

    /// The stack rebuilt per layer: the pieces (a whole outermost group, or an object; the selected part of a group
    /// is another piece) take the place of each one's frontmost object and `change` reorders them.
    private func stack(_ change: ([StackPiece]) -> [StackPiece]) -> [CanvasObject] {
        var layerOrder: [UUID] = [], byLayer: [UUID: [CanvasObject]] = [:]
        for object in objects {
            let layer = layer(of: object).id
            if byLayer[layer] == nil { layerOrder.append(layer) }
            byLayer[layer, default: []].append(object)
        }
        return layerOrder.flatMap { layer -> [CanvasObject] in
            var keys: [String] = [], pieces: [String: StackPiece] = [:], front: [String: Int] = [:]
            for (i, object) in byLayer[layer]!.enumerated() {
                let selected = selection.contains(object.id)
                let key = (object.groups.first ?? object.id).uuidString + (selected ? "*" : "")
                if pieces[key] == nil {
                    keys.append(key)
                    pieces[key] = StackPiece(objects: [], selected: selected)
                }
                pieces[key]!.objects.append(object)
                front[key] = i
            }
            return change(keys.sorted { front[$0]! < front[$1]! }.map { pieces[$0]! }).flatMap(\.objects)
        }
    }
}
