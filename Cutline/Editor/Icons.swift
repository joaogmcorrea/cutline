// Panel icons drawn like the prototype's SVGs (24 × 24 grid), as macOS template images
// (tinted by the system: they work in light, dark and in segmented controls).
import AppKit
import SwiftUI

enum Icons {
    /// Drawing on a 24 × 24 grid with y down, as in the SVG.
    private static func image(_ size: CGFloat, grade: CGFloat = 24, _ render: @escaping () -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let scale = size / grade
            NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
            NSColor.black.set()
            render()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func lines(_ pointsList: [(CGFloat, CGFloat)], width: CGFloat, cap: NSBezierPath.LineCapStyle = .butt,
                               join: NSBezierPath.LineJoinStyle = .miter, alfa: CGFloat = 1) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: pointsList[0].0, y: pointsList[0].1))
        for q in pointsList.dropFirst() { p.line(to: NSPoint(x: q.0, y: q.1)) }
        p.lineWidth = width
        p.lineCapStyle = cap
        p.lineJoinStyle = join
        NSColor.black.withAlphaComponent(alfa).setStroke()
        p.stroke()
    }

    private static func polygon(_ pointsList: [(CGFloat, CGFloat)], alfa: CGFloat = 1) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: pointsList[0].0, y: pointsList[0].1))
        for q in pointsList.dropFirst() { p.line(to: NSPoint(x: q.0, y: q.1)) }
        p.close()
        NSColor.black.withAlphaComponent(alfa).setFill()
        p.fill()
    }

    private static func frame(_ r: CGRect, width: CGFloat, dashed: Bool = false, alfa: CGFloat = 1) {
        let p = NSBezierPath(rect: r)
        p.lineWidth = width
        if dashed { p.setLineDash([2, 1.5], count: 2, phase: 0) }
        NSColor.black.withAlphaComponent(alfa).setStroke()
        p.stroke()
    }

    static func cap(_ cap: LineCap) -> NSImage {
        image(16) {
            let style: NSBezierPath.LineCapStyle = switch cap {
            case .straight: .butt
            case .rounded: .round
            case .projected: .square
            }
            lines([(4, 12), (16, 12)], width: 5, cap: style)
            lines([(16, 6), (16, 18)], width: 1)
        }
    }

    static func join(_ join: LineJoin) -> NSImage {
        image(16) {
            let style: NSBezierPath.LineJoinStyle = switch join {
            case .sharp: .miter
            case .round: .round
            case .bevel: .bevel
            }
            lines([(6, 20), (6, 6), (20, 6)], width: 5, join: style)
        }
    }

    static func alignment(_ alignment: StrokeAlignment) -> NSImage {
        image(16) {
            frame(CGRect(x: 5, y: 5, width: 14, height: 14), width: 1)
            let r: CGRect = switch alignment {
            case .center: CGRect(x: 5, y: 5, width: 14, height: 14)
            case .inside: CGRect(x: 7, y: 7, width: 10, height: 10)
            case .outside: CGRect(x: 3, y: 3, width: 18, height: 18)
            }
            frame(r, width: 4, alfa: 0.5)
        }
    }

    /// Line sample (solid or dashed), for the style menu.
    static func line(_ style: LineStyle, width: CGFloat = 110) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: 8), flipped: true) { _ in
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 0, y: 4))
            p.line(to: NSPoint(x: width, y: 4))
            p.lineWidth = 1.5
            if let defaultValue = style.defaultValue { p.setLineDash(defaultValue.map { CGFloat($0) * 3 }, count: defaultValue.count, phase: 0) }
            NSColor.black.setStroke()
            p.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    static func pathfinder(_ operation: PathfinderOperation) -> NSImage {
        image(22) {
            switch operation {
            case .unite:
                polygon([(3, 3), (14, 3), (14, 8), (21, 8), (21, 21), (10, 21), (10, 16), (3, 16)])
            case .minusFront:
                polygon([(3, 3), (14, 3), (14, 8), (8, 8), (8, 16), (3, 16)])
                frame(CGRect(x: 8.5, y: 8.5, width: 12, height: 12), width: 1, dashed: true)
            case .intersect:
                frame(CGRect(x: 3.5, y: 3.5, width: 10, height: 10), width: 1, dashed: true)
                frame(CGRect(x: 10.5, y: 10.5, width: 10, height: 10), width: 1, dashed: true)
                polygon([(10, 10), (14, 10), (14, 14), (10, 14)])
            case .exclude:
                polygon([(3, 3), (14, 3), (14, 10), (10, 10), (10, 14), (3, 14)])
                polygon([(14, 10), (21, 10), (21, 21), (10, 21), (10, 14), (14, 14)])
            case .divide:
                polygon([(3, 3), (14, 3), (14, 10), (10, 10), (10, 14), (3, 14)])
                polygon([(10.5, 10.5), (13.5, 10.5), (13.5, 13.5), (10.5, 13.5)])
                polygon([(14, 10), (21, 10), (21, 21), (10, 21), (10, 14), (14, 14)], alfa: 0.55)
            case .minusBack:
                frame(CGRect(x: 3.5, y: 3.5, width: 11, height: 11), width: 1, dashed: true)
                polygon([(15, 9), (21, 9), (21, 21), (9, 21), (9, 15), (15, 15)])
            case .subtractAll:
                // The top one (dashed) takes a bite out of both below it.
                frame(CGRect(x: 7.5, y: 3.5, width: 10, height: 10), width: 1, dashed: true)
                polygon([(3, 9), (7, 9), (7, 14), (11, 14), (11, 21), (3, 21)])
                polygon([(18, 9), (21, 9), (21, 21), (13, 21), (13, 14), (18, 14)])
            case .crop:
                // Only what is inside the top one (dashed) stays; the rest of the one below goes away (faint).
                frame(CGRect(x: 8.5, y: 3.5, width: 12, height: 12), width: 1, dashed: true)
                polygon([(9, 8), (16, 8), (16, 15), (9, 15)])
                polygon([(3, 8), (8, 8), (8, 16), (16, 16), (16, 21), (3, 21)], alfa: 0.3)
            }
        }
    }

}
