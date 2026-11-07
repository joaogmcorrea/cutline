// The Open from Canva… window (the calls are in Canva/CanvaService.swift). Before signing in: Connect to Canva. Then the
// person's designs in a grid (thumbnail, title, pages, when edited), with search, sort, Refresh and Load More. A design
// with several pages asks which one (Canva's page previews are a preview API that public integrations can't use, so
// the pages go by number). The export shows its progress, and the page opens as a new document (MainWindow, through
// `StartScreen.Setup.canva`). "Powered by Canva" stays at the bottom, as Canva's brand guidelines ask of any window for
// working with Canva, and nothing says or suggests that Canva makes or endorses Cutline.
import AppKit
import AuthenticationServices
import SwiftUI

/// What the window shows and does.
@Observable @MainActor final class CanvaBrowser {
    enum Phase { case starting, signedOut, browsing }
    enum Step { case exporting, downloading, opening }

    struct Export {
        let design: CanvaDesign
        let page: Int?
        var step: Step
    }

    var phase = Phase.starting
    var designs: [CanvaDesign] = []
    var continuation: String?
    var query = ""
    var sort = CanvaSort.modifiedDescending
    /// A new list on its way (a search, the sort, Refresh).
    var listing = false
    var loadingMore = false
    var signingIn = false
    var error: CanvaError?
    /// What Try Again does after an error.
    var retry: (() -> Void)?
    var export: Export?
    /// The design whose page is being chosen, and the page.
    var pagePicker: CanvaDesign?
    var pickerPage = 1
    /// What opens the exported PDF (the window sets it).
    var onOpen: ((URL, CanvaDesign) -> Void)?

    let client: CanvaClient?
    /// When the list was loaded: Canva's thumbnail links work for 15 minutes.
    private var listedAt: Date?
    private var generation = 0
    private var listTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?

    init() {
        client = CanvaConfig.server.map { CanvaClient(server: $0) }
    }

    func start() async {
        guard let client else { phase = .signedOut; return }
        await client.restore()
        phase = client.signedIn ? .browsing : .signedOut
        if client.signedIn { reload() }
    }

    // MARK: Signing in

    func signIn(_ authenticate: @escaping (URL) async throws -> URL) {
        guard let client, !signingIn else { return }
        signingIn = true
        error = nil
        Task {
            defer { signingIn = false }
            do {
                try await client.signIn(authenticate: authenticate)
                phase = .browsing
                reload()
            } catch {
                show(error, retry: nil)
            }
        }
    }

    func signOut() {
        guard let client else { return }
        cancelAll()
        Task {
            await client.signOut()
            phase = .signedOut
            designs = []
            continuation = nil
            error = nil
        }
    }

    // MARK: The list

    /// A new list (search, sort, Refresh): the older request, if still on its way, is dropped.
    func reload() {
        generation += 1
        let mine = generation
        listTask?.cancel()
        listing = true
        listTask = Task { await list(more: false, generation: mine) }
    }

    /// The search waits for a pause in the typing.
    func queryChanged() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { reload() }
        }
    }

    func loadMore() {
        guard continuation != nil, !loadingMore, !listing else { return }
        let mine = generation
        loadingMore = true
        listTask = Task { await list(more: true, generation: mine) }
    }

    /// Back to the window after a while: a list older than 14 minutes comes again, with thumbnail links that work.
    func refreshIfStale() {
        guard phase == .browsing, export == nil, let listedAt, Date().timeIntervalSince(listedAt) > 14 * 60 else { return }
        reload()
    }

    private func list(more: Bool, generation mine: Int) async {
        guard let client else { return }
        defer {
            if mine == generation {
                if more { loadingMore = false } else { listing = false }
            }
        }
        do {
            let page = try await client.designs(query: query, sort: sort, continuation: more ? continuation : nil)
            guard mine == generation, !Task.isCancelled else { return }
            if more {
                let known = Set(designs.map(\.id))
                designs += page.items.filter { !known.contains($0.id) }
            } else {
                designs = page.items
                listedAt = Date()
            }
            continuation = page.continuation
            error = nil
        } catch {
            guard mine == generation, !Task.isCancelled else { return }
            show(error) { [weak self] in more ? self?.loadMore() : self?.reload() }
        }
    }

    // MARK: Opening a design

    func choose(_ design: CanvaDesign) {
        guard export == nil else { return }
        if design.hasPages {
            pickerPage = 1
            pagePicker = design
        } else {
            open(design, page: nil)
        }
    }

    func open(_ design: CanvaDesign, page: Int?) {
        guard let client, export == nil else { return }
        pagePicker = nil
        error = nil
        export = Export(design: design, page: page, step: .exporting)
        let again: () -> Void = { [weak self] in self?.open(design, page: page) }
        exportTask = Task {
            do {
                let file = try await client.exportPDF(design, page: page) { self.export?.step = .downloading }
                guard !Task.isCancelled else { return }
                export?.step = .opening
                onOpen?(file, design)
                export = nil
            } catch {
                export = nil
                show(error, retry: again)
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
        export = nil
    }

    private func cancelAll() {
        listTask?.cancel()
        searchTask?.cancel()
        cancelExport()
        generation += 1
        listing = false
        loadingMore = false
    }

    /// An error for the person; a session that ended goes back to Connect to Canva.
    private func show(_ error: Error, retry: (() -> Void)?) {
        let canva = error as? CanvaError ?? .server
        guard canva != .cancelled else { return }
        if canva == .signedOut {
            cancelAll()
            phase = .signedOut
            designs = []
            continuation = nil
        }
        self.error = canva
        self.retry = canva == .signedOut ? nil : retry
    }
}

struct CanvaWindow: View {
    static let id = "canva"
    @State private var model = CanvaBrowser()
    @Environment(\.webAuthenticationSession) private var webAuthentication
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        Group {
            switch model.phase {
            case .starting: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signedOut: signIn
            case .browsing: browser
            }
        }
        .frame(minWidth: 720, minHeight: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay { if let export = model.export { exportProgress(export) } }
        .sheet(item: $model.pagePicker) { design in
            CanvaPagePicker(design: design, page: $model.pickerPage) { model.open(design, page: model.pickerPage) }
        }
        .onChange(of: activeState) { _, state in if state == .key { model.refreshIfStale() } }
        .task {
            model.onOpen = { file, design in
                StartScreen.newDocument(.canva(file, title: design.displayTitle))
                dismissWindow(id: Self.id)
            }
            await model.start()
            #if DEBUG
            await DebugHooks.driveCanva(model)
            #endif
        }
    }

    // MARK: Before signing in

    private var signIn: some View {
        VStack(spacing: 14) {
            Image(.designGrid).resizable().frame(width: 40, height: 40)
                .foregroundStyle(.secondary)
                .frame(width: 84, height: 84)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 20))
                .padding(.bottom, 6)
            Text("Open your Canva designs in Cutline").font(.title2.weight(.semibold))
            Text("Connect to Canva to see your designs here. Choose one, and the page you pick opens as a new Cutline document. Cutline only reads your designs: it never changes them.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
                .fixedSize(horizontal: false, vertical: true)
            Text("Shapes and text come in as paths and photos as images, as with any PDF you import.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
                .fixedSize(horizontal: false, vertical: true)
            if let message = model.error?.errorDescription {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(.warning).resizable().frame(width: 13, height: 13)
                    Text(message).fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
                .foregroundStyle(.orange)
                .frame(maxWidth: 460)
            }
            Button(action: connect) {
                HStack(spacing: 8) {
                    if model.signingIn { ProgressView().controlSize(.small) }
                    Text(model.signingIn ? "Waiting for Canva…" : "Connect to Canva")
                }
                .padding(.horizontal, 8)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(model.signingIn || model.client == nil)
            .padding(.top, 8)
            Spacer().frame(height: 18)
            poweredBy
            Text("Cutline works with Canva, but it isn’t made or endorsed by Canva.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The system's sign-in window (Safari or the default browser, with the person's Canva login), until the backend
    /// sends it to cutline://canva/callback.
    private func connect() {
        model.signIn { url in
            try await webAuthentication.authenticate(using: url, callback: .customScheme(CanvaConfig.callbackScheme),
                                                     preferredBrowserSession: .shared, additionalHeaderFields: [:])
        }
    }

    private var poweredBy: some View {
        Text("POWERED BY CANVA")
            .font(.caption2.weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(.secondary)
            .padding(8)
    }

    // MARK: The designs

    private var browser: some View {
        VStack(spacing: 0) {
            ScrollView {
                if model.designs.isEmpty {
                    emptyList
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 16)], alignment: .leading, spacing: 16) {
                        ForEach(model.designs) { design in
                            CanvaDesignCard(design: design) { model.choose(design) }
                        }
                    }
                    .padding(20)
                    .opacity(model.listing ? 0.45 : 1)
                    if model.continuation != nil {
                        Button {
                            model.loadMore()
                        } label: {
                            HStack(spacing: 8) {
                                if model.loadingMore { ProgressView().controlSize(.small) }
                                Text("Load More")
                            }
                            .padding(.horizontal, 10)
                        }
                        .buttonStyle(.glass)
                        .disabled(model.loadingMore || model.listing)
                        .padding(.bottom, 24)
                    }
                }
            }
            .overlay(alignment: .bottom) { if model.error != nil { errorBanner } }
            Divider()
            HStack {
                poweredBy
                Spacer()
                if model.listing || model.loadingMore {
                    ProgressView().controlSize(.small)
                } else if !model.designs.isEmpty {
                    Text(model.continuation == nil ? String(localized: "\(model.designs.count) designs")
                         : String(localized: "\(model.designs.count) designs so far"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
        }
        .searchable(text: $model.query, placement: .toolbar, prompt: Text("Search your designs"))
        .onChange(of: model.query) { _, _ in model.queryChanged() }
        .onChange(of: model.sort) { _, _ in model.reload() }
        .toolbar {
            ToolbarItem {
                Menu {
                    Picker("Sort By", selection: $model.sort) {
                        ForEach(CanvaSort.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label { Text("Sort") } icon: { Image(.sortOrder) }
                }
                .help("Sort the designs")
            }
            ToolbarItem {
                Button { model.reload() } label: { Label { Text("Refresh") } icon: { Image(.refresh) } }
                    .help("Load the list again")
                    .disabled(model.listing)
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button { model.signOut() } label: { Label { Text("Sign Out") } icon: { Image(.signOut) } }
                    .help("Disconnect Cutline from your Canva account")
            }
        }
    }

    @ViewBuilder
    private var emptyList: some View {
        VStack(spacing: 10) {
            if model.listing {
                ProgressView()
                Text("Loading your designs…").foregroundStyle(.secondary)
            } else if model.error == nil {
                Image(.designGrid).resizable().frame(width: 32, height: 32).foregroundStyle(.tertiary)
                Text(model.query.trimmingCharacters(in: .whitespaces).isEmpty ? String(localized: "No designs in your Canva account yet.")
                     : String(localized: "No designs match “\(model.query)”."))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 140)
    }

    /// The error, until dismissed, with Try Again (as the import notice of the document window).
    private var errorBanner: some View {
        HStack(spacing: 10) {
            Image(model.error == .offline ? .offline : .warning).resizable().frame(width: 15, height: 15)
                .foregroundStyle(.orange)
            Text(model.error?.errorDescription ?? "")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let retry = model.retry {
                Button("Try Again") {
                    model.error = nil
                    retry()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
            Button("OK") { withAnimation(.snappy(duration: 0.2)) { model.error = nil } }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: 640)
        .glassEffect(.regular, in: .capsule)
        .padding(.bottom, 16)
    }

    // MARK: The export

    private func exportProgress(_ export: CanvaBrowser.Export) -> some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 12) {
                CanvaThumbnail(design: export.design)
                    .frame(width: 160, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Text(export.design.displayTitle).font(.headline).lineLimit(1)
                Text(stepText(export)).font(.callout).foregroundStyle(.secondary)
                ProgressView().progressViewStyle(.linear).frame(width: 220)
                Button("Cancel") { model.cancelExport() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.glass)
                    .padding(.top, 4)
            }
            .padding(24)
            .frame(width: 320)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
        }
    }

    private func stepText(_ export: CanvaBrowser.Export) -> String {
        switch export.step {
        case .exporting:
            if let page = export.page, export.design.hasPages { String(localized: "Canva is exporting page \(page) as a PDF…") }
            else { String(localized: "Canva is exporting the design as a PDF…") }
        case .downloading: String(localized: "Downloading the PDF…")
        case .opening: String(localized: "Opening…")
        }
    }
}

/// A design in the grid: the thumbnail, the title, how many pages and when it was edited (as the start screen's recents).
private struct CanvaDesignCard: View {
    let design: CanvaDesign
    let action: () -> Void
    @State private var over = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                CanvaThumbnail(design: design).frame(height: 150)
                VStack(alignment: .leading, spacing: 3) {
                    Text(design.displayTitle).font(.callout.weight(.semibold)).lineLimit(1)
                    HStack(spacing: 4) {
                        if let pages = design.pageCount {
                            Image(.pages).resizable().frame(width: 11, height: 11)
                            Text("\(pages) pages")
                        }
                        if let date = design.updatedAt {
                            if design.pageCount != nil { Text(verbatim: "·") }
                            Text(date, format: .relative(presentation: .named))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
        .help(design.displayTitle)
    }
}

/// The design's thumbnail from Canva, kept in memory while the app is open (the link stops working after 15 minutes).
struct CanvaThumbnail: View {
    let design: CanvaDesign
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.18))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .padding(10)
            } else {
                Image(.designGrid).resizable().frame(width: 26, height: 26).foregroundStyle(.tertiary)
            }
        }
        .task(id: design.id) { image = await Self.load(design) }
    }

    private static let cache = NSCache<NSString, NSImage>()

    private static func load(_ design: CanvaDesign) async -> NSImage? {
        guard let url = design.thumbnail?.url else { return nil }
        let key = "\(design.id) \(design.updatedAt?.timeIntervalSince1970 ?? 0)" as NSString
        if let known = cache.object(forKey: key) { return known }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// Which page of a design with several (by number: public integrations can't use Canva's page previews).
private struct CanvaPagePicker: View {
    let design: CanvaDesign
    @Binding var page: Int
    let open: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let count = max(design.pageCount ?? 1, 1)
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                CanvaThumbnail(design: design)
                    .frame(width: 120, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(design.displayTitle).font(.headline).lineLimit(2)
                    Text("\(count) pages").foregroundStyle(.secondary)
                    Text("Which page do you want to open?").padding(.top, 6)
                }
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 46, maximum: 46), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(1...count, id: \.self) { number in
                        Button {
                            page = number
                        } label: {
                            Text(verbatim: "\(number)")
                                .font(.callout.weight(.medium).monospacedDigit())
                                .frame(width: 46, height: 38)
                                .foregroundStyle(number == page ? Color.white : Color.primary)
                                .background(number == page ? Color.accentColor : Color.primary.opacity(0.07),
                                            in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 190)
            .fixedSize(horizontal: false, vertical: count <= 24)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Open Page \(page)"), action: open)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
