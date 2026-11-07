// Side menu (right), like Adobe's docks: each panel is pinned in the glass column (sections
// separated by dividers, collapsible by the title) or collapsed into an icon in the strip beside it, which opens the
// panel floating when clicked. The pin pins or collapses; » collapses all, « pins all. The Color and
// Stroke sections are in ColorPanel.swift and StrokePanel.swift; Page in PagePanel.swift; Artboards in
// ArtboardsPanel.swift; Character and Paragraph in TextPanel.swift.
import SwiftUI

/// Side menu panels, in the order they appear.
enum Panel: String, CaseIterable, Identifiable {
    case page = "pagina", artboards = "pranchetas", color = "cor", gradient = "degrade", stroke = "traco", character = "caractere", paragraph = "paragrafo", pathfinder, offset, layers = "camadas", links = "vinculos"

    var id: Self { self }

    /// The panel of a feature not released yet stays out of the column and the Window menu (ReleaseGate.swift).
    var isAvailable: Bool {
        switch self {
        case .gradient: Feature.gradients.isOn
        case .links: Feature.linkedImages.isOn
        default: true
        }
    }

    static var available: [Panel] { allCases.filter(\.isAvailable) }

    var title: String {
        switch self {
        case .page: String(localized: "Page")
        case .artboards: String(localized: "Artboards")
        case .color: String(localized: "Color")
        case .gradient: String(localized: "Gradient")
        case .stroke: String(localized: "Stroke")
        case .character: String(localized: "Character")
        case .paragraph: String(localized: "Paragraph")
        case .pathfinder: String(localized: "Pathfinder")
        case .offset: String(localized: "Offset")
        case .layers: String(localized: "Layers")
        case .links: String(localized: "Links")
        }
    }

    var icon: ImageResource {
        switch self {
        case .page: .panelPage
        case .artboards: .panelArtboards
        case .color: .panelColors
        case .gradient: .panelGradient
        case .stroke: .panelStroke
        case .character: .panelCharacter
        case .paragraph: .panelParagraph
        case .pathfinder: .panelPathfinder
        case .offset: .panelOffset
        case .layers: .panelLayers
        case .links: .panelLinks
        }
    }

    /// Collapsed into icons the first time the app opens.
    static let defaultCollapsed = "pranchetas,pathfinder,offset,vinculos"

    /// The collapsed (or hidden) ones, stored as "pathfinder,camadas" (an app preference; the 1.0 names).
    static func parsedSet(_ text: String) -> Set<Panel> {
        Set(text.split(separator: ",").compactMap { Panel(rawValue: String($0)) })
    }

    static func text(_ parsedSet: Set<Panel>) -> String {
        allCases.filter { parsedSet.contains($0) }.map(\.rawValue).joined(separator: ",")
    }
}

struct SidePanel: View {
    @Bindable var doc: Document
    @State private var collapsed: Set<String> = {
        #if DEBUG
        DebugHooks.closedSections
        #else
        []
        #endif
    }()
    @AppStorage("modoCor") private var colorMode = ColorMode.cmyk
    @AppStorage("paineisRecolhidos") private var collapsedText = Panel.defaultCollapsed
    /// Unchecked in the Window menu: they show neither in the column nor in the icon strip.
    @AppStorage("paineisOcultos") private var hiddenText = ""
    /// Collapsed panel opened next to the icon strip.
    @State private var opened: Panel? = {
        #if DEBUG
        DebugHooks.openPanel
        #else
        nil
        #endif
    }()

    static let width = 284.0
    static let stripWidth = 62.0
    private static let iconHeight = 52.0

    /// Space the menu takes on the right (column + strip + margins), for the rulers and the free area.
    static func isBusy(collapsedSet: String, hiddenOnes: String) -> Double {
        let visibleOnes = Set(Panel.available).subtracting(Panel.parsedSet(hiddenOnes))
        let iconized = visibleOnes.intersection(Panel.parsedSet(collapsedSet))
        let column = visibleOnes.count > iconized.count ? width : 0
        let span = iconized.isEmpty ? 0 : stripWidth + (column > 0 ? 8 : 0)
        return column + span > 0 ? column + span + 24 : 0
    }

    private var collapsedSet: Set<Panel> { Panel.parsedSet(collapsedText) }
    private var hiddenOnes: Set<Panel> { Panel.parsedSet(hiddenText) }

    var body: some View {
        let visibleOnes = Panel.available.filter { !hiddenOnes.contains($0) }
        let pinnedOnes = visibleOnes.filter { !collapsedSet.contains($0) }
        let iconized = visibleOnes.filter { collapsedSet.contains($0) }
        HStack(alignment: .top, spacing: 8) {
            if !iconized.isEmpty { span(iconized) }
            if !pinnedOnes.isEmpty { column(pinnedOnes) }
        }
        .onChange(of: collapsedText + "|" + hiddenText) { _, _ in
            if let opened, !collapsedSet.contains(opened) || hiddenOnes.contains(opened) { self.opened = nil }
        }
    }

    private func setCollapsed(_ newItems: Set<Panel>) {
        withAnimation(.snappy(duration: 0.22)) { collapsedText = Panel.text(newItems) }
    }

    // MARK: Pinned column

    private func column(_ pinnedOnes: [Panel]) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Collapse All to Icons", image: .collapseAll) { setCollapsed(Set(Panel.available)) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Collapse all panels to icons")
                }
                .padding(EdgeInsets(top: 8, leading: 16, bottom: -6, trailing: 12))
                ForEach(Array(pinnedOnes.enumerated()), id: \.element) { index, panel in
                    if index > 0 { Divider() }
                    section(panel)
                }
            }
            .padding(.bottom, 4)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
    }

    private func section(_ panel: Panel) -> some View {
        let isOpen = !collapsed.contains(panel.title)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        if isOpen { collapsed.insert(panel.title) } else { collapsed.remove(panel.title) }
                    }
                } label: {
                    SectionHeader(title: panel.title, isOpen: isOpen)
                }
                .buttonStyle(.plain)
                if isOpen { accessory(panel) }
                PinButton(pinned: true) { setCollapsed(collapsedSet.union([panel])) }
            }
            .padding(EdgeInsets(top: 13, leading: 16, bottom: 6, trailing: 12))
            if isOpen {
                content(panel)
                    .padding(EdgeInsets(top: 4, leading: 16, bottom: 14, trailing: 16))
            }
        }
    }

    // MARK: Icon strip

    private func span(_ iconized: [Panel]) -> some View {
        VStack(spacing: 0) {
            Button("Pin All", image: .pinAll) { setCollapsed([]) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .frame(height: 26)
                .help("Pin all panels to the column")
            ForEach(iconized) { panel in
                Button {
                    withAnimation(.snappy(duration: 0.18)) { opened = opened == panel ? nil : panel }
                } label: {
                    VStack(spacing: 3) {
                        Image(panel.icon).resizable().frame(width: 20, height: 20)
                        Text(panel.title).font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(width: Self.stripWidth - 10, height: Self.iconHeight - 6)
                    .foregroundStyle(opened == panel ? Color.white : Color.primary)
                    .background(RoundedRectangle(cornerRadius: 12).fill(opened == panel ? Color.accentColor : .clear))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .frame(height: Self.iconHeight)
                .help(panel.title)
            }
        }
        .padding(.vertical, 5)
        .frame(width: Self.stripWidth)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
        .overlay(alignment: .topLeading) {
            if let opened, let i = iconized.firstIndex(of: opened) {
                // To the left of the strip, at the icon's height.
                floating(opened)
                    .offset(x: -(Self.width + 8), y: Double(i) * Self.iconHeight)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
            }
        }
    }

    /// Collapsed panel opened next to its icon: title, pin (pin to the column) and close.
    private func floating(_ panel: Panel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(panel.title).fontWeight(.semibold)
                Spacer()
                accessory(panel)
                PinButton(pinned: false) { setCollapsed(collapsedSet.subtracting([panel])) }
                Button("Close", image: .close) { withAnimation(.snappy(duration: 0.18)) { opened = nil } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .padding(EdgeInsets(top: 13, leading: 16, bottom: 6, trailing: 12))
            ScrollView {
                content(panel)
                    .padding(EdgeInsets(top: 4, leading: 16, bottom: 14, trailing: 16))
            }
            .frame(maxHeight: 560)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: Self.width)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ panel: Panel) -> some View {
        switch panel {
        case .page: PageSection(doc: doc)
        case .artboards: ArtboardsSection(doc: doc)
        case .color: ColorSection(doc: doc, mode: colorMode)
        case .gradient: GradientSection(doc: doc)
        case .stroke: StrokeSection(doc: doc)
        case .character: CharacterSection(doc: doc)
        case .paragraph: ParagraphSection(doc: doc)
        case .pathfinder: PathfinderSection(doc: doc)
        case .offset: OffsetSection(doc: doc)
        case .layers: LayersSection(doc: doc)
        case .links: LinksSection(doc: doc)
        }
    }

    @ViewBuilder
    private func accessory(_ panel: Panel) -> some View {
        if panel == .color {
            Picker("Mode", selection: $colorMode) {
                ForEach(ColorMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
            .help("Input mode (the document always stores CMYK)")
        }
    }
}

/// Header pin: in the pinned panel, collapses into an icon; in the one opened from the icon, pins it to the column.
private struct PinButton: View {
    let pinned: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(pinned ? .pinFilled : .pin).resizable().frame(width: 13, height: 13)
        }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(pinned ? "Collapse this panel to an icon" : "Pin this panel to the column")
    }
}

/// Section title; the arrow shows on hover and rotates when the section is open.
private struct SectionHeader: View {
    let title: String
    let isOpen: Bool
    @State private var over = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title).fontWeight(.semibold)
            Image(.expandSection)
                .resizable()
                .frame(width: 11, height: 11)
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .opacity(over || !isOpen ? 1 : 0)
            Spacer()
        }
        .contentShape(Rectangle())
        .onHover { over = $0 }
    }
}

// MARK: - Layers

/// Layers as in Illustrator (the top one is drawn last) and, inside the open ones, the objects.
private struct LayersSection: View {
    @Bindable var doc: Document
    @State private var renaming: Layer.ID?
    @State private var confirmDelete = false

    /// Object rows listed per layer, from the top. One row per object crashed the app with a 74,000-path PDF (SwiftUI's
    /// attribute graph runs out of room), and nobody scrolls that far: the rest shows as a count.
    private static var maxRows: Int {
        #if DEBUG
        DebugHooks.layerRows ?? 500
        #else
        500
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if Feature.layerBlending.isOn, let active = doc.layers.first(where: { $0.id == doc.activeLayer }) {
                LayerBlending(doc: doc, layer: active)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }
            ForEach(doc.layers) { layer in
                LayerRow(doc: doc, layer: layer, renaming: $renaming)
                if layer.isOpen {
                    let objects = doc.objects(of: layer)
                    ForEach(objects.suffix(Self.maxRows).reversed()) { object in
                        ObjectRow(doc: doc, object: object, layer: layer)
                    }
                    if objects.count > Self.maxRows {
                        Text("\(objects.count - Self.maxRows) more objects not listed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            // Lined up with the object names.
                            .padding(.leading, 91)
                            .frame(height: 26)
                    }
                }
            }
            Divider().padding(.top, 6)
            HStack(spacing: 4) {
                Text(verbatim: String(localized: "\(doc.layers.count) layers") + " · " + String(localized: "\(doc.objects.count) objects"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Move selection to the active layer", image: .moveToLayer) { doc.moveSelectionToActiveLayer() }
                    .disabled(doc.selection.isEmpty)
                    .help("Move selection to the active layer")
                Button("New layer", image: .newLayer) { doc.newLayer() }
                    .help("New layer")
                Button("Delete Active Layer", image: .trash) {
                    if let active = doc.layers.first(where: { $0.id == doc.activeLayer }), !doc.objects(of: active).isEmpty {
                        confirmDelete = true
                    } else {
                        doc.deleteActiveLayer()
                    }
                }
                .disabled(doc.layers.count < 2)
                .help("Delete Active Layer")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.top, 6)
            .padding(.horizontal, 6)
        }
        .padding(.horizontal, -8)
        .confirmationDialog(deleteText, isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { doc.deleteActiveLayer() }
        }
    }

    private var deleteText: String {
        guard let active = doc.layers.first(where: { $0.id == doc.activeLayer }) else { return "" }
        let n = doc.objects(of: active).count
        return n == 1 ? String(localized: "Delete “\(active.name)” and its object?")
            : String(localized: "Delete “\(active.name)” and its \(n) objects?")
    }
}

/// The active layer's blending mode and opacity, like the top of Photoshop's Layers panel (Illustrator keeps them in
/// its Transparency panel): what the layer prints mixes with the layers under it, on the canvas, in the print and in the
/// Finder's previews. The cut doesn't change.
private struct LayerBlending: View {
    @Bindable var doc: Document
    let layer: Layer

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Picker("Blending Mode", selection: Binding(get: { layer.blend ?? .normal }, set: { doc.setLayerBlend(layer.id, $0) })) {
                    ForEach(Array(LayerBlend.groups.enumerated()), id: \.offset) { index, group in
                        if index > 0 { Divider() }
                        ForEach(group) { Text($0.name).tag($0) }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(maxWidth: 130)
                .help("Blending mode of the active layer (“\(layer.name)”)")
                Spacer(minLength: 4)
                Text("Opacity").font(.caption).foregroundStyle(.secondary)
                TextField("Opacity", value: Binding(get: { Int((layer.alpha * 100).rounded()) }, set: {
                    doc.setLayerOpacity(layer.id, Double($0))
                }), format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 40)
                Text(verbatim: "%").font(.caption).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { layer.alpha * 100 }, set: { doc.setLayerOpacity(layer.id, $0, final: false) }), in: 0...100)
                .controlSize(.mini)
                .help("Opacity of the active layer (“\(layer.name)”)")
        }
    }
}

private struct LayerRow: View {
    @Bindable var doc: Document
    let layer: Layer
    @Binding var renaming: Layer.ID?
    @State private var name = ""
    @State private var over = false
    @FocusState private var editing: Bool

    var body: some View {
        let active = layer.id == doc.activeLayer
        let hasSelection = doc.objects(of: layer).contains { doc.selection.contains($0.id) }
        HStack(spacing: 4) {
            IconButton(icon: layer.visible ? .eye : .eyeClosed, tip: layer.visible ? "Hide layer" : "Show layer",
                       erased: !layer.visible) {
                doc.modifyLayer(layer.id) { $0.visible.toggle() }
            }
            IconButton(icon: layer.locked ? .lock : .lockOpen, tip: layer.locked ? "Unlock layer" : "Lock layer",
                       erased: !layer.locked) {
                doc.modifyLayer(layer.id) { $0.locked.toggle() }
            }
            RoundedRectangle(cornerRadius: 1.5)
                .fill(layer.barColor)
                .frame(width: 3, height: 16)
            Button {
                // Opening and closing isn't an edit (it doesn't go into undo).
                if let i = doc.layers.firstIndex(where: { $0.id == layer.id }) { doc.layers[i].isOpen.toggle() }
            } label: {
                Image(.expandSection)
                    .resizable()
                    .frame(width: 10, height: 10)
                    .rotationEffect(.degrees(layer.isOpen ? 90 : 0))
                    .frame(width: 14, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            if renaming == layer.id {
                TextField("Name", text: $name)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .focused($editing)
                    .onSubmit(finishName)
                    .onChange(of: editing) { _, focus in if !focus { finishName() } }
                    .onAppear {
                        name = layer.name
                        editing = true
                    }
            } else {
                Text(layer.name)
                    .fontWeight(active ? .semibold : .regular)
                    .lineLimit(1)
                    .opacity(layer.visible ? 1 : 0.4)
                    .onTapGesture(count: 2) { renaming = layer.id }
                    .help("Double-click to rename")
            }
            Spacer(minLength: 4)
            if !layer.isPlain {
                // Opacity or a blending mode: what the layer prints mixes with what is under it.
                HStack(spacing: 2) {
                    Image(.blendMode).resizable().frame(width: 11, height: 11)
                    if layer.opacity != nil { Text(verbatim: "\(Int(layer.alpha * 100))%").font(.caption2).monospacedDigit() }
                }
                .foregroundStyle(.secondary)
                .help(String(localized: "\((layer.blend ?? .normal).name) · \(Int(layer.alpha * 100)) % opacity"))
            }
            if hasSelection {
                RoundedRectangle(cornerRadius: 1.5).fill(layer.barColor).frame(width: 7, height: 7)
            }
            Button {
                doc.selectLayer(layer)
            } label: {
                Circle()
                    .strokeBorder(.secondary, lineWidth: 1.5)
                    .background(Circle().fill(hasSelection ? Color.secondary : .clear).padding(2.5))
                    .frame(width: 11, height: 11)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Select everything in the layer")
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(active ? Color.primary.opacity(0.08) : (over ? Color.primary.opacity(0.04) : .clear), in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture { doc.activeLayer = layer.id }
        .onHover { over = $0 }
    }

    private func finishName() {
        guard renaming == layer.id else { return }
        let updated = name.trimmingCharacters(in: .whitespaces)
        if !updated.isEmpty, updated != layer.name { doc.modifyLayer(layer.id) { $0.name = updated } }
        renaming = nil
    }
}

private struct ObjectRow: View {
    @Bindable var doc: Document
    let object: CanvasObject
    let layer: Layer
    @State private var over = false

    var body: some View {
        let isSelected = doc.selection.contains(object.id)
        HStack(spacing: 4) {
            IconButton(icon: object.isHidden ? .eyeClosed : .eye, tip: object.isHidden ? "Show" : "Hide", erased: object.isHidden) {
                doc.modifyObject(object.id) { $0.isHidden.toggle() }
            }
            IconButton(icon: object.isLocked ? .lock : .lockOpen, tip: object.isLocked ? "Unlock" : "Lock",
                       erased: !object.isLocked) {
                doc.modifyObject(object.id) { $0.isLocked.toggle() }
            }
            // Objects of a group a little indented (one step per group).
            Color.clear.frame(width: 21 + 12 * Double(object.groups.count))
            swatch
            Text(object.name)
                .fontWeight(isSelected ? .semibold : .regular)
                .lineLimit(1)
                .opacity(doc.visible(object) ? 1 : 0.4)
            if !object.cutsLine {
                Image(.noCut)
                    .resizable()
                    .frame(width: 12, height: 12)
                    .foregroundStyle(.secondary)
                    .help("No stroke: not sent to the machine")
            }
            Spacer(minLength: 4)
            Text("\(Int(object.frame.width.rounded())) × \(Int(object.frame.height.rounded()))")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(isSelected ? layer.barColor : .clear)
                .frame(width: 7, height: 7)
                .frame(width: 18)
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(isSelected ? Color.accentColor.opacity(0.18) : (over ? Color.primary.opacity(0.04) : .clear),
                    in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture {
            guard !doc.untouchable(object) else { return }
            if NSEvent.modifierFlags.contains(.shift) {
                doc.selection.formSymmetricDifference([object.id])
            } else {
                doc.selection = [object.id]
            }
            doc.activeLayer = layer.id
        }
        .onHover { over = $0 }
    }

    /// Fill inside and stroke as a frame (as in the prototype); image = gray.
    private var swatch: some View {
        let shape = Rectangle()
        return ZStack {
            if object.image != nil {
                shape.fill(.gray.opacity(0.35))
            } else if let gradient = object.gradient, object.fill != nil {
                GradientSwatch(gradient: gradient, colors: doc.colors, shape: shape)
            } else if let fill = object.fill {
                shape.fill(doc.colors.color(fill))
            }
            if object.cutsLine { shape.strokeBorder(doc.colors.color(object.strokeColor), lineWidth: 2) }
        }
        .frame(width: 12, height: 12)
        .overlay(shape.strokeBorder(.primary.opacity(0.25), lineWidth: 0.5))
    }
}

/// Small icon button of the layer rows (eye, lock).
private struct IconButton: View {
    let icon: ImageResource
    let tip: LocalizedStringKey
    let erased: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(icon)
                .resizable()
                .frame(width: 13, height: 13)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(erased ? 0.45 : 1)
        .help(tip)
    }
}
