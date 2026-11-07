// The Color Picker, like Illustrator's (double-click the fill or the stroke square at the foot of the tools or in the
// Color panel): the big field and the vertical strip, the new color over the current one, H S B and R G B (each with the
// radio button that picks the strip's axis), hex and C M Y K, Only Web Colors, the eyedropper (the system's loupe, from
// anywhere on the screen), OK, Cancel and Color Swatches, which swaps the field for the swatches.
// The document keeps CMYK. RGB, HSB and hex are in the RGB working space and become CMYK through the document's
// conversion (`doc.colors`, Model/ColorConversion.swift): with U.S. Web Coated (SWOP) v2, #000000 is C75 M68 Y67 K90,
// as in Illustrator. Typing C, M, Y or K keeps those numbers.
import AppKit
import SwiftUI

extension Document {
    /// Double-click on a color square: the picker for it (Illustrator brings the square to the front on the first click).
    func openColorPicker(_ target: ColorPickerTarget) {
        if textEditing != nil { finishText() }
        colorPicker = ColorPickerRequest(target: target)
    }

    /// The color the picker starts from (nil = none: the current swatch shows the slash).
    func pickerColor(_ target: ColorPickerTarget) -> CMYK? {
        switch target {
        case .fill: color(.fill).color
        case .strokeColor: color(.strokeColor).color
        case .gradientStop(let i): currentGradient.stops.indices.contains(i) ? currentGradient.stops[i].color : nil
        }
    }

    /// OK: the new color goes to the target, in one undo step (and into the recent colors).
    func applyPickedColor(_ color: CMYK, to target: ColorPickerTarget) {
        switch target {
        case .fill: setColor(.fill, color)
        case .strokeColor: setColor(.strokeColor, color)
        case .gradientStop(let i):
            var g = currentGradient
            guard g.stops.indices.contains(i) else { return }
            g.stops[i].color = color
            changeGradient(to: g)
            remember(color)
        }
    }
}

/// The picker's state: the new color in CMYK (what OK applies) and in the RGB working space and HSB (what the field, the
/// strip and the fields show). Each change through RGB, HSB or hex converts to CMYK; typing CMYK converts back.
@Observable
final class ColorPickerModel {
    /// The strip's axis (the radio buttons), as in Illustrator and Photoshop: H (the field is S × B), S (H × B),
    /// B (H × S), R (B × G), G (B × R) and B (R × G).
    enum Axis: CaseIterable { case hue, saturation, brightness, red, green, blue }

    let colors: ColorConverter
    let current: CMYK?
    private(set) var cmyk: CMYK
    /// 0–1, in the RGB working space.
    private(set) var rgb: [Double]
    /// Hue 0–360°, saturation and brightness 0–1. Kept apart from `rgb`, so the hue doesn't jump on grays.
    private(set) var hsb: [Double]
    var axis = Axis.hue
    var webOnly = false {
        didSet { if webOnly != oldValue, webOnly { setRGB(rgb) } }
    }
    var showingSwatches = false

    init(colors: ColorConverter, current: CMYK?, start: CMYK) {
        self.colors = colors
        self.current = current
        cmyk = start
        rgb = colors.rgb(start)
        hsb = ColorConverter.hsb(fromRGB: colors.rgb(start))
    }

    // MARK: Changes

    /// Typed C, M, Y or K (or a swatch): the numbers stay as typed.
    func set(cmyk c: CMYK) {
        let clamp = { (v: Double) in min(max(v.rounded(), 0), 100) }
        let c = CMYK(c: clamp(c.c), m: clamp(c.m), y: clamp(c.y), k: clamp(c.k))
        if webOnly {
            setRGB(colors.rgb(c))
            return
        }
        cmyk = c
        rgb = colors.rgb(c)
        hsb = keepingHue(ColorConverter.hsb(fromRGB: rgb))
    }

    func setRGB(_ v: [Double]) {
        var v = v.map { min(max($0, 0), 1) }
        if webOnly { v = v.map(Self.web) }
        rgb = v
        hsb = keepingHue(ColorConverter.hsb(fromRGB: v))
        cmyk = colors.cmyk(red: v[0], green: v[1], blue: v[2])
    }

    func setHSB(_ v: [Double]) {
        let h = min(max(v[0], 0), 360), s = min(max(v[1], 0), 1), b = min(max(v[2], 0), 1)
        if webOnly { return setRGB(ColorConverter.rgb(fromHSB: [h, s, b])) }
        hsb = [h, s, b]
        rgb = ColorConverter.rgb(fromHSB: hsb)
        cmyk = colors.cmyk(red: rgb[0], green: rgb[1], blue: rgb[2])
    }

    /// "RRGGBB" (or "#RGB"); false when it isn't a color.
    @discardableResult func set(hex text: String) -> Bool {
        var h = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return false }
        setRGB([Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255])
        return true
    }

    /// The current color swatch was clicked: back to it.
    func revert() {
        if let current { set(cmyk: current) }
    }

    /// Gray and black have no hue (and black no saturation): the ones before stay, as in Illustrator.
    private func keepingHue(_ v: [Double]) -> [Double] {
        var v = v
        if v[1] == 0 || v[2] == 0 { v[0] = hsb[0] }
        if v[2] == 0 { v[1] = hsb[1] }
        return v
    }

    /// Only Web Colors: each channel at a multiple of 0x33.
    static func web(_ v: Double) -> Double { (v * 5).rounded() / 5 }

    // MARK: The field and the strip

    /// Where the field's cursor is (x, y; 0–1, y up) and the strip's value (0–1, up), for the axis.
    var fieldPoint: CGPoint {
        switch axis {
        case .hue: CGPoint(x: hsb[1], y: hsb[2])
        case .saturation: CGPoint(x: hsb[0] / 360, y: hsb[2])
        case .brightness: CGPoint(x: hsb[0] / 360, y: hsb[1])
        case .red: CGPoint(x: rgb[2], y: rgb[1])
        case .green: CGPoint(x: rgb[2], y: rgb[0])
        case .blue: CGPoint(x: rgb[0], y: rgb[1])
        }
    }

    var stripValue: Double {
        switch axis {
        case .hue: hsb[0] / 360
        case .saturation: hsb[1]
        case .brightness: hsb[2]
        case .red: rgb[0]
        case .green: rgb[1]
        case .blue: rgb[2]
        }
    }

    func setField(_ p: CGPoint) {
        let x = min(max(p.x, 0), 1), y = min(max(p.y, 0), 1)
        switch axis {
        case .hue: setHSB([hsb[0], x, y])
        case .saturation: setHSB([x * 360, hsb[1], y])
        case .brightness: setHSB([x * 360, y, hsb[2]])
        case .red: setRGB([rgb[0], y, x])
        case .green: setRGB([y, rgb[1], x])
        case .blue: setRGB([x, y, rgb[2]])
        }
    }

    func setStrip(_ t: Double) {
        let t = min(max(t, 0), 1)
        switch axis {
        case .hue: setHSB([t * 360, hsb[1], hsb[2]])
        case .saturation: setHSB([hsb[0], t, hsb[2]])
        case .brightness: setHSB([hsb[0], hsb[1], t])
        case .red: setRGB([t, rgb[1], rgb[2]])
        case .green: setRGB([rgb[0], t, rgb[2]])
        case .blue: setRGB([rgb[0], rgb[1], t])
        }
    }

    /// The working-space RGB of a field point, with the strip where it is.
    private func fieldColor(_ x: Double, _ y: Double) -> [Double] {
        switch axis {
        case .hue: ColorConverter.rgb(fromHSB: [hsb[0], x, y])
        case .saturation: ColorConverter.rgb(fromHSB: [x * 360, hsb[1], y])
        case .brightness: ColorConverter.rgb(fromHSB: [x * 360, y, hsb[2]])
        case .red: [rgb[0], y, x]
        case .green: [y, rgb[1], x]
        case .blue: [x, y, rgb[2]]
        }
    }

    /// The working-space RGB of a strip value (the hue strip shows the pure hues, as in Illustrator).
    private func stripColor(_ t: Double) -> [Double] {
        switch axis {
        case .hue: ColorConverter.rgb(fromHSB: [t * 360, 1, 1])
        case .saturation: ColorConverter.rgb(fromHSB: [hsb[0], t, hsb[2]])
        case .brightness: ColorConverter.rgb(fromHSB: [hsb[0], hsb[1], t])
        case .red: [t, rgb[1], rgb[2]]
        case .green: [rgb[0], t, rgb[2]]
        case .blue: [rgb[0], rgb[1], t]
        }
    }

    @ObservationIgnored private var cachedField: (key: [Double], image: CGImage)?
    @ObservationIgnored private var cachedStrip: (key: [Double], image: CGImage)?

    /// The field: only the strip's value (and the axis) changes it.
    var fieldImage: CGImage? {
        let key = [Double(Axis.allCases.firstIndex(of: axis)!), stripValue, webOnly ? 1 : 0]
        if let cachedField, cachedField.key == key { return cachedField.image }
        let image = picture(width: Self.fieldSide, height: Self.fieldSide) { x, y in fieldColor(x, y) }
        if let image { cachedField = (key, image) }
        return image
    }

    /// The strip: the field's point (and the axis) changes it, except on the hue strip.
    var stripImage: CGImage? {
        let p = axis == .hue ? .zero : fieldPoint
        let key = [Double(Axis.allCases.firstIndex(of: axis)!), p.x, p.y, webOnly ? 1 : 0]
        if let cachedStrip, cachedStrip.key == key { return cachedStrip.image }
        let image = picture(width: 1, height: Self.fieldSide) { _, y in stripColor(y) }
        if let image { cachedStrip = (key, image) }
        return image
    }

    static let fieldSide = 256

    /// A bitmap in the RGB working space (x 0–1 left to right, y 0–1 bottom to top).
    private func picture(width: Int, height: Int, color: (Double, Double) -> [Double]) -> CGImage? {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0..<height {
            let y = 1 - (Double(row) + 0.5) / Double(height)
            for column in 0..<width {
                let x = width == 1 ? 0 : (Double(column) + 0.5) / Double(width)
                var v = color(x, y)
                if webOnly { v = v.map(Self.web) }
                let i = (row * width + column) * 4
                bytes[i] = UInt8((min(max(v[0], 0), 1) * 255).rounded())
                bytes[i + 1] = UInt8((min(max(v[1], 0), 1) * 255).rounded())
                bytes[i + 2] = UInt8((min(max(v[2], 0), 1) * 255).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: colors.rgbSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: What the fields show

    var hueText: Int { Int(hsb[0].rounded()) }
    var saturationText: Int { Int((hsb[1] * 100).rounded()) }
    var brightnessText: Int { Int((hsb[2] * 100).rounded()) }
    var rgbText: [Int] { rgb.map { Int(($0 * 255).rounded()) } }
    var hexText: String { rgbText.map { String(format: "%02X", $0) }.joined() }

    /// For the test log.
    var summary: String {
        "H\(hueText) S\(saturationText) B\(brightnessText) R\(rgbText[0]) G\(rgbText[1]) B\(rgbText[2]) #\(hexText) "
            + "C\(Int(cmyk.c)) M\(Int(cmyk.m)) Y\(Int(cmyk.y)) K\(Int(cmyk.k))"
    }
}

/// The sheet, on the document's window.
struct ColorPickerSheet: ViewModifier {
    @Bindable var doc: Document

    func body(content: Content) -> some View {
        content.sheet(item: $doc.colorPicker) { request in ColorPickerView(doc: doc, request: request) }
    }
}

struct ColorPickerView: View {
    let doc: Document
    let request: ColorPickerRequest
    @State private var model: ColorPickerModel
    @Environment(\.dismiss) private var dismiss

    init(doc: Document, request: ColorPickerRequest) {
        self.doc = doc
        self.request = request
        let current = doc.pickerColor(request.target)
        // None: the picker starts from white (a fill) or the cut red (a stroke).
        let start = current ?? (request.target == .strokeColor ? .red : CMYK(c: 0, m: 0, y: 0, k: 0))
        _model = State(initialValue: ColorPickerModel(colors: doc.colors, current: current, start: start))
    }

    private static let side = Double(ColorPickerModel.fieldSide)

    var body: some View {
        VStack(spacing: 14) {
            Text("Color Picker")
                .font(.headline)
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Select Color:")
                        Spacer()
                        Button(action: sample) {
                            Image("toolEyedropper").resizable().frame(width: 18, height: 18)
                        }
                        .buttonStyle(.borderless)
                        .help("Pick a color from anywhere on the screen")
                    }
                    if model.showingSwatches {
                        swatches
                    } else {
                        HStack(spacing: 12) {
                            field
                            strip
                        }
                    }
                    Toggle("Only Web Colors", isOn: $model.webOnly)
                }
                .frame(width: Self.side + 44)
                VStack(alignment: .leading, spacing: 10) {
                    newAndCurrent
                    numbers
                }
                VStack(spacing: 10) {
                    Button { ok() } label: { Text("OK").frame(maxWidth: .infinity) }
                        .keyboardShortcut(.defaultAction)
                    Button { dismiss() } label: { Text("Cancel").frame(maxWidth: .infinity) }
                        .keyboardShortcut(.cancelAction)
                    Button { model.showingSwatches.toggle() } label: {
                        Text(model.showingSwatches ? "Color Models" : "Color Swatches").frame(maxWidth: .infinity)
                    }
                }
                .controlSize(.large)
                .frame(width: 130)
            }
        }
        .padding(20)
        .fixedSize()
        #if DEBUG
        .task { await DebugHooks.drivePicker(model, ok: ok) }
        #endif
    }

    private func ok() {
        doc.applyPickedColor(model.cmyk, to: request.target)
        dismiss()
    }

    /// The system's loupe: a color from anywhere on the screen, in the working space.
    private func sample() {
        NSColorSampler().show { color in
            guard let color, let rgb = model.colors.workingRGB(color.cgColor) else { return }
            model.setRGB(rgb)
        }
    }

    // MARK: Field and strip

    private var field: some View {
        let p = model.fieldPoint
        return ZStack(alignment: .topLeading) {
            if let image = model.fieldImage {
                Image(decorative: image, scale: 1).resizable().interpolation(.high)
            }
            Circle()
                .strokeBorder(p.y > 0.55 && model.rgb.reduce(0, +) > 1.6 ? Color.black : Color.white, lineWidth: 1.5)
                .frame(width: 11, height: 11)
                .offset(x: p.x * Self.side - 5.5, y: (1 - p.y) * Self.side - 5.5)
        }
        .frame(width: Self.side, height: Self.side)
        .clipped()
        .overlay(Rectangle().strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            model.setField(CGPoint(x: g.location.x / Self.side, y: 1 - g.location.y / Self.side))
        })
    }

    private var strip: some View {
        let y = (1 - model.stripValue) * Self.side
        return ZStack(alignment: .topLeading) {
            Group {
                if let image = model.stripImage {
                    Image(decorative: image, scale: 1).resizable().interpolation(.high)
                }
            }
            .frame(width: 20, height: Self.side)
            .overlay(Rectangle().strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
            .offset(x: 7)
            // The two arrows on the sides, as in Illustrator.
            Arrow().fill(.secondary).frame(width: 7, height: 10).offset(x: 0, y: y - 5)
            Arrow().fill(.secondary).frame(width: 7, height: 10).scaleEffect(x: -1).offset(x: 27, y: y - 5)
        }
        .frame(width: 34, height: Self.side, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in model.setStrip(1 - g.location.y / Self.side) })
    }

    /// The swatches in place of the field (Color Swatches): the recent colors, then the palette.
    private var swatches: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(20), spacing: 4), count: 12), spacing: 4) {
                ForEach(Array((doc.recent + CMYK.swatches).enumerated()), id: \.offset) { _, color in
                    Swatch(color: color, shown: model.colors.color(color), chosen: color == model.cmyk) { model.set(cmyk: color) }
                }
            }
            .padding(2)
        }
        .frame(width: Self.side + 34, height: Self.side)
    }

    // MARK: Colors and numbers

    /// The new color on top, the current one below (clicking it goes back to it).
    private var newAndCurrent: some View {
        VStack(spacing: 0) {
            Rectangle().fill(model.colors.color(model.cmyk))
                .help("New color")
            Group {
                if let current = model.current {
                    Rectangle().fill(model.colors.color(current))
                } else {
                    NoneOption().background(.white)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { model.revert() }
            .help("Current color (click to go back to it)")
        }
        .frame(width: 70, height: 76)
        .overlay(Rectangle().strokeBorder(.black.opacity(0.3), lineWidth: 0.5))
    }

    private var numbers: some View {
        Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
            row(.hue, "H:", model.hueText, 360, "°") { model.setHSB([Double($0), model.hsb[1], model.hsb[2]]) }
            row(.saturation, "S:", model.saturationText, 100, "%") { model.setHSB([model.hsb[0], Double($0) / 100, model.hsb[2]]) }
            row(.brightness, "B:", model.brightnessText, 100, "%") { model.setHSB([model.hsb[0], model.hsb[1], Double($0) / 100]) }
            row(.red, "R:", model.rgbText[0], 255, "", ink: ("C:", \.c))
            row(.green, "G:", model.rgbText[1], 255, "", ink: ("M:", \.m))
            row(.blue, "B:", model.rgbText[2], 255, "", ink: ("Y:", \.y))
            GridRow {
                Color.clear.frame(width: 14, height: 1)
                Text(verbatim: "#").foregroundStyle(.secondary)
                HexText(value: model.hexText) { model.set(hex: $0) }
                Text(verbatim: "")
                Text(verbatim: "K:")
                inkField(\.k)
                Text(verbatim: "%").foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ axis: ColorPickerModel.Axis, _ label: String, _ value: Int, _ maximum: Int, _ unit: String,
                     ink: (String, WritableKeyPath<CMYK, Double>)? = nil, set: ((Int) -> Void)? = nil) -> some View {
        GridRow {
            RadioDot(on: model.axis == axis) { model.axis = axis }
            Text(verbatim: label)
            NumberField(value: value, maximum: maximum) { v in
                if let set {
                    set(v)
                } else {
                    var rgb = model.rgb
                    rgb[axis == .red ? 0 : axis == .green ? 1 : 2] = Double(v) / 255
                    model.setRGB(rgb)
                }
            }
            Text(verbatim: unit).foregroundStyle(.secondary).frame(width: 12, alignment: .leading)
            if let ink {
                Text(verbatim: ink.0)
                inkField(ink.1)
                Text(verbatim: "%").foregroundStyle(.secondary)
            } else {
                Color.clear.gridCellColumns(3).frame(height: 1)
            }
        }
    }

    private func inkField(_ key: WritableKeyPath<CMYK, Double>) -> some View {
        NumberField(value: Int(model.cmyk[keyPath: key].rounded()), maximum: 100) { v in
            var c = model.cmyk
            c[keyPath: key] = Double(v)
            model.set(cmyk: c)
        }
    }
}

/// A number field that applies on Enter or when it loses focus (out of range goes to the limit).
private struct NumberField: View {
    let value: Int
    let maximum: Int
    let apply: (Int) -> Void

    var body: some View {
        TextField("", value: Binding(get: { value }, set: { v in
            let v = min(max(v, 0), maximum)
            if v != value { apply(v) }
        }), format: .number)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()
            .frame(width: 58)
    }
}

/// The hex field: applies on Enter; text that isn't a color goes back.
private struct HexText: View {
    let value: String
    let apply: (String) -> Bool
    @State private var text = ""

    var body: some View {
        TextField("", text: $text)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()
            .frame(width: 58)
            .onAppear { text = value }
            .onChange(of: value) { _, updated in text = updated }
            .onSubmit { if !apply(text) { text = value } }
    }
}

/// Illustrator's round radio button.
private struct RadioDot: View {
    let on: Bool
    let choose: () -> Void

    var body: some View {
        ZStack {
            Circle().strokeBorder(.secondary, lineWidth: 1)
            if on { Circle().fill(.primary).padding(4) }
        }
        .frame(width: 14, height: 14)
        .contentShape(Circle())
        .onTapGesture(perform: choose)
        .help("Use this axis for the strip")
    }
}

/// The strip's arrow, pointing right.
nonisolated private struct Arrow: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
        }
    }
}
