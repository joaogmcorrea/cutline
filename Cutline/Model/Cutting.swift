// Cut by line color (Silhouette Studio's model): each stroke color has a material and settings, and can be turned off.
import CutlineKit
import SwiftUI

nonisolated struct Material: Hashable, Identifiable, Codable, Sendable {

    /// The keys stored on disk keep the names of the 1.0 format (Portuguese), so older files still open.

    enum CodingKeys: String, CodingKey {

        case name = "nome", settings = "ajustes"

    }

    let name: String
    let settings: CutSettings
    var id: String { name }

    /// The two sticker paper ones were validated on the Portrait 4; the others are guesses to calibrate.
    static let all = [
        Material(name: "Papel adesivo — meio-corte", settings: CutSettings(speed: 5, force: 8, blade: 1, passes: 1)),
        Material(name: "Papel adesivo — corte total", settings: CutSettings(speed: 3, force: 25, blade: 5, passes: 2)),
        Material(name: "Cartolina lisa", settings: CutSettings(speed: 4, force: 20, blade: 3, passes: 1)),
        Material(name: "Papel sulfite 75 g", settings: CutSettings(speed: 5, force: 10, blade: 2, passes: 1)),
        Material(name: "Papel fotográfico", settings: CutSettings(speed: 5, force: 18, blade: 3, passes: 1)),
        Material(name: "Vinil adesivo", settings: CutSettings(speed: 5, force: 10, blade: 1, passes: 1)),
    ]

    /// Only the app's (the user's are in `GlobalSettings`).
    static func named(_ name: String) -> Material? { all.first { $0.name == name } }

    /// On screen: the app's ones translated; the user's as they wrote them. The Portuguese name is still
    /// what goes into the file (so a file opens the same in any language).
    static func show(_ name: String) -> String {
        named(name) != nil ? String(localized: String.LocalizationValue(name)) : name
    }
}

nonisolated struct CutConfig: Hashable, Codable, Sendable {
    var enabled = true
    var material: String
    var settings: CutSettings

    init(material: Material) {
        self.material = material.name
        self.settings = material.settings
    }

    private enum CodingKeys: String, CodingKey { case enabled = "ligado", action = "acao", material, settings = "ajustes" }

    /// Up to 0.7.1 there was also a Cut/Don't cut action, which did the same as turning the color off: "Não cortar"
    /// ("Don't cut") from an old file (or from the app's memory) opens turned off.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        material = try c.decode(String.self, forKey: .material)
        settings = try c.decode(CutSettings.self, forKey: .settings)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        if try c.decodeIfPresent(String.self, forKey: .action) == "Não cortar" { enabled = false }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(material, forKey: .material)
        try c.encode(settings, forKey: .settings)
    }

    var sends: Bool { enabled }
    /// The material's values (the app's or "My materials"); nil if the material doesn't exist here (file from
    /// another Mac, deleted material) — the file's settings still apply.
    @MainActor var materialValues: CutSettings? { GlobalSettings.shared.material(material)?.settings }
    @MainActor var modified: Bool { materialValues.map { $0 != settings } ?? false }
}

/// The objects that have the same stroke color.
struct CutLine: Identifiable {
    let color: CMYK
    let objects: [CanvasObject]
    var id: CMYK { color }

    /// Paths in mm ready for the machine (curves become segments with up to 0.02 mm of deviation; dashed
    /// lines become separate pieces).
    var polylines: [[CGPoint]] {
        objects.flatMap { object in
            let lines = object.shapePath.cgPath.cutPolylines()
            guard let defaultValue = object.style.line.defaultValue else { return lines }
            return lines.flatMap { $0.dashed(defaultValue.map { CGFloat($0) }) }
        }
    }

    var lengthMM: Double {
        polylines.reduce(0) { total, line in
            total + zip(line, line.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        }
    }
}

extension Document {
    /// The file's; else, the ones the app remembers for this color; else, the default.
    func config(_ color: CMYK) -> CutConfig { cuts[color] ?? GlobalSettings.shared.byColor[color] ?? Self.defaultConfig(color) }

    /// Magenta = kiss cut (tracing contour); other colors start as cardstock.
    nonisolated static func defaultConfig(_ color: CMYK) -> CutConfig {
        let magenta = CMYK(c: 0, m: 100, y: 0, k: 0)
        return CutConfig(material: Material.named(color == magenta ? "Papel adesivo — meio-corte" : "Cartolina lisa")!)
    }

    /// Stores in the file (with undo) and in the app, for the next files.
    func setConfig(_ config: CutConfig, to color: CMYK) {
        GlobalSettings.shared.remember(config, to: color)
        guard cuts[color] != config else { return }
        registerAdjustment("cut \(color.summaryText)")
        cuts[color] = config
    }

    /// On send: the settings of all the table's colors are kept in the file (even the ones that came
    /// from the default or the app's memory), so the file reopens exactly as it was cut.
    func pinSendSettings() {
        let lines = cutLines
        for line in lines { GlobalSettings.shared.remember(config(line.color), to: line.color) }
        let missing = lines.filter { cuts[$0.color] == nil }
        let order = lines.map(\.color)
        guard !missing.isEmpty || cutOrder != order else { return }
        registrar()
        for line in missing { cuts[line.color] = config(line.color) }
        cutOrder = order
    }

    /// One row per stroke color, in the chosen order; new colors go in by force
    /// (lightest first: the inner kiss cut before the outer die cut). Left out are
    /// objects without a stroke (they don't cut), hidden ones and those entirely outside the page (as in Studio).
    var cutLines: [CutLine] {
        var arrivalOrder: [CMYK] = []
        var groups: [CMYK: [CanvasObject]] = [:]
        let page = CGRect(origin: .zero, size: Self.page)
        for object in objectsInOrder where object.cutsLine && visible(object) && object.shapePath.boundingRect.intersects(page) {
            if groups[object.strokeColor] == nil { arrivalOrder.append(object.strokeColor) }
            groups[object.strokeColor, default: []].append(object)
        }
        let position = { (color: CMYK) -> Int in self.cutOrder.firstIndex(of: color) ?? 1000 + self.config(color).settings.force }
        return arrivalOrder
            .sorted { position($0) < position($1) }
            .map { CutLine(color: $0, objects: groups[$0]!) }
    }

    func moveLine(_ color: CMYK, upward: Bool) {
        var order = cutLines.map(\.color)
        guard let i = order.firstIndex(of: color) else { return }
        let j = upward ? i - 1 : i + 1
        guard order.indices.contains(j) else { return }
        order.swapAt(i, j)
        registrar()
        cutOrder = order
    }

    /// Dragging in the table: the color goes to position `destination`. A drag that passes several rows becomes a
    /// single undo step.
    func moveLine(_ color: CMYK, to destination: Int) {
        var order = cutLines.map(\.color)
        guard let i = order.firstIndex(of: color), order.indices.contains(destination), i != destination else { return }
        order.remove(at: i)
        order.insert(color, at: destination)
        registerAdjustment("cut order")
        cutOrder = order
    }

    /// What goes to the machine: only the enabled colors with the "Cut" action, in the table's order.
    var layersToSend: [CutLayer] {
        cutLines.compactMap { line in
            let config = config(line.color)
            guard config.sends else { return nil }
            return CutLayer(name: "\(config.material) (\(line.color.summaryText))", paths: line.polylines,
                            settings: config.settings)
        }
    }
}

// MARK: - Test cut

/// Test cut (like Silhouette Studio's): a square with a triangle inside, at the spot chosen in the
/// Send window's preview and with one color's settings, to check the blade before cutting everything.
nonisolated enum TestCut {
    static let side = 10.0

    /// In page mm: the inner triangle first and the square last (the piece doesn't come loose earlier).
    static func paths(in p: CGPoint) -> [[CGPoint]] {
        let l = side, m = 2.0
        let triangle = [CGPoint(x: p.x + l / 2, y: p.y + m), CGPoint(x: p.x + l - m, y: p.y + l - m),
                         CGPoint(x: p.x + m, y: p.y + l - m), CGPoint(x: p.x + l / 2, y: p.y + m)]
        return [triangle, TestShapes.square(x: p.x, y: p.y, side: l)]
    }
}

extension Document {
    /// Where the test can go: between the marks with Print & Cut (the rest isn't cut); otherwise, on the page.
    var testAreaOf: CGRect { marks ? marksConfig.area : CGRect(origin: .zero, size: Self.page) }

    /// Puts the test at a spot on the sheet (without going past the area).
    func moveTest(to p: CGPoint) {
        let a = testAreaOf, l = TestCut.side
        testPosition = CGPoint(x: min(max(p.x, a.minX), a.maxX - l), y: min(max(p.y, a.minY), a.maxY - l))
    }

    /// Just the test, with the color's settings; with Print & Cut the machine reads the marks first, as in the real cut.
    func testJob(_ color: CMYK) -> Job {
        moveTest(to: testPosition)
        let config = config(color)
        let layer = CutLayer(name: String(localized: "Test cut (\(Material.show(config.material)))"),
                              paths: TestCut.paths(in: testPosition), settings: config.settings)
        return Job(name: String(localized: "Test cut"), origin: ObjectIdentifier(self), layers: [layer],
                        logLines: registrationToSend, withMat: withMat, base: cuttingMatSetting)
    }
}
