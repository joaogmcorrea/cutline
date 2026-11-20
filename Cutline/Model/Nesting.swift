// Nesting (Object › Nest…, Editor/NestMode.swift): packs pieces close together on an artboard to use less material, as
// Silhouette Studio's Nesting panel does (seen in its program: each piece becomes a picture on a grid, grown by half the
// spacing, and goes to the first free place). Here the grid is 0.5 mm; a piece is tried at each allowed turn, and the turn
// whose bottom edge ends up highest (then leftmost) wins. The biggest pieces go first, so the small ones fill the gaps and,
// with `holes`, the holes of the big ones. What doesn't fit goes to more sheets of the same size.
//
// Everything here works on plain geometry (page mm) and runs off the main thread.
import CoreGraphics
import Foundation

/// An outline to keep out of: filled with the even-odd rule and stroked `line` mm wide (open paths and printed strokes).
nonisolated struct NestPath: @unchecked Sendable {
    let path: CGPath
    let line: Double
}

/// A piece's geometry, as it is on the page now (one or several objects: a group goes as one piece).
nonisolated struct NestShape: Sendable {
    let paths: [NestPath]
    /// The box of the outlines (page mm), before any turn.
    let bounds: CGRect
    var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
}

/// One piece to place: a shape, moved by `offset` (pieces with the same geometry share the shape and its pictures).
nonisolated struct NestItem: Sendable {
    let shape: Int
    let offset: CGVector
}

nonisolated enum NestTurn: String, CaseIterable, Identifiable, Sendable {
    /// Keeps the pieces as they are (grain of the material, text that must stay upright).
    case never
    /// Upside down too: pairs that interlock (Studio's Interlock).
    case half
    /// Every 45°.
    case any

    var id: Self { self }

    var angles: [Double] {
        switch self {
        case .never: [0]
        case .half: [0, 180]
        case .any: [0, 45, 90, 135, 180, 225, 270, 315]
        }
    }
}

nonisolated struct NestSettings: Equatable, Sendable {
    /// Distance between pieces (and from the obstacles), mm.
    var spacing = 2.0
    var turn = NestTurn.any
    /// Small pieces may go inside the holes of bigger ones.
    var holes = true
}

/// A sheet: the artboard's rectangle (page mm) and what to keep out of on it.
nonisolated struct NestSheet: Sendable {
    let rect: CGRect
    let obstacles: [NestPath]
}

/// Where an item went: turned `angle` degrees (counterclockwise, as `CanvasObject.rotation`) around `center`, then moved
/// by `move`. `sheet` 0 is the first sheet; 1… are the extra ones (placed as if on the first: the caller moves them).
nonisolated struct NestPlacement: Sendable {
    let item: Int
    let sheet: Int
    let angle: Double
    let center: CGPoint
    let move: CGVector
}

nonisolated struct NestResult: Sendable {
    var placements: [NestPlacement] = []
    /// Items bigger than the sheet (or than its free part, even empty).
    var tooBig: [Int] = []
    /// Items that didn't fit on the first sheet when there are no extra sheets (`extra` nil).
    var leftOut: [Int] = []
    /// How many sheets got pieces (the first one counts even if empty).
    var sheets = 1
    /// Area of the pieces on the first sheet and of its free part, mm².
    var usedArea = 0.0
    var freeArea = 0.0
    /// Height of the clear band below the pieces on the first sheet, from side to side (mm): what can be cut off and kept.
    var leftover = 0.0
}

nonisolated enum Nester {
    /// Grid cell, mm.
    static let cell = 0.5
    /// Most extra sheets a nest makes.
    static let maxSheets = 20
    /// Least distance from the sheet's edges (and, with the marks, from the area between them), with or without spacing:
    /// pieces never touch the edge (owner's request, 19/11/2026).
    static let edgeMargin = 1.0

    /// Places every item: on `first`, then on as many copies of `extra` as needed; without `extra`, what doesn't fit on
    /// `first` is left out.
    static func nest(shapes: [NestShape], items: [NestItem], first: NestSheet, extra: NestSheet?, settings: NestSettings) -> NestResult? {
        var masks = MaskCache(shapes: shapes, settings: settings)
        let order = items.indices.sorted { a, b in
            let x = masks.area(items[a].shape), y = masks.area(items[b].shape)
            return x != y ? x > y : a < b
        }
        var result = NestResult()
        var pending = order
        var sheetIndex = 0
        let base = Grid(sheet: first, settings: settings)
        result.freeArea = Double(base.freeCells) * cell * cell
        var firstGrid = base
        while !pending.isEmpty, sheetIndex <= maxSheets {
            var grid = sheetIndex == 0 || extra == nil ? base : Grid(sheet: extra!, settings: settings)
            var rest: [Int] = []
            var placedHere = 0
            for index in pending {
                if Task.isCancelled { return nil }
                let item = items[index]
                guard let spot = grid.bestSpot(item.shape, &masks, settings.turn) else { rest.append(index); continue }
                grid.stamp(spot.mask, spot.x, spot.y)
                result.placements.append(placement(index, item, spot, sheet: sheetIndex, shapes: shapes))
                placedHere += 1
            }
            if sheetIndex == 0 { firstGrid = grid }
            if sheetIndex == 0, extra == nil {
                result.leftOut = rest
                break
            }
            if placedHere == 0 && sheetIndex > 0 {
                result.tooBig = rest
                break
            }
            if sheetIndex > 0 { result.sheets = sheetIndex + 1 }
            pending = rest
            sheetIndex += 1
            if sheetIndex > maxSheets { result.tooBig = rest }
        }
        let onFirst = result.placements.filter { $0.sheet == 0 }
        result.usedArea = onFirst.reduce(0) { $0 + masks.area(items[$1.item].shape) }
        result.leftover = firstGrid.clearBand(below: firstGrid.lowestStamped, base: base) * cell
        return result
    }

    /// After the items, as many more copies of each design (`designs`: the shape a copy has) as still fit on the first sheet,
    /// taking turns between the designs. Nil when the items alone don't fit on it, or when cancelled.
    static func fill(shapes: [NestShape], items: [NestItem], designs: [Int], first: NestSheet, settings: NestSettings,
                     limit: Int = 500) -> [Int]? {
        var masks = MaskCache(shapes: shapes, settings: settings)
        var grid = Grid(sheet: first, settings: settings)
        let order = items.indices.sorted { masks.area(items[$0].shape) > masks.area(items[$1].shape) }
        for index in order {
            if Task.isCancelled { return nil }
            guard let spot = grid.bestSpot(items[index].shape, &masks, settings.turn) else { return nil }
            grid.stamp(spot.mask, spot.x, spot.y)
        }
        var added = Array(repeating: 0, count: designs.count)
        // The biggest designs first in each round, so the small ones end up in the gaps.
        var active = designs.indices.sorted { masks.area(designs[$0]) > masks.area(designs[$1]) }
        var total = 0
        while !active.isEmpty, total < limit {
            for d in active {
                if Task.isCancelled { return nil }
                if let spot = grid.bestSpot(designs[d], &masks, settings.turn) {
                    grid.stamp(spot.mask, spot.x, spot.y)
                    added[d] += 1
                    total += 1
                } else {
                    active.removeAll { $0 == d }
                }
            }
        }
        return added
    }

    private static func placement(_ index: Int, _ item: NestItem, _ spot: Spot, sheet: Int, shapes: [NestShape]) -> NestPlacement {
        // The mask's corner is `origin` in the turned shape's space; it went to the grid cell (x, y) of the sheet.
        let target = CGPoint(x: spot.sheetOrigin.x + Double(spot.x) * cell, y: spot.sheetOrigin.y + Double(spot.y) * cell)
        let move = CGVector(dx: target.x - spot.mask.origin.x, dy: target.y - spot.mask.origin.y)
        let center = shapes[item.shape].center
        // The item is the shape moved by `offset`: it turns around its own center and moves by the rest.
        return NestPlacement(item: index, sheet: sheet, angle: spot.mask.angle,
                             center: CGPoint(x: center.x + item.offset.dx, y: center.y + item.offset.dy),
                             move: CGVector(dx: move.dx - item.offset.dx, dy: move.dy - item.offset.dy))
    }
}

// MARK: - Pictures of the pieces

/// A piece at one turn, on the grid: for each row, the runs of cells it takes (`runs`: row, first, end).
nonisolated struct NestMask: Sendable {
    let width: Int
    let height: Int
    let runs: [Int32]
    /// Page mm of the picture's top-left corner, in the turned shape's space.
    let origin: CGPoint
    let angle: Double
    /// Cells taken (without the spacing), for the material count.
    var cells = 0
}

nonisolated private struct MaskCache {
    let shapes: [NestShape]
    let settings: NestSettings
    private var masks: [Int: [Double: NestMask]] = [:]
    private var areas: [Int: Double] = [:]

    init(shapes: [NestShape], settings: NestSettings) {
        self.shapes = shapes
        self.settings = settings
    }

    /// The piece's own area (mm²), as it would be drawn on the grid.
    mutating func area(_ shape: Int) -> Double {
        if let a = areas[shape] { return a }
        let m = Raster.mask(shapes[shape], angle: 0, grow: 0, holes: true)
        let a = Double(m.cells) * Nester.cell * Nester.cell
        areas[shape] = a
        return a
    }

    mutating func mask(_ shape: Int, _ angle: Double) -> NestMask {
        if let m = masks[shape]?[angle] { return m }
        let m = Raster.mask(shapes[shape], angle: angle, grow: settings.spacing / 2, holes: settings.holes)
        masks[shape, default: [:]][angle] = m
        return m
    }
}

nonisolated private enum Raster {
    /// The piece turned `angle` around its center, grown by `grow` mm on every side, as cells of the grid. Edges count
    /// as taken (anti-aliased coverage above zero), so the spacing is never less than asked.
    static func mask(_ shape: NestShape, angle: Double, grow: Double, holes: Bool) -> NestMask {
        let cell = Nester.cell
        var turn = CanvasObject.rotation(angle, around: shape.center)
        var box = CGRect.null
        var widest = 0.0
        for p in shape.paths {
            if let turned = p.path.copy(using: &turn) { box = box.union(turned.boundingBoxOfPath) }
            widest = max(widest, p.line)
        }
        if box.isNull { box = CGRect(origin: shape.center, size: .zero) }
        let margin = grow + widest / 2 + cell
        let origin = CGPoint(x: box.minX - margin, y: box.minY - margin)
        let width = max(1, Int(((box.width + 2 * margin) / cell).rounded(.up)))
        let height = max(1, Int(((box.height + 2 * margin) / cell).rounded(.up)))
        var pixels = draw(width: width, height: height, origin: origin) { cg in
            cg.concatenate(turn)
            for p in shape.paths {
                cg.addPath(p.path)
                cg.fillPath(using: .evenOdd)
                let line = p.line + 2 * grow
                if line > 0 {
                    cg.setLineWidth(line)
                    cg.addPath(p.path)
                    cg.strokePath()
                }
            }
        }
        if !holes { fillHoles(&pixels, width: width, height: height) }
        var runs: [Int32] = []
        var cells = 0
        for y in 0..<height {
            var start = -1
            for x in 0...width {
                let on = x < width && pixels[y * width + x] != 0
                if on { cells += 1 }
                if on && start < 0 { start = x }
                if !on && start >= 0 {
                    runs.append(contentsOf: [Int32(y), Int32(start), Int32(x)])
                    start = -1
                }
            }
        }
        return NestMask(width: width, height: height, runs: runs, origin: origin, angle: angle, cells: cells)
    }

    /// Draws on a grid of `width` × `height` cells whose top-left corner is `origin` (page mm, y down); a cell is taken
    /// when anything covers it.
    static func draw(width: Int, height: Int, origin: CGPoint, _ paint: (CGContext) -> Void) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { raw in
            guard let cg = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                     space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            // Row 0 of the memory is the top: flip, then cells → mm.
            cg.translateBy(x: 0, y: Double(height))
            cg.scaleBy(x: 1 / Nester.cell, y: -1 / Nester.cell)
            cg.translateBy(x: -origin.x, y: -origin.y)
            cg.setFillColor(gray: 1, alpha: 1)
            cg.setStrokeColor(gray: 1, alpha: 1)
            cg.setLineJoin(.round)
            cg.setLineCap(.round)
            paint(cg)
        }
        return pixels
    }

    /// Without "Inside holes": the empty cells the outside can't reach (holes) count as taken.
    static func fillHoles(_ pixels: inout [UInt8], width: Int, height: Int) {
        var outside = [Bool](repeating: false, count: width * height)
        var stack: [Int] = []
        for x in 0..<width { stack.append(x); stack.append((height - 1) * width + x) }
        for y in 0..<height { stack.append(y * width); stack.append(y * width + width - 1) }
        while let i = stack.popLast() {
            guard !outside[i], pixels[i] == 0 else { continue }
            outside[i] = true
            let x = i % width, y = i / width
            if x > 0 { stack.append(i - 1) }
            if x < width - 1 { stack.append(i + 1) }
            if y > 0 { stack.append(i - width) }
            if y < height - 1 { stack.append(i + width) }
        }
        for i in pixels.indices where pixels[i] == 0 && !outside[i] { pixels[i] = 255 }
    }
}

// MARK: - The sheet

nonisolated private struct Spot {
    let mask: NestMask
    let x: Int
    let y: Int
    let sheetOrigin: CGPoint
}

/// The sheet's cells (taken or free), with a running sum per row, so a run of a piece checks in one subtraction.
nonisolated private struct Grid {
    let width: Int
    let height: Int
    let origin: CGPoint
    private var taken: [UInt8]
    private var sums: [Int32]
    /// The lowest row a piece reaches (−1 = none yet).
    private(set) var lowestStamped = -1
    /// Cells the two side edges take in each row.
    private var edgeCells = 0

    init(sheet: NestSheet, settings: NestSettings) {
        let cell = Nester.cell
        origin = sheet.rect.origin
        width = max(1, Int((sheet.rect.width / cell).rounded(.down)))
        height = max(1, Int((sheet.rect.height / cell).rounded(.down)))
        let grow = settings.spacing / 2
        taken = Raster.draw(width: width, height: height, origin: origin) { cg in
            for p in sheet.obstacles {
                cg.addPath(p.path)
                cg.fillPath(using: .evenOdd)
                let line = p.line + 2 * grow
                if line > 0 {
                    cg.setLineWidth(line)
                    cg.addPath(p.path)
                    cg.strokePath()
                }
            }
        }
        // The edges: half the spacing, at least `edgeMargin`.
        let edge = max(1, Int((max(grow, Nester.edgeMargin) / cell).rounded(.up)))
        edgeCells = min(width, 2 * edge)
        for y in 0..<height {
            for x in 0..<width where x < edge || y < edge || x >= width - edge || y >= height - edge { taken[y * width + x] = 255 }
        }
        sums = [Int32](repeating: 0, count: height * (width + 1))
        for y in 0..<height { sumRow(y) }
    }

    var freeCells: Int { taken.reduce(0) { $0 + ($1 == 0 ? 1 : 0) } }

    private mutating func sumRow(_ y: Int) {
        let base = y * (width + 1)
        var s: Int32 = 0
        sums[base] = 0
        for x in 0..<width {
            if taken[y * width + x] != 0 { s += 1 }
            sums[base + x + 1] = s
        }
    }

    /// The best place for a shape among the turns: the highest bottom edge, then the leftmost.
    func bestSpot(_ shape: Int, _ masks: inout MaskCache, _ turn: NestTurn) -> Spot? {
        var best: (spot: Spot, score: Int)?
        let row = width + 1
        for angle in turn.angles {
            let m = masks.mask(shape, angle)
            guard m.width <= width, m.height <= height else { continue }
            let limit = best?.score ?? Int.max
            let found: (Int, Int)? = m.runs.withUnsafeBufferPointer { runs in
                sums.withUnsafeBufferPointer { s in
                    let lastX = width - m.width
                    for y in 0...(height - m.height) {
                        if (y + m.height) * row >= limit { return nil }
                        var x = 0
                        while x <= lastX {
                            var skipTo = -1
                            var k = 0
                            while k < runs.count {
                                let base = (y + Int(runs[k])) * row
                                let a = x + Int(runs[k + 1]), b = x + Int(runs[k + 2])
                                if s[base + b] != s[base + a] {
                                    // The run hits a taken cell: no place before the last one it hits can work either.
                                    var c = b - 1
                                    while s[base + c + 1] == s[base + c] { c -= 1 }
                                    skipTo = c - Int(runs[k + 1]) + 1
                                    break
                                }
                                k += 3
                            }
                            if skipTo < 0 { return (x, y) }
                            x = max(x + 1, skipTo)
                        }
                    }
                    return nil
                }
            }
            if let (x, y) = found {
                let score = (y + m.height) * row + x
                if best == nil || score < best!.score { best = (Spot(mask: m, x: x, y: y, sheetOrigin: origin), score) }
            }
        }
        return best?.spot
    }

    mutating func stamp(_ m: NestMask, _ x: Int, _ y: Int) {
        var k = 0
        while k < m.runs.count {
            let row = y + Int(m.runs[k])
            for i in Int(m.runs[k + 1])..<Int(m.runs[k + 2]) { taken[row * width + x + i] = 255 }
            k += 3
        }
        for row in y..<(y + m.height) { sumRow(row) }
        lowestStamped = max(lowestStamped, y + m.height - 1)
    }

    /// Rows below `row` that are clear from side to side on the sheet before the pieces (`base`): only the edges taken.
    func clearBand(below row: Int, base: Grid) -> Double {
        guard row >= 0 else { return 0 }
        let edgeCells = base.edgeCells
        var count = 0
        for y in (row + 1)..<height {
            let taken = Int(base.sums[y * (width + 1) + width])
            if taken > edgeCells { break }
            count += 1
        }
        // The bottom edge's own rows aren't material that can be kept.
        return Double(max(0, count - base.bottomEdgeRows))
    }

    /// Rows the bottom edge takes whole.
    private var bottomEdgeRows: Int {
        var n = 0
        for y in stride(from: height - 1, through: 0, by: -1) where Int(sums[y * (width + 1) + width]) == width { n += 1 }
        return n
    }
}
