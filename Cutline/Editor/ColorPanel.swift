// Color section of the side panel (as in the prototype and in Illustrator): fill and stroke squares
// (X toggles, ⇧X swaps, D default, / none), CMYK/HSL/RGB channels with gradients, hex, quick colors,
// Studio swatches, spectrum and recent colors. Everything is stored as CMYK.
import SwiftUI

enum ColorMode: String, CaseIterable, Identifiable {
    case cmyk = "CMYK", hsl = "HSL", rgb = "RGB"
    var id: Self { self }
}

struct ColorSection: View {
    @Bindable var doc: Document
    let mode: ColorMode

    var body: some View {
        let target = doc.colorTarget
        let (current, mixed) = doc.color(target)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 6) {
                    ColorSquares(doc: doc)
                    HStack(spacing: 2) {
                        Button { doc.defaultColors() } label: { Image(.defaultColors).resizable().frame(width: 13, height: 13) }
                            .help("Default: no fill, red 0 pt stroke (D)")
                        Button { doc.swapColors() } label: { Image(.swapColors).resizable().frame(width: 13, height: 13) }
                            .help("Swap fill and stroke (⇧X)")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
                .frame(width: 46)
                ColorChannels(doc: doc, mode: mode, base: current ?? CMYK(c: 0, m: 0, y: 0, k: 0))
                    .disabled(current == nil)
                    .opacity(current == nil ? 0.4 : 1)
            }

            HStack(spacing: 6) {
                Text("#").foregroundStyle(.secondary)
                HexField(value: current?.hex ?? "") { color in doc.setColor(target, color) }
                Group {
                    if mixed {
                        Text("mixed colors")
                    } else if let current {
                        Text(verbatim: "C\(Int(current.c)) M\(Int(current.m)) Y\(Int(current.y)) K\(Int(current.k))")
                    } else {
                        Text("none")
                    }
                }
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 4) {
                ColorButton(color: nil, chosen: current == nil && !mixed, tip: String(localized: "None (/)")) { doc.setColor(target, nil) }
                ColorButton(color: CMYK(c: 0, m: 0, y: 0, k: 100), chosen: current == CMYK(c: 0, m: 0, y: 0, k: 100), tip: String(localized: "100% black")) {
                    doc.setColor(target, CMYK(c: 0, m: 0, y: 0, k: 100))
                }
                ColorButton(color: CMYK(c: 0, m: 0, y: 0, k: 0), chosen: current == CMYK(c: 0, m: 0, y: 0, k: 0), tip: String(localized: "White")) {
                    doc.setColor(target, CMYK(c: 0, m: 0, y: 0, k: 0))
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 12), spacing: 3) {
                ForEach(CMYK.swatches, id: \.self) { swatch in
                    Swatch(color: swatch, chosen: swatch == current) { doc.setColor(target, swatch) }
                }
            }

            Spectrum { color, final in doc.setColor(target, color, final: final) }
                .frame(height: 30)

            if !doc.recent.isEmpty {
                HStack(spacing: 3) {
                    ForEach(doc.recent, id: \.self) { color in
                        ColorButton(color: color, chosen: color == current, tip: color.summaryText) { doc.setColor(target, color) }
                    }
                }
            }

            Text(target == .strokeColor
                 ? "Colors are always CMYK. The stroke color sets the cut settings; with no stroke, the object isn’t cut."
                 : "Colors are always CMYK (RGB, HSL and hex convert on the fly). The fill is printed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Illustrator's two squares: fill behind, stroke (just the thick border) in front; clicking
/// brings one to the front. White with a red slash = none; "?" = mixed colors.
private struct ColorSquares: View {
    @Bindable var doc: Document

    var body: some View {
        let fill = doc.color(.fill), strokeColor = doc.color(.strokeColor)
        ZStack(alignment: .topLeading) {
            square(fill.color, mixed: fill.mixed, isStroke: false)
                .zIndex(doc.colorTarget == .fill ? 2 : 1)
            square(strokeColor.color, mixed: strokeColor.mixed, isStroke: true)
                .offset(x: 14, y: 14)
                .zIndex(doc.colorTarget == .strokeColor ? 2 : 1)
        }
        .frame(width: 44, height: 44, alignment: .topLeading)
    }

    private func square(_ color: CMYK?, mixed: Bool, isStroke: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        let isActive = doc.colorTarget == (isStroke ? .strokeColor : .fill)
        return ZStack {
            if let color, !mixed {
                if isStroke {
                    shape.fill(Color.white.opacity(0.001))
                    shape.strokeBorder(color.color, lineWidth: 6)
                } else {
                    shape.fill(color.color)
                }
            } else {
                shape.fill(.white)
                if mixed {
                    Text("?").font(.system(size: 13, weight: .bold)).foregroundStyle(.gray)
                } else {
                    NoneOption().clipShape(shape)
                }
            }
        }
        .frame(width: 28, height: 28)
        .overlay(shape.strokeBorder(.black.opacity(0.22), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 1.5, y: 1)
        .overlay(shape.inset(by: -3).stroke(Color.accentColor, lineWidth: isActive ? 2 : 0))
        .contentShape(shape)
        .onTapGesture { doc.colorTarget = isStroke ? .strokeColor : .fill }
        .help(isStroke ? "Stroke — cut color (X toggles)" : "Fill (X toggles)")
    }
}

/// Red diagonal slash: "none".
private struct NoneOption: View {
    var body: some View {
        Canvas { ctx, size in
            var slash = Path()
            slash.move(to: CGPoint(x: 0, y: size.height))
            slash.addLine(to: CGPoint(x: size.width, y: 0))
            ctx.stroke(slash, with: .color(Color(red: 1, green: 0.23, blue: 0.19)), lineWidth: max(2, size.width / 10))
        }
    }
}

/// Channels of the chosen mode: label, track with the channel's own gradient, editable value and unit.
private struct ColorChannels: View {
    @Bindable var doc: Document
    let mode: ColorMode
    let base: CMYK

    private struct Channel {
        let label: String
        let value: Int
        let maximum: Int
        let unit: String
        let colors: [Color]
        let apply: (Int) -> CMYK
    }

    private var channels: [Channel] {
        switch mode {
        case .cmyk:
            let fields: [(String, WritableKeyPath<CMYK, Double>)] = [("C", \.c), ("M", \.m), ("Y", \.y), ("K", \.k)]
            return fields.map { label, field in
                var of = base, until = base
                of[keyPath: field] = 0
                until[keyPath: field] = 100
                return Channel(label: label, value: Int(base[keyPath: field].rounded()), maximum: 100, unit: "%",
                             colors: [of.srgbColor, until.srgbColor]) { v in
                    var newOne = base
                    newOne[keyPath: field] = Double(v)
                    return newOne
                }
            }
        case .rgb:
            let rgb = base.rgb255
            return ["R", "G", "B"].enumerated().map { i, label in
                var of = rgb, until = rgb
                of[i] = 0
                until[i] = 255
                return Channel(label: label, value: rgb[i], maximum: 255, unit: "",
                             colors: [CMYK(rgb255: of).srgbColor, CMYK(rgb255: until).srgbColor]) { v in
                    var updated = rgb
                    updated[i] = v
                    return CMYK(rgb255: updated)
                }
            }
        case .hsl:
            let hsl = base.hsl
            let hues = stride(from: 0, through: 360, by: 60).map { CMYK(hsl: [$0, 100, 50]).srgbColor }
            let channel = { (i: Int, label: String, maximum: Int, unit: String, colors: [Color]) in
                Channel(label: label, value: hsl[i], maximum: maximum, unit: unit, colors: colors) { v in
                    var updated = hsl
                    updated[i] = v
                    return CMYK(hsl: updated)
                }
            }
            return [
                channel(0, "H", 360, "°", hues),
                channel(1, "S", 100, "%", [CMYK(hsl: [hsl[0], 0, hsl[2]]).srgbColor, CMYK(hsl: [hsl[0], 100, hsl[2]]).srgbColor]),
                channel(2, "L", 100, "%", [.black, CMYK(hsl: [hsl[0], hsl[1], 50]).srgbColor, .white]),
            ]
        }
    }

    var body: some View {
        VStack(spacing: 7) {
            ForEach(channels, id: \.label) { channel in
                HStack(spacing: 6) {
                    Text(channel.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 12, alignment: .leading)
                    ColorTrack(value: channel.value, maximum: channel.maximum, colors: channel.colors) { v, final in
                        doc.setColor(doc.colorTarget, channel.apply(v), final: final)
                    }
                    TextField(channel.label, value: Binding(get: { channel.value }, set: { updated in
                        let v = min(max(updated, 0), channel.maximum)
                        if v != channel.value { doc.setColor(doc.colorTarget, channel.apply(v)) }
                    }), format: .number)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 44)
                    Text(channel.unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 10, alignment: .leading)
                }
            }
        }
    }
}

/// Thin track with a gradient and a white knob: dragging or clicking picks the value.
private struct ColorTrack: View {
    let value: Int
    let maximum: Int
    let colors: [Color]
    /// (value, finished dragging)
    let change: (Int, Bool) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let x = Double(value) / Double(maximum) * width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .overlay(Capsule().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                    .frame(height: 6)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
                    .frame(width: 14, height: 14)
                    .offset(x: min(max(x - 7, -7), width - 7))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { change(valueAt($0.location.x, width), false) }
                .onEnded { change(valueAt($0.location.x, width), true) })
        }
        .frame(height: 16)
    }

    private func valueAt(_ x: Double, _ width: Double) -> Int {
        Int((min(max(x / width, 0), 1) * Double(maximum)).rounded())
    }
}

/// Hex field: applies on confirm; invalid text goes back to the current value.
private struct HexField: View {
    let value: String
    let apply: (CMYK) -> Void
    @State private var text = ""

    var body: some View {
        TextField("hex", text: $text)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()
            .frame(width: 76)
            .onAppear { text = value }
            .onChange(of: value) { _, updated in text = updated }
            .onSubmit {
                if let color = CMYK(hex: text), color.hex != value { apply(color) } else { text = value }
            }
    }
}

/// Small color square (quick and recent); no color = none.
private struct ColorButton: View {
    let color: CMYK?
    let chosen: Bool
    let tip: String
    let choose: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        Button(action: choose) {
            ZStack {
                if let color { shape.fill(color.color) } else { shape.fill(.white); NoneOption().clipShape(shape) }
            }
            .frame(width: 18, height: 18)
            .overlay(shape.strokeBorder(chosen ? Color.accentColor : .black.opacity(0.25), lineWidth: chosen ? 2 : 0.5))
        }
        .buttonStyle(.plain)
        .help(tip)
    }
}

struct Swatch: View {
    let color: CMYK
    let chosen: Bool
    let choose: () -> Void
    @State private var over = false

    var body: some View {
        Button(action: choose) {
            RoundedRectangle(cornerRadius: 4)
                .fill(color.color)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(chosen ? Color.accentColor : Color.black.opacity(0.18), lineWidth: chosen ? 2 : 0.5))
                .aspectRatio(1, contentMode: .fit)
                .scaleEffect(over ? 1.18 : 1)
                .animation(.snappy(duration: 0.12), value: over)
        }
        .buttonStyle(.plain)
        .onHover { over = $0 }
        .help(color.summaryText)
    }
}

/// Spectrum: hue horizontally; top to bottom, from white to the pure color to black.
private struct Spectrum: View {
    /// (color, finished dragging)
    let choose: (CMYK, Bool) -> Void

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Canvas { ctx, t in
                let rectangle = Path(CGRect(origin: .zero, size: t))
                let hues = stride(from: 0, through: 360, by: 30).map { CMYK(hsl: [$0, 100, 50]).srgbColor }
                ctx.fill(rectangle, with: .linearGradient(Gradient(colors: hues), startPoint: .zero, endPoint: CGPoint(x: t.width, y: 0)))
                ctx.fill(rectangle, with: .linearGradient(Gradient(stops: [
                    .init(color: .white, location: 0), .init(color: .white.opacity(0), location: 0.5),
                    .init(color: .black.opacity(0), location: 0.5), .init(color: .black, location: 1),
                ]), startPoint: .zero, endPoint: CGPoint(x: 0, y: t.height)))
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { choose(color(in: $0.location, size), false) }
                .onEnded { choose(color(in: $0.location, size), true) })
            .pointerStyle(.rectSelection)
        }
    }

    private func color(in p: CGPoint, _ t: CGSize) -> CMYK {
        let x = min(max(p.x / max(t.width, 1), 0), 1), y = min(max(p.y / max(t.height, 1), 0), 1)
        return CMYK(hsl: [Int((x * 360).rounded()) % 360, 100, Int(((1 - y) * 100).rounded())])
    }
}
