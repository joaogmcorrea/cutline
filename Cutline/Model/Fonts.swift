// Fonts installed on the Mac, as macOS sees them: the system's, the user's (Font Book) and those
// activated by other apps, like Creative Cloud's Adobe Fonts.
import AppKit
import CoreText

enum Fonts {
    /// A face of the family (Regular, Bold Italic…).
    struct Face: Hashable, Identifiable {
        let postscript: String
        /// Face name as macOS shows it.
        let name: String
        var id: String { postscript }
    }

    /// Families in alphabetical order, without the system's hidden ones (those starting with ".").
    static func families() -> [String] {
        NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The family's faces, in macOS order (lightest to heaviest).
    static func faces(_ family: String) -> [Face] {
        (NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []).compactMap { member in
            guard member.count >= 2, let postscript = member[0] as? String, let name = member[1] as? String else { return nil }
            return Face(postscript: postscript, name: name)
        }
    }

    /// The family in a font to show in the list (at the requested size).
    static func swatch(_ family: String, size: Double) -> CTFont {
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    /// Symbol font (Webdings, Zapf Dingbats…): the name written in it can't be read.
    static func isSymbols(_ font: CTFont) -> Bool {
        let kindClass = CTFontGetSymbolicTraits(font).rawValue & CTFontSymbolicTraits.traitClassMask.rawValue
        return kindClass == CTFontStylisticClass.classSymbolic.rawValue
    }

    /// Fonts installed, activated or removed while the app is open (Font Book, dragging into
    /// ~/Library/Fonts, Adobe Fonts): macOS notifies within about 1 s, even with the app in the background, and the
    /// catalog refreshes the list, the menus and the letters already drawn.
    @MainActor static func observeChanges() {
        for name in [NSFont.fontSetChangedNotification, Notification.Name(kCTFontManagerRegisteredFontsChangedNotification as String)] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { FontCatalog.shared.changed() }
            }
        }
    }
}

/// The families installed now. The font list, the style menu and the canvas read from here, and so they
/// redo themselves when the Mac's set of fonts changes (without quitting and reopening the app).
@Observable
final class FontCatalog {
    static let shared = FontCatalog()

    private(set) var families: [String]
    private(set) var installedOnes: Set<String>
    /// Changes on each change to the set of fonts (the canvas redraws the texts with the current fonts).
    private(set) var version = 0
    @ObservationIgnored private var scheduled = false

    private init() {
        let now = Fonts.families()
        families = now
        installedOnes = Set(now)
    }

    /// The family's faces as they are now (Regular, Bold…).
    func faces(_ family: String) -> [Fonts.Face] {
        _ = version
        return Fonts.faces(family)
    }

    /// Both notifications arrive together (and one per file when several fonts arrive): a single update,
    /// a moment later.
    func changed() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            scheduled = false
            TextBox.forgetFonts()
            let newOnes = Fonts.families()
            if newOnes != families {
                families = newOnes
                installedOnes = Set(newOnes)
            }
            version += 1
        }
    }
}

extension CharacterStyle {
    /// Face in use (the chosen one or the one the family gives when none was chosen).
    var postscriptInUse: String { CTFontCopyPostScriptName(ctFont()) as String }

    /// Switches the family trying to keep the face (Bold stays Bold, if the new family has it).
    mutating func switchFamily(_ family: String) {
        guard family != font else { return }
        let currentFace = Fonts.faces(font).first { $0.postscript == postscriptInUse }?.name
        font = family
        postscript = Fonts.faces(family).first { $0.name == currentFace }?.postscript
    }
}
