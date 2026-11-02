// Layers, as in Illustrator: the top one in the panel is drawn last; each can be
// hidden (gone from the canvas and from the cut) or locked (can't be selected). Objects can also be hidden and locked.
import SwiftUI

nonisolated struct Layer: Identifiable, Hashable, Codable, Sendable {

    /// The keys stored on disk keep the names of the 1.0 format (Portuguese), so older files still open.

    enum CodingKeys: String, CodingKey {

        case id, name = "nome", color = "cor", visible = "visivel", locked = "travada", isOpen = "aberta"

    }

    var id = UUID()
    var name: String
    /// Index in `Layer.colors` (color of the bar and of the selection).
    var color: Int
    var visible = true
    var locked = false
    /// Shows the layer's objects in the panel.
    var isOpen = true

    /// The prototype's.
    static let colors: [Color] = [0x4F8DF5, 0xE5484D, 0x30A46C, 0x8E4EC6, 0xF5A524, 0xE93D82, 0x12A594].map {
        Color(.sRGB, red: Double(($0 >> 16) & 0xFF) / 255, green: Double(($0 >> 8) & 0xFF) / 255, blue: Double($0 & 0xFF) / 255)
    }

    var barColor: Color { Self.colors[((color % Self.colors.count) + Self.colors.count) % Self.colors.count] }
}

extension Document {
    /// The object's layer (the top one, if its own no longer exists).
    func layer(of object: CanvasObject) -> Layer {
        layers.first { $0.id == object.layer } ?? layers[0]
    }

    func visible(_ object: CanvasObject) -> Bool { !object.isHidden && layer(of: object).visible }

    /// Locked or hidden: can't be selected or moved.
    func untouchable(_ object: CanvasObject) -> Bool { object.isLocked || layer(of: object).locked || !visible(object) }

    /// Back to front: bottom layers first; inside a layer, the objects' order.
    var objectsInOrder: [CanvasObject] {
        let position = Dictionary(uniqueKeysWithValues: layers.enumerated().map { ($0.element.id, $0.offset) })
        return objects.enumerated()
            .sorted { a, b in
                let ca = position[a.element.layer ?? layers[0].id] ?? 0, cb = position[b.element.layer ?? layers[0].id] ?? 0
                return ca != cb ? ca > cb : a.offset < b.offset
            }
            .map(\.element)
    }

    func objects(of layer: Layer) -> [CanvasObject] { objects.filter { self.layer(of: $0).id == layer.id } }

    // MARK: Layer editing (each one is an undo step)

    func modifyLayer(_ id: Layer.ID, _ change: (inout Layer) -> Void) {
        guard let i = layers.firstIndex(where: { $0.id == id }) else { return }
        registrar()
        change(&layers[i])
        // Hidden or locked stays unselected.
        selection = selection.filter { id in objects.first { $0.id == id }.map { !untouchable($0) } ?? false }
    }

    func modifyObject(_ id: CanvasObject.ID, _ change: (inout CanvasObject) -> Void) {
        guard let i = objects.firstIndex(where: { $0.id == id }) else { return }
        registrar()
        change(&objects[i])
        if untouchable(objects[i]) { selection.remove(id) }
    }

    func newLayer() {
        registrar()
        let newOne = Layer(name: String(localized: "Layer \(layers.count + 1)"), color: layers.count)
        layers.insert(newOne, at: 0)
        activeLayer = newOne.id
    }

    /// Deletes the active layer and its objects (there is always at least one left).
    func deleteActiveLayer() {
        guard layers.count > 1, let target = layers.first(where: { $0.id == activeLayer }) else { return }
        registrar()
        let ids = Set(objects(of: target).map(\.id))
        objects.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
        layers.removeAll { $0.id == target.id }
        activeLayer = layers[0].id
    }

    func moveSelectionToActiveLayer() {
        guard !selection.isEmpty else { return }
        modifySelection { $0.layer = activeLayer }
    }

    /// Selects everything that can be moved in the layer (and makes it active).
    func selectLayer(_ layer: Layer) {
        activeLayer = layer.id
        selection = Set(objects(of: layer).filter { !untouchable($0) }.map(\.id))
    }
}
