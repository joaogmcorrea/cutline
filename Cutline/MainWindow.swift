// Editor window, in Silhouette Studio's order: toolbar (file on the left, Send on the right), control
// bar, tabs and the canvas; over the canvas, tools and side panel float as glass pieces.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension FocusedValues {
    @Entry var document: Document?
}

/// What Import… accepts: PDF, AI, SVG, EPS and images (an image asks what to do: just the image or traced).
private enum Import {
    static let illustrator = UTType("com.adobe.illustrator.ai-image") ?? UTType(filenameExtension: "ai") ?? .pdf
    static let eps = UTType("com.adobe.encapsulated-postscript") ?? UTType(filenameExtension: "eps") ?? .data

    static let kinds: [UTType] = [.pdf, illustrator, .svg, eps, .image]
}

struct MainWindow: View {
    let doc: Document
    @Environment(\.undoManager) private var manager
    @Environment(Machine.self) private var machine
    @Environment(\.openWindow) private var openWindowAction
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var control = ViewControl()
    @State private var canvasSize = CGSize.zero
    @AppStorage("paineisRecolhidos") private var collapsedPanels = Panel.defaultCollapsed
    // Window menu: what is shown (applies to all windows, as in Illustrator).
    @AppStorage("paineisOcultos") private var hiddenPanels = ""
    @AppStorage("ferramentasVisiveis") private var toolsVisible = true
    @AppStorage("barraControleVisivel") private var controlBarVisible = true
    @State private var nsWindow = WeakWindow()
    @State private var sendWindowOpen = false
    @AppStorage("reguas") private var rulersOn = true
    @State private var importing = false
    @State private var tracingNow: ImageToTrace?
    @State private var layeredNow: LayeredImage?
    /// File being dragged over the window.
    @State private var dropping = false

    var body: some View {
        GeometryReader { _ in
            ZStack {
                if toolsVisible {
                    ToolsPanel(doc: doc)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .padding(.leading, 14)
                }
                // Notice and tip centered in the area to the left of the side panel.
                ZStack {
                    if let notice = doc.notice { importNotice(notice) } else if doc.objects.isEmpty { emptyTip }
                }
                .padding(.trailing, panelWidth)
                SidePanel(doc: doc)
                    .padding(EdgeInsets(top: 8, leading: 0, bottom: 12, trailing: 12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        // Files dragged from the Finder onto the window (the point is in canvas space, which sits behind).
        .dropDestination(for: URL.self) { urls, point in drop(urls, in: point) } isTargeted: { dropping = $0 }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .background {
            // The canvas starts below the tabs (outside the title bar area).
            CanvasView(doc: doc, viewState: $control.viewState, rulers: rulerGeometry)
                .onGeometryChange(for: CGSize.self, of: \.size) { canvasSize = $0 }
        }
        // The page refits to the window (and to the rulers and panel) until the user touches the zoom or position.
        .onChange(of: freeArea, initial: true) { _, newOne in
            control.freeArea = newOne
            if !control.viewState.manual, canvasSize.width > 300, canvasSize.height > 300 { control.adjust() }
        }
        .onChange(of: control.viewState.mm(CGPoint(x: control.freeArea.midX, y: control.freeArea.midY)), initial: true) { _, center in
            doc.visibleCenter = center
        }
        // The document name shows only on the tab.
        .toolbar(removing: .title)
        .toolbar { toolbarPanel }
        .sheet(isPresented: $sendWindowOpen) { SendWindow(doc: doc) }
        // Print & Cut without the marks read: the Send window opens (if it was closed) with the tips on top.
        .onChange(of: machine.queue.contains { $0.origin == ObjectIdentifier(doc) && $0.status == .marksNotFound }) { _, updated in
            if updated { sendWindowOpen = true }
        }
        .background { Color.clear.sheet(item: $tracingNow) { TraceWindow(doc: doc, origin: $0) } }
        .background { Color.clear.sheet(item: $layeredNow) { LayeredImageWindow(doc: doc, origin: $0) } }
        .fileImporter(isPresented: $importing, allowedContentTypes: Import.kinds) { result in
            if case .success(let url) = result { openImported(url, ask: true) }
        }
        .focusedSceneValue(\.document, doc)
        .focusedSceneValue(\.viewControl, control)
        .onChange(of: doc.importRequest) { _, _ in importing = true }
        .onChange(of: doc.printRequest) { _, _ in printDocument() }
        .onChange(of: doc.sendRequest) { _, _ in if !doc.objects.isEmpty { sendWindowOpen = true } }
        .onChange(of: controlBarVisible) { _, visible in
            if let nsWindow = nsWindow.nsWindow { ControlBar.display(visible, in: nsWindow) }
        }
        .background(WindowReader { nsWindow in
            // Control bar between the toolbar and the tabs; tab bar always shown (also with a
            // single document).
            self.nsWindow.nsWindow = nsWindow
            if let nsWindow { OpeningFrame.fill(nsWindow) }
            if let nsWindow { ControlBar.install(in: nsWindow, doc: doc, control: control) }
            if let nsWindow, let group = nsWindow.tabGroup, !group.isTabBarVisible { nsWindow.toggleTabBar(nil) }
            // AppKit puts focus on the first field (stroke width) when the window opens, and then the
            // shortcut keys stay with the field: the window opens with focus on the canvas.
            DispatchQueue.main.async { if nsWindow?.firstResponder is NSText { nsWindow?.makeFirstResponder(nil) } }
            turnOffFromStudioFile(nsWindow)
            #if DEBUG
            DebugHooks.saveForTest(nsWindow)
            #endif
        })
        .onAppear {
            doc.use(manager)
            // A document took the start screen's place; what was picked there (Print & Cut, an image) comes in now.
            StartScreen.opener = openWindowAction
            dismissWindow(id: StartScreen.id)
            switch doc.objects.isEmpty ? StartScreen.takeSetup() : nil {
            case .printAndCut: doc.marks = true
            case .importing(let url): openImported(url)
            case nil: break
            }
        }
        .onChange(of: manager) { _, updated in doc.use(updated) }
        .onDisappear {
            doc.use(nil)
            // The last document closed: the start screen comes back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                if StartScreen.enabled, NSDocumentController.shared.documents.isEmpty { StartScreen.show() }
            }
        }
        #if DEBUG
        .onAppear {
            DebugHooks.fillDemo(doc)
            if DebugHooks.openSettings { openSettings() }
            DebugHooks.editTextForTest(doc)
            DebugHooks.modifyForTest(doc)
            DebugHooks.pathfinderForTest(doc)
            if let url = DebugHooks.importForTest { openImported(url) }
            if let url = DebugHooks.dropForTest {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    _ = drop([url], in: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2))
                }
            }
            DebugHooks.printForTest(doc)
            DebugHooks.scheduleSnapshot()
            DebugHooks.dumpMenus()
            if DebugHooks.openSendWindow { sendWindowOpen = true }
            if let kind = DebugHooks.openReport { openWindowAction(value: kind) }
        }
        #endif
    }

    /// An opened .studio3 becomes a new Cutline document, still without a file (as Keynote does with a
    /// PowerPoint): macOS never writes the original, and ⌘S asks whether to save over it (the location is in
    /// `doc.studio`) or as a Cutline document (Model/StudioSave.swift).
    private func turnOffFromStudioFile(_ nsWindow: NSWindow?) {
        guard doc.cameFromStudio, let document = nsWindow?.windowController?.document as? NSDocument else { return }
        doc.cameFromStudio = false
        guard let kind = document.fileType.flatMap({ UTType($0) }), kind.conforms(to: .studio3) else { return }
        let name = document.fileURL?.deletingPathExtension().lastPathComponent
        doc.studio?.url = document.fileURL
        document.fileURL = nil
        document.fileType = UTType.cutlineDocument.identifier
        if let name {
            document.displayName = name
            nsWindow?.windowController?.synchronizeWindowTitleWithDocumentName()
        }
    }

    /// Files dropped on the window: documents (.cutline, .studio3) each open in their own window; the rest goes in
    /// as with Import… — an image asks what to do and is centered where it was dropped.
    private func drop(_ urls: [URL], in point: CGPoint) -> Bool {
        let files = urls.filter(\.isFileURL)
        for url in files {
            let kind = UTType(filenameExtension: url.pathExtension) ?? .data
            if kind.conforms(to: .cutlineDocument) || kind.conforms(to: .studio3) {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            } else {
                openImported(url, center: control.viewState.mm(point))
            }
        }
        return !files.isEmpty
    }

    /// PDF, AI, SVG and EPS (Model/VectorImport.swift) → the paths go into the active layer, with a notice of what
    /// was left out; a Photoshop file with layers → each layer as its own image (Editor/LayeredImageWindow.swift);
    /// any other image → Trace window, which first asks whether the image goes alone, with the outer
    /// contour or with the inner ones (`ask`; the Trace tool goes straight to the settings). The content decides:
    /// .ai and .svg are also "images" to macOS, and the Trace tool's panel accepts both.
    private func openImported(_ url: URL, ask: Bool = true, center: CGPoint? = nil) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let payload = try? Data(contentsOf: url) else {
            doc.notice = String(localized: "“\(url.lastPathComponent)” couldn’t be opened.")
            return
        }
        let kind = UTType(filenameExtension: url.pathExtension) ?? .data
        let vectorByName = [.pdf, Import.illustrator, .svg, Import.eps].contains { kind.conforms(to: $0) }
        guard VectorImporter.format(payload) != nil || vectorByName else {
            let openImage = {
                guard var image = ImageToTrace(url: url) else { doc.notice = String(localized: "The image couldn’t be opened."); return }
                image.ask = ask
                image.center = center
                tracingNow = image
            }
            guard PSDImport.isPhotoshop(payload) else { return openImage() }
            // Reading every layer takes a moment on big files: off the main thread. Flattened, it goes as one image.
            Task {
                let file = await Task.detached { PSDImport.read(payload) }.value
                guard let file, !file.layers.isEmpty else { return openImage() }
                layeredNow = LayeredImage(name: url.deletingPathExtension().lastPathComponent, file: file, center: center)
            }
            return
        }
        do {
            let result = try VectorImporter.read(payload)
            doc.insertImported(result.objects)
            var parts: [String] = []
            if result.texts > 0 { parts.append(String(localized: "text not imported (convert it to outlines in Illustrator)")) }
            if result.images > 0 { parts.append(String(localized: "\(result.images) images not imported")) }
            if result.objects.isEmpty {
                doc.notice = parts.isEmpty ? String(localized: "No paths to import in “\(url.lastPathComponent)”.")
                    : String(localized: "No paths to import in “\(url.lastPathComponent)”: \(parts.joined(separator: " · ")).")
            } else {
                parts.insert(String(localized: "\(result.objects.count) paths"), at: 0)
                doc.notice = String(localized: "Imported from “\(url.lastPathComponent)”: \(parts.joined(separator: " · ")).")
            }
        } catch {
            doc.notice = error.localizedDescription
        }
    }

    /// Summary of the Silhouette Studio import, until the user dismisses it.
    private func importNotice(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(.info)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button("OK") { withAnimation(.snappy(duration: 0.2)) { doc.notice = nil } }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: 640)
        .glassEffect(.regular, in: .capsule)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 16)
    }

    /// Space the side menu takes on the right (fixed column, icon strip and margins).
    private var panelWidth: Double { SidePanel.isBusy(collapsedSet: collapsedPanels, hiddenOnes: hiddenPanels) }

    /// How far the tools reach (or just the margin, when they are hidden).
    private var toolsWidth: Double { toolsVisible ? 62 : 10 }

    private var emptyTip: some View {
        Text("Draw with the tools on the left (P pen, T text, M, L and S shapes) or import with ⇧⌘I.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .glassEffect(.regular, in: .capsule)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 16)
            .allowsHitTesting(false)
    }

    /// Rulers: right below the tabs and to the right of the tools, up to the side panel.
    private var rulerGeometry: RulerGeometry? {
        guard rulersOn, canvasSize.width > 300 else { return nil }
        let top = 8.0, left = toolsWidth + 4, right = canvasSize.width - max(panelWidth - 4, 12)
        return RulerGeometry(area: CGRect(x: left, y: top, width: max(right - left, 50),
                                            height: max(canvasSize.height - top - 12, 50)))
    }

    /// Canvas area without the floating pieces (tools, rulers, side panel).
    private var freeArea: CGRect {
        let left = toolsWidth + (rulersOn ? 34 : 14), top = rulersOn ? 40.0 : 16
        return CGRect(x: left, y: top, width: max(canvasSize.width - left - 28 - panelWidth, 50),
                      height: max(canvasSize.height - top - 28, 50))
    }

    /// Print panel over this window (with the Send window open, over the document's).
    private func printDocument() {
        let nsWindow = NSApp.keyWindow.map { $0.sheetParent ?? $0 }
        Printing.printDocument(doc, in: nsWindow)
    }

    /// Toolbar icon at the size of the system ones (the SVGs are 16 pt).
    private func label(_ title: LocalizedStringKey, _ icon: ImageResource, size: Double = 20) -> some View {
        Label { Text(title) } icon: { Image(icon).resizable().frame(width: size, height: size) }
    }

    /// Like Studio's first row: file on the left; on the right the machine (and the queue) and Send.
    /// Undo, zoom and the drawing aids live in the control bar; Import, in the File menu.
    @ToolbarContentBuilder
    private var toolbarPanel: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { NSDocumentController.shared.newDocument(nil) } label: { label("New", .newDocument) }
                .help("New document (⌘N)")
            Button { NSDocumentController.shared.openDocument(nil) } label: { label("Open", .openDocument) }
                .help("Open a Cutline or Silhouette Studio document (⌘O)")
            Button { NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil) } label: { label("Save", .save) }
                .help("Save (⌘S)")
            Button { printDocument() } label: { label("Print", .printer) }
                .help("Print at actual size (⌘P)")
        }
        // Without the title in the middle, the spacer pushes the machine and Send to the right.
        ToolbarSpacer(.flexible)
        ToolbarItem {
            MachinePill()
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            // Icon: the machine's blade holder (needle) cutting the paper — the owner's drawing in the sketch.
            Button { sendWindowOpen = true } label: { label("Send", .needle, size: 18) }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.glassProminent)
                .disabled(doc.objects.isEmpty)
                .help("Send to the cutter (⌘E)")
        }
        // The button is already glass (prominent): no shared toolbar background behind it (glass on glass).
        .sharedBackgroundVisibility(.hidden)
    }
}

/// Weak reference to the window (keeping the NSWindow in a @State would keep it alive after closing).
final class WeakWindow {
    weak var nsWindow: NSWindow?
}

/// A document window opens filling the screen (its visible area: the menu bar and the Dock stay), once. A new tab
/// joins the window as it is, so the size the user chose stays.
enum OpeningFrame {
    private static var filled = Set<ObjectIdentifier>()

    static func fill(_ nsWindow: NSWindow) {
        #if DEBUG
        if DebugHooks.hidden { return }   // the hidden tests keep their windows off the screens
        #endif
        guard filled.insert(ObjectIdentifier(nsWindow)).inserted, (nsWindow.tabbedWindows?.count ?? 1) <= 1,
              let screen = nsWindow.screen ?? NSScreen.main else { return }
        nsWindow.setFrame(screen.visibleFrame, display: true)
    }
}
