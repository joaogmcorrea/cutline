// Pointers of the Pen's group and the Eyedropper's loupe. The Pen, Add and Delete Anchor Point show their own icon
// as the pointer (as in Illustrator), black with a white outline so it shows on the sheet and on the dark mat; the
// pencil's tip is the hot spot. The Eyedropper shows a loupe like macOS's color sampler: what is under the pointer,
// magnified, with the center square and a ring in the color there.
import SwiftUI

enum ToolPointer {
    private static var made: [Tool: PointerStyle] = [:]

    static func style(_ tool: Tool) -> PointerStyle {
        if let done = made[tool] { return done }
        guard let icon = NSImage(named: tool.icon) else { return .rectSelection }
        let tinted = { (color: NSColor) in
            NSImage(size: icon.size, flipped: false) { rect in
                icon.draw(in: rect)
                color.set()
                rect.fill(using: .sourceIn)
                return true
            }
        }
        let white = tinted(.white), black = tinted(.black)
        // 24 pt with the icon at 20 pt in the middle; the halo is the white icon shifted all around.
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: true) { _ in
            let place = NSRect(x: 2, y: 2, width: 20, height: 20)
            for dx in [-1.2, 0, 1.2] { for dy in [-1.2, 0, 1.2] where dx != 0 || dy != 0 { white.draw(in: place.offsetBy(dx: dx, dy: dy)) } }
            black.draw(in: place)
            return true
        }
        // The Tabler pencil's tip is at (4, 20) of 24.
        let style = PointerStyle.image(Image(nsImage: image), hotSpot: UnitPoint(x: (2 + 4 * 20 / 24) / 24, y: (2 + 20 * 20 / 24) / 24))
        made[tool] = style
        return style
    }
}

/// The rotate pointer (just outside a corner of the selection, the Rotate tool, while turning): a curved arrow with a head
/// at each end, in the app's style (black with a white halo, like the tools' pointers), bulging toward `degrees` on screen
/// (counterclockwise from the right; 45 = toward the top-right corner). Made once per 10°.
enum RotatePointer {
    private static var made: [Int: PointerStyle] = [:]

    static func style(_ degrees: Double) -> PointerStyle {
        let step = (Int((degrees / 10).rounded()) * 10 % 360 + 360) % 360
        if let done = made[step] { return done }
        let style = PointerStyle.image(Image(nsImage: image(step)), hotSpot: .center)
        made[step] = style
        return style
    }

    /// The pointer's picture, 26 × 26 pt, bulging toward `step` degrees.
    static func image(_ step: Int) -> NSImage {
        NSImage(size: NSSize(width: 26, height: 26), flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            // Drawn bulging toward the top-right (45°), then turned to `step` around the middle (y down: a negative angle
            // turns counterclockwise on screen).
            cg.translateBy(x: 13, y: 13)
            cg.rotate(by: -Double(step - 45) * .pi / 180)
            cg.translateBy(x: -13, y: -13)
            let arrow = CGMutablePath()
            // A quarter of a circle around the bottom-left, from the right end (pointing down) to the top end (pointing left).
            let c = CGPoint(x: 6, y: 20), r = 12.5
            let at = { (a: Double) in CGPoint(x: c.x + r * cos(a * .pi / 180), y: c.y - r * sin(a * .pi / 180)) }
            arrow.move(to: at(8))
            for a in stride(from: 8.0, through: 82, by: 2) { arrow.addLine(to: at(a)) }
            let head = { (tip: CGPoint, dx: Double, dy: Double) in
                // A head along (dx, dy), 4.5 long, 4 wide on each side.
                let px = -dy, py = dx
                arrow.move(to: CGPoint(x: tip.x - dx * 4.5 + px * 4, y: tip.y - dy * 4.5 + py * 4))
                arrow.addLine(to: tip)
                arrow.addLine(to: CGPoint(x: tip.x - dx * 4.5 - px * 4, y: tip.y - dy * 4.5 - py * 4))
            }
            let end = at(8), top = at(82)
            head(CGPoint(x: end.x, y: end.y + 1.5), sin(8 * .pi / 180), cos(8 * .pi / 180))
            head(CGPoint(x: top.x - 1.5, y: top.y), -sin(82 * .pi / 180), -cos(82 * .pi / 180))
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.addPath(arrow)
            cg.setStrokeColor(NSColor.white.cgColor)
            cg.setLineWidth(4)
            cg.strokePath()
            cg.addPath(arrow)
            cg.setStrokeColor(NSColor.black.cgColor)
            cg.setLineWidth(1.6)
            cg.strokePath()
            return true
        }
    }
}

/// What the canvas shows at a point (mm): the frontmost image pixel, stroke or fill; the sheet is white; nil = the mat.
@MainActor
struct CanvasSampler {
    private struct Piece {
        let object: CanvasObject
        let outline: CGPath
        let stroke: CGPath?
    }

    private let doc: Document
    private let pieces: [Piece]

    /// `slack`: how far from a 0 pt stroke still counts as on it (mm).
    init(doc: Document, slack: Double) {
        self.doc = doc
        pieces = doc.objectsInOrder.reversed().filter { doc.visible($0) }.map { object in
            let outline = object.shapePath.cgPath
            let width = max(object.strokeWidth * 25.4 / 72, 2 * slack)
            let stroke = object.cutsLine || object.strokeWidth > 0 ? outline.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10) : nil
            return Piece(object: object, outline: outline, stroke: stroke)
        }
    }

    func color(at p: CGPoint) -> CMYK? {
        for piece in pieces {
            if let stroke = piece.stroke, stroke.contains(p) { return piece.object.strokeColor }
            guard piece.outline.contains(p, using: .evenOdd) else { continue }
            if piece.object.image != nil, let pixel = doc.pixelColor(of: piece.object, at: p) { return pixel }
            if let fill = piece.object.fill { return fill }
        }
        return doc.artboards.contains { $0.rect.contains(p) } ? CMYK(c: 0, m: 0, y: 0, k: 0) : nil
    }
}

struct EyedropperLoupe: View {
    let doc: Document
    let viewState: ViewState
    let pointer: Pointer

    private static let diameter = 120.0, ring = 12.0, cells = 11
    private static let mat = Color(white: 0.17)

    var body: some View {
        if let p = pointer.canvas {
            // One canvas point per square, as the eye sees it.
            let sampler = CanvasSampler(doc: doc, slack: 0.6 / viewState.scale)
            let half = Self.cells / 2
            let converter = doc.colors
            let colors = (0..<Self.cells).map { j in
                (0..<Self.cells).map { i in
                    sampler.color(at: viewState.mm(CGPoint(x: p.x + Double(i - half), y: p.y + Double(j - half)))).map(converter.color)
                }
            }
            Canvas { ctx, size in
                let inner = CGRect(origin: .zero, size: size).insetBy(dx: Self.ring, dy: Self.ring)
                let cell = inner.width / Double(Self.cells)
                var clipped = ctx
                clipped.clip(to: Path(ellipseIn: inner))
                var grid = Path()
                for j in 0..<Self.cells {
                    for i in 0..<Self.cells {
                        let square = CGRect(x: inner.minX + Double(i) * cell, y: inner.minY + Double(j) * cell, width: cell, height: cell)
                        clipped.fill(Path(square), with: .color(colors[j][i] ?? Self.mat))
                        grid.addRect(square)
                    }
                }
                clipped.stroke(grid, with: .color(.gray.opacity(0.7)), lineWidth: 0.6)
                let center = CGRect(x: inner.minX + Double(half) * cell, y: inner.minY + Double(half) * cell, width: cell, height: cell)
                ctx.stroke(Path(center.insetBy(dx: -0.5, dy: -0.5)), with: .color(.black), lineWidth: 2)
                ctx.stroke(Path(center.insetBy(dx: 1, dy: 1)), with: .color(.white), lineWidth: 1)
                // The ring in the color the click picks.
                let middle = CGRect(origin: .zero, size: size).insetBy(dx: Self.ring / 2, dy: Self.ring / 2)
                ctx.stroke(Path(ellipseIn: middle), with: .color(colors[half][half] ?? Self.mat), lineWidth: Self.ring)
                ctx.stroke(Path(ellipseIn: inner), with: .color(.gray), lineWidth: 1.5)
                ctx.stroke(Path(ellipseIn: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)), with: .color(.black.opacity(0.35)), lineWidth: 1)
            }
            .frame(width: Self.diameter, height: Self.diameter)
            .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            .position(p)
            .allowsHitTesting(false)
        }
    }
}
