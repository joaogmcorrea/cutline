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
    /// Tool holder 1 or 2 and what is in it (experimental: not tried on a machine yet, besides the blade in holder 1).
    var holder = 1
    var tool = CutTool.blade

    init(material: Material) {
        self.material = material.name
        self.settings = material.settings
    }

    /// The keys stored on disk keep the names of the 1.0 format (Portuguese), so older files still open; the newer
    /// ones follow them.
    private enum CodingKeys: String, CodingKey {
        case enabled = "ligado", action = "acao", material, settings = "ajustes", holder = "suporte", tool = "ferramenta"
    }

    /// Up to 0.7.1 there was also a Cut/Don't cut action, which did the same as turning the color off: "Não cortar"
    /// ("Don't cut") from an old file (or from the app's memory) opens turned off.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        material = try c.decode(String.self, forKey: .material)
        settings = try c.decode(CutSettings.self, forKey: .settings)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        if try c.decodeIfPresent(String.self, forKey: .action) == "Não cortar" { enabled = false }
        holder = try c.decodeIfPresent(Int.self, forKey: .holder) ?? 1
        // A tool this version doesn't know (from a newer file) falls back to the blade.
        tool = (try? c.decodeIfPresent(CutTool.self, forKey: .tool)) ?? .blade
    }

    /// Holder and tool only when they aren't the default: files that don't use them stay as before.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(material, forKey: .material)
        try c.encode(settings, forKey: .settings)
        if holder != 1 { try c.encode(holder, forKey: .holder) }
        if tool != .blade { try c.encode(tool, forKey: .tool) }
    }

    /// Something other than the blade in holder 1 (the experimental part).
    var experimentalTool: Bool { holder != 1 || tool != .blade }

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
                            settings: config.settings, holder: config.holder, tool: config.tool)
        }
    }
}

// MARK: - Test cut

/// Test cut: a square with a C (for Cutline) inside, at the spot chosen in the Send window's preview, in the size
/// chosen there, and with one color's settings, to check the blade before cutting everything.
nonisolated enum TestCut {
    /// Side of the square, in mm.
    static let defaultSide = 10.0
    static let sides = 5.0...30.0

    /// In page mm: the inner C first and the square last (the piece doesn't come loose earlier).
    static func paths(in p: CGPoint, side: Double) -> [[CGPoint]] {
        [letterC(center: CGPoint(x: p.x + side / 2, y: p.y + side / 2), side: side),
         TestShapes.square(x: p.x, y: p.y, side: side)]
    }

    /// A closed C with round ends, open to the right, in the middle 60% of the square.
    private static func letterC(center c: CGPoint, side: Double) -> [CGPoint] {
        let outer = 0.3 * side, weight = 0.15 * side, inner = outer - weight, middle = outer - weight / 2
        let opening = 45.0 * .pi / 180, steps = 72
        let direction = { (a: Double) in CGPoint(x: cos(a), y: sin(a)) }
        let point = { (center: CGPoint, r: Double, d: CGPoint) in CGPoint(x: center.x + r * d.x, y: center.y + r * d.y) }
        /// From angle a to angle b (y points down, so growing angles turn clockwise on the sheet).
        let arc = { (r: Double, a: Double, b: Double) -> [CGPoint] in
            let n = max(2, Int((abs(b - a) / (2 * .pi) * Double(steps)).rounded(.up)))
            return (0...n).map { point(c, r, direction(a + (b - a) * Double($0) / Double(n))) }
        }
        /// Half circle joining the outer and inner arcs at angle a, bulging toward the opening (sign).
        let end = { (a: Double, sign: Double) -> [CGPoint] in
            let capCenter = point(c, middle, direction(a)), d = direction(a), t = CGPoint(x: -d.y * sign, y: d.x * sign)
            return (1..<(steps / 4)).map {
                let b = Double($0) / Double(steps / 4) * .pi
                let along = sign > 0 ? cos(b) : -cos(b)
                return CGPoint(x: capCenter.x + weight / 2 * (along * d.x + sin(b) * t.x),
                               y: capCenter.y + weight / 2 * (along * d.y + sin(b) * t.y))
            }
        }
        let start = opening, stop = 2 * .pi - opening
        var path = arc(outer, start, stop)
        path += end(stop, 1)
        path += arc(inner, stop, start)
        path += end(start, -1)
        path.append(path[0])
        // The opening makes the C narrower on the right: centered by its own width, it sits in the middle of the square.
        let xs = path.map(\.x), shift = c.x - (xs.min()! + xs.max()!) / 2
        return path.map { CGPoint(x: $0.x + shift, y: $0.y) }
    }
}

extension Document {
    /// Where the test can go: between the marks with Print & Cut (the rest isn't cut); otherwise, on the page.
    var testAreaOf: CGRect { marks ? marksConfig.area : CGRect(origin: .zero, size: Self.page) }

    /// The test's square on the sheet, in mm.
    var testBox: CGRect { CGRect(origin: testPosition, size: CGSize(width: testSide, height: testSide)) }

    /// Puts the test at a spot on the sheet (without going past the area).
    func moveTest(to p: CGPoint) {
        let a = testAreaOf, l = testSide
        testPosition = CGPoint(x: min(max(p.x, a.minX), a.maxX - l), y: min(max(p.y, a.minY), a.maxY - l))
    }

    /// Changes the test's size (within `TestCut.sides`), keeping the top-left corner where it fits.
    func resizeTest(to side: Double) {
        testSide = min(max(side, TestCut.sides.lowerBound), TestCut.sides.upperBound)
        moveTest(to: testPosition)
    }

    /// Just the test, with the color's settings; with Print & Cut the machine reads the marks first, as in the real cut.
    func testJob(_ color: CMYK) -> Job {
        moveTest(to: testPosition)
        let config = config(color)
        let layer = CutLayer(name: String(localized: "Test cut (\(Material.show(config.material)))"),
                              paths: TestCut.paths(in: testPosition, side: testSide), settings: config.settings,
                              holder: config.holder, tool: config.tool)
        return Job(name: String(localized: "Test cut"), origin: ObjectIdentifier(self), layers: [layer],
                        logLines: registrationToSend, withMat: withMat, base: cuttingMatSetting)
    }
}

/// One send in the queue: the machine cuts one at a time, in order of arrival.
struct Job: Identifiable {
    enum JobStatus: Equatable {
        case waiting
        case cutting(String)
        case done
        /// The queue stops here until the user retries or removes the job from the queue.
        case failure(String)
        /// Print & Cut: the machine didn't find the marks (nothing was cut).
        case marksNotFound

        var didStop: Bool {
            switch self {
            case .failure, .marksNotFound: true
            default: false
            }
        }
    }

    let id = UUID()
    /// Document name.
    let name: String
    /// Document it came from (the marks notice opens in its window).
    let origin: ObjectIdentifier
    let layers: [CutLayer]
    let logLines: Cutter.Registration?
    let withMat: Bool
    /// The chosen mat (nil = the machine's default).
    var base: CuttingMat? = nil
    var status = JobStatus.waiting
}
