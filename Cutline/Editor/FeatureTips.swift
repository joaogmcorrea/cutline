// Rich tips, as Illustrator's: over a looping animation of what the feature does, the name, the shortcut in a little key
// and a sentence. The tools' tips (Editor/Panels.swift) and the side panel icons of Nest, Offset and Artboards
// (Editor/SidePanel.swift) use them. The animations are drawn here (no video files): they follow dark and light mode and
// stay sharp at any size.
import SwiftUI

/// The card: the animation on top (when the feature has one), the name with its shortcut and what it does.
struct RichTipCard: View {
    let title: String
    let shortcut: String?
    let summary: String
    let preview: TipPreview?

    static let width = 250.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let preview { TipAnimation(preview: preview).frame(height: 130) }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title).font(.headline)
                    if let shortcut {
                        Text(verbatim: shortcut)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
        }
        .frame(width: Self.width, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}

/// What a tip's animation shows.
enum TipPreview {
    /// The Artboard tool: an artboard resized by its corner, then the + by its edge adds another.
    case artboards
    /// Offset: an outline growing around a star and going back.
    case offset
    /// Nest: scattered pieces packing together on the artboard and scattering again.
    case nest
    /// Type on a Path: letters coming one by one along an arc (the start screen's spotlight, WhatsNew.swift).
    case typeOnPath

    /// How long one loop takes (seconds).
    var period: Double {
        switch self {
        case .artboards: 5.5
        case .offset: 4
        case .nest: 5
        case .typeOnPath: 5
        }
    }
}

/// The looping animation, drawn on a gray pasteboard like the canvas (also on the start screen's spotlight).
struct TipAnimation: View {
    let preview: TipPreview
    @Environment(\.colorScheme) private var scheme
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            Canvas { ctx, size in
                let t = Self.loopTime(context.date.timeIntervalSince(start), period: preview.period)
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(scheme == .dark ? Color(white: 0.36) : Color(white: 0.8)))
                switch preview {
                case .artboards: TipDrawing.artboards(&ctx, size: size, t: t)
                case .offset: TipDrawing.offset(&ctx, size: size, t: t)
                case .nest: TipDrawing.nest(&ctx, size: size, t: t)
                case .typeOnPath: TipDrawing.typeOnPath(&ctx, size: size, t: t)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Where in the loop the animation is (seconds).
    private static func loopTime(_ elapsed: Double, period: Double) -> Double {
        #if DEBUG
        if let fixed = DebugHooks.tipTime { return fixed }
        #endif
        return elapsed.truncatingRemainder(dividingBy: period)
    }
}

/// The three drawings, as functions of the time in the loop.
private enum TipDrawing {
    /// 0 before `a`, 1 after `b`, eased in between.
    static func ease(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let x = min(max((t - a) / (b - a), 0), 1)
        return x * x * (3 - 2 * x)
    }

    static func mix(_ a: Double, _ b: Double, _ k: Double) -> Double { a + (b - a) * k }

    static func mix(_ a: CGPoint, _ b: CGPoint, _ k: Double) -> CGPoint { CGPoint(x: mix(a.x, b.x, k), y: mix(a.y, b.y, k)) }

    static let cutBlue = Color(red: 0.0, green: 0.48, blue: 1.0)
    static let cutRed = Color(red: 0.93, green: 0.11, blue: 0.14)
    static let cutGreen = Color(red: 0.15, green: 0.65, blue: 0.3)

    static func sheet(_ ctx: inout GraphicsContext, _ r: CGRect) {
        var shadowed = ctx
        shadowed.addFilter(.shadow(color: .black.opacity(0.25), radius: 3, y: 1))
        shadowed.fill(Path(r), with: .color(.white))
    }

    static func star(center c: CGPoint, outer: Double, inner: Double, points: Int = 5, turn: Double = 0) -> Path {
        var p = Path()
        for i in 0..<(points * 2) {
            let radius = i.isMultiple(of: 2) ? outer : inner
            let angle = -Double.pi / 2 + turn + Double(i) * .pi / Double(points)
            let q = CGPoint(x: c.x + cos(angle) * radius, y: c.y + sin(angle) * radius)
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        p.closeSubpath()
        return p
    }

    // MARK: Artboards

    /// An artboard grows by its corner (the cursor drags the handle), the cursor goes to the right edge, the + shows and
    /// a click adds the 2nd artboard beside it, which becomes the active one.
    static func artboards(_ ctx: inout GraphicsContext, size: CGSize, t: Double) {
        let grow = ease(t, 0.5, 1.7)
        let first = CGRect(x: 24, y: 32, width: mix(78, 100, grow), height: mix(52, 68, grow))
        let second = CGRect(x: 24 + 100 + 14, y: 32, width: 100, height: 68)
        let added = ease(t, 3.3, 3.6)
        let leaving = ease(t, 5.0, 5.4)
        let secondAlpha = added * (1 - leaving)
        let firstActive = secondAlpha < 0.5

        sheet(&ctx, first)
        drawArt(&ctx, in: first)
        if secondAlpha > 0 {
            var faded = ctx
            faded.opacity = secondAlpha
            sheet(&faded, second)
            drawArt(&faded, in: second)
        }
        label(&ctx, "01", at: first, active: firstActive)
        if secondAlpha > 0 {
            var faded = ctx
            faded.opacity = secondAlpha
            label(&faded, "02", at: second, active: !firstActive)
        }
        selection(&ctx, firstActive ? first : second, alpha: firstActive ? 1 : secondAlpha)

        // The cursor: on the corner while it grows, then to the + by the right edge, then back.
        let corner = CGPoint(x: first.maxX, y: first.maxY)
        let plus = CGPoint(x: first.maxX + 7, y: first.midY)
        // The pointer stops just below and to the right of the +, so the button stays in view.
        let onPlus = CGPoint(x: plus.x + 6, y: plus.y + 7)
        let rest = CGPoint(x: 70, y: 112)
        let cursor: CGPoint
        if t < 0.5 { cursor = mix(rest, corner, ease(t, 0, 0.45)) }
        else if t < 2.0 { cursor = corner }
        else if t < 3.6 { cursor = mix(corner, onPlus, ease(t, 2.0, 2.7)) }
        else { cursor = mix(onPlus, rest, ease(t, 4.2, 5.2)) }
        // The + by the edge, as on the canvas (blue under the pointer, until the click).
        let plusShows = ease(t, 2.3, 2.6) * (1 - ease(t, 3.5, 3.7))
        if plusShows > 0 {
            var layer = ctx
            layer.opacity = plusShows
            let hot = t > 2.7
            let circle = Path(ellipseIn: CGRect(x: plus.x - 6, y: plus.y - 6, width: 12, height: 12))
            layer.fill(circle, with: .color(hot ? .accentColor : .white))
            if !hot { layer.stroke(circle, with: .color(.black.opacity(0.8)), lineWidth: 0.75) }
            var cross = Path()
            cross.move(to: CGPoint(x: plus.x - 3, y: plus.y))
            cross.addLine(to: CGPoint(x: plus.x + 3, y: plus.y))
            cross.move(to: CGPoint(x: plus.x, y: plus.y - 3))
            cross.addLine(to: CGPoint(x: plus.x, y: plus.y + 3))
            layer.stroke(cross, with: .color(hot ? .white : .black), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        }
        artboardCursor(&ctx, at: cursor, pressed: (t > 0.5 && t < 1.8) || (t > 3.2 && t < 3.4))
    }

    /// A little design on the sheet: a red star (the cut) and two gray lines.
    private static func drawArt(_ ctx: inout GraphicsContext, in r: CGRect) {
        let s = r.height / 68
        let c = CGPoint(x: r.midX, y: r.minY + r.height * 0.4)
        ctx.stroke(star(center: c, outer: 15 * s, inner: 6.5 * s), with: .color(cutRed), lineWidth: 1.2)
        for (i, w) in [0.55, 0.35].enumerated() {
            let y = r.minY + r.height * (0.72 + Double(i) * 0.1)
            ctx.fill(Path(roundedRect: CGRect(x: r.midX - r.width * w / 2, y: y, width: r.width * w, height: 3 * s), cornerRadius: 1),
                     with: .color(Color(white: 0.78)))
        }
    }

    /// The artboard's number on a tab over its top-left corner (blue when active), as Illustrator's.
    private static func label(_ ctx: inout GraphicsContext, _ text: String, at r: CGRect, active: Bool) {
        let tab = CGRect(x: r.minX, y: r.minY, width: 17, height: 11)
        ctx.fill(Path(tab), with: .color(active ? Color(red: 0.36, green: 0.62, blue: 0.95) : Color(white: 0.85)))
        ctx.draw(Text(verbatim: text).font(.system(size: 8, weight: .bold)).foregroundStyle(.black), at: CGPoint(x: tab.midX, y: tab.midY))
    }

    /// The active artboard's dashed edge and handles.
    private static func selection(_ ctx: inout GraphicsContext, _ r: CGRect, alpha: Double) {
        guard alpha > 0 else { return }
        var layer = ctx
        layer.opacity = alpha
        let blue = Color(red: 0.36, green: 0.62, blue: 0.95)
        layer.stroke(Path(r), with: .color(blue), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        for p in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                  CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY),
                  CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)] {
            let square = Path(CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5))
            layer.fill(square, with: .color(.white))
            layer.stroke(square, with: .color(blue), lineWidth: 0.75)
        }
    }

    /// The Artboard tool's pointer: a small cross with a square, black with a white edge (as Illustrator's).
    private static func artboardCursor(_ ctx: inout GraphicsContext, at p: CGPoint, pressed: Bool) {
        var glyph = Path()
        glyph.move(to: CGPoint(x: p.x - 5, y: p.y))
        glyph.addLine(to: CGPoint(x: p.x + 5, y: p.y))
        glyph.move(to: CGPoint(x: p.x, y: p.y - 5))
        glyph.addLine(to: CGPoint(x: p.x, y: p.y + 5))
        glyph.addRect(CGRect(x: p.x + 3, y: p.y + 3, width: 9, height: 9))
        let s = pressed ? 0.9 : 1.0
        let shrink = CGAffineTransform(translationX: p.x, y: p.y).scaledBy(x: s, y: s).translatedBy(x: -p.x, y: -p.y)
        let shape = glyph.applying(shrink)
        ctx.stroke(shape, with: .color(.white), lineWidth: 3)
        ctx.stroke(shape, with: .color(.black), lineWidth: 1.2)
    }

    // MARK: Offset

    /// A star on the sheet; the offset outline grows around it (round corners), stays, and goes back.
    static func offset(_ ctx: inout GraphicsContext, size: CGSize, t: Double) {
        let page = CGRect(x: size.width / 2 - 70, y: 14, width: 140, height: size.height - 28)
        sheet(&ctx, page)
        let c = CGPoint(x: page.midX, y: page.midY + 3)
        let shape = star(center: c, outer: 34, inner: 15)
        let distance = 11 * ease(t, 0.5, 1.6) * (1 - ease(t, 2.9, 3.7))
        if distance > 0.2 {
            let band = shape.cgPath.copy(strokingWithWidth: 2 * distance, lineCap: .round, lineJoin: .round, miterLimit: 10)
                .normalized(using: .winding)
            let outline = Path(band.union(shape.cgPath.normalized(using: .evenOdd)))
            ctx.fill(outline, with: .color(cutRed.opacity(0.08)))
            ctx.stroke(outline, with: .color(cutRed), lineWidth: 1.3)
        }
        ctx.fill(shape, with: .color(cutBlue.opacity(0.12)))
        ctx.stroke(shape, with: .color(cutBlue), lineWidth: 1.3)
    }

    // MARK: Nest

    /// A piece: its shape around (0, 0) and where it goes, scattered and nested (center, turn in radians).
    private struct Piece {
        let shape: Path
        let color: Color
        let from: CGPoint, fromTurn: Double
        let to: CGPoint, toTurn: Double
    }

    private static let pieces: [Piece] = {
        let circle = Path(ellipseIn: CGRect(x: -13, y: -13, width: 26, height: 26))
        let square = Path(roundedRect: CGRect(x: -16, y: -11, width: 32, height: 22), cornerRadius: 3)
        let ellipse = Path(ellipseIn: CGRect(x: -15, y: -10, width: 30, height: 20))
        let tiny = Path(roundedRect: CGRect(x: -10, y: -10, width: 20, height: 20), cornerRadius: 2)
        var triangle = Path()
        triangle.move(to: CGPoint(x: 0, y: -13))
        triangle.addLine(to: CGPoint(x: 14, y: 11))
        triangle.addLine(to: CGPoint(x: -14, y: 11))
        triangle.closeSubpath()
        let starShape = star(center: .zero, outer: 15, inner: 6.5)
        // The sheet is 150 × 100 from (50, 15): the nested places fill it in two rows.
        return [
            Piece(shape: circle, color: cutBlue, from: CGPoint(x: 30, y: 30), fromTurn: 0, to: CGPoint(x: 66, y: 32), toTurn: 0),
            Piece(shape: square, color: cutRed, from: CGPoint(x: 200, y: 96), fromTurn: 0.6, to: CGPoint(x: 99, y: 30), toTurn: 0),
            Piece(shape: starShape, color: cutGreen, from: CGPoint(x: 120, y: 64), fromTurn: 0.9, to: CGPoint(x: 135, y: 33), toTurn: 0),
            Piece(shape: triangle, color: cutBlue, from: CGPoint(x: 222, y: 34), fromTurn: -0.7, to: CGPoint(x: 172, y: 33), toTurn: 0),
            Piece(shape: ellipse, color: cutGreen, from: CGPoint(x: 70, y: 102), fromTurn: 0.4, to: CGPoint(x: 70, y: 64), toTurn: 0),
            Piece(shape: tiny, color: cutRed, from: CGPoint(x: 160, y: 22), fromTurn: 0.5, to: CGPoint(x: 101, y: 63), toTurn: 0),
            Piece(shape: circle, color: cutRed, from: CGPoint(x: 26, y: 88), fromTurn: 0, to: CGPoint(x: 131, y: 63), toTurn: 0),
            Piece(shape: triangle, color: cutGreen, from: CGPoint(x: 160, y: 108), fromTurn: 2.4, to: CGPoint(x: 166, y: 61), toTurn: .pi),
        ]
    }()

    /// The pieces fly in from where they are scattered and pack together on the artboard, one after the other; then
    /// they scatter again.
    static func nest(_ ctx: inout GraphicsContext, size: CGSize, t: Double) {
        let page = CGRect(x: 50, y: 15, width: 150, height: 100)
        sheet(&ctx, page)
        for (i, piece) in pieces.enumerated() {
            let k = ease(t, 0.5 + Double(i) * 0.12, 1.4 + Double(i) * 0.12) * (1 - ease(t, 3.8, 4.6))
            let center = mix(piece.from, piece.to, k)
            let turn = mix(piece.fromTurn, piece.toTurn, k)
            let placed = piece.shape.applying(CGAffineTransform(translationX: center.x, y: center.y).rotated(by: turn))
            ctx.fill(placed, with: .color(piece.color.opacity(0.14)))
            ctx.stroke(placed, with: .color(piece.color), lineWidth: 1.2)
        }
    }
    // MARK: Type on a Path

    /// The letters of "Happy Birthday" come one by one along a dashed arc, from its start to its end, and leave together.
    static func typeOnPath(_ ctx: inout GraphicsContext, size: CGSize, t: Double) {
        let page = CGRect(x: 40, y: 12, width: 170, height: 106)
        sheet(&ctx, page)
        let a = CGPoint(x: 58, y: 100), c = CGPoint(x: 125, y: -2), b = CGPoint(x: 192, y: 100)
        func point(_ u: Double) -> CGPoint {
            CGPoint(x: (1 - u) * (1 - u) * a.x + 2 * (1 - u) * u * c.x + u * u * b.x,
                    y: (1 - u) * (1 - u) * a.y + 2 * (1 - u) * u * c.y + u * u * b.y)
        }
        var arc = Path()
        arc.move(to: a)
        arc.addQuadCurve(to: b, control: c)
        ctx.stroke(arc, with: .color(cutBlue.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        // Points every 1/200 of the curve, to place the letters by the length along it.
        let samples = (0...200).map { point(Double($0) / 200) }
        var lengths = [0.0]
        for i in 1..<samples.count { lengths.append(lengths[i - 1] + hypot(samples[i].x - samples[i - 1].x, samples[i].y - samples[i - 1].y)) }
        let letters = Array("Happy Birthday")
        // About how wide each letter is, so the narrow ones don't leave gaps.
        let widths = letters.map { "iltr ".contains($0) ? 6.5 : ($0 == "B" ? 12.0 : 10.5) }
        let total = widths.reduce(0, +)
        let leave = 1 - ease(t, 4.1, 4.7)
        var along = (lengths.last! - total) / 2
        for (i, letter) in letters.enumerated() {
            defer { along += widths[i] }
            guard letter != " " else { continue }
            let shown = ease(t, 0.4 + Double(i) * 0.17, 0.6 + Double(i) * 0.17) * leave
            guard shown > 0 else { continue }
            let target = along + widths[i] / 2
            let j = min(max(lengths.firstIndex { $0 >= target } ?? samples.count - 1, 1), samples.count - 1)
            let p = samples[j], q = samples[j - 1]
            var letterCtx = ctx
            letterCtx.opacity = shown
            letterCtx.translateBy(x: p.x, y: p.y)
            letterCtx.rotate(by: .radians(atan2(p.y - q.y, p.x - q.x)))
            letterCtx.draw(Text(verbatim: String(letter)).font(.system(size: 17, weight: .bold, design: .serif))
                .foregroundStyle(Color(red: 0.84, green: 0.2, blue: 0.42)), at: CGPoint(x: 0, y: -2), anchor: .bottom)
        }
        // The path's start and end.
        for end in [a, b] { ctx.fill(Path(ellipseIn: CGRect(x: end.x - 3, y: end.y - 3, width: 6, height: 6)), with: .color(cutBlue)) }
    }
}
