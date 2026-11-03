// Debug builds only: helps check the interface without screen recording permission.
//   open --env CUTLINE_SNAPSHOT=/path/window.png --env CUTLINE_DEMO=1 Cutline.app
//   CUTLINE_SEND=1 opens the Send window; CUTLINE_SIMULATE=1 uses the simulated machine;
//   CUTLINE_TEST_MODIFY=1 changes the document by itself; CUTLINE_TEST_SAVE=/x.cutline saves a copy;
//   CUTLINE_TEST_IMPORT=/x.pdf imports; CUTLINE_TEST_PATHFINDER=divide…; CUTLINE_COLLAPSED=Color,Stroke;
//   CUTLINE_TEST_DROP=/x.png does the same as dropping the file in the middle of the window;
//   CUTLINE_TEST_IMAGE=image|outer|inners|inners-insert picks the answer to the imported-image question;
//   CUTLINE_TEST_TRACE=nodes,smoothing (0–100) changes the Trace settings;
//   CUTLINE_TEST_HANDLE=1|option|shift|shift+option drags the selection's bottom-right corner (30 × 10 mm),
//   like the mouse, with those modifiers;
//   CUTLINE_TEST_SAVE_STUDIO=write|cancel (on a .studio3, after the keys) sends ⌘S through the window's
//   responder chain and answers the question 2.5 s later (twice with "write2": the 2nd writes directly);
//   CUTLINE_TEST_KEYS=cmd+a;cmd+g;click:120,70;cmd+right… passes keys (and clicks, in mm) through the canvas
//   keyboard, one every 0.3 s; CUTLINE_TEST_CONTEXT_MENU=/x.txt dumps the right-click menu (of the selection then);
//   in the keys, offset:2 (mm; < 0 inside) offsets the selection with round corners, hover:x,y (mm) puts the pointer
//   there (the Eyedropper's loupe shows in a photo) and log writes the document's state (NSLog "CUTLINE_TEST state");
//   CUTLINE_TEST_SETTINGS=1 opens Cutline › Settings;
//   CUTLINE_MARKS=1 turns on the Print & Cut marks; CUTLINE_TEST_PRINT=/x.pdf writes the print to a PDF;
//   CUTLINE_TEST_SEND=1 (with CUTLINE_SIMULATE) sends by itself when the Send window opens;
//   CUTLINE_TEST_TEST_CUT=x,y (with CUTLINE_SIMULATE) sends the test cut at x,y mm when the Send window opens;
//   CUTLINE_TEST_IGNORE_STUDIO=1 pretends Silhouette Studio is closed;
//   CUTLINE_TEST_MAT=mini_6x8 picks the cutting mat on open (CuttingMat values);
//   CUTLINE_TEST_MARKS=fail (with CUTLINE_SIMULATE) makes reading the marks fail;
//   CUTLINE_OPEN_PANEL=pathfinder opens a collapsed panel;
//   CUTLINE_TEST_MENUS=/x.txt dumps the menu bar (titles, shortcuts, ✓ and disabled) to a text file;
//   CUTLINE_TEST_TEXT=1|visible|selection|typography|runs|style|new (with CUTLINE_DEMO=2) opens typing on the canvas;
//   outlines|outlinesWhileTyping converts the demo text to outlines (selected, or through ⇧⌘O while typing);
//   CUTLINE_TEST_ORDER=1 (with CUTLINE_SEND) moves the last cut color to the top, like dragging it;
//   CUTLINE_TEST_DEMO_FONT=Family sets the demo text in that family (a font installed while the app is open)
//   (CUTLINE_TEST_FAMILY=Montserrat switches the family during it);
//   CUTLINE_TEST_FONTS=1 opens the Character panel's font list.
//   CUTLINE_TEST_REPORT=bug|feature opens the report window; CUTLINE_TEST_REPORT_TEXT=1 fills in
//   an example; CUTLINE_TEST_REPORT_OUTPUT=/x.txt writes the GitHub address and the text instead of opening it.
//   CUTLINE_HIDDEN=1 (with `open -g`) tests without showing up: the windows stay behind the desktop.
#if DEBUG
import AppKit
import CutlineKit
import SwiftUI

enum DebugHooks {
    /// CUTLINE_HIDDEN=1, opened with `open -g` (without taking focus): the test windows sit below the desktop and
    /// outside the screens' area (sheets, like Trace and Send, follow the window), invisible to whoever
    /// is using the Mac — and `screencapture -l` still photographs them. No App Nap, which would slow the hidden app.
    /// Popovers and menus need the active window: those tests still show up.
    static func hideWindows() {
        guard ProcessInfo.processInfo.environment["CUTLINE_HIDDEN"] != nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "hidden test")
        let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        let hide = {
            MainActor.assumeIsolated {
                for nsWindow in NSApp?.windows ?? [] where nsWindow.sheetParent == nil && nsWindow.parent == nil {
                    if nsWindow.level != level { nsWindow.level = level }
                    if nsWindow.frame.minX > -20000 { nsWindow.setFrameOrigin(NSPoint(x: -30000, y: nsWindow.frame.minY)) }
                }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { _ in hide() }
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in hide() }
    }

    private static var activity: NSObjectProtocol?

    /// CUTLINE_TEST_REPORT=bug|feature opens the report window at launch.
    static var openReport: ReportKind? {
        ProcessInfo.processInfo.environment["CUTLINE_TEST_REPORT"].flatMap(ReportKind.init(rawValue:))
    }

    /// CUTLINE_TEST_REPORT_TEXT=1 fills the window with an example; with CUTLINE_TEST_REPORT_OUTPUT, it also
    /// "opens in GitHub" by itself (the address goes to the file, see `dumpReport`).
    static func fillReport(_ report: inout Report, send: @escaping () -> Void) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CUTLINE_TEST_REPORT_TEXT"] != nil else { return }
        report.summary = "The star comes out cut in half"
        report.summaryText = "I sent the test sticker to cut and the machine stopped in the middle of the star."
        if report.kind == .bug {
            report.detail = "1. File › New\n2. Draw a 40 mm star\n3. Send (⌘E) › Cut"
            report.expected = "The whole star cut cleanly."
        }
        guard environment["CUTLINE_TEST_REPORT_OUTPUT"] != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { send() }
    }

    /// CUTLINE_TEST_REPORT_OUTPUT=/x.txt: the issue address and the text go to the file, without opening the browser.
    static func dumpReport(url: URL, text: String) -> Bool {
        guard let outputPath = ProcessInfo.processInfo.environment["CUTLINE_TEST_REPORT_OUTPUT"] else { return false }
        try? (url.absoluteString + "\n\n" + text).write(toFile: outputPath, atomically: true, encoding: .utf8)
        return true
    }

    /// CUTLINE_SEND=1 opens the Send window at launch (with CUTLINE_SIMULATE=1, without a machine).
    static var openSendWindow: Bool { ProcessInfo.processInfo.environment["CUTLINE_SEND"] != nil }

    /// CUTLINE_TEST_MARKS=fail with CUTLINE_SIMULATE: the simulated machine "doesn't find" the Print & Cut marks.
    static var marksFail: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CUTLINE_TEST_MARKS"] == "fail" && environment["CUTLINE_SIMULATE"] != nil
    }

    /// CUTLINE_TEST_SEND=1 with CUTLINE_SIMULATE: the Send window sends by itself (transcript in ~/Library/Logs/Cutline).
    static var sendForTest: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CUTLINE_TEST_SEND"] != nil && environment["CUTLINE_SIMULATE"] != nil
    }

    /// CUTLINE_TEST_TEST_CUT=x,y with CUTLINE_SIMULATE: the Send window puts the test cut at x,y mm and sends it.
    static var testCut: CGPoint? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CUTLINE_SIMULATE"] != nil, let value = environment["CUTLINE_TEST_TEST_CUT"] else { return nil }
        let n = value.split(separator: ",").compactMap { Double($0) }
        return n.count == 2 ? CGPoint(x: n[0], y: n[1]) : nil
    }

    /// CUTLINE_TEST_MODIFY=1 moves the first object 1 mm right after opening (registering the undo),
    /// to test the changed document (asking to save, autosave) without touching the mouse.
    static func modifyForTest(_ doc: Document) {
        // CUTLINE_TEST_MAT=mini_6x8 (a CuttingMat value) picks the mat in the document (without remembering it in the app,
        // so the owner's choice for new documents doesn't change).
        if let base = ProcessInfo.processInfo.environment["CUTLINE_TEST_MAT"].flatMap(CuttingMat.init(rawValue:)) {
            doc.withMat = base != .none
            doc.cuttingMatSetting = base
        }
        guard ProcessInfo.processInfo.environment["CUTLINE_TEST_MODIFY"] != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard !doc.objects.isEmpty else { return }
            doc.registrar()
            doc.objects[0].frame.origin.x += 1
        }
    }

    /// CUTLINE_TEST_SAVE=/path.cutline saves a copy of the document there right after opening
    /// (the same path as File › Save As…), to check writing and reading without the panel.
    static func saveForTest(_ nsWindow: NSWindow?) {
        guard let outputPath = ProcessInfo.processInfo.environment["CUTLINE_TEST_SAVE"] else { return }
        // CUTLINE_TEST_DELAY=8 saves after 8 s (after a sequence of CUTLINE_TEST_KEYS).
        let wait = Double(ProcessInfo.processInfo.environment["CUTLINE_TEST_DELAY"] ?? "") ?? 3
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            guard let document = nsWindow?.windowController?.document as? NSDocument else { return }
            document.save(to: URL(fileURLWithPath: outputPath), ofType: "io.github.joaogmcorrea.cutline.documento",
                           for: .saveToOperation) { error in
                print(error.map { "failed: \($0.localizedDescription)" } ?? "saved to \(outputPath)")
            }
        }
    }

    /// CUTLINE_OPEN_PANEL=pathfinder opens that collapsed panel next to the icon strip.
    static var openPanel: Panel? {
        ProcessInfo.processInfo.environment["CUTLINE_OPEN_PANEL"].flatMap(Panel.init(rawValue:))
    }

    /// CUTLINE_COLLAPSED=Color,Stroke opens the side panel with those sections collapsed.
    static var closedSections: Set<String> {
        Set((ProcessInfo.processInfo.environment["CUTLINE_COLLAPSED"] ?? "").split(separator: ",").map(String.init))
    }

    /// CUTLINE_TEST_PATHFINDER=unite|minusFront|intersect|exclude|divide|minusBack draws an overlapping
    /// rectangle and ellipse and applies the operation (to check the result without the mouse).
    static func pathfinderForTest(_ doc: Document) {
        guard let name = ProcessInfo.processInfo.environment["CUTLINE_TEST_PATHFINDER"],
              let operation = PathfinderOperation(rawValue: name) else { return }
        let rectangle = doc.newObject(.rectangle(radius: 8), frame: CGRect(x: 30, y: 40, width: 80, height: 70))
        var ellipse = doc.newObject(.ellipse, frame: CGRect(x: 70, y: 80, width: 90, height: 70))
        ellipse.strokeColor = CMYK(c: 100, m: 50, y: 0, k: 0)
        ellipse.fill = CMYK(c: 20, m: 0, y: 0, k: 0)
        doc.objects = [rectangle, ellipse]
        doc.selection = [rectangle.id, ellipse.id]
        doc.notice = doc.pathfinder(operation) ?? "\(operation.name): \(doc.objects.count) object(s)"
    }

    /// CUTLINE_TEST_IMPORT=/file.pdf|.ai|.png does the same as File › Import… with that file.
    static var importForTest: URL? {
        ProcessInfo.processInfo.environment["CUTLINE_TEST_IMPORT"].map { URL(fileURLWithPath: $0) }
    }

    /// CUTLINE_TEST_DROP=/file does the same as dropping the file in the middle of the window.
    static var dropForTest: URL? {
        ProcessInfo.processInfo.environment["CUTLINE_TEST_DROP"].map { URL(fileURLWithPath: $0) }
    }

    /// CUTLINE_TEST_IMAGE=image|outer|inners|inners-insert: the answer to the imported-image question.
    static var imageChoice: String? { ProcessInfo.processInfo.environment["CUTLINE_TEST_IMAGE"] }

    /// CUTLINE_TEST_TRACE=nodes,smoothing (0 to 100): the Trace settings on open.
    static var traceSettings: (nodes: Double, smoothing: Double)? {
        let values = (ProcessInfo.processInfo.environment["CUTLINE_TEST_TRACE"] ?? "").split(separator: ",").compactMap { Double($0) }
        return values.count == 2 ? (values[0], values[1]) : nil
    }

    /// CUTLINE_TEST_HANDLE=1: as soon as there is a selection, drags the bottom-right corner handle 30 mm to the
    /// right and 10 mm down, along the same path as the mouse (CanvasView.dragHandleForTest).
    static var dragHandle: Bool { ProcessInfo.processInfo.environment["CUTLINE_TEST_HANDLE"] != nil }

    static var hidden: Bool { ProcessInfo.processInfo.environment["CUTLINE_HIDDEN"] != nil }

    /// CUTLINE_TEST_SAVE_STUDIO: the answer to the ⌘S question for a document that came from Studio.
    static var saveStudio: String? { ProcessInfo.processInfo.environment["CUTLINE_TEST_SAVE_STUDIO"] }

    static func answerAlertForTest(_ alert: NSAlert, nsWindow: NSWindow) {
        guard let response = saveStudio else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            let code: NSApplication.ModalResponse = response.hasPrefix("write") ? .alertFirstButtonReturn : .alertThirdButtonReturn
            nsWindow.endSheet(alert.window, returnCode: code)
        }
    }

    /// The modifiers the canvas reads in the handle and key tests (the Mac's real ⇧ doesn't count).
    static var testModifiers: NSEvent.ModifierFlags? {
        let environment = ProcessInfo.processInfo.environment
        guard let handle = environment["CUTLINE_TEST_HANDLE"] ?? environment["CUTLINE_TEST_KEYS"].map({ _ in "" }) else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if handle.contains("shift") { flags.insert(.shift) }
        if handle.contains("option") { flags.insert(.option) }
        return flags
    }

    /// CUTLINE_TEST_SETTINGS=1: opens Cutline › Settings at launch.
    static var openSettings: Bool { ProcessInfo.processInfo.environment["CUTLINE_TEST_SETTINGS"] != nil }

    /// The "log" step of CUTLINE_TEST_KEYS: what a test needs to check, in the log.
    static func logState(_ doc: Document, zoom: Double) {
        let objects = doc.objects.map { o in "\(o.label ?? "?")[\(o.absoluteNodes.map(\.nodes.count).map(String.init).joined(separator: "+"))]" }
        let text = doc.selectedObjects.lazy.compactMap { o -> CharacterStyle? in if case .text(let t) = o.shape { t.style(in: 0) } else { nil } }.first
        NSLog("CUTLINE_TEST state: text=%@ underline=%d", text?.postscript ?? text?.font ?? "-", text?.underline == true ? 1 : 0)
        NSLog("CUTLINE_TEST state: tool=%@ zoom=%.2f objects=%@ selected=%ld guides v=%@ h=%@ fill=%@ stroke=%@",
              doc.tool.rawValue, zoom, objects.joined(separator: " "), doc.selection.count,
              doc.guides.verticals.map { String(format: "%.1f", $0) }.joined(separator: ","),
              doc.guides.horizontals.map { String(format: "%.1f", $0) }.joined(separator: ","),
              doc.selectedObjects.first?.fill?.summaryText ?? "none", doc.selectedObjects.first?.strokeColor.summaryText ?? "-")
    }

    /// In hidden tests, copy and paste use a pasteboard of Cutline's own (the owner's stays untouched).
    static let testArea: NSPasteboard? = ProcessInfo.processInfo.environment["CUTLINE_HIDDEN"] != nil
        ? NSPasteboard(name: NSPasteboard.Name("io.github.joaogmcorrea.cutline.test")) : nil

    /// CUTLINE_TEST_KEYS=cmd+a;cmd+g;click:120,70;… (separated by ";").
    static var testKeys: [String] {
        (ProcessInfo.processInfo.environment["CUTLINE_TEST_KEYS"] ?? "").split(separator: ";").map(String.init)
    }

    /// "cmd+shift+]", "cmd+right", "esc"… as a keyDown in this window.
    static func keyEvent(_ text: String, nsWindow: NSWindow) -> NSEvent? {
        var parts = text.split(separator: "+").map(String.init)
        guard let name = parts.popLast() else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if parts.contains("cmd") { flags.insert(.command) }
        if parts.contains("shift") { flags.insert(.shift) }
        if parts.contains("opt") { flags.insert(.option) }
        let arrow = { (keyEvent: Int) in String(utf16CodeUnits: [unichar(keyEvent)], count: 1) }
        let keyPresses: [String: (UInt16, String, String)] = [
            "a": (0, "a", "A"), "c": (8, "c", "C"), "d": (2, "d", "D"), "g": (5, "g", "G"), "v": (9, "v", "V"), "x": (7, "x", "X"),
            "z": (6, "z", "Z"), "e": (14, "e", "E"), "i": (34, "i", "I"), "b": (11, "b", "B"), "u": (32, "u", "U"), "p": (35, "p", "P"), "=": (24, "=", "+"), "-": (27, "-", "_"),
            "[": (33, "[", "{"), "]": (30, "]", "}"), "esc": (53, "\u{1b}", "\u{1b}"),
            "left": (123, arrow(NSLeftArrowFunctionKey), arrow(NSLeftArrowFunctionKey)),
            "right": (124, arrow(NSRightArrowFunctionKey), arrow(NSRightArrowFunctionKey)),
            "down": (125, arrow(NSDownArrowFunctionKey), arrow(NSDownArrowFunctionKey)),
            "up": (126, arrow(NSUpArrowFunctionKey), arrow(NSUpArrowFunctionKey)),
        ]
        guard let (code, simple, withShift) = keyPresses[name] else { return nil }
        let characters = flags.contains(.shift) ? withShift : simple
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: nsWindow.windowNumber, context: nil, characters: characters,
                                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
    }

    /// CUTLINE_TEST_CONTEXT_MENU=/x.txt: the right-click menu as text (titles, shortcuts, disabled items).
    static func dumpContextMenu(_ doc: Document) {
        guard let outputPath = ProcessInfo.processInfo.environment["CUTLINE_TEST_CONTEXT_MENU"] else { return }
        func lines(_ menu: NSMenu, _ level: Int) -> [String] {
            menu.items.flatMap { item -> [String] in
                guard !item.isSeparatorItem else { return [String(repeating: "  ", count: level) + "—"] }
                let shortcut = item.keyEquivalent.isEmpty ? "" : " [\(item.keyEquivalentModifierMask.contains(.shift) ? "⇧" : "")"
                    + "\(item.keyEquivalentModifierMask.contains(.command) ? "⌘" : "")\(item.keyEquivalent.unicodeScalars.map { String(format: "%X", $0.value) }.joined())]"
                return [String(repeating: "  ", count: level) + item.title + shortcut + (item.isEnabled ? "" : " (desligado)")]
                    + (item.submenu.map { lines($0, level + 1) } ?? [])
            }
        }
        try? lines(ContextMenu.create(doc), 0).joined(separator: "\n").write(toFile: outputPath, atomically: true, encoding: .utf8)
    }

    /// CUTLINE_MARKS=1 turns on the Print & Cut marks; CUTLINE_TEST_PRINT=/path.pdf writes the print
    /// (the same drawing as File › Print…) to a PDF, without the panel.
    static func printForTest(_ doc: Document) {
        let environment = ProcessInfo.processInfo.environment
        if environment["CUTLINE_MARKS"] != nil { doc.marks = true }
        guard let outputPath = environment["CUTLINE_TEST_PRINT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            Printing.printDocument(doc, in: nil, pdf: URL(fileURLWithPath: outputPath))
            print("printed to \(outputPath)")
        }
    }

    /// Opens with a few shapes already drawn and a star selected.
    static var demo: Bool { ProcessInfo.processInfo.environment["CUTLINE_DEMO"] != nil }

    static func fillDemo(_ doc: Document) {
        guard demo, doc.objects.isEmpty else { return }
        let square = CanvasObject(shape: .rectangle(radius: 6), frame: CGRect(x: 30, y: 40, width: 60, height: 60))
        let ellipse = CanvasObject(shape: .ellipse, frame: CGRect(x: 110, y: 50, width: 70, height: 45),
                            strokeColor: CMYK(c: 100, m: 50, y: 0, k: 0))
        let star = CanvasObject(shape: .star(points: 5, innerRadius: 0.45), frame: CGRect(x: 60, y: 130, width: 90, height: 86),
                             strokeColor: CMYK(c: 70, m: 0, y: 100, k: 0))
        doc.objects = [square, ellipse, star]
        doc.selection = [star.id]
        // CUTLINE_DEMO=2: the same objects with stroke styles (dashed, printed inside and outside).
        if ProcessInfo.processInfo.environment["CUTLINE_DEMO"] == "2" {
            doc.objects[0].style.line = .dashed3
            doc.objects[1].strokeWidth = 6
            doc.objects[1].style.alignment = .inside
            doc.objects[1].fill = CMYK(c: 0, m: 0, y: 20, k: 0)
            doc.objects[2].strokeWidth = 4
            doc.objects[2].style = StrokeStyleSettings(line: .dashed2, cap: .rounded, join: .round, alignment: .outside)
            // Text, guides and direct selection showing the star's nodes.
            var text = TextBox(content: "Happy Day")
            // CUTLINE_TEST_DEMO_FONT=Family: the demo text in that family (the frame comes from its letters).
            text.style.font = ProcessInfo.processInfo.environment["CUTLINE_TEST_DEMO_FONT"] ?? "Snell Roundhand"
            text.style.size = 54
            if let test = canvasText {
                // Two centered lines, with accents: the cursor and the selection must fall on the letters.
                text.content = "Happy Day\nat Café"
                text.alignment = .center
                if test == "typography" {
                    text.style.font = "Helvetica Neue"
                    text.style.size = 40
                    text.bullet = .numbers
                    text.style.underline = true
                    text.style.tracking = 50
                    text.style.rotation = 10
                    text.alignment = .left
                }
                if test == "runs" || test.hasPrefix("outlines") {
                    // Style per run: H₂O (subscript), x² (superscript), "Day" larger and bold, "at" underlined
                    // and raised.
                    text.content = "H2O & x2 Happy Day\nat Café"
                    text.style.font = "Helvetica Neue"
                    text.style.size = 36
                    text.alignment = .left
                    text.apply({ $0.position = .subscripted }, in: NSRange(location: 1, length: 1))
                    text.apply({ $0.position = .superscripted }, in: NSRange(location: 7, length: 1))
                    text.apply({ $0.size = 60; $0.postscript = "HelveticaNeue-Bold" }, in: NSRange(location: 15, length: 3))
                    text.apply({ $0.underline = true; $0.offset = 8 }, in: NSRange(location: 19, length: 2))
                }
            }
            doc.objects.append(CanvasObject(shape: .text(text), frame: CGRect(origin: CGPoint(x: 40, y: 230), size: text.naturalSize)))
            doc.guides = Guides(verticals: [60], horizontals: [130])
            doc.tool = .direct
        }
    }

    /// CUTLINE_TEST_TEXT=1|visible|selection|typography (with CUTLINE_DEMO=2): opens typing on the demo
    /// text with the cursor in its middle. "visible" shows the invisible field in blue (it must sit over the
    /// letters); "selection" selects "Happy"; "typography" uses numbers, underline, tracking and rotation. The
    /// cursor doesn't blink, so it shows up in the snapshot.
    static var canvasText: String? { ProcessInfo.processInfo.environment["CUTLINE_TEST_TEXT"] }

    static func editTextForTest(_ doc: Document) {
        guard let test = canvasText else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            // CUTLINE_TEST_FAMILY=Montserrat switches the family (and picks the heaviest face) during editing.
            if let family = ProcessInfo.processInfo.environment["CUTLINE_TEST_FAMILY"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    doc.changeStyle { $0.switchFamily(family) }
                    doc.changeStyle { $0.postscript = Fonts.faces(family).last?.postscript }
                }
            }
            if test == "new" {
                doc.tool = .text
                doc.newText(in: CGPoint(x: 30, y: 40))
                return
            }
            guard let object = doc.objects.last(where: { if case .text = $0.shape { true } else { false } }) else { return }
            if test == "outlines" {
                // Selected text → outlines (with the regular selection, to compare the outline with the text's).
                doc.selection = [object.id]
                doc.convertTextToOutlines()
                doc.tool = .selection
                return
            }
            doc.tool = .text
            doc.editText(object.id, click: CGPoint(x: object.frame.midX, y: object.frame.minY + 4))
            if test == "outlinesWhileTyping" {
                // ⇧⌘O through the menu (the real keyboard path) with the text being edited. The menu only gets the document
                // of the active window: in an instance opened in the background it's disabled, and the test calls the
                // same action directly (what matters is converting with typing open).
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    let nsWindow = NSApp.windows.first { $0.isVisible }
                    let could = doc.hasTextToOutline
                    guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
                                                        timestamp: 0, windowNumber: nsWindow?.windowNumber ?? 0, context: nil,
                                                        characters: "O", charactersIgnoringModifiers: "O", isARepeat: false,
                                                        keyCode: 31) else { return }
                    let handled = NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
                    let converted = handled ? -1 : doc.convertTextToOutlines()
                    NSLog("CUTLINE_TEST outlinesWhileTyping: active window = %@, could = %@, menu handled = %@, direct = %d, editing after = %@",
                          "\(nsWindow?.isKeyWindow ?? false)", "\(could)", "\(handled)", converted, "\(doc.textEditing != nil)")
                }
            }
        }
    }

    /// CUTLINE_TEST_FONTS=1 opens the Character panel's font list.
    static var fontListOpen: Bool { ProcessInfo.processInfo.environment["CUTLINE_TEST_FONTS"] != nil }

    /// "selection" selects "Happy"; "new" types into the invisible field (the real keyboard path);
    /// "style" selects "Happy" and, through the panel, sets it to 60 pt superscript and types more letters at the end.
    static func selectTextForTest(_ field: NSTextView) {
        switch canvasText {
        case "selection": field.setSelectedRange(NSRange(location: 0, length: 5))
        case "style":
            field.setSelectedRange(NSRange(location: 0, length: 5))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let doc = (field.delegate as? CanvasTextField.Coordinator)?.doc else { return }
                doc.changeStyle { $0.size = 30; $0.position = .superscripted; $0.underline = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    field.setSelectedRange(NSRange(location: 2, length: 0))
                    field.insertText("XY", replacementRange: field.selectedRange())
                }
            }
        case "new": field.insertText("Hello, Cutline!\nSecond line", replacementRange: field.selectedRange())
        default: break
        }
    }

    /// Writes the window to a PNG a few seconds after opening (glass and blurs may not come out faithfully).
    /// CUTLINE_TEST_MENUS=/x.txt: the menu bar as text, to check menus and translations without clicking.
    static func dumpMenus() {
        guard let outputPath = ProcessInfo.processInfo.environment["CUTLINE_TEST_MENUS"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            func lines(_ menu: NSMenu, level: Int) -> [String] {
                menu.update()
                return menu.items.flatMap { item -> [String] in
                    let indentation = String(repeating: "    ", count: level)
                    if item.isSeparatorItem { return [indentation + "—"] }
                    var shortcut = ""
                    if !item.keyEquivalent.isEmpty {
                        let m = item.keyEquivalentModifierMask
                        shortcut = "  " + (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "")
                            + (m.contains(.shift) ? "⇧" : "") + (m.contains(.command) ? "⌘" : "") + item.keyEquivalent.uppercased()
                    }
                    let mark = item.state == .on ? "✓ " : ""
                    // CUTLINE_TEST_MENU_ACTIONS=1: also each item's action (to know which path it takes).
                    let action = ProcessInfo.processInfo.environment["CUTLINE_TEST_MENU_ACTIONS"] != nil
                        ? item.action.map { "  [" + NSStringFromSelector($0) + "]" } ?? "" : ""
                    let line = indentation + mark + item.title + shortcut + (item.isEnabled ? "" : "  (desabilitado)") + action
                    return [line] + (item.submenu.map { lines($0, level: level + 1) } ?? [])
                }
            }
            let text = NSApp.mainMenu.map { lines($0, level: 0) }?.joined(separator: "\n") ?? ""
            try? text.write(toFile: outputPath, atomically: true, encoding: .utf8)
        }
    }

    static func scheduleSnapshot() {
        guard let outputPath = ProcessInfo.processInfo.environment["CUTLINE_SNAPSHOT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard let nsWindow = NSApp.windows.first(where: { $0.isVisible }),
                  let frame = nsWindow.contentView?.superview,
                  let image = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
            frame.cacheDisplay(in: frame.bounds, to: image)
            try? image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: outputPath))
        }
    }
}
#endif
