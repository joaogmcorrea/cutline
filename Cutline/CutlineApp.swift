// Cutline — editor and cutter for Silhouette machines (macOS, SwiftUI, Liquid Glass).
import SwiftUI

@main
struct CutlineApp: App {
    /// One connection to the cutter for the whole app.
    @State private var machine = Machine()
    /// The start screen instead of a blank document (StartScreen.swift).
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    init() {
        // On launch, a new blank document (not the open-file panel).
        UserDefaults.standard.register(defaults: ["NSShowAppCentricOpenPanelInsteadOfUntitledFile": false])
        // Documents in tabs, as in Illustrator and Silhouette Studio: the system setting
        // ("Prefer tabs when opening documents") applies to this app only.
        UserDefaults.standard.set("always", forKey: "AppleWindowTabbingMode")
        // Settings › Appearance: light, dark or as the system.
        AppAppearance.current.apply()
        // Fonts activated while the app is open (Adobe Fonts) apply to text already drawn.
        Fonts.observeChanges()
        // Sparkle checks for new versions from launch (never in debug builds).
        _ = Updates.controller
        #if DEBUG
        DebugHooks.hideWindows()
        #endif
    }

    var body: some Scene {
        // File › New, Open (also .studio3), Open Recent, Save, Duplicate, Revert… come from the system.
        DocumentGroup(newDocument: { Document() }) { file in
            MainWindow(doc: file.document)
                .environment(machine)
        }
        .defaultSize(width: 1400, height: 900)
        .windowToolbarStyle(.unified)
        .commands {
            EditorCommands()
            UpdatesCommand()
            HelpCommands()
        }

        // Start screen, as Illustrator's Home: at launch with no document and when the last one closes (Window menu too).
        Window("Welcome to Cutline", id: StartScreen.id) {
            StartView()
                .environment(machine)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(StartScreen.enabled ? .presented : .suppressed)

        // Cutline › Settings… (⌘,).
        Settings {
            SettingsView()
        }

        // Help › Report a Bug… / Request a Feature… (one window each; no items in the File menu).
        WindowGroup(for: ReportRequest.self) { $request in
            ReportWindow(request: request ?? ReportRequest(kind: .bug))
                .environment(machine)
        }
        .defaultSize(width: 600, height: 760)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .commandsRemoved()
    }
}
