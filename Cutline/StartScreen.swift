// Start screen, as Illustrator's Home: shows when Cutline opens with no document (instead of a blank one) and when the
// last document closes. New document, Open, ways to start (blank sheet, Print & Cut, trace an image, a Silhouette
// Studio file), the recent files with a preview drawn from the file itself, and the machine. Settings › General (or
// "Show at launch" here) turns it off: then Cutline opens a blank document, as before.
import AppKit
import CutlineKit
import SwiftUI
import UniformTypeIdentifiers

/// When the start screen shows, and what a new document from it starts with.
enum StartScreen {
    static let id = "start"
    static let key = "showStartScreen"

    /// On by default; off in the hidden tests (they expect a document at launch) unless CUTLINE_START=1.
    static var enabled: Bool {
        #if DEBUG
        if DebugHooks.hidden, ProcessInfo.processInfo.environment["CUTLINE_START"] == nil { return false }
        #endif
        return UserDefaults.standard.object(forKey: key) == nil || UserDefaults.standard.bool(forKey: key)
    }

    /// How a document window opens the start screen (the app delegate has no SwiftUI environment); kept by the first
    /// window that shows.
    static var opener: OpenWindowAction?

    static func show() { opener?(id: id) }

    /// What the next new document starts with (picked on the start screen).
    enum Setup { case printAndCut, importing(URL) }
    private static var pending: Setup?

    static func newDocument(_ setup: Setup? = nil) {
        pending = setup
        NSDocumentController.shared.newDocument(nil)
    }

    /// The new document's setup, once.
    static func takeSetup() -> Setup? {
        defer { pending = nil }
        return pending
    }

    /// .cutline and .studio3 open as documents; images and vector files go into a new document, as with Import….
    static func open(_ urls: [URL]) {
        for url in urls where url.isFileURL {
            let kind = UTType(filenameExtension: url.pathExtension) ?? .data
            if kind.conforms(to: .cutlineDocument) || kind.conforms(to: .studio3) {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            } else {
                newDocument(.importing(url))
            }
        }
    }
}

/// No blank document at launch nor on a Dock click with no windows when the start screen is on: the start screen
/// shows instead.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { !StartScreen.enabled }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows, StartScreen.enabled, StartScreen.opener != nil else { return true }
        StartScreen.show()
        return false
    }
}

struct StartView: View {
    @Environment(Machine.self) private var machine
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(StartScreen.key) private var showAtLaunch = true
    @State private var recent: [URL] = []
    @State private var dropping = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            main
        }
        .frame(minWidth: 940, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .dropDestination(for: URL.self) { urls, _ in
            StartScreen.open(urls)
            return !urls.isEmpty
        } isTargeted: { dropping = $0 }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor, lineWidth: 3).padding(6).allowsHitTesting(false)
            }
        }
        .onAppear {
            StartScreen.opener = openWindow
            recent = NSDocumentController.shared.recentDocumentURLs
            #if DEBUG
            if let files = DebugHooks.recentForTest { recent = files }
            switch DebugHooks.startAction {
            case "blank": DispatchQueue.main.asyncAfter(deadline: .now() + 1) { StartScreen.newDocument() }
            case "printAndCut": DispatchQueue.main.asyncAfter(deadline: .now() + 1) { StartScreen.newDocument(.printAndCut) }
            default: break
            }
            #endif
            // Documents brought back by macOS when Cutline opens: they take the place of the start screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if !NSDocumentController.shared.documents.isEmpty { dismissWindow(id: StartScreen.id) }
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)).resizable().frame(width: 34, height: 34)
                Text(verbatim: "Cutline").font(.title3.weight(.semibold))
            }
            .padding(.bottom, 24)
            Button { StartScreen.newDocument() } label: {
                Text("New Document").padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            Button("Open…") { NSDocumentController.shared.openDocument(nil) }
                .buttonStyle(.borderless)
                .padding(.top, 12)
                .padding(.leading, 6)
            Divider().padding(.vertical, 18)
            Text("MACHINE").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 8)
            machineStatus
            Spacer()
            Button { openWindow(value: ReportKind.bug) } label: { Label("Report a Bug…", image: .info) }
                .buttonStyle(.borderless)
                .padding(.bottom, 8)
            SettingsLink { Label("Settings…", image: .snap) }
                .buttonStyle(.borderless)
        }
        .foregroundStyle(.primary)
        .padding(22)
        .padding(.top, 18)
        .frame(width: 240, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.quaternary.opacity(0.35))
    }

    private var machineStatus: some View {
        let connected: Bool = switch machine.state {
        case .connected, .sent, .sending: true
        default: false
        }
        let connecting: Bool = if case .connecting = machine.state { true } else { false }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(connected ? Color.green : Color.secondary).frame(width: 7, height: 7)
                if let current = machine.current, connected {
                    Text(verbatim: "\(machine.modelName) · \(current.link == .usb ? "USB" : "Bluetooth")")
                } else {
                    Text(connecting ? "Connecting…" as LocalizedStringKey : "No machine connected")
                }
            }
            .font(.callout)
            if !connected, !connecting {
                Button("Connect") { Task { await machine.connect() } }
                    .controlSize(.small)
                    .disabled(machine.studioOpen)
            }
        }
    }

    // MARK: Main

    private var main: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Text("Welcome to Cutline").font(.system(size: 26))
                    Toggle("Show at launch", isOn: $showAtLaunch)
                        .toggleStyle(.checkbox)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.top, 30)
                heading("START WITH").padding(.top, 30)
                HStack(spacing: 14) {
                    StartCard(icon: .newDocument, title: "Blank sheet", detail: "A4, ready to draw or import") { StartScreen.newDocument() }
                    StartCard(icon: .registrationMarks, title: "Print & Cut", detail: "A4 with the registration marks") {
                        StartScreen.newDocument(.printAndCut)
                    }
                    StartCard(icon: .toolTrace, title: "Trace an image", detail: "PNG or JPEG → cut line") { pick([.image]) }
                    StartCard(icon: .openDocument, title: "Silhouette Studio file", detail: "Opens a .studio3") { pick([.studio3]) }
                }
                heading("RECENT").padding(.top, 32)
                if recent.isEmpty {
                    Text("The files you open show up here.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 30)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 14)], alignment: .leading, spacing: 14) {
                        ForEach(recent, id: \.self) { url in RecentCard(url: url) }
                    }
                }
                Text("Drop a file anywhere on this window to open it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
            }
            .padding(.horizontal, 36)
        }
    }

    private func heading(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 10)
    }

    /// Image to trace (a new document asks what to do with it) or a .studio3 to open.
    private func pick(_ kinds: [UTType]) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = kinds
        panel.begin { answer in
            if answer == .OK, let url = panel.url { StartScreen.open([url]) }
        }
    }
}

/// One of the ways to start.
private struct StartCard: View {
    let icon: ImageResource
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let action: () -> Void
    @State private var over = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(icon).resizable().frame(width: 24, height: 24)
                    .frame(width: 46, height: 46)
                    .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(.quaternary.opacity(over ? 0.9 : 0.5), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { over = $0 }
    }
}

/// A recent file: its page drawn small, the name, the kind and when it changed.
private struct RecentCard: View {
    let url: URL
    @State private var preview: CGImage?
    @State private var over = false

    var body: some View {
        Button {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Rectangle().fill(.black.opacity(0.18))
                    if let preview {
                        Image(decorative: preview, scale: 2).resizable().aspectRatio(contentMode: .fit)
                            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                            .padding(10)
                    } else {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 64, height: 64)
                    }
                }
                .frame(height: 170)
                VStack(alignment: .leading, spacing: 3) {
                    Text(url.deletingPathExtension().lastPathComponent).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(kind).font(.caption).foregroundStyle(.secondary)
                    if let date { Text(date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.quaternary.opacity(over ? 0.9 : 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { over = $0 }
        .help(url.path)
        .task { preview = Self.preview(of: url) }
    }

    private var kind: LocalizedStringKey {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .studio3) == true ? "Silhouette Studio" : "Cutline"
    }

    private var date: Date? { (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }

    /// The page as printed (fills, images, printed strokes, marks) plus the cut lines, from the file; nil if it can't be
    /// read.
    static func preview(of url: URL) -> CGImage? {
        guard let payload = try? Data(contentsOf: url) else { return nil }
        let doc: Document
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .studio3) == true {
            guard let studio = try? StudioDocument(data: payload) else { return nil }
            let (objects, _, images, _, _) = Document.importResult(studio)
            doc = Document(objects: objects, images: images, marks: studio.registrationMarks?.on ?? false,
                           marksConfig: studio.registrationMarks.map(MarksConfig.init) ?? .defaultValue)
        } else {
            guard let file = try? DocumentFile.read(payload) else { return nil }
            doc = Document(objects: file.objects, images: file.images, layers: file.layers, marks: file.marks, marksConfig: file.marksConfig)
        }
        // 2 px per point of a 150 pt wide page.
        let width = 300, scale = Double(width) / (Document.page.width * Printing.pointsPerMM)
        let height = Int((Document.page.height * Printing.pointsPerMM * scale).rounded())
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // The page is drawn y down, as in the print view.
        ctx.translateBy(x: 0, y: Double(height))
        ctx.scaleBy(x: scale, y: -scale)
        Printing.render(doc, in: ctx)
        // The 0 pt cut lines don't print, but they are most of a sticker sheet: thin, in their color.
        ctx.scaleBy(x: Printing.pointsPerMM, y: Printing.pointsPerMM)
        ctx.setLineWidth(0.4)
        for object in doc.objectsInOrder where doc.visible(object) && object.cutsLine && object.strokeWidth == 0 {
            ctx.addPath(object.shapePath.cgPath)
            ctx.setStrokeColor(object.strokeColor.cgCMYK)
            ctx.strokePath()
        }
        return ctx.makeImage()
    }
}
