// Right-click menu on the canvas (or ⌃-click): cut, copy, paste, duplicate and delete; group and
// ungroup; arrange in the stack; duplicate beside; show/hide and lock the guides. Clicking an object outside the selection selects it first (the
// whole group, with the Selection tool), as in Illustrator. Also `EditResponder`, which makes the Edit menu's
// Cut, Copy and Paste work on the objects.
import AppKit

enum ContextMenu {
    @MainActor static func create(_ doc: Document) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let algo = !doc.selection.isEmpty
        menu.addItem(item(String(localized: "Cut"), keyEvent: "x", isActive: algo) { doc.cutSelection() })
        menu.addItem(item(String(localized: "Copy"), keyEvent: "c", isActive: algo) { doc.copySelection() })
        menu.addItem(item(String(localized: "Paste"), keyEvent: "v", isActive: doc.canPaste) { doc.paste() })
        menu.addItem(item(String(localized: "Duplicate"), keyEvent: "d", isActive: algo) { doc.duplicateSelection() })
        menu.addItem(item(String(localized: "Delete"), keyEvent: "\u{8}", modifiers: [], isActive: algo) { doc.deleteSelection() })
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Group"), keyEvent: "g", isActive: doc.canGroup) { doc.groupSelected() })
        menu.addItem(item(String(localized: "Ungroup"), keyEvent: "g", modifiers: [.command, .shift], isActive: doc.canUngroup) {
            doc.ungroupSelected()
        })
        menu.addItem(.separator())
        menu.addItem(submenu(String(localized: "Arrange"), isActive: algo, Arrangement.allCases.map { mode in
            item(mode.name, keyEvent: mode == .front || mode == .forward ? "]" : "[",
                     modifiers: mode == .front || mode == .back ? [.command, .shift] : .command) { doc.arrange(mode) }
        }))
        let arrow = { (keyEvent: Int) in String(utf16CodeUnits: [unichar(keyEvent)], count: 1) }
        menu.addItem(submenu(String(localized: "Duplicate Beside"), isActive: algo, [
            item(String(localized: "Left"), keyEvent: arrow(NSLeftArrowFunctionKey)) { doc.duplicateBeside(.left) },
            item(String(localized: "Right"), keyEvent: arrow(NSRightArrowFunctionKey)) { doc.duplicateBeside(.right) },
            item(String(localized: "Above"), keyEvent: arrow(NSUpArrowFunctionKey)) { doc.duplicateBeside(.up) },
            item(String(localized: "Below"), keyEvent: arrow(NSDownArrowFunctionKey)) { doc.duplicateBeside(.bottom) },
        ]))
        // Guides, as in Illustrator's right click (the same settings as View › Show Guides and Lock Guides).
        menu.addItem(.separator())
        let defaults = UserDefaults.standard
        let visible = defaults.object(forKey: Preferences.guidesVisible) == nil || defaults.bool(forKey: Preferences.guidesVisible)
        let locked = defaults.bool(forKey: Preferences.guidesLocked)
        menu.addItem(item(visible ? String(localized: "Hide Guides") : String(localized: "Show Guides"), keyEvent: ";") {
            defaults.set(!visible, forKey: Preferences.guidesVisible)
        })
        menu.addItem(item(locked ? String(localized: "Unlock Guides") : String(localized: "Lock Guides"), keyEvent: ";",
                          modifiers: [.command, .option]) {
            defaults.set(!locked, forKey: Preferences.guidesLocked)
        })
        return menu
    }

    /// Item that runs a block (the shortcut only shows; the canvas keyboard handles it).
    @MainActor private static func item(_ title: String, keyEvent: String = "", modifiers: NSEvent.ModifierFlags = .command,
                                        isActive: Bool = true, action: @escaping () -> Void) -> NSMenuItem {
        let target = MenuAction(action)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.execute), keyEquivalent: keyEvent)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        item.representedObject = target   // the target is weak: the item keeps the target
        item.isEnabled = isActive
        return item
    }

    @MainActor private static func submenu(_ title: String, isActive: Bool, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = NSMenu(title: title)
        items.forEach { item.submenu?.addItem($0) }
        item.isEnabled = isActive
        return item
    }
}

/// A menu item's target: runs a block.
private final class MenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func execute() { action() }
}

nonisolated(unsafe) private var responderKey: UInt8 = 0

/// The Edit menu's Cut, Copy and Paste for objects when no text field has the keyboard (the
/// fields respond first, in the responder chain); and Save for a document that came from Silhouette Studio
/// (Model/StudioSave.swift). It sits right after the window, before the document. Its `nextResponder` is a
/// weak reference: the window holds it (associated object), and on each window update it checks it is still
/// in the chain.
final class EditResponder: NSResponder, NSMenuItemValidation {
    private weak var doc: Document?
    private weak var nsWindow: NSWindow?
    private var observer: NSObjectProtocol?

    static func install(in nsWindow: NSWindow, doc: Document) {
        var current = nsWindow.nextResponder
        while let r = current {
            if let mine = r as? EditResponder {
                mine.doc = doc
                mine.nsWindow = nsWindow
                return
            }
            current = r.nextResponder
        }
        let updated = EditResponder()
        updated.doc = doc
        updated.nsWindow = nsWindow
        objc_setAssociatedObject(nsWindow, &responderKey, updated, .OBJC_ASSOCIATION_RETAIN)
        updated.snap()
        updated.observer = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nsWindow,
                                                                 queue: .main) { [weak updated] _ in
            MainActor.assumeIsolated { updated?.snap() }
        }
    }

    /// Right after the window (if it isn't in its chain yet).
    private func snap() {
        guard let nsWindow else { return }
        var current = nsWindow.nextResponder
        while let r = current {
            if r === self { return }
            current = r.nextResponder
        }
        nextResponder = nsWindow.nextResponder
        nsWindow.nextResponder = self
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    @objc func copy(_ sender: Any?) { doc?.copySelection() }
    @objc func cut(_ sender: Any?) { doc?.cutSelection() }
    @objc func paste(_ sender: Any?) { doc?.paste() }

    /// ⌘S: the document that came from Studio (and has no Cutline file yet) asks where to save.
    @objc func saveDocument(_ sender: Any?) {
        guard let nsWindow, let document = nsWindow.windowController?.document as? NSDocument else { return }
        guard let doc, doc.studio?.url != nil, document.fileURL == nil else { return document.save(sender) }
        StudioSave.save(doc, document, nsWindow: nsWindow)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(saveDocument(_:)) {
            return (nsWindow?.windowController?.document as? NSDocument)?.validateUserInterfaceItem(item) ?? true
        }
        guard let doc, doc.textEditing == nil else { return false }
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)): return !doc.selection.isEmpty
        case #selector(paste(_:)): return doc.canPaste
        default: return true
        }
    }
}
