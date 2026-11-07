// Artboards (as in Illustrator): the document's pages, on one canvas with all the objects. Each one has a size (the
// presets of Illustrator and Silhouette Studio, or custom) and an orientation; the rulers, the snap and Fit in Window
// follow the active one; Send cuts one; Print prints one page per artboard. The 1st artboard is always at the canvas's
// origin (0, 0): files from versions without artboards open with an A4 there, and those versions open the new files
// showing the 1st artboard where it is. Moving, reordering or deleting the 1st one moves the whole canvas instead
// (`anchorFirstArtboard`), and the window shifts the view by the same amount so nothing jumps on screen.
// The CutlinePreview and CutlineThumbnail extensions compile this file (Document.swift uses it).
import CoreGraphics
import Foundation

/// Page sizes, portrait (mm): the paper ones of Illustrator and Silhouette Studio and the cutting mats' cut areas.
nonisolated enum PagePreset: String, CaseIterable, Identifiable, Sendable {
    case letter, legal, tabloid, a3, a4, a5, mat8x12, mat8_5x12, mat12x12, mat12x24, mat15x15, mat24x24

    var id: Self { self }

    var size: CGSize {
        let inch = 25.4
        return switch self {
        case .letter: CGSize(width: 8.5 * inch, height: 11 * inch)
        case .legal: CGSize(width: 8.5 * inch, height: 14 * inch)
        case .tabloid: CGSize(width: 11 * inch, height: 17 * inch)
        case .a3: CGSize(width: 297, height: 420)
        case .a4: CGSize(width: 210, height: 297)
        case .a5: CGSize(width: 148, height: 210)
        case .mat8x12: CGSize(width: 8 * inch, height: 12 * inch)
        case .mat8_5x12: CGSize(width: 8.5 * inch, height: 12 * inch)
        case .mat12x12: CGSize(width: 12 * inch, height: 12 * inch)
        case .mat12x24: CGSize(width: 12 * inch, height: 24 * inch)
        case .mat15x15: CGSize(width: 15 * inch, height: 15 * inch)
        case .mat24x24: CGSize(width: 24 * inch, height: 24 * inch)
        }
    }

    var name: String {
        switch self {
        case .letter: String(localized: "Letter")
        case .legal: String(localized: "Legal")
        case .tabloid: String(localized: "Tabloid")
        case .a3: "A3"
        case .a4: "A4"
        case .a5: "A5"
        case .mat8x12: String(localized: "Cutting mat 8 × 12 in")
        case .mat8_5x12: String(localized: "Cutting mat 8.5 × 12 in")
        case .mat12x12: String(localized: "Cutting mat 12 × 12 in")
        case .mat12x24: String(localized: "Cutting mat 12 × 24 in")
        case .mat15x15: String(localized: "Cutting mat 15 × 15 in")
        case .mat24x24: String(localized: "Cutting mat 24 × 24 in")
        }
    }

    /// The paper sizes first, then the cutting mats (the menus put a divider between them).
    var isMat: Bool { rawValue.hasPrefix("mat") }

    /// The preset with this size, in either orientation (0.05 mm of slack, for sizes typed in inches).
    static func matching(_ size: CGSize) -> PagePreset? {
        allCases.first { p in
            let s = p.size
            return (abs(s.width - size.width) < 0.05 && abs(s.height - size.height) < 0.05)
                || (abs(s.width - size.height) < 0.05 && abs(s.height - size.width) < 0.05)
        }
    }
}

/// A page of the document (Illustrator's artboard): where it is on the canvas and its size, in mm.
nonisolated struct Artboard: Hashable, Codable, Sendable, Identifiable {
    /// The keys stored on disk are in Portuguese, like the rest of the .cutline format.
    enum CodingKeys: String, CodingKey {
        case name = "nome", x, y, width = "largura", height = "altura"
    }

    /// Only for the interface (lists, the Send window's choice); doesn't go into the file.
    var id = UUID()
    /// nil = "Artboard N" (by its place in the list, in the app's language).
    var name: String?
    var rect: CGRect

    /// The smallest and largest side (Silhouette Studio refuses pages outside 10–3,000 mm).
    static let sides = 10.0...3000.0
    /// What documents without artboards have: an A4 at the origin.
    static let standard = Artboard(rect: CGRect(origin: .zero, size: PagePreset.a4.size))

    init(name: String? = nil, rect: CGRect) {
        self.name = name
        self.rect = rect
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        let x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0, y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        let width = try c.decodeIfPresent(Double.self, forKey: .width) ?? PagePreset.a4.size.width
        let height = try c.decodeIfPresent(Double.self, forKey: .height) ?? PagePreset.a4.size.height
        rect = CGRect(x: x, y: y, width: Self.limited(width), height: Self.limited(height))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(Double(rect.minX), forKey: .x)
        try c.encode(Double(rect.minY), forKey: .y)
        try c.encode(Double(rect.width), forKey: .width)
        try c.encode(Double(rect.height), forKey: .height)
    }

    static func limited(_ side: Double) -> Double { min(max(side.isFinite ? side : 210, sides.lowerBound), sides.upperBound) }

    var size: CGSize { rect.size }
    var isLandscape: Bool { rect.width > rect.height }
    var preset: PagePreset? { PagePreset.matching(rect.size) }

    /// The same artboard, the same in the file (the id is only the interface's).
    func sameAs(_ other: Artboard) -> Bool { name == other.name && rect == other.rect }

    /// "Artboard 2" when it has no name of its own.
    func title(_ index: Int) -> String { name ?? Self.defaultName(index) }

    static func defaultName(_ index: Int) -> String { String(localized: "Artboard \(index + 1)") }

    /// Its size in the other orientation, keeping the top-left corner.
    func rotated() -> Artboard {
        var a = self
        a.rect.size = CGSize(width: rect.height, height: rect.width)
        return a
    }
}

nonisolated extension Document {
    /// The artboards as they go into the file: nil for the one A4 at the origin that documents without artboards have, so
    /// those files save exactly as before.
    static func artboardsToSave(_ artboards: [Artboard]) -> [Artboard]? {
        artboards.count == 1 && artboards[0].sameAs(.standard) ? nil : artboards
    }

    var activeIndex: Int { artboards.firstIndex { $0.id == activeArtboardID } ?? 0 }
    var activeArtboard: Artboard { artboards[activeIndex] }
    /// The 1st artboard's size: the sheet the Finder's previews and the start screen show.
    var firstSheet: CGSize { artboards[0].size }
    /// All the artboards together (Fit All in Window, the previews).
    var artboardsBox: CGRect { artboards.dropFirst().reduce(artboards[0].rect) { $0.union($1.rect) } }

    /// The artboard under a point (mm): the active one if it is there, else the last one drawn there.
    func artboard(at p: CGPoint) -> Artboard? {
        if activeArtboard.rect.contains(p) { return activeArtboard }
        return artboards.last { $0.rect.contains(p) }
    }

    /// Keeps the 1st artboard at the canvas's origin: when it would leave it, everything (objects, guides, the other
    /// artboards) moves the other way instead; `anchor` tells the window how much, so the view follows.
    func anchorFirstArtboard() {
        let o = artboards[0].rect.origin
        guard o != .zero else { return }
        let dx = -o.x, dy = -o.y
        for i in objects.indices { objects[i].frame = objects[i].frame.offsetBy(dx: dx, dy: dy) }
        for i in artboards.indices { artboards[i].rect = artboards[i].rect.offsetBy(dx: dx, dy: dy) }
        guides.verticals = guides.verticals.map { $0 + dx }
        guides.horizontals = guides.horizontals.map { $0 + dy }
        testPosition = CGPoint(x: testPosition.x + dx, y: testPosition.y + dy)
        anchor = CGPoint(x: anchor.x + o.x, y: anchor.y + o.y)
    }
}

extension Document {
    /// The artboard an object belongs to: the one with the center of its box (else the one it touches most).
    func artboard(of object: CanvasObject) -> Artboard? {
        let box = object.shapePath.boundingRect
        let center = CGPoint(x: box.midX, y: box.midY)
        if let a = artboards.first(where: { $0.rect.contains(center) }) { return a }
        return artboards.map { ($0, $0.rect.intersection(box)) }.filter { !$1.isNull }
            .max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }?.0
    }

    /// Objects on other artboards than the 1st (what a .studio3, with one page, can't show on it).
    var objectsOffFirstArtboard: Int {
        guard artboards.count > 1 else { return 0 }
        let first = artboards[0].id
        return objects.filter { !$0.emptyText }.filter { o in artboard(of: o).map { $0.id != first } ?? false }.count
    }

}
