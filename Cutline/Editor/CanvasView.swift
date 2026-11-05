// Drawing canvas: cutting mat + A4 page, objects, guides and rulers; selection tools, direct
// selection (points and handles), pen, text and shapes; snap; zoom and pan. Clicking an object in a group
// selects the group; right-click opens the context menu (Editor/ContextMenu.swift).
import AppKit
import SwiftUI

/// The selection's resize handles (clockwise from the top-left corner).
enum Handle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    func point(in r: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: r.minX, y: r.minY)
        case .top: CGPoint(x: r.midX, y: r.minY)
        case .topRight: CGPoint(x: r.maxX, y: r.minY)
        case .right: CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
        case .left: CGPoint(x: r.minX, y: r.midY)
        }
    }

    var isCorner: Bool { [.topLeft, .topRight, .bottomRight, .bottomLeft].contains(self) }
    var movesLeft: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
    var movesRight: Bool { [.topRight, .right, .bottomRight].contains(self) }
    var movesTop: Bool { [.topLeft, .top, .topRight].contains(self) }
    var movesBottom: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }
}

/// A node of an object (direct selection).
struct NodeRef: Equatable {
    let object: CanvasObject.ID
    let sub: Int
    let node: Int
}

enum NodePart { case point, input, output }

/// Path being drawn with the pen (nodes in page mm).
struct Pen {
    var object: CanvasObject.ID?
    var nodes: [Node]
}

struct CanvasView: View {
    @Bindable var doc: Document
    @Binding var viewState: ViewState
    /// Where the rulers are (nil = hidden), in points of this canvas.
    let rulers: RulerGeometry?

    @State private var gesture: CanvasGesture?
    @State private var pointer = Pointer()
    @State private var tracing = Tracing()
    /// The print bleed's bands, drawn under the art (Model/PrintBleed.swift).
    @State private var bleedPreview = BleedPreview()
    @State private var scrollMonitor: Any?
    @State private var keyboardMonitor: Any?
    @State private var rightClickMonitor: Any?
    /// This canvas's window: shortcuts only work in it (and not with a sheet open).
    @State private var nsWindow: NSWindow?
    @State private var zoomAtPinchStart: Double?
    @State private var space = false
    @State private var pen: Pen?
    @State private var selectedNode: NodeRef?
    @State private var snapMark: CGPoint?
    @State private var draggedGuide: (axis: Axis, value: Double?)?
    /// Cursor and selection of the text being typed on the canvas (Editor/CanvasTextField.swift).
    @State private var textCursor = TextCursor()
    @AppStorage("snap") private var snapOn = true
    @AppStorage(Preferences.guideColor) private var guideColor = Preferences.defaultGuideColor
    @AppStorage(Preferences.guidesVisible) private var guidesVisible = true
    @AppStorage(Preferences.guidesLocked) private var guidesLocked = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var canvasScale

    private enum CanvasGesture {
        case creating(start: CGPoint, current: CGPoint)                                                          // mm
        case moving(start: CGPoint, originals: [CanvasObject.ID: CGRect], pointsList: [CGPoint], registered: Bool)     // mm
        case resizing(handle: Handle, originals: [CanvasObject.ID: CGRect], box: CGRect, registered: Bool)      // mm
        case selectingArea(start: CGPoint, current: CGPoint, sum: Bool)                                    // mm
        case pan(start: CGPoint, origin: CGPoint)                                                      // canvas
        case guide(axis: Axis)
        case node(NodeRef, part: NodePart, original: [Subpath], start: CGPoint, registered: Bool)
        case pen(index: Int, start: CGPoint)
        case zoomArea(start: CGPoint, current: CGPoint)                                                 // canvas
    }

    private var dark: Bool { scheme == .dark }
    /// The print bleed's outer edge on screen.
    private static let bleedGuide = Color(red: 0.93, green: 0.11, blue: 0.14)
    private var backgroundColor: Color { dark ? Color(white: 0.1) : Color(red: 0.89, green: 0.89, blue: 0.9) }
    private var baseColor: Color { dark ? Color(red: 0.17, green: 0.18, blue: 0.17) : Color(red: 0.8, green: 0.82, blue: 0.8) }

    var body: some View {
        Canvas { ctx, size in
            // Font installed or removed while the app is open: texts redraw with the current fonts.
            _ = FontCatalog.shared.version
            render(&ctx, size: size)
        }
            .background(backgroundColor)
            .onGeometryChange(for: CGSize.self, of: \.size) { tracing.size = $0 }
            .contentShape(Rectangle())
            .gesture(drag)
            .simultaneousGesture(pinch)
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    tracing.pointer = p
                    pointer.canvas = p
                    pointer.mm = viewState.mm(p)
                case .ended:
                    tracing.pointer = nil
                    pointer.canvas = nil
                    pointer.mm = nil
                }
            }
            .pointerStyle(pointerStyle)
            .overlay { textEdit }
            .overlay { if doc.tool == .eyedropper { EyedropperLoupe(doc: doc, viewState: viewState, pointer: pointer) } }
            .pointerVisibility(doc.tool == .eyedropper && pointer.canvas != nil ? .hidden : .automatic)
            .overlay {
                if let rulers {
                    Rulers(geometry: rulers, viewState: viewState, pointer: pointer, hasGuides: !doc.guides.emptyOnes)
                }
            }
            .background(WindowReader { newOne in
                nsWindow = newOne
                if let newOne { EditResponder.install(in: newOne, doc: doc) }
            })
            .onAppear {
                scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in scroll(event) }
                // Keys read in the window, without depending on SwiftUI focus (which a control bar field
                // can take): they only stay with the field while typing in it.
                keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in keyboard(event) }
                rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
                    rightClick(event)
                }
            }
            .onDisappear {
                if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
                if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
                if let rightClickMonitor { NSEvent.removeMonitor(rightClickMonitor) }
            }
            .onChange(of: doc.tool) { _, newOne in
                if newOne != .pen { finishPen() }
                if !newOne.editsNodes { selectedNode = nil }
                if newOne != .text { doc.finishText() }
            }
            // Selecting something else (layers, Select › None…) ends typing.
            .onChange(of: doc.selection) { _, newOne in
                if let edit = doc.textEditing, newOne != [edit.id] { doc.finishText() }
            }
            #if DEBUG
            .task {
                await dragHandleForTest()
                await keysForTest()
            }
            #endif
    }

    #if DEBUG
    /// CUTLINE_TEST_HANDLE=1 (DebugHooks.swift): dragging the handle, through the same steps as the mouse.
    private func dragHandleForTest() async {
        guard DebugHooks.dragHandle else { return }
        for _ in 0..<100 where doc.selection.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .milliseconds(500))
        guard let box = selectionBox else { return }
        let start = Handle.bottomRight.point(in: box), end = CGPoint(x: start.x + 30 * viewState.scale, y: start.y + 10 * viewState.scale)
        begin(in: start)
        try? await Task.sleep(for: .milliseconds(100))
        proceed(in: end)
        try? await Task.sleep(for: .milliseconds(100))
        finish(in: end)
        started = false
    }

    /// CUTLINE_TEST_KEYS (DebugHooks.swift): keys through the canvas keyboard and clicks through the mouse steps;
    /// at the end, CUTLINE_TEST_CONTEXT_MENU dumps the right-click menu.
    private func keysForTest() async {
        let keyPresses = DebugHooks.testKeys
        guard !keyPresses.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(1200))
        for text in keyPresses {
            if text.hasPrefix("offset:"), let distance = Double(text.dropFirst(7)) {
                if let notice = doc.offsetSelection(distance, corner: .round) { NSLog("CUTLINE_TEST offset: %@", notice) }
            } else if text.hasPrefix("hover:") {
                let mm = text.dropFirst(6).split(separator: ",").compactMap { Double($0) }
                guard mm.count == 2 else { continue }
                pointer.canvas = viewState.canvas(CGPoint(x: mm[0], y: mm[1]))
                pointer.mm = CGPoint(x: mm[0], y: mm[1])
            } else if text == "log" {
                DebugHooks.logState(doc, zoom: viewState.zoom)
            } else if text.hasPrefix("click:") {
                let mm = text.dropFirst(6).split(separator: ",").compactMap { Double($0) }
                guard mm.count == 2 else { continue }
                let p = viewState.canvas(CGPoint(x: mm[0], y: mm[1]))
                begin(in: p)
                finish(in: p)
                started = false
            } else if let nsWindow, let event = DebugHooks.keyEvent(text, nsWindow: nsWindow) {
                _ = keyboard(event)
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        DebugHooks.dumpContextMenu(doc)
        // ⌘S through the window's responder chain (like the File › Save menu).
        if let response = DebugHooks.saveStudio, let nsWindow {
            _ = nsWindow.tryToPerform(#selector(EditResponder.saveDocument(_:)), with: nil)
            if response == "write2" {
                try? await Task.sleep(for: .seconds(4))
                doc.moveSelection(dx: 0, dy: 5)
                _ = nsWindow.tryToPerform(#selector(EditResponder.saveDocument(_:)), with: nil)
            }
        }
    }
    #endif

    /// Text being typed: the invisible field over the letters and, on top, the cursor and the selection.
    @ViewBuilder private var textEdit: some View {
        if let edit = doc.textEditing, let object = doc.objectBeingEdited, case .text(let text) = object.shape,
           let anchor = doc.editAnchor {
            let geometry = EditGeometry(edit: edit, text: text, viewState: viewState, origin: anchor.origin, scale: anchor.scale)
            let frame = geometry.fieldFrame
            ZStack {
                CanvasTextField(doc: doc, geometry: geometry, cursor: textCursor)
                    .id(edit.session)
                    .frame(width: max(frame.width, 1), height: max(frame.height, 1))
                    .position(x: frame.midX, y: frame.midY)
                EditMarks(geometry: geometry, cursor: textCursor)
            }
        }
    }

    private var pointerStyle: PointerStyle? {
        if space || doc.tool == .hand {
            if case .pan = gesture { return .grabActive }
            return .grabIdle
        }
        switch doc.tool {
        case .text: return .horizontalText
        case .pen, .addNode, .deleteNode: return ToolPointer.style(doc.tool)
        case .eyedropper: return nil   // the loupe takes the pointer's place
        case .zoom: return option ? .zoomOut : .zoomIn
        default: return doc.tool.createsShape ? .rectSelection : nil
        }
    }

    /// Snap and click tolerance in points: 8 canvas points, in mm.
    private var tolerance: Double { 8 / viewState.scale }

    // MARK: Drawing

    private func render(_ ctx: inout GraphicsContext, size: CGSize) {
        let page = CGRect(origin: .zero, size: Document.page)
        let base = page.insetBy(dx: -Document.matMargin, dy: -Document.matMargin)
        ctx.fill(Path(roundedRect: viewState.canvas(base), cornerRadius: 3 * viewState.scale), with: .color(baseColor))
        var withShadow = ctx
        withShadow.addFilter(.shadow(color: .black.opacity(0.16), radius: 8, y: 3))
        withShadow.fill(Path(viewState.canvas(page)), with: .color(.white))   // the sheet is white in dark mode too
        // Print bleed: the bands under the art, as they print.
        let bleedPieces = doc.marks && doc.bleed.enabled ? bleedPreview.pieces(for: doc) : []
        if !bleedPieces.isEmpty {
            ctx.withCGContext { cg in
                cg.concatenate(viewState.transform)
                PrintBleed.draw(bleedPieces, in: cg)
            }
        }

        for object in doc.objectsInOrder where doc.visible(object) {
            paintPath(object, in: &ctx)
            if object.cutsLine || object.strokeWidth > 0 { trace(object, in: &ctx) }
        }
        // …and how far they go: a thin red line, like Illustrator's bleed guide (only on screen).
        for piece in bleedPieces {
            ctx.stroke(Path(piece.guide).applying(viewState.transform), with: .color(Self.bleedGuide), lineWidth: 1)
        }
        if doc.marks { drawMarks(&ctx, size: size) }

        if case .creating(let start, let current) = gesture {
            let preview = doc.newObject(newShape, frame: creationRect(start, current))
            paintPath(preview, in: &ctx)
            trace(preview, in: &ctx)
        }

        drawGuides(&ctx, size: size)

        // Selection: highlighted outline, box and handles (of one object or of several together, like the image and the
        // freshly traced contour; in direct selection, the nodes). The text being typed shows as it is (real color and
        // stroke), only with the cursor.
        let selectedObjects = doc.textEditing == nil ? doc.selectedObjects : []
        for object in selectedObjects {
            ctx.stroke(object.shapePath.applying(viewState.transform), with: .color(.accentColor), lineWidth: 1.5)
        }
        if doc.tool.editsNodes {
            drawNodes(selectedObjects, in: &ctx)
        } else if doc.textEditing == nil, let box = selectionBox {
            ctx.stroke(Path(box), with: .color(.accentColor.opacity(0.7)), lineWidth: 1)
            for handle in Handle.allCases {
                let p = handle.point(in: box)
                let square = Path(CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7))
                ctx.fill(square, with: .color(.white))
                ctx.stroke(square, with: .color(.accentColor), lineWidth: 1)
            }
        }

        if let pen { drawPen(pen, in: &ctx) }

        if case .selectingArea(let start, let current, _) = gesture {
            let area = Path(viewState.canvas(CGRect.between(start, current, proportional: false, fromCenter: false)))
            ctx.fill(area, with: .color(.accentColor.opacity(0.08)))
            ctx.stroke(area, with: .color(.accentColor.opacity(0.6)), lineWidth: 1)
        }

        if case .zoomArea(let start, let current) = gesture {
            let area = Path(CGRect.between(start, current, proportional: false, fromCenter: false))
            ctx.stroke(area, with: .color(.primary.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }

        if let snapMark {
            let p = viewState.canvas(snapMark)
            let mark = Path(CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
            ctx.stroke(mark, with: .color(.accentColor), lineWidth: 1.5)
        }
    }

    /// Fill and image (the image is clipped by the outline; even-odd rule, as in Studio).
    private func paintPath(_ object: CanvasObject, in ctx: inout GraphicsContext) {
        guard object.fill != nil || object.image != nil else { return }
        let shapePath = object.shapePath.applying(viewState.transform)
        let rule = FillStyle(eoFill: true)
        if let color = object.fill { ctx.fill(shapePath, with: .color(color.color), style: rule) }
        if let image = object.image, let cg = doc.image(image.key) {
            var clipping = ctx
            clipping.clip(to: shapePath, style: rule)
            clipping.concatenate(image.transform.cg.concatenating(object.frameToPage).concatenating(viewState.transform))
            clipping.draw(Image(decorative: cg, scale: 1), in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
    }

    /// 0 pt: a one-pixel hairline on screen (as thin as possible; doesn't print); above that, real width at the
    /// current zoom — never thinner than the hairline —, with cap, join and alignment. The dashes (in mm)
    /// follow the zoom in both cases.
    private func trace(_ object: CanvasObject, in ctx: inout GraphicsContext) {
        let shapePath = object.shapePath.applying(viewState.transform)
        let color = GraphicsContext.Shading.color(object.strokeColor.color)
        let dashed = object.style.line.defaultValue?.map { CGFloat($0 * viewState.scale) } ?? []
        let hairline = 1 / max(canvasScale, 1)
        guard object.strokeWidth > 0 else {
            ctx.stroke(shapePath, with: color, style: StrokeStyle(lineWidth: hairline, lineJoin: .round, dash: dashed))
            return
        }
        let e = object.style
        var style = StrokeStyle(lineWidth: max(object.strokeWidth * viewState.zoom, hairline), lineCap: e.cap.cg, lineJoin: e.join.cg,
                                 miterLimit: e.miterLimit, dash: dashed)
        switch e.alignment {
        case .center:
            ctx.stroke(shapePath, with: color, style: style)
        case .inside, .outside:
            // Inside/outside: twice the width, clipped by the outline itself (or by its outside).
            var clipping = ctx
            clipping.clip(to: shapePath, style: FillStyle(eoFill: true), options: e.alignment == .outside ? .inverse : [])
            style.lineWidth *= 2
            clipping.stroke(shapePath, with: color, style: style)
        }
    }

    /// Print & Cut: the marks as they print and, hatched, where not to put art or cuts (outside the
    /// area between the marks and around them).
    private func drawMarks(_ ctx: inout GraphicsContext, size: CGSize) {
        var forbidden = ctx
        forbidden.clip(to: doc.marksConfig.forbiddenZone.applying(viewState.transform), style: FillStyle(eoFill: true))
        let box = viewState.canvas(CGRect(origin: .zero, size: Document.page)).intersection(CGRect(origin: .zero, size: size))
        if !box.isNull {
            var hatch = Path()
            var x = box.minX - box.height
            while x < box.maxX {
                hatch.move(to: CGPoint(x: x, y: box.maxY))
                hatch.addLine(to: CGPoint(x: x + box.height, y: box.minY))
                x += 7
            }
            forbidden.stroke(hatch, with: .color(.gray.opacity(0.45)), lineWidth: 0.7)
        }
        for rectangle in doc.marksConfig.rectangles { ctx.fill(Path(viewState.canvas(rectangle)), with: .color(.black)) }
    }

    private func drawGuides(_ ctx: inout GraphicsContext, size: CGSize) {
        var lines = Path()
        var verticals = guidesVisible ? doc.guides.verticals : [], horizontals = guidesVisible ? doc.guides.horizontals : []
        if let dragged = draggedGuide, let value = dragged.value {
            if dragged.axis == .vertical { verticals.append(value) } else { horizontals.append(value) }
        }
        for x in verticals {
            let px = viewState.canvas(CGPoint(x: x, y: 0)).x.rounded() + 0.5
            lines.move(to: CGPoint(x: px, y: 0))
            lines.addLine(to: CGPoint(x: px, y: size.height))
        }
        for y in horizontals {
            let py = viewState.canvas(CGPoint(x: 0, y: y)).y.rounded() + 0.5
            lines.move(to: CGPoint(x: 0, y: py))
            lines.addLine(to: CGPoint(x: size.width, y: py))
        }
        ctx.stroke(lines, with: .color(Color(hex: guideColor).opacity(0.85)), lineWidth: 0.75)
    }

    /// Nodes of the selected objects; the chosen node highlighted, with its handles.
    private func drawNodes(_ objects: [CanvasObject], in ctx: inout GraphicsContext) {
        for object in objects {
            let subs = object.absoluteNodes
            for (s, sub) in subs.enumerated() {
                for (n, node) in sub.nodes.enumerated() {
                    let ref = NodeRef(object: object.id, sub: s, node: n)
                    let p = viewState.canvas(node.point)
                    let square = Path(CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
                    if ref == selectedNode {
                        for handle in [node.input, node.output].compactMap(\.self) {
                            let q = viewState.canvas(handle)
                            ctx.stroke(Path { $0.move(to: p); $0.addLine(to: q) }, with: .color(.accentColor), lineWidth: 1)
                            let dot = Path(ellipseIn: CGRect(x: q.x - 3, y: q.y - 3, width: 6, height: 6))
                            ctx.fill(dot, with: .color(.accentColor))
                        }
                        ctx.fill(square, with: .color(.accentColor))
                    } else {
                        ctx.fill(square, with: .color(.white))
                        ctx.stroke(square, with: .color(.accentColor), lineWidth: 1)
                    }
                }
            }
        }
    }

    /// Pen path: nodes, the last one's handles and the line to the pointer.
    private func drawPen(_ pen: Pen, in ctx: inout GraphicsContext) {
        guard let lastOne = pen.nodes.last else { return }
        if pen.object == nil, pen.nodes.count == 1 {
            let p = viewState.canvas(lastOne.point)
            ctx.fill(Path(CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.accentColor))
        }
        if gesture == nil, let mm = pointer.mm {
            var rubberBand = Path()
            rubberBand.move(to: viewState.canvas(lastOne.point))
            if let output = lastOne.output {
                rubberBand.addQuadCurve(to: viewState.canvas(mm), control: viewState.canvas(output))
            } else {
                rubberBand.addLine(to: viewState.canvas(mm))
            }
            ctx.stroke(rubberBand, with: .color(.accentColor.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            if let first = pen.nodes.first, pen.nodes.count >= 2,
               hypot(first.point.x - mm.x, first.point.y - mm.y) < tolerance {
                let p = viewState.canvas(first.point)
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(.accentColor), lineWidth: 1.5)
            }
        }
        for handle in [lastOne.input, lastOne.output].compactMap(\.self) {
            let p = viewState.canvas(lastOne.point), q = viewState.canvas(handle)
            ctx.stroke(Path { $0.move(to: p); $0.addLine(to: q) }, with: .color(.accentColor), lineWidth: 1)
            ctx.fill(Path(ellipseIn: CGRect(x: q.x - 3, y: q.y - 3, width: 6, height: 6)), with: .color(.accentColor))
        }
    }

    /// Selection box, in canvas points.
    private var selectionBox: CGRect? {
        let frames = doc.selectedObjects.map { $0.shapePath.boundingRect }
        guard let first = frames.first else { return nil }
        return viewState.canvas(frames.dropFirst().reduce(first) { $0.union($1) })
    }

    // MARK: Gestures

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if gesture == nil, !started { begin(in: value.startLocation) }
                proceed(in: value.location)
            }
            .onEnded { value in
                finish(in: value.location)
                started = false
            }
    }

    /// Some clicks (ruler, text, pen) don't start a `gesture`; this avoids restarting on every move.
    @State private var started = false

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let initial = zoomAtPinchStart ?? viewState.zoom
                zoomAtPinchStart = initial
                viewState.zoomIn(to: initial * value.magnification, anchor: value.startLocation)
            }
            .onEnded { _ in zoomAtPinchStart = nil }
    }

    private var modifiers: NSEvent.ModifierFlags {
        #if DEBUG
        if let test = DebugHooks.testModifiers { return test }
        #endif
        return NSEvent.modifierFlags
    }
    private var shift: Bool { modifiers.contains(.shift) }
    private var option: Bool { modifiers.contains(.option) }
    /// Only a mouse event has a click count (asking another one crashes the app).
    private var clicks: Int {
        guard let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp, .leftMouseDragged].contains(event.type) else { return 1 }
        return event.clickCount
    }

    private var newShape: ShapeKind {
        switch doc.tool {
        case .ellipse: .ellipse
        case .star: .star(points: 5, innerRadius: 0.5)
        default: .rectangle(radius: 0)
        }
    }

    private func creationRect(_ start: CGPoint, _ current: CGPoint) -> CGRect {
        CGRect.between(start, current, proportional: shift, fromCenter: option)
    }

    /// Snap targets of the gesture in progress (computed at the start).
    private func snapping(_ p: CGPoint) -> CGPoint {
        guard snapOn, let targets = tracing.targets else { snapMark = nil; return p }
        let (q, mark) = targets.snap(p, tolerance: tolerance)
        snapMark = mark
        return q
    }

    private func prepareSnap(exclude: Set<CanvasObject.ID>) {
        tracing.targets = snapOn ? SnapTargets(doc: doc, exclude: exclude, guides: guidesVisible) : nil
    }

    private func begin(in canvasPoint: CGPoint) {
        started = true
        // Clicking the canvas ends editing a field (and gives the keyboard back to the canvas) and typing a text
        // (a click inside the text being edited goes straight to the invisible field, it doesn't get here).
        if nsWindow?.firstResponder is NSText { nsWindow?.makeFirstResponder(nil) }
        doc.finishText()
        let p = viewState.mm(canvasPoint)
        if space || doc.tool == .hand {
            gesture = .pan(start: canvasPoint, origin: viewState.origin)
            return
        }
        if let rulers, beginOnRuler(canvasPoint, rulers) { return }
        switch doc.tool {
        case .pen:
            prepareSnap(exclude: Set([pen?.object].compactMap(\.self)))
            clickPen(snapping(p))
        case .text:
            // On a text: the cursor goes where the click was; elsewhere: new text with its baseline at the click.
            if let target = objectAt(canvasPoint), let object = doc.objects.first(where: { $0.id == target }), case .text = object.shape {
                doc.editText(target, click: p)
            } else {
                doc.newText(in: p)
            }
        case .direct:
            beginDirect(canvasPoint, p)
        case .addNode:
            // On the outline of a selected object first, then of the one under the click (which becomes selected).
            for id in doc.selectedObjects.reversed().map(\.id) + [objectAt(canvasPoint)].compactMap(\.self)
            where doc.addNode(to: id, at: p, tolerance: tolerance) {
                doc.selection = [id]
                selectedNode = nil
                return
            }
            if let target = objectAt(canvasPoint) { doc.selection = [target] }
        case .deleteNode:
            selectedNode = nil
            if let ref = nodeAt(canvasPoint) {
                doc.deleteNode(of: ref.object, sub: ref.sub, node: ref.node)
            } else {
                doc.selection = objectAt(canvasPoint).map { [$0] } ?? []
            }
        case .eyedropper:
            if let target = objectAt(canvasPoint) { doc.eyedrop(from: target, at: p) }
        case .zoom:
            gesture = .zoomArea(start: canvasPoint, current: canvasPoint)
        case _ where doc.tool.createsShape:
            prepareSnap(exclude: [])
            let q = snapping(p)
            gesture = .creating(start: q, current: q)
        default:
            beginSelection(canvasPoint, p)
        }
    }

    private func beginSelection(_ canvasPoint: CGPoint, _ p: CGPoint) {
        if let handle = handleAt(canvasPoint), let box = doc.selectionBox {
            prepareSnap(exclude: doc.selection)
            gesture = .resizing(handle: handle, originals: Dictionary(uniqueKeysWithValues: doc.selectedObjects.map { ($0.id, $0.frame.standardized) }),
                                     box: box, registered: false)
        } else if let target = objectAt(canvasPoint) {
            if clicks >= 2, let object = doc.objects.first(where: { $0.id == target }) {
                // Double click: a text opens typing on the canvas (cursor at the click); a path, direct selection.
                if case .text = object.shape {
                    doc.tool = .text
                    doc.editText(target, click: p)
                } else {
                    doc.selection = [target]
                    doc.tool = .direct
                }
                return
            }
            // In a group, the whole outermost group.
            let unit = doc.unit(of: target)
            if shift {
                if doc.selection.contains(target) { doc.selection.subtract(unit) } else { doc.selection.formUnion(unit) }
            } else if !doc.selection.contains(target) {
                doc.selection = unit
            }
            if let object = doc.objects.first(where: { $0.id == target }) { doc.activeLayer = doc.layer(of: object).id }
            beginMove(p)
        } else if let (axis, index) = guideAt(canvasPoint) {
            // Existing guide: removed from the document while dragging; drop it on the ruler to delete it.
            doc.registrar()
            let value: Double
            switch axis {
            case .vertical: value = doc.guides.verticals.remove(at: index)
            case .horizontal: value = doc.guides.horizontals.remove(at: index)
            }
            draggedGuide = (axis, value)
            gesture = .guide(axis: axis)
        } else {
            if !shift { doc.selection = [] }
            gesture = .selectingArea(start: p, current: p, sum: shift)
        }
    }

    /// Dragging the selection (⌥: a copy of it).
    private func beginMove(_ p: CGPoint) {
        var registered = false
        if option, !doc.selection.isEmpty {
            registered = true
            doc.duplicateSelection(offset: .zero)
        }
        prepareSnap(exclude: doc.selection)
        let selectedObjects = doc.selectedObjects
        gesture = .moving(start: p, originals: Dictionary(uniqueKeysWithValues: selectedObjects.map { ($0.id, $0.frame) }),
                         pointsList: CanvasObject.movablePoints(selectedObjects), registered: registered)
    }

    /// Click on the ruler: starts a new guide; double click on the corner deletes them all.
    private func beginOnRuler(_ canvasPoint: CGPoint, _ rulers: RulerGeometry) -> Bool {
        if rulers.join.contains(canvasPoint) {
            if clicks >= 2, !doc.guides.emptyOnes {
                doc.registrar()
                doc.guides = Guides()
            }
            return true
        }
        let axis: Axis
        if rulers.horizontal.contains(canvasPoint) { axis = .horizontal } else if rulers.vertical.contains(canvasPoint) { axis = .vertical } else { return false }
        doc.registrar()
        // A new guide shows them all again.
        guidesVisible = true
        draggedGuide = (axis, nil)
        gesture = .guide(axis: axis)
        prepareSnap(exclude: [])
        return true
    }

    private func beginDirect(_ canvasPoint: CGPoint, _ p: CGPoint) {
        // 1. Handles of the chosen node; 2. nodes of the selected objects; 3. objects.
        if let ref = selectedNode, let object = doc.objects.first(where: { $0.id == ref.object }) {
            let subs = object.absoluteNodes
            if subs.indices.contains(ref.sub), subs[ref.sub].nodes.indices.contains(ref.node) {
                let node = subs[ref.sub].nodes[ref.node]
                for (part, handle) in [(NodePart.input, node.input), (.output, node.output)] {
                    if let handle, hypot(viewState.canvas(handle).x - canvasPoint.x, viewState.canvas(handle).y - canvasPoint.y) <= 6 {
                        gesture = .node(ref, part: part, original: subs, start: p, registered: false)
                        return
                    }
                }
            }
        }
        if let ref = nodeAt(canvasPoint), let object = doc.objects.first(where: { $0.id == ref.object }) {
            let subs = object.absoluteNodes
            selectedNode = ref
            if clicks >= 2 {
                toggleSmooth(ref, subs)
                return
            }
            prepareSnap(exclude: [object.id])
            gesture = .node(ref, part: .point, original: subs, start: p, registered: false)
            return
        }
        selectedNode = nil
        if let target = objectAt(canvasPoint) {
            doc.selection = shift ? doc.selection.symmetricDifference([target]) : [target]
        } else {
            if !shift { doc.selection = [] }
            gesture = .selectingArea(start: p, current: p, sum: shift)
        }
    }

    private func proceed(in canvasPoint: CGPoint) {
        let p = viewState.mm(canvasPoint)
        switch gesture {
        case .creating(let start, _):
            gesture = .creating(start: start, current: snapping(p))
        case .moving(let start, let originals, let pointsList, let registered):
            var dx = p.x - start.x, dy = p.y - start.y
            guard registered || hypot(dx, dy) * viewState.scale > 2 else { return }
            if shift { if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 } }
            if snapOn, let targets = tracing.targets {
                let snapped = targets.snap(pointsList, dx: dx, dy: dy, tolerance: tolerance)
                (dx, dy, snapMark) = (snapped.dx, snapped.dy, snapped.mark)
            }
            if !registered { doc.registrar() }
            for i in doc.objects.indices {
                if let original = originals[doc.objects[i].id] { doc.objects[i].frame = original.offsetBy(dx: dx, dy: dy) }
            }
            gesture = .moving(start: start, originals: originals, pointsList: pointsList, registered: true)
        case .resizing(let handle, let originals, let box, let registered):
            // The selection box goes to the pointer; each object stretches in the same proportion.
            if !registered { doc.registrar() }
            let newOne = resize(box, handle: handle, to: snapping(p), proportional: shift, fromCenter: option)
            for i in doc.objects.indices {
                if let original = originals[doc.objects[i].id] { doc.objects[i].frame = Document.stretch(original, of: box, to: newOne) }
            }
            gesture = .resizing(handle: handle, originals: originals, box: box, registered: true)
        case .selectingArea(let start, _, let sum):
            gesture = .selectingArea(start: start, current: p, sum: sum)
        case .pan(let start, let origin):
            viewState.origin = CGPoint(x: origin.x + canvasPoint.x - start.x, y: origin.y + canvasPoint.y - start.y)
            viewState.manual = true
        case .guide(let axis):
            let q = snapping(p)
            draggedGuide = (axis, ((axis == .vertical ? q.x : q.y) * 100).rounded() / 100)
            pointer.mm = p
        case .node(let ref, let part, let original, let start, let registered):
            dragNode(ref, part: part, original: original, start: start, p: p, registered: registered)
        case .pen(let index, let start):
            dragPen(index, start: start, p: p)
        case .zoomArea(let start, _):
            gesture = .zoomArea(start: start, current: canvasPoint)
        case nil:
            break
        }
    }

    private func finish(in canvasPoint: CGPoint) {
        defer {
            gesture = nil
            snapMark = nil
            tracing.targets = nil
        }
        switch gesture {
        case .creating(let start, let current):
            var frame = creationRect(start, current)
            // Click without dragging: a 30 mm shape centered on the click.
            if frame.width * viewState.scale < 4 || frame.height * viewState.scale < 4 {
                frame = CGRect(x: start.x - 15, y: start.y - 15, width: 30, height: 30)
            }
            doc.add(doc.newObject(newShape, frame: frame))
        case .selectingArea(let start, let current, let sum):
            let area = CGRect.between(start, current, proportional: false, fromCenter: false)
            // A click without dragging on empty space only clears the selection (a zero-size area caught the objects' boxes).
            guard max(area.width, area.height) * viewState.scale >= 3 else { break }
            let touched = doc.withGroups(Set(doc.objects.filter { !doc.untouchable($0) && $0.shapePath.boundingRect.intersects(area) }.map(\.id)))
            doc.selection = sum ? doc.selection.union(touched) : touched
        case .guide(let axis):
            // Dropped on the ruler (or without moving) = no guide.
            if let value = draggedGuide?.value, let rulers, !rulers.contains(canvasPoint) {
                switch axis {
                case .vertical: doc.guides.verticals.append(value)
                case .horizontal: doc.guides.horizontals.append(value)
                }
            }
            draggedGuide = nil
        case .zoomArea(let start, let current):
            // Click: twice as close (⌥: half); dragging: the area fills the canvas.
            let area = CGRect.between(start, current, proportional: false, fromCenter: false)
            if max(area.width, area.height) < 4 {
                viewState.zoomIn(to: viewState.zoom * (option ? 0.5 : 2), anchor: start)
            } else {
                let center = CGPoint(x: area.midX, y: area.midY)
                viewState.zoomIn(to: viewState.zoom * min(tracing.size.width / area.width, tracing.size.height / area.height), anchor: center)
                viewState.offsetBy(dx: tracing.size.width / 2 - center.x, dy: tracing.size.height / 2 - center.y)
            }
            pointer.mm = viewState.mm(current)
        default:
            break
        }
    }

    // MARK: Direct selection

    private func dragNode(_ ref: NodeRef, part: NodePart, original: [Subpath], start: CGPoint, p: CGPoint, registered: Bool) {
        guard original.indices.contains(ref.sub), original[ref.sub].nodes.indices.contains(ref.node),
              let i = doc.objects.firstIndex(where: { $0.id == ref.object }) else { return }
        guard registered || hypot(p.x - start.x, p.y - start.y) * viewState.scale > 1 else { return }
        if !registered { doc.registrar() }
        var subs = original
        var node = subs[ref.sub].nodes[ref.node]
        switch part {
        case .point:
            let q = snapping(p)
            let dx = q.x - node.point.x, dy = q.y - node.point.y
            node.point = q
            node.input = node.input.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            node.output = node.output.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        case .input, .output:
            // The opposite handle follows, with its own length (⌥ breaks the node).
            let opposite = part == .input ? node.output : node.input
            if part == .input { node.input = p } else { node.output = p }
            if !option, let opposite {
                let length = hypot(opposite.x - node.point.x, opposite.y - node.point.y)
                let d = hypot(p.x - node.point.x, p.y - node.point.y)
                if d > 0 {
                    let mirror = CGPoint(x: node.point.x - (p.x - node.point.x) / d * length, y: node.point.y - (p.y - node.point.y) / d * length)
                    if part == .input { node.output = mirror } else { node.input = mirror }
                }
            }
        }
        subs[ref.sub].nodes[ref.node] = node
        doc.objects[i].setNodes(subs)
        gesture = .node(ref, part: part, original: original, start: start, registered: true)
    }

    /// Double click on a node: corner ↔ smooth (handles in the direction of the neighbors, as in the prototype).
    private func toggleSmooth(_ ref: NodeRef, _ subs: [Subpath]) {
        guard let i = doc.objects.firstIndex(where: { $0.id == ref.object }) else { return }
        var subs = subs
        var node = subs[ref.sub].nodes[ref.node]
        let nodes = subs[ref.sub].nodes
        if node.input != nil || node.output != nil {
            node.input = nil
            node.output = nil
        } else {
            let previous = nodes[(ref.node - 1 + nodes.count) % nodes.count].point, next = nodes[(ref.node + 1) % nodes.count].point
            let dx = (next.x - previous.x) / 6, dy = (next.y - previous.y) / 6
            node.input = CGPoint(x: node.point.x - dx, y: node.point.y - dy)
            node.output = CGPoint(x: node.point.x + dx, y: node.point.y + dy)
        }
        subs[ref.sub].nodes[ref.node] = node
        doc.registrar()
        doc.objects[i].setNodes(subs)
    }

    // MARK: Pen

    /// Click: corner point (dragging pulls the handles); clicking the first point closes the path.
    private func clickPen(_ p: CGPoint) {
        if var current = pen {
            if current.object.flatMap({ id in doc.objects.first { $0.id == id } }) == nil, current.object != nil {
                pen = nil   // the object is gone (⌘Z): start over
                clickPen(p)
                return
            }
            if current.nodes.count >= 2, let first = current.nodes.first, hypot(first.point.x - p.x, first.point.y - p.y) < tolerance {
                commitPen(current, closed: true)
                pen = nil
                return
            }
            current.nodes.append(Node(point: p))
            pen = current
            commitPen(current, closed: false)
            gesture = .pen(index: current.nodes.count - 1, start: p)
        } else {
            pen = Pen(object: nil, nodes: [Node(point: p)])
            gesture = .pen(index: 0, start: p)
        }
    }

    private func dragPen(_ index: Int, start: CGPoint, p: CGPoint) {
        guard var current = pen, current.nodes.indices.contains(index), hypot(p.x - start.x, p.y - start.y) > 0.4 else { return }
        let point = current.nodes[index].point
        current.nodes[index].output = p
        current.nodes[index].input = CGPoint(x: 2 * point.x - p.x, y: 2 * point.y - p.y)
        pen = current
        commitPen(current, closed: false)
    }

    /// Brings the pen path into the document (creates the object at the 2nd point).
    private func commitPen(_ current: Pen, closed: Bool) {
        guard current.nodes.count >= 2 else { return }
        let subs = [Subpath(nodes: current.nodes, closed: closed)]
        if let id = current.object, let i = doc.objects.firstIndex(where: { $0.id == id }) {
            doc.objects[i].setNodes(subs)
        } else {
            var updated = doc.newObject(.shapePath([]), frame: .zero)
            updated.setNodes(subs)
            doc.add(updated)
            pen?.object = updated.id
        }
    }

    private func finishPen() {
        pen = nil
        snapMark = nil
    }

    // MARK: Click targets

    /// Frontmost object under the point, in two steps. 1) What is actually there: the letter box of a
    /// text, the stroke (or near it; the whole thick stroke) or the inside of a shape with a fill or image.
    /// 2) Only if nothing is: the inside of a shape without fill. This way an empty shape on top doesn't cover
    /// what is below it, and clicking its empty inside still selects it.
    private func objectAt(_ canvasPoint: CGPoint) -> CanvasObject.ID? {
        let order = doc.objectsInOrder.reversed().filter { !doc.untouchable($0) }
        for object in order {
            // Text: any point of the letter box (not only on the letters, as in Illustrator).
            if case .text = object.shape, viewState.canvas(object.frame.standardized).insetBy(dx: -4, dy: -4).contains(canvasPoint) {
                return object.id
            }
            let shapePath = object.shapePath.applying(viewState.transform)
            let filled = object.fill != nil || object.image != nil
            let strokeColor = shapePath.strokedPath(StrokeStyle(lineWidth: max(8, 2 * object.strokeWidth * viewState.zoom)))
            if filled && shapePath.contains(canvasPoint, eoFill: true) || strokeColor.contains(canvasPoint) {
                return object.id
            }
        }
        return order.first { $0.shapePath.applying(viewState.transform).contains(canvasPoint, eoFill: true) }?.id
    }

    /// Node of a selected object under the point (the frontmost).
    private func nodeAt(_ canvasPoint: CGPoint) -> NodeRef? {
        for object in doc.selectedObjects.reversed() {
            for (s, sub) in object.absoluteNodes.enumerated() {
                for (n, node) in sub.nodes.enumerated() {
                    let q = viewState.canvas(node.point)
                    if abs(q.x - canvasPoint.x) <= 6, abs(q.y - canvasPoint.y) <= 6 { return NodeRef(object: object.id, sub: s, node: n) }
                }
            }
        }
        return nil
    }

    private func handleAt(_ canvasPoint: CGPoint) -> Handle? {
        guard let box = selectionBox else { return nil }
        return Handle.allCases.first { handle in
            let p = handle.point(in: box)
            return abs(p.x - canvasPoint.x) <= 6 && abs(p.y - canvasPoint.y) <= 6
        }
    }

    /// Hidden or locked guides can't be picked up.
    private func guideAt(_ canvasPoint: CGPoint) -> (Axis, Int)? {
        guard guidesVisible, !guidesLocked else { return nil }
        if let i = doc.guides.verticals.firstIndex(where: { abs(viewState.canvas(CGPoint(x: $0, y: 0)).x - canvasPoint.x) <= 3 }) { return (.vertical, i) }
        if let i = doc.guides.horizontals.firstIndex(where: { abs(viewState.canvas(CGPoint(x: 0, y: $0)).y - canvasPoint.y) <= 3 }) { return (.horizontal, i) }
        return nil
    }

    /// New frame from dragging a handle; with shift on the corners, keeps the proportion; with ⌥, grows on both
    /// sides (the center stays put and the opposite side follows, mirrored).
    private func resize(_ r: CGRect, handle: Handle, to p: CGPoint, proportional: Bool, fromCenter: Bool) -> CGRect {
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        if handle.movesLeft { minX = p.x }
        if handle.movesRight { maxX = p.x }
        if handle.movesTop { minY = p.y }
        if handle.movesBottom { maxY = p.y }
        if fromCenter {
            if handle.movesLeft || handle.movesRight { (minX, maxX) = (r.midX - abs(p.x - r.midX), r.midX + abs(p.x - r.midX)) }
            if handle.movesTop || handle.movesBottom { (minY, maxY) = (r.midY - abs(p.y - r.midY), r.midY + abs(p.y - r.midY)) }
            if proportional, handle.isCorner, r.width > 0, r.height > 0 {
                let s = max((maxX - minX) / r.width, (maxY - minY) / r.height)
                return CGRect(x: r.midX - r.width * s / 2, y: r.midY - r.height * s / 2, width: r.width * s, height: r.height * s)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        if proportional, handle.isCorner, r.width > 0, r.height > 0 {
            // anchor = opposite corner
            let ax = handle.movesLeft ? r.maxX : r.minX
            let ay = handle.movesTop ? r.maxY : r.minY
            let s = max(abs(p.x - ax) / r.width, abs(p.y - ay) / r.height)
            let sx: Double = p.x < ax ? -1 : 1, sy: Double = p.y < ay ? -1 : 1
            return CGRect.between(CGPoint(x: ax, y: ay), CGPoint(x: ax + sx * r.width * s, y: ay + sy * r.height * s),
                                proportional: false, fromCenter: false)
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }


    // MARK: Keyboard and scrolling

    /// Delete deletes, Esc clears the selection (or finishes the pen), Enter finishes the pen, space holds the
    /// hand, arrows move the selection (1 mm; ⇧ 10 mm; ⌥ 0.1 mm), letters switch the tool (V, A, P, +/=, −, T, M, L, S,
    /// I, H, Z); colors as in Illustrator: X toggles
    /// fill/stroke, ⇧X swaps them, D default, / none. With ⌘, object shortcuts are read
    /// here (outside text fields, which keep their own), without depending on the menus' state: ⌘A all,
    /// ⌘C/⌘X/⌘V, ⌘D duplicates, ⌘ + arrow duplicates beside, ⌘G/⇧⌘G group and ungroup, ⌘] ⌘[ ⇧⌘] ⇧⌘[ arrange,
    /// ⌘B/⌘I/⌘U bold, italic and underline of the selected texts. ⌘R, ⌘U (snap, without a text) and ⌘; (guides)
    /// belong to the View menu.
    private func keyboard(_ event: NSEvent) -> NSEvent? {
        guard let nsWindow, event.window === nsWindow, nsWindow.attachedSheet == nil,
              !(nsWindow.firstResponder is NSText) else { return event }
        let command = event.modifierFlags.contains(.command)
        let withModifier = !event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        let goingDown = event.type == .keyDown
        if goingDown, command, event.modifierFlags.isDisjoint(with: [.option, .control]) {
            let uppercase = event.modifierFlags.contains(.shift)
            let arrows: [UInt16: Direction] = [123: .left, 124: .right, 125: .bottom, 126: .up]
            if let direction = arrows[event.keyCode] {
                guard !uppercase else { return event }
                doc.duplicateBeside(direction)
                return nil
            }
            switch (event.charactersIgnoringModifiers?.lowercased(), uppercase) {
            case ("a", false): doc.selectAll()
            case ("c", false): doc.copySelection()
            case ("x", false): doc.cutSelection()
            case ("v", false): doc.paste()
            case ("d", false): doc.duplicateSelection()
            case ("b", false), ("i", false), ("u", false):
                // Bold, italic and underline of the whole selected texts; without a text, ⌘U goes to the Snap menu.
                guard doc.hasTextSelected, let key = event.charactersIgnoringModifiers?.lowercased().first else { return event }
                doc.toggleTextStyle(key)
            case ("g", false): doc.groupSelected()
            case ("g", true): doc.ungroupSelected()
            case ("]", _), ("}", _): doc.arrange(uppercase ? .front : .forward)
            case ("[", _), ("{", _): doc.arrange(uppercase ? .back : .backward)
            default: return event
            }
            return nil
        }
        switch event.keyCode {
        case 49:   // space
            guard !withModifier else { return event }
            space = goingDown
            return nil
        case 36 where pen != nil, 76 where pen != nil:   // enter
            guard goingDown else { return nil }
            finishPen()
            return nil
        case 51, 117:   // delete, forward delete (⌘⌫ stays with the Edit › Delete menu)
            guard goingDown, !withModifier else { return event }
            doc.deleteSelection()
            selectedNode = nil
            return nil
        case 53:   // esc
            guard goingDown else { return event }
            if pen != nil { finishPen() } else {
                doc.selection = []
                selectedNode = nil
            }
            return nil
        case 7 where goingDown && !withModifier:   // x
            if event.modifierFlags.contains(.shift) {
                doc.swapColors()
            } else {
                doc.colorTarget = doc.colorTarget == .strokeColor ? .fill : .strokeColor
            }
            return nil
        case 2 where goingDown && !withModifier && !event.modifierFlags.contains(.shift):   // d
            doc.defaultColors()
            return nil
        case 123...126 where event.modifierFlags.isDisjoint(with: [.command, .control]):   // arrows
            // Move the selection by the steps in Settings (1 mm; with ⇧, 10 mm; with ⌥, 0.1 mm). Without a selection, they
            // go to whoever comes next.
            guard !doc.selection.isEmpty else { return event }
            guard goingDown else { return nil }
            let steps = Preferences.arrowSteps
            let step = event.modifierFlags.contains(.shift) ? steps.shift : event.modifierFlags.contains(.option) ? steps.option : steps.normal
            let offsets: [UInt16: (Double, Double)] = [123: (-step, 0), 124: (step, 0), 125: (0, step), 126: (0, -step)]
            if let (dx, dy) = offsets[event.keyCode] { doc.moveSelection(dx: dx, dy: dy) }
            return nil
        case 44 where goingDown && !withModifier && !event.modifierFlags.contains(.shift):   // /
            doc.setColor(doc.colorTarget, nil)
            return nil
        default:
            // + is ⇧= on most keyboards (= also works, as in Illustrator).
            guard goingDown, !withModifier, let typed = event.charactersIgnoringModifiers?.lowercased().first else { return event }
            let letter: Character = typed == "=" ? "+" : typed
            guard letter == "+" || !event.modifierFlags.contains(.shift),
                  let tool = Tool.allCases.first(where: { $0.keyEvent == letter }) else { return event }
            doc.tool = tool
            return nil
        }
    }

    /// Right click (or ⌃-click) on the canvas: selects what is underneath, if it isn't selected, and opens the
    /// context menu. While typing a text, the menu is the text's.
    private func rightClick(_ event: NSEvent) -> NSEvent? {
        guard let nsWindow, event.window === nsWindow, nsWindow.attachedSheet == nil, let p = tracing.pointer,
              event.type == .rightMouseDown || event.modifierFlags.contains(.control),
              doc.textEditing == nil, gesture == nil, pen == nil else { return event }
        if let rulers, rulers.contains(p) { return event }
        if let target = objectAt(p), !doc.selection.contains(target), let object = doc.objects.first(where: { $0.id == target }) {
            doc.selection = doc.tool.editsNodes ? [target] : doc.unit(of: target)
            doc.activeLayer = doc.layer(of: object).id
            selectedNode = nil
        }
        NSMenu.popUpContextMenu(ContextMenu.create(doc), with: event, for: nsWindow.contentView ?? NSView())
        return nil
    }

    /// Two fingers on the trackpad (or the mouse wheel) move the page; with ⌘ or ⌥, zoom at the pointer.
    private func scroll(_ event: NSEvent) -> NSEvent? {
        guard let p = tracing.pointer, event.window?.isKeyWindow == true else { return event }
        let factor = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
        if !event.modifierFlags.isDisjoint(with: [.command, .option]) {
            viewState.zoomIn(to: viewState.zoom * exp(event.scrollingDeltaY * factor * 0.01), anchor: p)
        } else {
            viewState.offsetBy(dx: event.scrollingDeltaX * factor, dy: event.scrollingDeltaY * factor)
        }
        pointer.mm = viewState.mm(p)
        return nil
    }
}

/// Canvas state that shouldn't redraw when it changes.
private final class Tracing {
    var pointer: CGPoint?
    /// The canvas size (the Zoom tool's area fills it).
    var size = CGSize.zero
    var targets: SnapTargets?
}

/// Finds the NSWindow that contains the view.
struct WindowReader: NSViewRepresentable {
    let didFindMatch: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { Probe(didFindMatch: didFindMatch) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        let didFindMatch: (NSWindow?) -> Void
        init(didFindMatch: @escaping (NSWindow?) -> Void) {
            self.didFindMatch = didFindMatch
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let nsWindow = window
            DispatchQueue.main.async { self.didFindMatch(nsWindow) }
        }
    }
}
