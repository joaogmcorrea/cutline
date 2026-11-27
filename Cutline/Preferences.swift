// App settings (Cutline › Settings…, ⌘,), in tabs (23/11/2026): General (language, appearance, start screen, length unit,
// updates), Canvas (guides, grid, how far the arrows move), Color (the profiles, Editor/ColorProfileViews.swift), Import
// (the Trace defaults) and Machine (the preferred connection). Stored in UserDefaults; the document keeps everything in mm.
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

    /// How far the arrows move the selection, in mm: Illustrator's 1 pt, 10 pt with ⇧, and 0.1 mm with ⌥ (decision of the
    /// owner, 16/11/2026: the 1 mm and 10 mm before were too far).
    static let defaultArrowStep = 25.4 / 72, defaultArrowStepShift = 254.0 / 72, defaultArrowStepOption = 0.1

    static var arrowSteps: (normal: Double, shift: Double, option: Double) {
        (number(arrowStep) ?? defaultArrowStep, number(arrowStepShift) ?? defaultArrowStepShift, number(arrowStepOption) ?? defaultArrowStepOption)
    }

    /// Once: the old steps (1 mm, 10 mm), which the Settings fields used to save just by being left, give way to the new
    /// defaults. A step someone typed (anything else) stays.
    static func migrateArrowSteps() {
        let defaults = UserDefaults.standard, done = "arrowStepsMigrated"
        guard !defaults.bool(forKey: done) else { return }
        let old = [arrowStep: 1.0, arrowStepShift: 10.0].filter { number($0.key) == $0.value }.map(\.key)
        #if DEBUG
        // A hidden test never writes the owner's settings: the same result only in memory (the argument domain wins).
        if ProcessInfo.processInfo.environment["CUTLINE_HIDDEN"] != nil {
            var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            for key in old where arguments[key] == nil {
                arguments[key] = key == arrowStep ? defaultArrowStep : defaultArrowStepShift
            }
            defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            return
        }
        #endif
        for key in old { defaults.removeObject(forKey: key) }
        defaults.set(true, forKey: done)
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

/// The tabs of Cutline › Settings…, as the Settings of Safari or Final Cut (proposal A of the redesign, 23/11/2026).
/// The last one opened comes back.
nonisolated enum SettingsTab: String, Sendable {
    case general, canvas, color, importing, machine

    static let key = "settingsTab"
}

/// The language of the interface: the Mac's (the default) or one of Cutline's. Stored where the system keeps the
/// language of each app (System Settings › General › Language & Region › Applications): `AppleLanguages` in Cutline's
/// own domain, so both places always show the same choice. It takes effect when Cutline opens again.
nonisolated enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, english = "en", portuguese = "pt-BR", spanish = "es"

    static let key = "AppleLanguages"

    var id: Self { self }

    init(code: String) {
        switch code.lowercased() {
        case let c where c.hasPrefix("pt"): self = .portuguese
        case let c where c.hasPrefix("es"): self = .spanish
        case let c where c.hasPrefix("en"): self = .english
        default: self = .system
        }
    }

    /// Each language in itself, as in System Settings; System Default says which one the Mac gives.
    var name: String {
        switch self {
        case .system: String(localized: "System Default (\(Self.macChoice.name))")
        case .english: "English"
        case .portuguese: "Português (Brasil)"
        case .spanish: "Español"
        }
    }

    /// The one stored for Cutline. `UserDefaults.standard` would also read the Mac's list, so only Cutline's domain.
    static var chosen: AppLanguage {
        guard let id = Bundle.main.bundleIdentifier,
              let first = (UserDefaults.standard.persistentDomain(forName: id)?[key] as? [String])?.first else { return .system }
        return AppLanguage(code: first)
    }

    /// What the Mac gives Cutline without a choice of its own: the first of the Mac's languages that Cutline has.
    static var macChoice: AppLanguage {
        let mac = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[key] as? [String] ?? Locale.preferredLanguages
        let code = Bundle.preferredLocalizations(from: Bundle.main.localizations.filter { $0 != "Base" }, forPreferences: mac).first ?? "en"
        let language = AppLanguage(code: code)
        return language == .system ? .english : language
    }

    /// The language on screen now.
    static var running: AppLanguage {
        let language = AppLanguage(code: Bundle.main.preferredLocalizations.first ?? "en")
        return language == .system ? .english : language
    }

    /// The language Cutline opens in with this choice.
    var resolved: AppLanguage { self == .system ? Self.macChoice : self }

    @MainActor func save() {
        #if DEBUG
        // A hidden test never writes the owner's settings.
        if ProcessInfo.processInfo.environment["CUTLINE_HIDDEN"] != nil { return }
        #endif
        if self == .system {
            UserDefaults.standard.removeObject(forKey: Self.key)
        } else {
            UserDefaults.standard.set([rawValue], forKey: Self.key)
        }
    }

    /// A sentence of the catalog in this language (its .lproj), so whoever picks it can read the notice. English, the
    /// catalog's source, has no table of its own: the key is the text.
    func text(_ key: String) -> String {
        guard resolved != .english,
              let path = Bundle.main.path(forResource: resolved.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// Restart Now: the documents with changes are reviewed as when quitting (Cancel keeps Cutline open), then Cutline
    /// quits and opens again.
    @MainActor static func relaunch() { Relauncher.shared.start() }
}

@MainActor private final class Relauncher: NSObject {
    static let shared = Relauncher()

    func start() {
        NSDocumentController.shared.reviewUnsavedDocuments(withAlertTitle: nil, cancellable: true, delegate: self,
                                                           didReviewAllSelector: #selector(reviewed(_:didReviewAll:contextInfo:)),
                                                           contextInfo: nil)
    }

    @objc private func reviewed(_ controller: NSDocumentController, didReviewAll: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard didReviewAll else { return }
        // A shell that waits for this process to end and opens the app again (the same way Sparkle restarts it).
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
                           Bundle.main.bundlePath]
        do { try shell.run() } catch { return }
        NSApp.terminate(nil)
    }
}

/// Cutline › Settings…
struct SettingsView: View {
    @AppStorage(SettingsTab.key) private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", image: "settingsTabGeneral", value: SettingsTab.general) { GeneralSettings() }
            Tab("Canvas", image: "settingsTabCanvas", value: SettingsTab.canvas) { CanvasSettings() }
            if Feature.colorProfiles.isOn {
                Tab("Color", image: "settingsTabColor", value: SettingsTab.color) { ColorTab() }
            }
            Tab("Import", image: "settingsTabImport", value: SettingsTab.importing) { ImportSettings() }
            Tab("Machine", image: "settingsTabMachine", value: SettingsTab.machine) { MachineSettings() }
        }
        #if DEBUG
        .onAppear {
            if let test = DebugHooks.settingsTab { tab = test }
            DebugHooks.resizeSettings()
        }
        #endif
    }
}

/// One tab, laid out as the Settings of Final Cut (owner's request, 23/11/2026): labels with a colon on the left,
/// controls on the right, checkboxes and pop-up menus, every number with its ˅ ˄ arrows. The window can grow; the
/// form stays at the top, in the middle.
private struct SettingsPane<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        // A grid of our own and not Form's columns style, which pushed the rows with a text field to the left of the
        // others (the numbers didn't line up with the colors and menus).
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 14) { content }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 40)
            .padding(.vertical, 24)
            .fixedSize()
            // Opens just as big as the tab needs (at least 620 wide, so the tabs don't jump); dragging the corner
            // makes it bigger, never smaller.
            .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// One row: the label with its colon on the left (right-aligned), the controls on the right, on the label's baseline.
/// Without a title, the controls go under the ones above (a button under its menus).
struct SettingsRow<Content: View>: View {
    let title: LocalizedStringKey?
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        GridRow {
            if let title { Text(title).gridColumnAlignment(.trailing) } else { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
            content
        }
    }
}

/// The small text under a control that says what it does.
struct SettingsNote: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 330, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.automatic
    @AppStorage(StartScreen.key) private var startScreen = true
    @AppStorage(LengthUnit.key) private var unit = LengthUnit.mm
    @AppStorage(GoogleFonts.shownKey) private var googleFonts = true
    @State private var language = AppLanguage.chosen

    var body: some View {
        SettingsPane {
            Section {
                SettingsRow("Language:") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Language:", selection: $language) {
                            Text(verbatim: AppLanguage.system.name).tag(AppLanguage.system)
                            Divider()
                            ForEach(AppLanguage.allCases.filter { $0 != .system }) { Text(verbatim: $0.name).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .onChange(of: language) { _, chosen in chosen.save() }
                        if language.resolved != AppLanguage.running {
                            HStack(spacing: 8) {
                                Text(verbatim: language.text("Cutline will be in English the next time it opens."))
                                    .fixedSize(horizontal: false, vertical: true)
                                Button(language.text("Restart Now")) { AppLanguage.relaunch() }
                                    .buttonStyle(.borderedProminent)
                            }
                            .font(.callout)
                            .frame(width: 330, alignment: .leading)
                        }
                        SettingsNote("Cutline follows the Mac’s language unless you choose one here. It changes when Cutline opens again. The same choice is in System Settings › General › Language & Region › Applications.")
                    }
                }
                SettingsRow("Appearance:") {
                    Picker("Appearance:", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { Text($0.name).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: appearance) { _, chosen in chosen.apply() }
                }
                SettingsRow("Start screen:") {
                    Toggle("Show when no document is open", isOn: $startScreen)
                        .help("When Cutline opens with no document and when the last one closes; off, it opens a blank document.")
                }
                SettingsRow("Length:") {
                    Picker("Length:", selection: $unit) {
                        ForEach(LengthUnit.allCases) { Text(verbatim: "\($0.name) (\($0.symbol))").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Rulers, position and size, margins and the other lengths. Documents always store millimeters.")
                }
                if Feature.googleFonts.isOn {
                    SettingsRow("Fonts:") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Show Google Fonts in the font list", isOn: $googleFonts)
                            SettingsNote("Off, Cutline never talks to Google. The fonts you already added keep working.")
                        }
                    }
                }
            }
            Divider()
            Section {
                UpdatesSettings(updater: Updates.controller.updater)
            }
        }
        #if DEBUG
        .onAppear { if let test = DebugHooks.settingsLanguage { language = test } }
        #endif
    }
}

private struct CanvasSettings: View {
    @AppStorage(Preferences.guideColor) private var guideColor = Preferences.defaultGuideColor
    @AppStorage(Preferences.gridColor) private var gridColor = Preferences.defaultGridColor
    @AppStorage(Preferences.gridSpacing) private var gridSpacing = Preferences.defaultGridSpacing
    @AppStorage(Preferences.gridSubdivisions) private var gridSubdivisions = Preferences.defaultGridSubdivisions
    @AppStorage(Preferences.arrowStep) private var arrowStep = Preferences.defaultArrowStep
    @AppStorage(Preferences.arrowStepShift) private var arrowStepShift = Preferences.defaultArrowStepShift
    @AppStorage(Preferences.arrowStepOption) private var arrowStepOption = Preferences.defaultArrowStepOption

    var body: some View {
        SettingsPane {
            Section {
                ColorRow(title: "Guide color:", hex: $guideColor)
                if Feature.grid.isOn {
                    ColorRow(title: "Grid color:", hex: $gridColor)
                    LengthRow(title: "Gridline every:", mm: Binding(get: { gridSpacing }, set: { gridSpacing = max($0, 0.5) }))
                    SettingsRow("Subdivisions:") {
                        StepperField(value: Binding(get: { Double(gridSubdivisions) }, set: { gridSubdivisions = Int($0.rounded()) }),
                                     step: 1, range: 1...50, fractionDigits: 0)
                    }
                }
            }
            Divider()
            Section {
                LengthRow(title: "Arrow keys move:", mm: $arrowStep, fine: true)
                LengthRow(title: "With ⇧:", mm: $arrowStepShift, fine: true)
                LengthRow(title: "With ⌥:", mm: $arrowStepOption, fine: true)
            }
        }
    }
}

private struct ColorTab: View {
    var body: some View {
        SettingsPane { ColorSettingsSection() }
    }
}

private struct ImportSettings: View {
    @AppStorage(Preferences.traceMargin) private var traceMargin = TraceParameters().margin
    @AppStorage(Preferences.traceNodes) private var traceNodes = TraceParameters().nodes
    @AppStorage(Preferences.traceSmoothing) private var traceSmoothing = TraceParameters().smoothing
    @AppStorage(LengthUnit.key) private var unit = LengthUnit.mm

    var body: some View {
        SettingsPane {
            // A group of values, as Final Cut's Durations: the group on the left, each value with its own label.
            SettingsRow("Trace Image:") {
                VStack(alignment: .leading, spacing: 8) {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
                        GridRow {
                            Text("Margin:").gridColumnAlignment(.trailing)
                            LengthField(mm: $traceMargin)
                        }
                        GridRow {
                            Text("Node count:")
                            PercentField(value: $traceNodes)
                        }
                        GridRow {
                            Text("Smoothing:")
                            PercentField(value: $traceSmoothing)
                        }
                    }
                    SettingsNote("What the Trace window opens with.")
                }
            }
        }
    }
}

private struct MachineSettings: View {
    @AppStorage(PreferredConnection.key) private var connection = PreferredConnection.usb
    @AppStorage(TestCut.sizeKey) private var testSize = TestCut.defaultSide

    var body: some View {
        SettingsPane {
            SettingsRow("Try first:") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Try first:", selection: $connection) {
                        ForEach(PreferredConnection.allCases) { Text($0.name).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    SettingsNote("When the machine is on the cable and on Bluetooth at the same time. If it doesn’t answer, the other one is tried.")
                }
            }
            SettingsRow("Test cut:") {
                VStack(alignment: .leading, spacing: 8) {
                    LengthField(mm: Binding(get: { testSize }, set: { testSize = min(max($0, TestCut.sides.lowerBound), TestCut.sides.upperBound) }))
                    SettingsNote("The size of the test square in the Send window of a new document. You can still change it there.")
                }
            }
        }
    }
}

/// A color well with its code beside it. The code gives the row a text baseline: a well alone sat higher than its
/// label and pushed the row to the right of the others.
private struct ColorRow: View {
    let title: LocalizedStringKey
    @Binding var hex: String

    var body: some View {
        SettingsRow(title) {
            HStack(spacing: 8) {
                ColorPicker(title, selection: Binding(get: { Color(hex: hex) }, set: { hex = $0.hex }), supportsOpacity: false)
                    .labelsHidden()
                Text(verbatim: "#" + hex.uppercased())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A length in mm, shown and typed in the chosen unit, with its arrows.
private struct LengthRow: View {
    let title: LocalizedStringKey
    @Binding var mm: Double
    var fine = false

    var body: some View {
        SettingsRow(title) { LengthField(mm: $mm, fine: fine) }
    }
}

private struct LengthField: View {
    @Binding var mm: Double
    /// Small steps (the arrow keys' distances); otherwise whole millimeters.
    var fine = false
    @AppStorage(LengthUnit.key) private var unit = LengthUnit.mm

    var body: some View {
        StepperField(value: Binding(get: { unit.show(mm) }, set: { typed in
            // Only a real change is saved: leaving the field gives back the rounded number it shows ("0.35" for 1 pt),
            // which would replace the value (and save a default that never changed).
            let v = max(unit.mm(typed), 0)
            if abs(unit.show(v) - unit.show(mm)) > 0.5 * pow(10, -Double(unit.fractionDigits)) { mm = v }
        }), step: step, range: 0...Double.greatestFiniteMagnitude, fractionDigits: unit.fractionDigits, unit: unit.symbol)
    }

    private var step: Double {
        switch unit {
        case .mm: fine ? 0.1 : 1
        case .cm, .inch: fine ? 0.01 : 0.1
        }
    }
}

private struct PercentField: View {
    @Binding var value: Double

    var body: some View {
        StepperField(value: $value, step: 5, range: 0...100, fractionDigits: 0, unit: "%")
    }
}

/// A number as Final Cut shows it: a field with ˅ on the left and ˄ on the right (and the ↓ ↑ keys while typing), then
/// the unit. The arrows go to the next multiple of the step.
struct StepperField: View {
    @Binding var value: Double
    let step: Double
    let range: ClosedRange<Double>
    let fractionDigits: Int
    var unit: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 0) {
                arrow(.chevronDown, -1)
                TextField(value: $value, format: .number.precision(.fractionLength(0...fractionDigits))) { EmptyView() }
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .frame(width: 52)
                    .onKeyPress(.upArrow) { move(1); return .handled }
                    .onKeyPress(.downArrow) { move(-1); return .handled }
                arrow(.chevronUp, 1)
            }
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
            if let unit { Text(verbatim: unit).foregroundStyle(.secondary) }
        }
    }

    private func arrow(_ icon: ImageResource, _ direction: Double) -> some View {
        Button { move(direction) } label: {
            Image(icon)
                .resizable()
                .frame(width: 11, height: 11)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(direction < 0 ? value <= range.lowerBound : value >= range.upperBound)
    }

    private func move(_ direction: Double) {
        let next = direction > 0 ? (value / step + 1e-9).rounded(.down) + 1 : (value / step - 1e-9).rounded(.up) - 1
        value = min(max(next * step, range.lowerBound), range.upperBound)
    }
}

/// Sparkle's own setting (kept by it) and Check Now; both off in debug builds, where the updater doesn't run.
private struct UpdatesSettings: View {
    let updater: SPUUpdater
    @State private var automatic = false
    @State private var can = false

    var body: some View {
        SettingsRow("Updates:") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Check for updates automatically", isOn: Binding(get: { automatic }, set: {
                    automatic = $0
                    updater.automaticallyChecksForUpdates = $0
                }))
                .onAppear { automatic = updater.automaticallyChecksForUpdates }
                Button("Check Now") { updater.checkForUpdates() }
                    .disabled(!can)
                    .onReceive(updater.publisher(for: \.canCheckForUpdates)) { can = $0 }
            }
        }
    }
}
