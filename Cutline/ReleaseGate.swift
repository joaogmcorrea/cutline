// Features that are finished in the code but reach people in a later release, on the owner's schedule (06/11/2026):
// a feature shows in the app once it's in `Feature.released`. Its code ships before that; only the ways in (menus,
// tools, panels, buttons) stay hidden. To see everything on a Mac before the release:
//   defaults write io.github.joaogmcorrea.cutline previewFeatures -bool YES
// or, in a debug build, CUTLINE_ALL_FEATURES=1.
import Foundation

enum Feature: String, CaseIterable {
    // 1.6.0 (13/11/2026)
    case colorProfiles, colorPicker, gradients, layerBlending, trackEnhancing
    // 1.7.0 (20/11/2026)
    case typeOnPath, linkedImages, googleFonts, grid

    /// The released ones: each release adds its features here.
    static let released: Set<Feature> = [.colorProfiles, .colorPicker, .gradients, .layerBlending, .trackEnhancing]

    /// Shown in the app: released, or every feature on a Mac that asked to preview them.
    var isOn: Bool { Self.released.contains(self) || Self.previewAll }

    static let previewAll: Bool = {
        if UserDefaults.standard.bool(forKey: "previewFeatures") { return true }
        #if DEBUG
        if ProcessInfo.processInfo.environment["CUTLINE_ALL_FEATURES"] == "1" { return true }
        #endif
        return false
    }()
}
