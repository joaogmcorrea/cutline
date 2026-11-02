// Rulers in mm (origin at the page's top-left corner), as in the prototype: glass strips at the
// top and left of the free area, with the pointer mark. Dragging from them creates guides (in CanvasView, which
// receives the gesture — the rulers only draw).
import SwiftUI

/// Pointer position over the canvas. It lives outside CanvasView's state: only readers (rulers, pen
/// preview) redraw when the mouse moves.
@Observable
final class Pointer {
    var canvas: CGPoint?
    var mm: CGPoint?
}

enum Axis {
    /// Vertical guide (position in x) or horizontal (in y).
    case vertical, horizontal
}

struct RulerGeometry {
    static let strokeWidth = 18.0
    /// Top-left corner of the rulers and how far they reach (canvas points).
    let area: CGRect

    var join: CGRect { CGRect(x: area.minX, y: area.minY, width: Self.strokeWidth, height: Self.strokeWidth) }
    var horizontal: CGRect {
        CGRect(x: area.minX + Self.strokeWidth + 2, y: area.minY, width: max(area.width - Self.strokeWidth - 2, 0), height: Self.strokeWidth)
    }
    var vertical: CGRect {
        CGRect(x: area.minX, y: area.minY + Self.strokeWidth + 2, width: Self.strokeWidth, height: max(area.height - Self.strokeWidth - 2, 0))
    }
}

struct Rulers: View {
    let geometry: RulerGeometry
    let viewState: ViewState
    let pointer: Pointer
    let hasGuides: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            span(geometry.horizontal, horizontal: true)
            span(geometry.vertical, horizontal: false)
            RoundedRectangle(cornerRadius: 6)
                .fill(.clear)
                .frame(width: geometry.join.width, height: geometry.join.height)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    if hasGuides {
                        Image(.close).resizable().frame(width: 9, height: 9).foregroundStyle(.secondary)
                    }
                }
                .help("Double-click to clear the guides")
                .offset(x: geometry.join.minX, y: geometry.join.minY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func span(_ r: CGRect, horizontal: Bool) -> some View {
        Canvas { ctx, size in
            render(&ctx, size: size, origin: horizontal ? viewState.origin.x - r.minX : viewState.origin.y - r.minY, horizontal: horizontal)
        }
        .frame(width: r.width, height: r.height)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 6))
        .offset(x: r.minX, y: r.minY)
    }

    /// Step of the major ticks so they are ≥ 55 pt apart; subdivisions of 5 or 10.
    private func render(_ ctx: inout GraphicsContext, size: CGSize, origin: Double, horizontal: Bool) {
        let e = viewState.scale, rg = RulerGeometry.strokeWidth
        let step = [1.0, 2, 5, 10, 20, 50, 100, 200, 500].first { $0 * e >= 55 } ?? 500
        var sub = step / (String(Int(step)).first == "5" ? 5 : 10)
        if sub * e < 4 { sub *= 5 }
        let length = horizontal ? size.width : size.height
        let start = (-origin / e / sub).rounded(.down) * sub, end = (length - origin) / e
        var marks = Path()
        var v = start
        while v <= end {
            let pos = (origin + v * e).rounded() + 0.5
            let larger = abs(v / step - (v / step).rounded()) < 1e-6
            let middle = !larger && abs(v * 2 / step - (v * 2 / step).rounded()) < 1e-6
            let t = larger ? rg * 0.55 : middle ? 6 : 3.5
            if horizontal {
                marks.move(to: CGPoint(x: pos, y: rg))
                marks.addLine(to: CGPoint(x: pos, y: rg - t))
            } else {
                marks.move(to: CGPoint(x: rg, y: pos))
                marks.addLine(to: CGPoint(x: rg - t, y: pos))
            }
            if larger {
                let text = ctx.resolve(Text("\(Int(v.rounded()))").font(.system(size: 8.5)).foregroundStyle(.secondary))
                if horizontal {
                    ctx.draw(text, at: CGPoint(x: pos + 2, y: 1), anchor: .topLeading)
                } else {
                    var rotated = ctx
                    rotated.translateBy(x: 1, y: pos - 2)
                    rotated.rotate(by: .degrees(-90))
                    rotated.draw(text, at: .zero, anchor: .topLeading)
                }
            }
            v += sub
        }
        ctx.stroke(marks, with: .color(.secondary), lineWidth: 0.6)
        if let p = pointer.mm {
            let pos = (origin + (horizontal ? p.x : p.y) * e).rounded() + 0.5
            var mark = Path()
            if horizontal {
                mark.move(to: CGPoint(x: pos, y: 0))
                mark.addLine(to: CGPoint(x: pos, y: rg))
            } else {
                mark.move(to: CGPoint(x: 0, y: pos))
                mark.addLine(to: CGPoint(x: rg, y: pos))
            }
            ctx.stroke(mark, with: .color(.accentColor), lineWidth: 1)
        }
    }
}
