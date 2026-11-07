// Google Fonts in the font list (the "Google Fonts" tab of FontList, Editor/TextPanel.swift), like Illustrator's Find More.
//
// The catalog ships with the app (google-fonts.json, made before each release from the official github.com/google/fonts
// repository, checked against the CSS API): no API key, and nothing goes out until the tab opens. Then the tab asks
// Google's CSS API (fonts.googleapis.com/css2) for the name of each visible row only (the `text` parameter gives a font
// with just those letters, read by CoreText and never registered), and for every style of a family when it's added.
//
// Added fonts stay in ~/Library/Application Support/Cutline/Google Fonts/<family>/ (static TrueType files, one per
// style) and are registered for this process only (CTFontManagerScope.process): no other app sees them, even with
// Cutline open, and they never go to ~/Library/Fonts. At every launch they're registered again before the documents
// open, so texts never show in another font first (owner's decisions, 05/11/2026).
import AppKit
import CoreText
import Network

/// A family of the Google Fonts catalog.
nonisolated struct GoogleFamily: Decodable, Identifiable, Hashable {
    let name: String
    /// sans-serif, serif, display, handwriting, monospace (a few families have two).
    let category: [String]
    /// OFL, Apache or UFL.
    let license: String
    /// The styles as the CSS API takes them: "ital,wght" pairs, "0,400;1,700".
    let styles: String
    /// Has Latin letters (otherwise its name isn't written in it).
    let latin: Bool

    var id: String { name }
    var styleCount: Int { styles.split(separator: ";").count }
}

nonisolated enum GoogleFontsError: Error {
    /// Google answered, but not with this family (a style that no longer exists, a family taken down).
    case notServed
    /// The files came, but CoreText can't read them.
    case unreadable
}

@Observable
final class GoogleFonts {
    static let shared = GoogleFonts()

    /// The catalog that ships with the app, in alphabetical order (read on first use, no network).
    static let catalog: [GoogleFamily] = {
        guard let url = Bundle.main.url(forResource: "google-fonts", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        struct List: Decodable { let families: [GoogleFamily] }
        return (try? JSONDecoder().decode(List.self, from: data))?.families ?? []
    }()

    private static let byName: [String: GoogleFamily] =
        Dictionary(catalog.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

    /// Families added to Cutline: the name in the catalog → the family name CoreText reads in the files (the same
    /// one, as far as seen; the list and the texts use this one).
    private(set) var added: [String: String] = [:]
    /// Families being downloaded, with how far they are (0…1).
    private(set) var downloading: [String: Double] = [:]
    /// Families whose last attempt failed.
    private(set) var failed: Set<String> = []
    /// Google Fonts doesn't answer (no network, or the network is up and Google isn't): the tab says so.
    private(set) var unreachable = false
    /// Goes up when the network comes back: the visible rows ask for their names again.
    private(set) var retry = 0

    @ObservationIgnored private var previews: [String: CTFont] = [:]
    @ObservationIgnored private var running = 0
    @ObservationIgnored private var queue: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var networkWasDown = false

    private init() {}

    static func family(named name: String) -> GoogleFamily? { byName[name] }

    /// A font missing from this Mac that Google Fonts has (the text's family name).
    static func missing(_ name: String) -> GoogleFamily? {
        FontCatalog.shared.installedOnes.contains(name) ? nil : byName[name]
    }

    /// The family is on the Mac without Cutline adding it (installed with Font Book, or by another app).
    func isOnMac(_ family: GoogleFamily) -> Bool {
        added[family.name] == nil && FontCatalog.shared.installedOnes.contains(family.name)
    }

    /// The family name to give a text (the one CoreText reads in the files).
    func installedName(_ family: GoogleFamily) -> String { added[family.name] ?? family.name }

    /// The catalog name of a family Cutline added, from the name the list and the texts use.
    func addedFamily(installedAs name: String) -> String? {
        added.first { $0.value == name }?.key
    }

    // MARK: Folders

    /// Where added fonts live. Tests use their own folder (DebugHooks.googleFontsFolder), never this one.
    nonisolated static var folder: URL {
        #if DEBUG
        if let test = DebugHooks.googleFontsFolder { return test.appending(path: "Fonts", directoryHint: .isDirectory) }
        #endif
        return URL.applicationSupportDirectory.appending(path: "Cutline/Google Fonts", directoryHint: .isDirectory)
    }

    /// The answers of the CSS API and the name fonts (HTTP cache: a day for the CSS, a year for the fonts).
    nonisolated static var cacheFolder: URL {
        #if DEBUG
        if let test = DebugHooks.googleFontsFolder { return test.appending(path: "Cache", directoryHint: .isDirectory) }
        #endif
        return URL.cachesDirectory.appending(path: (Bundle.main.bundleIdentifier ?? "Cutline") + "/Google Fonts",
                                             directoryHint: .isDirectory)
    }

    nonisolated private static func fontFiles(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["ttf", "otf", "woff2"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: Launch

    /// At launch, before the documents open: registers every added family for this process.
    static func activateAdded() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                                    options: .skipsHiddenFiles)) ?? []
        for familyFolder in folders where familyFolder.hasDirectoryPath {
            if let name = register(fontFiles(in: familyFolder)) { shared.added[familyFolder.lastPathComponent] = name }
        }
        #if DEBUG
        DebugHooks.googleFontsActivated(shared.added)
        #endif
    }

    /// Registers the files for this process only; the family name CoreText reads in them (nil when none registered).
    private static func register(_ files: [URL]) -> String? {
        var family: String?
        for url in files {
            var error: Unmanaged<CFError>?
            let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            let already = (error?.takeRetainedValue()).map { CFErrorGetCode($0) == CTFontManagerError.alreadyRegistered.rawValue } ?? false
            guard registered || already, family == nil else { continue }
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
            family = descriptors.first.flatMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String }
        }
        return family
    }

    // MARK: Network

    /// Google's CSS API (documented at developers.google.com/fonts/docs/css2).
    nonisolated private static var cssAPI: String {
        #if DEBUG
        if let test = DebugHooks.googleFontsCSS { return test }
        #endif
        return "https://fonts.googleapis.com/css2"
    }

    /// Previews and the CSS: cached on disk by the HTTP rules, no cookies.
    nonisolated private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 4 << 20, diskCapacity: 40 << 20, directory: cacheFolder)
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    /// The family's files: saved in its folder, so not kept in a cache too.
    nonisolated private static let files: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 60
        return URLSession(configuration: configuration)
    }()

    /// One @font-face of the CSS API's answer. To this app (CFNetwork's user agent) it gives TrueType files, one per
    /// style, with the style's PostScript name; CoreText also reads WOFF2, in case that ever changes.
    nonisolated private struct Face: Sendable {
        let italic: Bool
        let weight: Int
        let url: URL
    }

    nonisolated private static func faces(_ query: String) async throws -> [Face] {
        guard let url = URL(string: cssAPI + "?" + query) else { throw GoogleFontsError.notServed }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let css = String(data: data, encoding: .utf8) else {
            throw GoogleFontsError.notServed
        }
        return css.components(separatedBy: "@font-face").dropFirst().compactMap { block in
            guard let match = block.firstMatch(of: /url\(([^)]+)\)/), let url = URL(string: String(match.1)) else { return nil }
            let weight = block.firstMatch(of: /font-weight:\s*(\d+)/).flatMap { Int($0.1) } ?? 400
            return Face(italic: block.contains("font-style: italic"), weight: weight, url: url)
        }
    }

    /// family=Open+Sans (the names only have letters, digits and spaces).
    nonisolated private static func familyParameter(_ name: String) -> String {
        (name.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: " "))) ?? name)
            .replacingOccurrences(of: " ", with: "+")
    }

    private static let unreachableCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .timedOut,
        .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed,
    ]

    private func note(_ error: Error) {
        if let error = error as? URLError, Self.unreachableCodes.contains(error.code) { unreachable = true }
    }

    /// While the tab is open: the notice comes on when the Mac goes offline, and the rows ask again when it's back.
    func watchNetwork() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            MainActor.assumeIsolated {
                let fonts = GoogleFonts.shared
                if path.status == .satisfied {
                    if fonts.networkWasDown {
                        fonts.unreachable = false
                        fonts.retry += 1
                    }
                    fonts.networkWasDown = false
                } else {
                    fonts.networkWasDown = true
                    fonts.unreachable = true
                }
            }
        }
        monitor.start(queue: .main)
        self.monitor = monitor
    }

    func stopWatchingNetwork() {
        monitor?.cancel()
        monitor = nil
    }

    // MARK: Previews

    /// The family's name written in itself, for its row: a font with only those letters (a few KB), never registered.
    /// At most six at a time; a row that scrolls away before its turn gives up (its task is cancelled).
    func preview(_ family: GoogleFamily) async -> CTFont? {
        if let font = previews[family.name] { return font }
        guard family.latin else { return nil }
        if running >= 6 { await withCheckedContinuation { queue.append($0) } }
        running += 1
        defer {
            running -= 1
            if !queue.isEmpty { queue.removeFirst().resume() }
        }
        guard !Task.isCancelled else { return nil }
        do {
            let text = family.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? family.name
            guard let face = try await Self.faces("family=" + Self.familyParameter(family.name) + "&text=" + text).first else {
                return nil
            }
            let (data, _) = try await Self.session.data(from: face.url)
            guard let descriptor = (CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor])?.first else {
                return nil
            }
            let font = CTFontCreateWithFontDescriptor(descriptor, 15, nil)
            previews[family.name] = font
            unreachable = false
            return font
        } catch {
            note(error)
            return nil
        }
    }

    // MARK: Adding and removing

    /// Downloads every style of the family, then registers it for this process: it shows in the Installed tab, in the
    /// style menu, and the texts in it redraw (FontCatalog hears CoreText). `then` runs once it's in.
    func add(_ family: GoogleFamily, then: (@MainActor (String) -> Void)? = nil) {
        // A family already on the Mac isn't added again (two fonts with the same PostScript names in one process).
        guard downloading[family.name] == nil, added[family.name] == nil, !isOnMac(family) else { return }
        downloading[family.name] = 0
        failed.remove(family.name)
        Task {
            do {
                let name = try await download(family)
                added[family.name] = name
                unreachable = false
                #if DEBUG
                DebugHooks.googleFontAdded(family.name, as: name)
                #endif
                then?(name)
            } catch {
                note(error)
                failed.insert(family.name)
                #if DEBUG
                NSLog("CUTLINE_TEST google failed %@: %@", family.name, "\(error)")
                #endif
            }
            downloading[family.name] = nil
        }
    }

    private func download(_ family: GoogleFamily) async throws -> String {
        let parameter = Self.familyParameter(family.name)
        var faces: [Face]
        do {
            faces = try await Self.faces("family=" + parameter + ":ital,wght@" + family.styles)
        } catch GoogleFontsError.notServed {
            // A style of the catalog that Google no longer has: at least the regular one.
            faces = try await Self.faces("family=" + parameter)
        }
        guard !faces.isEmpty else { throw GoogleFontsError.notServed }

        // Into a hidden folder first: a download cut in the middle never gets registered.
        let manager = FileManager.default
        try manager.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let staging = Self.folder.appending(path: ".adding-" + UUID().uuidString, directoryHint: .isDirectory)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }

        var done = 0
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            while next < min(4, faces.count) {
                let face = faces[next]
                group.addTask { try await Self.save(face, into: staging) }
                next += 1
            }
            for try await _ in group {
                done += 1
                downloading[family.name] = Double(done) / Double(faces.count)
                if next < faces.count {
                    let face = faces[next]
                    group.addTask { try await Self.save(face, into: staging) }
                    next += 1
                }
            }
        }

        let destination = Self.folder.appending(path: family.name, directoryHint: .isDirectory)
        if manager.fileExists(atPath: destination.path) {
            let leftovers = Self.fontFiles(in: destination)
            CTFontManagerUnregisterFontURLs(leftovers as CFArray, .process, nil)
            try manager.removeItem(at: destination)
        }
        try manager.moveItem(at: staging, to: destination)
        guard let name = Self.register(Self.fontFiles(in: destination)) else { throw GoogleFontsError.unreadable }
        return name
    }

    /// One style: downloaded, checked that CoreText reads it, and named after its PostScript name (Roboto-BoldItalic.ttf).
    nonisolated private static func save(_ face: Face, into folder: URL) async throws {
        #if DEBUG
        if DebugHooks.googleFontsSlow { try await Task.sleep(for: .seconds(1)) }
        #endif
        let (data, response) = try await files.data(from: face.url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let descriptor = (CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor])?.first,
              let postscript = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String else {
            throw GoogleFontsError.unreadable
        }
        let safe = postscript.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let kind = data.starts(with: Array("wOF2".utf8)) ? "woff2" : data.starts(with: Array("OTTO".utf8)) ? "otf" : "ttf"
        try data.write(to: folder.appending(path: safe + "." + kind), options: .atomic)
    }

    /// Takes the family out of Cutline: unregistered and its files deleted. Texts in it show in another font (with the
    /// warning of the Character panel) until it's added again.
    func remove(_ name: String) {
        let familyFolder = Self.folder.appending(path: name, directoryHint: .isDirectory)
        let files = Self.fontFiles(in: familyFolder)
        CTFontManagerUnregisterFontURLs(files as CFArray, .process, nil)
        try? FileManager.default.removeItem(at: familyFolder)
        added[name] = nil
        failed.remove(name)
        #if DEBUG
        NSLog("CUTLINE_TEST google removed %@ (folder left: %@)", name, "\(FileManager.default.fileExists(atPath: familyFolder.path))")
        #endif
    }
}
