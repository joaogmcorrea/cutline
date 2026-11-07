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
    @State private var tracingNow: ImageToTrace?
    @State private var layeredNow: LayeredImage?
    @State private var manyPathsNow: ManyPaths?
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
        // Files dragged from the Finder onto the window (the point is in canvas space, which sits behind); an image over a
        // shape highlights it (it goes inside: Editor/ImageInsideShape.swift).
        .onDrop(of: [.fileURL], delegate: FileDrop(doc: doc, viewState: control.viewState, dropping: $dropping) { urls, point in
            _ = drop(urls, in: point)
        })
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
                // The linked images' files (Editor/LinksPanel.swift).
                .modifier(LinkWatcher(doc: doc))
                // A photo, sketch or scan from an iPhone or iPad (Editor/DeviceImport.swift).
                .modifier(DeviceImportReceiver(doc: doc, tracing: $tracingNow, manyPaths: $manyPathsNow))
        }
        // The page refits to the window (and to the rulers and panel) until the user touches the zoom or position.
        .onChange(of: freeArea, initial: true) { _, newOne in
            control.freeArea = newOne
            control.activeArtboard = doc.activeArtboard.rect
            if !control.viewState.manual, canvasSize.width > 300, canvasSize.height > 300 { control.adjust() }
        }
        // Fit in Window shows the active artboard; Fit All in Window, all of them.
        .onChange(of: doc.activeArtboard.rect, initial: true) { _, newOne in control.activeArtboard = newOne }
        .onChange(of: doc.artboardsBox, initial: true) { _, newOne in control.allArtboards = newOne }
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
        // (Also Edit › Assign Profile…'s sheet: in the same background, so the chain stays short enough to type-check.)
        .background {
            Color.clear.sheet(item: $manyPathsNow) { ManyPathsWindow(doc: doc, origin: $0) }.modifier(AssignProfileSheet(doc: doc))
                .modifier(ColorPickerSheet(doc: doc)).modifier(PathTextOptionsSheet(doc: doc)).modifier(RotateSheet(doc: doc))
        }
        .focusedSceneValue(\.document, doc)
        .focusedSceneValue(\.viewControl, control)
        .onChange(of: doc.importRequest) { _, _ in chooseFileToImport() }
        .onChange(of: doc.printRequest) { _, _ in printDocument() }
        .onChange(of: doc.saveSelectionRequest) { _, _ in saveSelection() }
        .onChange(of: doc.mergeRequest) { _, _ in chooseFileToMerge() }
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
            DebugHooks.deviceImportForTest(nsWindow, doc: doc)
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
            case .canva(let url, let title): openPage(url, title: title, from: .canva)
            case .illustrator(let url):
                openPage(url, title: IllustratorScript.title(of: url), from: .illustrator)
                IllustratorScript.discard(url)
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
            DebugHooks.openPickerForTest(doc)
            DebugHooks.showFontListForTest(doc)
            DebugHooks.pathfinderForTest(doc)
            if let url = DebugHooks.importForTest { openImported(url, link: DebugHooks.linkImport) }
            if let url = DebugHooks.dropForTest {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let point = DebugHooks.dropPointForTest.map(control.viewState.canvas) ?? CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                    _ = drop([url], in: point)
                }
            }
            DebugHooks.printForTest(doc)
            DebugHooks.scheduleSnapshot()
            DebugHooks.dumpMenus()
            if DebugHooks.openSendWindow { sendWindowOpen = true }
            if DebugHooks.openSendPlain {
                DebugHooks.showPlain(SendWindow(doc: doc).environment(machine), title: "CutlineTestSend", size: CGSize(width: 1000, height: 680))
            }
            if let request = DebugHooks.reportRequest(doc: doc, machine: machine) { openWindowAction(value: request) }
            if DebugHooks.openCanvaOnce() { openWindowAction(id: CanvaWindow.id) }
            DebugHooks.installScriptForTest()
        }
        #endif
    }

    /// An opened .studio3 becomes a new Cutline document, still without a file (as Keynote does with a
    /// PowerPoint): macOS never writes the original, and ⌘S asks whether to save over it (the location is in
    /// `doc.studio`) or as a Cutline document (Model/StudioSave.swift). The window can show up before it has its
    /// document: then it tries again a moment later (and ⌘S detaches it too, in case it never got one in time).
    private func turnOffFromStudioFile(_ nsWindow: NSWindow?, attempt: Int = 0) {
        guard doc.cameFromStudio else { return }
        #if DEBUG
        if DebugHooks.keepStudioAttached { return }
        #endif
        guard let document = nsWindow?.windowController?.document as? NSDocument else {
            if attempt < 20, nsWindow != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { turnOffFromStudioFile(nsWindow, attempt: attempt + 1) }
            }
            return
        }
        StudioSave.detach(doc, from: document, nsWindow: nsWindow)
    }

    /// Files dropped on the window: documents (.cutline, .studio3) merge into this one, as with File › Merge… (to open
    /// one in its own window: File › Open, or drop it on the Dock icon); the rest goes in as with Import… — an image asks
    /// what to do and is centered where it was dropped.
    private func drop(_ urls: [URL], in point: CGPoint) -> Bool {
        let files = urls.filter(\.isFileURL)
        // One image over a shape: it goes inside, filling it (as Silhouette Studio's Fill Pattern), without the question.
        if files.count == 1, let target = doc.imageTarget(at: control.viewState.mm(point)), doc.putImageFile(files[0], into: target) {
            doc.tool = .selection
            return true
        }
        for url in files {
            let kind = UTType(filenameExtension: url.pathExtension) ?? .data
            if Document.mergeable.contains(where: kind.conforms(to:)) {
                merge(url)
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
    /// File › Import…: the open panel on this window, with Link (Editor/LinksPanel.swift).
    private func chooseFileToImport() {
        guard let nsWindow = nsWindow.nsWindow, nsWindow.attachedSheet == nil else { return }
        doc.finishText()
        ImportPanel.choose(Import.kinds, in: nsWindow) { url, link in openImported(url, ask: true, link: link) }
    }

    /// Where a page for a new document comes from.
    enum PageSource { case canva, illustrator }

    /// A page exported by Open from Canva… (Canva/CanvaWindow.swift) or sent by Illustrator's script (Illustrator/), in
    /// this new document: the 1st artboard takes the page's size, the PDF comes in as any imported PDF (with the
    /// many-paths question, if it comes to that), and the document is named after the design or the Illustrator document
    /// (the window's tab, and Save's suggested name).
    private func openPage(_ url: URL, title: String, from source: PageSource) {
        if let pdf = CGPDFDocument(url as CFURL), let page = pdf.page(at: 1) {
            let box = page.getBoxRect(.cropBox), mm = 25.4 / 72
            let size = CGSize(width: Artboard.limited(box.width * mm), height: Artboard.limited(box.height * mm))
            if !box.isEmpty, size != doc.artboards[0].size {
                doc.artboards[0].rect = CGRect(origin: .zero, size: size)
                control.activeArtboard = doc.activeArtboard.rect
                DispatchQueue.main.async { if canvasSize.width > 300, canvasSize.height > 300 { control.adjust() } }
            }
        }
        // From Illustrator, the notice names the Illustrator document, not the temporary file.
        openImported(url, name: source == .illustrator ? title : nil, fromCanva: source == .canva)
        nameDocument(title, from: source)
    }

    /// The untitled document takes the design's name, once the window has its document.
    private func nameDocument(_ title: String, from source: PageSource, attempt: Int = 0) {
        guard let document = nsWindow.nsWindow?.windowController?.document as? NSDocument else {
            if attempt < 30 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { nameDocument(title, from: source, attempt: attempt + 1) }
            }
            return
        }
        document.displayName = title
        document.windowControllers.forEach { $0.synchronizeWindowTitleWithDocumentName() }
        #if DEBUG
        DebugHooks.pageOpened(doc, document: document, from: source == .canva ? "canva" : "illustrator")
        #endif
    }

    /// `link`: an image goes in linked (its file isn't copied into the document); vectors always come in as paths.
    /// `name`: the file's name in the notices (its own by default). `fromCanva`: the notice doesn't send the person to
    /// Illustrator for the text.
    private func openImported(_ url: URL, ask: Bool = true, center: CGPoint? = nil, link: Bool = false, name: String? = nil,
                              fromCanva: Bool = false) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let name = name ?? url.lastPathComponent
        guard let payload = try? Data(contentsOf: url) else {
            doc.notice = String(localized: "“\(name)” couldn’t be opened.")
            return
        }
        let kind = UTType(filenameExtension: url.pathExtension) ?? .data
        let vectorByName = [.pdf, Import.illustrator, .svg, Import.eps].contains { kind.conforms(to: $0) }
        guard VectorImporter.format(payload) != nil || vectorByName else {
            let openImage = {
                guard var image = ImageToTrace(url: url) else { doc.notice = String(localized: "The image couldn’t be opened."); return }
                image.ask = ask
                image.center = center
                image.sheet = doc.activeArtboard.rect
                if link { image.linkURL = url }
                tracingNow = image
            }
            guard PSDImport.isPhotoshop(payload) else { return openImage() }
            // Reading every layer takes a moment on big files: off the main thread. Flattened, it goes as one image.
            Task {
                let colors = doc.colors
                let file = await Task.detached { PSDImport.read(payload, colors: colors) }.value
                guard let file, !file.layers.isEmpty else { return openImage() }
                layeredNow = LayeredImage(name: url.deletingPathExtension().lastPathComponent, file: file, center: center,
                                          sheet: doc.activeArtboard.rect)
                if link { doc.notice = String(localized: "A Photoshop file’s layers go into the document: only a whole image can be linked.") }
            }
            return
        }
        do {
            let result = try VectorImporter.read(payload, colors: doc.colors, sheet: doc.activeArtboard.rect)
            // Tens of thousands of paths (a texture, an image trace): flatten, simplify or bring them all.
            if result.objects.count > ManyPaths.threshold {
                let origin = ManyPaths(name: name, result: result, fromCanva: fromCanva)
                #if DEBUG
                if let output = DebugHooks.manyPathsPlain {
                    DebugHooks.showPlain(ManyPathsWindow(doc: doc, origin: origin), title: "CutlineTestManyPaths",
                                         size: CGSize(width: 480, height: 470), output: output)
                    return
                }
                #endif
                manyPathsNow = origin
                return
            }
            doc.insertImported(result.objects, images: result.imageData)
            doc.notice = result.notice(from: name, fromCanva: fromCanva)
        } catch {
            doc.notice = error.localizedDescription
        }
    }

    /// File › Merge…: the open panel on this window, for a .cutline or .studio3 to bring into this document.
    private func chooseFileToMerge() {
        guard let nsWindow = nsWindow.nsWindow, nsWindow.attachedSheet == nil else { return }
        doc.finishText()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Document.mergeable
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a Cutline or Silhouette Studio document to bring into this one.")
        panel.prompt = String(localized: "Merge")
        panel.beginSheetModal(for: nsWindow) { response in
            if response == .OK, let url = panel.url { merge(url) }
        }
    }

    private func merge(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            doc.notice = try doc.merge(url)
        } catch {
            doc.notice = String(localized: "“\(url.lastPathComponent)” couldn’t be merged: \(error.localizedDescription)")
        }
    }

    /// File › Save Selection…: the save panel on this window, for a new Cutline file with only the selected objects.
    private func saveSelection() {
        guard let nsWindow = nsWindow.nsWindow, nsWindow.attachedSheet == nil else { return }
        let payload: Data
        do {
            guard let data = try doc.selectionFile() else { return }
            payload = data
        } catch {
            doc.notice = error.localizedDescription
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.cutlineDocument]
        panel.nameFieldStringValue = String(localized: "\(nsWindow.title) (selection)")
        panel.beginSheetModal(for: nsWindow) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try payload.write(to: url, options: .atomic)
                doc.notice = String(localized: "Selection saved to “\(url.lastPathComponent)”.")
            } catch {
                doc.notice = error.localizedDescription
            }
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

/// Files dragged from the Finder over the window: the frame around it while they are over it, and the shape a single image
/// would go into, highlighted on the canvas (the drop itself decides again where it lands: `MainWindow.drop`).
struct FileDrop: DropDelegate {
    let doc: Document
    let viewState: ViewState
    @Binding var dropping: Bool
    let perform: ([URL], CGPoint) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }

    func dropEntered(info: DropInfo) {
        dropping = true
        highlight(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        highlight(info)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        dropping = false
        doc.imageDropTarget = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        dropping = false
        doc.imageDropTarget = nil
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        let point = info.location
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await Self.url(from: provider) { urls.append(url) }
            }
            if !urls.isEmpty { perform(urls, point) }
        }
        return true
    }

    /// One raster image (not a vector file, which is also an "image" to macOS) over a shape that takes it.
    private func highlight(_ info: DropInfo) {
        let providers = info.itemProviders(for: [.fileURL])
        let vectors: [UTType] = [.pdf, .svg, UTType("com.adobe.illustrator.ai-image") ?? .pdf, UTType("com.adobe.encapsulated-postscript") ?? .pdf]
        let image = providers.count == 1 && info.hasItemsConforming(to: [.image]) && !info.hasItemsConforming(to: vectors)
        let target = image ? doc.imageTarget(at: viewState.mm(info.location)) : nil
        if doc.imageDropTarget != target { doc.imageDropTarget = target }
    }

    private static func url(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
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
