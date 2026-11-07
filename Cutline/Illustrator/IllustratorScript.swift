// The Illustrator script "Send to Cutline" (Send to Cutline.jsx, next to this file, copied into the app): it saves the
// selection, or the active artboard, as a PDF named .cutlinesend in the temporary folder and opens it with File.execute(),
// which hands it to Cutline (the owner of that type, Cutline-Info.plist). Cutline opens it as a new document with the
// artboard's size (StartScreen.open → MainWindow.openPage) and then deletes it.
// Help › Install Illustrator Script… copies the script to the Scripts folder of each Illustrator on the Mac.
import AppKit
import UniformTypeIdentifiers

extension UTType {
    /// The PDF the script saves for Cutline (extension .cutlinesend; declared in Cutline-Info.plist).
    static let illustratorSend = UTType(exportedAs: "io.github.joaogmcorrea.cutline.send")
}

enum IllustratorScript {
    static let fileName = "Send to Cutline.jsx"

    /// The copy inside the app.
    static var bundled: URL? { Bundle.main.url(forResource: "Send to Cutline", withExtension: "jsx") }

    // MARK: Receiving

    /// The new document's name: the script names the file after the Illustrator document.
    static func title(of url: URL) -> String { url.deletingPathExtension().lastPathComponent }

    /// Deletes the file once read, and its folder ("Send to Cutline <time>") if that's empty: only in the temporary
    /// folder, where the script writes (a .cutlinesend kept somewhere else is the person's file).
    static func discard(_ url: URL) {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        let file = url.resolvingSymlinksInPath()
        guard file.path.hasPrefix(temporary + "/") else { return }
        try? FileManager.default.removeItem(at: file)
        let folder = file.deletingLastPathComponent()
        if folder.path != temporary, folder.lastPathComponent.hasPrefix("Send to Cutline "),
           (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: Installing

    /// One Illustrator on the Mac: its name ("Adobe Illustrator 2026") and the Scripts folder of each of its languages
    /// (<Illustrator folder>/Presets/<language>/Scripts, the folders File › Scripts lists).
    struct Target {
        var name: String
        var folders: [URL]
    }

    /// The Illustrators macOS knows of, and any in /Applications.
    static func targets() -> [Target] {
        var apps = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: "com.adobe.illustrator")
        let applications = URL(fileURLWithPath: "/Applications")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: applications.path)) ?? [] where name.hasPrefix("Adobe Illustrator") {
            apps.append(applications.appendingPathComponent(name).appendingPathComponent("Adobe Illustrator.app"))
        }
        var seen = Set<String>()
        var found: [Target] = []
        for app in apps {
            let home = app.deletingLastPathComponent().standardizedFileURL
            guard seen.insert(home.path).inserted, FileManager.default.fileExists(atPath: app.path) else { continue }
            let presets = ["Presets.localized", "Presets"].map { home.appendingPathComponent($0) }
                .first { FileManager.default.fileExists(atPath: $0.path) }
            guard let presets else { continue }
            let languages = (try? FileManager.default.contentsOfDirectory(at: presets, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            let folders = languages.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .map { $0.appendingPathComponent("Scripts") }
                .sorted { $0.path < $1.path }
            if !folders.isEmpty { found.append(Target(name: FileManager.default.displayName(atPath: home.path), folders: folders)) }
        }
        return found.sorted { $0.name > $1.name }
    }

    /// Help › Install Illustrator Script…: the script goes to every Scripts folder found. Those folders belong to the
    /// system (Illustrator's installer), so the copy usually asks for the Mac's password.
    @MainActor static func install() {
        guard let script = bundled else { return }
        var found = targets()
        #if DEBUG
        if let folders = DebugHooks.installFolders { found = [Target(name: "Test", folders: folders)] }
        #endif
        guard !found.isEmpty else {
            return explain(String(localized: "Illustrator wasn’t found on this Mac."),
                           String(localized: "Install Adobe Illustrator, or copy the script by hand to Illustrator’s Scripts folder (Adobe Illustrator › Presets › your language › Scripts)."))
        }
        let folders = found.flatMap(\.folders)
        // Without the password first, in case the folders can be written to.
        let left = folders.filter { (try? copy(script, into: $0)) == nil }
        if !left.isEmpty {
            switch copyAsAdministrator(script, into: left) {
            case .done: break
            case .cancelled: return
            case .failed(let reason):
                return explain(String(localized: "The script couldn’t be installed."),
                               reason + "\n\n" + String(localized: "Copy it by hand to Illustrator’s Scripts folder (Adobe Illustrator › Presets › your language › Scripts), or open it in Illustrator with File › Scripts › Other Script…"))
            }
        }
        let names = ListFormatter.localizedString(byJoining: found.map(\.name))
        var detail = String(localized: "In Illustrator, choose File › Scripts › Send to Cutline. With something selected, it sends the selection; with nothing selected, the artboard. Cutline opens it as a new document.")
        if illustratorRunning {
            detail += "\n\n" + String(localized: "Illustrator is open: quit it and open it again to see the script.")
        }
        show(String(localized: "Send to Cutline is installed in \(names)."), detail, offerScript: false)
    }

    /// Illustrator reads its Scripts folder when it opens.
    static var illustratorRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.adobe.illustrator" }
    }

    private static func copy(_ script: URL, into folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: script, to: destination)
    }

    private enum Outcome { case done, cancelled, failed(String) }

    /// The copy with the Mac's password (the system's authorization window), through AppleScript's `do shell script`.
    @MainActor private static func copyAsAdministrator(_ script: URL, into folders: [URL]) -> Outcome {
        // AppleScript string literal: backslashes and quotes escaped; `quoted form of` quotes it for the shell.
        let literal = { (text: String) in "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let commands = folders.map { folder in
            "\"/bin/mkdir -p \" & quoted form of \(literal(folder.path)) & \" && /bin/cp -f \" & quoted form of \(literal(script.path))"
                + " & \" \" & quoted form of \(literal(folder.appendingPathComponent(fileName).path))"
        }
        let prompt = String(localized: "Cutline wants to put the Send to Cutline script in Illustrator’s Scripts folder.")
        let source = "do shell script (" + commands.joined(separator: " & \" && \" & ") + ") with prompt \(literal(prompt)) with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        guard let error else { return .done }
        // -128: the person clicked Cancel.
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }
        return .failed(error[NSAppleScript.errorMessage] as? String ?? String(localized: "Unknown error."))
    }

    /// A problem, with the way to do it by hand.
    @MainActor private static func explain(_ message: String, _ detail: String) {
        show(message, detail, offerScript: true)
    }

    /// The alert. `offerScript`: a button that puts a copy of the script in Downloads and shows it in the Finder.
    @MainActor private static func show(_ message: String, _ detail: String, offerScript: Bool) {
        #if DEBUG
        if DebugHooks.hidden {
            NSLog("CUTLINE_TEST illustrator alert message=%@ detail=%@", message, detail)
            return
        }
        #endif
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        if offerScript {
            alert.addButton(withTitle: String(localized: "Show Script in Finder"))
            alert.addButton(withTitle: String(localized: "OK"))
        }
        if alert.runModal() == .alertFirstButtonReturn, offerScript { showScript() }
    }

    /// A copy of the script in Downloads, selected in the Finder (to drag to the Scripts folder or run from anywhere).
    @MainActor private static func showScript() {
        guard let script = bundled,
              let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        do {
            try copy(script, into: downloads)
            NSWorkspace.shared.activateFileViewerSelecting([downloads.appendingPathComponent(fileName)])
        } catch {
            NSWorkspace.shared.activateFileViewerSelecting([script])
        }
    }
}
