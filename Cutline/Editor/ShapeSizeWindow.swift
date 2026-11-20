// A shape tool clicked without dragging asks the size, as Illustrator's windows do: Rectangle and Ellipse (width and height,
// with the proportion link), Polygon (radius and sides), Star (radius 1 and 2, points) and Line (length and angle). The
// rectangle and the ellipse start at the click (⌥-click: centered on it); the polygon and the star are centered on it; the
// line starts there. The windows open with the last size used, also by dragging, as Illustrator remembers it while the app
// is open; the polygon's sides and the star's points and radii also go to the next drag.
import AppKit
import SwiftUI

/// Opens the window when `Document.shapeRequest` is set (in the window's `.background`, like the Rotate window's sheet).
struct ShapeSizeSheet: ViewModifier {
    @Bindable var doc: Document

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { doc.shapeRequest }, set: { doc.shapeRequest = $0 })) { request in
            ShapeSizeWindow(doc: doc, request: request)
        }
    }
}

/// The last sizes used (mm, degrees), while the app is open.
@MainActor
enum ShapeSizes {
    static var rectangle = CGSize(width: 30, height: 30)
    static var ellipse = CGSize(width: 30, height: 30)
    static var linked = false
    static var polygonRadius = 15.0
    static var polygonSides = PolygonShape.defaultSides
    /// Illustrator's order: radius 1 to the inner corners, radius 2 to the outer ones (either may be the bigger one).
    static var starRadius1 = 7.5
    static var starRadius2 = 15.0
    static var starPoints = 5
    static var lineLength = 30.0
    static var lineAngle = 0.0

    /// The star's inner radius as a fraction of the outer one (what `ShapeKind.star` keeps).
    static var starInner: Double {
        let outer = max(starRadius1, starRadius2)
        return outer > 0 ? min(starRadius1, starRadius2) / outer : 0.5
    }

    /// A shape just drawn by dragging: its size is the next window's.
    static func remember(_ object: CanvasObject, tool: Tool) {
        let r = object.frame.standardized
        switch tool {
        case .rectangle: rectangle = r.size
        case .ellipse: ellipse = r.size
        case .polygon: polygonRadius = PolygonShape.radius(sides: polygonSides, frame: r)
        case .star:
            let outer = CanvasObject.starRadius(points: starPoints, innerRadius: starInner, frame: r), inner = outer * starInner
            if starRadius1 <= starRadius2 { (starRadius1, starRadius2) = (inner, outer) } else { (starRadius1, starRadius2) = (outer, inner) }
        default: break
        }
    }

    static func rememberLine(from start: CGPoint, to end: CGPoint) {
        lineLength = hypot(end.x - start.x, end.y - start.y)
        // Counterclockwise from the right, as Illustrator (the page's y goes down).
        lineAngle = CanvasObject.normalizedAngle((atan2(start.y - end.y, end.x - start.x) * 180 / .pi * 100).rounded() / 100)
    }
}

extension Document {
    /// A shape tool's new object in that frame (the polygon is a path with its parameter, see `PolygonShape`; the polygon's
    /// sides and the star's points and radii are the last ones used).
    func shapeObject(_ tool: Tool, frame: CGRect) -> CanvasObject {
        let shape: ShapeKind = switch tool {
        case .ellipse: .ellipse
        case .star: .star(points: ShapeSizes.starPoints, innerRadius: ShapeSizes.starInner)
        default: .rectangle(radius: 0)
        }
        var object = newObject(shape, frame: frame)
        if tool == .polygon { object.setPolygon(sides: ShapeSizes.polygonSides) }
        return object
    }

    /// The Line tool's object: an open path of two nodes, without fill (it cuts like any stroke).
    func lineObject(from start: CGPoint, to end: CGPoint) -> CanvasObject? {
        guard start != end else { return nil }
        var object = newObject(.shapePath([]), frame: .zero)
        object.setNodes([Subpath(nodes: [Node(point: start), Node(point: end)], closed: false)])
        object.fill = nil
        object.label = String(localized: "Line")
        return object
    }
}

struct ShapeSizeWindow: View {
    @Bindable var doc: Document
    let request: ShapeRequest
    @Environment(\.dismiss) private var dismiss
    @AppStorage(LengthUnit.key) private var unit = LengthUnit.mm

    // Lengths in mm (the fields show them in the Settings unit).
    @State private var width = 30.0
    @State private var height = 30.0
    @State private var linked = false
    /// Height ÷ width when the link went on (each side follows the other by it, so they don't push each other forever).
    @State private var ratio = 1.0
    @State private var radius = 15.0
    @State private var radius2 = 15.0
    @State private var count = 6.0
    @State private var angle = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            fields
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 300)
        .onAppear {
            switch request.tool {
            case .rectangle, .ellipse:
                let size = request.tool == .rectangle ? ShapeSizes.rectangle : ShapeSizes.ellipse
                (width, height, linked) = (size.width, size.height, ShapeSizes.linked)
                ratio = size.width > 0 ? size.height / size.width : 1
            case .polygon: (radius, count) = (ShapeSizes.polygonRadius, Double(ShapeSizes.polygonSides))
            case .star: (radius, radius2, count) = (ShapeSizes.starRadius1, ShapeSizes.starRadius2, Double(ShapeSizes.starPoints))
            case .line: (width, angle) = (ShapeSizes.lineLength, ShapeSizes.lineAngle)
            default: break
            }
            #if DEBUG
            DebugHooks.driveShapeWindow(width: $width, height: $height, linked: $linked, radius: $radius, radius2: $radius2, count: $count,
                                        angle: $angle, ok: { create() }, cancel: { close() })
            #endif
        }
    }

    private var title: String { request.tool.name }

    @ViewBuilder
    private var fields: some View {
        switch request.tool {
        case .rectangle, .ellipse:
            HStack(spacing: 10) {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
                    row("Width:") { length($width) }
                    row("Height:") { length($height) }
                }
                .fixedSize()
                Button {
                    linked.toggle()
                } label: {
                    Image(.aspectRatio)
                        .resizable()
                        .frame(width: 17, height: 17)
                        .foregroundStyle(linked ? Color.accentColor : .secondary)
                        .frame(width: 26, height: 26)
                        .background(linked ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(linked ? "Proportions locked" as LocalizedStringKey : "Keep proportions")
            }
            .onChange(of: linked) { _, on in
                if on, width > 0 { ratio = height / width }
            }
            .onChange(of: width) { _, new in
                if linked, abs(height - new * ratio) > 1e-9 { height = new * ratio }
            }
            .onChange(of: height) { _, new in
                if linked, ratio > 0, abs(width - new / ratio) > 1e-9 { width = new / ratio }
            }
        case .polygon:
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
                row("Radius:") { length($radius) }
                row("Sides:") { whole($count) }
            }
        case .star:
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
                row("Radius 1:") { length($radius) }
                row("Radius 2:") { length($radius2) }
                row("Points:") { whole($count) }
            }
        case .line:
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
                row("Length:") { length($width) }
                row("Angle:") {
                    HStack(spacing: 8) {
                        AngleDial(angle: $angle)
                        NumberEntry(value: $angle, digits: 2, step: 1, width: 64, suffix: "°")
                    }
                }
            }
        default:
            EmptyView()
        }
    }

    private func row(_ label: LocalizedStringKey, @ViewBuilder _ field: () -> some View) -> some View {
        GridRow {
            Text(label).gridColumnAlignment(.trailing)
            field()
        }
    }

    /// A length in mm, shown and typed in the Settings unit.
    private func length(_ mm: Binding<Double>) -> some View {
        NumberEntry(value: Binding(get: { unit.show(mm.wrappedValue) }, set: { mm.wrappedValue = unit.mm($0) }),
                    digits: unit.fractionDigits, step: unit == .mm ? 1 : 0.1, suffix: unit.symbol)
    }

    /// Sides or points: 3 to 40, with the arrows always there (as Illustrator's).
    private func whole(_ value: Binding<Double>) -> some View {
        NumberEntry(value: value, digits: 0, step: 1, width: 64, always: true)
    }

    private var valid: Bool {
        switch request.tool {
        case .rectangle, .ellipse: width >= 0.01 && height >= 0.01
        case .polygon: radius >= 0.01
        case .star: max(radius, radius2) >= 0.01
        case .line: width >= 0.01
        default: false
        }
    }

    private func close() {
        doc.shapeRequest = nil
        dismiss()
    }

    /// The shape at the click (one undo step), and its size for the next time.
    private func create() {
        guard valid else { return }
        let p = request.point
        let sides = min(max(Int(count.rounded()), PolygonShape.sideRange.lowerBound), PolygonShape.sideRange.upperBound)
        var object: CanvasObject?
        switch request.tool {
        case .rectangle, .ellipse:
            let size = CGSize(width: max(width, 0.1), height: max(height, 0.1))
            if request.tool == .rectangle { ShapeSizes.rectangle = size } else { ShapeSizes.ellipse = size }
            ShapeSizes.linked = linked
            let origin = request.fromCenter ? CGPoint(x: p.x - size.width / 2, y: p.y - size.height / 2) : p
            object = doc.shapeObject(request.tool, frame: CGRect(origin: origin, size: size))
        case .polygon:
            (ShapeSizes.polygonRadius, ShapeSizes.polygonSides) = (radius, sides)
            object = doc.shapeObject(.polygon, frame: PolygonShape.frame(sides: sides, radius: radius, center: p))
        case .star:
            (ShapeSizes.starRadius1, ShapeSizes.starRadius2, ShapeSizes.starPoints) = (max(radius, 0), max(radius2, 0), sides)
            let frame = CanvasObject.starFrame(points: sides, innerRadius: ShapeSizes.starInner, radius: max(radius, radius2), center: p)
            object = doc.shapeObject(.star, frame: frame)
        case .line:
            let degrees = CanvasObject.normalizedAngle(angle)
            (ShapeSizes.lineLength, ShapeSizes.lineAngle) = (width, degrees)
            let (s, c) = CanvasObject.sinCos(degrees)
            object = doc.lineObject(from: p, to: CGPoint(x: p.x + width * c, y: p.y - width * s))
        default:
            break
        }
        if let object { doc.add(object) }
        close()
    }
}

/// A number typed as text (read on every key, so Return's OK sees what was typed; a comma works as the decimal point too),
/// with the arrows.
private struct NumberEntry: View {
    @Binding var value: Double
    let digits: Int
    let step: Double
    var width = 96.0
    var suffix = ""
    var always = false
    @State private var text = ""

    var body: some View {
        HStack(spacing: 6) {
            TextField("", text: $text)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: width)
                .stepperArrows($value, step: step, always: always)
            if !suffix.isEmpty { Text(verbatim: suffix).foregroundStyle(.secondary).fixedSize() }
        }
        .onAppear { text = format(value) }
        .onChange(of: text) { _, typed in
            if let v = StepperArrows.number(typed), v != value { value = v }
        }
        .onChange(of: value) { _, v in
            if StepperArrows.number(text) != v { text = format(v) }
        }
    }

    private func format(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...digits)).grouping(.never)) }
}
