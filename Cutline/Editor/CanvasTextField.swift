// Typing on the canvas: an invisible NSTextView, placed over the letters, receives the keyboard (accents, paste,
// macOS text shortcuts); each change goes to the document and the canvas redraws the real text. The
// style of each run travels as an attribute of the field's text (typing, deleting and pasting carry the style along,
// as in a text editor). Cursor, selection, clicks and ↑ ↓ arrows use the text's own layout
// (TextBox.textLayout), the same as the letters — so they match the drawing with any alignment.
import AppKit
import SwiftUI

/// Cursor and selection of the invisible field (they don't redraw the whole canvas, only the edit marks).
@Observable
final class TextCursor {
    var selection = NSRange(location: 0, length: 0)
    /// Text being composed (accent before the letter, input methods).
    var checked: NSRange?
    /// Last change: the cursor stays lit while typing and blinks afterwards.
    var changed = Date()
}

/// Links the text being edited (body pt, y down, from the text's point) to canvas points.
struct EditGeometry {
    let edit: TextEditing
    let text: TextBox
    let viewState: ViewState
    /// The text's point (mm) and stretch, as they are now (Document.editAnchor).
    let origin: CGPoint
    let scale: CGSize

    var textLayout: TextBox.TextLayout { text.textLayout }

    /// Body pt → canvas points.
    func canvas(_ p: CGPoint) -> CGPoint {
        let mm = TextBox.mmPerPt
        return viewState.canvas(CGPoint(x: origin.x + p.x * mm * scale.width, y: origin.y + p.y * mm * scale.height))
    }

    /// Page mm → body pt.
    func pointSize(_ p: CGPoint) -> CGPoint {
        let mm = TextBox.mmPerPt
        return CGPoint(x: (p.x - origin.x) / (mm * scale.width), y: (p.y - origin.y) / (mm * scale.height))
    }

    /// Area of the invisible field in body pt: the lines, with slack for the cursor and for letters that go past the
    /// start of the line (italics, scripts).
    var fieldBounds: CGRect {
        let d = textLayout, emSize = text.largestSize
        let x0 = d.minX - 0.3 * emSize, x1 = d.maxX + emSize
        return CGRect(x: x0, y: 0, width: x1 - x0, height: d.height + 0.2 * emSize)
    }

    /// The same area in canvas points.
    var fieldFrame: CGRect {
        let r = fieldBounds
        let a = canvas(CGPoint(x: r.minX, y: r.minY)), b = canvas(CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    /// Rectangle (body pt) of a run in its line, from the top of the letters to the foot.
    func rectangle(_ span: NSRange) -> CGRect {
        let d = textLayout
        let (i, x0) = d.position(span.location)
        let x1 = d.position(min(NSMaxRange(span), d.lines[i].end)).x
        return CGRect(x: x0, y: d.lines[i].top, width: max(x1 - x0, 1), height: d.lines[i].foot - d.lines[i].top)
    }
}

/// Cursor (blinking), selection and underline of the text being composed, over the letters.
struct EditMarks: View {
    let geometry: EditGeometry
    let cursor: TextCursor

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { cgContext in
            Canvas { ctx, _ in render(&ctx, now: cgContext.date) }
        }
        .allowsHitTesting(false)
    }

    private func render(_ ctx: inout GraphicsContext, now: Date) {
        let d = geometry.textLayout
        let selection = cursor.selection
        if selection.length > 0 {
            for line in d.lines where selection.location <= line.end && NSMaxRange(selection) > line.start {
                let x0 = d.position(max(selection.location, line.start)).x
                var x1 = d.position(min(NSMaxRange(selection), line.end)).x
                // A selected line break shows as a small extra piece.
                if NSMaxRange(selection) > line.end { x1 += geometry.text.largestSize * 0.25 }
                square(&ctx, CGRect(x: x0, y: line.top, width: x1 - x0, height: line.foot - line.top))
            }
        } else {
            let tempo = now.timeIntervalSince(cursor.changed)
            if tempo < 0.5 || Int(tempo / 0.5) % 2 == 0 || Self.fixedCursor {
                // Height of the letter before the cursor (superscript, different sizes on the same line).
                let c = d.cursor(selection.location)
                trace(&ctx, of: CGPoint(x: c.x, y: c.top), until: CGPoint(x: c.x, y: c.foot))
            }
        }
        if let checked = cursor.checked, checked.length > 0 {
            let (i, x0) = d.position(checked.location)
            let x1 = d.position(NSMaxRange(checked)).x
            let y = d.lines[i].base + d.lines[i].descender * 0.45
            trace(&ctx, of: CGPoint(x: x0, y: y), until: CGPoint(x: x1, y: y))
        }
    }

    private func square(_ ctx: inout GraphicsContext, _ r: CGRect) {
        let a = geometry.canvas(CGPoint(x: r.minX, y: r.minY)), b = geometry.canvas(CGPoint(x: r.maxX, y: r.maxY))
        ctx.fill(Path(CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)), with: .color(.accentColor.opacity(0.28)))
    }

    private func trace(_ ctx: inout GraphicsContext, of a: CGPoint, until b: CGPoint) {
        var line = Path()
        line.move(to: geometry.canvas(a))
        line.addLine(to: geometry.canvas(b))
        ctx.stroke(line, with: .color(.accentColor), lineWidth: 1.5)
    }

    #if DEBUG
    private static let fixedCursor = DebugHooks.canvasText != nil
    #else
    private static let fixedCursor = false
    #endif
}

/// The invisible field that receives the keyboard, placed over the letters; its coordinates are body pt.
struct CanvasTextField: NSViewRepresentable {
    let doc: Document
    let geometry: EditGeometry
    let cursor: TextCursor

    func makeCoordinator() -> Coordinator {
        Coordinator(doc: doc, cursor: cursor, session: geometry.edit.session)
    }

    func makeNSView(context: Context) -> Support {
        let coordinator = context.coordinator
        coordinator.geometry = geometry
        let field = InvisibleField(frame: .zero)
        field.delegate = coordinator
        field.textContainerInset = .zero
        field.textContainer?.lineFragmentPadding = 0
        field.textContainer?.widthTracksTextView = false
        field.textContainer?.containerSize = NSSize(width: 1e7, height: 1e7)
        field.drawsBackground = false
        // With attributes (each run's style); pasting only brings the text (InvisibleField.readablePasteboardTypes).
        field.isRichText = true
        field.importsGraphics = false
        field.usesFontPanel = false
        field.usesRuler = false
        field.usesFindBar = false
        field.allowsUndo = false   // ⌘Z undoes the whole edit (one document step)
        field.isHorizontallyResizable = false
        field.isVerticallyResizable = false
        field.isContinuousSpellCheckingEnabled = false
        field.isGrammarCheckingEnabled = false
        field.isAutomaticSpellingCorrectionEnabled = false
        field.isAutomaticTextReplacementEnabled = false
        field.isAutomaticLinkDetectionEnabled = false
        field.isAutomaticDataDetectionEnabled = false
        field.inlinePredictionType = .no
        field.writingToolsBehavior = .none
        field.insertionPointColor = .clear
        field.selectedTextAttributes = [.backgroundColor: NSColor.clear]
        field.markedTextAttributes = [.foregroundColor: NSColor.clear]
        field.coordinator = coordinator
        coordinator.field = field
        field.string = geometry.text.content
        coordinator.writeRuns(geometry.text)
        coordinator.sync()

        let support = Support(field: field)
        support.limits = geometry.fieldBounds
        // The cursor starts where the click was (or at the end of the text).
        let start = geometry.edit.click.map { geometry.textLayout.index(in: geometry.pointSize($0)) }
            ?? (geometry.text.content as NSString).length
        support.onEnterWindow = { [weak field, weak coordinator] nsWindow in
            guard let field else { return }
            nsWindow.makeFirstResponder(field)
            field.setSelectedRange(NSRange(location: start, length: 0))
            coordinator?.updateCursor()
            #if DEBUG
            DebugHooks.selectTextForTest(field)
            #endif
        }
        return support
    }

    func updateNSView(_ support: Support, context: Context) {
        context.coordinator.geometry = geometry
        context.coordinator.sync()
        support.limits = geometry.fieldBounds
    }

    /// Receives the size given by the canvas and shows the field in it, with coordinates in body pt.
    final class Support: NSView {
        let field: InvisibleField
        var onEnterWindow: ((NSWindow) -> Void)?
        var limits = CGRect.zero {
            didSet { if limits != oldValue { needsLayout = true } }
        }

        init(field: InvisibleField) {
            self.field = field
            super.init(frame: .zero)
            addSubview(field)
        }

        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }

        override func layout() {
            super.layout()
            field.frame = bounds
            guard limits.width > 0, limits.height > 0 else { return }
            field.setBoundsSize(limits.size)
            field.setBoundsOrigin(limits.origin)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let onEnter = onEnterWindow else { return }
            onEnterWindow = nil
            DispatchQueue.main.async { onEnter(window) }
        }
    }

    /// NSTextView that uses the text's layout for clicks, ↑ ↓ arrows and the position of the input-method
    /// window, and reports losing focus.
    final class InvisibleField: NSTextView {
        weak var coordinator: Coordinator?

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { coordinator?.resigned() }
            return resigned
        }

        /// Click places the cursor; dragging selects; double click, the word; triple, the line; ⇧ extends.
        override func mouseDown(with event: NSEvent) {
            guard let d = coordinator?.geometry?.textLayout else { return super.mouseDown(with: event) }
            window?.makeFirstResponder(self)
            if hasMarkedText() { unmarkText() }
            let granularity: NSSelectionGranularity = switch event.clickCount {
            case 1: .selectByCharacter
            case 2: .selectByWord
            default: .selectByParagraph
            }
            func index(_ e: NSEvent) -> Int { d.index(in: convert(e.locationInWindow, from: nil)) }
            func span(_ a: Int, _ b: Int) -> NSRange {
                let r = NSRange(location: min(a, b), length: abs(a - b))
                return granularity == .selectByCharacter ? r : selectionRange(forProposedRange: r, granularity: granularity)
            }
            let current = selectedRange(), clicked = index(event)
            let anchor = event.modifierFlags.contains(.shift)
                ? (clicked > current.location ? current.location : NSMaxRange(current))
                : clicked
            setSelectedRange(span(anchor, clicked))
            while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                setSelectedRange(span(anchor, index(next)))
                if next.type == .leftMouseUp { break }
            }
        }

        /// Paste and drag bring only the text (with the style of where it goes in).
        override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
        override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [.string] }

        /// ⌘B, ⌘I and ⌘U (the app has no Format menu): bold, italic and the Character panel's underline for the
        /// selected letters.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, let doc = coordinator?.doc,
               let key = event.charactersIgnoringModifiers?.lowercased().first, "biu".contains(key) {
                doc.toggleTextStyle(key)
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        override func moveUp(_ sender: Any?) { move(-1) }
        override func moveDown(_ sender: Any?) { move(1) }

        private func move(_ orientation: Int) {
            guard let d = coordinator?.geometry?.textLayout else { return }
            let r = selectedRange()
            setSelectedRange(NSRange(location: d.neighbor(orientation < 0 ? r.location : NSMaxRange(r), orientation), length: 0))
        }

        override func firstRect(forCharacterRange span: NSRange, actualRange: NSRangePointer?) -> NSRect {
            guard let geometry = coordinator?.geometry, let window else {
                return super.firstRect(forCharacterRange: span, actualRange: actualRange)
            }
            actualRange?.pointee = span
            return window.convertToScreen(convert(geometry.rectangle(span), to: nil))
        }
    }

    /// Style stored as an attribute of the field's text (comparable, so runs can merge).
    nonisolated final class StyleBox: NSObject, Sendable {
        let style: CharacterStyle
        init(_ style: CharacterStyle) { self.style = style }
        override func isEqual(_ other: Any?) -> Bool { (other as? StyleBox)?.style == style }
        override var hash: Int { style.hashValue }
    }

    static let styleKey = NSAttributedString.Key("cutline.style")

    final class Coordinator: NSObject, NSTextViewDelegate {
        let doc: Document
        let cursor: TextCursor
        let session: UUID
        weak var field: NSTextView?
        var geometry: EditGeometry?
        private var seenFocus: Int

        init(doc: Document, cursor: TextCursor, session: UUID) {
            self.doc = doc
            self.cursor = cursor
            self.session = session
            seenFocus = doc.focusCanvasText
        }

        /// Attributes of a run in the field: the style and the font (the field isn't visible, but macOS uses the font
        /// for accents and input methods).
        private func attributes(_ e: CharacterStyle) -> [NSAttributedString.Key: Any] {
            var color = NSColor.clear
            #if DEBUG
            if DebugHooks.canvasText == "visible" { color = NSColor.systemBlue.withAlphaComponent(0.55) }
            #endif
            return [.font: e.ctFont(pointSize: e.effectivePointSize) as NSFont, .foregroundColor: color,
                    CanvasTextField.styleKey: StyleBox(e)]
        }

        /// Runs of the field's text, by the style attribute.
        func readRuns() -> [TextRun] {
            guard let storage = field?.textStorage else { return [] }
            let defaultValue = geometry?.text.style ?? CharacterStyle()
            var textRuns: [TextRun] = []
            storage.enumerateAttribute(CanvasTextField.styleKey, in: NSRange(location: 0, length: storage.length)) { value, span, _ in
                textRuns.append(TextRun(length: span.length, style: (value as? StyleBox)?.style ?? defaultValue))
            }
            return textRuns
        }

        /// Puts each document run's style into the field (the panel changed the selected letters).
        func writeRuns(_ text: TextBox) {
            guard let field, let storage = field.textStorage, storage.string == text.content, !field.hasMarkedText() else { return }
            storage.beginEditing()
            var position = 0
            for t in text.completeRuns {
                storage.setAttributes(attributes(t.style), range: NSRange(location: position, length: t.length))
                position += t.length
            }
            storage.endEditing()
        }

        /// After each document change: runs, typing style and focus back on the text.
        func sync() {
            guard let field, let text = geometry?.text else { return }
            if text.length > 0 {
                var ofField = text
                ofField.textRuns = readRuns()
                ofField.normalize()
                if ofField.textRuns != text.textRuns || ofField.style != text.style { writeRuns(text) }
            }
            if let typing = doc.typingStyle ?? (text.length == 0 ? text.style : nil),
               (field.typingAttributes[CanvasTextField.styleKey] as? StyleBox)?.style != typing {
                field.typingAttributes = attributes(typing)
            }
            if doc.focusCanvasText != seenFocus {
                seenFocus = doc.focusCanvasText
                field.window?.makeFirstResponder(field)
            }
        }

        func updateCursor() {
            guard let field else { return }
            let selection = field.selectedRange()
            cursor.selection = selection
            cursor.checked = field.hasMarkedText() ? field.markedRange() : nil
            cursor.changed = Date()
            if doc.textSelection != selection { doc.textSelection = selection }
            // Moving the cursor discards the style chosen for typing (the letter before it wins).
            if doc.typingStyle != nil { doc.typingStyle = nil }
        }

        /// Lost focus: ends editing afterwards (it may have been a click that already opened another one). If focus went
        /// to a field in the bar or the panels, editing continues: they act on the selected letters.
        func resigned() {
            let doc = doc, session = session
            DispatchQueue.main.async { [weak field] in
                if let nsWindow = field?.window, let focus = nsWindow.firstResponder as? NSText, focus !== field { return }
                doc.finishText(session: session)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let field else { return }
            let typing = (field.typingAttributes[CanvasTextField.styleKey] as? StyleBox)?.style
            doc.typeText(field.string, textRuns: readRuns(), emptyStyle: typing)
            updateCursor()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            updateCursor()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Esc ends editing and goes back to selection with the text selected (as in Illustrator).
            guard selector == #selector(NSResponder.cancelOperation(_:)) || selector == #selector(NSTextView.complete(_:)) else {
                return false
            }
            doc.finishText()
            doc.tool = .selection
            return true
        }

        /// Line breaks from other systems (pasted from another app) become the regular break, the only one the
        /// text's lines know.
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
            guard let text, text.contains(where: { $0 == "\r" || $0 == "\r\n" || $0 == "\u{2028}" || $0 == "\u{2029}" }) else {
                return true
            }
            let normal = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n")
            textView.insertText(normal, replacementRange: range)
            return false
        }
    }
}
