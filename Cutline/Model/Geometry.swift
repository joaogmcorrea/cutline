// Shape outlines (in mm) and the conversion between page mm and canvas points.
import CoreText
import SwiftUI

extension CanvasObject {
    /// Outline in mm, page coordinates.
    var shapePath: Path {
        let r = frame.standardized
        switch shape {
        case .rectangle(let radius):
            // Circular-arc corners (like Illustrator's), not iOS's "continuous" corner.
            return Path(roundedRect: r, cornerRadius: min(max(radius, 0), min(r.width, r.height) / 2), style: .circular)
        case .ellipse:
            return Path(ellipseIn: r)
        case .star(let points, let inner):
            return Self.star(in: r, points: points, innerRadius: inner)
        case .shapePath(let subpaths):
            return Self.shapePath(subpaths, in: r)
        case .text(let text):
            // No letters (only while typing a new text): nothing to draw or cut.
            guard let contour = text.contour else { return Path() }
            let natural = contour.boundingBoxOfPath
            let adjustment = CGAffineTransform(translationX: -natural.minX, y: -natural.minY)
                .concatenating(CGAffineTransform(scaleX: r.width / max(natural.width, 0.001), y: r.height / max(natural.height, 0.001)))
                .concatenating(CGAffineTransform(translationX: r.minX, y: r.minY))
            return Path(contour.copy(using: [adjustment]) ?? contour)
        }
    }

    /// Subpaths with coordinates in page mm (any shape; the parametric ones become a path).
    var absoluteNodes: [Subpath] {
        if case .shapePath(let subs) = shape {
            let t = frameToPage
            return subs.map { s in
                Subpath(nodes: s.nodes.map { Node(point: $0.point.applying(t), input: $0.input?.applying(t), output: $0.output?.applying(t)) },
                           closed: s.closed)
            }
        }
        guard let free = CanvasObject.freePath(shapePath.cgPath) else { return [] }
        return CanvasObject(shape: .shapePath(free.subpaths), frame: free.frame).absoluteNodes
    }

    /// Replaces the shape with a free path with these nodes (in page mm); the frame follows.
    mutating func setNodes(_ absolutes: [Subpath]) {
        let path = Self.shapePath(absolutes, in: CGRect(x: 0, y: 0, width: 1, height: 1)).cgPath
        guard let free = CanvasObject.freePath(path) else { return }
        shape = .shapePath(free.subpaths)
        frame = free.frame
    }

    /// Snap points: path nodes; for other shapes, the frame's corners, midpoints and center.
    var anchors: [CGPoint] {
        if case .shapePath = shape { return absoluteNodes.flatMap { $0.nodes.map(\.point) } }
        let r = frame.standardized
        return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.midX, y: r.midY), CGPoint(x: r.maxX, y: r.midY),
                CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
    }

    /// Frame unit (0…1) → page mm.
    var frameToPage: CGAffineTransform {
        let r = frame.standardized
        return CGAffineTransform(a: r.width, b: 0, c: 0, d: r.height, tx: r.minX, ty: r.minY)
    }

    static func shapePath(_ subpaths: [Subpath], in r: CGRect) -> Path {
        let mm = { (p: CGPoint) in CGPoint(x: r.minX + p.x * r.width, y: r.minY + p.y * r.height) }
        var path = Path()
        for sub in subpaths where !sub.nodes.isEmpty {
            path.move(to: mm(sub.nodes[0].point))
            let n = sub.nodes.count
            for i in 0..<(sub.closed ? n : n - 1) {
                let a = sub.nodes[i], b = sub.nodes[(i + 1) % n]
                if a.output == nil, b.input == nil {
                    path.addLine(to: mm(b.point))
                } else {
                    path.addCurve(to: mm(b.point), control1: mm(a.output ?? a.point), control2: mm(b.input ?? b.point))
                }
            }
            if sub.closed { path.closeSubpath() }
        }
        return path
    }

    /// Star with the first point up, stretched to fill the frame exactly.
    static func star(in r: CGRect, points: Int, innerRadius: Double) -> Path {
        let n = max(3, points)
        let unitOnes = (0..<(2 * n)).map { i -> CGPoint in
            let radius = i % 2 == 0 ? 1 : min(max(innerRadius, 0.05), 1)
            let a = -Double.pi / 2 + Double(i) * Double.pi / Double(n)
            return CGPoint(x: radius * cos(a), y: radius * sin(a))
        }
        let minX = unitOnes.map(\.x).min()!, maxX = unitOnes.map(\.x).max()!
        let minY = unitOnes.map(\.y).min()!, maxY = unitOnes.map(\.y).max()!
        var path = Path()
        for (i, p) in unitOnes.enumerated() {
            let q = CGPoint(x: r.minX + (p.x - minX) / (maxX - minX) * r.width,
                            y: r.minY + (p.y - minY) / (maxY - minY) * r.height)
            if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
        }
        path.closeSubpath()
        return path
    }
}

/// The page's position and scale on the canvas.
struct ViewState: Equatable {
    static let pointsPerMM = 72.0 / 25.4

    /// 1 = actual size (100%).
    var zoom = 1.0
    /// Where the page's (0, 0) is, in canvas points.
    var origin = CGPoint.zero
    /// False while the user doesn't touch the zoom or the position: the page refits to the window.
    var manual = false

    var scale: Double { zoom * Self.pointsPerMM }
    var transform: CGAffineTransform { CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: origin.x, ty: origin.y) }

    func canvas(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale) }
    func canvas(_ r: CGRect) -> CGRect { r.applying(transform) }
    func mm(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - origin.x) / scale, y: (p.y - origin.y) / scale) }

    static let minZoom = 0.1, maxZoom = 16.0

    /// Changes the zoom keeping the canvas point `anchor` fixed.
    mutating func zoomIn(to updated: Double, anchor: CGPoint) {
        let z = min(max(updated, Self.minZoom), Self.maxZoom)
        let factor = z / zoom
        manual = true
        origin = CGPoint(x: anchor.x - (anchor.x - origin.x) * factor, y: anchor.y - (anchor.y - origin.y) * factor)
        zoom = z
    }

    /// The whole page (with the mat) inside the free area.
    mutating func adjust(in area: CGRect) {
        let m = Document.matMargin
        let base = CGSize(width: Document.page.width + 2 * m, height: Document.page.height + 2 * m)
        let fitScale = min(area.width / base.width, area.height / base.height)
        zoom = min(max(fitScale / Self.pointsPerMM, Self.minZoom), Self.maxZoom)
        let size = CGSize(width: Document.page.width * scale, height: Document.page.height * scale)
        origin = CGPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2)
        manual = false
    }

    mutating func offsetBy(dx: Double, dy: Double) {
        origin.x += dx
        origin.y += dy
        manual = true
    }
}

extension CGRect {
    /// Rectangle between two points; with `proportional`, a square; with `fromCenter`, `a` is the center.
    static func between(_ a: CGPoint, _ b: CGPoint, proportional: Bool, fromCenter: Bool) -> CGRect {
        var dx = b.x - a.x, dy = b.y - a.y
        if proportional {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        if fromCenter { return CGRect(x: a.x - abs(dx), y: a.y - abs(dy), width: 2 * abs(dx), height: 2 * abs(dy)) }
        return CGRect(x: a.x, y: a.y, width: dx, height: dy).standardized
    }
}

extension CharacterStyle {
    /// Superscript and subscript: reduced size (58.3 %) and the distance from the baseline (33.3 % of the size).
    static let positionFactor = 0.583, positionHeight = 0.333

    /// Size the letters are drawn at.
    var effectivePointSize: Double { position == .normal ? size : size * Self.positionFactor }

    /// How much the run's baseline rises (pt): offset + superscript/subscript.
    var rise: Double {
        switch position {
        case .normal: offset
        case .superscripted: offset + size * Self.positionHeight
        case .subscripted: offset - size * Self.positionHeight
        }
    }

    /// Font at the requested size: the chosen face (PostScript) or the family's regular one. A font that isn't
    /// installed falls back to the system's (CoreText picks another).
    func ctFont(pointSize: Double? = nil) -> CTFont {
        let pointSize = pointSize ?? size
        if let postscript {
            let font = CTFontCreateWithName(postscript as CFString, pointSize, nil)
            if CTFontCopyPostScriptName(font) as String == postscript { return font }
        }
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: font] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, pointSize, nil)
    }

    /// Automatic leading: 115 % of the font's height (Cutline's usual).
    var autoLeading: Double { Self.autoLeading(ctFont()) }

    static func autoLeading(_ f: CTFont) -> Double {
        (CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f)) * 1.15
    }
}

/// Cutline's own attributes of the CoreText runs (they go to the CTRuns along with the font).
private extension NSAttributedString.Key {
    static let rise = NSAttributedString.Key("cutline.subida")
    static let rotation = NSAttributedString.Key("cutline.rotacao")
    static let underline = NSAttributedString.Key("cutline.sublinhado")
    static let strikethrough = NSAttributedString.Key("cutline.tachado")
    static let leading = NSAttributedString.Key("cutline.entrelinha")
}

extension TextBox {
    /// Body pt → mm.
    static let mmPerPt = 25.4 / 72

    /// Length in UTF-16.
    var length: Int { (content as NSString).length }

    /// Runs covering the whole text (a single one, with `style`, when it is uniform).
    var completeRuns: [TextRun] {
        textRuns.isEmpty ? (length > 0 ? [TextRun(length: length, style: style)] : []) : textRuns
    }

    /// Style of the letter at the position (UTF-16); empty text = `style`.
    func style(in index: Int) -> CharacterStyle {
        var end = 0
        for t in textRuns {
            end += t.length
            if index < end { return t.style }
        }
        return textRuns.last?.style ?? style
    }

    /// Largest size in the text (slack for editing on the canvas).
    var largestSize: Double { completeRuns.map(\.style.size).max() ?? style.size }

    /// Lines as CoreText sets them, in body pt, y down: the top of the 1st line at y = 0 and x = 0 at the
    /// text's point (start of the lines on the left, middle in the center, end on the right). Used for the letters'
    /// outline and for the cursor, selection and clicks of editing on the canvas — so both always match.
    struct TextLayout {
        struct Row {
            let ct: CTLine
            /// Position in the whole string, in UTF-16 (like the text field's NSRange).
            let start: Int
            let length: Int
            /// Where the line's text starts.
            let x: Double
            let base: Double
            /// Height above and below the baseline (the line's largest letter, with the offset).
            let ascender: Double
            let descender: Double
            /// Width without the trailing spaces (alignment, underline) and with them (click area).
            let width: Double
            let totalWidth: Double
            /// The paragraph's bullet or number (outside the string: it can't be selected).
            let bullet: CTLine?
            let bulletX: Double
            var end: Int { start + length }
            var top: Double { base - ascender }
            var foot: Double { base + descender }
        }

        /// Font and rise of each run (UTF-16), for the cursor height.
        struct FontSpan {
            let start: Int
            let end: Int
            let font: CTFont
            let rise: Double
        }

        let lines: [Row]
        let fontSpans: [FontSpan]

        var minX: Double { lines.map { $0.bullet == nil ? $0.x : min($0.x, $0.bulletX) }.min() ?? 0 }
        var maxX: Double { lines.map { $0.x + $0.totalWidth }.max() ?? 0 }
        var height: Double { lines.last?.foot ?? 0 }

        /// The line where the position (UTF-16) is, and its x.
        func position(_ index: Int) -> (line: Int, x: Double) {
            let i = lines.firstIndex { index <= $0.end } ?? lines.count - 1
            let local = min(max(index - lines[i].start, 0), lines[i].length)
            return (i, lines[i].x + CTLineGetOffsetForStringIndex(lines[i].ct, local, nil))
        }

        /// Cursor at the position: x, top and foot, at the height of the letter before it (or of the line, if empty).
        func cursor(_ index: Int) -> (x: Double, top: Double, foot: Double) {
            let (i, x) = position(index)
            let line = lines[i]
            let reference = index > line.start ? index - 1 : index
            guard line.length > 0, let pointSize = fontSpans.first(where: { reference >= $0.start && reference < $0.end }) else {
                return (x, line.top, line.foot)
            }
            return (x, line.base - CTFontGetAscent(pointSize.font) - pointSize.rise, line.base + CTFontGetDescent(pointSize.font) - pointSize.rise)
        }

        /// Position (UTF-16) closest to a point (body pt).
        func index(in p: CGPoint) -> Int {
            var i = lines.count - 1
            for k in 0..<(lines.count - 1) where p.y < (lines[k].foot + lines[k + 1].top) / 2 {
                i = k
                break
            }
            let line = lines[i]
            let local = CTLineGetStringIndexForPosition(line.ct, CGPoint(x: p.x - line.x, y: 0))
            return line.start + min(max(local == kCFNotFound ? 0 : local, 0), line.length)
        }

        /// Position on the line above (−1) or below (+1), at the same x (↑ ↓ arrows).
        func neighbor(_ of: Int, _ orientation: Int) -> Int {
            let (i, x) = position(of)
            let target = i + orientation
            guard lines.indices.contains(target) else { return orientation < 0 ? 0 : lines.last?.end ?? 0 }
            return index(in: CGPoint(x: x, y: lines[target].base))
        }
    }

    @MainActor private static var layouts: [TextBox: TextLayout] = [:]
    @MainActor private static var contours: [TextBox: CGPath] = [:]
    @MainActor private static var fontSmallCaps: [String: Bool] = [:]

    /// Fonts activated or deactivated (Adobe Fonts, Font Book): redoes the letters with the current ones.
    @MainActor static func forgetFonts() {
        layouts = [:]
        contours = [:]
        fontSmallCaps = [:]
    }

    /// The font with real small caps (the OpenType "smcp" feature).
    private static func withSmallCaps(_ font: CTFont) -> CTFont {
        let feature = [kCTFontOpenTypeFeatureTag as String: "smcp", kCTFontOpenTypeFeatureValue as String: 1] as [String: Any]
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFeatureSettingsAttribute as String: [feature]] as CFDictionary)
        return CTFontCreateCopyWithAttributes(font, 0, nil, descriptor)
    }

    /// Does the font have its own small caps? (Otherwise they're made with capitals at 70 %, as in Illustrator.)
    private static func hasSmallCaps(_ font: CTFont) -> Bool {
        let name = CTFontCopyPostScriptName(font) as String
        if let known = fontSmallCaps[name] { return known }
        func glyphs(_ f: CTFont) -> [CGGlyph] {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "abc", attributes: [.font: f]))
            return (CTLineGetGlyphRuns(line) as? [CTRun] ?? []).flatMap { glyphRun in
                var g = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(glyphRun))
                CTRunGetGlyphs(glyphRun, CFRange(location: 0, length: g.count), &g)
                return g
            }
        }
        let has = glyphs(font) != glyphs(withSmallCaps(font))
        fontSmallCaps[name] = has
        return has
    }

    /// CoreText attributes of a run (font at the effective size, kerning, tracking) and Cutline's own.
    private static func attributes(_ e: CharacterStyle) -> [NSAttributedString.Key: Any] {
        let pointSize = e.effectivePointSize
        var a: [NSAttributedString.Key: Any] = [.font: e.ctFont(pointSize: pointSize), .rise: e.rise, .rotation: e.rotation,
                                                .underline: e.underline, .strikethrough: e.strikethrough]
        // Fixed kerning turns off the font's (0 = no kerning); tracking adds to the font's kerning.
        if let kerning = e.kerning { a[NSAttributedString.Key(kCTKernAttributeName as String)] = kerning / 1000 * pointSize }
        if e.tracking != 0 { a[NSAttributedString.Key(kCTTrackingAttributeName as String)] = e.tracking / 1000 * pointSize }
        if let leading = e.leading { a[.leading] = leading }
        return a
    }

    /// A run as it is drawn: all caps and small caps swap letters without changing the length (the cursor
    /// indices still apply).
    private static func show(_ chunk: String, _ e: CharacterStyle) -> NSAttributedString {
        let attributes = attributes(e)
        guard e.allCaps || e.smallCaps else { return NSAttributedString(string: chunk, attributes: attributes) }
        let font = attributes[.font] as! CTFont
        if !e.allCaps, hasSmallCaps(font) {
            var withFont = attributes
            withFont[.font] = withSmallCaps(font)
            return NSAttributedString(string: chunk, attributes: withFont)
        }
        var small = attributes
        small[.font] = CTFontCreateCopyWithAttributes(font, e.effectivePointSize * 0.7, nil, nil)
        let result = NSMutableAttributedString()
        for letter in chunk {
            let original = String(letter), uppercase = original.uppercased()
            let swap = uppercase != original && uppercase.utf16.count == original.utf16.count
            result.append(NSAttributedString(string: swap ? uppercase : original,
                                                attributes: swap && !e.allCaps ? small : attributes))
        }
        return result
    }

    var textLayout: TextLayout {
        if let ready = Self.layouts[self] { return ready }
        let text = content as NSString
        // Runs with start and end (UTF-16) and the fonts for the cursor height.
        var ranges: [(start: Int, end: Int, style: CharacterStyle)] = [], runningTotal = 0
        for t in completeRuns {
            ranges.append((runningTotal, runningTotal + t.length, t.style))
            runningTotal += t.length
        }
        let fontSpans = ranges.map { TextLayout.FontSpan(start: $0.start, end: $0.end, font: $0.style.ctFont(pointSize: $0.style.effectivePointSize),
                                                    rise: $0.style.rise) }

        struct Raw {
            let ct: CTLine, start: Int, length: Int, width: Double, total: Double, bullet: CTLine?
            let ascender: Double, descender: Double, step: Double
        }
        var raw: [Raw] = [], start = 0, number = 0
        for line in text.components(separatedBy: "\n") {
            let length = (line as NSString).length
            let end = start + length
            let shown = NSMutableAttributedString()
            for f in ranges where f.end > start && f.start < end {
                let a = max(f.start, start), b = min(f.end, end)
                shown.append(Self.show(text.substring(with: NSRange(location: a, length: b - a)), f.style))
            }
            let ct = CTLineCreateWithAttributedString(shown)
            let total = CTLineGetTypographicBounds(ct, nil, nil, nil)
            // The line's heights and leading: those of the largest letter (as in Illustrator); empty, those of the style there.
            var ascender = 0.0, descender = 0.0, step = 0.0
            let glyphRuns = CTLineGetGlyphRuns(ct) as? [CTRun] ?? []
            for glyphRun in glyphRuns {
                let attributes = CTRunGetAttributes(glyphRun) as NSDictionary
                let font = attributes[kCTFontAttributeName as String].map { $0 as! CTFont } ?? style.ctFont()
                let rise = attributes[NSAttributedString.Key.rise.rawValue] as? Double ?? 0
                ascender = max(ascender, CTFontGetAscent(font) + rise)
                descender = max(descender, CTFontGetDescent(font) - rise)
                step = max(step, attributes[NSAttributedString.Key.leading.rawValue] as? Double
                            ?? CharacterStyle.autoLeading(font))
            }
            let here = style(in: length > 0 ? start : max(start - 1, 0))
            if glyphRuns.isEmpty {
                let font = here.ctFont(pointSize: here.effectivePointSize)
                ascender = CTFontGetAscent(font) + here.rise
                descender = CTFontGetDescent(font) - here.rise
                step = here.leading ?? CharacterStyle.autoLeading(font)
            }
            var bullet: CTLine?
            if self.bullet != .plain, !line.allSatisfy(\.isWhitespace) {
                number += 1
                let sign = self.bullet == .dot ? "•" : "\(number)."
                bullet = CTLineCreateWithAttributedString(NSAttributedString(string: sign, attributes: [.font: here.ctFont()]))
            }
            raw.append(Raw(ct: ct, start: start, length: length, width: total - CTLineGetTrailingWhitespaceWidth(ct),
                                total: total, bullet: bullet, ascender: ascender, descender: descender, step: step))
            start = end + 1
        }
        // Bullet column: the widest one's (1. to 10. aligned) and half an em of slack to the text.
        let bulletWidth = raw.compactMap { $0.bullet.map { CTLineGetTypographicBounds($0, nil, nil, nil) } }.max()
        let column = bulletWidth.map { $0 + style(in: 0).size * 0.5 } ?? 0
        var lines: [TextLayout.Row] = [], base = 0.0
        for (i, b) in raw.enumerated() {
            base = i == 0 ? b.ascender : base + b.step + spaceBefore + spaceAfter
            let busy = column + b.width
            let startOffset: Double = switch alignment {
            case .left: leftIndent + firstLineIndent
            case .center: (leftIndent + firstLineIndent - rightIndent) / 2 - busy / 2
            case .right: -rightIndent - busy
            }
            lines.append(.init(ct: b.ct, start: b.start, length: b.length, x: startOffset + column, base: base,
                                ascender: b.ascender, descender: b.descender, width: b.width, totalWidth: b.total,
                                bullet: b.bullet, bulletX: startOffset))
        }
        let ready = TextLayout(lines: lines, fontSpans: fontSpans)
        // Typing on the canvas goes through many intermediate texts: the cache doesn't grow without limit.
        if Self.layouts.count > 300 { Self.layouts = [:] }
        Self.layouts[self] = ready
        return ready
    }

    /// The letters' outline in mm, y down, in the same system as the layout (nil without letters).
    var contour: CGPath? {
        if let isReady = Self.contours[self] { return isReady }
        let d = textLayout
        let mm = Self.mmPerPt
        let path = CGMutablePath()

        func letters(_ line: CTLine, x: Double, base: Double, ranges limitValue: Double? = nil) {
            for glyphRun in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                let n = CTRunGetGlyphCount(glyphRun)
                var glyphs = [CGGlyph](repeating: 0, count: n), positions = [CGPoint](repeating: .zero, count: n)
                CTRunGetGlyphs(glyphRun, CFRange(location: 0, length: n), &glyphs)
                CTRunGetPositions(glyphRun, CFRange(location: 0, length: n), &positions)
                let attributes = CTRunGetAttributes(glyphRun) as NSDictionary
                let font = attributes[kCTFontAttributeName as String].map { $0 as! CTFont } ?? style.ctFont()
                let rise = attributes[NSAttributedString.Key.rise.rawValue] as? Double ?? 0
                let spin = (attributes[NSAttributedString.Key.rotation.rawValue] as? Double ?? 0) * .pi / 180
                for (glyph, position) in zip(glyphs, positions) {
                    // The font's y up from the baseline → mm with y down.
                    var t = CGAffineTransform(a: mm, b: 0, c: 0, d: -mm, tx: (x + position.x) * mm, ty: (base - position.y - rise) * mm)
                    if spin != 0 {
                        var box = CGRect.zero
                        var g = glyph
                        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &g, &box, 1)
                        t = CGAffineTransform(translationX: box.midX, y: box.midY).rotated(by: spin)
                            .translatedBy(x: -box.midX, y: -box.midY).concatenating(t)
                    }
                    if let letter = CTFontCreatePathForGlyph(font, glyph, &t) { path.addPath(letter) }
                }
                // The run's underline and strikethrough, to the end of the line's letters (without trailing spaces).
                guard let limitValue, n > 0 else { continue }
                let startOffset = x + positions[0].x
                let final = min(startOffset + CTRunGetTypographicBounds(glyphRun, CFRange(location: 0, length: 0), nil, nil, nil), x + limitValue)
                guard final > startOffset else { continue }
                let strokeWidth = CTFontGetUnderlineThickness(font) > 0 ? CTFontGetUnderlineThickness(font) : CTFontGetSize(font) / 20
                func span(_ center: Double) {
                    path.addRect(CGRect(x: startOffset * mm, y: (center - strokeWidth / 2) * mm, width: (final - startOffset) * mm, height: strokeWidth * mm))
                }
                if attributes[NSAttributedString.Key.underline.rawValue] as? Bool == true {
                    span(base - rise - CTFontGetUnderlinePosition(font))
                }
                if attributes[NSAttributedString.Key.strikethrough.rawValue] as? Bool == true {
                    span(base - rise - CTFontGetXHeight(font) / 2)
                }
            }
        }

        for line in d.lines {
            letters(line.ct, x: line.x, base: line.base, ranges: line.width)
            if let bullet = line.bullet { letters(bullet, x: line.bulletX, base: line.base) }
        }
        guard !path.isEmpty else { return nil }
        if Self.contours.count > 300 { Self.contours = [:] }
        Self.contours[self] = path
        return path
    }

    /// The letters' natural box, in mm (for the frame when creating or changing the text).
    var naturalSize: CGSize { contour?.boundingBoxOfPath.size ?? CGSize(width: 10, height: 5) }
}
