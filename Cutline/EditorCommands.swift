// macOS menu bar, like Illustrator's, with only what Cutline does: File (Import, Print,
// Send), Edit (Delete, Duplicate), Object (Group, Arrange, Align, Pathfinder…), Select,
// View (zoom, rulers, snap, guides, marks) and Window (tools, control bar and panels, which can
// be hidden for good). They act on the active window (FocusedValues); undo/redo and Select All in text
// fields are the system's, and so are cut/copy/paste, which reach the objects through `EditResponder`.
// On the canvas, ⌘ shortcuts for objects are read by its keyboard (CanvasView.keyboard), not by the menus.
import AppKit
import SwiftUI

struct EditorCommands: Commands {
    @FocusedValue(\.document) private var doc
    @FocusedValue(\.viewControl) private var control
    @Environment(\.openWindow) private var openWindow
    @AppStorage("reguas") private var rulers = true
    @AppStorage("snap") private var snap = true
    @AppStorage(Preferences.guidesVisible) private var guidesVisible = true
    @AppStorage(Preferences.guidesLocked) private var guidesLocked = false
    @AppStorage(Preferences.gridVisible) private var gridVisible = false
    @AppStorage(Preferences.gridSnap) private var gridSnap = false
    @AppStorage("ferramentasVisiveis") private var toolsVisible = true
    @AppStorage("barraControleVisivel") private var controlBarVisible = true
    @AppStorage("paineisOcultos") private var hiddenText = ""

    var body: some Commands {
        file
        editAction
        viewMenu
        nsWindow
        CommandMenu("Object") { object }
        CommandMenu("Select") { select }
    }

    /// Acts on the document only when no window is over it (Send, Trace, Print).
    private func act(_ action: (Document) -> Void) {
        guard let doc, NSApp.keyWindow?.sheetParent == nil else { return }
        action(doc)
    }

    private var noSelection: Bool { doc?.selection.isEmpty ?? true }

    /// Typing on the canvas: ⌘⌫, ⌘D and ⇧⌘A stay with the text (delete to line start etc.), not the object.
    private var isTyping: Bool { doc?.textEditing != nil }

    // MARK: File and Edit

    @CommandsBuilder
    private var file: some Commands {
        // After Open Recent; only once the Info.plist has the backend's address (Canva/CanvaService.swift).
        CommandGroup(before: .saveItem) {
            if CanvaConfig.isEnabled {
                Button("Open from Canva…") { openWindow(id: CanvaWindow.id) }
                Divider()
            }
        }
        CommandGroup(after: .saveItem) {
            // Only the selected objects, to a new Cutline file (as in Silhouette Studio); the document doesn't change.
            Button("Save Selection…") { act { $0.saveSelectionRequest += 1 } }
                .disabled(noSelection || isTyping)
        }
        CommandGroup(after: .importExport) {
            Button("Import…") { act { $0.importRequest += 1 } }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(doc == nil)
            // A Cutline or Silhouette Studio document into this one (as Studio's Merge), with its layers and colors.
            Button("Merge…") { act { $0.mergeRequest += 1 } }
                .disabled(doc == nil || isTyping)
        }
        CommandGroup(replacing: .printItem) {
            // A4 at actual size; with Print & Cut, with the registration marks.
            Button("Print…") { act { $0.printRequest += 1 } }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(doc == nil)
            Button("Send to Machine…") { act { $0.sendRequest += 1 } }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(doc?.objects.isEmpty ?? true)
        }
    }

    @CommandsBuilder
    private var editAction: some Commands {
        CommandGroup(after: .pasteboard) {
            // The copied image inside the selected shapes (InDesign's Paste Into; Editor/ImageInsideShape.swift).
            Button("Paste Inside") { act { doc in if let notice = doc.pasteInside() { doc.notice = notice } } }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(!(doc?.canPasteInside ?? false) || isTyping)
            // Delete alone deletes when the canvas has focus; ⌘⌫ works from anywhere.
            Button("Delete") { act { $0.deleteSelection() } }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(noSelection || isTyping)
            Button("Duplicate") { act { $0.duplicateSelection() } }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(noSelection || isTyping)
            if Feature.colorProfiles.isOn {
                Divider()
                // As in Illustrator's Edit menu (Editor/ColorProfileViews.swift).
                SettingsLink { Text("Color Settings…") }
                Button("Assign Profile…") { act { $0.assignProfileRequest += 1 } }
                    .disabled(doc == nil || isTyping)
            }
        }
    }

    // MARK: Object and Select

    @ViewBuilder
    private var object: some View {
        let selectedObjects = doc?.selectedObjects ?? []
        // As Illustrator's Object › Transform: Rotate… and the quick turns (around the selection's center), Reset Bounding Box.
        Menu("Transform") {
            Button("Rotate…") { act { $0.rotateRequest = RotateRequest() } }
            Button("Rotate 90° Clockwise") { act { $0.rotateSelection(by: -90) } }
            Button("Rotate 90° Counterclockwise") { act { $0.rotateSelection(by: 90) } }
            Button("Rotate 180°") { act { $0.rotateSelection(by: 180) } }
            Divider()
            Button("Reset Bounding Box") { act { $0.resetBoundingBox() } }
                .disabled(!(doc?.canResetBoundingBox ?? false))
        }
        .disabled(selectedObjects.isEmpty || isTyping)
        Menu("Align") {
            ForEach(AlignMode.allCases) { mode in
                Button("Align \(mode.name)") { act { $0.align(mode) } }
            }
            Divider()
            ForEach(SpacingAxis.allCases) { axis in
                Button(axis.name) { act { $0.distribute(axis) } }
                    .disabled(!(doc?.canDistribute ?? false))
            }
        }
        .disabled(selectedObjects.isEmpty)
        Menu("Pathfinder") {
            ForEach(PathfinderOperation.allCases) { operation in
                Button(operation.name) {
                    act { doc in if let notice = doc.pathfinder(operation) { doc.notice = notice } }
                }
            }
        }
        .disabled(selectedObjects.isEmpty)
        Divider()
        Button("Group") { act { $0.groupSelected() } }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(!(doc?.canGroup ?? false) || isTyping)
        Button("Ungroup") { act { $0.ungroupSelected() } }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(!(doc?.canUngroup ?? false) || isTyping)
        Menu("Arrange") {
            ForEach(Arrangement.allCases) { mode in
                Button(mode.name) { act { $0.arrange(mode) } }
                    .keyboardShortcut(mode == .front || mode == .forward ? "]" : "[",
                                      modifiers: mode == .front || mode == .back ? [.command, .shift] : .command)
            }
        }
        .disabled(selectedObjects.isEmpty || isTyping)
        // As in Illustrator (⌘8 and ⌥⇧⌘8; on the canvas, read by its keyboard).
        Menu("Compound Path") {
            Button("Make") { act { $0.makeCompoundPath() } }
                .keyboardShortcut("8", modifiers: .command)
                .disabled(!(doc?.canMakeCompoundPath ?? false))
            Button("Release") { act { $0.releaseCompoundPath() } }
                .keyboardShortcut("8", modifiers: [.command, .option, .shift])
                .disabled(!(doc?.canReleaseCompoundPath ?? false))
        }
        .disabled(selectedObjects.isEmpty || isTyping)
        // As in Illustrator (⌘7 and ⌥⌘7; on the canvas, read by its keyboard): an image inside a shape.
        Menu("Clipping Mask") {
            Button("Make") { act { doc in if let notice = doc.makeClippingMask() { doc.notice = notice } } }
                .keyboardShortcut("7", modifiers: .command)
                .disabled(!(doc?.canMakeClippingMask ?? false))
            Button("Release") { act { $0.releaseClippingMask() } }
                .keyboardShortcut("7", modifiers: [.command, .option])
                .disabled(!(doc?.canReleaseClippingMask ?? false))
            Divider()
            Button("Edit Contents") { act { doc in if let id = doc.selectedObjects.first(where: \.hasImageInside)?.id { doc.editContent(id) } } }
                .disabled(!(doc?.canReleaseClippingMask ?? false))
        }
        .disabled(selectedObjects.isEmpty || isTyping)
        Divider()
        Button("Convert to Path") { act { $0.convertToPath() } }
            .disabled(!selectedObjects.contains(where: \.isParametric))
        // ⇧⌘O is Illustrator's Create Outlines; while typing, it converts the text being edited.
        Button("Convert Text to Outlines") { act { $0.convertTextToOutlines() } }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(!(doc?.hasTextToOutline ?? false))
        Button("Close Path") { act { $0.closePaths() } }
            .disabled(!selectedObjects.contains { if case .shapePath(let subs) = $0.shape { subs.contains { !$0.closed } } else { false } })
        Divider()
        Button("Move to Active Layer") { act { $0.moveSelectionToActiveLayer() } }
            .disabled(selectedObjects.isEmpty)
    }

    @ViewBuilder
    private var select: some View {
        // ⌘A on the canvas is read by the canvas keyboard; in text fields it stays with Edit › Select All.
        Button("All") { act { $0.selectAll() } }
            .disabled(doc?.objects.isEmpty ?? true)
        Button("None") { act { $0.selection = [] } }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(noSelection || isTyping)
        Divider()
        // As in Illustrator; the stroke color is the cut, so Stroke Color picks all the lines of a cut.
        Menu("Same") {
            Button("Fill Color") { act { $0.selectSame(.fill) } }
            Button("Stroke Color") { act { $0.selectSame(.strokeColor) } }
        }
        .disabled(noSelection || isTyping)
        Button("All in Active Layer") {
            act { doc in if let active = doc.layers.first(where: { $0.id == doc.activeLayer }) { doc.selectLayer(active) } }
        }
        .disabled(doc == nil)
    }

    // MARK: View and Window

    @CommandsBuilder
    private var viewMenu: some Commands {
        CommandGroup(before: .toolbar) {
            Button("Zoom In") { control?.zoom(1.25) }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(control == nil)
            Button("Zoom Out") { control?.zoom(1 / 1.25) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(control == nil)
            Button("Fit in Window") { control?.adjust() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(control == nil)
            Button("Fit All in Window") { control?.adjustAll() }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(control == nil)
            Button("Actual Size") { control?.setZoom(1) }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(control == nil)
            Divider()
            Toggle("Rulers", isOn: $rulers)
                .keyboardShortcut("r", modifiers: .command)
            // ⌘U is the underline while typing a text or with a text selected: the menu lets go of it then.
            Toggle("Snap", isOn: $snap)
                .keyboardShortcut("u", modifiers: .command)
                .disabled(isTyping || (doc?.hasTextSelected ?? false))
            Toggle("Show Guides", isOn: $guidesVisible)
                .keyboardShortcut(";", modifiers: .command)
            Toggle("Lock Guides", isOn: $guidesLocked)
                .keyboardShortcut(";", modifiers: [.command, .option])
            Button("Clear Guides") { act { $0.clearGuides() } }
                .disabled(doc?.guides.emptyOnes ?? true)
            if Feature.grid.isOn {
                // As in Illustrator (⌘' and ⇧⌘'); spacing, subdivisions and color in Settings.
                Toggle("Show Grid", isOn: $gridVisible)
                    .keyboardShortcut("'", modifiers: .command)
                Toggle("Snap to Grid", isOn: $gridSnap)
                    .keyboardShortcut("'", modifiers: [.command, .shift])
            }
            Toggle("Registration Marks (Print & Cut)", isOn: Binding(get: { doc?.marks ?? false }, set: { updated in
                act { if $0.marks != updated { $0.toggleMarks() } }
            }))
            .disabled(doc == nil)
            Divider()
        }
    }

    @CommandsBuilder
    private var nsWindow: some Commands {
        CommandGroup(before: .windowArrangement) {
            Toggle("Tools", isOn: $toolsVisible)
            Toggle("Control Bar", isOn: $controlBarVisible)
            Divider()
            ForEach(Panel.available) { panel in
                Toggle(panel.title, isOn: Binding(get: { !Panel.parsedSet(hiddenText).contains(panel) }, set: { visible in
                    var hiddenOnes = Panel.parsedSet(hiddenText)
                    if visible { hiddenOnes.remove(panel) } else { hiddenOnes.insert(panel) }
                    hiddenText = Panel.text(hiddenOnes)
                }))
            }
            Divider()
        }
    }
}
