// Send window (Silhouette Studio style): sheet preview, machine, "cut by line color"
// and the chosen color's settings (horizontal sliders).
import AppKit
import CutlineKit
import SwiftUI
import UniformTypeIdentifiers

struct SendWindow: View {
    @Bindable var doc: Document
    @Environment(Machine.self) private var machine
    @Environment(\.dismiss) private var close
    @State private var chosenColor: CMYK?
    @State private var materialName = ""
    @State private var savingMaterial = false
    @State private var deletingMaterial = false
    /// This document's job where the machine didn't find the marks (opens the tips window).
    @State private var marksNotice: Job?
    /// Color being dragged in the table (to change the cut order).
    @State private var dragging: CMYK?
    private var global: GlobalSettings { .shared }

    private var marksNotRead: Job? {
        machine.queue.first { $0.origin == ObjectIdentifier(doc) && $0.status == .marksNotFound }
    }

    /// This document's last send (the footer shows how it is going).
    private var lastSend: Job? { machine.queue.last { $0.origin == ObjectIdentifier(doc) } }

    var body: some View {
        let lines = doc.cutLines
        let current = lines.first { $0.color == chosenColor } ?? lines.first
        HStack(spacing: 0) {
            SheetPreview(doc: doc, lines: lines, highlight: current?.color)
                .padding(28)
                .frame(width: 380)
                .frame(maxHeight: .infinity)
                .background(.black.opacity(0.06))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    StudioNotice()
                    MachineCard(withMat: doc.withMat, base: doc.base(to: machine.hardware))
                    if !machine.queue.isEmpty { QueueList() }
                    table(lines, current: current?.color)
                    if doc.marks { printAndCut }
                    if let current { detail(current) }
                }
                .padding(20)
            }
        }
        .overlay(alignment: .topLeading) {
            Button("Close", image: .close) { close() }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
                .help("Close")
                .padding(12)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer(lines, current: current?.color) }
        .frame(width: 1000, height: 680)
        .task {
            if case .disconnected = machine.state { await machine.connect() }
            if case .failure = machine.state { await machine.connect() }
            #if DEBUG
            // CUTLINE_TEST_TOOL=2:foil: the first color goes to holder 2 with that tool (raw value or case name). Only in
            // the document: `setConfig` would also remember it in the app's settings, which are the owner's.
            if let (holder, tool) = DebugHooks.testTool, let first = doc.cutLines.first {
                var config = doc.config(first.color)
                config.holder = holder
                config.tool = tool
                doc.cuts[first.color] = config
            }
            // CUTLINE_TEST_SEND=1 (only with the simulated machine): sends by itself, without pinning the settings in the file.
            if DebugHooks.sendForTest { machine.enqueue(doc.job(name: "Teste")) }
            // CUTLINE_TEST_TEST_SHAPE=x,y[,side]: turns on the test shape at x,y mm (and that size).
            if let (target, side) = DebugHooks.testShape {
                doc.testShape = true
                if let side { doc.resizeTest(to: side) }
                doc.moveTest(to: target)
            }
            // CUTLINE_TEST_TEST_CUT=x,y[,side] (with CUTLINE_SIMULATE): the same, and sends the test cut.
            if let (target, side) = DebugHooks.testCut, let color = doc.cutLines.first?.color {
                doc.testShape = true
                if let side { doc.resizeTest(to: side) }
                doc.moveTest(to: target)
                machine.enqueue(doc.testJob(color))
            }
            // CUTLINE_TEST_ORDER=1: the last color goes to the top, the same way as dragging.
            if ProcessInfo.processInfo.environment["CUTLINE_TEST_ORDER"] != nil, let last = doc.cutLines.last {
                doc.moveLine(last.color, to: 0)
            }
            #endif
        }
        .onChange(of: marksNotRead?.id, initial: true) { _, updated in if updated != nil { marksNotice = marksNotRead } }
        .sheet(item: $marksNotice) { MarksWindow(job: $0) }
    }

    // MARK: Table by color

    private func table(_ lines: [CutLine], current: CMYK?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cut by line color").font(.headline)
            if lines.count > 1 {
                Text("The machine cuts from top to bottom. Drag a color (or use the arrows) to change the order.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    tableRow(line, index: index, total: lines.count, chosen: line.color == current)
                        // Dragging the whole row changes the order right away, while it passes over the others.
                        .onDrag {
                            dragging = line.color
                            return NSItemProvider(object: line.color.summaryText as NSString)
                        }
                        .onDrop(of: [.text], delegate: ColorDrop(color: line.color, doc: doc, dragging: $dragging))
                }
            }
        }
    }

    private func tableRow(_ line: CutLine, index: Int, total: Int, chosen: Bool) -> some View {
        let config = doc.config(line.color)
        return HStack(spacing: 10) {
            Image(.dragHandle)
                .foregroundStyle(.tertiary)
                .opacity(total > 1 ? 1 : 0)
                .help("Drag to change the cutting order")
            Toggle("On", isOn: link(line.color).enabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
            Text("\(index + 1)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 14)
            RoundedRectangle(cornerRadius: 4)
                .fill(line.color.color)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.15)))
                .frame(width: 26, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(Material.show(config.material))
                Text(verbatim: [String(localized: "\(line.objects.count) objects"),
                                config.enabled ? nil : String(localized: "doesn't cut"), config.modified ? String(localized: "modified") : nil].compactMap(\.self).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .opacity(config.sends ? 1 : 0.45)
            Spacer()
            HStack(spacing: 2) {
                Button("Cut Earlier", image: .arrowUp) { doc.moveLine(line.color, upward: true) }
                    .disabled(index == 0)
                Button("Cut Later", image: .arrowDown) { doc.moveLine(line.color, upward: false) }
                    .disabled(index == total - 1)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(chosen ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture { chosenColor = line.color }
    }

    // MARK: Print & Cut

    /// Print & Cut reminder and notice of cuts that go past the area between the marks.
    private var printAndCut: some View {
        let outside = doc.objectsOutsideMarks
        return VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("**Print & Cut:** print the page at 100% (⌘P) and place the sheet on the mat in the same position as on screen, with the square in the top-left corner. The machine reads the marks before cutting (up to 40 s).")
            } icon: {
                Image(.registrationMarks)
            }
            Text(marksDescription)
                .foregroundStyle(.secondary)
            if outside > 0 {
                Label("\(outside) objects go past the area between the marks — whatever is outside isn’t cut.", image: .warning)
                    .foregroundStyle(.orange)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Where the machine will look for the marks (it must be where the sheet was printed).
    private var marksDescription: String {
        let c = doc.marksConfig, unit = LengthUnit.current
        let length = { (v: Double) in unit.text(v) }
        let margin = c.margin.map { String(localized: "\(length($0)) from the edge") }
            ?? String(localized: "margins of \(length(c.left)), \(length(c.top)), \(length(c.right)) and \(length(c.bottom))")
        return String(localized: "Marks \(margin), \(length(c.length)) corner marks. Change them in the Page panel.")
    }

    // MARK: Chosen color detail

    private func detail(_ line: CutLine) -> some View {
        let color = line.color
        let config = doc.config(color)
        let defaultValue = config.materialValues ?? config.settings
        let settings = link(color).settings
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Picker("Material", selection: Binding(
                    get: { config.material },
                    set: { name in
                        guard let material = global.material(name) else { return }
                        var newOne = config
                        newOne.material = name
                        newOne.settings = material.settings
                        doc.setConfig(newOne, to: color)
                    })) {
                    ForEach(Material.all) { Text(Material.show($0.name)).tag($0.name) }
                    if !global.materials.isEmpty {
                        Divider()
                        Section("My Materials") {
                            ForEach(global.materials) { Text($0.name).tag($0.name) }
                        }
                    }
                    // A material that came with the file and doesn't exist on this Mac: still shows.
                    if global.material(config.material) == nil {
                        Divider()
                        Text("\(config.material) (from file)").tag(config.material)
                    }
                }
                materialMenu(config, color: color)
            }
            ToolChoice(doc: doc, color: color)

            HStack(spacing: 6) {
                Text("Settings").fontWeight(.semibold)
                Text(config.modified ? "· modified" : global.material(config.material) == nil ? "· from file" : "· from material")
                    .foregroundStyle(.secondary)
                if config.modified {
                    Button("Revert") {
                        var newOne = config
                        newOne.settings = defaultValue
                        doc.setConfig(newOne, to: color)
                    }
                    .buttonStyle(.link)
                }
            }

            // One row per setting (compact horizontal slider).
            VStack(spacing: 10) {
                SettingsEditor(title: "Force", unit: "pressure", span: CutSettings.forceRange, value: settings.force,
                       defaultValue: defaultValue.force) { Image(.force).resizable().scaledToFit() }
                SettingsEditor(title: "Speed", unit: "cm/s", span: 1...machine.maxSpeed, value: settings.speed,
                       defaultValue: defaultValue.speed) { Image(.speed).resizable().scaledToFit() }
                SettingsEditor(title: "Blade", unit: "depth", span: CutSettings.bladeRange, value: settings.blade,
                       defaultValue: defaultValue.blade) { Image(.blade).resizable().scaledToFit() }
                    // Pen, foil, emboss and Heat Pen have no blade depth (the driver doesn't send it).
                    .disabled(config.tool != .blade)
                    .opacity(config.tool != .blade ? 0.35 : 1)
                    .overlay {
                        if config.tool != .blade {
                            Text("Not used with \(config.tool.name)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.background, in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
                        }
                    }
                SettingsEditor(title: "Passes", unit: "repeats", span: CutSettings.passesRange, value: settings.passes,
                       defaultValue: defaultValue.passes) { Image(.passes).resizable().scaledToFit() }
            }
            .padding(.vertical, 4)
            .disabled(!config.sends)
            .opacity(config.sends ? 1 : 0.4)

            if config.tool != .blade {
                Label {
                    Text("Pen, foil, emboss and Heat Pen usually go before the blade (drag this color up), so the piece doesn’t come loose first.")
                } icon: {
                    Image(.info).resizable().scaledToFit().frame(width: 13, height: 13)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Text("Saved in this file and remembered by the app for this color in future files.")
                .font(.caption)
                .foregroundStyle(.secondary)

            let (mm, seconds) = estimate(line, config.settings)
            HStack(spacing: 14) {
                Text("**\(mm / 10, format: .number.precision(.fractionLength(1))) cm** of cutting")
                if config.settings.passes > 1 {
                    Text("≈ \(Text(tempo(seconds)).fontWeight(.semibold)) in \(config.settings.passes) passes")
                } else {
                    Text("≈ \(Text(tempo(seconds)).fontWeight(.semibold))")
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    /// Save the settings as your own material, update or delete one of "My materials".
    private func materialMenu(_ config: CutConfig, color: CMYK) -> some View {
        let own = global.isUserMaterial(config.material)
        return Menu {
            Button("Save Settings as Material…") {
                materialName = ""
                savingMaterial = true
            }
            if own {
                Button("Update “\(config.material)” with These Settings") {
                    global.saveMaterial(config.material, settings: config.settings)
                }
                .disabled(!config.modified)
                Divider()
                Button("Delete “\(config.material)”…", role: .destructive) { deletingMaterial = true }
            }
        } label: {
            Image(.plus)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("My Materials")
        .alert("Save as Material", isPresented: $savingMaterial) {
            TextField("Material name", text: $materialName)
            Button("Save") {
                let name = materialName.trimmingCharacters(in: .whitespaces)
                guard global.saveMaterial(name, settings: config.settings) else { return }
                var newOne = config
                newOne.material = name
                doc.setConfig(newOne, to: color)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Force \(config.settings.force), speed \(config.settings.speed), blade \(config.settings.blade), \(String(localized: "\(config.settings.passes) passes")). Available in every file.")
        }
        .confirmationDialog("Delete “\(config.material)” from My Materials?", isPresented: $deletingMaterial) {
            Button("Delete", role: .destructive) { global.deleteMaterial(config.material) }
        } message: {
            Text("Files that use this material keep the settings saved in them.")
        }
    }

    // MARK: Footer

    private func footer(_ lines: [CutLine], current: CMYK?) -> some View {
        let layers = doc.layersToSend
        let seconds = lines.reduce(0.0) { total, line in
            let config = doc.config(line.color)
            return config.sends ? total + estimate(line, config.settings).1 : total
        }
        return HStack(spacing: 14) {
            status
            Spacer()
            if !layers.isEmpty {
                Text(verbatim: String(localized: "\(layers.count) colors") + " · ≈ " + tempo(seconds))
                    .foregroundStyle(.secondary)
            }
            testControls
            Button("Test Cut") {
                if let current { machine.enqueue(doc.testJob(current)) }
            }
            .controlSize(.large)
            .disabled(current == nil || machine.studioOpen || !doc.testShape)
            .help(!doc.testShape ? "Turn on Test Shape to place the test on the sheet" as LocalizedStringKey
                  : current.map { "Cuts only the square with the C, where it is marked on the sheet, with the settings of \(Material.show(doc.config($0).material))" as LocalizedStringKey }
                  ?? "Cuts only the square with the C, where it is marked on the sheet")
            Button {
                // Goes into the queue: if the machine is busy, it cuts when the previous one is done.
                doc.pinSendSettings()
                let nsWindow = NSApp.keyWindow.map { $0.sheetParent ?? $0 }
                machine.enqueue(doc.job(name: nsWindow?.title ?? String(localized: "Untitled")))
            } label: {
                Label("Send", image: .needle)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(layers.isEmpty || machine.studioOpen)
            .help(machine.studioOpen ? "Close Silhouette Studio to send" as LocalizedStringKey
                  : machine.pending > 0 ? "Goes into the queue: the machine cuts it when it finishes the previous job" : "Send to the cutter")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// Test Shape on/off and its size (the corner handle on the sheet does the same).
    private var testControls: some View {
        HStack(spacing: 8) {
            Toggle("Test Shape", isOn: $doc.testShape)
                .toggleStyle(.checkbox)
                .help("Shows the test cut on the sheet: drag it to move it, or its corner to resize it")
            HStack(spacing: 8) {
                // Whole mm, without a step (a step draws a tick for each mm).
                Slider(value: Binding(get: { doc.testSide }, set: { doc.resizeTest(to: $0.rounded()) }), in: TestCut.sides)
                    .controlSize(.small)
                    .frame(width: 90)
                    .help("Size of the test cut")
                Text(verbatim: LengthUnit.current.text(doc.testSide))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .leading)
            }
            .disabled(!doc.testShape)
            .opacity(doc.testShape ? 1 : 0.45)
        }
    }

    @ViewBuilder
    private var status: some View {
        if machine.studioOpen {
            Label("Close Silhouette Studio to send.", image: .warning)
                .foregroundStyle(.orange)
        } else if marksNotRead != nil {
            HStack(spacing: 8) {
                Label("The machine couldn’t find the registration marks.", image: .warning)
                    .foregroundStyle(.orange)
                Button("What to check") { marksNotice = marksNotRead }
            }
        } else if let lastOne = lastSend, case .failure(let text) = lastOne.status {
            HStack(spacing: 8) {
                Label(text, image: .warning)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                Button("Try Again") { machine.retry(lastOne.id) }
            }
        } else if let lastOne = lastSend, lastOne.status == .waiting {
            let front = machine.ahead(of: lastOne.id)
            Label(front == 0 ? "In the queue: it’s next." as LocalizedStringKey : "In the queue: \(front) jobs ahead.", image: .clock)
                .foregroundStyle(.secondary)
        } else {
            machineStatus
        }
    }

    @ViewBuilder
    private var machineStatus: some View {
        switch machine.state {
        case .sending(let text):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text)
            }
        case .sent:
            Label("Sent. The machine finished cutting.", image: .checkCircle)
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, image: .warning)
                .foregroundStyle(.orange)
                .lineLimit(2)
        default:
            EmptyView()
        }
    }

    // MARK: Support

    private func link(_ color: CMYK) -> Binding<CutConfig> {
        Binding(get: { doc.config(color) }, set: { doc.setConfig($0, to: color) })
    }

    /// Length × passes ÷ speed (≈ cm/s).
    private func estimate(_ line: CutLine, _ settings: CutSettings) -> (Double, Double) {
        let mm = line.lengthMM
        return (mm, mm / 10 * Double(settings.passes) / Double(max(settings.speed, 1)))
    }

    private func tempo(_ seconds: Double) -> String {
        seconds < 60 ? "\(max(1, Int(seconds.rounded()))) s" : "\(Int(seconds) / 60) min \(Int(seconds) % 60) s"
    }
}

/// A4 sheet with the cuts: the chosen color highlighted; the disabled ones disappear. With Print & Cut, with the marks.
/// With Test Shape on, the test cut shows dashed: dragging it moves it, dragging its corner handle resizes it.
struct SheetPreview: View {
    let doc: Document
    let lines: [CutLine]
    let highlight: CMYK?
    /// What the drag started on: moving the test (from that corner, in mm) or resizing it.
    @State private var testDrag: TestDrag?

    private enum TestDrag {
        case move(CGPoint)
        case resize
    }

    /// Size of the corner handle, in points.
    private static let handle = 6.0

    /// Page mm → preview points.
    private static func transform(_ size: CGSize) -> CGAffineTransform {
        let page = Document.page
        let m = 8.0
        let scale = min(size.width / (page.width + 2 * m), size.height / (page.height + 2 * m))
        let origin = CGPoint(x: (size.width - page.width * scale) / 2, y: (size.height - page.height * scale) / 2)
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: origin.x, ty: origin.y)
    }

    var body: some View {
        GeometryReader { geometry in
            let t = Self.transform(geometry.size)
            sheet
                .overlay(alignment: .topLeading) {
                    // Over the corner handle the pointer shows it resizes.
                    if doc.testShape {
                        let corner = CGPoint(x: doc.testBox.maxX, y: doc.testBox.maxY).applying(t)
                        Color.clear
                            .frame(width: 3 * Self.handle, height: 3 * Self.handle)
                            .contentShape(Rectangle())
                            .pointerStyle(.frameResize(position: .bottomTrailing))
                            .offset(x: corner.x - 1.5 * Self.handle, y: corner.y - 1.5 * Self.handle)
                    }
                }
                .gesture(dragTest(t))
                .help(doc.testShape ? Text("Drag the test cut (the dashed square) to where you want to test on the sheet, or its corner to resize it")
                      : Text(verbatim: ""))
        }
    }

    /// Drag the test cut or its corner; clicking elsewhere on the sheet moves it there. Nothing with Test Shape off.
    private func dragTest(_ t: CGAffineTransform) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                guard doc.testShape else { return }
                let toMM = t.inverted()
                let box = doc.testBox
                if testDrag == nil {
                    let p = gesture.startLocation.applying(toMM)
                    let grab = 1.5 * Self.handle / t.a
                    if abs(p.x - box.maxX) <= grab && abs(p.y - box.maxY) <= grab {
                        testDrag = .resize
                    } else {
                        testDrag = .move(box.insetBy(dx: -3, dy: -3).contains(p)
                                         ? box.origin : CGPoint(x: p.x - box.width / 2, y: p.y - box.height / 2))
                    }
                }
                switch testDrag {
                case .move(let start):
                    doc.moveTest(to: CGPoint(x: start.x + gesture.translation.width / t.a, y: start.y + gesture.translation.height / t.d))
                case .resize:
                    // Square from the top-left corner to the pointer, in whole mm (like the slider), without
                    // pushing past the area.
                    let p = gesture.location.applying(toMM), area = doc.testAreaOf
                    doc.resizeTest(to: min(max(p.x - box.minX, p.y - box.minY).rounded(), area.maxX - box.minX, area.maxY - box.minY))
                case nil:
                    break
                }
            }
            .onEnded { _ in testDrag = nil }
    }

    private var sheet: some View {
        Canvas { ctx, size in
            let page = Document.page
            let m = 8.0
            let t = Self.transform(size)
            let scale = t.a
            let sheet = CGRect(origin: .zero, size: page)
            ctx.fill(Path(roundedRect: sheet.insetBy(dx: -m, dy: -m).applying(t), cornerRadius: 3 * scale),
                     with: .color(.gray.opacity(0.35)))
            var shadow = ctx
            shadow.addFilter(.shadow(color: .black.opacity(0.18), radius: 10, y: 4))
            shadow.fill(Path(sheet.applying(t)), with: .color(.white))
            if doc.marks {
                for rectangle in doc.marksConfig.rectangles { ctx.fill(Path(rectangle.applying(t)), with: .color(.black)) }
            }
            for line in lines where doc.config(line.color).sends {
                let strong = line.color == highlight
                for object in line.objects {
                    let dashed = object.style.line.defaultValue?.map { CGFloat($0 * scale) } ?? []
                    ctx.stroke(object.shapePath.applying(t), with: .color(line.color.color.opacity(strong ? 1 : 0.35)),
                               style: StrokeStyle(lineWidth: strong ? 1.6 : 0.8, dash: dashed))
                }
            }
            guard doc.testShape else { return }
            var test = Path()
            for shapePath in TestCut.paths(in: doc.testPosition, side: doc.testSide) { test.addLines(shapePath.map { $0.applying(t) }) }
            ctx.stroke(test, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
            // Corner handle (resizes), like the canvas's selection handles.
            let h = Self.handle
            let corner = CGPoint(x: doc.testBox.maxX, y: doc.testBox.maxY).applying(t)
            let knob = Path(CGRect(x: corner.x - h / 2, y: corner.y - h / 2, width: h, height: h))
            ctx.fill(knob, with: .color(.white))
            ctx.stroke(knob, with: .color(.accentColor), lineWidth: 1)
        }
    }
}

/// Cutter card: illustration, model, connection and status; with more than one in range, the choice.
struct MachineCard: View {
    @Environment(Machine.self) private var machine
    /// The document's cutting mat (in the Send window); nil in the toolbar's machine menu.
    var withMat: Bool?
    /// The mat that goes to the machine (in the Send window).
    var base: CuttingMat?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                PortraitIllustration()
                    .frame(width: 96, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(machine.info == nil ? machine.current?.model ?? String(localized: "Silhouette cutter") : machine.modelName)
                        .font(.headline)
                    Text([machine.current?.link == .usb ? "USB" : "Bluetooth", machine.current?.serial.map { String(localized: "S/N \($0)") }, machine.firmware]
                        .compactMap(\.self).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let withMat {
                        Text(withMat ? "\(base?.name ?? String(localized: "With cutting mat")) · change it in the Page panel"
                             : "No cutting mat (sheet fed directly) · change it in the Page panel")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                state
            }
            if case .choose(let list) = machine.state {
                choice(list)
            }
        }
        .padding(12)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private func choice(_ list: [DiscoveredCutter]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Found \(list.count) cutters. Which one?")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(list) { cutter in
                HStack {
                    Text(Self.label(cutter))
                    Spacer()
                    Button("Connect") { Task { await machine.connect(cutter) } }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.leading, 110)
    }

    /// "Portrait 4 · No. 0000001" (on the cable, "· USB") — the serial number tells apart machines of the same model.
    static func label(_ cutter: DiscoveredCutter) -> String {
        [cutter.model, cutter.serial.map { String(localized: "S/N \($0)") }, cutter.link == .usb ? "USB" : nil]
            .compactMap(\.self).joined(separator: " · ")
    }

    @ViewBuilder
    private var state: some View {
        if machine.studioOpen {
            indicator(.orange, "Silhouette Studio open")
        } else {
            connectionState
        }
    }

    @ViewBuilder
    private var connectionState: some View {
        switch machine.state {
        case .disconnected, .failure:
            HStack(spacing: 8) {
                indicator(.secondary, "Disconnected")
                Button("Connect") { Task { await machine.connect() } }
            }
        case .connecting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for the machine…").foregroundStyle(.secondary)
            }
        case .sending:
            indicator(.accentColor, "Cutting")
        case .connected, .sent:
            HStack(spacing: 8) {
                switch machine.info?.status {
                case .unloaded: indicator(.orange, withMat == false ? "Load the sheet" : "No mat — load the mat")
                case .moving: indicator(.accentColor, "Moving")
                default: indicator(.green, "Ready")
                }
                Button("Check", image: .refresh) { Task { await machine.connect() } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Check the machine status again")
                if machine.discovered.count > 1 { switchMachine }
            }
        case .choose:
            indicator(.orange, "Choose the machine")
        }
    }

    private var switchMachine: some View {
        Menu("Switch Machine", image: .swap) {
            ForEach(machine.discovered) { cutter in
                Button(Self.label(cutter)) { Task { await machine.connect(cutter) } }
                    .disabled(cutter == machine.current)
            }
        }
        .labelStyle(.iconOnly)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch Machine")
    }

    private func indicator(_ color: Color, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.callout)
        }
    }
}

/// Drawing of the Portrait 4 (from the prototype, viewBox 96 × 44).
struct PortraitIllustration: View {
    var body: some View {
        Canvas { ctx, size in
            let e = min(size.width / 96, size.height / 44)
            ctx.scaleBy(x: e, y: e)
            let line = GraphicsContext.Shading.color(.primary)
            var pointSize = Path()
            pointSize.move(to: CGPoint(x: 10, y: 14))
            pointSize.addQuadCurve(to: CGPoint(x: 6, y: 18), control: CGPoint(x: 8, y: 14))
            pointSize.addLine(to: CGPoint(x: 4, y: 30))
            pointSize.addQuadCurve(to: CGPoint(x: 9, y: 36), control: CGPoint(x: 3.5, y: 36))
            pointSize.addLine(to: CGPoint(x: 87, y: 36))
            pointSize.addQuadCurve(to: CGPoint(x: 92, y: 30), control: CGPoint(x: 92.5, y: 36))
            pointSize.addLine(to: CGPoint(x: 90, y: 18))
            pointSize.addQuadCurve(to: CGPoint(x: 86, y: 14), control: CGPoint(x: 88, y: 14))
            pointSize.closeSubpath()
            ctx.fill(pointSize, with: .color(.primary.opacity(0.06)))
            ctx.stroke(pointSize, with: line, lineWidth: 1.4)

            var lid = Path()
            lid.move(to: CGPoint(x: 14, y: 14))
            lid.addQuadCurve(to: CGPoint(x: 26, y: 7), control: CGPoint(x: 16, y: 7))
            lid.addLine(to: CGPoint(x: 70, y: 7))
            lid.addQuadCurve(to: CGPoint(x: 82, y: 14), control: CGPoint(x: 80, y: 7))
            ctx.fill(lid, with: .color(.primary.opacity(0.1)))
            ctx.stroke(lid, with: line, lineWidth: 1.4)

            ctx.stroke(Path { $0.move(to: CGPoint(x: 8, y: 24)); $0.addLine(to: CGPoint(x: 88, y: 24)) },
                       with: .color(.primary.opacity(0.55)), lineWidth: 1)
            ctx.fill(Path(roundedRect: CGRect(x: 12, y: 25.5, width: 72, height: 2.2), cornerRadius: 1), with: .color(.primary.opacity(0.8)))
            var base = Path()
            base.move(to: CGPoint(x: 6.5, y: 36))
            base.addQuadCurve(to: CGPoint(x: 11, y: 39.5), control: CGPoint(x: 7, y: 39.5))
            base.addLine(to: CGPoint(x: 85, y: 39.5))
            base.addQuadCurve(to: CGPoint(x: 89.5, y: 36), control: CGPoint(x: 89, y: 39.5))
            ctx.stroke(base, with: .color(.primary.opacity(0.6)), lineWidth: 1.2)
            ctx.stroke(Path(ellipseIn: CGRect(x: 78, y: 17, width: 4, height: 4)), with: line, lineWidth: 1.1)
            ctx.stroke(Path { $0.move(to: CGPoint(x: 30, y: 31)); $0.addLine(to: CGPoint(x: 66, y: 31)) },
                       with: .color(.primary.opacity(0.35)), lineWidth: 1)
        }
    }
}

/// Dropping a dragged color on another table row: it takes that row's place.
private struct ColorDrop: DropDelegate {
    let color: CMYK
    let doc: Document
    @Binding var dragging: CMYK?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != color, let destination = doc.cutLines.firstIndex(where: { $0.color == color }) else { return }
        withAnimation(.snappy(duration: 0.2)) { doc.moveLine(dragging, to: destination) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
