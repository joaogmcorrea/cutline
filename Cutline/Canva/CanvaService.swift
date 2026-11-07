// File › Open from Canva…: the person's Canva designs, searched and sorted, and one page of one design exported as a PDF
// and opened as a new document through the PDF import (Model/PDFImport.swift). Canva only takes integrations whose
// credentials stay on a server (the client secret, the PKCE verifier and the Canva tokens), so every Canva call goes
// through Cutline's backend at cutline.joaocorrea.design/canva/ (its PHP is outside this repository): the app holds
// only a session with that backend, a random token kept in the Keychain. The menu item stays hidden until the
// Info.plist has the backend's address (`CanvaServer`), which is set once Canva approves the integration.
// The window: Canva/CanvaWindow.swift.
import AuthenticationServices
import Foundation
import Security

/// Where the backend is. Without it, Open from Canva… doesn't show up. The Info.plist's `CanvaServer` turns it on for
/// everybody; the `canvaServer` preference turns it on in one Mac only, to try it before Canva approves the integration
/// (the owner, Canva's reviewers): `defaults write io.github.joaogmcorrea.cutline canvaServer https://…/canva/`.
enum CanvaConfig {
    static var server: URL? {
        #if DEBUG
        if let test = DebugHooks.canvaServer { return test }
        #endif
        let text = (Bundle.main.object(forInfoDictionaryKey: "CanvaServer") as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? UserDefaults.standard.string(forKey: "canvaServer") ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed.hasSuffix("/") ? trimmed : trimmed + "/"), url.scheme == "https"
        else { return nil }
        return url
    }

    static var isEnabled: Bool { server != nil }

    /// The sign-in window ends when the backend sends the browser to cutline://canva/callback (the scheme doesn't need
    /// registering: the sign-in window catches it).
    static let callbackScheme = "cutline"
}

/// A design in the list.
nonisolated struct CanvaDesign: Identifiable, Hashable, Decodable, Sendable {
    let id: String
    let title: String
    /// Canva doesn't always know (some design types).
    let pageCount: Int?
    let updatedAt: Date?
    let thumbnail: Thumbnail?

    nonisolated struct Thumbnail: Hashable, Decodable, Sendable {
        /// Works for 15 minutes.
        let url: URL
        let width: Int
        let height: Int
    }

    enum CodingKeys: String, CodingKey {
        case id, title, thumbnail, pageCount = "page_count", updatedAt = "updated_at"
    }

    init(id: String, title: String, pageCount: Int?, updatedAt: Date?, thumbnail: Thumbnail?) {
        self.id = id
        self.title = title
        self.pageCount = pageCount
        self.updatedAt = updatedAt
        self.thumbnail = thumbnail
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount)
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        thumbnail = try? c.decodeIfPresent(Thumbnail.self, forKey: .thumbnail)
    }

    var displayTitle: String { title.isEmpty ? String(localized: "Untitled design") : title }

    /// More than one page: the window asks which one.
    var hasPages: Bool { (pageCount ?? 1) > 1 }
}

/// One page of the list and what loads the next.
nonisolated struct CanvaDesignList: Decodable, Sendable {
    let items: [CanvaDesign]
    let continuation: String?
}

/// Canva's export job, as the backend passes it.
nonisolated struct CanvaExportJob: Decodable, Sendable {
    let id: String
    let status: String
    let urls: [URL]?
    let error: JobError?

    nonisolated struct JobError: Decodable, Sendable {
        let code: String
        let message: String?
    }
}

/// How the list is sorted (Canva's `sort_by`).
enum CanvaSort: String, CaseIterable, Identifiable {
    case modifiedDescending = "modified_descending"
    case relevance
    case titleAscending = "title_ascending"
    case titleDescending = "title_descending"
    case modifiedAscending = "modified_ascending"

    var id: Self { self }

    var name: String {
        switch self {
        case .modifiedDescending: String(localized: "Last Edited")
        case .relevance: String(localized: "Relevance")
        case .titleAscending: String(localized: "Title (A–Z)")
        case .titleDescending: String(localized: "Title (Z–A)")
        case .modifiedAscending: String(localized: "Oldest Edited")
        }
    }
}

/// What went wrong, in words for the person (Canva asks for no low-level messages).
enum CanvaError: LocalizedError, Equatable {
    case offline, signedOut, cancelled, denied, signInFailed, licenseRequired, approvalRequired, rateLimited, exportFailed,
         notFound, server, unreadable

    var errorDescription: String? {
        switch self {
        case .offline: String(localized: "Cutline can’t reach Canva right now. Check your internet connection and try again.")
        case .signedOut: String(localized: "Your Canva session has ended. Connect to Canva again to see your designs.")
        case .cancelled: nil
        case .denied: String(localized: "Canva didn’t give Cutline access to your designs.")
        case .signInFailed: String(localized: "Connecting to Canva didn’t finish. Try again.")
        case .licenseRequired:
            String(localized: "This design has premium elements that your Canva account can’t export. Remove them or get a license for them in Canva, then try again.")
        case .approvalRequired: String(localized: "This design needs a reviewer’s approval in Canva before it can be exported.")
        case .rateLimited: String(localized: "Canva is limiting requests for now. Wait a few minutes and try again.")
        case .exportFailed: String(localized: "Canva couldn’t export this design. Try again in a moment.")
        case .notFound: String(localized: "This design isn’t available anymore. Refresh the list and try again.")
        case .server: String(localized: "Something went wrong while talking to Canva. Try again in a moment.")
        case .unreadable: String(localized: "The PDF from Canva couldn’t be read.")
        }
    }

    /// The error of a network call (no connection, the backend or Canva not answering…).
    static func network(_ error: Error) -> CanvaError {
        if error is CancellationError { return .cancelled }
        guard let urlError = error as? URLError else { return .server }
        switch urlError.code {
        case .cancelled: return .cancelled
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .timedOut,
             .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed:
            return .offline
        default: return .server
        }
    }
}

/// The app's session with the backend (never a Canva token): in the login keychain, as "Cutline: Canva". Read and
/// written away from the main thread (the Keychain may ask for the Mac's password).
nonisolated enum CanvaSessionStore {
    private static let service = "io.github.joaogmcorrea.cutline.canva"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "session"]
    }

    static func load() -> String? {
        #if DEBUG
        if let file = DebugHooks.canvaSessionFile { return try? String(contentsOf: file, encoding: .utf8) }
        #endif
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) {
        #if DEBUG
        if let file = DebugHooks.canvaSessionFile { try? token.write(to: file, atomically: true, encoding: .utf8); return }
        #endif
        let data = Data(token.utf8)
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Cutline: Canva"
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete() {
        #if DEBUG
        if let file = DebugHooks.canvaSessionFile { try? FileManager.default.removeItem(at: file); return }
        #endif
        SecItemDelete(query as CFDictionary)
    }
}

/// The backend's addresses (`_site/canva/README.md` in the project folder), with the session in X-Cutline-Session.
@MainActor final class CanvaClient {
    let server: URL
    private(set) var session: String?
    private let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 40
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    init(server: URL) {
        self.server = server
    }

    var signedIn: Bool { session != nil }

    /// The session kept from an earlier sign-in. The Keychain may ask the person for their Mac password once after an
    /// update (a new build of the app); that wait happens away from the main thread.
    func restore() async {
        session = await Task.detached { CanvaSessionStore.load() }.value
    }

    // MARK: Sign in and out

    /// Signs in: the backend makes the Canva consent address, `authenticate` shows it (the system's sign-in window)
    /// and returns the cutline://canva/callback address the backend sent the browser to, and the ticket in it becomes
    /// the session. The login key never passes through the browser, so only this app can turn the ticket into a session.
    func signIn(authenticate: (URL) async throws -> URL) async throws {
        struct Login: Decodable {
            let authorize_url: URL
            let login_key: String
            let state: String
        }
        struct Session: Decodable {
            let session: String
        }
        let login: Login = try await call("login/", body: [String: String]())
        let callback: URL
        do {
            callback = try await authenticate(login.authorize_url)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            throw CanvaError.cancelled
        } catch let error as CanvaError {
            throw error
        } catch {
            throw CanvaError.network(error) == .server ? CanvaError.signInFailed : CanvaError.network(error)
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard callback.scheme == CanvaConfig.callbackScheme, value("state") == login.state else { throw CanvaError.signInFailed }
        if let error = value("error") { throw error == "access_denied" ? CanvaError.denied : CanvaError.signInFailed }
        guard let ticket = value("ticket") else { throw CanvaError.signInFailed }
        let new: Session
        do {
            new = try await call("session/", body: ["ticket": ticket, "login_key": login.login_key])
        } catch CanvaError.server {
            throw CanvaError.signInFailed   // the ticket was refused (too old, or used)
        }
        // A session of an earlier sign-in (maybe another Canva account) ends on the backend too.
        if let old = session { _ = try? await logout(old) }
        session = new.session
        let token = new.session
        await Task.detached { CanvaSessionStore.save(token) }.value
    }

    /// Sign Out: the backend tells Canva to forget the sign-in; the app forgets its session even when that fails.
    func signOut() async {
        if let old = session { _ = try? await logout(old) }
        forget()
    }

    private func logout(_ token: String) async throws -> Bool {
        struct Answer: Decodable { let ok: Bool }
        let answer: Answer = try await call("logout/", body: [String: String](), session: token)
        return answer.ok
    }

    private func forget() {
        session = nil
        Task.detached { CanvaSessionStore.delete() }
    }

    // MARK: Designs and exports

    func designs(query: String, sort: CanvaSort, continuation: String?) async throws -> CanvaDesignList {
        var items = [URLQueryItem(name: "sort_by", value: sort.rawValue)]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { items.append(URLQueryItem(name: "query", value: String(trimmed.prefix(255)))) }
        if let continuation { items.append(URLQueryItem(name: "continuation", value: continuation)) }
        return try await call("designs/", query: items)
    }

    /// Starts the PDF export of one page (all of them without `page`).
    func startExport(design: String, page: Int?) async throws -> CanvaExportJob {
        struct Body: Encodable {
            let design_id: String
            let page: Int?
        }
        struct Answer: Decodable { let job: CanvaExportJob }
        let answer: Answer = try await call("exports/", body: Body(design_id: design, page: page))
        return answer.job
    }

    func exportJob(_ id: String) async throws -> CanvaExportJob {
        struct Answer: Decodable { let job: CanvaExportJob }
        let answer: Answer = try await call("exports/", query: [URLQueryItem(name: "id", value: id)])
        return answer.job
    }

    /// Exports one page as a PDF and downloads it to a temporary folder, named after the design. `downloading` is called
    /// when Canva has the file ready. Asks Canva again with a growing pause (1 s up to 5 s), for up to 3 minutes.
    func exportPDF(_ design: CanvaDesign, page: Int?, downloading: () -> Void) async throws -> URL {
        var job = try await startExport(design: design.id, page: page)
        var pause = 1.0
        let deadline = Date().addingTimeInterval(180)
        while job.status == "in_progress" {
            guard Date() < deadline else { throw CanvaError.exportFailed }
            do { try await Task.sleep(for: .seconds(pause)) } catch { throw CanvaError.cancelled }
            pause = min(pause * 1.5, 5)
            job = try await exportJob(job.id)
        }
        if job.status == "failed" {
            switch job.error?.code {
            case "license_required": throw CanvaError.licenseRequired
            case "approval_required": throw CanvaError.approvalRequired
            default: throw CanvaError.exportFailed
            }
        }
        guard job.status == "success", let link = job.urls?.first else { throw CanvaError.exportFailed }
        downloading()
        let downloaded: URL, response: URLResponse
        do {
            (downloaded, response) = try await urlSession.download(from: link)
        } catch {
            throw CanvaError.network(error)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CanvaError.exportFailed }
        // "Gift tags (page 2).pdf", in a folder of its own: the import's notice and the many-paths question show the name.
        var name = design.displayTitle.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if let page, design.hasPages { name += " " + String(localized: "(page \(page))") }
        let folder = FileManager.default.temporaryDirectory.appending(path: "Canva-\(UUID().uuidString)", directoryHint: .isDirectory)
        let file = folder.appending(path: String(name.prefix(120)) + ".pdf")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: downloaded, to: file)
        } catch {
            throw CanvaError.unreadable
        }
        return file
    }

    // MARK: Calls

    private struct ServerError: Decodable {
        let error: String
    }

    private func call<Answer: Decodable>(_ path: String, query: [URLQueryItem] = [], body: (some Encodable)? = String?.none,
                                         session explicit: String? = nil) async throws -> Answer {
        var parts = URLComponents(url: URL(string: path, relativeTo: server)!.absoluteURL, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        var request = URLRequest(url: parts.url!)
        request.setValue("1", forHTTPHeaderField: "X-Cutline")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = explicit ?? session { request.setValue(token, forHTTPHeaderField: "X-Cutline-Session") }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw CanvaError.network(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status), let answer = try? JSONDecoder().decode(Answer.self, from: data) { return answer }
        let code = (try? JSONDecoder().decode(ServerError.self, from: data))?.error ?? ""
        #if DEBUG
        NSLog("CUTLINE_TEST canva %@ → %ld %@", path, status, code)
        #endif
        switch (status, code) {
        case (401, _):
            // The session ended (Sign Out on another Mac, access taken away in Canva, a long time unused).
            if explicit == nil { forget() }
            throw CanvaError.signedOut
        case (429, _): throw CanvaError.rateLimited
        case (404, _), (403, "permission_denied"): throw CanvaError.notFound
        default: throw CanvaError.server   // 502: the backend couldn't reach Canva; 500/503: the backend itself
        }
    }
}
