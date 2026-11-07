// Layers, as in Illustrator: the top one in the panel is drawn last; each can be
// hidden (gone from the canvas and from the cut) or locked (can't be selected). Objects can also be hidden and locked.
import SwiftUI

nonisolated struct Layer: Identifiable, Hashable, Codable, Sendable {

    /// The keys stored on disk keep the names of the 1.0 format (Portuguese), so older files still open.

    enum CodingKeys: String, CodingKey {

        case id, name = "nome", color = "cor", visible = "visivel", locked = "travada", isOpen = "aberta", opacity = "opacidade", blend = "mesclagem"

    }

    var id = UUID()
    var name: String
    /// Index in `Layer.colors` (color of the bar and of the selection).
    var color: Int
    var visible = true
    var locked = false
    /// Shows the layer's objects in the panel.
    var isOpen = true
    /// Opacity of what the layer prints, 0–100 %; nil = 100 (files without it stay as before).
    var opacity: Double?
    /// How the layer mixes with what is below it, as Illustrator's blending modes; nil = Normal.
    var blend: LayerBlend?

    init(name: String, color: Int) {
        self.name = name
        self.color = color
    }

    /// Tolerant reading: what is missing keeps the default; a blending mode a later version wrote is Normal here.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        color = try c.decodeIfPresent(Int.self, forKey: .color) ?? 0
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        isOpen = try c.decodeIfPresent(Bool.self, forKey: .isOpen) ?? true
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity).map { min(max($0, 0), 100) }
        blend = (try? c.decodeIfPresent(LayerBlend.self, forKey: .blend)).flatMap { $0 }
    }

    /// Opacity 100 % and Normal: drawn as always, straight on the page.
    var isPlain: Bool { (opacity ?? 100) >= 100 && (blend ?? .normal) == .normal }
    var alpha: Double { min(max(opacity ?? 100, 0), 100) / 100 }

    /// The prototype's.
    static let colors: [Color] = [0x4F8DF5, 0xE5484D, 0x30A46C, 0x8E4EC6, 0xF5A524, 0xE93D82, 0x12A594].map {
        Color(.sRGB, red: Double(($0 >> 16) & 0xFF) / 255, green: Double(($0 >> 8) & 0xFF) / 255, blue: Double($0 & 0xFF) / 255)
    }

    var barColor: Color { Self.colors[((color % Self.colors.count) + Self.colors.count) % Self.colors.count] }
}

/// Illustrator's blending modes (all of them exist in Core Graphics, and in a PDF). The values stored on disk follow the
/// rest of the .cutline format (Portuguese).
nonisolated enum LayerBlend: String, Codable, CaseIterable, Identifiable, Sendable {
    case normal
    case darken = "escurecer", multiply = "multiplicar", colorBurn = "superexporCor"
    case lighten = "clarear", screen = "tela", colorDodge = "subexporCor"
    case overlay = "sobrepor", softLight = "luzSuave", hardLight = "luzForte"
    case difference = "diferenca", exclusion = "exclusao"
    case hue = "matiz", saturation = "saturacao", color = "cor", luminosity = "luminosidade"

    var id: Self { self }

    /// Illustrator's groups in its menu.
    static let groups: [[LayerBlend]] = [[.normal], [.darken, .multiply, .colorBurn], [.lighten, .screen, .colorDodge],
                                         [.overlay, .softLight, .hardLight], [.difference, .exclusion],
                                         [.hue, .saturation, .color, .luminosity]]

    var cg: CGBlendMode {
        switch self {
        case .normal: .normal
        case .darken: .darken
        case .multiply: .multiply
        case .colorBurn: .colorBurn
        case .lighten: .lighten
        case .screen: .screen
        case .colorDodge: .colorDodge
        case .overlay: .overlay
        case .softLight: .softLight
        case .hardLight: .hardLight
        case .difference: .difference
        case .exclusion: .exclusion
        case .hue: .hue
        case .saturation: .saturation
        case .color: .color
        case .luminosity: .luminosity
        }
    }
}

extension Document {
    /// The visible objects in drawing order (bottom layers first), in runs of one layer each: a layer with opacity or a
    /// blending mode is drawn as a group, mixed with what is under it (Printing.render, the canvas).
    var layerRuns: [(layer: Layer, objects: [CanvasObject])] {
        var runs: [(layer: Layer, objects: [CanvasObject])] = []
        for object in objectsInOrder where visible(object) {
            let layer = layer(of: object)
            if runs.last?.layer.id == layer.id { runs[runs.count - 1].objects.append(object) } else { runs.append((layer, [object])) }
        }
        return runs
    }

    /// The layer's opacity (0–100 %; 100 = none). `final` false (dragging the slider) merges the steps into one undo.
    func setLayerOpacity(_ id: Layer.ID, _ percent: Double, final: Bool = true) {
        guard let i = layers.firstIndex(where: { $0.id == id }) else { return }
        let value = min(max(percent.rounded(), 0), 100)
        let stored: Double? = value >= 100 ? nil : value
        guard layers[i].opacity != stored else { return }
        if final { registrar() } else { registerAdjustment("layer opacity \(id)") }
        layers[i].opacity = stored
    }

    func setLayerBlend(_ id: Layer.ID, _ mode: LayerBlend) {
        let stored: LayerBlend? = mode == .normal ? nil : mode
        guard let layer = layers.first(where: { $0.id == id }), layer.blend != stored else { return }
        modifyLayer(id) { $0.blend = stored }
    }

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
        pinLayers()
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

    /// Objects without a layer (or with one that no longer exists) belong to the top one: each says so, before something
    /// goes on top (a new layer, merged layers), so they don't move into it. Opening a document already does it; this is
    /// for objects that got in some other way.
    func pinLayers() {
        let known = Set(layers.map(\.id))
        for i in objects.indices where objects[i].layer.map(known.contains) != true { objects[i].layer = layers[0].id }
    }

    /// Selects everything that can be moved in the layer (and makes it active).
    func selectLayer(_ layer: Layer) {
        activeLayer = layer.id
        selection = Set(objects(of: layer).filter { !untouchable($0) }.map(\.id))
    }

    /// Select › Same › Fill Color / Stroke Color, as in Illustrator: every object (one by one, also inside groups,
    /// in any layer; not the hidden or locked ones) with the same color as one of the selected objects. The stroke color
    /// defines the cut, so this picks all the lines of a cut; "none" picks the ones that don't cut (or have no fill).
    /// An image counts as its own fill, apart from "none".
    func selectSame(_ target: ColorTarget) {
        let key = { (o: CanvasObject) -> SameKey in
            switch target {
            case .strokeColor: o.cutsLine ? .color(o.strokeColor) : .none
            case .fill: o.image != nil ? .image : o.fill == nil ? .none : o.gradient.map(SameKey.gradient) ?? o.fill.map(SameKey.color) ?? .none
            }
        }
        let keys = Set(selectedObjects.map(key))
        guard !keys.isEmpty else { return }
        if textEditing != nil { finishText() }
        selection = Set(objects.filter { !untouchable($0) && keys.contains(key($0)) }.map(\.id))
    }
}

/// What Select › Same compares.
nonisolated private enum SameKey: Hashable {
    case color(CMYK), gradient(GradientFill), none, image
}
