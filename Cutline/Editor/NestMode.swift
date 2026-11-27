// Object › Nest… (⌥⌘N): packs the pieces close together to use less material (the engine: Model/Nesting.swift). With
// something selected, it nests the selection; with nothing, everything on the active artboard (owner's decision,
// 18/11/2026). It is a mode, like editing the image inside a shape: every setting is in the Nest panel of the side menu
// (its icon, or the menu, starts it; owner's request, 19/11/2026), the control bar only says so, and the canvas shows
// the result live. Nothing changes for good
// until Apply (one undo step); Cancel (Esc) puts everything back.
//
// The preview is the document itself: the pieces move on the canvas, the copies and the new artboards are there, and the
// state from before is kept to come back to. Pieces that look the same (the same objects, wherever and however turned)
// are one design with a quantity; asking for more makes copies. What doesn't fit goes to new artboards, already nested.
// Dragging on the artboard marks a part that is already cut (`Artboard.used`, kept in the file for the next time).
import SwiftUI

/// The nest open on each document (the document's own type stays without it: the Finder's previews compile it).
@Observable
final class NestCenter {
    static let shared = NestCenter()
    var sessions: [ObjectIdentifier: NestSession] = [:]
}

extension Document {
    var nest: NestSession? { NestCenter.shared.sessions[ObjectIdentifier(self)] }

    /// Object › Nest… can start: the selection, or else the active artboard, has something that moves.
    var canNest: Bool {
        guard nest == nil, textEditing == nil else { return false }
        if !selection.isEmpty { return true }
        let artboard = activeArtboard
        return objects.contains { !$0.emptyText && !untouchable($0) && self.artboard(of: $0)?.id == artboard.id }
    }

    func startNest() {
        guard canNest else { return }
        finishText()
        imageContentEditing = nil
        guard let session = NestSession(self) else { return }
        NestCenter.shared.sessions[ObjectIdentifier(self)] = session
        session.schedule(immediately: true)
    }
}

/// Pieces that look the same, nested together: how many there are and how many are asked for.
struct NestDesign: Identifiable {
    let id: Int
    let name: String
    /// The first piece, as it was: the copies come from it.
    let template: [CanvasObject]
    /// The pieces already in the document.
    let pieces: [[CanvasObject.ID]]
    /// How many are asked for (at least one). Fewer than the ones there: the extra ones are removed on Apply.
    var quantity: Int
    var existing: Int { pieces.count }
    /// With "Fill the artboard" on: the copies added to fill it (worked out again on every change).
    var fillCopies = 0
    /// Without new artboards: how many of the ones asked for don't fit (they come off the number shown, and come back when
    /// "Add artboards for what doesn't fit" is turned on; owner's request, 19/11/2026).
    var trimmed = 0
    var total: Int { quantity - trimmed + fillCopies }
}

@Observable
final class NestSession {
    static let maxPieces = 500
    static let maxQuantity = 999
    private static let zeroID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    /// Spacing, Turn and Inside holes come back the next time Cutline opens (owner's request, 23/11/2026: key `nestSettings`);
    /// Fill and new artboards stay only while the app is open. A hidden test copy doesn't save them (it shares the
    /// preferences with the owner's app).
    private static var lastSettings = storedSettings() { didSet { store(lastSettings) } }
    private static let settingsKey = "nestSettings"
    private static var lastFill = false
    private static var lastAddArtboards = false

    private static func storedSettings() -> NestSettings {
        var settings = NestSettings()
        guard let saved = UserDefaults.standard.dictionary(forKey: settingsKey) else { return settings }
        // Numbers as numbers or as text (a test copy's arguments come as text).
        func number(_ key: String) -> Double? { (saved[key] as? NSNumber)?.doubleValue ?? (saved[key] as? String).flatMap(Double.init) }
        if let spacing = number("spacing"), spacing >= 0, spacing <= 50 { settings.spacing = spacing }
        if let turn = (saved["turn"] as? String).flatMap(NestTurn.init(rawValue:)) { settings.turn = turn }
        if let holes = number("holes") { settings.holes = holes != 0 }
        return settings
    }

    private static func store(_ settings: NestSettings) {
        #if DEBUG
        if DebugHooks.hidden { return }
        #endif
        UserDefaults.standard.set(["spacing": settings.spacing, "turn": settings.turn.rawValue, "holes": settings.holes], forKey: settingsKey)
    }

    @ObservationIgnored private weak var doc: Document?
    let artboardID: UUID
    let artboardRect: CGRect
    var designs: [NestDesign]
    var settings: NestSettings { didSet { if settings != oldValue { Self.lastSettings = settings; schedule() } } }
    /// "Fill the artboard": copies of every design, taking turns, while there is room; done again on every change
    /// (owner's request, 19/11/2026: changing the spacing fills again without pressing anything).
    var fill = NestSession.lastFill { didSet { if fill != oldValue { Self.lastFill = fill; schedule() } } }
    /// What doesn't fit goes to new artboards, already nested. Off (the default, owner's request, 19/11/2026), it is left
    /// out: no copies for it, and the pieces already there that don't fit are removed on Apply.
    var addArtboards = NestSession.lastAddArtboards {
        didSet { if addArtboards != oldValue { Self.lastAddArtboards = addArtboards; schedule() } }
    }
    /// Pieces already in the document that the result removes (left out, or past the quantity asked).
    private(set) var removing = 0
    /// More copies were asked for than fit (the quantity came back down).
    private(set) var noRoomForMore = false
    /// Parts of the artboard already cut (relative to its corner).
    var used: [CGRect] { didSet { schedule() } }
    private(set) var result: NestResult?
    private(set) var working = false
    /// Pieces of each design on the artboard now (the rest went to new artboards).
    private(set) var onArtboard: [Int] = []
    /// How long the last nest took (s), for the tests.
    @ObservationIgnored private(set) var lastDuration = 0.0

    @ObservationIgnored private let before: Snapshot
    @ObservationIgnored private var shapes: [NestShape] = []
    /// Each design's pieces as items (existing ones; the copies use `templateShape`).
    @ObservationIgnored private var pieceItems: [[NestItem]] = []
    @ObservationIgnored private var templateShape: [Int] = []
    @ObservationIgnored private var copies: [Int: [[CanvasObject]]] = [:]
    @ObservationIgnored private var newArtboards: [Artboard] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var obstacles: [NestPath] = []
    /// The area outside the Print & Cut marks (nil without them); kept `Nester.edgeMargin` away from, like the edges.
    @ObservationIgnored private var marksZone: CGPath?

    private struct Snapshot {
        var objects: [CanvasObject]
        var artboards: [Artboard]
        var activeArtboardID: UUID
        var selection: Set<CanvasObject.ID>
    }

    init?(_ doc: Document) {
        self.doc = doc
        let selected = !doc.selection.isEmpty
        let artboard = selected ? (doc.selectedObjects.first.flatMap(doc.artboard(of:)) ?? doc.activeArtboard) : doc.activeArtboard
        artboardID = artboard.id
        artboardRect = artboard.rect
        used = artboard.used
        settings = Self.lastSettings
        before = Snapshot(objects: doc.objects, artboards: doc.artboards, activeArtboardID: doc.activeArtboardID, selection: doc.selection)
        // The pieces: the selection's, or everything on the artboard; a whole outermost group is one piece.
        let chosen: [CanvasObject] = selected
            ? doc.selectedObjects
            : doc.objects.filter { !$0.emptyText && doc.artboard(of: $0)?.id == artboard.id }
        let movable = chosen.filter { !$0.emptyText && !doc.untouchable($0) }
        var order: [UUID] = [], grouped: [UUID: [CanvasObject]] = [:]
        for object in movable {
            let key = object.groups.first ?? object.id
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(object)
        }
        let pieces = order.map { grouped[$0]! }
        guard !pieces.isEmpty else { return nil }
        guard pieces.count <= Self.maxPieces else {
            doc.notice = String(localized: "Too many pieces to nest at once (\(pieces.count); up to \(Self.maxPieces)). Select fewer.")
            return nil
        }
        // Designs: the same objects, wherever they are and however turned.
        var keys: [Data: Int] = [:]
        var found: [(name: String, template: [CanvasObject], pieces: [[CanvasObject.ID]])] = []
        for piece in pieces {
            let key = Self.fingerprint(piece)
            if let d = keys[key] { found[d].pieces.append(piece.map(\.id)); continue }
            keys[key] = found.count
            let name = piece.count == 1 ? piece[0].name : String(localized: "Group of \(piece.count)")
            found.append((name, piece, [piece.map(\.id)]))
        }
        designs = found.enumerated().map { NestDesign(id: $0, name: $1.name, template: $1.template, pieces: $1.pieces, quantity: $1.pieces.count) }
        prepareGeometry(doc, pieces: Set(movable.map(\.id)), artboard: artboard)
        doc.selection = []
    }

    // MARK: Geometry

    /// What doesn't move on the artboard, and each piece's shape (pieces with the same look and turn share one).
    private func prepareGeometry(_ doc: Document, pieces: Set<CanvasObject.ID>, artboard: Artboard) {
        let byID = Dictionary(uniqueKeysWithValues: before.objects.map { ($0.id, $0) })
        var shapeOf: [String: Int] = [:]
        pieceItems = designs.map { design in
            design.pieces.map { ids in
                let objects = ids.compactMap { byID[$0] }
                let shape = Self.shape(objects, doc)
                let key = "\(design.id)/\(((objects.first?.rotation ?? 0) * 100).rounded())"
                if let index = shapeOf[key] {
                    let o = shapes[index].bounds.origin
                    return NestItem(shape: index, offset: CGVector(dx: shape.bounds.minX - o.x, dy: shape.bounds.minY - o.y))
                }
                shapeOf[key] = shapes.count
                shapes.append(shape)
                return NestItem(shape: shapes.count - 1, offset: .zero)
            }
        }
        templateShape = pieceItems.map { $0[0].shape }
        // Everything else that shows on the artboard is in the way (locked objects, what isn't selected).
        obstacles = before.objects
            .filter { !pieces.contains($0.id) && !$0.emptyText && doc.visible($0) }
            .filter { $0.shapePath.boundingRect.intersects(artboard.rect) }
            .map { NestPath(path: $0.shapePath.cgPath, line: Self.line($0)) }
        readMarks(doc)
    }

    private func readMarks(_ doc: Document) {
        guard let artboard = doc.artboards.first(where: { $0.id == artboardID }) else { return }
        marksZone = doc.marks ? doc.marksConfig.forbiddenZone(on: doc.sheetFrame(artboard)).cgPath : nil
    }

    /// The Print & Cut marks turned on or off (or moved) with the Nest panel open: nests again with them.
    func marksChanged() {
        guard let doc else { return }
        readMarks(doc)
        schedule()
    }

    static func shape(_ objects: [CanvasObject], _ doc: Document) -> NestShape {
        let paths = objects.filter { doc.visible($0) }.map { NestPath(path: $0.shapePath.cgPath, line: line($0)) }
        let box = paths.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath.insetBy(dx: -$1.line / 2, dy: -$1.line / 2)) }
        return NestShape(paths: paths, bounds: box.isNull ? .zero : box)
    }

    /// How wide the outline is (a printed stroke; a cut line counts a hair, so open paths take room too).
    static func line(_ o: CanvasObject) -> Double { max(o.strokeWidth * TextBox.mmPerPt, 0.2) }

    /// The same look whatever the place and the turn: each object without its id, layer and groups, its turn relative to
    /// the piece's first object and its place relative to it, turned back.
    static func fingerprint(_ piece: [CanvasObject]) -> Data {
        guard let first = piece.first else { return Data() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let back = CanvasObject.rotation(-first.rotation, around: .zero)
        var data = Data()
        for o in piece {
            var n = o
            n.id = Self.zeroID
            n.groups = []
            n.layer = nil
            n.rotation = (CanvasObject.normalizedAngle(o.rotation - first.rotation) * 100).rounded() / 100
            let rel = CGPoint(x: o.pivot.x - first.pivot.x, y: o.pivot.y - first.pivot.y).applying(back)
            let r = o.frame.standardized
            n.frame = CGRect(x: (rel.x * 100).rounded() / 100 - r.width / 2, y: (rel.y * 100).rounded() / 100 - r.height / 2,
                             width: r.width, height: r.height)
            data.append((try? encoder.encode(n)) ?? Data())
        }
        return data
    }

    // MARK: Running

    /// The items in order: each design's pieces, then its copies.
    nonisolated private static func items(_ quantities: [Int], _ pieceItems: [[NestItem]], _ templateShape: [Int])
        -> (items: [NestItem], refs: [(design: Int, index: Int)]) {
        var items: [NestItem] = [], refs: [(Int, Int)] = []
        for (d, quantity) in quantities.enumerated() {
            for k in 0..<quantity {
                items.append(k < pieceItems[d].count ? pieceItems[d][k] : NestItem(shape: templateShape[d], offset: .zero))
                refs.append((d, k))
            }
        }
        return (items, refs)
    }

    /// The marks' zone as an obstacle: grown so the pieces stay at least `Nester.edgeMargin` from the area between them.
    private var marksObstacle: [NestPath] {
        guard let marksZone else { return [] }
        return [NestPath(path: marksZone, line: 2 * max(0, Nester.edgeMargin - settings.spacing / 2))]
    }

    private var firstSheet: NestSheet {
        let usedPaths = used.map { NestPath(path: CGPath(rect: $0.offsetBy(dx: artboardRect.minX, dy: artboardRect.minY), transform: nil), line: 0) }
        return NestSheet(rect: artboardRect, obstacles: obstacles + marksObstacle + usedPaths)
    }

    func schedule(immediately: Bool = false) {
        task?.cancel()
        working = true
        let base = designs.map(\.quantity)
        let shapes = shapes, settings = settings, first = firstSheet, pieceItems = pieceItems, templates = templateShape, fill = fill
        let extra = addArtboards ? NestSheet(rect: artboardRect, obstacles: marksObstacle) : nil
        task = Task { [weak self] in
            if !immediately { try? await Task.sleep(for: .milliseconds(90)) }
            guard !Task.isCancelled else { return }
            let start = Date()
            let outcome = await Task.detached(priority: .userInitiated) { () -> (NestResult, [(design: Int, index: Int)], [Int])? in
                let added = fill ? Self.fillCopies(base, shapes: shapes, pieceItems: pieceItems, templates: templates, first: first,
                                                    extra: extra, settings: settings) : Array(repeating: 0, count: base.count)
                guard let added else { return nil }
                let (items, refs) = Self.items(zip(base, added).map(+), pieceItems, templates)
                guard let result = Nester.nest(shapes: shapes, items: items, first: first, extra: extra, settings: settings) else { return nil }
                return (result, refs, added)
            }.value
            guard let self, !Task.isCancelled, var (result, refs, added) = outcome else { return }
            self.lastDuration = Date().timeIntervalSince(start)
            for d in self.designs.indices { self.designs[d].fillCopies = added[d] }
            self.fitQuantities(&result, refs)
            self.show(result, refs: refs)
            self.working = false
        }
    }

    /// How many copies of each design fill the artboard after the pieces asked for (none when those already overflow it).
    /// The nest places them in its own order (the biggest first), which can leave a few out: those come off, so the artboard
    /// ends full without new artboards. (Identical pieces go in order: the ones left out are the last ones, and taking them
    /// off doesn't move the others.)
    nonisolated private static func fillCopies(_ base: [Int], shapes: [NestShape], pieceItems: [[NestItem]], templates: [Int],
                                               first: NestSheet, extra: NestSheet?, settings: NestSettings) -> [Int]? {
        let (items, _) = Self.items(base, pieceItems, templates)
        guard var added = Nester.fill(shapes: shapes, items: items, designs: templates, first: first, settings: settings) else {
            return Task.isCancelled ? nil : Array(repeating: 0, count: base.count)
        }
        let (all, refs) = Self.items(zip(base, added).map(+), pieceItems, templates)
        guard let r = Nester.nest(shapes: shapes, items: all, first: first, extra: extra, settings: settings) else { return nil }
        for p in r.placements where p.sheet > 0 { added[refs[p.item].design] -= 1 }
        for i in r.tooBig + r.leftOut { added[refs[i].design] -= 1 }
        return added.map { max(0, $0) }
    }

    /// Without new artboards, what doesn't fit comes off the quantities, so the number shown is what fits (owner's request,
    /// 19/11/2026: turning the marks on and nesting again goes from 15 to 13). The placements don't change: the ones left out
    /// are each design's last pieces, which stamped nothing. A design keeps at least one piece (asked for, even if it is out).
    private func fitQuantities(_ result: inout NestResult, _ refs: [(design: Int, index: Int)]) {
        noRoomForMore = false
        for d in designs.indices { designs[d].trimmed = 0 }
        guard !addArtboards, !result.leftOut.isEmpty else { return }
        var still: [Int] = []
        for i in result.leftOut {
            let (d, k) = refs[i]
            if k >= designs[d].existing { noRoomForMore = true }
            if designs[d].quantity - designs[d].trimmed > 1 { designs[d].trimmed += 1 } else { still.append(i) }
        }
        result.leftOut = still
    }

    func setQuantity(_ design: Int, _ quantity: Int) {
        guard designs.indices.contains(design) else { return }
        // `quantity` is the number shown (what fits): it becomes the one asked for.
        let q = min(max(quantity, 1), Self.maxQuantity)
        guard q != designs[design].quantity - designs[design].trimmed else { return }
        designs[design].quantity = q
        designs[design].trimmed = 0
        schedule()
    }

    // MARK: The preview (on the document)

    private func show(_ r: NestResult, refs: [(design: Int, index: Int)]) {
        guard let doc else { return }
        var objects = before.objects
        var artboards = before.artboards
        if let i = artboards.firstIndex(where: { $0.id == artboardID }) { artboards[i].used = used }
        // New artboards to the right of all of them, the same size as this one.
        let extra = r.sheets - 1
        let box = artboards.dropFirst().reduce(artboards[0].rect) { $0.union($1.rect) }
        while newArtboards.count < extra {
            let x = box.maxX + Document.artboardGap + Double(newArtboards.count) * (artboardRect.width + Document.artboardGap)
            newArtboards.append(Artboard(rect: CGRect(x: x, y: artboardRect.minY, width: artboardRect.width, height: artboardRect.height)))
        }
        artboards += newArtboards.prefix(extra)
        let index = Dictionary(uniqueKeysWithValues: objects.enumerated().map { ($1.id, $0) })
        var added: [CanvasObject] = []
        var counts = Array(repeating: 0, count: designs.count)
        for p in r.placements {
            let (d, k) = refs[p.item]
            var move = p.move
            if p.sheet > 0 {
                let target = newArtboards[p.sheet - 1].rect.origin
                move.dx += target.x - artboardRect.minX
                move.dy += target.y - artboardRect.minY
            } else {
                counts[d] += 1
            }
            if k < designs[d].existing {
                for id in designs[d].pieces[k] {
                    if let i = index[id] { Self.place(&objects[i], p, move) }
                }
            } else {
                for var o in copy(d, k - designs[d].existing) {
                    Self.place(&o, p, move)
                    added.append(o)
                }
            }
        }
        // Pieces already there that aren't placed go (left out, or past the quantity asked); one too big for the artboard
        // stays where it was.
        var placed = Set<CanvasObject.ID>()
        for p in r.placements {
            let (d, k) = refs[p.item]
            if k < designs[d].existing { placed.formUnion(designs[d].pieces[k]) }
        }
        for i in r.tooBig {
            let (d, k) = refs[i]
            if k < designs[d].existing { placed.formUnion(designs[d].pieces[k]) }
        }
        let gone = Set(designs.flatMap { $0.pieces.flatMap { $0 } }).subtracting(placed)
        removing = designs.reduce(0) { n, design in n + design.pieces.filter { $0.contains(where: gone.contains) }.count }
        objects.removeAll { gone.contains($0.id) }
        objects += added
        onArtboard = counts
        result = r
        doc.objects = objects
        doc.artboards = artboards
    }

    private static func place(_ o: inout CanvasObject, _ p: NestPlacement, _ move: CGVector) {
        o.rotate(by: p.angle, around: p.center)
        o.frame = o.frame.offsetBy(dx: move.dx, dy: move.dy)
    }

    /// The n-th copy of a design (the same ones each time, so the ids stay while the settings change).
    private func copy(_ design: Int, _ n: Int) -> [CanvasObject] {
        var pool = copies[design] ?? []
        while pool.count <= n { pool.append(CanvasObject.copies(designs[design].template)) }
        copies[design] = pool
        return pool[n]
    }

    // MARK: Ending

    /// Keeps the result: one undo step back to before.
    func apply() {
        guard let doc else { return end() }
        task?.cancel()
        let objects = doc.objects, artboards = doc.artboards
        restore(doc, selection: false)
        doc.registrar()
        doc.objects = objects
        doc.artboards = artboards
        // The pieces now on this artboard stay selected.
        let pieceIDs = Set(designs.flatMap { $0.pieces.flatMap { $0 } }).union(copies.values.flatMap { $0.flatMap { $0.map(\.id) } })
        doc.selection = Set(objects.filter { pieceIDs.contains($0.id) && doc.artboard(of: $0)?.id == artboardID }.map(\.id))
        end()
    }

    func cancel() {
        task?.cancel()
        if let doc { restore(doc, selection: true) }
        end()
    }

    private func restore(_ doc: Document, selection: Bool) {
        doc.objects = before.objects
        doc.artboards = before.artboards
        doc.activeArtboardID = before.activeArtboardID
        if selection { doc.selection = before.selection }
    }

    private func end() {
        guard let doc else { return }
        NestCenter.shared.sessions[ObjectIdentifier(doc)] = nil
    }

    // MARK: Numbers for the card and the bar

    var asked: Int { designs.reduce(0) { $0 + $1.total } }
    var fitting: Int { onArtboard.reduce(0, +) }
    var extraArtboards: Int { max(0, (result?.sheets ?? 1) - 1) }
    /// Pieces that don't fit, left out (without "Add artboards for what doesn't fit").
    var leftOut: Int { result?.leftOut.count ?? 0 }
    var usedPercent: Int {
        guard let r = result, r.freeArea > 0 else { return 0 }
        return Int((100 * r.usedArea / r.freeArea).rounded())
    }

    /// Takes a part of the artboard out (a drag on it, canvas mm); a click on one gives it back.
    func markUsed(_ rect: CGRect) {
        let r = rect.standardized.intersection(artboardRect)
        guard !r.isNull, r.width >= 2, r.height >= 2 else { return }
        used.append(r.offsetBy(dx: -artboardRect.minX, dy: -artboardRect.minY))
    }

    func unmarkUsed(at p: CGPoint) -> Bool {
        let local = CGPoint(x: p.x - artboardRect.minX, y: p.y - artboardRect.minY)
        guard let i = used.lastIndex(where: { $0.contains(local) }) else { return false }
        used.remove(at: i)
        return true
    }

    /// The used parts, in canvas mm.
    var usedOnCanvas: [CGRect] { used.map { $0.offsetBy(dx: artboardRect.minX, dy: artboardRect.minY) } }

    /// The pieces being nested now (for their outline on the canvas).
    var pieceIDs: Set<CanvasObject.ID> {
        Set(designs.flatMap { $0.pieces.flatMap { $0 } }).union(copies.values.flatMap { $0.flatMap { $0.map(\.id) } })
    }
}

// MARK: - The control bar in the mode

/// While nesting, the control bar only says where the settings are (all of them in the Nest panel, owner's request,
/// 19/11/2026: settings in two places were confusing) and how it is going.
struct NestStatusBar: View {
    let session: NestSession

    var body: some View {
        HStack(spacing: 10) {
            Text("Nest").fontWeight(.semibold)
            Divider().frame(height: 16)
            Text("The settings are in the Nest panel. Return applies, Esc cancels.").foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if session.working { ProgressView().controlSize(.mini) }
            NestSummary(session: session)
        }
        .lineLimit(1)
    }
}

/// Whether everything fits on the artboard.
private struct NestSummary: View {
    let session: NestSession

    var body: some View {
        HStack(spacing: 6) {
            if session.result != nil {
                if session.extraArtboards > 0 {
                    Text("New artboards for the rest: \(session.extraArtboards)").foregroundStyle(.orange)
                } else if session.leftOut > 0 {
                    Text("Don't fit, left out: \(session.leftOut)").foregroundStyle(.orange)
                } else {
                    Text("Fits on this artboard").foregroundStyle(.secondary)
                }
                if let tooBig = session.result?.tooBig.count, tooBig > 0 {
                    Text("Too big for the artboard: \(tooBig)").foregroundStyle(.red)
                }
            }
        }
    }
}

// MARK: - The Nest panel

/// The Nest panel (Editor/SidePanel.swift): before nesting, what it will nest and the button; while nesting, every
/// setting, the pieces, the material, Cancel and Apply.
struct NestSection: View {
    @Bindable var doc: Document

    var body: some View {
        if let session = doc.nest {
            NestSettingsView(session: session, doc: doc)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(doc.selection.isEmpty
                     ? "Packs everything on the active artboard close together, to use less material." as LocalizedStringKey
                     : "Packs the selection close together, to use less material.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(doc.selection.isEmpty ? "Nest the Artboard" as LocalizedStringKey : "Nest the Selection") { doc.startNest() }
                    .disabled(!doc.canNest)
                    .frame(maxWidth: .infinity)
                    .help("Object › Nest… (⌥⌘N)")
            }
        }
    }
}

private struct NestSettingsView: View {
    @Bindable var session: NestSession
    let doc: Document
    @AppStorage(LengthUnit.key) private var unit = LengthUnit.mm

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Pieces").fontWeight(.semibold)
                Spacer()
                if session.working { ProgressView().controlSize(.mini) }
                Text("\(session.fitting) of \(session.asked) on this artboard")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(session.designs) { design in row(design) }
                }
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
            Toggle("Fill the artboard", isOn: $session.fill)
                .toggleStyle(.checkbox)
                .help("Adds copies of every piece, taking turns, while there is room on the artboard; it fills again when a setting changes")
            Toggle("Add artboards for what doesn't fit", isOn: $session.addArtboards)
                .toggleStyle(.checkbox)
                .help("On: what doesn't fit goes to new artboards, already nested. Off: it is left out, and the pieces already there that don't fit are removed on Apply")
            if session.noRoomForMore {
                Text("No room for more copies on this artboard.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if session.removing > 0 {
                Text("Removed: \(session.removing)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            settings
            Divider()
            material
            Text(session.used.isEmpty ? "Drag on the artboard to mark a part that's already cut." as LocalizedStringKey
                 : "Click a marked part to give it back.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                NestSummary(session: session).font(.caption)
                Spacer()
                Button("Cancel") { session.cancel() }
                    .help("Puts everything back (Esc)")
                Button("Apply") { session.apply() }
                    .buttonStyle(.borderedProminent)
                    .help("Keeps the result (Return)")
            }
            .controlSize(.small)
        }
        .font(.callout)
        .onChange(of: doc.marks) { _, _ in session.marksChanged() }
        .onChange(of: doc.marksConfig) { _, _ in session.marksChanged() }
    }

    private var settings: some View {
        let shown = Binding(get: { unit.show(session.settings.spacing) },
                            set: { session.settings.spacing = min(max(unit.mm($0), 0), 50) })
        return Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Text("Spacing").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                HStack(spacing: 4) {
                    TextField("Spacing", value: shown, format: .number.precision(.fractionLength(0...unit.fractionDigits)))
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 40)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                        .stepperArrows(shown, step: unit == .mm ? 0.5 : 0.05)
                    Text(verbatim: unit.symbol).foregroundStyle(.secondary)
                }
                .help("Distance between the pieces, and from the edges and what is in the way")
            }
            GridRow {
                Text("Turn").foregroundStyle(.secondary)
                Picker("Turn", selection: $session.settings.turn) {
                    Text("Never").tag(NestTurn.never)
                    Text(verbatim: "180°").tag(NestTurn.half)
                    Text("Any").tag(NestTurn.any)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Never keeps the pieces as they are (grain, upright text); 180° lets them turn upside down to interlock; Any tries every 45°")
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                Toggle("Inside holes", isOn: $session.settings.holes)
                    .toggleStyle(.checkbox)
                    .help("Small pieces can go inside the holes of bigger ones")
            }
        }
    }

    private func row(_ design: NestDesign) -> some View {
        let here = session.onArtboard.indices.contains(design.id) ? session.onArtboard[design.id] : 0
        let wanted = design.total
        let size = design.template.reduce(CGRect.null) { $0.union($1.shapePath.boundingRect) }.size
        return HStack(spacing: 9) {
            NestThumbnail(objects: design.template, doc: doc)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: design.name).lineLimit(1)
                Group {
                    if here < wanted {
                        Text(session.addArtboards ? "\(unit.text(size)) · \(wanted - here) on new artboards" as LocalizedStringKey
                             : "\(unit.text(size)) · \(wanted - here) don't fit").foregroundStyle(.orange)
                    } else if design.fillCopies > 0 {
                        Text("\(unit.text(size)) · \(design.fillCopies) to fill").foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: unit.text(size)).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                Button { session.setQuantity(design.id, wanted - 1) } label: { Text(verbatim: "−").frame(width: 14) }
                    .disabled(wanted <= 1)
                    .help("Fewer pieces (below the ones already there, the extra ones are removed on Apply)")
                Text(verbatim: "\(wanted)")
                    .monospacedDigit()
                    .frame(minWidth: 26)
                Button { session.setQuantity(design.id, wanted + 1) } label: { Text(verbatim: "+").frame(width: 14) }
                    .help("One more copy")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }

    private var material: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Material used")
                Spacer()
                Text(verbatim: "\(session.usedPercent)%").fontWeight(.semibold).monospacedDigit()
            }
            ProgressView(value: Double(min(session.usedPercent, 100)), total: 100)
                .tint(.green)
            Group {
                if let leftover = session.result?.leftover, leftover >= 10, session.fitting > 0 {
                    Text("A \(unit.text(session.artboardRect.width)) × \(unit.text(leftover)) strip is left below the pieces, to cut off and keep.")
                } else if session.extraArtboards > 0 {
                    Text("New artboards for what doesn't fit, already nested: \(session.extraArtboards).")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .help("How much of the artboard's free part the pieces take")
    }
}

/// A piece drawn small, as it prints and cuts.
private struct NestThumbnail: View {
    let objects: [CanvasObject]
    let doc: Document

    var body: some View {
        Canvas { ctx, size in
            let box = objects.reduce(CGRect.null) { $0.union($1.shapePath.boundingRect) }
            guard !box.isNull, box.width > 0 || box.height > 0 else { return }
            let scale = min((size.width - 2) / max(box.width, 0.1), (size.height - 2) / max(box.height, 0.1))
            let t = CGAffineTransform(translationX: size.width / 2, y: size.height / 2).scaledBy(x: scale, y: scale)
                .translatedBy(x: -box.midX, y: -box.midY)
            let colors = doc.colors
            for o in objects {
                let path = o.shapePath.applying(t)
                if let fill = o.fill { ctx.fill(path, with: .color(colors.color(fill)), style: FillStyle(eoFill: true)) }
                if o.cutsLine || o.strokeWidth > 0 {
                    ctx.stroke(path, with: .color(o.cutsLine ? colors.color(o.strokeColor) : .secondary), lineWidth: 1)
                }
            }
        }
    }
}
