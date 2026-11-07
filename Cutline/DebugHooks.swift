// Debug builds only: helps check the interface without screen recording permission.
//   open --env CUTLINE_SNAPSHOT=/path/window.png --env CUTLINE_DEMO=1 Cutline.app
//   CUTLINE_SEND=1 opens the Send window; CUTLINE_SIMULATE=1 uses the simulated machine;
//   CUTLINE_SIMULATE_MODEL=Silhouette_Cameo4 picks the simulated model; CUTLINE_SIMULATE_TOOLS=2,8 pretends what
//   is in its tool holders (Cameo 4 onward); CUTLINE_TEST_TOOL=2:foil sets the 1st color's holder and tool;
//   CUTLINE_TEST_MODIFY=1 changes the document by itself; CUTLINE_TEST_SAVE=/x.cutline saves a copy;
//   CUTLINE_TEST_IMPORT=/x.pdf imports; CUTLINE_TEST_PATHFINDER=divide…; CUTLINE_COLLAPSED=Color,Stroke;
//   CUTLINE_TEST_LAYER_ROWS=3 lists that many objects per layer in the Layers panel (500 normally);
//   CUTLINE_TEST_MANY_PATHS=flatten|simplify:2|all|cancel answers the question of a file with too many paths, and
//   CUTLINE_TEST_MANY_PATHS_PLAIN=/x.png shows that question in a plain hidden window (and draws it into the file);
//   CUTLINE_TEST_DROP=/x.png does the same as dropping the file in the middle of the window;
//   CUTLINE_TEST_IMAGE=image|outer|inners|inners-insert picks the answer to the imported-image question (also the
//   question of a Photoshop file with layers, which inserts right away);
//   CUTLINE_TEST_TRACE=nodes,smoothing (0–100) changes the Trace settings;
//   CUTLINE_TEST_HANDLE=1|option|shift|shift+option drags the selection's bottom-right corner (30 × 10 mm),
//   like the mouse, with those modifiers;
//   CUTLINE_TEST_SAVE_STUDIO=write|cancel (on a .studio3, after the keys) sends ⌘S through the window's
//   responder chain and answers the question 2.5 s later (twice with "write2": the 2nd writes directly);
//   CUTLINE_TEST_KEEP_STUDIO=1 leaves an opened .studio3 attached to its file (⌘S must still ask);
//   CUTLINE_TEST_SAVE_AS_STUDIO=/x.studio3 does Save As… to that .studio3 without the panel;
//   CUTLINE_TEST_KEYS=cmd+a;cmd+g;click:120,70;cmd+right… passes keys (and clicks, in mm) through the canvas
//   keyboard, one every 0.3 s; CUTLINE_TEST_CONTEXT_MENU=/x.txt dumps the right-click menu (of the selection then);
//   in the keys, offset:2 (mm; < 0 inside) offsets the selection with round corners, hover:x,y (mm) puts the pointer
//   there (the Eyedropper's loupe shows in a photo), log writes the document's state (NSLog "CUTLINE_TEST state" and
//   "CUTLINE_TEST frames"), do:spaceH runs that document action (list in `perform`), drag:x1,y1,x2,y2 (mm) drags
//   the mouse, and shift / noshift hold and let go of ⇧ for the next steps;
//   CUTLINE_TEST_SETTINGS=1 opens Cutline › Settings; CUTLINE_START=1 keeps the start screen on in a hidden test, and
//   CUTLINE_TEST_RECENT=/a.cutline:/b.studio3 shows those files as its recent ones (the owner's list stays untouched),
//   CUTLINE_TEST_START=blank|printAndCut picks that way to start 1 s after it opens;
//   CUTLINE_SNAPSHOT_DELAY=6 takes the snapshot later;
//   CUTLINE_MARKS=1 turns on the Print & Cut marks; CUTLINE_TEST_BLEED=1.5 turns on the print bleed (that width, mm);
//   CUTLINE_TEST_PRINT=/x.pdf writes the print to a PDF (one page per artboard; after CUTLINE_TEST_DELAY s, 1.5 by default);
//   in the keys, do:artboardAdd:x,y,w,h, do:artboardNew, do:artboardActivate:2, do:artboardPreset:letter,
//   do:artboardLandscape|artboardPortrait, do:artboardSize:w,h, do:artboardMoveTo:x,y, do:artboardRename:Name,
//   do:artboardOrder:-1|1 and do:artboardDelete edit the artboards (on the active one), and fit / fitAll fit the active
//   one or all of them in the canvas; CUTLINE_TEST_SEND_ARTBOARD=2 makes the Send window cut the 2nd artboard;
//   CUTLINE_TEST_SEND=1 (with CUTLINE_SIMULATE) sends by itself when the Send window opens;
//   CUTLINE_TEST_TEST_CUT=x,y[,side] (with CUTLINE_SIMULATE) sends the test cut at x,y mm when the Send window opens;
//   CUTLINE_TEST_TEST_SHAPE=x,y[,side] only turns on the test shape there (side in mm);
//   CUTLINE_TEST_SEND_PLAIN=1 opens the Send window's content in a plain hidden window (a sheet may take the menu bar);
//   CUTLINE_TEST_IGNORE_STUDIO=1 pretends Silhouette Studio is closed;
//   CUTLINE_TEST_PROFILE=/x.icc|app gives the document that CMYK profile (a path that doesn't exist: missing);
//   CUTLINE_TEST_COLORS=1 logs a few conversions with the document's profiles; CUTLINE_TEST_ASSIGN=1 opens Edit ›
//   Assign Profile…; the app's profiles go in as arguments (nothing saved): -cmykProfile '{"nome":"…","arquivo":"/x.icc"}';
//   CUTLINE_TEST_MAT=mini_6x8 picks the cutting mat on open (CuttingMat values); CUTLINE_TEST_TRACK=1 turns on Track
//   Enhancing;
//   CUTLINE_TEST_MARKS=fail (with CUTLINE_SIMULATE) makes reading the marks fail;
//   CUTLINE_OPEN_PANEL=pathfinder opens a collapsed panel;
//   CUTLINE_TEST_MENUS=/x.txt dumps the menu bar (titles, shortcuts, ✓ and disabled) to a text file;
//   CUTLINE_TEST_TEXT=1|visible|selection|typography|runs|style|new (with CUTLINE_DEMO=2) opens typing on the canvas;
//   outlines|outlinesWhileTyping converts the demo text to outlines (selected, or through ⇧⌘O while typing);
//   CUTLINE_TEST_ORDER=1 (with CUTLINE_SEND) moves the last cut color to the top, like dragging it;
//   CUTLINE_TEST_DEMO_FONT=Family sets the demo text in that family (a font installed while the app is open)
//   (CUTLINE_TEST_FAMILY=Montserrat switches the family during it);
//   CUTLINE_TEST_FONTS=1 opens the Character panel's font list.
//   Google Fonts (GoogleFonts/): CUTLINE_TEST_GOOGLE_FONTS_DIR=/x keeps the added fonts in /x/Fonts and the cache in
//   /x/Cache (a hidden test without it uses a temporary folder: tests never touch the owner's fonts);
//   CUTLINE_TEST_GOOGLE_CSS=http://127.0.0.1:9/css2 asks another address (one that doesn't answer: the offline notice);
//   CUTLINE_TEST_GOOGLE_SLOW=1 makes each file wait a second (to photograph the progress ring);
//   CUTLINE_TEST_FONT_LIST=google|installed shows the font list in a plain hidden window ("CutlineTestFonts") on that tab,
//   with CUTLINE_TEST_FONT_CURRENT=Family as the text's font; CUTLINE_TEST_FONT_STEPS=search:lob;category:display;
//   add:Lobster;wait:Lobster;choose:Lobster;snap:/x.png;remove:Lobster;tab:installed;log;sleep:2 drives it (see
//   `driveFontList`). Logs "CUTLINE_TEST google …" (the families activated at launch, each one added, with its faces).
//   CUTLINE_TEST_REPORT=bug|tools|printBleed opens the report window; CUTLINE_TEST_REPORT_TEXT=1 fills in
//   an example; CUTLINE_TEST_REPORT_OUTPUT=/x.txt writes the GitHub address and the text instead of opening it.
//   CUTLINE_TEST_PICKER=fill|stroke opens the Color Picker (CUTLINE_TEST_PICKER_PLAIN=/x.png in a plain window, drawn to
//   the file); CUTLINE_TEST_PICKER_STEPS=hex:000000;axis:red;field:0.3,0.7;…;ok drives it (see `drivePicker`).
//   CUTLINE_TEST_LINK=1 makes CUTLINE_TEST_IMPORT import with Link; CUTLINE_TEST_LINK_ANSWER=update|later answers the
//   question of a linked file changed on disk; CUTLINE_TEST_PATH_OPTIONS=effect:skew;…;ok drives Type on a Path Options
//   (opened by do:pathOptions). More "do:" actions (gradients, layer opacity and blending, links, Type on a Path, undo) are
//   listed in `perform`.
//   CUTLINE_CANVA_SERVER=http://127.0.0.1:8791/canva/ uses the test backend of Open from Canva… (_site/canva/dev/serve.sh)
//   and turns the menu item on (the session goes to a file, CUTLINE_TEST_CANVA_SESSION, never to the Keychain);
//   CUTLINE_TEST_CANVA=1 opens that window; CUTLINE_TEST_CANVA_STEPS=signin;search:tags;pick:Gift tags;page:2;open drives
//   it (see `driveCanva`); CUTLINE_TEST_CANVA_SAVE=/x.cutline saves the document it opens.
//   A .cutlinesend (Illustrator's "Send to Cutline" script) opened with `open -a`: CUTLINE_TEST_ILLUSTRATOR_SAVE=/x.cutline
//   saves the new document; CUTLINE_TEST_INSTALL_SCRIPT=/a/Scripts:/b/Scripts installs the script into those folders
//   (=list logs the Illustrators found).
//   CUTLINE_TEST_DEVICE_IMPORT=/x.jpg|/x.png|/x.heic|/x.tiff|/x.pdf does what Continuity Camera does (File › Import from
//   iPhone or iPad): puts the file on the test pasteboard and hands its items, as item providers, to the window's
//   handler (as AppKit and SwiftUI do); logs "CUTLINE_TEST device …" (the providers, the image question or the scan's
//   objects, and every object 6 s later), after 1.5 s or CUTLINE_TEST_DEVICE_DELAY. With CUTLINE_TEST_IMAGE it answers the
//   image question too.
//   Rotation (Model/Rotation.swift): in the keys, do:rotate:30 turns the selection 30° counterclockwise around its center
//   (do:rotate:30@x,y around that point), do:rotateCopy:30 turns copies, do:resetBox is Reset Bounding Box, do:angle:30 is the
//   control bar's angle field (around the reference point, top-left as it starts), do:width:40 and do:height:20 its W and
//   H, do:rotateDialog opens Object › Transform › Rotate…, and CUTLINE_TEST_ROTATE_STEPS=angle:45;preview;sleep:1;ok|copy|cancel
//   drives that window (see `driveRotateWindow`); drag:… from just outside a corner of the selection turns it (as the
//   mouse), and with do:tool:rotate a click moves the center and a drag turns around it. CUTLINE_TEST_ROTATE_POINTER=/folder
//   writes the rotate pointer's pictures there (rotate-<degrees>.png).
//   Images inside shapes (Editor/ImageInsideShape.swift): CUTLINE_DEMO=4 draws shapes (a star turned 30°, an ellipse, a
//   rounded rectangle, a hexagon) and a test image on its own (four colored quarters, a black square at its top-left
//   corner), labeled Star, Ellipse, Rect, Hexagon and Photo. In the keys: select:Star (by label; select+:Photo adds),
//   do:clipMake (⌘7), do:clipRelease (⌥⌘7), do:copyImage:/x.png puts that file on the test pasteboard as another app copies
//   an image, do:pasteInside (⌥⌘V), do:putFile:/x.png@x,y drops that file at x,y mm as the Finder does, do:imageFit:tile
//   (fill, fit, stretch), do:imageScale:50 and do:imageOpacity:50 (%, as the control bar), do:editContent (double click),
//   do:contentMove:dx,dy (mm), do:contentScale:1.5 and do:contentRotate:30 (around the content's center), do:contentExit
//   (Esc); "command" / "nocommand" hold and let go of ⌘ for the next drag: steps (dragging an image onto a shape).
//   CUTLINE_TEST_DROP_AT=x,y (mm) drops CUTLINE_TEST_DROP's file there instead of the window's middle. The "log" step writes
//   each image's fitting ("CUTLINE_TEST images").
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

    /// CUTLINE_TEST_REPORT=bug|tools|printBleed opens the report window at launch (the last two as their
    /// "Report a Problem…" links do, with the document's details).
    static func reportRequest(doc: Document, machine: Machine) -> ReportRequest? {
        switch ProcessInfo.processInfo.environment["CUTLINE_TEST_REPORT"] {
        case "bug": ReportRequest()
        case "tools": ReportRequest(feature: .tools, context: ToolChoice.reportContext(doc: doc, machine: machine))
        case "printBleed": ReportRequest(feature: .printBleed, context: PrintBleed.reportContext(doc))
        default: nil
        }
    }

    /// CUTLINE_TEST_REPORT_TEXT=1 fills the window with an example; with CUTLINE_TEST_REPORT_OUTPUT, it also
    /// "opens in GitHub" by itself (the address goes to the file, see `dumpReport`).
    static func fillReport(_ report: inout Report, send: @escaping () -> Void) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CUTLINE_TEST_REPORT_TEXT"] != nil else { return }
        report.summary = "The star comes out cut in half"
        report.summaryText = "I sent the test sticker to cut and the machine stopped in the middle of the star."
        report.detail = "1. File › New\n2. Draw a 40 mm star\n3. Send (⌘E) › Cut"
        report.expected = "The whole star cut cleanly."
        guard environment["CUTLINE_TEST_REPORT_OUTPUT"] != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { send() }
    }

    /// CUTLINE_TEST_REPORT_OUTPUT=/x.txt: the issue address and the text go to the file, without opening the browser.
    static func dumpReport(url: URL, text: String) -> Bool {
        guard let outputPath = ProcessInfo.processInfo.environment["CUTLINE_TEST_REPORT_OUTPUT"] else { return false }
        try? (url.absoluteString + "\n\n" + text).write(toFile: outputPath, atomically: true, encoding: .utf8)
        return true
    }

    /// CUTLINE_TEST_TOOL=2:foil (holder:tool, the tool by its stored value or its name): the Send window sets the first
    /// color to it, in the document only (not in the app's remembered settings).
    static var testTool: (Int, CutTool)? {
        guard let text = ProcessInfo.processInfo.environment["CUTLINE_TEST_TOOL"] else { return nil }
        let parts = text.split(separator: ":").map(String.init)
        guard parts.count == 2, let holder = Int(parts[0]),
              let tool = CutTool(rawValue: parts[1]) ?? CutTool.allCases.first(where: { "\($0)" == parts[1] }) else { return nil }
        return (holder, tool)
    }

    /// CUTLINE_SEND=1 opens the Send window at launch (with CUTLINE_SIMULATE=1, without a machine).
    static var openSendWindow: Bool { ProcessInfo.processInfo.environment["CUTLINE_SEND"] != nil }

    /// CUTLINE_TEST_MARKS=fail with CUTLINE_SIMULATE: the simulated machine "doesn't find" the Print & Cut marks.
    static var marksFail: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CUTLINE_TEST_MARKS"] == "fail" && environment["CUTLINE_SIMULATE"] != nil
    }

    /// CUTLINE_TEST_SEND_ARTBOARD=2: the Send window picks that artboard (1 = the 1st) instead of the active one.
    static var sendArtboard: Int? { ProcessInfo.processInfo.environment["CUTLINE_TEST_SEND_ARTBOARD"].flatMap { Int($0) } }

    /// CUTLINE_TEST_SEND=1 with CUTLINE_SIMULATE: the Send window sends by itself (transcript in ~/Library/Logs/Cutline).
    static var sendForTest: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CUTLINE_TEST_SEND"] != nil && environment["CUTLINE_SIMULATE"] != nil
    }

    /// CUTLINE_TEST_SEND_PLAIN=1 (or =/x.png): the Send window's content opens in a plain window instead of a sheet. In a
    /// hidden copy, a sheet can take over the menu bar; this window goes straight below the desktop, off the screens, and
    /// never becomes key (`screencapture -l` finds it by the title "CutlineTestSend"). With a .png path, it also draws
    /// itself into that file 2.5 s later (no screen recording permission needed; glass doesn't show in it).
    static var openSendPlain: Bool { ProcessInfo.processInfo.environment["CUTLINE_TEST_SEND_PLAIN"] != nil }

    static func showPlain(_ view: some View, title: String, size: CGSize,
                          output: String? = ProcessInfo.processInfo.environment["CUTLINE_TEST_SEND_PLAIN"]) {
        let nsWindow = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: size.width, height: size.height),
                                styleMask: [.borderless], backing: .buffered, defer: false)
        nsWindow.title = title
        nsWindow.isReleasedWhenClosed = false
        nsWindow.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        nsWindow.contentView = NSHostingView(rootView: view)
        nsWindow.orderFront(nil)
        plainWindows.append(nsWindow)
        guard let outputPath = output, outputPath.hasSuffix(".png") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard let view = nsWindow.contentView, let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: image)
            try? image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: outputPath))
        }
    }

    private static var plainWindows: [NSWindow] = []

    /// CUTLINE_TEST_TEST_CUT=x,y[,side] with CUTLINE_SIMULATE: the Send window turns on the test shape, puts it at
    /// x,y mm (with that side, in mm) and sends it.
    static var testCut: (CGPoint, Double?)? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CUTLINE_SIMULATE"] != nil else { return nil }
        return testShapeValue(environment["CUTLINE_TEST_TEST_CUT"])
    }

    /// CUTLINE_TEST_TEST_SHAPE=x,y[,side]: the Send window turns on the test shape at x,y mm (with that side, in mm),
    /// without sending it.
    static var testShape: (CGPoint, Double?)? { testShapeValue(ProcessInfo.processInfo.environment["CUTLINE_TEST_TEST_SHAPE"]) }

    private static func testShapeValue(_ value: String?) -> (CGPoint, Double?)? {
        guard let n = value?.split(separator: ",").compactMap({ Double($0) }), n.count == 2 || n.count == 3 else { return nil }
        return (CGPoint(x: n[0], y: n[1]), n.count == 3 ? n[2] : nil)
    }

    /// CUTLINE_TEST_ASSIGN=1 opens Edit › Assign Profile…'s sheet.
    static var openAssignProfile: Bool { ProcessInfo.processInfo.environment["CUTLINE_TEST_ASSIGN"] != nil }

    /// CUTLINE_TEST_PICKER=fill|stroke opens the Color Picker 1 s after the window (as a double-click on that square);
    /// with CUTLINE_TEST_PICKER_PLAIN=/x.png it opens in a plain hidden window instead and draws itself into that file.
    static func openPickerForTest(_ doc: Document) {
        guard let name = ProcessInfo.processInfo.environment["CUTLINE_TEST_PICKER"] else { return }
        let target: ColorPickerTarget = name == "stroke" ? .strokeColor : .fill
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if let output = ProcessInfo.processInfo.environment["CUTLINE_TEST_PICKER_PLAIN"] {
                showPlain(ColorPickerView(doc: doc, request: ColorPickerRequest(target: target)), title: "CutlineTestPicker",
                          size: CGSize(width: 760, height: 400), output: output)
            } else {
                doc.openColorPicker(target)
            }
        }
    }

    /// CUTLINE_TEST_PATH_OPTIONS=effect:skew;align:center;spacing:2;flip;range:10,90;ok drives Type on a Path Options
    /// (opened by do:pathOptions in CUTLINE_TEST_KEYS), one step every 0.4 s.
    static func drivePathTextOptions(_ options: Binding<TextOnPath>, ok: () -> Void) async {
        let steps = (ProcessInfo.processInfo.environment["CUTLINE_TEST_PATH_OPTIONS"] ?? "").split(separator: ";").map(String.init)
        for step in steps {
            try? await Task.sleep(for: .milliseconds(400))
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let value = parts.count > 1 ? parts[1] : ""
            switch parts[0] {
            case "effect": if let e = PathTextEffect.allCases.first(where: { "\($0)" == value }) { options.wrappedValue.effect = e }
            case "align": if let a = PathTextAlignment.allCases.first(where: { "\($0)" == value }) { options.wrappedValue.alignment = a }
            case "spacing": options.wrappedValue.spacing = Double(value) ?? 0
            case "flip": options.wrappedValue.flipped.toggle()
            case "range":
                let v = value.split(separator: ",").compactMap { Double($0) }
                if v.count == 2 { (options.wrappedValue.start, options.wrappedValue.end) = (v[0] / 100, v[1] / 100) }
            case "ok":
                ok()
                return
            default: NSLog("CUTLINE_TEST path options: unknown step %@", step)
            }
        }
    }

    /// CUTLINE_TEST_PICKER_STEPS=hex:000000;axis:red;field:0.3,0.7;strip:0.5;rgb:255,0,0;hsb:120,50,50;cmyk:0,0,0,100;
    /// web;noweb;swatches;revert;sample;ok drives the open picker, one step every 0.4 s, and logs its state after each
    /// ("CUTLINE_TEST picker").
    /// CUTLINE_TEST_ROTATE_STEPS: angle:45;preview;sleep:1;ok|copy|cancel, one every 0.4 s, in the Rotate window.
    static func driveRotateWindow(angle: Binding<Double>, preview: Binding<Bool>, copy: @escaping () -> Void, ok: @escaping () -> Void,
                                  cancel: @escaping () -> Void) {
        let steps = (ProcessInfo.processInfo.environment["CUTLINE_TEST_ROTATE_STEPS"] ?? "").split(separator: ";").map(String.init)
        guard !steps.isEmpty else { return }
        Task { @MainActor in
            for step in steps {
                try? await Task.sleep(for: .milliseconds(400))
                let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
                switch parts[0] {
                case "angle": if parts.count > 1, let v = Double(parts[1]) { angle.wrappedValue = v }
                case "preview": preview.wrappedValue.toggle()
                case "sleep": if parts.count > 1, let v = Double(parts[1]) { try? await Task.sleep(for: .seconds(v)) }
                case "ok": ok()
                case "copy": copy()
                case "cancel": cancel()
                default: NSLog("CUTLINE_TEST rotate window: unknown step %@", step)
                }
                NSLog("CUTLINE_TEST rotate window: %@", step)
            }
        }
    }

    /// CUTLINE_TEST_ROTATE_POINTER=/folder: the rotate pointer at a few angles, as PNGs to look at.
    static func writeRotatePointers() {
        guard let folder = ProcessInfo.processInfo.environment["CUTLINE_TEST_ROTATE_POINTER"] else { return }
        for degrees in [45, 135, 225, 315, 0, 90] {
            let image = RotatePointer.image(degrees)
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("rotate-\(degrees).png"))
        }
        NSLog("CUTLINE_TEST rotate pointers written to %@", folder)
    }

    static func drivePicker(_ model: ColorPickerModel, ok: () -> Void) async {
        let steps = (ProcessInfo.processInfo.environment["CUTLINE_TEST_PICKER_STEPS"] ?? "").split(separator: ";").map(String.init)
        guard !steps.isEmpty else { return }
        NSLog("CUTLINE_TEST picker start: %@", model.summary)
        for step in steps {
            try? await Task.sleep(for: .milliseconds(400))
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let numbers = parts.count > 1 ? parts[1].split(separator: ",").compactMap { Double($0) } : []
            switch parts[0] {
            case "hex": model.set(hex: parts.count > 1 ? parts[1] : "")
            case "axis":
                let names: [String: ColorPickerModel.Axis] = ["hue": .hue, "saturation": .saturation, "brightness": .brightness,
                                                              "red": .red, "green": .green, "blue": .blue]
                if parts.count > 1, let axis = names[parts[1]] { model.axis = axis }
            case "field" where numbers.count == 2: model.setField(CGPoint(x: numbers[0], y: numbers[1]))
            case "strip" where numbers.count == 1: model.setStrip(numbers[0])
            case "rgb" where numbers.count == 3: model.setRGB(numbers.map { $0 / 255 })
            case "hsb" where numbers.count == 3: model.setHSB([numbers[0], numbers[1] / 100, numbers[2] / 100])
            case "cmyk" where numbers.count == 4: model.set(cmyk: CMYK(c: numbers[0], m: numbers[1], y: numbers[2], k: numbers[3]))
            case "web": model.webOnly = true
            case "noweb": model.webOnly = false
            case "swatches": model.showingSwatches.toggle()
            case "revert": model.revert()
            case "ok":
                NSLog("CUTLINE_TEST picker ok: %@", model.summary)
                ok()
                return
            default: NSLog("CUTLINE_TEST picker: unknown step %@", step)
            }
            NSLog("CUTLINE_TEST picker %@: %@", step, model.summary)
        }
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
        // CUTLINE_TEST_TRACK=1 turns on the Send window's Track Enhancing in the document.
        if ProcessInfo.processInfo.environment["CUTLINE_TEST_TRACK"] != nil { doc.trackEnhancing = true }
        // CUTLINE_TEST_PROFILE=/x.icc gives the document that CMYK profile (as Edit › Assign Profile…, without undo; a path
        // that doesn't exist tests the missing profile, "app" goes back to the app's); CUTLINE_TEST_COLORS=1 logs a few
        // conversions with the document's profiles ("CUTLINE_TEST colors").
        if let path = ProcessInfo.processInfo.environment["CUTLINE_TEST_PROFILE"] {
            doc.colorProfile = path == "app" ? nil
                : ColorProfiles.read(URL(fileURLWithPath: path))?.0 ?? ColorProfile(name: "Missing Test Profile", path: path)
        }
        if ProcessInfo.processInfo.environment["CUTLINE_TEST_COLORS"] != nil {
            let c = doc.colors
            let samples = [CMYK(c: 0, m: 0, y: 0, k: 100), CMYK(c: 100, m: 0, y: 0, k: 0), CMYK(c: 0, m: 100, y: 0, k: 0),
                           CMYK(c: 0, m: 0, y: 100, k: 0), CMYK(c: 0, m: 100, y: 100, k: 0)]
            let shown = samples.map { "\($0.summaryText) → #\(c.hex($0))" }.joined(separator: " · ")
            let typed = ["000000", "FF0000", "00FF00", "0000FF", "ED1C24"].map { "#\($0) → \(c.cmyk(hex: $0)!.summaryText)" }
            NSLog("CUTLINE_TEST colors CMYK “%@”%@ · RGB “%@”%@ · %@ · %@", c.cmykProfile.name, c.cmykMissing ? " (missing)" : "",
                  c.rgbProfile.name, c.rgbMissing ? " (missing)" : "", shown, typed.joined(separator: " · "))
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

    /// CUTLINE_TEST_LAYER_ROWS=3 lists only that many objects per layer in the Layers panel (instead of 500), to see
    /// the "more objects not listed" line at the top of the panel.
    static var layerRows: Int? {
        ProcessInfo.processInfo.environment["CUTLINE_TEST_LAYER_ROWS"].flatMap { Int($0) }
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

    /// CUTLINE_TEST_LINK=1: CUTLINE_TEST_IMPORT imports with Link (as the option in Import…'s panel).
    static var linkImport: Bool { ProcessInfo.processInfo.environment["CUTLINE_TEST_LINK"] != nil }

    /// CUTLINE_TEST_LINK_ANSWER=update|later answers the question of a linked file that changed on disk (logged).
    static func answerLinksForTest(_ doc: Document) {
        let states = doc.imageKeysInUse.compactMap { key in doc.links[key].map { _ in "\(doc.imageName(key))=\(doc.linkStates[key].map { "\($0)" } ?? "-")" } }
        NSLog("CUTLINE_TEST links: %@ ask=%ld", states.joined(separator: " "), doc.linksToAsk.count)
        guard !doc.linksToAsk.isEmpty, let answer = ProcessInfo.processInfo.environment["CUTLINE_TEST_LINK_ANSWER"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if answer == "update" { doc.updateLinks(doc.linksToAsk) } else { doc.linksToAsk = [] }
            NSLog("CUTLINE_TEST links answered %@", answer)
        }
    }

    /// CUTLINE_TEST_IMPORT=/file.pdf|.ai|.png does the same as File › Import… with that file.
    static var importForTest: URL? {
        ProcessInfo.processInfo.environment["CUTLINE_TEST_IMPORT"].map { URL(fileURLWithPath: $0) }
    }

    /// CUTLINE_TEST_DROP=/file does the same as dropping the file in the middle of the window.
    static var dropForTest: URL? {
        ProcessInfo.processInfo.environment["CUTLINE_TEST_DROP"].map { URL(fileURLWithPath: $0) }
    }

    /// CUTLINE_TEST_DROP_AT=x,y (mm): where CUTLINE_TEST_DROP drops the file (the window's middle without it).
    static var dropPointForTest: CGPoint? {
        let v = ProcessInfo.processInfo.environment["CUTLINE_TEST_DROP_AT"]?.split(separator: ",").compactMap { Double($0) } ?? []
        return v.count == 2 ? CGPoint(x: v[0], y: v[1]) : nil
    }

    /// CUTLINE_TEST_IMAGE=image|outer|inners|inners-insert: the answer to the imported-image question.
    static var imageChoice: String? { ProcessInfo.processInfo.environment["CUTLINE_TEST_IMAGE"] }

    private static var deviceImportDone = false

    /// Each document window's Import from iPhone or iPad handler (Editor/DeviceImport.swift), for the test below.
    static var deviceImportHandler: [ObjectIdentifier: ([NSItemProvider]) -> Bool] = [:]

    /// CUTLINE_TEST_DEVICE_IMPORT=/x.jpg|/x.pdf: what Continuity Camera does once the photo or scan arrives
    /// (Editor/DeviceImport.swift). AppKit gives SwiftUI's requestor the pasteboard's items as item providers
    /// (`readSelection(fromItems:)`), and SwiftUI hands them to the window's `importsItemProviders`; here the file goes on
    /// the test pasteboard (never the owner's), each of its items becomes a provider with all its types, and they go to
    /// the same handler. (The requestor itself only answers in the key window, which a hidden copy never has.)
    static func deviceImportForTest(_ nsWindow: NSWindow?, doc: Document) {
        guard let path = ProcessInfo.processInfo.environment["CUTLINE_TEST_DEVICE_IMPORT"], !deviceImportDone,
              nsWindow != nil, let area = testArea else { return }
        deviceImportDone = true
        // CUTLINE_TEST_DEVICE_DELAY=3: later (after a few CUTLINE_TEST_KEYS).
        let wait = Double(ProcessInfo.processInfo.environment["CUTLINE_TEST_DEVICE_DELAY"] ?? "") ?? 1.5
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            let url = URL(fileURLWithPath: path)
            guard let data = try? Data(contentsOf: url) else { return NSLog("CUTLINE_TEST device: can't read %@", path) }
            let kind: NSPasteboard.PasteboardType = switch url.pathExtension.lowercased() {
            case "pdf": .pdf
            case "png": .png
            case "tif", "tiff": .tiff
            case "heic": .init("public.heic")
            default: .init("public.jpeg")
            }
            area.clearContents()
            area.setData(data, forType: kind)
            let providers = (area.pasteboardItems ?? []).map { item in
                let provider = NSItemProvider()
                for type in item.types {
                    provider.registerDataRepresentation(forTypeIdentifier: type.rawValue, visibility: .all) { completion in
                        completion(item.data(forType: type), nil)
                        return nil
                    }
                }
                return provider
            }
            guard let handler = deviceImportHandler[ObjectIdentifier(doc)] else { return NSLog("CUTLINE_TEST device: no handler") }
            NSLog("CUTLINE_TEST device providers: %@ → %@", providers.map { $0.registeredTypeIdentifiers.joined(separator: ",") }
                .joined(separator: " | "), handler(providers) ? "taken" : "refused")
            NSLog("CUTLINE_TEST device: visible center %@, artboard %@", doc.visibleCenter.map { NSStringFromPoint($0) } ?? "nil",
                  NSStringFromRect(doc.activeArtboard.rect))
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                for object in doc.objects {
                    NSLog("CUTLINE_TEST device object: %@ %@ center %@%@", object.name, NSStringFromRect(object.frame),
                          NSStringFromPoint(CGPoint(x: object.frame.midX, y: object.frame.midY)),
                          object.image.map { " image \($0.key.prefix(8)) \(doc.images[$0.key]?.count ?? 0) bytes" } ?? "")
                }
                NSLog("CUTLINE_TEST device notice: %@", doc.notice ?? "none")
            }
        }
    }

    /// The image question opened for what arrived from the device.
    static func deviceImportOpened(_ image: ImageToTrace) {
        let source = CGImageSourceCreateWithData(image.payload as CFData, nil)
        NSLog("CUTLINE_TEST device image: %d × %d px, %@ %d bytes, width %.1f mm, frame %@", image.image.width, image.image.height,
              source.flatMap { CGImageSourceGetType($0) as String? } ?? "?", image.payload.count, image.initialWidth,
              NSStringFromRect(image.frame(width: image.initialWidth)))
    }

    /// The scanned page's objects, once in the document.
    static func deviceImportInserted(_ doc: Document, _ objects: [CanvasObject]) {
        guard let first = objects.first else { return }
        let box = objects.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        NSLog("CUTLINE_TEST device scan: %d objects, box %@, center %@", objects.count, NSStringFromRect(box),
              NSStringFromPoint(CGPoint(x: box.midX, y: box.midY)))
    }

    /// CUTLINE_TEST_MANY_PATHS=flatten|simplify|simplify:2|all|cancel: the answer to the many-paths question (simplify
    /// with that size in mm), picked by itself once the previews are ready.
    static var manyPathsChoice: String? { ProcessInfo.processInfo.environment["CUTLINE_TEST_MANY_PATHS"] }

    /// CUTLINE_TEST_MANY_PATHS_PLAIN=1 (or =/x.png): the many-paths question opens in a plain hidden window instead of a
    /// sheet, like CUTLINE_TEST_SEND_PLAIN (with a .png, it draws itself into that file 2.5 s later).
    static var manyPathsPlain: String? { ProcessInfo.processInfo.environment["CUTLINE_TEST_MANY_PATHS_PLAIN"] }

    /// CUTLINE_TEST_TRACE=nodes,smoothing (0 to 100): the Trace settings on open.
    static var traceSettings: (nodes: Double, smoothing: Double)? {
        let values = (ProcessInfo.processInfo.environment["CUTLINE_TEST_TRACE"] ?? "").split(separator: ",").compactMap { Double($0) }
        return values.count == 2 ? (values[0], values[1]) : nil
    }

    /// CUTLINE_TEST_HANDLE=1: as soon as there is a selection, drags the bottom-right corner handle 30 mm to the
    /// right and 10 mm down, along the same path as the mouse (CanvasView.dragHandleForTest).
    static var dragHandle: Bool { ProcessInfo.processInfo.environment["CUTLINE_TEST_HANDLE"] != nil }

    static var hidden: Bool { ProcessInfo.processInfo.environment["CUTLINE_HIDDEN"] != nil }

    /// CUTLINE_TEST_SAVE_AS_STUDIO=/x.studio3 (on a .studio3, after the keys): Save As… to that .studio3, without the panel.
    static var saveAsStudio: URL? {
        ProcessInfo.processInfo.environment["CUTLINE_TEST_SAVE_AS_STUDIO"].map { URL(fileURLWithPath: $0) }
    }

    /// CUTLINE_TEST_KEEP_STUDIO=1: the window doesn't detach an opened .studio3 (to test that ⌘S still asks).
    static var keepStudioAttached: Bool { ProcessInfo.processInfo.environment["CUTLINE_TEST_KEEP_STUDIO"] != nil }

    /// CUTLINE_TEST_SAVE_STUDIO: the answer to the ⌘S question for a document that came from Studio.
    static var saveStudio: String? { ProcessInfo.processInfo.environment["CUTLINE_TEST_SAVE_STUDIO"] }

    static func answerAlertForTest(_ alert: NSAlert, nsWindow: NSWindow) {
        guard let response = saveStudio else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            let code: NSApplication.ModalResponse = response.hasPrefix("write") ? .alertFirstButtonReturn : .alertThirdButtonReturn
            nsWindow.endSheet(alert.window, returnCode: code)
        }
    }

    /// ⇧ held by the "shift" step of CUTLINE_TEST_KEYS (until "noshift").
    static var heldModifiers: NSEvent.ModifierFlags = []

    /// The modifiers the canvas reads in the handle and key tests (the Mac's real ⇧ doesn't count).
    static var testModifiers: NSEvent.ModifierFlags? {
        let environment = ProcessInfo.processInfo.environment
        guard let handle = environment["CUTLINE_TEST_HANDLE"] ?? environment["CUTLINE_TEST_KEYS"].map({ _ in "" }) else { return nil }
        var flags = heldModifiers
        if handle.contains("shift") { flags.insert(.shift) }
        if handle.contains("option") { flags.insert(.option) }
        return flags
    }

    static var startAction: String? { ProcessInfo.processInfo.environment["CUTLINE_TEST_START"] }

    static var recentForTest: [URL]? {
        ProcessInfo.processInfo.environment["CUTLINE_TEST_RECENT"].map { $0.split(separator: ":").map { URL(fileURLWithPath: String($0)) } }
    }

    /// CUTLINE_TEST_SETTINGS=1: opens Cutline › Settings at launch.
    static var openSettings: Bool { ProcessInfo.processInfo.environment["CUTLINE_TEST_SETTINGS"] != nil }

    /// The "do:" step of CUTLINE_TEST_KEYS: runs a document action by name, as its menu item does (the menus are
    /// disabled in a hidden copy): do:spaceH, do:spaceV.
    static func perform(_ name: String, _ doc: Document) {
        switch name {
        case "spaceH": doc.distribute(.horizontal)
        case "spaceV": doc.distribute(.vertical)
        case "sameFill": doc.selectSame(.fill)
        case "sameStroke": doc.selectSame(.strokeColor)
        case "newLayer": doc.newLayer()
        case "toLayer": doc.moveSelectionToActiveLayer()
        case "compoundMake": doc.makeCompoundPath()
        case "compoundRelease": doc.releaseCompoundPath()
        case _ where name.hasPrefix("tool:"):
            if let tool = Tool(rawValue: String(name.dropFirst(5))) { doc.tool = tool }
        case _ where name.hasPrefix("pathfinder:"):
            guard let operation = PathfinderOperation(rawValue: String(name.dropFirst(11))) else { break }
            NSLog("CUTLINE_TEST pathfinder %@: %@", operation.rawValue, doc.pathfinder(operation) ?? "done")
        case _ where name.hasPrefix("merge:"):
            // The same as File › Merge… with that file, without the panel.
            do {
                let notice = try doc.merge(URL(fileURLWithPath: String(name.dropFirst(6))))
                doc.notice = notice
                NSLog("CUTLINE_TEST merge: %@", notice)
            } catch {
                NSLog("CUTLINE_TEST merge failed: %@", error.localizedDescription)
            }
        case _ where name.hasPrefix("saveSelection:"):
            // The same file as File › Save Selection…, written without the panel.
            let path = String(name.dropFirst(14))
            do {
                try doc.selectionFile()?.write(to: URL(fileURLWithPath: path))
                NSLog("CUTLINE_TEST saveSelection: %@", path)
            } catch {
                NSLog("CUTLINE_TEST saveSelection failed: %@", error.localizedDescription)
            }
        case _ where name.hasPrefix("layerOpacity:"):
            if let v = Double(name.dropFirst(13)) { doc.setLayerOpacity(doc.activeLayer, v) }
        case _ where name.hasPrefix("layerBlend:"):
            if let mode = LayerBlend.allCases.first(where: { "\($0)" == name.dropFirst(11) }) { doc.setLayerBlend(doc.activeLayer, mode) }
        case _ where name.hasPrefix("rotate:") || name.hasPrefix("rotateCopy:"):
            // rotate:30 or rotate:30@x,y (mm): the selection turned around its center or that point.
            let copy = name.hasPrefix("rotateCopy:")
            let parts = name.dropFirst(copy ? 11 : 7).split(separator: "@")
            let at = parts.count > 1 ? parts[1].split(separator: ",").compactMap { Double($0) } : []
            if let degrees = parts.first.flatMap({ Double($0) }) {
                doc.rotateSelection(by: degrees, around: at.count == 2 ? CGPoint(x: at[0], y: at[1]) : nil, copy: copy)
            }
        case "resetBox": doc.resetBoundingBox()
        case _ where name.hasPrefix("rotateEach:"):
            // Each selected piece (a group as one) around its own center, in one step (test only).
            guard let degrees = Double(name.dropFirst(11)) else { break }
            doc.registrar()
            for piece in doc.selectedPieces {
                let ids = Set(piece.map(\.id))
                let center = piece.dropFirst().reduce(piece[0].bounds) { $0.union($1.bounds) }
                for i in doc.objects.indices where ids.contains(doc.objects[i].id) {
                    doc.objects[i].rotate(by: degrees, around: CGPoint(x: center.midX, y: center.midY))
                }
            }
        case "rotateDialog": doc.rotateRequest = RotateRequest()
        case _ where name.hasPrefix("angle:"):
            // As the control bar's angle field, with the reference point it starts with (the top-left corner).
            if let v = Double(name.dropFirst(6)), let box = doc.selectionFrame {
                doc.rotateSelection(by: CanvasObject.normalizedAngle(v - box.angle), around: box.point(0, 0))
            }
        case _ where name.hasPrefix("width:") || name.hasPrefix("height:"):
            // As the control bar's W or H (top-left reference point, proportions free).
            let width = name.hasPrefix("width:")
            if let v = Double(name.dropFirst(width ? 6 : 7)), let box = doc.selectionFrame {
                var r = box.rect
                if width { r.size.width = v } else { r.size.height = v }
                doc.fitSelection(box, to: r)
            }
        case "undo": doc.undo()
        case "redo": doc.redo()
        case "pathOptions": doc.pathTextOptionsOpen = true
        case _ where name.hasPrefix("pathText:"):
            // pathText:x,y (mm): Type on a Path on the object there, starting at that point (as the tool's click).
            let v = name.dropFirst(9).split(separator: ",").compactMap { Double($0) }
            guard v.count == 2 else { break }
            let p = CGPoint(x: v[0], y: v[1])
            let target = doc.objectsInOrder.reversed().first { o in
                !doc.untouchable(o) && o.shapePath.cgPath.copy(strokingWithWidth: 3, lineCap: .round, lineJoin: .round, miterLimit: 10).contains(p)
            }
            if let target { doc.tool = .typeOnPath; doc.newPathText(on: target.id, at: p) }
        case _ where name.hasPrefix("type:"):
            // type:text types into the text being edited (as the keyboard into the invisible field).
            if let id = doc.textEditing?.id, let object = doc.objects.first(where: { $0.id == id }), case .text(let t) = object.shape {
                doc.typeText(t.content + name.dropFirst(5), textRuns: [], emptyStyle: nil)
            }
        case "finishText": doc.finishText()
        case _ where name.hasPrefix("pathRange:"):
            let v = name.dropFirst(10).split(separator: ",").compactMap { Double($0) }
            if v.count == 2 { doc.changePathText { $0.start = v[0] / 100; $0.end = v[1] / 100 } }
        case "pathFlip": doc.changePathText { $0.flipped.toggle() }
        case "outlines": NSLog("CUTLINE_TEST outlines: %d", doc.convertTextToOutlines())
        case "embed": doc.embed(doc.imageKeysInUse)
        case "updateLinks": doc.updateLinks(doc.imageKeysInUse.filter { doc.links[$0] != nil })
        case _ where name.hasPrefix("relinkSelected:"):
            // The Links panel's Relink… on the selected object's image (an image inside a shape too).
            if let key = doc.selectedObjects.first?.image?.key {
                NSLog("CUTLINE_TEST relink: %d", doc.relink(key, to: URL(fileURLWithPath: String(name.dropFirst(15)))) ? 1 : 0)
            }
        case _ where name.hasPrefix("relink:"):
            if let key = doc.imageKeysInUse.first { NSLog("CUTLINE_TEST relink: %d", doc.relink(key, to: URL(fileURLWithPath: String(name.dropFirst(7)))) ? 1 : 0) }
        case "gradient": doc.applyGradient()
        case "gradientSolid": doc.removeGradient()
        case _ where name.hasPrefix("gradient:"):
            // gradient:radial|linear[,angle] changes the type (and the angle).
            let parts = name.dropFirst(9).split(separator: ",")
            var g = doc.currentGradient
            if let kind = parts.first.flatMap({ GradientKind(rawValue: String($0)) }) { g.kind = kind }
            if parts.count > 1, let angle = Double(parts[1]) { g.angle = angle }
            doc.changeGradient(to: g)
        case _ where name.hasPrefix("gradientStop:"):
            // gradientStop:location,c,m,y,k adds a stop (as a click on the bar, with that color).
            let v = name.dropFirst(13).split(separator: ",").compactMap { Double($0) }
            guard v.count == 5 else { break }
            var g = doc.currentGradient
            g.stops.append(GradientStop(color: CMYK(c: v[1], m: v[2], y: v[3], k: v[4]), location: v[0]))
            doc.changeGradient(to: g)
        case _ where name.hasPrefix("gradientColor:"):
            // gradientColor:index,c,m,y,k: the stop's color, as the Color Picker's OK.
            let v = name.dropFirst(14).split(separator: ",").compactMap { Double($0) }
            guard v.count == 5 else { break }
            doc.applyPickedColor(CMYK(c: v[1], m: v[2], y: v[3], k: v[4]), to: .gradientStop(Int(v[0])))
        case _ where name.hasPrefix("sides:"):
            if let sides = Int(name.dropFirst(6)) { doc.modifySelection { $0.setPolygon(sides: sides) } }
        case _ where name.hasPrefix("strokeWidth:"):
            // strokeWidth:2 (pt) on the selection, as the control bar's field.
            if let width = Double(name.dropFirst(12)) { doc.setStrokeWidth(width) }
        // Artboards (as the Artboards panel, the Page panel and the Artboard tool's bar do).
        case "artboardNew": doc.newArtboard()
        case "artboardDelete": doc.deleteArtboard(doc.activeArtboardID)
        case "artboardLandscape": doc.setArtboardLandscape(doc.activeArtboardID, true)
        case "artboardPortrait": doc.setArtboardLandscape(doc.activeArtboardID, false)
        case _ where name.hasPrefix("artboardAdd:"):
            // artboardAdd:x,y,w,h (canvas mm), as the Artboard tool's drag.
            let v = name.dropFirst(12).split(separator: ",").compactMap { Double($0) }
            if v.count == 4 { doc.addArtboard(CGRect(x: v[0], y: v[1], width: v[2], height: v[3])) }
        case _ where name.hasPrefix("artboardActivate:"):
            if let n = Int(name.dropFirst(17)), doc.artboards.indices.contains(n - 1) { doc.activate(doc.artboards[n - 1].id) }
        case _ where name.hasPrefix("artboardPreset:"):
            if let preset = PagePreset(rawValue: String(name.dropFirst(15))) { doc.setArtboardPreset(doc.activeArtboardID, preset) }
        case _ where name.hasPrefix("artboardSize:"):
            let v = name.dropFirst(13).split(separator: ",").compactMap { Double($0) }
            if v.count == 2 { doc.setArtboardSize(doc.activeArtboardID, CGSize(width: v[0], height: v[1])) }
        case _ where name.hasPrefix("artboardMoveTo:"):
            // artboardMoveTo:x,y (canvas mm), as dragging it with the Artboard tool (the artwork on it goes along).
            let v = name.dropFirst(15).split(separator: ",").compactMap { Double($0) }
            guard v.count == 2 else { break }
            let a = doc.activeArtboard
            doc.setArtboardRect(a.id, CGRect(origin: CGPoint(x: v[0], y: v[1]), size: a.size), artwork: doc.artworkOn(a.id))
        case _ where name.hasPrefix("artboardRename:"):
            doc.renameArtboard(doc.activeArtboardID, String(name.dropFirst(15)))
        case _ where name.hasPrefix("artboardOrder:"):
            if let offset = Int(name.dropFirst(14)) { doc.moveArtboard(doc.activeArtboardID, by: offset) }
        // Images inside shapes (Editor/ImageInsideShape.swift).
        case "clipMake": NSLog("CUTLINE_TEST clipMake: %@", doc.makeClippingMask() ?? "done")
        case "clipRelease": doc.releaseClippingMask()
        case "pasteInside": NSLog("CUTLINE_TEST pasteInside: %@", doc.pasteInside() ?? "done")
        case _ where name.hasPrefix("copyImage:"):
            // As another app copies an image (Preview, a browser): its PNG (or the file's data) on the test pasteboard.
            guard let area = testArea, let data = try? Data(contentsOf: URL(fileURLWithPath: String(name.dropFirst(10)))) else { break }
            area.clearContents()
            area.setData(data, forType: .png)
        case _ where name.hasPrefix("putFile:"):
            // putFile:/x.png@x,y: the file dropped at x,y mm, as from the Finder (into the shape there).
            let parts = name.dropFirst(8).split(separator: "@")
            let v = parts.count > 1 ? parts[1].split(separator: ",").compactMap { Double($0) } : []
            guard let path = parts.first, v.count == 2 else { break }
            let target = doc.imageTarget(at: CGPoint(x: v[0], y: v[1]))
            NSLog("CUTLINE_TEST putFile: target %@ → %d", target.flatMap { id in doc.objects.first { $0.id == id }?.name } ?? "none",
                  target.map { doc.putImageFile(URL(fileURLWithPath: String(path)), into: $0) ? 1 : 0 } ?? 0)
        case _ where name.hasPrefix("imageFit:"):
            if let mode = ImageFitMode.allCases.first(where: { "\($0)" == name.dropFirst(9) }) { doc.setImageFit(mode) }
        case _ where name.hasPrefix("imageScale:"):
            if let v = Double(name.dropFirst(11)) { doc.setImageScale(v) }
        case _ where name.hasPrefix("imageOpacity:"):
            if let v = Double(name.dropFirst(13)) { doc.setImageOpacity(v) }
        case "editContent":
            if let id = doc.selectedObjects.first(where: \.hasImageInside)?.id { doc.editContent(id) }
        case "contentExit": doc.imageContentEditing = nil
        case _ where name.hasPrefix("contentMove:"):
            let v = name.dropFirst(12).split(separator: ",").compactMap { Double($0) }
            if v.count == 2 { doc.transformContent(CGAffineTransform(translationX: v[0], y: v[1])) }
        case _ where name.hasPrefix("contentScale:") || name.hasPrefix("contentRotate:"):
            // Around the content's center (the middle of its box).
            guard let o = doc.contentObject, let corners = doc.contentCorners(o) else { break }
            let c = CGPoint(x: corners.map(\.x).reduce(0, +) / 4, y: corners.map(\.y).reduce(0, +) / 4)
            if name.hasPrefix("contentScale:"), let f = Double(name.dropFirst(13)) {
                doc.transformContent(CGAffineTransform(translationX: -c.x, y: -c.y).concatenating(CGAffineTransform(scaleX: f, y: f))
                    .concatenating(CGAffineTransform(translationX: c.x, y: c.y)))
            } else if let degrees = Double(name.dropFirst(14)) {
                doc.transformContent(CanvasObject.rotation(degrees, around: c))
            }
        default: NSLog("CUTLINE_TEST do: unknown action %@", name)
        }
    }

    /// The "select:Label" step (select+: adds): the objects with that label (or name).
    static func select(_ step: String, _ doc: Document) {
        let adding = step.hasPrefix("select+:")
        let name = String(step.dropFirst(adding ? 8 : 7))
        let found = Set(doc.objects.filter { $0.label == name || $0.name == name }.map(\.id))
        doc.selection = adding ? doc.selection.union(found) : found
    }

    /// The "log" step of CUTLINE_TEST_KEYS: what a test needs to check, in the log.
    static func logState(_ doc: Document, zoom: Double) {
        let frames = doc.objects.map { o in
            let r = o.frame.standardized
            let turn = o.rotation == 0 ? "" : String(format: "↻%.2f°", o.rotation)
            return String(format: "%@(%.2f,%.2f %.2fx%.2f)%@@%@", o.label ?? o.shape.name, r.minX, r.minY, r.width, r.height, turn,
                          doc.layer(of: o).name)
        }
        if let box = doc.selectionFrame {
            NSLog("CUTLINE_TEST box: (%.2f,%.2f %.2fx%.2f) %.2f° corners %@", box.rect.minX, box.rect.minY, box.rect.width,
                  box.rect.height, box.angle, box.corners.map { String(format: "%.2f,%.2f", $0.x, $0.y) }.joined(separator: " "))
        }
        NSLog("CUTLINE_TEST frames: %@", frames.joined(separator: " "))
        let objects = doc.objects.map { o in "\(o.label ?? "?")[\(o.absoluteNodes.map(\.nodes.count).map(String.init).joined(separator: "+"))]" }
        let text = doc.selectedObjects.lazy.compactMap { o -> CharacterStyle? in if case .text(let t) = o.shape { t.style(in: 0) } else { nil } }.first
        NSLog("CUTLINE_TEST state: text=%@ underline=%d", text?.postscript ?? text?.font ?? "-", text?.underline == true ? 1 : 0)
        NSLog("CUTLINE_TEST state: tool=%@ zoom=%.2f objects=%@ selected=%ld guides v=%@ h=%@ fill=%@ stroke=%@",
              doc.tool.rawValue, zoom, objects.joined(separator: " "), doc.selection.count,
              doc.guides.verticals.map { String(format: "%.1f", $0) }.joined(separator: ","),
              doc.guides.horizontals.map { String(format: "%.1f", $0) }.joined(separator: ","),
              doc.selectedObjects.first?.fill?.summaryText ?? "none", doc.selectedObjects.first?.strokeColor.summaryText ?? "-")
        if let g = doc.selectedObjects.first?.gradient {
            NSLog("CUTLINE_TEST gradient: %@ %.0f° %@", g.kind.rawValue, g.angle,
                  g.stops.map { String(format: "%@@%.2f", $0.color.summaryText, $0.location) }.joined(separator: " "))
        }
        let pictures = doc.objects.filter { $0.image != nil }.map { o -> String in
            let fit = o.imageFit.map { f in
                String(format: " %@ scale %.3f×%.3f angle %.2f° offset %.3f,%.3f opacity %.2f", f.mode.rawValue, f.scaleX, f.scaleY,
                       f.angle, f.offset.x, f.offset.y, f.opacity)
            } ?? " alone"
            let placed = o.imageToPage.map { t in
                String(format: " pixel→page [%.4f %.4f %.4f %.4f %.2f %.2f]", t.a, t.b, t.c, t.d, t.tx, t.ty)
            } ?? ""
            return "\(o.name)<\(o.image!.key.prefix(8))>\(fit)\(placed) cuts=\(o.cutsLine ? 1 : 0)"
        }
        if !pictures.isEmpty { NSLog("CUTLINE_TEST images: %@", pictures.joined(separator: " | ")) }
        if let id = doc.imageContentEditing { NSLog("CUTLINE_TEST editing content of %@", doc.objects.first { $0.id == id }?.name ?? "?") }
        if let notice = doc.notice { NSLog("CUTLINE_TEST notice: %@", notice) }
        NSLog("CUTLINE_TEST artboards: %@ anchor=%.1f,%.1f", doc.artboards.enumerated().map { i, a in
            String(format: "%d:%@(%.1f,%.1f %.1fx%.1f)%@", i + 1, a.title(i), a.rect.minX, a.rect.minY, a.rect.width, a.rect.height,
                   a.id == doc.activeArtboardID ? "*" : "")
        }.joined(separator: " "), doc.anchor.x, doc.anchor.y)
        NSLog("CUTLINE_TEST layers: %@", doc.layers.map { "\($0.name)[\(Int($0.alpha * 100))% \(($0.blend ?? .normal).rawValue)]" }.joined(separator: " "))
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
            "a": (0, "a", "A"), "7": (26, "7", "&"), "8": (28, "8", "*"), "c": (8, "c", "C"), "d": (2, "d", "D"), "g": (5, "g", "G"), "v": (9, "v", "V"), "x": (7, "x", "X"),
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
        if let width = environment["CUTLINE_TEST_BLEED"].flatMap(Double.init) {
            doc.bleed = PrintBleed()
            doc.bleed.enabled = true
            doc.bleed.width = width
        }
        guard let outputPath = environment["CUTLINE_TEST_PRINT"] else { return }
        // CUTLINE_TEST_DELAY=8 prints later (after a sequence of CUTLINE_TEST_KEYS), as with CUTLINE_TEST_SAVE.
        let wait = Double(environment["CUTLINE_TEST_DELAY"] ?? "") ?? 1.5
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            Printing.printDocument(doc, in: nil, pdf: URL(fileURLWithPath: outputPath))
            print("printed to \(outputPath)")
        }
    }

    /// Opens with a few shapes already drawn and a star selected.
    static var demo: Bool { ProcessInfo.processInfo.environment["CUTLINE_DEMO"] != nil }

    static func fillDemo(_ doc: Document) {
        guard demo, doc.objects.isEmpty else { return }
        // CUTLINE_DEMO=3: one of each kind of object, to turn (rotation tests).
        if ProcessInfo.processInfo.environment["CUTLINE_DEMO"] == "3" { return fillRotationDemo(doc) }
        if ProcessInfo.processInfo.environment["CUTLINE_DEMO"] == "4" { return fillImageDemo(doc) }
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

    /// One of each kind: rectangle with a radius and a gradient, ellipse, star, polygon, an open path with curves, text, text
    /// on a path, a group of two and a compound path (a square with a hole). Nothing selected.
    /// CUTLINE_DEMO=4: shapes to put an image in and a test image on its own (see the top of the file).
    static func fillImageDemo(_ doc: Document) {
        var star = doc.newObject(.star(points: 5, innerRadius: 0.45), frame: CGRect(x: 20, y: 25, width: 70, height: 67))
        star.rotation = 30
        star.label = "Star"
        var ellipse = doc.newObject(.ellipse, frame: CGRect(x: 110, y: 30, width: 80, height: 50))
        ellipse.strokeColor = CMYK(c: 100, m: 50, y: 0, k: 0)
        ellipse.label = "Ellipse"
        var rect = doc.newObject(.rectangle(radius: 8), frame: CGRect(x: 20, y: 120, width: 80, height: 50))
        rect.strokeColor = CMYK(c: 70, m: 0, y: 100, k: 0)
        rect.label = "Rect"
        var hexagon = doc.newObject(.shapePath([]), frame: CGRect(x: 120, y: 115, width: 60, height: 60 * PolygonShape.naturalAspect(sides: 6)))
        hexagon.setPolygon(sides: 6)
        hexagon.label = "Hexagon"
        let key = "demo-image"
        var photo = doc.imageObject(CGRect(x: 60, y: 200, width: 60, height: 45), key: key, pixels: CGSize(width: 400, height: 300), name: "Photo")
        photo.label = "Photo"
        doc.images[key] = testImagePNG()
        doc.objects = [star, ellipse, rect, hexagon, photo]
        doc.pinLayers()
        doc.selection = []
    }

    /// A 400 × 300 test image: red, green, blue and yellow quarters (from the top-left corner, clockwise), a black square
    /// at the top-left corner and a white diagonal from there, so its place and turn show in a photo.
    static func testImagePNG() -> Data {
        let w = 400, h = 300
        let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // y up in the bitmap: the top quarters are at y ≥ 150.
        let quarters: [(CGRect, [CGFloat])] = [(CGRect(x: 0, y: 150, width: 200, height: 150), [0.9, 0.15, 0.15]),
                                               (CGRect(x: 200, y: 150, width: 200, height: 150), [0.15, 0.7, 0.25]),
                                               (CGRect(x: 200, y: 0, width: 200, height: 150), [0.95, 0.85, 0.1]),
                                               (CGRect(x: 0, y: 0, width: 200, height: 150), [0.15, 0.3, 0.9])]
        for (r, c) in quarters {
            cg.setFillColor(red: c[0], green: c[1], blue: c[2], alpha: 1)
            cg.fill(r)
        }
        cg.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 1)
        cg.setLineWidth(14)
        cg.move(to: CGPoint(x: 0, y: 300))
        cg.addLine(to: CGPoint(x: 400, y: 0))
        cg.strokePath()
        cg.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        cg.fill(CGRect(x: 0, y: 240, width: 60, height: 60))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cg.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    static func fillRotationDemo(_ doc: Document) {
        var rectangle = doc.newObject(.rectangle(radius: 5), frame: CGRect(x: 20, y: 25, width: 50, height: 30))
        rectangle.fill = CMYK(c: 0, m: 0, y: 100, k: 0)
        rectangle.setGradient(GradientFill(stops: [GradientStop(color: CMYK(c: 0, m: 0, y: 100, k: 0), location: 0),
                                                   GradientStop(color: CMYK(c: 100, m: 0, y: 0, k: 0), location: 1)]))
        let ellipse = doc.newObject(.ellipse, frame: CGRect(x: 85, y: 25, width: 50, height: 28))
        let star = doc.newObject(.star(points: 5, innerRadius: 0.45), frame: CGRect(x: 150, y: 20, width: 40, height: 38))
        var polygon = doc.newObject(.shapePath([]), frame: CGRect(x: 20, y: 75, width: 40, height: 40 * PolygonShape.naturalAspect(sides: 6)))
        polygon.setPolygon(sides: 6)
        var path = doc.newObject(.shapePath([]), frame: .zero)
        path.setNodes([Subpath(nodes: [Node(point: CGPoint(x: 80, y: 100), output: CGPoint(x: 90, y: 75)),
                                       Node(point: CGPoint(x: 110, y: 95), input: CGPoint(x: 100, y: 110), output: CGPoint(x: 120, y: 80)),
                                       Node(point: CGPoint(x: 135, y: 85))], closed: false)])
        path.label = "Path"
        var text = TextBox(content: "Rotate")
        text.style.font = "Helvetica Neue"
        text.style.size = 40
        let words = CanvasObject(shape: .text(text), frame: CGRect(origin: CGPoint(x: 150, y: 80), size: text.naturalSize))
        var arcText = TextBox(content: "on a path")
        arcText.style.font = "Helvetica Neue"
        arcText.style.size = 18
        var onPath = doc.newObject(.text(arcText), frame: CGRect(x: 20, y: 140, width: 70, height: 25))
        onPath.textPath = TextOnPath(subpaths: [Subpath(nodes: [Node(point: CGPoint(x: 0, y: 1), output: CGPoint(x: 0.2, y: -0.3)),
                                                                Node(point: CGPoint(x: 1, y: 1), input: CGPoint(x: 0.8, y: -0.3))], closed: false)])
        let group = UUID()
        var a = doc.newObject(.rectangle(radius: 0), frame: CGRect(x: 110, y: 140, width: 20, height: 20))
        var b = doc.newObject(.ellipse, frame: CGRect(x: 135, y: 145, width: 25, height: 15))
        a.groups = [group]
        b.groups = [group]
        var compound = doc.newObject(.shapePath([]), frame: .zero)
        compound.setNodes([Subpath(nodes: [Node(point: CGPoint(x: 20, y: 190)), Node(point: CGPoint(x: 60, y: 190)),
                                           Node(point: CGPoint(x: 60, y: 230)), Node(point: CGPoint(x: 20, y: 230))]),
                           Subpath(nodes: [Node(point: CGPoint(x: 30, y: 200)), Node(point: CGPoint(x: 50, y: 200)),
                                           Node(point: CGPoint(x: 50, y: 220)), Node(point: CGPoint(x: 30, y: 220))])])
        compound.fill = CMYK(c: 0, m: 60, y: 0, k: 0)
        compound.label = "Compound Path"
        doc.objects = [rectangle, ellipse, star, polygon, path, words, onPath, a, b, compound].map { o in
            var o = o
            o.layer = doc.activeLayer
            return o
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

    // MARK: Google Fonts (GoogleFonts/)

    /// CUTLINE_TEST_GOOGLE_FONTS_DIR=/x: added fonts in /x/Fonts and the cache in /x/Cache instead of the real folders.
    /// A hidden test (CUTLINE_HIDDEN) without it uses a temporary folder: tests never add to, nor remove from, the owner's.
    nonisolated static var googleFontsFolder: URL? {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["CUTLINE_TEST_GOOGLE_FONTS_DIR"] { return URL(fileURLWithPath: path, isDirectory: true) }
        guard environment["CUTLINE_HIDDEN"] != nil else { return nil }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appending(path: "CutlineTestGoogleFonts")
    }

    /// CUTLINE_TEST_GOOGLE_CSS=http://127.0.0.1:9/css2: the CSS API at another address (one that doesn't answer shows the
    /// offline notice).
    nonisolated static var googleFontsCSS: String? { ProcessInfo.processInfo.environment["CUTLINE_TEST_GOOGLE_CSS"] }

    /// CUTLINE_TEST_GOOGLE_SLOW=1: each file of a family waits a second before downloading (to photograph the progress).
    nonisolated static var googleFontsSlow: Bool { ProcessInfo.processInfo.environment["CUTLINE_TEST_GOOGLE_SLOW"] != nil }

    /// At launch: which added families were registered again, and whether CoreText already sees them.
    static func googleFontsActivated(_ added: [String: String]) {
        guard ProcessInfo.processInfo.environment["CUTLINE_HIDDEN"] != nil else { return }
        let seen = Set(CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? [])
        let list = added.keys.sorted().map { "\($0) as \(added[$0]!) (CoreText sees it: \(seen.contains(added[$0]!)))" }
        NSLog("CUTLINE_TEST google activated %d: %@", added.count, list.joined(separator: ", "))
    }

    static func googleFontAdded(_ name: String, as family: String) {
        let faces = (NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []).compactMap { $0.first as? String }
        NSLog("CUTLINE_TEST google added %@ as %@, faces (%d): %@", name, family, faces.count, faces.joined(separator: " "))
    }

    /// CUTLINE_TEST_FONT_LIST=google|installed: the font list (the popover of the Character panel's font button) in a
    /// plain hidden window, "CutlineTestFonts", on that tab; CUTLINE_TEST_FONT_CURRENT=Family is the text's font (by
    /// default the one of the selection). Choosing a family applies it to the demo text (CUTLINE_DEMO=2).
    static func showFontListForTest(_ doc: Document) {
        let environment = ProcessInfo.processInfo.environment
        guard let tab = environment["CUTLINE_TEST_FONT_LIST"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let current = environment["CUTLINE_TEST_FONT_CURRENT"] ?? doc.textStyle.font
            let list = FontList(current: current, start: tab == "google" ? .google : .installed) { family in
                if let text = doc.objects.last(where: { if case .text = $0.shape { true } else { false } }) {
                    doc.selection = [text.id]
                }
                doc.changeStyle { $0.switchFamily(family) }
                NSLog("CUTLINE_TEST google chose %@ (text font now: %@, face %@)", family, doc.textStyle.font, doc.textStyle.postscriptInUse)
            }
            // An opaque background, so the drawing into a file (snap:) shows the dark mode's light letters.
            showPlain(list.background(Color(nsColor: .windowBackgroundColor)), title: "CutlineTestFonts",
                      size: CGSize(width: 320, height: 480), output: nil)
        }
    }

    private static var fontListDriven = false

    /// CUTLINE_TEST_FONT_STEPS (with CUTLINE_TEST_FONT_LIST), one step every 0.6 s: tab:google|installed, search:text,
    /// category:display (a pill: all, sans-serif, serif, display, handwriting, monospace), add:Family, wait:Family (until
    /// it's in or failed, up to 90 s), choose:Family, remove:Family, snap:/x.png (draws the list into the file), log, sleep:s.
    static func driveFontList(source: Binding<FontSource>, search: Binding<String>, category: Binding<GoogleCategory>,
                              choose: (String) -> Void) async {
        guard !fontListDriven, let text = ProcessInfo.processInfo.environment["CUTLINE_TEST_FONT_STEPS"] else { return }
        fontListDriven = true
        let fonts = GoogleFonts.shared
        for step in text.split(separator: ";").map(String.init) {
            try? await Task.sleep(for: .milliseconds(600))
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let value = parts.count > 1 ? parts[1] : ""
            switch parts[0] {
            case "tab": source.wrappedValue = value == "installed" ? .installed : .google
            case "search": search.wrappedValue = value
            case "category": category.wrappedValue = GoogleCategory(rawValue: value) ?? .all
            case "add": if let family = GoogleFonts.family(named: value) { fonts.add(family) }
            case "wait":
                for _ in 0..<900 where fonts.downloading[value] != nil || (fonts.added[value] == nil && !fonts.failed.contains(value)) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                NSLog("CUTLINE_TEST google wait %@: added = %@, failed = %@", value, "\(fonts.added[value] != nil)", "\(fonts.failed.contains(value))")
            case "choose": if let family = GoogleFonts.family(named: value) { choose(fonts.installedName(family)) } else { choose(value) }
            case "remove": fonts.remove(value)
            case "snap":
                guard let nsWindow = NSApp.windows.first(where: { $0.title == "CutlineTestFonts" }), let view = nsWindow.contentView,
                      let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: image)
                try? image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: value))
                NSLog("CUTLINE_TEST google snap %@", value)
            case "sleep": try? await Task.sleep(for: .seconds(Double(value) ?? 1))
            case "log":
                let seen = Set(CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? [])
                NSLog("CUTLINE_TEST google state: added = %@, downloading = %@, failed = %@, unreachable = %@, installed list has: %@",
                      "\(fonts.added.sorted { $0.key < $1.key })", "\(fonts.downloading)", "\(fonts.failed.sorted())", "\(fonts.unreachable)",
                      fonts.added.values.map { "\($0) \(FontCatalog.shared.installedOnes.contains($0)) (CoreText \(seen.contains($0)))" }
                        .joined(separator: ", "))
            default: NSLog("CUTLINE_TEST google: unknown step %@", step)
            }
        }
    }

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
                        ? (item.action.map { "  [" + NSStringFromSelector($0) + "]" } ?? "")
                          + (item.target.map { " → " + String(describing: type(of: $0)) } ?? "") : ""
                    // The Continuity Camera item (Editor/DeviceImport.swift): AppKit names and fills it.
                    let device = item.identifier == NSMenuItem.importFromDeviceIdentifier ? "  {import from device}" : ""
                    let line = indentation + mark + item.title + shortcut + (item.isEnabled ? "" : "  (desabilitado)") + device + action
                    return [line] + (item.submenu.map { lines($0, level: level + 1) } ?? [])
                }
            }
            let text = NSApp.mainMenu.map { lines($0, level: 0) }?.joined(separator: "\n") ?? ""
            try? text.write(toFile: outputPath, atomically: true, encoding: .utf8)
        }
    }

    static func scheduleSnapshot() {
        guard let outputPath = ProcessInfo.processInfo.environment["CUTLINE_SNAPSHOT"] else { return }
        // CUTLINE_SNAPSHOT_DELAY=6: later than the usual 2.5 s (for what is drawn a moment after, like the print bleed).
        let delay = Double(ProcessInfo.processInfo.environment["CUTLINE_SNAPSHOT_DELAY"] ?? "") ?? 2.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let nsWindow = NSApp.windows.first(where: { $0.isVisible }),
                  let frame = nsWindow.contentView?.superview,
                  let image = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
            frame.cacheDisplay(in: frame.bounds, to: image)
            try? image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: outputPath))
        }
    }

    // MARK: Open from Canva… (Canva/)

    /// CUTLINE_CANVA_SERVER=http://127.0.0.1:8791/canva/: the backend of the tests (_site/canva/dev/serve.sh, with the
    /// fake Canva); it turns the menu item on, and plain http is allowed.
    nonisolated static var canvaServer: URL? {
        ProcessInfo.processInfo.environment["CUTLINE_CANVA_SERVER"].flatMap { URL(string: $0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    /// With the test backend, the session goes to a file (CUTLINE_TEST_CANVA_SESSION=/x.txt, or one in the temporary
    /// folder), never to the Keychain: a debug build changes on every compile, and the Keychain would ask for the Mac's
    /// password on screen to read what an earlier build saved.
    nonisolated static var canvaSessionFile: URL? {
        guard canvaServer != nil else { return nil }
        let path = ProcessInfo.processInfo.environment["CUTLINE_TEST_CANVA_SESSION"]
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("cutline-canva-test-session.txt")
        return URL(fileURLWithPath: path)
    }

    /// CUTLINE_TEST_CANVA=1 opens the Open from Canva… window once, when the first document window shows.
    static func openCanvaOnce() -> Bool {
        guard ProcessInfo.processInfo.environment["CUTLINE_TEST_CANVA"] != nil, !canvaOpened else { return false }
        canvaOpened = true
        return true
    }

    private static var canvaOpened = false

    /// CUTLINE_TEST_CANVA_STEPS=signin;search:tags;sort:title_ascending;more;pick:Gift tags;page:3;open;… drives the
    /// window, one step after the other (each waits for what it started): signin (without a browser: `followRedirects`),
    /// search:text, sort:modified_ascending (a CanvaSort value), more (Load More), refresh, pick:title (a design of the
    /// list; one with pages opens the page question), page:n, open (the question's Open Page), cancel (the export),
    /// signout, wait:seconds and log (NSLog "CUTLINE_TEST canva …").
    static func driveCanva(_ model: CanvaBrowser) async {
        guard let steps = ProcessInfo.processInfo.environment["CUTLINE_TEST_CANVA_STEPS"] else { return }
        func until(_ done: @escaping () -> Bool) async {
            for _ in 0..<150 where !done() { try? await Task.sleep(for: .milliseconds(100)) }
        }
        try? await Task.sleep(for: .milliseconds(600))
        for step in steps.split(separator: ";").map(String.init) {
            let name = step.split(separator: ":", maxSplits: 1).first.map(String.init) ?? step
            let value = step.contains(":") ? String(step[step.index(after: step.firstIndex(of: ":")!)...]) : ""
            switch name {
            case "signin":
                model.signIn(followRedirects)
                try? await Task.sleep(for: .milliseconds(200))
                await until { !model.signingIn && !model.listing }
            case "search":
                model.query = value
                try? await Task.sleep(for: .milliseconds(700))
                await until { !model.listing }
            case "sort":
                if let sort = CanvaSort(rawValue: value) { model.sort = sort }
                try? await Task.sleep(for: .milliseconds(300))
                await until { !model.listing }
            case "more":
                model.loadMore()
                await until { !model.loadingMore }
            case "refresh":
                model.reload()
                await until { !model.listing }
            case "pick":
                if let design = model.designs.first(where: { $0.title == value }) { model.choose(design) }
                else { NSLog("CUTLINE_TEST canva no design %@", value) }
            case "page":
                model.pickerPage = Int(value) ?? 1
            case "open":
                if let design = model.pagePicker { model.open(design, page: model.pickerPage) }
            case "cancel":
                model.cancelExport()
            case "signout":
                model.signOut()
                await until { model.phase == .signedOut }
            case "wait":
                try? await Task.sleep(for: .seconds(Double(value) ?? 1))
            case "log":
                logCanva(model)
            default:
                NSLog("CUTLINE_TEST canva unknown step %@", step)
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    static func logCanva(_ model: CanvaBrowser) {
        let phase = switch model.phase { case .starting: "starting"; case .signedOut: "signedOut"; case .browsing: "browsing" }
        let export = model.export.map { e in "\(e.design.title) page \(e.page.map(String.init) ?? "-") \(e.step)" } ?? "-"
        NSLog("CUTLINE_TEST canva phase=%@ designs=%ld more=%@ query=%@ sort=%@ error=%@ export=%@ picker=%@ titles=%@",
              phase, model.designs.count, model.continuation ?? "-", model.query, model.sort.rawValue,
              model.error.map { "\($0)" } ?? "-", export, model.pagePicker?.title ?? "-",
              model.designs.prefix(6).map(\.title).joined(separator: "|"))
    }

    /// Signing in without a browser, for the hidden tests: follows the redirects of the consent address (the fake Canva
    /// approves at once) up to the cutline:// address the backend sends the browser to.
    static func followRedirects(_ start: URL) async throws -> URL {
        var url = start
        for _ in 0..<6 {
            let (_, response) = try await URLSession.shared.data(for: URLRequest(url: url), delegate: RedirectStopper())
            guard let http = response as? HTTPURLResponse, (300..<400).contains(http.statusCode),
                  let location = http.value(forHTTPHeaderField: "Location"),
                  let next = URL(string: location, relativeTo: url)?.absoluteURL else { throw CanvaError.signInFailed }
            if next.scheme == CanvaConfig.callbackScheme { return next }
            url = next
        }
        throw CanvaError.signInFailed
    }

    /// The document Open from Canva… made: logged (NSLog "CUTLINE_TEST canva document …") and, with
    /// CUTLINE_TEST_CANVA_SAVE=/x.cutline, saved there 2 s later (after the many-paths question, if any).
    /// A page opened in a new document (`from`: "canva" or "illustrator"): logs it and saves it to CUTLINE_TEST_CANVA_SAVE
    /// or CUTLINE_TEST_ILLUSTRATOR_SAVE.
    static func pageOpened(_ doc: Document, document: NSDocument, from source: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let a = doc.artboards[0].rect
            NSLog("CUTLINE_TEST %@ document name=%@ objects=%ld artboard=%.1fx%.1f notice=%@", source, document.displayName,
                  doc.objects.count, a.width, a.height, doc.notice ?? "-")
            guard let path = ProcessInfo.processInfo.environment["CUTLINE_TEST_\(source.uppercased())_SAVE"] else { return }
            document.save(to: URL(fileURLWithPath: path), ofType: "io.github.joaogmcorrea.cutline.documento", for: .saveToOperation) { error in
                NSLog("CUTLINE_TEST %@ %@", source, error.map { "save failed: \($0.localizedDescription)" } ?? "saved to \(path)")
            }
        }
    }

    // MARK: Illustrator's script (Illustrator/)

    /// CUTLINE_TEST_INSTALL_SCRIPT=/a/Scripts:/b/Scripts runs Help › Install Illustrator Script… into those folders
    /// instead of Illustrator's (the alert goes to the log); =list logs the Illustrators found and installs nothing.
    static var installFolders: [URL]? {
        guard let value = ProcessInfo.processInfo.environment["CUTLINE_TEST_INSTALL_SCRIPT"], value != "list" else { return nil }
        return value.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
    }

    static func installScriptForTest() {
        guard let value = ProcessInfo.processInfo.environment["CUTLINE_TEST_INSTALL_SCRIPT"], !installRan else { return }
        installRan = true
        if value == "list" {
            for target in IllustratorScript.targets() {
                NSLog("CUTLINE_TEST illustrator found %@: %@", target.name, target.folders.map(\.path).joined(separator: ", "))
            }
            NSLog("CUTLINE_TEST illustrator bundled=%@ running=%@", IllustratorScript.bundled?.path ?? "missing",
                  IllustratorScript.illustratorRunning ? "yes" : "no")
            return
        }
        IllustratorScript.install()
    }
    private static var installRan = false
}

/// Doesn't follow redirects: `followRedirects` reads each Location itself.
private final class RedirectStopper: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
#endif
