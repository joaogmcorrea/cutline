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
    @AppStorage("reguas") private var rulers = true
    @AppStorage("snap") private var snap = true
    @AppStorage(Preferences.guidesVisible) private var guidesVisible = true
    @AppStorage(Preferences.guidesLocked) private var guidesLocked = false
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
        CommandGroup(after: .importExport) {
            Button("Import…") { act { $0.importRequest += 1 } }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(doc == nil)
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
            // Delete alone deletes when the canvas has focus; ⌘⌫ works from anywhere.
            Button("Delete") { act { $0.deleteSelection() } }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(noSelection || isTyping)
            Button("Duplicate") { act { $0.duplicateSelection() } }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(noSelection || isTyping)
        }
    }

    // MARK: Object and Select

    @ViewBuilder
    private var object: some View {
        let selectedObjects = doc?.selectedObjects ?? []
        Menu("Align") {
            ForEach(AlignMode.allCases) { mode in
                Button("Align \(mode.name)") { act { $0.align(mode) } }
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
        Divider()
        Button("Convert to Path") { act { $0.convertToPath() } }
            .disabled(!selectedObjects.contains { $0.shape.parametric })
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
            ForEach(Panel.allCases) { panel in
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
