// Updates through Sparkle 2: the app reads the appcast.xml of the latest version on GitHub Releases (SUFeedURL in
// Cutline-Info.plist) and only installs what comes signed with the project's EdDSA key (SUPublicEDKey).
// The installer and the appcast come from the distribution script.
import Combine
import Sparkle
import SwiftUI

/// One updater for the whole app. In debug builds it doesn't check anything: test copies
/// run hidden and the Sparkle window would show up on screen.
enum Updates {
    static let controller = SPUStandardUpdaterController(
        startingUpdater: !debugging, updaterDelegate: nil, userDriverDelegate: nil)

    private static var debugging: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}

/// Cutline › Check for Updates…, right below About Cutline.
struct UpdatesCommand: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            UpdatesButton(updater: Updates.controller.updater)
        }
    }
}

/// Disabled while Sparkle is already checking or installing (and always in debug builds).
private struct UpdatesButton: View {
    let updater: SPUUpdater
    @State private var can = false

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!can)
            .onReceive(updater.publisher(for: \.canCheckForUpdates)) { can = $0 }
    }
}
