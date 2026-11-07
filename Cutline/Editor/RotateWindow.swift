// Object › Transform › Rotate… (also the right click's Transform, a double click or ⌥-click on the Rotate tool): the
// angle, Preview, Copy and OK/Cancel, as Illustrator's Rotate window. It turns the selection around its center, or around
// the point the Rotate tool's ⌥-click chose. With Preview, the objects turn while the angle changes; Cancel puts them back;
// OK and Copy are one undo step each.
import SwiftUI

/// Opens the window when `Document.rotateRequest` is set (in the window's `.background`, like the Color Picker's sheet).
struct RotateSheet: ViewModifier {
    @Bindable var doc: Document

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { doc.rotateRequest }, set: { doc.rotateRequest = $0 })) { request in
            RotateWindow(doc: doc, request: request)
        }
    }
}

struct RotateWindow: View {
    @Bindable var doc: Document
    let request: RotateRequest
    @Environment(\.dismiss) private var dismiss

    /// The last angle used, for the next time (as Illustrator remembers it while the app is open).
    @MainActor private static var lastAngle = 0.0

    @State private var angle = RotateWindow.lastAngle
    /// The field's text (read on every key, so Return's OK sees what was typed; a comma works as the decimal point too).
    @State private var text = RotateWindow.format(RotateWindow.lastAngle)
    @State private var preview = false
    /// The objects as they were when the window opened (Preview turns copies of them; Cancel puts them back).
    @State private var originals: [CanvasObject] = []
    @State private var pivot = CGPoint.zero

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rotate").font(.headline)
            HStack(spacing: 10) {
                Text("Angle:")
                TextField("Angle", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 70)
                Text(verbatim: "°").foregroundStyle(.secondary)
                AngleDial(angle: $angle)
            }
            Toggle("Preview", isOn: $preview)
            HStack {
                Button("Copy") { finish(copy: true) }
                Spacer()
                Button("Cancel", role: .cancel) { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") { finish(copy: false) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 300)
        .onAppear {
            originals = doc.objects
            pivot = request.pivot ?? doc.selectionFrame?.center ?? .zero
            #if DEBUG
            DebugHooks.driveRotateWindow(angle: $angle, preview: $preview, copy: { finish(copy: true) }, ok: { finish(copy: false) },
                                         cancel: { cancel() })
            #endif
        }
        .onChange(of: text) { _, newOne in
            if let v = Self.parse(newOne), v != angle { angle = v }
        }
        .onChange(of: angle) { _, newOne in
            if Self.parse(text) != newOne { text = Self.format(newOne) }
            showPreview()
        }
        .onChange(of: preview) { _, _ in showPreview() }
    }

    static func format(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...2)).grouping(.never)) }

    /// The typed angle ("30", "-12,5", "−45°"); nil when it isn't a number.
    static func parse(_ typed: String) -> Double? {
        let clean = typed.replacingOccurrences(of: "°", with: "").replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        return Double(clean).flatMap { $0.isFinite ? $0 : nil }
    }

    /// The selection turned by the angle (without undo), or as it was.
    private func showPreview() {
        guard !originals.isEmpty else { return }
        var objects = originals
        if preview, angle.isFinite {
            for i in objects.indices where doc.selection.contains(objects[i].id) { objects[i].rotate(by: angle, around: pivot) }
        }
        doc.objects = objects
    }

    private func cancel() {
        if !originals.isEmpty { doc.objects = originals }
        doc.rotateRequest = nil
        dismiss()
    }

    /// OK turns the selection; Copy turns copies of it (and selects them). One undo step, from the objects before Preview.
    private func finish(copy: Bool) {
        if !originals.isEmpty { doc.objects = originals }
        let degrees = CanvasObject.normalizedAngle(Self.parse(text) ?? angle)
        Self.lastAngle = degrees
        doc.rotateSelection(by: degrees, around: pivot, copy: copy)
        doc.rotateRequest = nil
        dismiss()
    }
}

/// A small dial beside the angle, as Illustrator's: the line points at the angle (counterclockwise from the right);
/// dragging on it sets the angle (⇧: steps of 45°).
private struct AngleDial: View {
    @Binding var angle: Double
    private let side = 28.0

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2), r = size.width / 2 - 1.5
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(.secondary), lineWidth: 1)
            let (s, co) = CanvasObject.sinCos(angle.isFinite ? angle : 0)
            ctx.stroke(Path { $0.move(to: c); $0.addLine(to: CGPoint(x: c.x + co * r, y: c.y - s * r)) }, with: .color(.primary), lineWidth: 1.5)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)), with: .color(.primary))
        }
        .frame(width: side, height: side)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            let dx = value.location.x - side / 2, dy = side / 2 - value.location.y
            guard hypot(dx, dy) > 2 else { return }
            var a = atan2(dy, dx) * 180 / .pi
            a = NSEvent.modifierFlags.contains(.shift) ? (a / 45).rounded() * 45 : a.rounded()
            angle = CanvasObject.normalizedAngle(a)
        })
        .help("Drag to set the angle (⇧: steps of 45°)")
    }
}
