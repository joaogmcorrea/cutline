// The fonts of an imported PDF (Model/PDFImport.swift, Model/PDFText.swift): what turns a string's bytes into glyphs
// (outline, advance, Unicode). The outlines come from the font embedded in the PDF, read by CoreGraphics: TrueType
// (FontFile2), CFF (FontFile3: Type1C, CIDFontType0C, OpenType) and Type 1 (FontFile) when CoreGraphics takes it. A
// font that isn't embedded uses the one installed on the Mac with the same name (the standard 14 of PDF are all there),
// and is left out when the Mac doesn't have it. Type 3 fonts draw each glyph with a content stream of their own (Skia,
// the PDF engine of Chrome and of many web apps, writes CFF fonts, outlined text and emoji that way).
// Codes → glyphs as the PDF specification says (9.6.6 and 9.7): simple fonts by their encoding (WinAnsi, MacRoman,
// Standard, Differences, the font's own); composite fonts (Type0) by their CMap (Identity-H or an embedded one), then
// CIDToGIDMap (TrueType) or the CFF charset.
import CoreGraphics
import CoreText
import Foundation

nonisolated final class PDFFont {
    /// One glyph of a string.
    struct Glyph {
        /// Glyph index in `outlines` (outline fonts).
        var index: CGGlyph = 0
        /// Type 3: the glyph's content stream.
        var procedure: CGPDFStreamRef?
        /// Horizontal advance in text space (1 = the font size).
        var width: Double
        /// The single-byte code 32: it takes the word spacing (Tw).
        var isSpace = false
        /// What the glyph means (ToUnicode or the encoding), for the object's name.
        var text = ""
    }

    /// Outline fonts: the glyphs at size 1 (an em = 1 text space unit).
    let outlines: CTFont?
    /// Type 3: glyph space → text space, the fonts' own resources (nil = the page's) and the glyphs by name.
    let fontMatrix: CGAffineTransform
    let resources: PDFDict?
    private var procedures: [String: CGPDFStreamRef] = [:]

    private var codeLengths: [(length: Int, low: UInt32, high: UInt32)] = [(1, 0, 0xFF)]
    /// Simple fonts: code → glyph name (the encoding with its Differences), and the Unicode the encoding implies.
    private var names: [UInt8: String] = [:]
    /// Simple fonts: code → glyph index when it doesn't go by name (TrueType's cmap, the CFF's own encoding).
    private var codeToGlyph: (UInt32) -> CGGlyph? = { _ in nil }
    private var nameToGlyph: (String) -> CGGlyph? = { _ in nil }
    /// Composite fonts: code → CID (the CMap) and CID → glyph.
    private var cmap: PDFCMap?
    private var cidToGlyph: (UInt32) -> CGGlyph? = { CGGlyph(truncatingIfNeeded: $0) }
    private let composite: Bool
    private var toUnicode: PDFCMap?
    /// Advances in glyph space units /1000 (simple: by code; composite: by CID).
    private var widths: [UInt32: Double] = [:]
    private var widthRanges: [(low: UInt32, high: UInt32, width: Double)] = []
    private var defaultWidth: Double?
    private var paths: [CGGlyph: CGPath] = [:]

    /// nil when the glyphs can't be had (a font that isn't embedded and isn't on the Mac, a CMap Cutline doesn't know).
    static func load(_ dictionary: PDFDict) -> PDFFont? {
        let subtype = dictionary.name("Subtype") ?? ""
        switch subtype {
        case "Type0":
            guard let descendants = dictionary.array("DescendantFonts"), let cidFont = descendants.dictionary(at: 0) else { return nil }
            return PDFFont(composite: dictionary, cidFont: cidFont)
        case "Type3":
            return PDFFont(type3: dictionary)
        default:
            return PDFFont(simple: dictionary)
        }
    }

    // MARK: Glyphs

    /// The glyphs of a string; nil when none could be found (the text is left out and counted).
    func glyphs(_ bytes: [UInt8]) -> [Glyph]? {
        var result: [Glyph] = []
        var i = 0
        var found = false
        while i < bytes.count {
            let (code, length) = nextCode(bytes, at: i)
            i += length
            var glyph: Glyph
            if composite {
                let cid = cmap?.cid(code, length: length) ?? code
                glyph = Glyph(index: cidToGlyph(cid) ?? 0, width: width(cid) / 1000)
            } else {
                let byte = UInt8(truncatingIfNeeded: code)
                glyph = Glyph(width: width(code), isSpace: code == 32 && length == 1)
                if outlines != nil {
                    glyph.index = names[byte].flatMap(nameToGlyph) ?? codeToGlyph(code) ?? 0
                    glyph.width /= 1000
                } else {
                    glyph.procedure = names[byte].flatMap { procedures[$0] }
                    glyph.width *= fontMatrix.a
                }
            }
            glyph.text = toUnicode?.unicode(code, length: length) ?? names[UInt8(truncatingIfNeeded: code)].flatMap(PDFEncoding.unicode) ?? ""
            if composite, length == 1, code == 32 { glyph.isSpace = true }
            if glyph.index != 0 || glyph.procedure != nil { found = true }
            result.append(glyph)
        }
        // Nothing found: only spaces still count as read (they draw nothing anyway).
        let spaces = composite ? result.allSatisfy { !$0.text.isEmpty && $0.text.allSatisfy(\.isWhitespace) } : bytes.allSatisfy { $0 == 32 }
        return found || spaces ? result : nil
    }

    /// The glyph's outline at size 1 (text space, y up); nil for an empty glyph (a space).
    func path(_ glyph: CGGlyph) -> CGPath? {
        if let ready = paths[glyph] { return ready.isEmpty ? nil : ready }
        guard let outlines else { return nil }
        let path = CTFontCreatePathForGlyph(outlines, glyph, nil) ?? CGMutablePath()
        paths[glyph] = path
        return path.isEmpty ? nil : path
    }

    private func nextCode(_ bytes: [UInt8], at start: Int) -> (UInt32, Int) {
        var code: UInt32 = 0
        for length in 1...4 where start + length <= bytes.count {
            code = code << 8 | UInt32(bytes[start + length - 1])
            if codeLengths.contains(where: { $0.length == length && code >= $0.low && code <= $0.high }) { return (code, length) }
        }
        // Outside every code space range: as many bytes as the shortest range (9.7.6.3).
        let length = min(codeLengths.map(\.length).min() ?? 1, bytes.count - start)
        return (bytes[start..<(start + length)].reduce(0) { $0 << 8 | UInt32($1) }, length)
    }

    private func width(_ key: UInt32) -> Double {
        if let w = widths[key] { return w }
        if let range = widthRanges.first(where: { key >= $0.low && key <= $0.high }) { return range.width }
        if let defaultWidth { return defaultWidth }
        // No widths in the PDF (a standard 14 font): the font's own advance.
        guard let outlines, !composite else { return 1000 }
        let byte = UInt8(truncatingIfNeeded: key)
        var glyph = names[byte].flatMap(nameToGlyph) ?? codeToGlyph(key) ?? 0
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(outlines, .horizontal, &glyph, &advance, 1)
        return advance.width * 1000
    }

    // MARK: Loading

    private init(simple dictionary: PDFDict) {
        composite = false
        fontMatrix = .identity
        resources = nil
        let descriptor = dictionary.dictionary("FontDescriptor")
        let embedded = descriptor.flatMap(Self.embeddedFont)
        let system = embedded == nil ? Self.systemFont(dictionary.name("BaseFont") ?? "") : nil
        outlines = embedded?.font ?? system
        toUnicode = dictionary.stream("ToUnicode").flatMap { PDFCMap($0.data) }
        readSimpleWidths(dictionary, descriptor: descriptor)
        guard let outlines else { return }
        let graphics = CTFontCopyGraphicsFont(outlines, nil)
        let isTrueType = embedded?.isTrueType ?? (CTFontCopyTable(outlines, CTFontTableTag(kCTFontTableGlyf), []) != nil)
        // Symbolic (flag 3) without an encoding of its own: the codes go straight to the font (9.6.6.4).
        let flags = descriptor?.integer("Flags") ?? 0
        let symbolic = flags & 4 != 0 && flags & 32 == 0
        let encoding = Self.encoding(dictionary.object("Encoding"))
        let cff = embedded?.cff
        if let encoding {
            names = encoding.names(base: cff?.builtIn ?? (isTrueType || !symbolic ? PDFEncoding.standard : [:]))
        } else if let builtIn = cff?.builtIn {
            names = builtIn
        } else if !isTrueType || !symbolic {
            names = PDFEncoding.standard
        }
        let cmaps = isTrueType ? TrueTypeCMaps(outlines) : nil
        nameToGlyph = { name in
            if let cmaps, cmaps.hasUnicode, !symbolic || encoding != nil, let unicode = PDFEncoding.unicode(name)?.unicodeScalars.first,
               let glyph = cmaps.unicode(unicode.value) { return glyph }
            if let cmaps, let mac = PDFEncoding.macRomanCode[name], let glyph = cmaps.macRoman(UInt32(mac)) { return glyph }
            let glyph = graphics.getGlyphWithGlyphName(name: name as CFString)
            if glyph != 0 { return glyph }
            // A font that isn't embedded (or a TrueType without names): by the Unicode the name stands for.
            if let unicode = PDFEncoding.unicode(name) {
                var characters = Array(unicode.utf16)
                var glyphs = [CGGlyph](repeating: 0, count: characters.count)
                if CTFontGetGlyphsForCharacters(outlines, &characters, &glyphs, characters.count), glyphs[0] != 0 { return glyphs[0] }
            }
            return nil
        }
        let ownEncoding = cff?.codeToGlyph
        codeToGlyph = { code in
            if let glyph = ownEncoding?[UInt8(truncatingIfNeeded: code)] { return glyph }
            guard let cmaps else { return nil }
            return cmaps.symbol(code) ?? cmaps.macRoman(code) ?? (embedded != nil && code < cmaps.glyphCount ? CGGlyph(code) : nil)
        }
    }

    private init(composite dictionary: PDFDict, cidFont: PDFDict) {
        composite = true
        fontMatrix = .identity
        resources = nil
        let descriptor = cidFont.dictionary("FontDescriptor")
        let embedded = descriptor.flatMap(Self.embeddedFont)
        outlines = embedded?.font ?? Self.systemFont(cidFont.name("BaseFont") ?? dictionary.name("BaseFont") ?? "")
        toUnicode = dictionary.stream("ToUnicode").flatMap { PDFCMap($0.data) }
        if let name = dictionary.name("Encoding") {
            // Identity-V is vertical writing, which Cutline doesn't lay out: left out.
            guard name == "Identity-H" else {
                codeLengths = []
                return
            }
            codeLengths = [(2, 0, 0xFFFF)]
        } else if let stream = dictionary.stream("Encoding"), let embeddedMap = PDFCMap(stream.data), !embeddedMap.codespaces.isEmpty {
            cmap = embeddedMap
            codeLengths = embeddedMap.codespaces
        } else {
            codeLengths = []
            return
        }
        defaultWidth = cidFont.number("DW") ?? 1000
        if let w = cidFont.array("W") {
            var i = 0
            let n = w.count
            while i < n {
                guard let first = w.number(at: i) else { break }
                if let list = w.array(at: i + 1) {
                    for k in 0..<list.count { widths[UInt32(first) + UInt32(k)] = list.number(at: k) ?? 0 }
                    i += 2
                } else if let last = w.number(at: i + 1), let value = w.number(at: i + 2) {
                    widthRanges.append((UInt32(first), UInt32(last), value))
                    i += 3
                } else {
                    break
                }
            }
        }
        if cidFont.name("Subtype") == "CIDFontType2" {
            if let map = cidFont.stream("CIDToGIDMap")?.data {
                let bytes = [UInt8](map)
                cidToGlyph = { cid in
                    let k = Int(cid) * 2
                    return k + 1 < bytes.count ? CGGlyph(bytes[k]) << 8 | CGGlyph(bytes[k + 1]) : nil
                }
            }
        } else if let cff = embedded?.cff, let cids = cff.cidToGlyph {
            cidToGlyph = { cids[$0] }
        }
        if embedded == nil, let outlines {
            // Not embedded: only by Unicode (the CIDs are another font's).
            let toUnicode = toUnicode
            cmap = nil
            codeLengths = codeLengths.isEmpty ? [(2, 0, 0xFFFF)] : codeLengths
            cidToGlyph = { code in
                guard let text = toUnicode?.unicode(code, length: 2) else { return nil }
                var characters = Array(text.utf16)
                var glyphs = [CGGlyph](repeating: 0, count: characters.count)
                return CTFontGetGlyphsForCharacters(outlines, &characters, &glyphs, characters.count) ? glyphs[0] : nil
            }
        }
    }

    private init(type3 dictionary: PDFDict) {
        composite = false
        outlines = nil
        resources = dictionary.dictionary("Resources")
        if let m = dictionary.array("FontMatrix"), m.count == 6 {
            let v = (0..<6).map { m.number(at: $0) ?? 0 }
            fontMatrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
        } else {
            fontMatrix = CGAffineTransform(scaleX: 0.001, y: 0.001)
        }
        if let procs = dictionary.dictionary("CharProcs") {
            var found: [String: CGPDFStreamRef] = [:]
            CGPDFDictionaryApplyBlock(procs.ref, { key, object, _ in
                var stream: CGPDFStreamRef?
                if CGPDFObjectGetValue(object, .stream, &stream), let stream { found[String(cString: key)] = stream }
                return true
            }, nil)
            procedures = found
        }
        names = Self.encoding(dictionary.object("Encoding"))?.names(base: [:]) ?? [:]
        toUnicode = dictionary.stream("ToUnicode").flatMap { PDFCMap($0.data) }
        readSimpleWidths(dictionary, descriptor: nil)
    }

    private func readSimpleWidths(_ dictionary: PDFDict, descriptor: PDFDict?) {
        guard let list = dictionary.array("Widths") else { return }
        let first = dictionary.integer("FirstChar") ?? 0
        for i in 0..<list.count { widths[UInt32(max(0, first + i))] = list.number(at: i) ?? 0 }
        defaultWidth = descriptor?.number("MissingWidth") ?? 0
    }

    /// The font file in the descriptor, read by CoreGraphics; `cff`: what CoreGraphics doesn't tell about a CFF font
    /// (the CID-keyed charset, the font's own encoding).
    private static func embeddedFont(_ descriptor: PDFDict) -> (font: CTFont, isTrueType: Bool, cff: CFFFont?)? {
        for key in ["FontFile2", "FontFile3", "FontFile"] {
            guard let stream = descriptor.stream(key), let data = stream.data, let provider = CGDataProvider(data: data as CFData),
                  let graphics = CGFont(provider) else { continue }
            let subtype = stream.dictionary.flatMap { $0.name("Subtype") }
            let cff = key == "FontFile3" && subtype != "OpenType" ? CFFFont(data) : nil
            return (CTFontCreateWithGraphicsFont(graphics, 1, nil, nil), key == "FontFile2" || subtype == "OpenType" && cff == nil, cff)
        }
        return nil
    }

    /// The Mac's font with that PostScript name ("ABCDEF+Arial-BoldMT", "Arial,Bold", "Helvetica"…); nil if it isn't there.
    static func systemFont(_ baseFont: String) -> CTFont? {
        var name = baseFont
        if name.count > 7, name.dropFirst(6).first == "+" { name = String(name.dropFirst(7)) }
        guard !name.isEmpty else { return nil }
        let base = PDFEncoding.standard14[name] ?? name
        let dashed = base.replacingOccurrences(of: ",", with: "-")
        for candidate in [base, dashed, dashed + "MT", dashed + "PSMT", base.replacingOccurrences(of: ",", with: "")] {
            let font = CTFontCreateWithName(candidate as CFString, 1, nil)
            let found = CTFontCopyPostScriptName(font) as String
            if found.caseInsensitiveCompare(candidate) == .orderedSame { return font }
        }
        return nil
    }

    private static func encoding(_ object: CGPDFObjectRef?) -> PDFEncoding? {
        guard let object else { return nil }
        var name: UnsafePointer<CChar>?
        if CGPDFObjectGetValue(object, .name, &name), let name { return PDFEncoding(base: String(cString: name), differences: nil) }
        guard let dictionary = PDFDict(object) else { return nil }
        return PDFEncoding(base: dictionary.name("BaseEncoding"), differences: dictionary.array("Differences"))
    }
}

// MARK: - Encodings

/// A simple font's encoding: a base (by name) and the Differences.
nonisolated struct PDFEncoding {
    var base: String?
    var differences: [UInt8: String] = [:]

    init(base: String?, differences: PDFArray?) {
        self.base = base
        guard let differences else { return }
        var code = 0
        for i in 0..<differences.count {
            if let n = differences.number(at: i) {
                code = Int(n)
            } else if let name = differences.name(at: i) {
                if (0...255).contains(code) { self.differences[UInt8(code)] = name }
                code += 1
            }
        }
    }

    /// code → glyph name: the base encoding (`fallback` when the PDF names none) with the Differences on top.
    func names(base fallback: [UInt8: String]) -> [UInt8: String] {
        var result: [UInt8: String]
        switch base {
        case "WinAnsiEncoding": result = Self.winAnsi
        case "MacRomanEncoding": result = Self.macRoman
        case "StandardEncoding": result = Self.standard
        default: result = fallback
        }
        result.merge(differences) { $1 }
        return result
    }

    static let standard = table(32, """
        space exclam quotedbl numbersign dollar percent ampersand quoteright parenleft parenright asterisk plus comma hyphen \
        period slash zero one two three four five six seven eight nine colon semicolon less equal greater question at A B C \
        D E F G H I J K L M N O P Q R S T U V W X Y Z bracketleft backslash bracketright asciicircum underscore quoteleft a \
        b c d e f g h i j k l m n o p q r s t u v w x y z braceleft bar braceright asciitilde
        """).merging(table(161, """
        exclamdown cent sterling fraction yen florin section currency quotesingle quotedblleft guillemotleft guilsinglleft \
        guilsinglright fi fl . endash dagger daggerdbl periodcentered . paragraph bullet quotesinglbase quotedblbase \
        quotedblright guillemotright ellipsis perthousand . questiondown . grave acute circumflex tilde macron breve \
        dotaccent dieresis . ring cedilla . hungarumlaut ogonek caron emdash
        """)) { $1 }.merging([225: "AE", 227: "ordfeminine", 232: "Lslash", 233: "Oslash", 234: "OE", 235: "ordmasculine",
                              241: "ae", 245: "dotlessi", 248: "lslash", 249: "oslash", 250: "oe", 251: "germandbls"]) { $1 }

    private static let ascii = table(32, """
        space exclam quotedbl numbersign dollar percent ampersand quotesingle parenleft parenright asterisk plus comma hyphen \
        period slash zero one two three four five six seven eight nine colon semicolon less equal greater question at A B C \
        D E F G H I J K L M N O P Q R S T U V W X Y Z bracketleft backslash bracketright asciicircum underscore grave a \
        b c d e f g h i j k l m n o p q r s t u v w x y z braceleft bar braceright asciitilde
        """)

    private static let latin1 = table(160, """
        space exclamdown cent sterling currency yen brokenbar section dieresis copyright ordfeminine guillemotleft \
        logicalnot hyphen registered macron degree plusminus twosuperior threesuperior acute mu paragraph periodcentered \
        cedilla onesuperior ordmasculine guillemotright onequarter onehalf threequarters questiondown Agrave Aacute \
        Acircumflex Atilde Adieresis Aring AE Ccedilla Egrave Eacute Ecircumflex Edieresis Igrave Iacute Icircumflex \
        Idieresis Eth Ntilde Ograve Oacute Ocircumflex Otilde Odieresis multiply Oslash Ugrave Uacute Ucircumflex \
        Udieresis Yacute Thorn germandbls agrave aacute acircumflex atilde adieresis aring ae ccedilla egrave eacute \
        ecircumflex edieresis igrave iacute icircumflex idieresis eth ntilde ograve oacute ocircumflex otilde odieresis \
        divide oslash ugrave uacute ucircumflex udieresis yacute thorn ydieresis
        """)

    static let winAnsi = ascii.merging(table(128, """
        Euro . quotesinglbase florin quotedblbase ellipsis dagger daggerdbl circumflex perthousand Scaron guilsinglleft OE \
        . Zcaron . . quoteleft quoteright quotedblleft quotedblright bullet endash emdash tilde trademark scaron \
        guilsinglright oe . zcaron Ydieresis
        """)) { $1 }.merging(latin1) { $1 }

    static let macRoman = ascii.merging(table(128, """
        Adieresis Aring Ccedilla Eacute Ntilde Odieresis Udieresis aacute agrave acircumflex adieresis atilde aring \
        ccedilla eacute egrave ecircumflex edieresis iacute igrave icircumflex idieresis ntilde oacute ograve ocircumflex \
        odieresis otilde uacute ugrave ucircumflex udieresis dagger degree cent sterling section bullet paragraph \
        germandbls registered copyright trademark acute dieresis notequal AE Oslash infinity plusminus lessequal \
        greaterequal yen mu partialdiff summation product pi integral ordfeminine ordmasculine Omega ae oslash \
        questiondown exclamdown logicalnot radical florin approxequal Delta guillemotleft guillemotright ellipsis space \
        Agrave Atilde Otilde OE oe endash emdash quotedblleft quotedblright quoteleft quoteright divide lozenge \
        ydieresis Ydieresis fraction currency guilsinglleft guilsinglright fi fl daggerdbl periodcentered quotesinglbase \
        quotedblbase perthousand Acircumflex Ecircumflex Aacute Edieresis Egrave Iacute Icircumflex Idieresis Igrave \
        Oacute Ocircumflex apple Ograve Uacute Ucircumflex Ugrave dotlessi circumflex tilde macron breve dotaccent ring \
        cedilla hungarumlaut ogonek caron
        """)) { $1 }

    /// MacRoman code of a glyph name (TrueType fonts with only the Mac cmap).
    static let macRomanCode: [String: UInt8] = Dictionary(macRoman.map { ($0.value, $0.key) }) { a, b in min(a, b) }

    /// The Unicode a glyph name stands for: the names of the encodings above, uniXXXX, uXXXX[XX] and a few more.
    static func unicode(_ name: String) -> String? {
        if let known = names[name] { return known }
        let base = name.split(separator: ".").first.map(String.init) ?? name
        if base != name, let known = names[base] { return known }
        if base.hasPrefix("uni"), base.count >= 7 {
            let hex = Array(base.dropFirst(3))
            var text = ""
            for k in stride(from: 0, to: hex.count - 3, by: 4) {
                guard let v = UInt32(String(hex[k..<(k + 4)]), radix: 16), let s = Unicode.Scalar(v) else { return nil }
                text.unicodeScalars.append(s)
            }
            return text
        }
        if base.hasPrefix("u"), (5...7).contains(base.count), let v = UInt32(base.dropFirst(), radix: 16), let s = Unicode.Scalar(v) {
            return String(Character(s))
        }
        if base.contains("_") {
            let parts = base.split(separator: "_").map { unicode(String($0)) }
            return parts.allSatisfy({ $0 != nil }) ? parts.compactMap { $0 }.joined() : nil
        }
        return nil
    }

    private static let names: [String: String] = {
        var result: [String: String] = [:]
        for (code, name) in winAnsi {
            if let s = String(bytes: [code], encoding: .windowsCP1252) { result[name] = s }
        }
        for (code, name) in macRoman where result[name] == nil {
            if let s = String(bytes: [code], encoding: .macOSRoman) { result[name] = s }
        }
        let extra: [String: UInt32] = [
            "fraction": 0x2044, "dotlessi": 0x131, "Lslash": 0x141, "lslash": 0x142, "hungarumlaut": 0x2DD, "ogonek": 0x2DB,
            "caron": 0x2C7, "breve": 0x2D8, "dotaccent": 0x2D9, "ring": 0x2DA, "fi": 0xFB01, "fl": 0xFB02, "ff": 0xFB00,
            "ffi": 0xFB03, "ffl": 0xFB04, "minus": 0x2212, "nbspace": 0xA0, "sfthyphen": 0xAD, "Euro": 0x20AC,
            "quotesingle": 0x27, "grave": 0x60, "space": 0x20, "Gbreve": 0x11E, "gbreve": 0x11F, "Idotaccent": 0x130,
            "Scedilla": 0x15E, "scedilla": 0x15F, "Cacute": 0x106, "cacute": 0x107, "Ccaron": 0x10C, "ccaron": 0x10D,
            "Ecaron": 0x11A, "ecaron": 0x11B, "Rcaron": 0x158, "rcaron": 0x159, "Zacute": 0x179, "zacute": 0x17A,
            "Zdotaccent": 0x17B, "zdotaccent": 0x17C, "Nacute": 0x143, "nacute": 0x144, "Sacute": 0x15A, "sacute": 0x15B,
            "Aogonek": 0x104, "aogonek": 0x105, "Eogonek": 0x118, "eogonek": 0x119, "Ohungarumlaut": 0x150,
            "ohungarumlaut": 0x151, "Uhungarumlaut": 0x170, "uhungarumlaut": 0x171, "Uring": 0x16E, "uring": 0x16F,
            "Tcaron": 0x164, "tcaron": 0x165, "Dcaron": 0x10E, "dcaron": 0x10F, "Ncaron": 0x147, "ncaron": 0x148,
            "dcroat": 0x111, "Dcroat": 0x110, "Amacron": 0x100, "amacron": 0x101, "Emacron": 0x112, "emacron": 0x113,
            "Imacron": 0x12A, "imacron": 0x12B, "Omacron": 0x14C, "omacron": 0x14D, "Umacron": 0x16A, "umacron": 0x16B,
            "Lcaron": 0x13D, "lcaron": 0x13E, "Lacute": 0x139, "lacute": 0x13A, "Racute": 0x154, "racute": 0x155,
            "ellipsis": 0x2026, "bullet": 0x2022, "periodcentered": 0xB7, "checkmark": 0x2713, "arrowright": 0x2192,
            "arrowleft": 0x2190, "arrowup": 0x2191, "arrowdown": 0x2193, "heart": 0x2665, "infinity": 0x221E,
        ]
        for (name, value) in extra { if let s = Unicode.Scalar(value) { result[name] = String(Character(s)) } }
        return result
    }()

    /// The standard 14 fonts by the Mac's PostScript names.
    static let standard14: [String: String] = [
        "Helvetica": "Helvetica", "Helvetica-Bold": "Helvetica-Bold", "Helvetica-Oblique": "Helvetica-Oblique",
        "Helvetica-BoldOblique": "Helvetica-BoldOblique", "Times-Roman": "Times-Roman", "Times-Bold": "Times-Bold",
        "Times-Italic": "Times-Italic", "Times-BoldItalic": "Times-BoldItalic", "Courier": "Courier",
        "Courier-Bold": "Courier-Bold", "Courier-Oblique": "Courier-Oblique", "Courier-BoldOblique": "Courier-BoldOblique",
        "Symbol": "Symbol", "ZapfDingbats": "ZapfDingbatsITC", "Arial": "ArialMT", "Arial,Bold": "Arial-BoldMT",
        "Arial,Italic": "Arial-ItalicMT", "Arial,BoldItalic": "Arial-BoldItalicMT", "TimesNewRoman": "TimesNewRomanPSMT",
        "TimesNewRoman,Bold": "TimesNewRomanPS-BoldMT", "TimesNewRoman,Italic": "TimesNewRomanPS-ItalicMT",
        "TimesNewRoman,BoldItalic": "TimesNewRomanPS-BoldItalicMT", "CourierNew": "CourierNewPSMT",
    ]

    /// Names from `start` on, separated by spaces ("." = no glyph at that code).
    private static func table(_ start: Int, _ list: String) -> [UInt8: String] {
        var result: [UInt8: String] = [:]
        for (i, name) in list.split(whereSeparator: \.isWhitespace).enumerated() where name != "." && start + i < 256 {
            result[UInt8(start + i)] = String(name)
        }
        return result
    }
}

// MARK: - CMaps

/// An embedded CMap (a Type0 font's Encoding) or a ToUnicode: code space ranges, code → CID and code → Unicode.
nonisolated struct PDFCMap {
    var codespaces: [(length: Int, low: UInt32, high: UInt32)] = []
    private var cids: [UInt32: UInt32] = [:]
    private var cidRanges: [(low: UInt32, high: UInt32, first: UInt32)] = []
    private var texts: [UInt32: String] = [:]
    private var textRanges: [(low: UInt32, high: UInt32, first: [UInt16])] = []

    init?(_ data: Data?) {
        guard let data else { return nil }
        let tokens = Self.tokens([UInt8](data))
        var i = 0
        var operands: [Token] = []
        while i < tokens.count {
            let token = tokens[i]
            i += 1
            guard case .word(let word) = token else {
                operands.append(token)
                continue
            }
            defer { operands = [] }
            switch word {
            case "endcodespacerange":
                for k in stride(from: 0, to: operands.count - 1, by: 2) {
                    guard case .hex(let low) = operands[k], case .hex(let high) = operands[k + 1] else { continue }
                    codespaces.append((low.count, Self.value(low), Self.value(high)))
                }
            case "endcidrange":
                for k in stride(from: 0, to: operands.count - 2, by: 3) {
                    guard case .hex(let low) = operands[k], case .hex(let high) = operands[k + 1],
                          case .number(let first) = operands[k + 2] else { continue }
                    cidRanges.append((Self.value(low), Self.value(high), UInt32(max(0, first))))
                }
            case "endcidchar":
                for k in stride(from: 0, to: operands.count - 1, by: 2) {
                    guard case .hex(let code) = operands[k], case .number(let cid) = operands[k + 1] else { continue }
                    cids[Self.value(code)] = UInt32(max(0, cid))
                }
            case "endbfchar":
                for k in stride(from: 0, to: operands.count - 1, by: 2) {
                    guard case .hex(let code) = operands[k] else { continue }
                    if case .hex(let text) = operands[k + 1] { texts[Self.value(code)] = Self.utf16(text) }
                    if case .name(let name) = operands[k + 1] { texts[Self.value(code)] = PDFEncoding.unicode(name) }
                }
            case "endbfrange":
                var k = 0
                while k + 2 < operands.count {
                    defer { k += 3 }
                    guard case .hex(let lowBytes) = operands[k], case .hex(let highBytes) = operands[k + 1] else { continue }
                    let low = Self.value(lowBytes), high = Self.value(highBytes)
                    switch operands[k + 2] {
                    case .hex(let first):
                        textRanges.append((low, high, Self.units(first)))
                    case .array(let list):
                        for (n, item) in list.enumerated() where low + UInt32(n) <= high {
                            if case .hex(let text) = item { texts[low + UInt32(n)] = Self.utf16(text) }
                        }
                    default: break
                    }
                }
            default:
                break
            }
        }
    }

    func cid(_ code: UInt32, length: Int) -> UInt32? {
        if let cid = cids[code] { return cid }
        if let range = cidRanges.first(where: { code >= $0.low && code <= $0.high }) { return range.first + code - range.low }
        return 0
    }

    func unicode(_ code: UInt32, length: Int) -> String? {
        if let text = texts[code] { return text }
        guard let range = textRanges.first(where: { code >= $0.low && code <= $0.high }), var units = range.first.isEmpty ? nil : range.first
        else { return nil }
        units[units.count - 1] &+= UInt16(truncatingIfNeeded: code - range.low)
        return String(decoding: units, as: UTF16.self)
    }

    private indirect enum Token {
        case hex([UInt8]), number(Int), name(String), word(String), array([Token])
    }

    private static func value(_ bytes: [UInt8]) -> UInt32 { bytes.prefix(4).reduce(0) { $0 << 8 | UInt32($1) } }

    private static func units(_ bytes: [UInt8]) -> [UInt16] {
        stride(from: 0, to: bytes.count - 1, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
    }

    private static func utf16(_ bytes: [UInt8]) -> String { String(decoding: units(bytes), as: UTF16.self) }

    /// PostScript-like tokens: <hex>, numbers, /names, words and [arrays] (strings and comments are skipped).
    private static func tokens(_ b: [UInt8]) -> [Token] {
        var result: [Token] = []
        var stack: [[Token]] = []
        var i = 0
        func push(_ t: Token) {
            if stack.isEmpty { result.append(t) } else { stack[stack.count - 1].append(t) }
        }
        let delimiters: Set<UInt8> = Set("()<>[]{}/%".utf8)
        while i < b.count {
            let c = b[i]
            switch c {
            case UInt8(ascii: "%"):
                while i < b.count, b[i] != 10, b[i] != 13 { i += 1 }
            case UInt8(ascii: "<"):
                if i + 1 < b.count, b[i + 1] == UInt8(ascii: "<") { i += 2; continue }
                i += 1
                var digits: [UInt8] = []
                while i < b.count, b[i] != UInt8(ascii: ">") {
                    if let d = hexDigit(b[i]) { digits.append(d) }
                    i += 1
                }
                i += 1
                if digits.count % 2 == 1 { digits.append(0) }
                push(.hex(stride(from: 0, to: digits.count, by: 2).map { digits[$0] << 4 | digits[$0 + 1] }))
            case UInt8(ascii: ">"):
                i += 1
            case UInt8(ascii: "("):
                var depth = 0
                repeat {
                    if b[i] == UInt8(ascii: "\\") { i += 1 } else if b[i] == UInt8(ascii: "(") { depth += 1 } else if b[i] == UInt8(ascii: ")") { depth -= 1 }
                    i += 1
                } while i < b.count && depth > 0
            case UInt8(ascii: "["):
                stack.append([])
                i += 1
            case UInt8(ascii: "]"):
                i += 1
                if let list = stack.popLast() { push(.array(list)) }
            case UInt8(ascii: "/"):
                i += 1
                let start = i
                while i < b.count, !isSpace(b[i]), !delimiters.contains(b[i]) { i += 1 }
                push(.name(String(decoding: b[start..<i], as: UTF8.self)))
            default:
                if isSpace(c) || delimiters.contains(c) {
                    i += 1
                    continue
                }
                let start = i
                while i < b.count, !isSpace(b[i]), !delimiters.contains(b[i]) { i += 1 }
                let word = String(decoding: b[start..<i], as: UTF8.self)
                if let n = Int(word) { push(.number(n)) } else { push(.word(word)) }
            }
        }
        return result
    }

    private static func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 12 || c == 0 }

    private static func hexDigit(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: c - 48
        case 65...70: c - 55
        case 97...102: c - 87
        default: nil
        }
    }
}

// MARK: - Font files

/// What a bare CFF font (FontFile3) says that CoreGraphics doesn't: a CID-keyed font's CID → glyph (its charset) and a
/// simple font's own encoding (code → glyph name, or code → glyph when its glyphs have no names to look up).
nonisolated struct CFFFont {
    var cidToGlyph: [UInt32: CGGlyph]?
    var builtIn: [UInt8: String]?
    var codeToGlyph: [UInt8: CGGlyph]?

    init?(_ data: Data) {
        let b = [UInt8](data)
        guard b.count > 4, b[0] == 1 else { return nil }
        var r = CFFReader(bytes: b, at: Int(b[2]))
        guard let _ = r.index(), let top = r.index()?.first, let strings = r.index() else { return nil }
        let dict = CFFReader.dict(b, top)
        guard let charStrings = dict[17]?.first.map(Int.init) else { return nil }
        var counter = CFFReader(bytes: b, at: charStrings)
        let glyphCount = counter.card16()
        // GID → SID (or CID, for CID-keyed fonts).
        var charset: [Int] = [0]
        let charsetOffset = Int(dict[15]?.first ?? 0)
        if charsetOffset > 2 {
            var c = CFFReader(bytes: b, at: charsetOffset)
            let format = c.card8()
            while charset.count < glyphCount, !c.atEnd {
                switch format {
                case 0:
                    charset.append(c.card16())
                case 1, 2:
                    let first = c.card16(), left = format == 1 ? c.card8() : c.card16()
                    for k in 0...left where charset.count < glyphCount { charset.append(first + k) }
                default:
                    return nil
                }
            }
        } else if charsetOffset == 0 {
            charset = Array(0..<glyphCount)
        }
        if dict[1230] != nil {
            // CID-keyed (ROS): the charset's numbers are the CIDs.
            var map: [UInt32: CGGlyph] = [:]
            for (glyph, cid) in charset.enumerated() { map[UInt32(cid)] = CGGlyph(glyph) }
            cidToGlyph = map
            return
        }
        let name = { (sid: Int) -> String? in
            if sid < CFFReader.standardStrings.count { return CFFReader.standardStrings[sid] }
            let k = sid - CFFReader.standardStrings.count
            return k < strings.count ? String(decoding: b[strings[k]], as: UTF8.self) : nil
        }
        let encodingOffset = Int(dict[16]?.first ?? 0)
        if encodingOffset == 0 {
            builtIn = PDFEncoding.standard
        } else if encodingOffset > 1 {
            var e = CFFReader(bytes: b, at: encodingOffset)
            let format = e.card8()
            var codes: [UInt8: CGGlyph] = [:]
            switch format & 0x7F {
            case 0:
                let n = e.card8()
                for glyph in 1...max(1, n) where glyph <= n { codes[UInt8(truncatingIfNeeded: e.card8())] = CGGlyph(glyph) }
            case 1:
                var glyph = 1
                for _ in 0..<e.card8() {
                    let first = e.card8(), left = e.card8()
                    for k in 0...left { codes[UInt8(truncatingIfNeeded: first + k)] = CGGlyph(glyph); glyph += 1 }
                }
            default:
                return
            }
            if format & 0x80 != 0 {
                for _ in 0..<e.card8() {
                    let code = e.card8(), sid = e.card16()
                    if let glyph = charset.firstIndex(of: sid) { codes[UInt8(truncatingIfNeeded: code)] = CGGlyph(glyph) }
                }
            }
            codeToGlyph = codes
            var names: [UInt8: String] = [:]
            for (code, glyph) in codes where Int(glyph) < charset.count { names[code] = name(charset[Int(glyph)]) }
            builtIn = names
        }
    }
}

/// Reads the parts of a CFF font file (Adobe Technical Note #5176).
nonisolated struct CFFReader {
    let bytes: [UInt8]
    var at: Int

    var atEnd: Bool { at >= bytes.count }

    mutating func card8() -> Int {
        guard at < bytes.count else { at += 1; return 0 }
        defer { at += 1 }
        return Int(bytes[at])
    }

    mutating func card16() -> Int { card8() << 8 | card8() }

    mutating func offset(_ size: Int) -> Int { (0..<size).reduce(0) { value, _ in value << 8 | card8() } }

    /// An INDEX: the byte ranges of its items.
    mutating func index() -> [Range<Int>]? {
        let count = card16()
        guard count > 0 else { return [] }
        let size = card8()
        guard (1...4).contains(size) else { return nil }
        let offsets = (0...count).map { _ in offset(size) }
        let base = at - 1
        at = base + (offsets.last ?? 1)
        guard at <= bytes.count, offsets.allSatisfy({ $0 >= 1 }) else { return nil }
        return (0..<count).map { (base + offsets[$0])..<(base + max(offsets[$0], offsets[$0 + 1])) }
    }

    /// A DICT: operator (12 x = 1200 + x) → operands.
    static func dict(_ b: [UInt8], _ range: Range<Int>) -> [Int: [Double]] {
        var result: [Int: [Double]] = [:]
        var operands: [Double] = []
        var i = range.lowerBound
        while i < range.upperBound {
            let b0 = Int(b[i])
            i += 1
            switch b0 {
            case 0...21:
                var key = b0
                if b0 == 12, i < range.upperBound { key = 1200 + Int(b[i]); i += 1 }
                result[key] = operands
                operands = []
            case 28:
                guard i + 1 < range.upperBound else { return result }
                operands.append(Double(Int16(bitPattern: UInt16(b[i]) << 8 | UInt16(b[i + 1]))))
                i += 2
            case 29:
                guard i + 3 < range.upperBound else { return result }
                operands.append(Double(Int32(bitPattern: (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(b[i + $1]) })))
                i += 4
            case 30:
                // A real: nibbles up to 0xf. Only its place matters here (the values read are integers).
                while i < range.upperBound, b[i] & 0x0F != 0x0F, b[i] >> 4 != 0x0F { i += 1 }
                i += 1
                operands.append(0)
            case 32...246:
                operands.append(Double(b0 - 139))
            case 247...250:
                guard i < range.upperBound else { return result }
                operands.append(Double((b0 - 247) * 256 + Int(b[i]) + 108))
                i += 1
            case 251...254:
                guard i < range.upperBound else { return result }
                operands.append(Double(-(b0 - 251) * 256 - Int(b[i]) - 108))
                i += 1
            default:
                break
            }
        }
        return result
    }

    /// The CFF's 391 standard strings (SIDs 0–390).
    static let standardStrings: [String] = (".notdef " + PDFEncoding.standardNamesForCFF).split(separator: " ").map(String.init)
}

nonisolated extension PDFEncoding {
    /// SIDs 1–390 of CFF (Adobe Technical Note #5176, Appendix A).
    static let standardNamesForCFF = """
        space exclam quotedbl numbersign dollar percent ampersand quoteright parenleft parenright asterisk plus comma hyphen \
        period slash zero one two three four five six seven eight nine colon semicolon less equal greater question at A B C D \
        E F G H I J K L M N O P Q R S T U V W X Y Z bracketleft backslash bracketright asciicircum underscore quoteleft a b c \
        d e f g h i j k l m n o p q r s t u v w x y z braceleft bar braceright asciitilde exclamdown cent sterling fraction \
        yen florin section currency quotesingle quotedblleft guillemotleft guilsinglleft guilsinglright fi fl endash dagger \
        daggerdbl periodcentered paragraph bullet quotesinglbase quotedblbase quotedblright guillemotright ellipsis \
        perthousand questiondown grave acute circumflex tilde macron breve dotaccent dieresis ring cedilla hungarumlaut \
        ogonek caron emdash AE ordfeminine Lslash Oslash OE ordmasculine ae dotlessi lslash oslash oe germandbls \
        onesuperior logicalnot mu trademark Eth onehalf plusminus Thorn onequarter divide brokenbar degree thorn \
        threequarters twosuperior registered minus eth multiply threesuperior copyright Aacute Acircumflex Adieresis \
        Agrave Aring Atilde Ccedilla Eacute Ecircumflex Edieresis Egrave Iacute Icircumflex Idieresis Igrave Ntilde Oacute \
        Ocircumflex Odieresis Ograve Otilde Scaron Uacute Ucircumflex Udieresis Ugrave Yacute Ydieresis Zcaron aacute \
        acircumflex adieresis agrave aring atilde ccedilla eacute ecircumflex edieresis egrave iacute icircumflex \
        idieresis igrave ntilde oacute ocircumflex odieresis ograve otilde scaron uacute ucircumflex udieresis ugrave \
        yacute ydieresis zcaron exclamsmall Hungarumlautsmall dollaroldstyle dollarsuperior ampersandsmall Acutesmall \
        parenleftsuperior parenrightsuperior twodotenleader onedotenleader zerooldstyle oneoldstyle twooldstyle \
        threeoldstyle fouroldstyle fiveoldstyle sixoldstyle sevenoldstyle eightoldstyle nineoldstyle commasuperior \
        threequartersemdash periodsuperior questionsmall asuperior bsuperior centsuperior dsuperior esuperior isuperior \
        lsuperior msuperior nsuperior osuperior rsuperior ssuperior tsuperior ff ffi ffl parenleftinferior \
        parenrightinferior Circumflexsmall hyphensuperior Gravesmall Asmall Bsmall Csmall Dsmall Esmall Fsmall Gsmall \
        Hsmall Ismall Jsmall Ksmall Lsmall Msmall Nsmall Osmall Psmall Qsmall Rsmall Ssmall Tsmall Usmall Vsmall Wsmall \
        Xsmall Ysmall Zsmall colonmonetary onefitted rupiah Tildesmall exclamdownsmall centoldstyle Lslashsmall \
        Scaronsmall Zcaronsmall Dieresissmall Brevesmall Caronsmall Dotaccentsmall Macronsmall figuredash \
        hypheninferior Ogoneksmall Ringsmall Cedillasmall questiondownsmall oneeighth threeeighths fiveeighths \
        seveneighths onethird twothirds zerosuperior foursuperior fivesuperior sixsuperior sevensuperior eightsuperior \
        ninesuperior zeroinferior oneinferior twoinferior threeinferior fourinferior fiveinferior sixinferior \
        seveninferior eightinferior nineinferior centinferior dollarinferior periodinferior commainferior Agravesmall \
        Aacutesmall Acircumflexsmall Atildesmall Adieresissmall Aringsmall AEsmall Ccedillasmall Egravesmall Eacutesmall \
        Ecircumflexsmall Edieresissmall Igravesmall Iacutesmall Icircumflexsmall Idieresissmall Ethsmall Ntildesmall \
        Ogravesmall Oacutesmall Ocircumflexsmall Otildesmall Odieresissmall OEsmall Oslashsmall Ugravesmall Uacutesmall \
        Ucircumflexsmall Udieresissmall Yacutesmall Thornsmall Ydieresissmall 001.000 001.001 001.002 001.003 Black Bold \
        Book Light Medium Regular Roman Semibold
        """
}

/// A TrueType font's cmap subtables, looked up as needed: (3,1)/(3,10) Unicode, (3,0) symbol and (1,0) Mac Roman.
nonisolated struct TrueTypeCMaps {
    private let bytes: [UInt8]
    private var tables: [UInt32: Int] = [:]
    let glyphCount: UInt32

    init?(_ font: CTFont) {
        guard let data = CTFontCopyTable(font, CTFontTableTag(kCTFontTableCmap), []) as Data? else { return nil }
        bytes = [UInt8](data)
        glyphCount = UInt32(CTFontGetGlyphCount(font))
        guard bytes.count >= 4 else { return nil }
        let count = Int(u16(2))
        for k in 0..<count where 4 + k * 8 + 8 <= bytes.count {
            let platform = u16(4 + k * 8), encoding = u16(6 + k * 8), offset = Int(u32(8 + k * 8))
            let key = UInt32(platform) << 16 | UInt32(encoding)
            // The full Unicode table (3,10) wins over the BMP one (3,1).
            if tables[key] == nil, offset < bytes.count { tables[key] = offset }
        }
        if tables.isEmpty { return nil }
    }

    var hasUnicode: Bool { tables[0x30001] != nil || tables[0x3000A] != nil || tables[0x00003] != nil || tables[0x00004] != nil }

    func unicode(_ code: UInt32) -> CGGlyph? {
        for key: UInt32 in [0x3000A, 0x00004, 0x30001, 0x00003] {
            if let offset = tables[key], let glyph = lookup(offset, code), glyph != 0 { return glyph }
        }
        return nil
    }

    func symbol(_ code: UInt32) -> CGGlyph? {
        guard let offset = tables[0x30000] else { return nil }
        for candidate in [0xF000 + code, 0xF100 + code, 0xF200 + code, code] {
            if let glyph = lookup(offset, candidate), glyph != 0 { return glyph }
        }
        return nil
    }

    func macRoman(_ code: UInt32) -> CGGlyph? {
        guard let offset = tables[0x10000], let glyph = lookup(offset, code), glyph != 0 else { return nil }
        return glyph
    }

    private func lookup(_ t: Int, _ code: UInt32) -> CGGlyph? {
        guard t + 2 <= bytes.count else { return nil }
        switch u16(t) {
        case 0:
            return code < 256 && t + 6 + Int(code) < bytes.count ? CGGlyph(bytes[t + 6 + Int(code)]) : nil
        case 4:
            let segments = Int(u16(t + 6)) / 2
            let ends = t + 14, starts = ends + segments * 2 + 2, deltas = starts + segments * 2, ranges = deltas + segments * 2
            guard ranges + segments * 2 <= bytes.count else { return nil }
            for s in 0..<segments where code <= UInt32(u16(ends + s * 2)) {
                let start = UInt32(u16(starts + s * 2))
                guard code >= start else { return nil }
                let delta = u16(deltas + s * 2), rangeOffset = Int(u16(ranges + s * 2))
                if rangeOffset == 0 { return CGGlyph(truncatingIfNeeded: UInt32(delta) &+ code) }
                let at = ranges + s * 2 + rangeOffset + Int(code - start) * 2
                guard at + 2 <= bytes.count else { return nil }
                let glyph = u16(at)
                return glyph == 0 ? 0 : glyph &+ delta
            }
            return nil
        case 6:
            let first = UInt32(u16(t + 6)), count = UInt32(u16(t + 8))
            guard code >= first, code - first < count, t + 10 + Int(code - first) * 2 + 2 <= bytes.count else { return nil }
            return u16(t + 10 + Int(code - first) * 2)
        case 12:
            guard t + 16 <= bytes.count else { return nil }
            let groups = Int(u32(t + 12))
            for g in 0..<groups where t + 16 + g * 12 + 12 <= bytes.count {
                let at = t + 16 + g * 12
                let start = u32(at), end = u32(at + 4)
                if code >= start, code <= end { return CGGlyph(truncatingIfNeeded: u32(at + 8) + code - start) }
            }
            return nil
        default:
            return nil
        }
    }

    private func u16(_ at: Int) -> UInt16 { at + 1 < bytes.count ? UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1]) : 0 }

    private func u32(_ at: Int) -> UInt32 { UInt32(u16(at)) << 16 | UInt32(u16(at + 2)) }
}

// MARK: - CGPDF helpers

/// A PDF dictionary (the CGPDF types are all `OpaquePointer`: these wrappers keep their helpers apart).
nonisolated struct PDFDict {
    let ref: CGPDFDictionaryRef
    /// An inline image's (BI … ID): its keys are abbreviated (W, H, BPC, CS…), looked up by the full names.
    var inline = false

    init(_ ref: CGPDFDictionaryRef) { self.ref = ref }

    init?(_ object: CGPDFObjectRef?) {
        var value: CGPDFDictionaryRef?
        guard let object, CGPDFObjectGetValue(object, .dictionary, &value), let value else { return nil }
        ref = value
    }

    func name(_ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        return CGPDFDictionaryGetName(ref, name(of: key), &value) ? value.map { String(cString: $0) } : nil
    }

    func dictionary(_ key: String) -> PDFDict? {
        var value: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(ref, name(of: key), &value) ? value.map(PDFDict.init) : nil
    }

    func array(_ key: String) -> PDFArray? {
        var value: CGPDFArrayRef?
        return CGPDFDictionaryGetArray(ref, name(of: key), &value) ? value.map(PDFArray.init) : nil
    }

    func stream(_ key: String) -> PDFStream? {
        var value: CGPDFStreamRef?
        return CGPDFDictionaryGetStream(ref, name(of: key), &value) ? value.map { PDFStream($0) } : nil
    }

    func number(_ key: String) -> Double? {
        var value: CGPDFReal = 0
        return CGPDFDictionaryGetNumber(ref, name(of: key), &value) ? Double(value) : nil
    }

    func integer(_ key: String) -> Int? {
        var value: CGPDFInteger = 0
        return CGPDFDictionaryGetInteger(ref, name(of: key), &value) ? Int(value) : nil
    }

    func boolean(_ key: String) -> Bool? {
        var value: CGPDFBoolean = 0
        return CGPDFDictionaryGetBoolean(ref, name(of: key), &value) ? value != 0 : nil
    }

    private func name(of key: String) -> String { inline ? Self.inlineKeys[key] ?? key : key }

    private static let inlineKeys = ["Width": "W", "Height": "H", "BitsPerComponent": "BPC", "ColorSpace": "CS",
                                     "Decode": "D", "ImageMask": "IM", "Filter": "F", "DecodeParms": "DP", "Interpolate": "I"]

    func object(_ key: String) -> CGPDFObjectRef? {
        var value: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(ref, name(of: key), &value) ? value : nil
    }
}

nonisolated struct PDFArray {
    let ref: CGPDFArrayRef

    init(_ ref: CGPDFArrayRef) { self.ref = ref }

    var count: Int { CGPDFArrayGetCount(ref) }

    func number(at i: Int) -> Double? {
        var value: CGPDFReal = 0
        return CGPDFArrayGetNumber(ref, i, &value) ? Double(value) : nil
    }

    func name(at i: Int) -> String? {
        var value: UnsafePointer<CChar>?
        return CGPDFArrayGetName(ref, i, &value) ? value.map { String(cString: $0) } : nil
    }

    func array(at i: Int) -> PDFArray? {
        var value: CGPDFArrayRef?
        return CGPDFArrayGetArray(ref, i, &value) ? value.map(PDFArray.init) : nil
    }

    func dictionary(at i: Int) -> PDFDict? {
        var value: CGPDFDictionaryRef?
        return CGPDFArrayGetDictionary(ref, i, &value) ? value.map(PDFDict.init) : nil
    }

    func stream(at i: Int) -> PDFStream? {
        var value: CGPDFStreamRef?
        return CGPDFArrayGetStream(ref, i, &value) ? value.map { PDFStream($0) } : nil
    }

    func object(at i: Int) -> CGPDFObjectRef? {
        var value: CGPDFObjectRef?
        return CGPDFArrayGetObject(ref, i, &value) ? value : nil
    }
}

nonisolated struct PDFStream {
    let ref: CGPDFStreamRef
    /// An inline image (BI … EI), which CGPDFScanner hands over as a stream with abbreviated keys.
    var inline = false

    init(_ ref: CGPDFStreamRef, inline: Bool = false) {
        self.ref = ref
        self.inline = inline
    }

    /// The stream decoded (every filter applied).
    var data: Data? {
        var format = CGPDFDataFormat.raw
        return CGPDFStreamCopyData(ref, &format) as Data?
    }

    var dictionary: PDFDict? {
        CGPDFStreamGetDictionary(ref).map { ref in
            var dictionary = PDFDict(ref)
            dictionary.inline = inline
            return dictionary
        }
    }
}
