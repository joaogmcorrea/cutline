// Gradient panel, like Illustrator's: the swatch (click applies the gradient to the selection's fill), Linear or Radial,
// the angle, reverse, and the gradient bar with its stops (click the bar adds one, drag moves it, drag it off the bar
// or the trash deletes it, double-click opens the Color Picker), the selected stop's location and color. The gradient
// only prints: the cut is still the stroke. Drawing is in Printing.swift (`GradientFill.draw`); the model in
// Model/Document.swift (`GradientFill`).
import SwiftUI

extension Document {
    /// The gradient the panel shows: the first selected object's, or the one Apply would use.
    var currentGradient: GradientFill {
        selectedObjects.first { $0.gradient != nil && $0.fill != nil }?.gradient ?? lastGradient
    }

    /// Some selected object has a gradient fill (the panel edits it).
    var selectionHasGradient: Bool { selectedObjects.contains { $0.gradient != nil && $0.fill != nil } }

    /// The fill squares show this gradient: every selected object has the same one.
    var shownGradient: GradientFill? {
        guard let first = selectedObjects.first?.gradient, selectedObjects.allSatisfy({ $0.gradient == first && $0.fill != nil })
        else { return nil }
        return first
    }

    /// Apply (the swatch, or the gradient button at the foot of the tools): the panel's gradient becomes the fill of the
    /// selected objects, in one undo step.
    func applyGradient() {
        colorTarget = .fill
        guard !selection.isEmpty else { return }
        if textEditing != nil { finishText() }
        let g = currentGradient
        lastGradient = g
        guard selectedObjects.contains(where: { $0.gradient != g || $0.fill == nil }) else { return }
        modifySelection { $0.setGradient(g) }
    }

    /// Back to a solid fill (the gradient's first color).
    func removeGradient() {
        guard selectionHasGradient else { return }
        modifySelection { $0.gradient = nil }
    }

    /// The panel's change: to the selected objects that have a gradient (`final` = one undo step; while dragging, the steps
    /// merge into one) or, without them, to the next one Apply uses.
    func changeGradient(to updated: GradientFill, final: Bool = true) {
        let g = updated.sorted
        lastGradient = g
        let targets = Set(selectedObjects.filter { $0.gradient != nil && $0.fill != nil }.map(\.id))
        guard !targets.isEmpty, selectedObjects.contains(where: { targets.contains($0.id) && $0.gradient != g }) else { return }
        if final { registrar() } else { registerAdjustment("gradient") }
        for i in objects.indices where targets.contains(objects[i].id) { objects[i].setGradient(g) }
    }
}

extension GradientFill {
    /// Where stop `i` lands once the stops are put in order (a dragged stop can pass another).
    func sortedIndex(of i: Int) -> Int {
        let order = stops.indices.sorted { a, b in
            stops[a].location != stops[b].location ? stops[a].location < stops[b].location : a < b
        }
        return order.firstIndex(of: i) ?? i
    }

    /// The colors as the canvas shows them, for SwiftUI (33 samples mixed in CMYK).
    func shown(_ colors: ColorConverter) -> Gradient {
        Gradient(stops: (0...32).map { n in
            let t = Double(n) / 32, c = color(at: t)
            return .init(color: colors.color(CMYK(c: c.c.rounded(), m: c.m.rounded(), y: c.y.rounded(), k: c.k.rounded())), location: t)
        })
    }
}

/// A gradient in a shape, as it is (linear at its angle, or radial).
struct GradientSwatch<S: Shape>: View {
    let gradient: GradientFill
    let colors: ColorConverter
    let shape: S

    var body: some View {
        let shown = gradient.shown(colors)
        Group {
            switch gradient.kind {
            case .linear:
                let a = gradient.angle * .pi / 180
                shape.fill(LinearGradient(gradient: shown, startPoint: UnitPoint(x: 0.5 - cos(a) / 2, y: 0.5 + sin(a) / 2),
                                          endPoint: UnitPoint(x: 0.5 + cos(a) / 2, y: 0.5 - sin(a) / 2)))
            case .radial:
                GeometryReader { geo in
                    shape.fill(RadialGradient(gradient: shown, center: .center, startRadius: 0,
                                              endRadius: max(geo.size.width, geo.size.height) / 2))
                }
            }
        }
    }
}

struct GradientSection: View {
    @Bindable var doc: Document
    @State private var selectedStop = 0
    /// The gradient and the stop when a drag started (the drag moves from there).
    @State private var dragging: (gradient: GradientFill, index: Int)?

    private static let barHeight = 20.0

    var body: some View {
        let g = doc.currentGradient
        let colors = doc.colors
        let stop = min(selectedStop, g.stops.count - 1)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Button { doc.applyGradient() } label: {
                    GradientSwatch(gradient: g, colors: colors, shape: RoundedRectangle(cornerRadius: 6))
                        .frame(width: 46, height: 46)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.black.opacity(0.22), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .disabled(doc.selection.isEmpty)
                .help("Apply the gradient to the selection’s fill")
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Type", selection: Binding(get: { g.kind }, set: { kind in
                        var updated = g
                        updated.kind = kind
                        doc.changeGradient(to: updated)
                    })) {
                        Text("Linear").tag(GradientKind.linear)
                        Text("Radial").tag(GradientKind.radial)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    HStack(spacing: 6) {
                        Text("Angle").foregroundStyle(.secondary)
                        TextField("Angle", value: Binding(get: { Int(g.angle.rounded()) }, set: { v in
                            // −180 to 180, as in Illustrator.
                            var a = Double(v).truncatingRemainder(dividingBy: 360)
                            if a > 180 { a -= 360 } else if a < -180 { a += 360 }
                            guard a != g.angle else { return }
                            var updated = g
                            updated.angle = a
                            doc.changeGradient(to: updated)
                        }), format: .number)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 48)
                            .disabled(g.kind == .radial)
                        Text(verbatim: "°").foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("Reverse Gradient", image: .swap) {
                            var updated = g
                            updated.stops = g.stops.reversed().map { GradientStop(color: $0.color, location: 1 - $0.location) }
                            doc.changeGradient(to: updated)
                            selectedStop = g.stops.count - 1 - stop
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Reverse Gradient")
                    }
                }
            }
            bar(g, colors, stop: stop)
            HStack(spacing: 6) {
                Button { doc.openColorPicker(.gradientStop(stop)) } label: {
                    RoundedRectangle(cornerRadius: 4).fill(colors.color(g.stops[stop].color))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("The stop’s color: click for the Color Picker")
                let c = g.stops[stop].color
                Text(verbatim: "C\(Int(c.c)) M\(Int(c.m)) Y\(Int(c.y)) K\(Int(c.k))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("Location").foregroundStyle(.secondary)
                TextField("Location", value: Binding(get: { Int((g.stops[stop].location * 100).rounded()) }, set: { v in
                    var updated = g
                    updated.stops[stop].location = Double(min(max(v, 0), 100)) / 100
                    guard updated != g else { return }
                    selectedStop = updated.sortedIndex(of: stop)
                    doc.changeGradient(to: updated)
                }), format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 44)
                Text(verbatim: "%").foregroundStyle(.secondary)
                Button("Delete Stop", image: .trash) { delete(stop, from: g) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(g.stops.count <= 2)
                    .help("Delete Stop")
            }
            Text(doc.selectionHasGradient
                 ? "Click the bar to add a stop, drag a stop off it to delete it, double-click a stop for the Color Picker. The gradient only prints: the stroke is still the cut."
                 : "The selection has no gradient: click the swatch to fill it with this one.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if doc.selectionHasGradient {
                Button("Solid Fill") { doc.removeGradient() }
                    .controlSize(.small)
                    .help("Back to a solid fill, with the gradient’s first color")
            }
        }
        .onChange(of: doc.selection) { _, _ in selectedStop = 0 }
    }

    /// The bar with the gradient and, below it, the stops.
    private func bar(_ g: GradientFill, _ colors: ColorConverter, stop: Int) -> some View {
        GeometryReader { geo in
            let width = max(geo.size.width - 12, 1)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(gradient: g.shown(colors), startPoint: .leading, endPoint: .trailing))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.black.opacity(0.2), lineWidth: 0.5))
                    .frame(width: width, height: Self.barHeight)
                    .offset(x: 6)
                    .contentShape(Rectangle())
                    .onTapGesture { p in add(at: (p.x - 6) / width, to: g) }
                    .help("Click to add a stop")
                ForEach(Array(g.stops.enumerated()), id: \.offset) { i, s in
                    StopMarker(color: colors.color(s.color), selected: i == stop)
                        .offset(x: s.location * width, y: Self.barHeight + 2)
                        .onTapGesture { selectedStop = i }
                        .simultaneousGesture(TapGesture(count: 2).onEnded { doc.openColorPicker(.gradientStop(i)) })
                        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("gradientBar"))
                            .onChanged { d in drag(i, d, width: width, from: g) }
                            .onEnded { d in endDrag(d, width: width) })
                }
            }
            .coordinateSpace(.named("gradientBar"))
        }
        .frame(height: Self.barHeight + 16)
    }

    private func add(at t: Double, to g: GradientFill) {
        let t = min(max(t, 0), 1)
        let c = g.color(at: t)
        var updated = g
        updated.stops.append(GradientStop(color: CMYK(c: c.c.rounded(), m: c.m.rounded(), y: c.y.rounded(), k: c.k.rounded()), location: t))
        selectedStop = updated.sortedIndex(of: updated.stops.count - 1)
        doc.changeGradient(to: updated)
    }

    private func delete(_ i: Int, from g: GradientFill) {
        guard g.stops.count > 2 else { return }
        var updated = g
        updated.stops.remove(at: i)
        selectedStop = max(0, min(i, updated.stops.count - 1) - (i == updated.stops.count ? 1 : 0))
        doc.changeGradient(to: updated)
    }

    private func drag(_ i: Int, _ d: DragGesture.Value, width: Double, from g: GradientFill) {
        if dragging == nil { dragging = (g, i) }
        guard let (start, index) = dragging else { return }
        var updated = start
        updated.stops[index].location = min(max((d.location.x - 6) / width, 0), 1)
        // Pulled down off the bar: it will be deleted (shown already gone, as in Illustrator), if more than two are left.
        if d.translation.height > 28, start.stops.count > 2 {
            updated.stops.remove(at: index)
            selectedStop = 0
        } else {
            selectedStop = updated.sortedIndex(of: index)
        }
        doc.changeGradient(to: updated, final: false)
    }

    private func endDrag(_ d: DragGesture.Value, width: Double) {
        dragging = nil
    }
}

/// A stop under the bar: a little house with the color, like Illustrator's.
private struct StopMarker: View {
    let color: Color
    let selected: Bool

    var body: some View {
        ZStack {
            House().fill(selected ? Color.accentColor : Color.secondary.opacity(0.6))
            House().inset(by: 2).fill(color)
        }
        .frame(width: 12, height: 14)
        .contentShape(Rectangle())
    }
}

nonisolated private struct House: InsettableShape {
    var amount = 0.0

    func path(in r: CGRect) -> Path {
        let r = r.insetBy(dx: amount, dy: amount)
        return Path { p in
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.35))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.35))
            p.closeSubpath()
        }
    }

    func inset(by amount: CGFloat) -> House { House(amount: self.amount + amount) }
}
