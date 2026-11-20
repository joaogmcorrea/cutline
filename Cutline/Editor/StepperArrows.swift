// The little up and down arrows of a number field, as Illustrator's: they show at the field's left while the pointer
// is over it (or always, like the Polygon window's Sides); each click adds or takes one step (⇧: ten), and holding
// the arrow repeats. Each click applies at once, like a value typed and confirmed (one undo step each).
import AppKit
import SwiftUI

extension View {
    /// `value`: the field's value, in the units it shows (its setter applies, as confirming the field does);
    /// `step`: what one click adds.
    func stepperArrows(_ value: Binding<Double>, step: Double = 1, always: Bool = false) -> some View {
        modifier(StepperArrows(value: value, step: step, always: always))
    }

    func stepperArrows(_ value: Binding<Int>, step: Int = 1, always: Bool = false) -> some View {
        stepperArrows(Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) }),
                      step: Double(step), always: always)
    }
}

struct StepperArrows: ViewModifier {
    let value: Binding<Double>
    let step: Double
    let always: Bool
    @State private var hovering = false
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .overlay(alignment: .leading) {
                if hovering || always || Self.testing {
                    VStack(spacing: 0) {
                        arrow(up: true)
                        arrow(up: false)
                    }
                    .padding(.leading, 1)
                }
            }
            .onHover { hovering = $0 }
    }

    private func arrow(up: Bool) -> some View {
        Button { nudge(up ? 1 : -1) } label: {
            Chevron(up: up)
                .stroke(style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                .frame(width: 6, height: 3)
                .frame(width: 11)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(ArrowStyle())
        .buttonRepeatBehavior(.enabled)
        .help(up ? "Increase (⇧: ×10)" : "Decrease (⇧: ×10)")
    }

    /// One step from what the field shows. While typing in this field: from what was typed. Any typing in the window
    /// ends first (what was typed is confirmed), so leaving the field later can't put the old text back.
    private func nudge(_ direction: Double) {
        var base = value.wrappedValue
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.firstResponder is NSTextView }),
           let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
            if focused, let typed = Self.number(editor.string) { base = typed }
            window.makeFirstResponder(nil)
        }
        let amount = NSEvent.modifierFlags.contains(.shift) ? step * 10 : step
        // Rounded to a millionth: 0.1 + 0.2 shows as 0.3, not 0.30000000000000004.
        value.wrappedValue = ((base + direction * amount) * 1e6).rounded() / 1e6
    }

    #if DEBUG
    private static var testing: Bool { DebugHooks.showAllArrows }
    #else
    private static let testing = false
    #endif

    /// A typed number in this Mac's format ("53,29" in Brazil), or with a point; nil when it isn't one.
    static func number(_ typed: String) -> Double? {
        let clean = typed.replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "°", with: "")
            .replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        if let v = try? Double(clean, format: .number), v.isFinite { return v }
        return Double(clean.replacingOccurrences(of: ",", with: ".")).flatMap { $0.isFinite ? $0 : nil }
    }
}

/// ⌃ or ⌄, drawn (the icons are Tabler's, and none is this small).
private nonisolated struct Chevron: Shape {
    let up: Bool

    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.minX, y: up ? r.maxY : r.minY))
            p.addLine(to: CGPoint(x: r.midX, y: up ? r.minY : r.maxY))
            p.addLine(to: CGPoint(x: r.maxX, y: up ? r.maxY : r.minY))
        }
    }
}

/// Gray, the pressed one in the text's color.
private struct ArrowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(configuration.isPressed ? Color.primary : Color.secondary)
    }
}
