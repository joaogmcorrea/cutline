// Send window setting: compact horizontal slider (one row per setting), with the semantics of the
// approved dial — green track; a notch at the material's value; above it, a green → yellow
// → red gradient; the knob is the only glass piece. Adjust: drag, click the track, type the value,
// arrows (⇧ = 5), Home/End.
import SwiftUI

struct SettingsEditor<Icon: View>: View {
    let title: LocalizedStringKey
    let unit: LocalizedStringKey
    let span: ClosedRange<Int>
    @Binding var value: Int
    /// The chosen material's value.
    let defaultValue: Int
    @ViewBuilder let icon: () -> Icon

    @Environment(\.colorScheme) private var scheme
    @State private var dragging = false
    @State private var overPin = false
    @FocusState private var focused: Bool

    private let trackHeight = 6.0
    private let knob = 18.0

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                icon()
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                Text(title)
            }
            .frame(width: 104, alignment: .leading)

            track
                .frame(height: 26)

            TextField(title, value: Binding(get: { value }, set: { value = limit($0) }), format: .number)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 44)

            Text(unit)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)

            Button {
                value = defaultValue
            } label: {
                HStack(spacing: 4) {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                    Text("material \(defaultValue)").monospacedDigit()
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Back to the material’s value (\(defaultValue))")
            .opacity(value == defaultValue ? 0 : 1)
            .disabled(value == defaultValue)
            .frame(width: 86, alignment: .leading)
        }
        .font(.callout)
    }

    // MARK: Track

    private var track: some View {
        GeometryReader { geo in
            let width = geo.size.width - knob
            let x = { (v: Int) in knob / 2 + width * fraction(v) }
            ZStack(alignment: .leading) {
                Canvas { ctx, size in render(&ctx, size, x: x) }
                Circle()
                    .fill(.clear)
                    .frame(width: knob, height: knob)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
                    .background(Circle().fill(palette.halo).frame(width: 28, height: 28).opacity(dragging ? 1 : 0))
                    .scaleEffect(dragging ? 1.2 : (overPin ? 1.08 : 1))
                    .animation(.spring(duration: 0.18), value: dragging)
                    .animation(.spring(duration: 0.18), value: overPin)
                    .onHover { overPin = $0 }
                    .position(x: x(value), y: geo.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { dragGesture in
                        dragging = true
                        focused = true
                        value = value(in: dragGesture.location.x, width: width)
                    }
                    .onEnded { _ in dragging = false }
            )
            .pointerStyle(dragging ? .grabActive : .grabIdle)
        }
        .focusable(interactions: .edit)
        .focusEffectDisabled()
        .focused($focused)
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5).padding(-3).opacity(focused ? 1 : 0))
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .home, .end], phases: .down) { keyEvent in
            let step = keyEvent.modifiers.contains(.shift) ? 5 : 1
            switch keyEvent.key {
            case .rightArrow, .upArrow: value = limit(value + step)
            case .leftArrow, .downArrow: value = limit(value - step)
            case .home: value = span.lowerBound
            default: value = span.upperBound
            }
            return .handled
        }
        .help(Text(title) + Text(verbatim: ": \(span.lowerBound)–\(span.upperBound)"))
    }

    private func render(_ ctx: inout GraphicsContext, _ size: CGSize, x: (Int) -> Double) {
        let middle = size.height / 2
        let trackRange = { (of: Double, until: Double) in
            Path(roundedRect: CGRect(x: of, y: middle - trackHeight / 2, width: max(until - of, 0), height: trackHeight),
                 cornerRadius: trackHeight / 2)
        }
        let start = x(span.lowerBound) - trackHeight / 2, end = x(span.upperBound) + trackHeight / 2
        ctx.fill(trackRange(start, end), with: .color(palette.groove))

        let xValue = x(value), defaultX = x(defaultValue)
        if value > span.lowerBound {
            // green up to the default (or up to the value, if below it)
            let greenEnd = min(xValue, defaultX)
            let greenByDefault = RGB.mixSRGB(palette.weak, palette.value, fraction(min(value, defaultValue)))
            ctx.fill(trackRange(start, max(greenEnd, start + trackHeight)),
                     with: .linearGradient(Gradient(colors: [palette.weak.color, greenByDefault.color]),
                                           startPoint: CGPoint(x: start, y: middle), endPoint: CGPoint(x: greenEnd, y: middle)))
            // above the default: green → yellow → red (OKLab), full red at the value
            if value > defaultValue {
                let stops = (0...12).map { i -> Gradient.Stop in
                    let t = Double(i) / 12
                    let color = t < 0.5 ? RGB.mixOKLab(greenByDefault, palette.yellow, t / 0.5)
                                      : RGB.mixOKLab(palette.yellow, palette.above, (t - 0.5) / 0.5)
                    return Gradient.Stop(color: color.color, location: t)
                }
                ctx.fill(Path(CGRect(x: defaultX, y: middle - trackHeight / 2, width: xValue - defaultX, height: trackHeight)),
                         with: .linearGradient(Gradient(stops: stops), startPoint: CGPoint(x: defaultX, y: middle),
                                               endPoint: CGPoint(x: xValue, y: middle)))
            }
        }
        // Notch at the material's limit: always visible, a few points to the right of the knob when it is
        // at the material's value (marks where the excess starts).
        let notchX = defaultX + knob / 2 + 3
        var notch = Path()
        notch.move(to: CGPoint(x: notchX, y: middle - 7))
        notch.addLine(to: CGPoint(x: notchX, y: middle + 7))
        ctx.stroke(notch, with: .color(.primary.opacity(0.55)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
    }

    // MARK: Support

    private func fraction(_ v: Int) -> Double {
        Double(limit(v) - span.lowerBound) / Double(max(1, span.upperBound - span.lowerBound))
    }

    private func value(in x: Double, width: Double) -> Int {
        let fr = min(max((x - knob / 2) / max(width, 1), 0), 1)
        return span.lowerBound + Int((fr * Double(span.upperBound - span.lowerBound)).rounded())
    }

    private func limit(_ v: Int) -> Int { min(max(v, span.lowerBound), span.upperBound) }

    private var palette: SettingsPalette { scheme == .dark ? .darkShade : .light }
}

/// Setting colors (the system's green, yellow and red, light and dark).
private struct SettingsPalette {
    let value, weak, yellow, above: RGB
    let groove: Color
    let halo: Color

    static let light = SettingsPalette(value: RGB(0x34C759), weak: RGB(0xA3E6B4), yellow: RGB(0xFFCC00),
                                    above: RGB(0xFF3B30), groove: .black.opacity(0.09),
                                    halo: Color(red: 0.2, green: 0.78, blue: 0.35).opacity(0.2))
    static let darkShade = SettingsPalette(value: RGB(0x30D158), weak: RGB(0x86DFA0), yellow: RGB(0xFFD60A),
                                     above: RGB(0xFF453A), groove: .white.opacity(0.13),
                                     halo: Color(red: 0.19, green: 0.82, blue: 0.35).opacity(0.26))
}
