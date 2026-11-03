// Text editing right on the canvas, as in Illustrator: the Text tool (or a double click on a text)
// opens editing; each typed letter changes the object right away (the canvas shows the real outline). All
// the typing is a single undo step; text that ends up empty disappears.
import AppKit
import CoreGraphics
import Foundation

/// Text being typed on the canvas. The invisible field that receives the keyboard is in Editor/CanvasTextField.swift.
nonisolated struct TextEditing: Equatable, Sendable {
    /// Changes on each edit (the canvas recreates the invisible field).
    let session = UUID()
    let id: CanvasObject.ID
    /// The text's point, in page mm: top of the 1st line and x of the alignment (start of the lines on the left,
    /// middle in the center, end on the right). It stays put while typing.
    var origin: CGPoint
    /// The object's stretch relative to the letters' natural size (1 = no stretch): the Character panel's
    /// horizontal and vertical scales.
    var scale: CGSize
    /// Where the click that opened editing landed (page mm): the cursor starts there; nil = at the end of the text.
    let click: CGPoint?
    /// Already went into undo.
    var registered = false
}

extension CanvasObject {
    /// Text without letters (only exists while typing a new text on the canvas).
    nonisolated var emptyText: Bool {
        if case .text(let t) = shape { t.content.allSatisfy(\.isWhitespace) } else { false }
    }

    /// Text: the text's point (top of the 1st line and x of the alignment, page mm) and the frame's stretch
    /// relative to the letters' natural size.
    var textAnchor: (origin: CGPoint, scale: CGSize)? {
        guard case .text(let t) = shape else { return nil }
        let r = frame.standardized
        guard let n = t.contour?.boundingBoxOfPath, n.width > 0, n.height > 0 else {
            return (r.origin, CGSize(width: 1, height: 1))
        }
        let scale = CGSize(width: r.width / n.width, height: r.height / n.height)
        return (CGPoint(x: r.minX - n.minX * scale.width, y: r.minY - n.minY * scale.height), scale)
    }

    /// Replaces the text keeping the text's point in place and the stretch (the frame follows the letters).
    mutating func replaceText(_ updated: TextBox, origin: CGPoint, scale: CGSize) {
        shape = .text(updated)
        guard let n = updated.contour?.boundingBoxOfPath else {
            frame = CGRect(origin: origin, size: .zero)
            return
        }
        frame = CGRect(x: origin.x + n.minX * scale.width, y: origin.y + n.minY * scale.height,
                        width: n.width * scale.width, height: n.height * scale.height)
    }
}

extension TextBox {
    /// Applies the change to the run (UTF-16) or, without a run, to the whole text (also to the empty text's style).
    mutating func apply(_ change: (inout CharacterStyle) -> Void, in span: NSRange? = nil) {
        guard let span, span.length > 0 else {
            change(&style)
            for i in textRuns.indices { change(&textRuns[i].style) }
            normalize()
            return
        }
        var newItems: [TextRun] = [], position = 0
        for t in completeRuns {
            let start = position, end = position + t.length
            position = end
            let a = min(max(span.location, start), end), b = min(max(NSMaxRange(span), start), end)
            if a > start { newItems.append(TextRun(length: a - start, style: t.style)) }
            if b > a {
                var e = t.style
                change(&e)
                newItems.append(TextRun(length: b - a, style: e))
            }
            if end > b { newItems.append(TextRun(length: end - b, style: t.style)) }
        }
        textRuns = newItems
        normalize()
    }

    /// Content and runs coming from the canvas field (empty text keeps `emptyStyle`, the typing one).
    mutating func assign(content: String, textRuns: [TextRun], emptyStyle: CharacterStyle?) {
        self.content = content
        self.textRuns = textRuns
        if content.isEmpty, let emptyStyle { style = emptyStyle }
        normalize()
    }

    /// Runs covering exactly the text, equal neighbors merged; uniform = only `style`.
    mutating func normalize() {
        let total = length
        guard total > 0 else {
            textRuns = []
            return
        }
        var list: [TextRun] = [], runningTotal = 0
        for t in textRuns where t.length > 0 && runningTotal < total {
            let c = min(t.length, total - runningTotal)
            runningTotal += c
            if let lastOne = list.last, lastOne.style == t.style {
                list[list.count - 1].length += c
            } else {
                list.append(TextRun(length: c, style: t.style))
            }
        }
        if runningTotal < total {
            if list.isEmpty { list.append(TextRun(length: total, style: style)) } else { list[list.count - 1].length += total - runningTotal }
        }
        if list.count == 1 {
            style = list[0].style
            textRuns = []
        } else {
            textRuns = list
        }
    }
}

extension Document {
    /// Object of the edit in progress.
    var objectBeingEdited: CanvasObject? {
        guard let textEditing else { return nil }
        return objects.first { $0.id == textEditing.id }
    }

    /// The text's point and the edit's stretch, read from the object as it is now (it may have been moved by the
    /// control bar during editing); without letters, the ones stored in the edit.
    var editAnchor: (origin: CGPoint, scale: CGSize)? {
        guard let edit = textEditing, let object = objectBeingEdited else { return nil }
        if object.emptyText { return (object.frame.standardized.origin, edit.scale) }
        return object.textAnchor
    }

    /// Text tool on an empty spot: new text, still without letters, with the 1st line's baseline at
    /// `point` (mm). It's already selected (the control bar shows the font), but only goes into
    /// undo when something is typed; if it ends up empty, it disappears.
    func newText(in point: CGPoint) {
        finishText()
        var text = defaultText
        text.content = ""
        text.textRuns = []
        let origin = CGPoint(x: point.x, y: point.y - (text.textLayout.lines.first?.ascender ?? 0) * TextBox.mmPerPt)
        saveState()
        var object = newObject(.text(text), frame: CGRect(origin: origin, size: .zero))
        object.layer = activeLayer
        // Writing on a hidden or locked layer shows and unlocks it (otherwise the text would disappear).
        if let i = layers.firstIndex(where: { $0.id == activeLayer }) {
            layers[i].visible = true
            layers[i].locked = false
        }
        objects.append(object)
        selection = [object.id]
        textEditing = TextEditing(id: object.id, origin: origin, scale: CGSize(width: 1, height: 1), click: nil)
    }

    /// Opens editing of an existing text; `click` (page mm) puts the cursor there.
    func editText(_ id: CanvasObject.ID, click: CGPoint?) {
        finishText()
        guard let object = objects.first(where: { $0.id == id }), !untouchable(object),
              let anchor = object.textAnchor else { return }
        saveState()
        selection = [id]
        activeLayer = layer(of: object).id
        textEditing = TextEditing(id: id, origin: anchor.origin, scale: anchor.scale, click: click)
    }

    /// What is in the canvas's invisible field becomes the object's text, letter by letter, with each run's style.
    func typeText(_ content: String, textRuns: [TextRun], emptyStyle: CharacterStyle?) {
        modifyEditing { $0.assign(content: content, textRuns: textRuns, emptyStyle: emptyStyle) }
    }

    /// Text shown in the Paragraph panel: the one being typed, the 1st selected text or the next texts'.
    var currentText: TextBox {
        if let object = objectBeingEdited, case .text(let t) = object.shape { return t }
        for object in selectedObjects { if case .text(let t) = object.shape { return t } }
        return defaultText
    }

    /// Style shown in the Character panel and the bar: the selected letters' on the canvas (the 1st), the cursor's
    /// (what will be typed), the 1st selected text's or the next texts'.
    var textStyle: CharacterStyle {
        if let object = objectBeingEdited, case .text(let t) = object.shape {
            if textSelection.length > 0 { return t.style(in: textSelection.location) }
            return typingStyle ?? t.style(in: max(textSelection.location - 1, 0))
        }
        for object in selectedObjects { if case .text(let t) = object.shape { return t.style(in: 0) } }
        return defaultText.style
    }

    /// Where a Character panel change goes (the panel's caption).
    enum StyleTarget { case letters, typing, texts, nextOnes }

    var styleTarget: StyleTarget {
        if objectBeingEdited != nil { return textSelection.length > 0 ? .letters : .typing }
        return currentTextObject == nil ? .nextOnes : .texts
    }

    /// The panels' text object (nil = no text selected: the panels change the next texts).
    var currentTextObject: CanvasObject? {
        objectBeingEdited ?? selectedObjects.first { if case .text = $0.shape { true } else { false } }
    }

    /// Character panel and control bar: while typing, they apply to the letters selected on the canvas (or, with the
    /// cursor still, to what is typed next); outside editing, to the whole selected texts;
    /// with none, to the next texts. It also becomes the default for the next ones (the last used, as in
    /// Illustrator).
    func changeStyle(_ change: (inout CharacterStyle) -> Void) {
        var defaultValue = defaultText.style
        change(&defaultValue)
        if defaultValue != defaultText.style { defaultText.style = defaultValue }

        if let object = objectBeingEdited, case .text(let text) = object.shape {
            let span = textSelection
            if span.length > 0 {
                modifyEditing { $0.apply(change, in: span) }
            } else {
                var e = typingStyle ?? text.style(in: max(span.location - 1, 0))
                change(&e)
                typingStyle = e
                // Text still empty: its style changes along (the cursor already shows the new size).
                if text.length == 0 { modifyEditing { $0.style = e } }
            }
            return
        }
        let changes = selectedObjects.contains { o in
            guard case .text(var text) = o.shape else { return false }
            let before = text
            text.apply(change)
            return text != before
        }
        guard changes else { return }
        modifySelection { o in
            guard case .text(var text) = o.shape, let anchor = o.textAnchor else { return }
            text.apply(change)
            o.replaceText(text, origin: anchor.origin, scale: anchor.scale)
        }
    }

    /// Paragraph panel (applies to the whole text): of the text being edited, of the selected texts or, with
    /// none, of the next texts. The text's point stays in place; when changing the alignment, the block doesn't
    /// move.
    func changeText(_ change: (inout TextBox) -> Void) {
        var defaultValue = defaultText
        change(&defaultValue)
        defaultValue.content = ""
        defaultValue.textRuns = []
        if defaultValue != defaultText { defaultText = defaultValue }

        if objectBeingEdited != nil {
            modifyEditing(change)
            return
        }
        let changes = selectedObjects.contains { o in
            guard case .text(var text) = o.shape else { return false }
            let before = text
            change(&text)
            return text != before
        }
        guard changes else { return }
        modifySelection { o in
            guard case .text(var text) = o.shape, let anchor = o.textAnchor else { return }
            let alignmentBefore = text.alignment, frameBefore = o.frame
            change(&text)
            o.replaceText(text, origin: anchor.origin, scale: anchor.scale)
            if text.alignment != alignmentBefore { o.frame.origin.x += frameBefore.minX - o.frame.minX }
        }
    }

    /// The Character panel's horizontal and vertical scales (1 = 100 %): they stretch the letters like the
    /// selection handles, from the text's point.
    func setTextScale(horizontal: Double? = nil, vertical: Double? = nil) {
        func newOne(_ current: CGSize) -> CGSize {
            CGSize(width: max(horizontal ?? current.width, 0.01), height: max(vertical ?? current.height, 0.01))
        }
        if let i = objects.firstIndex(where: { $0.id == textEditing?.id }), case .text(let text) = objects[i].shape,
           let anchor = editAnchor {
            let scale = newOne(anchor.scale)
            guard scale != anchor.scale else { return }
            registerEdit()
            objects[i].replaceText(text, origin: anchor.origin, scale: scale)
            textEditing?.origin = anchor.origin
            textEditing?.scale = scale
            return
        }
        guard selectedObjects.contains(where: { $0.textAnchor.map { newOne($0.scale) != $0.scale } ?? false }) else { return }
        modifySelection { o in
            guard case .text(let text) = o.shape, let anchor = o.textAnchor else { return }
            o.replaceText(text, origin: anchor.origin, scale: newOne(anchor.scale))
        }
    }

    /// Enter in a panel or bar field: the keyboard goes back to the text being edited on the canvas.
    func returnFocusToText() {
        if textEditing != nil { focusCanvasText += 1 }
    }

    /// Ends editing (click outside, Esc, another tool). `session`: only if it is still that edit — the
    /// invisible field reports after losing focus, when another edit may already have started.
    func finishText(session: UUID? = nil) {
        guard let edit = textEditing, session == nil || session == edit.session else { return }
        textEditing = nil
        textSelection = NSRange(location: 0, length: 0)
        typingStyle = nil
        discardSavedState()
        // Ended without letters: the text disappears (if it was already in undo, deleting is part of the same step).
        if let object = objects.first(where: { $0.id == edit.id }), object.emptyText {
            objects.removeAll { $0.id == edit.id }
            selection.remove(edit.id)
        }
    }

    /// Changes the text being edited keeping the text's point (read from the object now) and the stretch; changing the
    /// alignment doesn't move the block.
    private func modifyEditing(_ change: (inout TextBox) -> Void) {
        guard let i = objects.firstIndex(where: { $0.id == textEditing?.id }), case .text(var text) = objects[i].shape,
              let anchor = editAnchor else { return }
        let before = text, wasEmpty = objects[i].emptyText, frameBefore = objects[i].frame
        change(&text)
        guard text != before else { return }
        registerEdit()
        objects[i].replaceText(text, origin: anchor.origin, scale: anchor.scale)
        var origin = anchor.origin
        if text.alignment != before.alignment, !wasEmpty, !objects[i].emptyText {
            let dx = frameBefore.minX - objects[i].frame.minX
            objects[i].frame.origin.x += dx
            origin.x += dx
        }
        textEditing?.origin = origin
        textEditing?.scale = anchor.scale
    }

    /// The 1st change of an edit registers undo from before the edit; the others add to it.
    private func registerEdit() {
        guard textEditing?.registered == false else { return }
        registerSaved()
        textEditing?.registered = true
    }
}

// MARK: ⌘B, ⌘I and ⌘U

extension CharacterStyle {
    /// The face is bold (or italic).
    func has(_ trait: NSFontTraitMask) -> Bool { NSFontManager.shared.traits(of: ctFont() as NSFont).contains(trait) }

    /// The family's face with or without the trait; unchanged when the family has no such face.
    mutating func set(_ trait: NSFontTraitMask, _ on: Bool) {
        let manager = NSFontManager.shared, current = ctFont() as NSFont
        let converted = on ? manager.convert(current, toHaveTrait: trait) : manager.convert(current, toNotHaveTrait: trait)
        guard converted.familyName == current.familyName, converted.fontName != current.fontName else { return }
        postscript = converted.fontName
    }
}

extension Document {
    var hasTextSelected: Bool { selectedObjects.contains { if case .text = $0.shape { true } else { false } } }

    /// ⌘B, ⌘I and ⌘U (key "b", "i" or "u"): on the selected letters while typing, on the whole selected texts
    /// otherwise — turned on if the first letter doesn't have it, off if it does (as in a word processor).
    func toggleTextStyle(_ key: Character) {
        let current = textStyle
        switch key {
        case "b":
            let on = !current.has(.boldFontMask)
            changeStyle { $0.set(.boldFontMask, on) }
        case "i":
            let on = !current.has(.italicFontMask)
            changeStyle { $0.set(.italicFontMask, on) }
        default:
            let on = !current.underline
            changeStyle { $0.underline = on }
        }
    }
}
