// Control bar: strip under the toolbar and above the tabs (a title bar accessory), like Silhouette Studio's
// settings bar and Illustrator's control bar.
import AppKit
import SwiftUI

/// Zoom and page position. Lives in an observable object because the control bar is outside the
/// window hierarchy (in the title bar accessory) and also changes the zoom.
@Observable
final class ViewControl {
    var viewState = ViewState()
    /// Canvas area without the floating pieces, where the page fits.
    var freeArea = CGRect.zero
    /// The active artboard and all of them (canvas mm): what Fit in Window and Fit All in Window show (the window keeps
    /// them).
    var activeArtboard = CGRect(origin: .zero, size: PagePreset.a4.size)
    var allArtboards = CGRect(origin: .zero, size: PagePreset.a4.size)

    /// Fit in Window (⌘0): the active artboard.
    func adjust() { viewState.adjust(in: freeArea, page: activeArtboard) }

    /// Fit All in Window (⌥⌘0): every artboard (doesn't keep refitting when the window changes).
    func adjustAll() { viewState.adjust(in: freeArea, page: allArtboards, refits: false) }

    func zoom(_ factor: Double) { setZoom(viewState.zoom * factor) }

    func setZoom(_ zoom: Double) {
        viewState.zoomIn(to: zoom, anchor: CGPoint(x: freeArea.midX, y: freeArea.midY))
    }
}

extension FocusedValues {
    /// For the View menu's zoom commands.
    @Entry var viewControl: ViewControl?
}

/// Fixed undo/redo and zoom; name, stroke (style and width), position and size (reference point,
/// X/Y/W/H in mm, lock), shape parameters and selection alignment (one object: to the sheet; several: to the
/// selection) — without a selection, the stroke is the one for the next objects; on the right snap, rulers and Print & Cut marks.
struct ControlBar: View {
    @Bindable var doc: Document
    let control: ViewControl
    /// Reference point for X/Y and where the size grows from (0, 0.5 or 1 on each axis).
    @AppStorage("referenciaX") private var referenceX = 0.0
    @AppStorage("referenciaY") private var referenceY = 0.0
    @AppStorage("travaProporcao") private var lockAspect = false
    @AppStorage("reguas") private var rulersOn = true
    @AppStorage("snap") private var snapOn = true
    @AppStorage(LengthUnit.key) private var unit = LengthUnit.mm

    static let height = 32.0

    /// To put the bar between the toolbar and the tabs (SwiftUI has no title bar accessories).
    static func install(in nsWindow: NSWindow, doc: Document, control: ViewControl) {
        let id = NSUserInterfaceItemIdentifier("barraControle")
        guard !nsWindow.titlebarAccessoryViewControllers.contains(where: { $0.identifier == id }) else { return }
        let host = NSHostingView(rootView: ControlBar(doc: doc, control: control))
        host.sizingOptions = []
        host.frame.size = CGSize(width: nsWindow.frame.width, height: height)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.identifier = id
        accessory.view = host
        accessory.layoutAttribute = .bottom
        accessory.isHidden = !(UserDefaults.standard.object(forKey: "barraControleVisivel") as? Bool ?? true)
        nsWindow.addTitlebarAccessoryViewController(accessory)
    }

    /// Window › Control Bar.
    static func display(_ visible: Bool, in nsWindow: NSWindow) {
        nsWindow.titlebarAccessoryViewControllers.first { $0.identifier == NSUserInterfaceItemIdentifier("barraControle") }?
            .isHidden = !visible
    }

    var body: some View {
        HStack(spacing: 8) {
            historyAndZoom
            separator
            if doc.tool == .artboard {
                // The Artboard tool's bar, as in Illustrator: the active artboard's name, size and orientation.
                ViewThatFits(in: .horizontal) {
                    ArtboardBar(doc: doc)
                    ScrollView(.horizontal, showsIndicators: false) { ArtboardBar(doc: doc) }
                }
            } else {
                // Without room, the alignments become a menu (as in Illustrator); in a very narrow window, the
                // selection part scrolls sideways instead of squeezing the fields.
                ViewThatFits(in: .horizontal) {
                    selection(alignInMenu: false)
                    selection(alignInMenu: true)
                    ScrollView(.horizontal, showsIndicators: false) { selection(alignInMenu: true) }
                }
            }
            separator
            helpers
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        // Darker than the toolbar (as in the sketch and in Final Cut), with a hairline above and below.
        .background(Self.background)
        .overlay(alignment: .top) { Self.hairline.frame(height: 1) }
        .overlay(alignment: .bottom) { Self.hairline.frame(height: 1) }
    }

    /// Dark: #1D1D1D from the sketch; light: a gray close to the canvas's.
    private static let background = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.114, alpha: 1) : NSColor(white: 0.9, alpha: 1)
    })
    private static let hairline = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : NSColor(white: 0.78, alpha: 1)
    })

    private var separator: some View { Divider().frame(height: 16) }

    // MARK: Fixed

    private var historyAndZoom: some View {
        HStack(spacing: 2) {
            action("Undo (⌘Z)", .undo) { doc.undo() }
                .disabled(!doc.canUndo)
            action("Redo (⇧⌘Z)", .redo) { doc.redo() }
                .disabled(!doc.canRedo)
            separator.padding(.horizontal, 6)
            action("Zoom Out (⌘−)", .zoomOut) { control.zoom(1 / 1.25) }
            Menu {
                ForEach([0.5, 1, 2, 4], id: \.self) { z in
                    Button("\(Int(z * 100))%") { control.setZoom(z) }
                }
                Divider()
                Button("Fit in Window") { control.adjust() }
                Button("Fit All in Window") { control.adjustAll() }
                    .disabled(doc.artboards.count < 2)
            } label: {
                Text("\(Int((control.viewState.zoom * 100).rounded()))%").monospacedDigit()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(minWidth: 44)
            .help("Zoom")
            action("Zoom In (⌘+)", .zoomIn) { control.zoom(1.25) }
            action("Fit in Window (⌘0)", .fitWindow) { control.adjust() }
        }
    }

    private var helpers: some View {
        HStack(spacing: 2) {
            toggle("Snap: snap to points, the artboard and guides (⌘;)", .snap, enabled: snapOn) {
                snapOn.toggle()
            }
            toggle("Rulers and guides (⌘R) — drag from a ruler to create a guide", .rulers, enabled: rulersOn) {
                rulersOn.toggle()
            }
            toggle("Registration marks (Print & Cut): print with them and the machine reads them before cutting",
                     .registrationMarks, enabled: doc.marks) { doc.toggleMarks() }
        }
    }

    private func action(_ tip: LocalizedStringKey, _ icon: ImageResource, execute: @escaping () -> Void) -> some View {
        Button(action: execute) {
            Image(icon).resizable().frame(width: 18, height: 18).frame(width: 28, height: 26)
        }
        .buttonStyle(.borderless)
        .help(tip)
    }

    /// Toggle button: lit in the accent color, like the proportion lock.
    private func toggle(_ tip: LocalizedStringKey, _ icon: ImageResource, enabled: Bool, change: @escaping () -> Void) -> some View {
        Button(action: change) {
            Image(icon)
                .resizable()
                .frame(width: 18, height: 18)
                .foregroundStyle(enabled ? Color.accentColor : .secondary)
                .frame(width: 28, height: 26)
                .background(enabled ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    // MARK: Selection

    private func selection(alignInMenu: Bool) -> some View {
        HStack(spacing: 8) {
            let selectedObjects = doc.selectedObjects
            if selectedObjects.isEmpty {
                Text("Nothing selected").foregroundStyle(.secondary)
            } else {
                Group {
                    if selectedObjects.count == 1 { Text(selectedObjects[0].name) } else if doc.selectionIsAGroup { Text("selection.group") } else {
                        Text("\(selectedObjects.count) objects")
                    }
                }
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            strokeColor
            separator
            if let box = doc.selectionFrame {
                ReferenceGrid(x: $referenceX, y: $referenceY)
                positionAndSize(box)
                if let object = selectedObjects.first, selectedObjects.count == 1 {
                    parameters(object)
                    // An image inside the shape: its fitting, scale and opacity (Editor/ImageInsideShape.swift).
                    if let fitting = object.imageFit, object.image != nil {
                        separator
                        ImageFitBar(doc: doc, fitting: fitting, id: object.id)
                    }
                    if object.isParametric {
                        Button("→ Path") { doc.convertToPath() }
                            .controlSize(.small)
                            .help("Convert to a path to edit its points (direct selection)")
                    }
                }
            } else {
                let artboard = doc.activeArtboard
                Text(verbatim: [artboard.title(doc.activeIndex), artboard.preset?.name, unit.text(artboard.size)].compactMap(\.self)
                    .joined(separator: " · "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("The active artboard (click another one to make it active; ⇧O edits them)")
            }
            separator
            // A group aligns to the sheet, like a single object.
            let pieces = doc.selectedPieces.count
            if alignInMenu { alignMenu(pieces) } else { alignments(pieces) }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func alignMenu(_ howMany: Int) -> some View {
        Menu {
            ForEach(AlignMode.allCases) { mode in
                Button { doc.align(mode) } label: { Label("Align \(mode.name)", image: mode.icon) }
            }
            Divider()
            ForEach(SpacingAxis.allCases) { axis in
                Button { doc.distribute(axis) } label: { Label(axis.name, image: axis.icon) }
                    .disabled(howMany < 3)
            }
        } label: {
            Label("Align", image: AlignMode.centerH.icon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(howMany == 0)
        .help(howMany > 1 ? "Align to the selection" as LocalizedStringKey : "Align to the sheet")
    }

    /// Stroke style (solid or dashed) and width, as in Studio's bar.
    private var strokeColor: some View {
        let style = doc.currentStyle
        let strokeWidth = doc.selectedObjects.first?.strokeWidth ?? doc.defaultStrokeWidth
        return HStack(spacing: 6) {
            Menu {
                Picker("Style", selection: Binding(get: { style.line }, set: { newOne in doc.setStyle { $0.line = newOne } })) {
                    ForEach(LineStyle.allCases) { e in
                        Label { Text(e.name) } icon: { Image(nsImage: Icons.line(e)) }.tag(e)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Image(nsImage: Icons.line(style.line, width: 44))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .help(style.line == .solid ? "Solid stroke" as LocalizedStringKey : "Dashed stroke: the cut is perforated")
            field(nil, strokeWidth, minimum: 0, maximum: 100, unit: "pt", width: 34) { doc.setStrokeWidth($0) }
                .help(strokeWidth > 0 ? "Weight: this stroke will also be printed" as LocalizedStringKey
                      : "Weight: 0 pt shows on screen, doesn’t print and marks the cut")
        }
    }

    /// X and Y of the reference point, W and H of the selection's box (turned with the objects when they share an angle:
    /// the size along their own sides) and its angle.
    private func positionAndSize(_ turnedBox: RotatedBox) -> some View {
        let box = turnedBox.rect
        let reference = turnedBox.point(referenceX, referenceY)
        return HStack(spacing: 6) {
            // X and Y from the active artboard's top-left corner, like the rulers (as in Illustrator).
            let zero = doc.activeArtboard.rect.origin
            field("X", reference.x - zero.x, length: true, unit: "") { v in
                if turnedBox.angle == 0 {
                    doc.fitSelection(to: box.offsetBy(dx: v + zero.x - (box.minX + box.width * referenceX), dy: 0))
                } else {
                    doc.translateSelection(dx: v + zero.x - reference.x, dy: 0)
                }
            }
            field("Y", reference.y - zero.y, length: true, unit: "") { v in
                if turnedBox.angle == 0 {
                    doc.fitSelection(to: box.offsetBy(dx: 0, dy: v + zero.y - (box.minY + box.height * referenceY)))
                } else {
                    doc.translateSelection(dx: 0, dy: v + zero.y - reference.y)
                }
            }
            field("W", box.width, minimum: 0.1, length: true, unit: "") { v in
                resize(turnedBox, width: v, height: lockAspect ? box.height * v / max(box.width, 0.001) : box.height)
            }
            Button {
                lockAspect.toggle()
            } label: {
                Image(.aspectRatio)
                    .resizable()
                    .frame(width: 17, height: 17)
                    .foregroundStyle(lockAspect ? Color.accentColor : .secondary)
                    .frame(width: 24, height: 24)
                    .background(lockAspect ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(lockAspect ? "Proportions locked" as LocalizedStringKey : "Keep proportions")
            field("H", box.height, minimum: 0.1, length: true, unit: "") { v in
                resize(turnedBox, width: lockAspect ? box.width * v / max(box.height, 0.001) : box.width, height: v)
            }
            Text(verbatim: unit.symbol).foregroundStyle(.secondary).fixedSize()
            // The angle, as Illustrator's: typing one turns the selection around the reference point.
            HStack(spacing: 4) {
                Image("toolRotate").resizable().frame(width: 15, height: 15).foregroundStyle(.secondary)
                field(nil, turnedBox.angle, minimum: -360, maximum: 360, unit: "°", width: 40) { v in
                    doc.rotateSelection(by: CanvasObject.normalizedAngle(v - turnedBox.angle), around: reference)
                }
            }
            .help("Angle: turns the selection around the reference point")
        }
    }

    private func alignments(_ howMany: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(AlignMode.allCases) { mode in
                Button {
                    doc.align(mode)
                } label: {
                    Image(mode.icon)
                        .resizable()
                        .frame(width: 18, height: 18)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(howMany == 0)
                .opacity(howMany == 0 ? 0.35 : 1)
                .help(howMany == 1 ? "Align \(mode.name) to the sheet" as LocalizedStringKey
                      : howMany > 1 ? "Align \(mode.name) to the selection" : "Align \(mode.name)")
            }
            Divider().frame(height: 16).padding(.horizontal, 4)
            // Space: equal gaps between 3 or more pieces (Studio's Space Horizontally/Vertically).
            ForEach(SpacingAxis.allCases) { axis in
                Button {
                    doc.distribute(axis)
                } label: {
                    Image(axis.icon)
                        .resizable()
                        .frame(width: 18, height: 18)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(howMany < 3)
                .opacity(howMany < 3 ? 0.35 : 1)
                .help("\(axis.name): equal gaps between 3 or more objects")
            }
        }
    }

    /// New size anchored to the reference point (along the box's own sides when it is turned).
    private func resize(_ turnedBox: RotatedBox, width: Double, height: Double) {
        let box = turnedBox.rect
        let l = max(width, 0.1), a = max(height, 0.1)
        let newRect = CGRect(x: box.minX + (box.width - l) * referenceX, y: box.minY + (box.height - a) * referenceY, width: l, height: a)
        if turnedBox.angle == 0, !doc.selectedObjects.contains(where: { $0.rotation != 0 }) {
            doc.fitSelection(to: newRect)
        } else {
            doc.fitSelection(turnedBox, to: newRect)
        }
    }

    @ViewBuilder
    private func parameters(_ object: CanvasObject) -> some View {
        if let sides = object.polygonSides {
            field("Sides", Double(sides), minimum: Double(PolygonShape.sideRange.lowerBound),
                  maximum: Double(PolygonShape.sideRange.upperBound), unit: "") { v in
                doc.modifySelection { $0.setPolygon(sides: Int(v.rounded())) }
            }
        } else {
            shapeParameters(object)
        }
    }

    @ViewBuilder
    private func shapeParameters(_ object: CanvasObject) -> some View {
        switch object.shape {
        case .rectangle(let radius):
            field("Radius", radius, minimum: 0, length: true) { v in doc.modifySelection { $0.shape = .rectangle(radius: v) } }
        case .star(let points, let inner):
            field("Points", Double(points), minimum: 3, maximum: 40, unit: "") { v in
                doc.modifySelection { $0.shape = .star(points: Int(v.rounded()), innerRadius: inner) }
            }
            field("Inner radius", inner * 100, minimum: 5, maximum: 100, unit: "%") { v in
                doc.modifySelection { $0.shape = .star(points: points, innerRadius: v / 100) }
            }
        case .text:
            TextFields(doc: doc)
            if object.textPath != nil {
                Button("Path Options…") { doc.pathTextOptionsOpen = true }
                    .controlSize(.small)
                    .help("Type on a Path Options: effect, alignment to the path, spacing, flip")
            }
        case .shapePath(let subs):
            let pointsList = subs.reduce(0) { $0 + $1.nodes.count }, opened = subs.contains { !$0.closed }
            Text(opened ? "\(pointsList) points · open" as LocalizedStringKey : "\(pointsList) points · closed").foregroundStyle(.secondary)
            if opened {
                Button("Close") { doc.closePaths() }
                    .controlSize(.small)
            }
            SmoothButton(doc: doc)
        case .ellipse:
            EmptyView()
        }
    }

    /// Numeric field: applies on confirm (Enter or leaving the field), as in Illustrator. A `length` is in mm and shows
    /// in the Settings unit (with its symbol, unless `unit` says otherwise).
    private func field(_ label: LocalizedStringKey?, _ value: Double, minimum: Double = -10_000, maximum: Double = 10_000,
                       length: Bool = false, unit symbol: String? = nil, width: Double = 42, apply: @escaping (Double) -> Void) -> some View {
        let factor = length ? unit.mmPer : 1
        return HStack(spacing: 4) {
            if let label { Text(label).foregroundStyle(.secondary).fixedSize() }
            // The field confirms the value again on losing focus: it only applies (and registers the undo) if it changed.
            TextField(label ?? "", value: Binding(get: { value / factor }, set: { updated in
                let v = min(max(updated * factor, minimum), maximum)
                if abs(v - value) > 1e-9 { apply(v) }
            }),
                      format: .number.precision(.fractionLength(0...(length ? unit.fractionDigits : 2))))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: width)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            let shown = symbol ?? (length ? unit.symbol : "")
            if !shown.isEmpty { Text(verbatim: shown).foregroundStyle(.secondary).fixedSize() }
        }
    }
}

/// Font, style and size (the text itself is typed on the canvas; the rest is in the Character panel). While typing,
/// they apply to the selected letters, as in the panel.
private struct TextFields: View {
    @Bindable var doc: Document

    var body: some View {
        let style = doc.textStyle
        HStack(spacing: 8) {
            FontButton(doc: doc, style: style, compact: true)
                .frame(width: 150)
            StyleMenu(doc: doc, style: style, compact: true)
                .frame(width: 110)
            HStack(spacing: 5) {
                TextField("Size", value: Binding(get: { style.size }, set: { updated in
                    let v = min(max(updated, 1), 1000)
                    if v != style.size { doc.changeStyle { $0.size = v } }
                }), format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 40)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .onSubmit { doc.returnFocusToText() }
                Text("pt").foregroundStyle(.secondary).fixedSize()
            }
        }
    }
}

/// 3 × 3 reference point (as in Illustrator): where X/Y count from and where the size grows to.
private struct ReferenceGrid: View {
    @Binding var x: Double
    @Binding var y: Double

    var body: some View {
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            ForEach([0.0, 0.5, 1.0], id: \.self) { fy in
                GridRow {
                    ForEach([0.0, 0.5, 1.0], id: \.self) { fx in
                        let isActive = x == fx && y == fy
                        Rectangle()
                            .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.35))
                            .frame(width: 5, height: 5)
                            .padding(1)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                x = fx
                                y = fy
                            }
                    }
                }
            }
        }
        .help("Reference point")
    }
}

/// Smooth… (a path selected): the nodes round off like the Trace window's smoothing, live, from how the paths were when
/// it opened (0 % = all corners — a polyline, as after tracing with 0 %; 100 % = all smooth).
private struct SmoothButton: View {
    @Bindable var doc: Document
    @State private var open = false
    @State private var smoothing = 50.0
    @State private var originals: [CanvasObject.ID: [Subpath]] = [:]

    var body: some View {
        Button("Smooth…") {
            originals = doc.pathsToSmooth
            open = true
        }
        .controlSize(.small)
        .help("Round off the nodes of the selected paths")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Smoothing")
                    Spacer()
                    Text(verbatim: "\(Int(smoothing.rounded())) %").monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { smoothing }, set: {
                    smoothing = $0.rounded()
                    doc.smoothNodes(smoothing, from: originals)
                }), in: 0...100)
                Text("How sharp a turn can be and still become a smooth node. The nodes stay where they are.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(width: 260)
        }
    }
}
