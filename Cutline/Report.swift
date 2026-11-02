// Help › Report a Bug… / Request a Feature…: a window with what happened, how to reproduce it and what was
// expected (or the feature and what it would be for), plus the technical details (versions, Mac, machine and the
// driver log), which the person sees before sending. It goes as a GitHub issue (prefilled new-issue page) or by
// email (with the latest cut log attached); it can also just be copied.
import AppKit
import CutlineKit
import SwiftUI

enum ReportKind: String, Codable, Hashable, CaseIterable {
    case bug, feature

    var title: String {
        switch self {
        case .bug: String(localized: "Report a Bug")
        case .feature: String(localized: "Request a Feature")
        }
    }
}

/// Where the reports go.
enum Contact {
    static let repository = "joaogmcorrea/cutline"
    static let email = "cutline@joaocorrea.design"
    static var gitHubPage: URL { URL(string: "https://github.com/\(repository)")! }
}

/// The fields the person fills in and the text built from them.
struct Report {
    var kind: ReportKind
    var summary = ""
    /// Bug: what happened. Feature: what Cutline should do.
    var summaryText = ""
    /// Bug: the steps. Feature: what it would be for.
    var detail = ""
    /// Bug: what should have happened.
    var expected = ""
    var includeTechnical = true

    /// GitHub doesn't open pages with very long addresses: the log shrinks until it fits.
    static let urlLimit = 7_500

    var complete: Bool {
        !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var finalTitle: String {
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return kind == .bug ? summary : "[" + String(localized: "Feature") + "] " + summary
    }

    /// The text in Markdown. On GitHub, the log goes in a collapsible block.
    func text(_ technical: TechnicalInfo?, logLineCount: Int? = nil, forGitHub: Bool = true) -> String {
        var parts: [String] = []
        func section(_ title: String, _ pointSize: String) {
            let pointSize = pointSize.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pointSize.isEmpty else { return }
            parts.append("### \(title)\n\n\(pointSize)")
        }
        switch kind {
        case .bug:
            section(String(localized: "What happened"), summaryText)
            section(String(localized: "Steps to reproduce"), detail == Self.emptySteps ? "" : detail)
            section(String(localized: "What should have happened"), expected)
        case .feature:
            section(String(localized: "What Cutline should do"), summaryText)
            section(String(localized: "What it would be for"), detail)
        }
        if let technical {
            parts.append("### " + String(localized: "Technical details") + "\n\n" + technical.summary)
            let lines = technical.logLines.suffix(logLineCount ?? technical.logLines.count)
            if !lines.isEmpty {
                let title = String(localized: "Machine log (last \(lines.count) lines)")
                let block = "```\n" + lines.joined(separator: "\n") + "\n```"
                parts.append(forGitHub ? "<details><summary>\(title)</summary>\n\n\(block)\n\n</details>"
                                         : "\(title):\n\n\(block)")
            }
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    static let emptySteps = "1. \n2. \n3. "

    /// The prefilled new-issue page. If it doesn't fit even without the log, the text is cut and `cut` = true.
    func gitHubURL(_ technical: TechnicalInfo?) -> (url: URL, wasCut: Bool) {
        func url(_ pointSize: String) -> URL {
            var components = URLComponents(string: "https://github.com/\(Contact.repository)/issues/new")!
            components.queryItems = [URLQueryItem(name: "title", value: finalTitle),
                                      URLQueryItem(name: "body", value: pointSize),
                                      URLQueryItem(name: "labels", value: kind == .bug ? "bug" : "enhancement")]
            return components.url!
        }
        var lines = technical?.logLines.count ?? 0
        while true {
            let candidate = url(text(technical, logLineCount: lines))
            if candidate.absoluteString.count <= Self.urlLimit { return (candidate, false) }
            if lines == 0 { break }
            lines = lines > 10 ? lines / 2 : 0
        }
        var pointSize = text(technical, logLineCount: 0)
        let notice = "\n\n" + String(localized: "(Text cut short: the full report was copied; paste it here.)")
        while url(pointSize + notice).absoluteString.count > Self.urlLimit, !pointSize.isEmpty {
            pointSize.removeLast(min(200, pointSize.count))
        }
        return (url(pointSize + notice), true)
    }
}

/// What goes along with the report (the person sees everything before sending).
struct TechnicalInfo {
    let summary: String
    let logLines: [String]
    /// The transcript of the last cut (~/Library/Logs/Cutline), to attach to the email.
    let lastCut: URL?

    static var logsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Cutline")
    }

    /// Everything that goes along, as the person sees it before sending.
    var preview: String {
        var text = summary
        if !logLines.isEmpty { text += "\n\n" + logLines.joined(separator: "\n") }
        if let lastCut {
            text += "\n\n" + String(localized: "Attached to the email: \(lastCut.lastPathComponent)")
        }
        return text
    }

    @MainActor
    init(machine: Machine) {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        #if arch(arm64)
        let processor = "Apple Silicon"
        #else
        let processor = "Intel"
        #endif
        let language = [Bundle.main.preferredLocalizations.first, Locale.preferredLanguages.first]
            .compactMap(\.self).joined(separator: " / ")
        let connection = machine.current.map { $0.link == .usb ? "USB" : "Bluetooth" }
        let machineText: String
        if machine.info != nil {
            machineText = [machine.modelName, machine.firmware, connection, Self.state(machine)]
                .compactMap(\.self).joined(separator: " · ")
        } else if let current = machine.current {
            machineText = String(localized: "not connected (last: \(current.model) · \(connection ?? "?"))")
        } else {
            machineText = String(localized: "none used yet")
        }
        summary = [
            "- Cutline \(version) (build \(build))",
            "- macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "- Mac: \(Self.macModel) · \(processor) · \(language)",
            "- " + String(localized: "Machine: \(machineText)"),
            "- Silhouette Studio " + (machine.studioOpen ? String(localized: "open") : String(localized: "closed")),
        ].joined(separator: "\n")
        logLines = Array(machine.logLines.suffix(60))
        lastCut = (try? FileManager.default.contentsOfDirectory(at: Self.logsFolder,
                                                                    includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.pathExtension == "gpgl" }
            .max { Self.data($0) < Self.data($1) }
    }

    private static func data(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    @MainActor
    private static func state(_ machine: Machine) -> String? {
        switch machine.state {
        case .failure(let message): String(localized: "error: \(message)")
        default:
            switch machine.info?.status {
            case .ready: String(localized: "ready")
            case .moving: String(localized: "moving")
            case .unloaded: String(localized: "no sheet or mat loaded")
            case .noResponse: String(localized: "no response")
            case .other(let text): text
            case nil: nil
            }
        }
    }

    /// "Mac16,10".
    private static var macModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(decoding: bytes.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
    }
}

struct ReportWindow: View {
    @Environment(Machine.self) private var machine
    @State private var report: Report
    @State private var notice: String?

    init(kind: ReportKind) {
        _report = State(initialValue: Report(kind: kind, detail: kind == .bug ? Report.emptySteps : ""))
    }

    private var technical: TechnicalInfo? { report.includeTechnical ? TechnicalInfo(machine: machine) : nil }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Type", selection: $report.kind) {
                        Text("Bug").tag(ReportKind.bug)
                        Text("Feature request").tag(ReportKind.feature)
                    }
                    .pickerStyle(.segmented)
                    TextField("Summary", text: $report.summary,
                              prompt: Text(report.kind == .bug ? "In one line, what went wrong"
                                                                       : "In one line, what you’d like"))
                }
                if report.kind == .bug {
                    field("What happened?", $report.summaryText,
                          "Tell what you did and what Cutline did (error message, what the machine cut…)")
                    field("Steps to reproduce", $report.detail, "The steps, one per line")
                    field("What should have happened?", $report.expected, "What you expected to see")
                } else {
                    field("What should Cutline do?", $report.summaryText, "Describe the feature")
                    field("What would it be for?", $report.detail,
                          "What you’d do with it (and how you do it today, in Silhouette Studio or another app)")
                }
                Section {
                    Toggle("Include Cutline, Mac and machine details", isOn: $report.includeTechnical)
                    if let technical {
                        DisclosureGroup("See what’s included") {
                            Text(technical.preview)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } footer: {
                    if report.kind == .bug {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("If the problem happens with a file, attach the document (.cutline, .studio3, PDF…). Cut logs are in ~/Library/Logs/Cutline; the latest one is attached to the email.")
                            Button("Show cut logs") { showLogs() }
                                .buttonStyle(.link)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack(spacing: 10) {
                Button("Copy", action: copyAction)
                if let notice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Send by Email", action: sendEmail)
                Button("Open in GitHub", action: openGitHub)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(!report.complete)
            .padding(14)
        }
        .frame(minWidth: 540, idealWidth: 580, minHeight: 640, idealHeight: 720)
        .navigationTitle(report.kind.title)
        .background(NoTabs())
        .onChange(of: report.kind) { _, kind in
            // The numbered steps are only for bugs.
            if kind == .feature, report.detail == Report.emptySteps { report.detail = "" }
            if kind == .bug, report.detail.isEmpty { report.detail = Report.emptySteps }
        }
        #if DEBUG
        .onAppear { DebugHooks.fillReport(&report, send: { openGitHub() }) }
        #endif
    }

    private func field(_ title: LocalizedStringKey, _ text: Binding<String>, _ tip: LocalizedStringKey) -> some View {
        Section(title) {
            TextField(title, text: text, prompt: Text(tip), axis: .vertical)
                .labelsHidden()
                .lineLimit(3...10)
        }
    }

    // MARK: Sending

    private func copyAction() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.finalTitle + "\n\n" + report.text(technical, forGitHub: false),
                                       forType: .string)
        notice = String(localized: "Report copied.")
    }

    private func openGitHub() {
        let technical = technical
        let (url, wasCut) = report.gitHubURL(technical)
        if wasCut {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report.text(technical), forType: .string)
        }
        #if DEBUG
        if DebugHooks.dumpReport(url: url, text: report.text(technical)) { return }
        #endif
        NSWorkspace.shared.open(url)
        notice = wasCut ? String(localized: "The text was too long for the link: the full report was copied, paste it into the issue.")
                        : String(localized: "Opened the GitHub page (you need a free account).")
    }

    private func sendEmail() {
        let technical = technical
        let pointSize = report.text(technical, forGitHub: false)
        if let service = NSSharingService(named: .composeEmail) {
            service.recipients = [Contact.email]
            service.subject = "Cutline: " + report.finalTitle
            let items: [Any] = [pointSize] + [technical?.lastCut].compactMap(\.self)
            if service.canPerform(withItems: items) {
                service.perform(withItems: items)
                notice = String(localized: "Opened an email to \(Contact.email).")
                return
            }
        }
        // Without Mail set up: the (short) address through mailto and the text copied.
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = Contact.email
        components.queryItems = [URLQueryItem(name: "subject", value: "Cutline: " + report.finalTitle)]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pointSize, forType: .string)
        if let url = components.url, NSWorkspace.shared.open(url) {
            notice = String(localized: "The report was copied: paste it into the email.")
        } else {
            notice = String(localized: "Couldn’t find an email app. The report was copied; send it to \(Contact.email).")
        }
    }

    private func showLogs() {
        let folder = TechnicalInfo.logsFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let lastOne = technical?.lastCut {
            NSWorkspace.shared.activateFileViewerSelecting([lastOne])
        } else {
            NSWorkspace.shared.open(folder)
        }
    }
}

/// The app always opens documents in tabs; the report window stays on its own.
private struct NoTabs: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.tabbingMode = .disallowed
        }
    }
}

/// Help: report a bug, request a feature and the project page.
struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindowAction

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Report a Bug…") { openWindowAction(value: ReportKind.bug) }
            Button("Request a Feature…") { openWindowAction(value: ReportKind.feature) }
            Divider()
            Link("Cutline on GitHub", destination: Contact.gitHubPage)
        }
    }
}
