// Character and Paragraph panels of the side menu (like Illustrator's) and the font list, which also
// shows in the control bar. Character: while typing on the canvas, it applies to the selected letters (or what is
// typed next); outside editing, to whole selected texts; with none, to the next ones
// (Document.changeStyle). Paragraph: always the whole text (Document.changeText).
import AppKit
import SwiftUI

// MARK: Character

struct CharacterSection: View {
    @Bindable var doc: Document

    var body: some View {
        let style = doc.textStyle
        let object = doc.currentTextObject
        let scale = doc.editAnchor?.scale ?? object?.textAnchor?.scale ?? CGSize(width: 1, height: 1)
        VStack(alignment: .leading, spacing: 8) {
            FontButton(doc: doc, style: style)
            StyleMenu(doc: doc, style: style)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    KindField(icon: .textSize, tip: "Font size", value: style.size, unit: "pt",
                              suggestions: [6, 8, 9, 10, 11, 12, 14, 18, 24, 30, 36, 48, 60, 72, 96, 144], minimum: 1, maximum: 1000) { v in
                        if let v { doc.changeStyle { $0.size = v } }
                    }
                    KindField(icon: .textLeading, tip: "Leading (empty = auto; each line uses the largest)", value: style.leading,
                              automatic: "(\(number(style.autoLeading)))", unit: "pt",
                              suggestions: [6, 8, 9, 10, 11, 12, 14, 18, 24, 30, 36, 48, 60, 72], minimum: 0, maximum: 5000) { v in
                        doc.changeStyle { $0.leading = v }
                    }
                }
                GridRow {
                    KindField(icon: .textKerning, tip: "Kerning: empty = the font's own (Auto); 0 = no kerning",
                              value: style.kerning, automatic: String(localized: "Auto"), unit: "",
                              suggestions: [-100, -75, -50, -25, -10, -5, 0, 5, 10, 25, 50, 75, 100], minimum: -1000, maximum: 10_000) { v in
                        doc.changeStyle { $0.kerning = v }
                    }
                    KindField(icon: .textTracking, tip: "Tracking: space between all letters (thousandths of an em)",
                              value: style.tracking, unit: "",
                              suggestions: [-100, -75, -50, -25, -10, -5, 0, 5, 10, 25, 50, 75, 100, 200], minimum: -1000, maximum: 10_000) { v in
                        if let v { doc.changeStyle { $0.tracking = v } }
                    }
                }
                GridRow {
                    KindField(icon: .textScaleV, tip: "Vertical scale (whole text)", value: scale.height * 100, unit: "%",
                              suggestions: [25, 50, 75, 100, 125, 150, 200], minimum: 1, maximum: 10_000) { v in
                        if let v { doc.setTextScale(vertical: v / 100) }
                    }
                    .disabled(object == nil)
                    KindField(icon: .textScaleH, tip: "Horizontal scale (whole text)", value: scale.width * 100, unit: "%",
                              suggestions: [25, 50, 75, 100, 125, 150, 200], minimum: 1, maximum: 10_000) { v in
                        if let v { doc.setTextScale(horizontal: v / 100) }
                    }
                    .disabled(object == nil)
                }
                GridRow {
                    KindField(icon: .textBaselineShift, tip: "Baseline shift (positive moves up)", value: style.offset,
                              unit: "pt", suggestions: [-12, -6, -3, -1, 0, 1, 3, 6, 12], minimum: -5000, maximum: 5000) { v in
                        if let v { doc.changeStyle { $0.offset = v } }
                    }
                    KindField(icon: .textRotation, tip: "Character rotation", value: style.rotation, unit: "°",
                              suggestions: [-90, -45, -30, -15, 0, 15, 30, 45, 90, 180], minimum: -360, maximum: 360) { v in
                        if let v { doc.changeStyle { $0.rotation = v } }
                    }
                }
            }
            HStack(spacing: 2) {
                ToggleButton(icon: .textAllCaps, tip: "All caps", enabled: style.allCaps) {
                    doc.changeStyle { $0.allCaps.toggle() }
                }
                ToggleButton(icon: .textSmallCaps, tip: "Small caps (the font's own; otherwise capitals at 70%)", enabled: style.smallCaps) {
                    doc.changeStyle { $0.smallCaps.toggle() }
                }
                ToggleButton(icon: .textSuperscript, tip: "Superscript", enabled: style.position == .superscripted) {
                    doc.changeStyle { $0.position = $0.position == .superscripted ? .normal : .superscripted }
                }
                ToggleButton(icon: .textSubscript, tip: "Subscript", enabled: style.position == .subscripted) {
                    doc.changeStyle { $0.position = $0.position == .subscripted ? .normal : .subscripted }
                }
                Spacer(minLength: 0)
                ToggleButton(icon: .textUnderline, tip: "Underline (also cut)", enabled: style.underline) {
                    doc.changeStyle { $0.underline.toggle() }
                }
                ToggleButton(icon: .textStrikethrough, tip: "Strikethrough (also cut)", enabled: style.strikethrough) {
                    doc.changeStyle { $0.strikethrough.toggle() }
                }
            }
            Group {
                switch doc.styleTarget {
                case .letters: Text("Applies to the selected letters.")
                case .typing: Text("Applies to what you type next. Select letters to change them.")
                case .texts: Text("Applies to the whole text. To change only some letters, select them while typing (T).")
                case .nextOnes: Text("No text selected: applies to the next texts.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            // Like Illustrator's quick actions for text (Create Outlines); also in the Object menu (⇧⌘O).
            if doc.hasTextToOutline {
                Button { doc.convertTextToOutlines() } label: {
                    Text("Create Outlines").frame(maxWidth: .infinity)
                }
                .help("The letters become paths with editable points and no longer depend on the font (⇧⌘O). Only ⌘Z turns them back into text.")
            }
        }
        // Enter in a field gives the keyboard back to the text being typed on the canvas (the selection stays there).
        .onSubmit { doc.returnFocusToText() }
    }
}

// MARK: Paragraph

struct ParagraphSection: View {
    @Bindable var doc: Document

    var body: some View {
        let text = doc.currentText
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(TextAlignmentKind.allCases) { alignment in
                    ToggleButton(icon: alignment.icon, tip: alignment.tip, enabled: text.alignment == alignment) {
                        doc.changeText { $0.alignment = alignment }
                    }
                }
                Spacer()
                ToggleButton(icon: .textBullets, tip: "Bullets", enabled: text.bullet == .dot) {
                    doc.changeText { $0.bullet = $0.bullet == .dot ? .plain : .dot }
                }
                ToggleButton(icon: .textNumbers, tip: "Numbering", enabled: text.bullet == .numbers) {
                    doc.changeText { $0.bullet = $0.bullet == .numbers ? .plain : .numbers }
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    KindField(icon: .textIndentLeft, tip: "Left indent", value: text.leftIndent, unit: "pt",
                              suggestions: [0, 6, 12, 18, 24, 36, 48, 72], minimum: -5000, maximum: 5000) { v in
                        if let v { doc.changeText { $0.leftIndent = v } }
                    }
                    KindField(icon: .textIndentRight, tip: "Right indent (right- or center-aligned text)",
                              value: text.rightIndent, unit: "pt",
                              suggestions: [0, 6, 12, 18, 24, 36, 48, 72], minimum: -5000, maximum: 5000) { v in
                        if let v { doc.changeText { $0.rightIndent = v } }
                    }
                }
                GridRow {
                    KindField(icon: .textIndentFirst, tip: "First-line indent of each paragraph",
                              value: text.firstLineIndent, unit: "pt",
                              suggestions: [0, 6, 12, 18, 24, 36, 48, 72], minimum: -5000, maximum: 5000) { v in
                        if let v { doc.changeText { $0.firstLineIndent = v } }
                    }
                }
                GridRow {
                    KindField(icon: .textSpaceBefore, tip: "Space before paragraph", value: text.spaceBefore, unit: "pt",
                              suggestions: [0, 3, 6, 9, 12, 18, 24, 36], minimum: 0, maximum: 5000) { v in
                        if let v { doc.changeText { $0.spaceBefore = v } }
                    }
                    KindField(icon: .textSpaceAfter, tip: "Space after paragraph", value: text.spaceAfter, unit: "pt",
                              suggestions: [0, 3, 6, 9, 12, 18, 24, 36], minimum: 0, maximum: 5000) { v in
                        if let v { doc.changeText { $0.spaceAfter = v } }
                    }
                }
            }
            Text("Each line is a paragraph: text only breaks where you press Return. Applies to the whole text.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onSubmit { doc.returnFocusToText() }
    }
}

private extension TextAlignmentKind {
    var icon: ImageResource {
        switch self {
        case .left: .textAlignLeft
        case .center: .textAlignCenter
        case .right: .textAlignRight
        }
    }

    var tip: LocalizedStringKey {
        switch self {
        case .left: "Align left"
        case .center: "Align center"
        case .right: "Align right"
        }
    }
}

// MARK: Pieces

/// Number as in the fields (up to two decimals, the region's separator).
private func number(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...1))) }

/// Numeric field with an icon and a menu of common values, like Illustrator's Character panel. `value`
/// nil = automatic (the field is empty and shows `automatic`).
struct KindField: View {
    let icon: ImageResource
    let tip: LocalizedStringKey
    let value: Double?
    var automatic: String?
    let unit: String
    let suggestions: [Double]
    let minimum: Double
    let maximum: Double
    let assign: (Double?) -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(icon).resizable().frame(width: 16, height: 16).foregroundStyle(.secondary)
            HStack(spacing: 2) {
                // Confirms on Enter or leaving the field; only applies (and registers the undo) if it changed.
                TextField(tip, value: Binding<Double?>(get: { value }, set: { updated in
                    let v = updated.map { min(max($0, minimum), maximum) }
                    if v != value, v != nil || automatic != nil { assign(v) }
                }), format: .number.precision(.fractionLength(0...2)), prompt: automatic.map { Text($0) })
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
                Menu {
                    if automatic != nil {
                        Button("Auto") { assign(nil) }
                        Divider()
                    }
                    ForEach(suggestions, id: \.self) { s in
                        Button(number(s) + (unit.isEmpty ? "" : " " + unit)) { assign(s) }
                    }
                } label: {
                    Image(.arrowDown).resizable().frame(width: 10, height: 10)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        }
        .frame(width: 118)
        .help(tip)
    }
}

/// Toggle button, lit in the accent color (like the control bar's).
struct ToggleButton: View {
    let icon: ImageResource
    let tip: LocalizedStringKey
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(icon)
                .resizable()
                .frame(width: 18, height: 18)
                .foregroundStyle(enabled ? Color.accentColor : .secondary)
                .frame(width: 30, height: 26)
                .background(enabled ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tip)
    }
}

/// The text's family; opens the list of all the Mac's fonts, with search.
struct FontButton: View {
    let doc: Document
    let style: CharacterStyle
    var compact = false
    @State private var isOpen = false

    var body: some View {
        let installed = FontCatalog.shared.installedOnes.contains(style.font)
        Button { isOpen.toggle() } label: {
            MenuLabel(text: style.font, compact: compact, missing: !installed)
        }
        .buttonStyle(.plain)
        .help(installed ? "Font" as LocalizedStringKey
              : Feature.googleFonts.isOn && GoogleFonts.missing(style.font) != nil
              ? "Font not installed on this Mac. It's on Google Fonts: open the list to add it to Cutline."
              : "Font not installed on this Mac: the text shows in another font until it's installed or activated (no need to quit Cutline)")
        #if DEBUG
        .onAppear { if DebugHooks.fontListOpen, !compact { isOpen = true } }
        #endif
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            FontList(current: style.font) { family in
                doc.changeStyle { $0.switchFamily(family) }
                isOpen = false
            }
        }
    }
}

/// The family's faces (Regular, Bold Italic…).
struct StyleMenu: View {
    let doc: Document
    let style: CharacterStyle
    var compact = false

    var body: some View {
        let faces = FontCatalog.shared.faces(style.font)
        let inUse = style.postscriptInUse
        Menu {
            Picker("Style", selection: Binding(get: { inUse }, set: { updated in doc.changeStyle { $0.postscript = updated } })) {
                ForEach(faces) { Text($0.name).tag($0.postscript) }
                if !faces.contains(where: { $0.postscript == inUse }) { Text(inUse).tag(inUse) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            MenuLabel(text: faces.first { $0.postscript == inUse }?.name ?? inUse, compact: compact)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Font style")
    }
}

/// Look of the font and style menus: the name and the small arrow in a field, like the control bar's.
private struct MenuLabel: View {
    let text: String
    let compact: Bool
    /// A font that isn't installed on this Mac (the text shows in another one until it's installed).
    var missing = false

    var body: some View {
        HStack(spacing: 6) {
            if missing {
                Image(.warning).resizable().frame(width: 13, height: 13).foregroundStyle(.orange)
            }
            Text(text).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Image(.arrowDown).resizable().frame(width: 10, height: 10).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, compact ? 3 : 5)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}

/// Where the list's families come from: the Mac's (Installed) or Google Fonts (GoogleFonts/).
enum FontSource: Hashable {
    case installed, google
}

/// The font list: two tabs, Installed (every family on the Mac, Google Fonts added to Cutline included) and Google Fonts
/// (GoogleFonts/GoogleFontsTab.swift), like Illustrator's Find More. It opens on the tab used last (while the app is open).
struct FontList: View {
    let current: String
    let choose: (String) -> Void
    @State private var source: FontSource
    @State private var search = ""
    @State private var googleSearch = ""
    @State private var category: GoogleCategory = .all

    /// The tab used last, kept while the app is open.
    private static var lastSource: FontSource = .installed

    init(current: String, start: FontSource? = nil, choose: @escaping (String) -> Void) {
        self.current = current
        self.choose = choose
        _source = State(initialValue: start ?? Self.lastSource)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Before Google Fonts is released (ReleaseGate.swift), only the installed fonts, as before.
            if Feature.googleFonts.isOn {
                Picker("Fonts", selection: $source) {
                    Text("Installed").tag(FontSource.installed)
                    Text(verbatim: "Google Fonts").tag(FontSource.google)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 10)
                .padding(.top, 10)
            }
            switch Feature.googleFonts.isOn ? source : .installed {
            case .installed: InstalledFontList(current: current, choose: choose, search: $search)
            case .google: GoogleFontsTab(current: current, choose: choose, search: $googleSearch, category: $category)
            }
        }
        .frame(width: 320, height: 480)
        .onChange(of: source) { Self.lastSource = source }
        #if DEBUG
        .task { await DebugHooks.driveFontList(source: $source, search: $googleSearch, category: $category, choose: choose) }
        #endif
    }
}

/// The search field at the top of each tab; Enter picks the first family found.
struct FontSearchField: View {
    let prompt: LocalizedStringKey
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    let submit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(.search).resizable().frame(width: 14, height: 14).foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused(focus)
                .onSubmit(submit)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
    }
}

/// All installed families (system, user, activated Adobe Fonts and the Google Fonts added to Cutline), each written in
/// itself.
private struct InstalledFontList: View {
    let current: String
    let choose: (String) -> Void
    @Binding var search: String
    @State private var position: String?
    @FocusState private var searching: Bool

    /// From the catalog: a font installed while the list is open already shows in it.
    private var families: [String] { FontCatalog.shared.families }

    private var filtered: [String] {
        search.isEmpty ? families : families.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            FontSearchField(prompt: "Search fonts", text: $search, focus: $searching) {
                if let firstOne = filtered.first { choose(firstOne) }
            }
            // The text's font is missing and Google Fonts has it (a document from another Mac): add it right here.
            if Feature.googleFonts.isOn, let family = GoogleFonts.missing(current) {
                MissingFontBanner(name: current, family: family)
            }
            Divider()
            if filtered.isEmpty {
                Text("No fonts found").foregroundStyle(.secondary).frame(maxHeight: .infinity)
            } else {
                // Rows of the same height: the list opens already at the current font (scrollPosition), without measuring all.
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered, id: \.self) { family in
                            FontRow(family: family, current: family == current) { choose(family) }
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.vertical, 4)
                }
                .scrollPosition(id: $position, anchor: .center)
            }
            Divider()
            Text("\(families.count) font families installed")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(6)
        }
        .onAppear {
            position = current
            searching = true
        }
    }
}

private struct FontRow: View {
    let family: String
    let current: Bool
    let choose: () -> Void
    @State private var over = false

    var body: some View {
        let font = Fonts.swatch(family, size: 15)
        // A Google Fonts family that Cutline added (only Cutline sees it): a cloud, and Remove in the right-click.
        let google = GoogleFonts.shared.addedFamily(installedAs: family)
        Button(action: choose) {
            HStack(spacing: 8) {
                Image(.checked).resizable().frame(width: 12, height: 12).foregroundStyle(Color.accentColor).opacity(current ? 1 : 0)
                if Fonts.isSymbols(font) {
                    // Symbol font: the name in the system font and a sample beside it.
                    Text(family).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(verbatim: "Abc").font(Font(font)).foregroundStyle(.secondary)
                } else {
                    Text(family).font(Font(font)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                if google != nil {
                    Image(.cloud).resizable().frame(width: 13, height: 13).foregroundStyle(.secondary)
                        .help("Added from Google Fonts: only Cutline uses it")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .clipped()
            .background(over ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { over = $0 }
        .contextMenu {
            if let google {
                Button("Remove from Cutline") { GoogleFonts.shared.remove(google) }
            }
        }
    }
}
