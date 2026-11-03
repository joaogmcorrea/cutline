// Stroke sections (Silhouette Studio style: solid or dashed; width; cap, join and
// alignment only for printed strokes) and the side panel's Pathfinder.
import SwiftUI

struct StrokeSection: View {
    @Bindable var doc: Document

    private var strokeWidth: Double { doc.selectedObjects.first?.strokeWidth ?? doc.defaultStrokeWidth }

    var body: some View {
        let style = doc.currentStyle
        VStack(alignment: .leading, spacing: 8) {
            line("Style") {
                Menu {
                    Picker("Style", selection: Binding(get: { style.line }, set: { newOne in doc.setStyle { $0.line = newOne } })) {
                        ForEach(LineStyle.allCases) { e in
                            Label { Text(e.name) } icon: { Image(nsImage: Icons.line(e)) }.tag(e)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Image(nsImage: Icons.line(style.line))
                }
                .menuIndicator(.visible)
                .fixedSize()
                .help(style.line == .solid ? "Solid" : "Dashed: the cut is perforated")
            }
            line("Weight") {
                HStack(spacing: 6) {
                    TextField("Weight", value: Binding(get: { strokeWidth }, set: { doc.setStrokeWidth($0) }),
                              format: .number.precision(.fractionLength(0...2)))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 56)
                    Text("pt").foregroundStyle(.secondary)
                }
            }
            Text(strokeWidth > 0 ? "This stroke will also be printed." : "0 pt shows on screen, doesn’t print and marks the cut.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 78)
                .fixedSize(horizontal: false, vertical: true)
            if strokeWidth > 0 {
                line("Cap") {
                    segments(LineCap.allCases, current: style.cap, icon: Icons.cap, tip: \.tip) { v in doc.setStyle { $0.cap = v } }
                }
                line("Corner") {
                    HStack(spacing: 6) {
                        segments(LineJoin.allCases, current: style.join, icon: Icons.join, tip: \.tip) { v in doc.setStyle { $0.join = v } }
                        Text("Limit").foregroundStyle(.secondary)
                        TextField("Miter limit", value: Binding(get: { style.miterLimit }, set: { updated in
                            let v = min(max(updated, 1), 500)
                            if v != style.miterLimit { doc.setStyle { $0.miterLimit = v } }
                        }), format: .number.precision(.fractionLength(0...1)))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 40)
                            .help("Miter limit")
                            .disabled(style.join != .sharp)
                    }
                }
                line("Align") {
                    segments(StrokeAlignment.allCases, current: style.alignment, icon: Icons.alignment, tip: \.tip) { v in
                        doc.setStyle { $0.alignment = v }
                    }
                }
            }
        }
    }

    private func line<Content: View>(_ label: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
    }

    private func segments<Value: Hashable & Identifiable>(_ values: [Value], current: Value, icon: @escaping (Value) -> NSImage,
                                                           tip: KeyPath<Value, String>, choose: @escaping @MainActor @Sendable (Value) -> Void) -> some View {
        Picker("", selection: Binding(get: { current }, set: choose)) {
            ForEach(values) { v in
                Image(nsImage: icon(v)).help(v[keyPath: tip]).tag(v)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

private extension LineCap {
    var tip: String {
        switch self {
        case .straight: String(localized: "Butt cap")
        case .rounded: String(localized: "Round cap")
        case .projected: String(localized: "Projecting cap")
        }
    }
}

private extension LineJoin {
    var tip: String {
        switch self {
        case .sharp: String(localized: "Miter join")
        case .round: String(localized: "Round join")
        case .bevel: String(localized: "Bevel join")
        }
    }
}

private extension StrokeAlignment {
    var tip: String {
        switch self {
        case .center: String(localized: "Align stroke to center")
        case .inside: String(localized: "Align stroke to inside")
        case .outside: String(localized: "Align stroke to outside")
        }
    }
}

struct PathfinderSection: View {
    @Bindable var doc: Document

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Shape modes:").font(.caption).foregroundStyle(.secondary)
            buttons(PathfinderOperation.allCases.filter(\.isShapeMode))
            Text("Pathfinders:").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            buttons(PathfinderOperation.allCases.filter { !$0.isShapeMode })
        }
    }

    private func buttons(_ operations: [PathfinderOperation]) -> some View {
        HStack(spacing: 6) {
            ForEach(operations) { op in
                Button {
                    if let notice = doc.pathfinder(op) { withAnimation(.snappy(duration: 0.2)) { doc.notice = notice } }
                } label: {
                    Image(nsImage: Icons.pathfinder(op))
                        .frame(width: 40, height: 32)
                        .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .help(op.name)
            }
        }
    }
}

/// Offset, as Silhouette Studio's panel: a new outline at a distance from the selected shapes, outside or inside, with
/// round or sharp corners (the originals stay; images are left out — offset their contour).
struct OffsetSection: View {
    @Bindable var doc: Document
    @AppStorage("offsetDistance") private var distance = 2.0
    @AppStorage("offsetInside") private var inside = false
    @AppStorage("offsetCorner") private var corner = OffsetCorner.round
    @AppStorage(LengthUnit.key) private var unit = LengthUnit.mm

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Side", selection: $inside) {
                Text("Outside").tag(false)
                Text("Inside").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(spacing: 6) {
                Text("Distance").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                TextField("Distance", value: Binding(get: { unit.show(distance) }, set: { distance = min(max(unit.mm($0), 0.05), 100) }),
                          format: .number.precision(.fractionLength(0...unit.fractionDigits)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                Text(verbatim: unit.symbol).foregroundStyle(.secondary)
                Stepper("", value: $distance, in: 0.05...100, step: 0.5)
                    .labelsHidden()
                    .controlSize(.mini)
            }
            HStack(spacing: 6) {
                Text("Corners").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Picker("Corners", selection: $corner) {
                    ForEach(OffsetCorner.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Button {
                if let notice = doc.offsetSelection(inside ? -distance : distance, corner: corner) {
                    withAnimation(.snappy(duration: 0.2)) { doc.notice = notice }
                }
            } label: {
                Text("Apply").frame(maxWidth: .infinity)
            }
            .disabled(doc.selection.isEmpty)
            Text("Makes a new cut line around the selected shapes (or inside them); the shapes stay.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .controlSize(.small)
    }
}
