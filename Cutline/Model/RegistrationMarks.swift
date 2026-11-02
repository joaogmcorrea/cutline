// Print & Cut: registration marks in the Silhouette standard (the same as Studio's and inkscape-silhouette's).
// The machine reads the marks with the optical sensor before cutting and corrects position, scale and rotation;
// the cuts are relative to them, so only the area between the marks is cut.
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

    /// Area between the marks (page mm): the driver only cuts in here.
    var area: CGRect {
        let page = Document.page
        return CGRect(x: left, y: top, width: page.width - left - right, height: page.height - top - bottom)
    }

    /// What the machine looks for before cutting.
    var logLines: Cutter.Registration {
        let a = area
        return Cutter.Registration(originX: a.minX, originY: a.minY, width: a.width, length: a.height,
                                   markLength: length, markThickness: strokeWidth)
    }

    /// Black rectangles that make up the marks (page mm): the square in the top-left corner and the
    /// L corner marks at the top-right and bottom-left corners.
    var rectangles: [CGRect] {
        let a = area, e = strokeWidth, l = length, q = Self.square
        return [
            CGRect(x: a.minX, y: a.minY, width: q, height: q),
            CGRect(x: a.maxX - l, y: a.minY, width: l, height: e), CGRect(x: a.maxX - e, y: a.minY, width: e, height: l),   // ┐
            CGRect(x: a.minX, y: a.maxY - e, width: l, height: e), CGRect(x: a.minX, y: a.maxY - l, width: e, height: l),   // └
        ]
    }

    /// Where not to put art or cuts: outside the area between the marks and around each mark.
    /// Paint with the even-odd rule.
    var forbiddenZone: Path {
        let a = area, l = length, q = Self.square
        var zone = Path(CGRect(origin: .zero, size: Document.page))
        zone.addRect(a)
        let boxes = [CGRect(x: a.minX, y: a.minY, width: q, height: q),
                      CGRect(x: a.maxX - l, y: a.minY, width: l, height: l),
                      CGRect(x: a.minX, y: a.maxY - l, width: l, height: l)]
        for box in boxes { zone.addRect(box.insetBy(dx: -Self.slack, dy: -Self.slack).intersection(a)) }
        return zone
    }

    /// Equal margin on all four sides (the Page panel edits it this way); nil if they differ.
    var margin: Double? { Set([left, top, right, bottom]).count == 1 ? left : nil }
}

extension Document {
    /// Turns the marks on or off (stays in the file; one undo step).
    func toggleMarks() {
        registrar()
        marks.toggle()
    }

    /// What the machine reads before cutting (nil without the marks).
    var registrationToSend: Cutter.Registration? { marks ? marksConfig.logLines : nil }

    /// Changes the marks' position or size (stays in the file; consecutive adjustments are one undo step).
    func setMarks(_ newOne: MarksConfig) {
        guard newOne != marksConfig else { return }
        registerAdjustment("marcas")
        marksConfig = newOne
    }

    /// Objects that go to the machine and go past the area between the marks (what's outside isn't cut).
    var objectsOutsideMarks: Int {
        let area = marksConfig.area
        return cutLines.filter { config($0.color).sends }
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

    /// What goes to the machine's queue: the enabled colors, the marks (Print & Cut) and the mat.
    func job(name: String) -> Job {
        Job(name: name, origin: ObjectIdentifier(self), layers: layersToSend, logLines: registrationToSend,
                 withMat: withMat, base: cuttingMatSetting)
    }
}
