// Print & Cut: registration marks in the Silhouette standard (the same as Studio's and inkscape-silhouette's).
// The machine reads the marks with the optical sensor before cutting and corrects position, scale and rotation;
// the cuts are relative to them, so only the area between the marks is cut.
import CoreText
import CutlineKit
import SwiftUI

/// Where the marks are on the page (mm), per document. Cutline's default is the one validated on the Portrait 4; a .studio3
/// brings Studio's (a 15.875 mm = 5/8" margin and corner marks of 20 or 10 mm), which the machine has to look for
/// in the right place to find a sheet printed by Studio.
nonisolated struct MarksConfig: Hashable, Codable, Sendable {
    /// The keys stored on disk keep the names of the 1.0 format (Portuguese), so older files still open.
    enum CodingKeys: String, CodingKey {
        case left = "esquerda", top = "topo", right = "direita", bottom = "baixo", length = "comprimento", strokeWidth = "espessura"
    }

    /// From the page edge to the marks' outer corner.
    var left = 15.0, top = 15.0, right = 15.0, bottom = 15.0
    /// Length of the L corner marks and width of the lines (TB51 and TB53 in the send).
    var length = 20.0, strokeWidth = 0.5

    static let defaultValue = MarksConfig()
    /// Silhouette Studio's default on an A4 sheet (5/8 in. from the edge), as seen in its files.
    static let studio = MarksConfig(margin: 15.875)
    /// The top-left corner square.
    static let square = 5.0
    /// Slack around each mark where nothing should be printed (it confuses the sensor).
    static let slack = 2.0

    init() {}

    init(margin: Double, length: Double = 20) {
        (left, top, right, bottom) = (margin, margin, margin, margin)
        self.length = length
    }

    /// The ones from the Silhouette Studio file.
    init(_ studio: StudioDocument.RegistrationMarks) {
        left = studio.left
        top = studio.top
        right = studio.right
        bottom = studio.bottom
        length = studio.length
        strokeWidth = studio.thickness
    }

    /// Area between the marks on the sheet as it goes on the mat (its own mm): the driver only cuts in here.
    private func fedArea(_ size: CGSize) -> CGRect {
        CGRect(x: left, y: top, width: size.width - left - right, height: size.height - top - bottom)
    }

    /// Area between the marks on an artboard (canvas mm).
    func area(on sheet: SheetFrame) -> CGRect { fedArea(sheet.fedSize).applying(sheet.fromFed) }

    /// What the machine looks for before cutting a sheet (in the mm of the sheet as it goes on the mat).
    func logLines(for sheet: SheetFrame) -> Cutter.Registration {
        let a = fedArea(sheet.fedSize)
        return Cutter.Registration(originX: a.minX, originY: a.minY, width: a.width, length: a.height,
                                   markLength: length, markThickness: strokeWidth)
    }

    /// Black rectangles that make up the marks on an artboard (canvas mm): on the sheet as it goes on the mat, the square
    /// in the top-left corner and the L corner marks at the top-right and bottom-left corners (on a turned landscape
    /// artboard that is its bottom-left corner, and its top-left and bottom-right ones).
    func rectangles(on sheet: SheetFrame) -> [CGRect] { fedRectangles(sheet.fedSize).map { $0.applying(sheet.fromFed) } }

    private func fedRectangles(_ size: CGSize) -> [CGRect] {
        let a = fedArea(size), e = strokeWidth, l = length, q = Self.square
        return [
            CGRect(x: a.minX, y: a.minY, width: q, height: q),
            CGRect(x: a.maxX - l, y: a.minY, width: l, height: e), CGRect(x: a.maxX - e, y: a.minY, width: e, height: l),   // ┐
            CGRect(x: a.minX, y: a.maxY - e, width: l, height: e), CGRect(x: a.minX, y: a.maxY - l, width: e, height: l),   // └
        ]
    }

    /// Where not to put art or cuts on an artboard (canvas mm): outside the area between the marks and around each mark.
    /// Paint with the even-odd rule.
    func forbiddenZone(on sheet: SheetFrame) -> Path { fedForbiddenZone(sheet.fedSize).applying(sheet.fromFed) }

    private func fedForbiddenZone(_ size: CGSize) -> Path {
        let a = fedArea(size), l = length, q = Self.square
        var zone = Path(CGRect(origin: .zero, size: size))
        zone.addRect(a)
        let boxes = [CGRect(x: a.minX, y: a.minY, width: q, height: q),
                      CGRect(x: a.maxX - l, y: a.minY, width: l, height: l),
                      CGRect(x: a.minX, y: a.maxY - l, width: l, height: l)]
        for box in boxes { zone.addRect(box.insetBy(dx: -Self.slack, dy: -Self.slack).intersection(a)) }
        return zone
    }

    /// Equal margin on all four sides (the Page panel edits it this way); nil if they differ.
    var margin: Double? { Set([left, top, right, bottom]).count == 1 ? left : nil }

    /// The scale check printed in an artboard's bottom margin, under the right end of the area between the marks.
    /// nil when the margin or the area is too small for it.
    func scaleCheck(on sheet: SheetFrame) -> ScaleCheck? {
        let size = sheet.fedSize, a = fedArea(size)
        let y = a.maxY + Self.slack + ScaleCheck.drop
        guard a.width >= ScaleCheck.length + 10, size.height - y >= ScaleCheck.paperEdge else { return nil }
        let start = CGPoint(x: a.maxX - ScaleCheck.length, y: y)
        // The note stays clear of the bottom-left corner mark and the slack around it.
        return ScaleCheck(start: start, toCanvas: sheet.fromFed, noteRoom: start.x - ScaleCheck.noteGap - (a.minX + length + Self.slack))
    }
}

/// A 50 mm line with a note to print at 100 %, in the bottom margin of a Print & Cut sheet. A sheet printed at another
/// scale ("fit to page" on a phone or in another app) still has its marks found by the machine, which then cuts at the
/// file's size and misses the art (a report on 08/11/2026: printed at 91 %). A ruler on this line shows it before the
/// cut. It sits outside the area between the marks (nothing is cut there) and away from the three marks the sensor
/// looks for. Coordinates in the sheet's mm as it goes on the mat.
nonisolated struct ScaleCheck: Sendable {
    /// From the outer edge of one end tick to the other's.
    static let length = 50.0
    static let lineWidth = 0.3
    /// Height of the end ticks.
    static let tick = 2.0
    /// From the slack under the area between the marks to the line.
    static let drop = 3.5
    /// Room left under the line: printers leave the last 3 to 5 mm of the paper blank.
    static let paperEdge = 5.0
    /// The note's size (6.5 pt) and its gap to the line.
    static let noteSize = 6.5 * 25.4 / 72
    static let noteGap = 2.0

    /// The line's left end.
    let start: CGPoint
    /// Sheet mm → canvas mm.
    let toCanvas: CGAffineTransform
    /// Width available for the note, left of the line.
    let noteRoom: Double

    /// The line and its end ticks.
    var rectangles: [CGRect] {
        let w = Self.lineWidth, l = Self.length, t = Self.tick
        return [CGRect(x: start.x, y: start.y - w / 2, width: l, height: w),
                CGRect(x: start.x, y: start.y - t / 2, width: w, height: t),
                CGRect(x: start.x + l - w, y: start.y - t / 2, width: w, height: t)]
    }

    /// The note's baseline ends here (right-aligned), just under the line's height.
    var noteEnd: CGPoint { CGPoint(x: start.x - Self.noteGap, y: start.y + 0.8) }

    static var note: String { String(localized: "Print at 100% (actual size): this line measures 50 mm.") }

    /// The note as one line of text in Helvetica, colored; nil when it doesn't fit beside the line.
    func noteLine(color: CGColor) -> (line: CTLine, width: Double)? {
        let font = CTFontCreateWithName("Helvetica" as CFString, Self.noteSize, nil)
        let text = NSAttributedString(string: Self.note, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        let line = CTLineCreateWithAttributedString(text)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        return width <= noteRoom ? (line, width) : nil
    }

    /// Draws the line and, if it fits, the note in a context in canvas mm (y down).
    func draw(in cg: CGContext, color: CGColor) {
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.concatenate(toCanvas)
        cg.setFillColor(color)
        cg.fill(rectangles)
        guard let (line, width) = noteLine(color: color) else { return }
        cg.textMatrix = .identity
        cg.translateBy(x: noteEnd.x - width, y: noteEnd.y)
        cg.scaleBy(x: 1, y: -1)
        cg.textPosition = .zero
        CTLineDraw(line, cg)
    }
}

/// How an artboard goes on the cutting mat (and into the machine), as Silhouette Studio does it: as it is, its top-left
/// corner at the mat's; or, a landscape artboard, turned a quarter turn clockwise (its left edge goes in first, its top
/// edge along the right side), except on the square mats, which take it as it is (seen in Studio with REA, 05/11/2026:
/// it keeps `TB50,0` and turns the coordinates itself). "Fed" mm: x across the machine, y along the feed, from the corner
/// that goes in first.
nonisolated struct SheetFrame: Sendable {
    /// The artboard (canvas mm).
    let rect: CGRect
    let turned: Bool

    /// The sheet's size as it goes on the mat: across × along.
    var fedSize: CGSize { turned ? CGSize(width: rect.height, height: rect.width) : rect.size }

    /// Canvas mm → the sheet's fed mm. Turned: across = H − y, along = x (from the artboard's corner).
    var toFed: CGAffineTransform {
        turned ? CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: rect.minY + rect.height, ty: -rect.minX)
            : CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
    }

    var fromFed: CGAffineTransform { toFed.inverted() }
}

nonisolated extension Document {
    /// The square mats: a landscape artboard fits them as it is (Studio doesn't turn it there).
    static let squareMats: Set<CuttingMat> = [.cameo12x12, .electrostatic12x12, .cameoPlus15x15, .cameoPro24x24]

    /// How an artboard goes on the mat: a landscape one turned, unless the document's mat is a square one.
    func sheetFrame(_ artboard: Artboard) -> SheetFrame {
        let square = withMat && cuttingMatSetting.map(Self.squareMats.contains) == true
        return SheetFrame(rect: artboard.rect, turned: artboard.isLandscape && !square)
    }
}

extension Document {
    /// Turns the marks on or off (stays in the file; one undo step).
    func toggleMarks() {
        registrar()
        marks.toggle()
    }

    /// What the machine reads before cutting an artboard (nil without the marks).
    func registrationToSend(_ artboard: Artboard) -> Cutter.Registration? { marks ? marksConfig.logLines(for: sheetFrame(artboard)) : nil }

    /// Changes the marks' position or size (stays in the file; consecutive adjustments are one undo step).
    func setMarks(_ newOne: MarksConfig) {
        guard newOne != marksConfig else { return }
        registerAdjustment("marcas")
        marksConfig = newOne
    }

    /// Objects of an artboard that go to the machine and go past the area between the marks (what's outside isn't cut).
    func objectsOutsideMarks(_ artboard: Artboard) -> Int {
        let area = marksConfig.area(on: sheetFrame(artboard))
        return cutLines(on: artboard).filter { config($0.color).sends }
            .flatMap(\.objects)
            .filter { !area.contains($0.shapePath.boundingRect) }
            .count
    }
}

// MARK: - Page (cutting mat) and sending

extension Document {
    /// Last cutting mat choice (for new documents).
    nonisolated static var lastMat: Bool {
        UserDefaults.standard.object(forKey: "comBase") as? Bool ?? true
    }

    /// With or without the cutting mat (stays in the file, with undo, and applies to the next documents).
    func setMat(_ newOne: Bool) {
        UserDefaults.standard.set(newOne, forKey: "comBase")
        guard newOne != withMat else { return }
        registrar()
        withMat = newOne
    }

    /// Last mat chosen (for new documents); nil = the machine's default.
    nonisolated static var lastCuttingMat: CuttingMat? {
        UserDefaults.standard.string(forKey: "baseDeCorte").flatMap(CuttingMat.init(rawValue:))
    }

    /// The mat that goes to the machine: the chosen one, if it accepts it; otherwise, its default. "No mat" = `.none`.
    func base(to hardware: Hardware) -> CuttingMat {
        guard withMat else { return .none }
        if let cuttingMatSetting, hardware.supportedCuttingMats.contains(cuttingMatSetting) { return cuttingMatSetting }
        return hardware.defaultCuttingMat ?? .none
    }

    /// Picks the mat (Page panel): "no mat" turns the mat off; the others turn it on. Stays in the file, with undo,
    /// and applies to the next documents.
    func setMat(_ newOne: CuttingMat) {
        if newOne == .none { return setMat(false) }
        UserDefaults.standard.set(true, forKey: "comBase")
        UserDefaults.standard.set(newOne.rawValue, forKey: "baseDeCorte")
        guard !withMat || cuttingMatSetting != newOne else { return }
        registrar()
        withMat = true
        cuttingMatSetting = newOne
    }

    /// What goes to the machine's queue: an artboard's enabled colors (in the mm of the sheet as it goes on the mat), its
    /// marks (Print & Cut), its size on the mat and the mat.
    func job(name: String, artboard: Artboard) -> Job {
        Job(name: name, origin: ObjectIdentifier(self), layers: layersToSend(on: artboard), logLines: registrationToSend(artboard),
            withMat: withMat, base: cuttingMatSetting, trackEnhancing: trackEnhancing, media: sheetFrame(artboard).fedSize)
    }

    /// Track enhancing on or off for this document's sends (stays in the file, with undo).
    func setTrackEnhancing(_ on: Bool) {
        guard on != trackEnhancing else { return }
        registrar()
        trackEnhancing = on
    }
}
