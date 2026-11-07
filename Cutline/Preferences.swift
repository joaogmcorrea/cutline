// App settings (Cutline › Settings…, ⌘,): appearance, start screen, length unit, guide color, how far the arrows move, the
// color profiles (Editor/ColorProfileViews.swift), the Trace defaults, the preferred connection and the updates. Stored in UserDefaults; the document keeps everything in mm.
import Sparkle
import SwiftUI

/// The unit the interface shows lengths in (rulers, X/Y/W/H, margins…). Values are converted on the way in and out.
nonisolated enum LengthUnit: String, CaseIterable, Identifiable, Sendable {
    case mm, cm, inch = "in"

    static let key = "unit"

    var id: Self { self }

    /// How many mm one unit has.
    var mmPer: Double {
        switch self {
        case .mm: 1
        case .cm: 10
        case .inch: 25.4
        }
    }

    var symbol: String {
        switch self {
        case .mm: "mm"
        case .cm: "cm"
        case .inch: "in"
        }
    }

    var name: String {
        switch self {
        case .mm: String(localized: "Millimeters")
        case .cm: String(localized: "Centimeters")
        case .inch: String(localized: "Inches")
        }
    }

    /// Decimals shown: 0.01 mm, 0.001 cm and 0.001 in are about the same.
    var fractionDigits: Int { self == .mm ? 2 : 3 }

    func show(_ mm: Double) -> Double { mm / mmPer }
    func mm(_ value: Double) -> Double { value * mmPer }

    /// "12.5 mm", "1.25 cm", "0.492 in".
    func text(_ mm: Double) -> String {
        "\(show(mm).formatted(.number.precision(.fractionLength(0...fractionDigits)))) \(symbol)"
    }

    /// "210 × 297 mm".
    func text(_ size: CGSize) -> String {
        let number = { (v: Double) in self.show(v).formatted(.number.precision(.fractionLength(0...self.fractionDigits))) }
        return "\(number(size.width)) × \(number(size.height)) \(symbol)"
    }

    /// The one chosen in Settings (for code outside the views).
    static var current: LengthUnit { UserDefaults.standard.string(forKey: key).flatMap(LengthUnit.init(rawValue:)) ?? .mm }
}

/// Light or dark, or as the system (the canvas, panels and windows follow it).
nonisolated enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case automatic, light, dark

    static let key = "appearance"

    var id: Self { self }

    var name: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }

    @MainActor func apply() {
        NSApplication.shared.appearance = switch self {
        case .automatic: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    static var current: AppAppearance { UserDefaults.standard.string(forKey: key).flatMap(AppAppearance.init(rawValue:)) ?? .automatic }
}

/// Which connection is tried first when the machine is on both.
nonisolated enum PreferredConnection: String, CaseIterable, Identifiable, Sendable {
    case usb, bluetooth

    static let key = "preferredConnection"

    var id: Self { self }

    var name: String {
        switch self {
        case .usb: String(localized: "USB cable")
        case .bluetooth: String(localized: "Bluetooth")
        }
    }

    static var current: PreferredConnection {
        UserDefaults.standard.string(forKey: key).flatMap(PreferredConnection.init(rawValue:)) ?? .usb
    }
}

/// The other settings: keys and defaults.
nonisolated enum Preferences {
    static let guideColor = "guideColor", arrowStep = "arrowStep", arrowStepShift = "arrowStepShift", arrowStepOption = "arrowStepOption"
    static let traceMargin = "traceMargin", traceNodes = "traceNodes", traceSmoothing = "traceSmoothing"
    /// View › Show Guides (⌘;) and Lock Guides (⌥⌘;), also in the right-click menu.
    static let guidesVisible = "guidesVisible", guidesLocked = "guidesLocked"
    /// View › Show Grid (⌘') and Snap to Grid (⇧⌘'), as in Illustrator; the spacing (mm), the subdivisions and the color
    /// are in Settings.
    static let gridVisible = "gridVisible", gridSnap = "gridSnap", gridSpacing = "gridSpacing", gridSubdivisions = "gridSubdivisions"
    static let gridColor = "gridColor"
    /// The Artboard tool moves the artwork on an artboard with it (the control bar's option; Illustrator's default is on).
    static let moveArtworkWithArtboard = "moveArtworkWithArtboard"

    static let defaultGuideColor = "00B8FF"
    static let defaultGridColor = "B4BCC8"
    static let defaultGridSpacing = 10.0, defaultGridSubdivisions = 5

    /// The grid: lines every `spacing` mm, each square split in `subdivisions` (the snap uses the smaller step).
    static var grid: (spacing: Double, subdivisions: Int) {
        (max(number(gridSpacing) ?? defaultGridSpacing, 0.5), min(max(Int(number(gridSubdivisions) ?? Double(defaultGridSubdivisions)), 1), 50))
    }

    /// How far the arrows move the selection, in mm: normal, with ⇧ and with ⌥.
    static var arrowSteps: (normal: Double, shift: Double, option: Double) {
        (number(arrowStep) ?? 1, number(arrowStepShift) ?? 10, number(arrowStepOption) ?? 0.1)
    }

    /// The settings the Trace window opens with.
    static var traceDefaults: TraceParameters {
        var prm = TraceParameters()
        prm.margin = number(traceMargin) ?? prm.margin
        prm.nodes = number(traceNodes) ?? prm.nodes
        prm.smoothing = number(traceSmoothing) ?? prm.smoothing
        return prm
    }

    /// nil when never set (a value given on the command line comes as text, which `double` also reads).
    private static func number(_ key: String) -> Double? {
        UserDefaults.standard.object(forKey: key) == nil ? nil : UserDefaults.standard.double(forKey: key)
    }
}

extension Color {
    /// "RRGGBB" (the guide color in Settings).
    init(hex: String) {
        let v = UInt32(hex, radix: 16) ?? 0x00B8FF
        self.init(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var hex: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .systemBlue
        return [c.redComponent, c.greenComponent, c.blueComponent].map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
    }
}

/// Cutline › Settings…
struct SettingsView: View {
    @AppStorage(LengthUnit.key) private var unit = LengthUnit.mm
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.automatic
    @AppStorage(StartScreen.key) private var startScreen = true
    @AppStorage(Preferences.guideColor) private var guideColor = Preferences.defaultGuideColor
    @AppStorage(Preferences.gridColor) private var gridColor = Preferences.defaultGridColor
    @AppStorage(Preferences.gridSpacing) private var gridSpacing = Preferences.defaultGridSpacing
    @AppStorage(Preferences.gridSubdivisions) private var gridSubdivisions = Preferences.defaultGridSubdivisions
    @AppStorage(Preferences.arrowStep) private var arrowStep = 1.0
    @AppStorage(Preferences.arrowStepShift) private var arrowStepShift = 10.0
    @AppStorage(Preferences.arrowStepOption) private var arrowStepOption = 0.1
    @AppStorage(Preferences.traceMargin) private var traceMargin = TraceParameters().margin
    @AppStorage(Preferences.traceNodes) private var traceNodes = TraceParameters().nodes
    @AppStorage(Preferences.traceSmoothing) private var traceSmoothing = TraceParameters().smoothing
    @AppStorage(PreferredConnection.key) private var connection = PreferredConnection.usb

    var body: some View {
        Form {
            Section("General") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { _, chosen in chosen.apply() }
                Toggle("Show the start screen", isOn: $startScreen)
                Text("When Cutline opens with no document and when the last one closes; off, it opens a blank document.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Units") {
                Picker("Length", selection: $unit) {
                    ForEach(LengthUnit.allCases) { Text(verbatim: "\($0.name) (\($0.symbol))").tag($0) }
                }
                Text("Rulers, position and size, margins and the other lengths. Documents always store millimeters.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Canvas") {
                ColorPicker("Guide color", selection: Binding(get: { Color(hex: guideColor) }, set: { guideColor = $0.hex }),
                            supportsOpacity: false)
                if Feature.grid.isOn {
                    ColorPicker("Grid color", selection: Binding(get: { Color(hex: gridColor) }, set: { gridColor = $0.hex }),
                                supportsOpacity: false)
                    length("Gridline every", Binding(get: { gridSpacing }, set: { gridSpacing = max($0, 0.5) }))
                    LabeledContent("Subdivisions") {
                        HStack(spacing: 4) {
                            TextField("Subdivisions", value: Binding(get: { gridSubdivisions }, set: { gridSubdivisions = min(max($0, 1), 50) }),
                                      format: .number)
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                            Stepper("Subdivisions", value: Binding(get: { gridSubdivisions }, set: { gridSubdivisions = min(max($0, 1), 50) }),
                                    in: 1...50)
                                .labelsHidden()
                        }
                    }
                }
                length("Arrow keys move", $arrowStep)
                length("With ⇧", $arrowStepShift)
                length("With ⌥", $arrowStepOption)
            }
            if Feature.colorProfiles.isOn { ColorSettingsSection() }
            Section("Trace Image") {
                length("Margin", $traceMargin)
                percent("Node count", $traceNodes)
                percent("Smoothing", $traceSmoothing)
                Text("What the Trace window opens with.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Machine") {
                Picker("Try first", selection: $connection) {
                    ForEach(PreferredConnection.allCases) { Text($0.name).tag($0) }
                }
                Text("When the machine is on the cable and on Bluetooth at the same time. If it doesn’t answer, the other one is tried.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Updates") {
                UpdatesSettings(updater: Updates.controller.updater)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A length in mm, shown and typed in the chosen unit.
    private func length(_ title: LocalizedStringKey, _ mm: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, value: Binding(get: { unit.show(mm.wrappedValue) }, set: { mm.wrappedValue = max(unit.mm($0), 0) }),
                          format: .number.precision(.fractionLength(0...unit.fractionDigits)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                Text(verbatim: unit.symbol).foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
            }
        }
    }

    private func percent(_ title: LocalizedStringKey, _ value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = min(max($0, 0), 100) }),
                          format: .number.precision(.fractionLength(0)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                Text(verbatim: "%").foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
            }
        }
    }
}

/// Sparkle's own setting (kept by it) and Check Now; both off in debug builds, where the updater doesn't run.
private struct UpdatesSettings: View {
    let updater: SPUUpdater
    @State private var automatic = false
    @State private var can = false

    var body: some View {
        Toggle("Check for updates automatically", isOn: Binding(get: { automatic }, set: {
            automatic = $0
            updater.automaticallyChecksForUpdates = $0
        }))
        .onAppear { automatic = updater.automaticallyChecksForUpdates }
        LabeledContent("") {
            Button("Check Now") { updater.checkForUpdates() }
                .disabled(!can)
                .onReceive(updater.publisher(for: \.canCheckForUpdates)) { can = $0 }
        }
    }
}
