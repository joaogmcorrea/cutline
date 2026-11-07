// The text of an imported PDF (Model/PDFImport.swift): the letters come in as paths, drawn from the fonts embedded in
// the PDF (Model/PDFFonts.swift), with the common painting rule (Model/VectorImport.swift): text painted with a fill
// becomes a print-only fill, text painted with a stroke (Tr 1, 2, 5, 6) a cut line. Invisible text (Tr 3, the OCR layer
// of a scan) and text with a transparent paint stay out; text used as a clipping path (Tr 4 to 7) clips what comes
// after it, like any clipping path (Model/ImportClipping.swift). The letters of one text object (BT … ET) with the
// same paint become one object, named after the text. Type 3 glyphs run their own content: an uncolored one (d1) gives
// its shapes to the text's paint, a colored one (d0, such as an emoji) comes in as its own paths and images.
import CoreGraphics
import Foundation

nonisolated extension PDFImport.Reader {
    /// The text matrices (between BT and ET) and the letters that clip at ET.
    struct TextObject {
        var matrix = CGAffineTransform.identity
        var line = CGAffineTransform.identity
        var clip = CGMutablePath()
        var clips = false
        /// Where the last letter ended, in user space: a next letter far from it starts a new word (in the name).
        var end: CGPoint?
    }

    /// Letters waiting to become one object: same paint, same clip.
    struct TextRun {
        var path = CGMutablePath()
        var fill: CMYK?
        var stroke: CMYK?
        /// The stroke's width (pt, at the page's scale).
        var width: Double
        var clip: ImportClipping.Region?
        var text = ""
    }

    /// What an uncolored Type 3 glyph (d1) paints, in page mm. `colored` (d0): it paints with its own colors instead.
    final class GlyphCapture {
        var colored = false
        let fill = CGMutablePath()
        let stroke = CGMutablePath()
        var strokeWidth = 0.0
    }

    /// The glyph paints with the text's colors: the color operators inside it don't count.
    var ignoresColor: Bool { glyph.map { !$0.colored } ?? false }

    // MARK: Showing text

    func show(_ string: CGPDFStringRef) {
        guard let start = CGPDFStringGetBytePtr(string) else { return }
        show(Array(UnsafeBufferPointer(start: start, count: CGPDFStringGetLength(string))))
    }

    func show(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        guard let font = state.font, let glyphs = font.glyphs(bytes) else {
            // Invisible text (an OCR layer) that can't be read is no loss.
            if state.renderMode != 3 { texts += 1 }
            return
        }
        let h = state.horizontalScale
        let fontSpace = CGAffineTransform(a: state.fontSize * h, b: 0, c: 0, d: state.fontSize, tx: 0, ty: state.rise)
        for glyph in glyphs {
            let toUser = fontSpace.concatenating(text.matrix).concatenating(state.ctm)
            // A jump of more than 0.4 em from where the last letter ended (a new line, a gap) separates words.
            let origin = CGPoint.zero.applying(toUser)
            if let end = text.end, hypot(origin.x - end.x, origin.y - end.y) > 0.4 * hypot(toUser.c, toUser.d),
               let last = run?.text.last, !last.isWhitespace {
                run?.text += " "
            }
            paint(glyph, of: font, toUser: toUser)
            let advance = (glyph.width * state.fontSize + state.charSpacing + (glyph.isSpace ? state.wordSpacing : 0)) * h
            text.matrix = CGAffineTransform(translationX: advance, y: 0).concatenating(text.matrix)
            text.end = CGPoint.zero.applying(fontSpace.concatenating(text.matrix).concatenating(state.ctm))
        }
    }

    /// TJ's numbers: a move back, in thousandths of the font size.
    func adjust(_ amount: Double) {
        let tx = -amount / 1000 * state.fontSize * state.horizontalScale
        text.matrix = CGAffineTransform(translationX: tx, y: 0).concatenating(text.matrix)
    }

    /// Td, TD, T*, Tm: a new line, or a jump.
    func moveText(to matrix: CGAffineTransform) {
        text.line = matrix
        text.matrix = matrix
    }

    private func paint(_ glyph: PDFFont.Glyph, of font: PDFFont, toUser: CGAffineTransform) {
        let mode = state.renderMode
        guard mode != 3 else { return }
        if let procedure = glyph.procedure {
            let capture = runGlyph(procedure, of: font, toUser: toUser)
            guard !capture.colored else { return }
            if capture.fill.isEmpty, capture.stroke.isEmpty {
                run?.text += glyph.text.isEmpty ? " " : glyph.text
                return
            }
            if mode >= 4 {
                text.clip.addPath(capture.fill)
                text.clips = true
            }
            guard mode != 7 else { return }
            if !capture.fill.isEmpty { addLetters(capture.fill, fill: true, stroke: false, text: glyph.text) }
            if !capture.stroke.isEmpty {
                addLetters(capture.stroke, fill: false, stroke: true, text: capture.fill.isEmpty ? glyph.text : "",
                           width: capture.strokeWidth)
            }
            return
        }
        guard glyph.index != 0, let outline = font.path(glyph.index), let page = outline.copy(using: [toUser.concatenating(toPage)])
        else {
            // A blank glyph (a space, also when the PDF doesn't say what it means).
            run?.text += glyph.text.isEmpty ? " " : glyph.text
            return
        }
        if mode >= 4 {
            text.clip.addPath(page)
            text.clips = true
        }
        addLetters(page, fill: [0, 2, 4, 6].contains(mode), stroke: [1, 2, 5, 6].contains(mode), text: glyph.text)
    }

    /// A letter (page mm) into the run, which becomes a new one when the paint or the clip changes.
    private func addLetters(_ page: CGPath, fill: Bool, stroke: Bool, text: String, width: Double? = nil) {
        let fillColor = fill && state.fillAlpha > 0 ? state.fill : nil
        let strokeColor = stroke && state.strokeAlpha > 0 ? state.strokeColor : nil
        guard fillColor != nil || strokeColor != nil else { return }
        let scale = sqrt(abs(state.ctm.a * state.ctm.d - state.ctm.b * state.ctm.c))
        let strokeWidth = width ?? state.strokeWidth * scale
        if let current = run, current.fill == fillColor, current.stroke == strokeColor,
           strokeColor == nil || current.width == strokeWidth, current.clip?.path === state.clip?.path {
            run?.path.addPath(page)
            run?.text += text
            return
        }
        flushText()
        run = TextRun(fill: fillColor, stroke: strokeColor, width: strokeWidth, clip: state.clip, text: text)
        run?.path.addPath(page)
    }

    /// The letters waiting become objects (before anything else is painted, and at ET).
    func flushText() {
        guard let current = run else { return }
        run = nil
        guard !current.path.isEmpty else { return }
        let made = ImportClipping.objects(current.path, strokeColor: current.stroke, strokeWidth: current.width,
                                          fill: current.fill, evenOdd: false, clip: current.clip)
        let words = current.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let label = words.isEmpty ? nil : words.count > 60 ? String(words.prefix(59)) + "…" : words
        objects += made.map { object in
            var object = object
            object.label = label
            return object
        }
        textObjects += made.count
    }

    /// ET: the letters become objects, and those drawn in a clipping mode clip from now on.
    func endText() {
        flushText()
        if text.clips { clip(to: text.clip, rule: .winding) }
        text = TextObject()
    }

    /// Runs a Type 3 glyph's content stream at its place (glyph space → user space: FontMatrix, then the text's).
    private func runGlyph(_ procedure: CGPDFStreamRef, of font: PDFFont, toUser: CGAffineTransform) -> GlyphCapture {
        let capture = GlyphCapture()
        guard let content = contents.last, let resources = font.resources?.ref ?? CGPDFStreamGetDictionary(procedure) else { return capture }
        let saved = (state, text, shapePath, pendingClip, glyph)
        state.ctm = font.fontMatrix.concatenating(toUser)
        shapePath = CGMutablePath()
        pendingClip = nil
        glyph = capture
        let nested = CGPDFContentStreamCreateWithStream(procedure, resources, content)
        read(nested)
        CGPDFContentStreamRelease(nested)
        (state, text, shapePath, pendingClip, glyph) = saved
        return capture
    }

    /// A painting operator inside an uncolored Type 3 glyph: its shapes go to the glyph (fills as they are, even-odd
    /// ones without their overlaps, so the text's nonzero rule paints them the same).
    func capture(_ page: CGPath, stroke: Bool, fill: Bool, evenOdd: Bool) {
        guard let glyph else { return }
        if fill { glyph.fill.addPath(evenOdd ? page.normalized(using: .evenOdd) : page) }
        if stroke {
            glyph.stroke.addPath(page)
            glyph.strokeWidth = state.strokeWidth * sqrt(abs(state.ctm.a * state.ctm.d - state.ctm.b * state.ctm.c))
        }
    }

    /// The font of a Tf, read once per font dictionary; nil = its glyphs can't be had.
    func font(named name: UnsafePointer<CChar>) -> PDFFont? {
        guard let content = contents.last, let object = CGPDFContentStreamGetResource(content, "Font", name),
              let dictionary = PDFDict(object) else { return nil }
        if let known = fonts[dictionary.ref] { return known }
        let font = PDFFont.load(dictionary)
        fonts[dictionary.ref] = font
        return font
    }

    // MARK: Operators

    static func registerText(_ t: CGPDFOperatorTableRef) {
        CGPDFOperatorTableSetCallback(t, "BT") { _, info in textReader(info)?.text = TextObject() }
        CGPDFOperatorTableSetCallback(t, "ET") { _, info in textReader(info)?.endText() }
        CGPDFOperatorTableSetCallback(t, "Tf") { s, info in
            guard let l = textReader(info) else { return }
            var size: CGPDFReal = 0
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopNumber(s, &size), CGPDFScannerPopName(s, &name), let name else { return }
            l.state.fontSize = Double(size)
            l.state.font = l.font(named: name)
        }
        CGPDFOperatorTableSetCallback(t, "Tc") { s, info in textReader(info)?.state.charSpacing = operand(s) ?? 0 }
        CGPDFOperatorTableSetCallback(t, "Tw") { s, info in textReader(info)?.state.wordSpacing = operand(s) ?? 0 }
        CGPDFOperatorTableSetCallback(t, "Tz") { s, info in textReader(info)?.state.horizontalScale = (operand(s) ?? 100) / 100 }
        CGPDFOperatorTableSetCallback(t, "TL") { s, info in textReader(info)?.state.leading = operand(s) ?? 0 }
        CGPDFOperatorTableSetCallback(t, "Ts") { s, info in textReader(info)?.state.rise = operand(s) ?? 0 }
        CGPDFOperatorTableSetCallback(t, "Tr") { s, info in textReader(info)?.state.renderMode = Int(operand(s) ?? 0) }
        CGPDFOperatorTableSetCallback(t, "Td") { s, info in
            guard let l = textReader(info), let ty = operand(s), let tx = operand(s) else { return }
            l.moveText(to: CGAffineTransform(translationX: tx, y: ty).concatenating(l.text.line))
        }
        CGPDFOperatorTableSetCallback(t, "TD") { s, info in
            guard let l = textReader(info), let ty = operand(s), let tx = operand(s) else { return }
            l.state.leading = -ty
            l.moveText(to: CGAffineTransform(translationX: tx, y: ty).concatenating(l.text.line))
        }
        CGPDFOperatorTableSetCallback(t, "Tm") { s, info in
            guard let l = textReader(info) else { return }
            var v = [Double](repeating: 0, count: 6)
            for i in stride(from: 5, through: 0, by: -1) {
                guard let x = operand(s) else { return }
                v[i] = x
            }
            l.moveText(to: CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]))
        }
        CGPDFOperatorTableSetCallback(t, "T*") { _, info in textReader(info)?.nextLine() }
        CGPDFOperatorTableSetCallback(t, "Tj") { s, info in
            var string: CGPDFStringRef?
            guard let l = textReader(info), CGPDFScannerPopString(s, &string), let string else { return }
            l.show(string)
        }
        CGPDFOperatorTableSetCallback(t, "'") { s, info in
            var string: CGPDFStringRef?
            guard let l = textReader(info), CGPDFScannerPopString(s, &string), let string else { return }
            l.nextLine()
            l.show(string)
        }
        CGPDFOperatorTableSetCallback(t, "\"") { s, info in
            var string: CGPDFStringRef?
            guard let l = textReader(info), CGPDFScannerPopString(s, &string), let string,
                  let charSpacing = operand(s), let wordSpacing = operand(s) else { return }
            l.state.wordSpacing = wordSpacing
            l.state.charSpacing = charSpacing
            l.nextLine()
            l.show(string)
        }
        CGPDFOperatorTableSetCallback(t, "TJ") { s, info in
            var array: CGPDFArrayRef?
            guard let l = textReader(info), CGPDFScannerPopArray(s, &array), let array else { return }
            for i in 0..<CGPDFArrayGetCount(array) {
                var string: CGPDFStringRef?
                var amount: CGPDFReal = 0
                if CGPDFArrayGetString(array, i, &string), let string {
                    l.show(string)
                } else if CGPDFArrayGetNumber(array, i, &amount) {
                    l.adjust(Double(amount))
                }
            }
        }
        // Type 3 glyphs: d0 = colored (its own colors and images), d1 = uncolored (the text's colors).
        CGPDFOperatorTableSetCallback(t, "d0") { _, info in textReader(info)?.glyph?.colored = true }
        CGPDFOperatorTableSetCallback(t, "d1") { _, info in textReader(info)?.glyph?.colored = false }
    }

    func nextLine() {
        moveText(to: CGAffineTransform(translationX: 0, y: -state.leading).concatenating(text.line))
    }
}

// Free functions: CGPDFScanner's callbacks are C function pointers and can't capture anything.
private nonisolated func textReader(_ info: UnsafeMutableRawPointer?) -> PDFImport.Reader? {
    info.map { Unmanaged<PDFImport.Reader>.fromOpaque($0).takeUnretainedValue() }
}

/// The number on top of the operand stack.
private nonisolated func operand(_ scanner: CGPDFScannerRef) -> Double? {
    var x: CGPDFReal = 0
    return CGPDFScannerPopNumber(scanner, &x) ? Double(x) : nil
}
