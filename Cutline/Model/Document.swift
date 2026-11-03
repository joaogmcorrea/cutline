// The editor's document: objects in mm on the A4 page, selection, tool and undo.
// The file (save, open, import from Studio) is in Model/DocumentFile.swift.
import CutlineKit
import ImageIO
import Observation
import SwiftUI

/// Color always in CMYK (the document goes to print); RGB is only for showing on screen.
nonisolated struct CMYK: Hashable, Codable, Sendable {
    var c: Double, m: Double, y: Double, k: Double   // 0–100

    /// Naive conversion, without an ICC profile (in the future: ColorSync with a real CMYK profile).
    var color: Color {
        let f = { (v: Double) in 1 - v / 100 }
        return Color(red: f(c) * f(k), green: f(m) * f(k), blue: f(y) * f(k))
    }

    var summaryText: String { "CMYK (\(Int(c)), \(Int(m)), \(Int(y)), \(Int(k)))" }

    static let red = CMYK(c: 0, m: 100, y: 100, k: 0)

    /// From RGB (0–1), with the same naive conversion, rounded to 1 % so equal colors group together.
    init(red r: Double, green g: Double, blue b: Double) {
        let limit = { (v: Double) in min(max(v, 0), 1) }
        let (r, g, b) = (limit(r), limit(g), limit(b))
        let k = 1 - max(r, g, b)
        guard k < 1 else {
            self.init(c: 0, m: 0, y: 0, k: 100)
            return
        }
        let channel = { (v: Double) in ((1 - v - k) / (1 - k) * 100).rounded() }
        self.init(c: channel(r), m: channel(g), y: channel(b), k: (k * 100).rounded())
    }

    init(c: Double, m: Double, y: Double, k: Double) {
        self.c = c
        self.m = m
        self.y = y
        self.k = k
    }

    /// Palette like Silhouette Studio's: grays + 12 hues in 5 tints.
    static let swatches: [CMYK] = {
        let grays = [0.0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 95, 100].map { CMYK(c: 0, m: 0, y: 0, k: $0) }
        let hues: [[Double]] = [[0, 100, 100, 0], [0, 100, 40, 0], [30, 100, 0, 0], [70, 80, 0, 0], [100, 50, 0, 0],
                                   [100, 0, 0, 0], [80, 0, 50, 0], [70, 0, 100, 0], [30, 0, 100, 0], [0, 0, 100, 0],
                                   [0, 50, 100, 0], [0, 60, 100, 45]]
        let tints = [1, 0.75, 0.5, 0.3, 0.15].flatMap { f in
            hues.map { v in CMYK(c: (v[0] * f).rounded(), m: (v[1] * f).rounded(), y: (v[2] * f).rounded(), k: (v[3] * f).rounded()) }
        }
        return grays + tints
    }()
}

/// A free path's node. Coordinates are relative to the object's frame (0…1 on both axes), so the
/// path follows the frame when moving and resizing; `input`/`output` are the control points.
nonisolated struct Node: Hashable, Codable, Sendable {
    /// The keys stored on disk keep the names of the 1.0 format (Portuguese), so older files still open.
    enum CodingKeys: String, CodingKey {
        case point = "ponto", input = "entrada", output = "saida"
    }

    var point: CGPoint
    var input: CGPoint?
    var output: CGPoint?
}

nonisolated struct Subpath: Hashable, Codable, Sendable {

    /// The keys stored on disk keep the names of the 1.0 format (Portuguese), so older files still open.

    enum CodingKeys: String, CodingKey {

        case nodes = "nos", closed = "fechado"

    }

    var nodes: [Node]
    var closed = true
}

nonisolated enum ShapeKind: Hashable, Codable, Sendable {
    /// The keys stored on disk keep the names of the 1.0 format (Portuguese), so older files still open.
    enum CodingKeys: String, CodingKey {
        case rectangle = "retangulo", ellipse = "elipse", star = "estrela", shapePath = "caminho", text = "texto"
    }
    enum RectangleCodingKeys: String, CodingKey { case radius = "raio" }
    enum StarCodingKeys: String, CodingKey { case points = "pontas", innerRadius = "raioInterno" }

    /// Corner radius in mm.
    case rectangle(radius: Double)
    case ellipse
    /// Inner radius as a fraction of the outer one.
    case star(points: Int, innerRadius: Double)
    /// Free path (pen, Pathfinder, imported, shapes edited point by point).
    case shapePath([Subpath])
    /// Text: the letters' outline (CoreText) stretched to the frame; cuts along the letters' edges.
    case text(TextBox)

    var name: String {
        switch self {
        case .rectangle: String(localized: "Rectangle")
        case .ellipse: String(localized: "Ellipse")
        case .star: String(localized: "Star")
        case .shapePath: String(localized: "Path")
        case .text(let t): t.content.isEmpty ? String(localized: "Text") : t.content
        }
    }
}

nonisolated struct TextBox: Hashable, Codable, Sendable {

    /// The keys stored on disk keep the names of the 1.0 format (Portuguese), so older files still open.

    enum CodingKeys: String, CodingKey {

        case content = "conteudo", style = "estilo", textRuns = "trechos", alignment = "alinhamento", bullet = "marcador", leftIndent = "recuoEsquerda", rightIndent = "recuoDireita", firstLineIndent = "recuoPrimeira", spaceBefore = "espacoAntes", spaceAfter = "espacoDepois"

    }

    var content = String(localized: "Text")
    /// Style of the whole text when it is uniform (`textRuns` empty) and of the empty text.
    var style = CharacterStyle()
    /// Style per run, in order, covering the whole text (lengths in UTF-16, like the text field's
    /// NSRange); empty = the whole text with `style`. Always normalized (Model/TextEditing.swift).
    var textRuns: [TextRun] = []

    // Paragraph panel (each line is a paragraph; the text doesn't wrap by itself): applies to the whole text.
    var alignment = TextAlignmentKind.left
    var bullet = TextBullet.plain
    /// Indents and space between paragraphs, in pt.
    var leftIndent = 0.0
    var rightIndent = 0.0
    var firstLineIndent = 0.0
    var spaceBefore = 0.0
    var spaceAfter = 0.0

    init(content: String = String(localized: "Text"), style: CharacterStyle = CharacterStyle()) {
        self.content = content
        self.style = style
    }
}

/// Style of a text run (Character panel and control bar).
nonisolated struct CharacterStyle: Hashable, Codable, Sendable {
    /// The keys stored on disk keep the names of the 1.0 format (Portuguese), so older files still open.
    enum CodingKeys: String, CodingKey {
        case font = "fonte", size = "tamanho", postscript, leading = "entrelinha", kerning, tracking, offset = "deslocamento", position = "posicao", rotation = "rotacao", allCaps = "caixaAlta", smallCaps = "versalete", underline = "sublinhado", strikethrough = "tachado"
    }

    /// Family name (e.g. "Helvetica Neue").
    var font = "Helvetica Neue"
    /// Size in pt.
    var size = 36.0
    /// Face chosen in the Style menu (PostScript name, e.g. "Montserrat-Bold"); nil = the family's regular one.
    var postscript: String?
    /// Distance from the previous baseline to this line's, in pt (the line uses the largest); nil = automatic.
    var leading: Double?
    /// Kerning in thousandths of an em; nil = the font's (metric); 0 = no kerning.
    var kerning: Double?
    /// Extra space between letters, in thousandths of an em.
    var tracking = 0.0
    /// Baseline shift, in pt (positive = up).
    var offset = 0.0
    var position = CharacterPosition.normal
    /// Each letter rotated around its own center, in degrees (positive = counterclockwise, as in Illustrator).
    var rotation = 0.0
    var allCaps = false
    var smallCaps = false
    var underline = false
    var strikethrough = false

    init() {}

    /// Tolerant reading (missing fields keep the default).
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(reading: c)
    }

    /// Reads the fields from a container with the same keys (also the old `TextBox`'s, which had them loose).
    nonisolated init<Key: CodingKey>(reading c: KeyedDecodingContainer<Key>) throws {
        func value<T: Decodable>(_ name: String, _ kind: T.Type) throws -> T? {
            guard let key = Key(stringValue: name) else { return nil }
            return try c.decodeIfPresent(kind, forKey: key)
        }
        font = try value("fonte", String.self) ?? font
        size = try value("tamanho", Double.self) ?? size
        postscript = try value("postscript", String.self)
        leading = try value("entrelinha", Double.self)
        kerning = try value("kerning", Double.self)
        tracking = try value("tracking", Double.self) ?? tracking
        offset = try value("deslocamento", Double.self) ?? offset
        position = try value("posicao", CharacterPosition.self) ?? position
        rotation = try value("rotacao", Double.self) ?? rotation
        allCaps = try value("caixaAlta", Bool.self) ?? allCaps
        smallCaps = try value("versalete", Bool.self) ?? smallCaps
        underline = try value("sublinhado", Bool.self) ?? underline
        strikethrough = try value("tachado", Bool.self) ?? strikethrough
    }
}

/// Superscript and subscript like Illustrator's: 58.3 % of the size, at 33.3 % of the size from the baseline.
nonisolated enum CharacterPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case normal, superscripted = "sobrescrito", subscripted = "subscrito"
    var id: Self { self }
}

/// A run with one style (length in UTF-16).
nonisolated struct TextRun: Hashable, Codable, Sendable {
    /// The keys stored on disk keep the names of the 1.0 format (Portuguese), so older files still open.
    enum CodingKeys: String, CodingKey {
        case length = "comprimento", style = "estilo"
    }

    var length: Int
    var style: CharacterStyle
}

/// Tolerant reading: v0.6.0 files only have content, font and size, loose in the text.
extension TextBox {
    nonisolated private struct FreeKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        if let style = try c.decodeIfPresent(CharacterStyle.self, forKey: .style) {
            self.style = style
        } else {
            style = try CharacterStyle(reading: decoder.container(keyedBy: FreeKey.self))
        }
        textRuns = try c.decodeIfPresent([TextRun].self, forKey: .textRuns) ?? []
        alignment = try c.decodeIfPresent(TextAlignmentKind.self, forKey: .alignment) ?? alignment
        bullet = try c.decodeIfPresent(TextBullet.self, forKey: .bullet) ?? bullet
        leftIndent = try c.decodeIfPresent(Double.self, forKey: .leftIndent) ?? leftIndent
        rightIndent = try c.decodeIfPresent(Double.self, forKey: .rightIndent) ?? rightIndent
        firstLineIndent = try c.decodeIfPresent(Double.self, forKey: .firstLineIndent) ?? firstLineIndent
        spaceBefore = try c.decodeIfPresent(Double.self, forKey: .spaceBefore) ?? spaceBefore
        spaceAfter = try c.decodeIfPresent(Double.self, forKey: .spaceAfter) ?? spaceAfter
    }
}

/// Alignment of the lines relative to the text's point (like Illustrator's point text).
nonisolated enum TextAlignmentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case left = "esquerda", center = "centro", right = "direita"
    var id: Self { self }
}

/// Bullet before each paragraph that has letters.
nonisolated enum TextBullet: String, Codable, CaseIterable, Identifiable, Sendable {
    case plain = "nenhum", dot = "bolinha", numbers = "numeros"
    var id: Self { self }
}

/// Guides in mm (vertical in x, horizontal in y), dragged from the rulers.
nonisolated struct Guides: Hashable, Codable, Sendable {
    /// The keys stored on disk keep the names of the 1.0 format (Portuguese), so older files still open.
    enum CodingKeys: String, CodingKey {
        case verticals = "verticais", horizontals = "horizontais"
    }

    var verticals: [Double] = []
    var horizontals: [Double] = []
    var emptyOnes: Bool { verticals.isEmpty && horizontals.isEmpty }
}

/// Affine transform stored in the file (x' = a·x + c·y + tx; y' = b·x + d·y + ty).
nonisolated struct Transform: Hashable, Codable, Sendable {
    var a, b, c, d, tx, ty: Double

    init(_ t: CGAffineTransform) {
        a = t.a
        b = t.b
        c = t.c
        d = t.d
        tx = t.tx
        ty = t.ty
    }

    var cg: CGAffineTransform { CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty) }
}

/// Image that fills the shape (the Print & Cut artwork), clipped by the outline.
nonisolated struct ImageInShape: Hashable, Codable, Sendable {
    /// The keys stored on disk keep the names of the 1.0 format (Portuguese), so older files still open.
    enum CodingKeys: String, CodingKey {
        case key = "chave", transform = "transformacao"
    }

    /// Key in `Document.images`.
    var key: String
    /// Image pixel (origin at the top-left corner) → coordinates relative to the frame (0…1).
    var transform: Transform
}

/// Silhouette Studio's line styles: the dashed ones become perforated cuts.
nonisolated enum LineStyle: Int, Codable, CaseIterable, Identifiable, Sendable {
    case solid, dashed1, dashed2, dashed3, dashed4

    var id: Self { self }

    /// Cut piece and uncut piece, in mm (nil = solid).
    var defaultValue: [Double]? {
        switch self {
        case .solid: nil
        case .dashed1: [0.8, 0.8]
        case .dashed2: [2, 1.5]
        case .dashed3: [3, 4]
        case .dashed4: [4, 1]
        }
    }

    var name: String {
        guard let defaultValue else { return String(localized: "Solid") }
        let mm = defaultValue.map { $0.formatted(.number.precision(.fractionLength(0...1))) }
        return String(localized: "Dashed \(mm[0]) / \(mm[1]) mm")
    }
}

nonisolated enum LineCap: String, Codable, CaseIterable, Identifiable, Sendable {
    case straight = "reta", rounded = "arredondada", projected = "projetada"
    var id: Self { self }
    var cg: CGLineCap {
        switch self {
        case .straight: .butt
        case .rounded: .round
        case .projected: .square
        }
    }
}

nonisolated enum LineJoin: String, Codable, CaseIterable, Identifiable, Sendable {
    case sharp = "vivo", round = "arredondado", bevel = "chanfrado"
    var id: Self { self }
    var cg: CGLineJoin {
        switch self {
        case .sharp: .miter
        case .round: .round
        case .bevel: .bevel
        }
    }
}

nonisolated enum StrokeAlignment: String, Codable, CaseIterable, Identifiable, Sendable {
    case center = "centro", inside = "dentro", outside = "fora"
    var id: Self { self }
}

/// How the stroke is drawn and cut (color and width stay in the object, as before).
nonisolated struct StrokeStyleSettings: Hashable, Codable, Sendable {
    /// The keys stored on disk keep the names of the 1.0 format (Portuguese), so older files still open.
    enum CodingKeys: String, CodingKey {
        case line = "linha", cap = "ponta", join = "canto", miterLimit = "limiteCanto", alignment = "alinhamento"
    }

    var line = LineStyle.solid
    /// Cap, join and alignment only apply with width > 0 (printed stroke).
    var cap = LineCap.straight
    var join = LineJoin.sharp
    var miterLimit = 10.0
    var alignment = StrokeAlignment.center
}

nonisolated struct CanvasObject: Identifiable, Hashable, Codable, Sendable {

    /// The keys stored on disk keep the names of the 1.0 format (Portuguese), so older files still open.

    enum CodingKeys: String, CodingKey {

        case id, shape = "forma", frame = "quadro", strokeColor = "traco", strokeWidth = "espessura", style = "estilo", fill = "preenchimento", image = "imagem", cutsLine = "corta", layer = "camada", isHidden = "oculto", isLocked = "travado", label = "rotulo", groups = "grupos"

    }

    var id = UUID()
    var shape: ShapeKind
    /// The shape's box, in page mm (origin at the top-left corner).
    var frame: CGRect
    /// The stroke color defines the cut (as in Silhouette Studio).
    var strokeColor = CMYK.red
    /// In pt. 0 = a hairline visible on screen that doesn't print — cut only.
    var strokeWidth = 0.0
    var style = StrokeStyleSettings()
    var fill: CMYK?
    var image: ImageInShape?
    /// False: stays in the drawing (and in the print), but doesn't go to the machine.
    var cutsLine = true
    /// The object's layer (nil or one that no longer exists = the top one).
    var layer: UUID?
    var isHidden = false
    var isLocked = false
    /// Name given by the app (e.g. "União" from the Pathfinder); without it, the shape's name.
    var label: String?
    /// The object's groups, from the outermost to the innermost (Model/Groups.swift); empty = loose.
    var groups: [UUID] = []

    var name: String { label ?? (image != nil ? String(localized: "Image") : shape.name) }
}

/// Tolerant reading: missing fields (files from earlier versions) get the default value.
extension CanvasObject {
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(shape: try c.decode(ShapeKind.self, forKey: .shape), frame: try c.decode(CGRect.self, forKey: .frame))
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? id
        strokeColor = try c.decodeIfPresent(CMYK.self, forKey: .strokeColor) ?? strokeColor
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? strokeWidth
        style = try c.decodeIfPresent(StrokeStyleSettings.self, forKey: .style) ?? style
        fill = try c.decodeIfPresent(CMYK.self, forKey: .fill)
        image = try c.decodeIfPresent(ImageInShape.self, forKey: .image)
        cutsLine = try c.decodeIfPresent(Bool.self, forKey: .cutsLine) ?? cutsLine
        layer = try c.decodeIfPresent(UUID.self, forKey: .layer)
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? isHidden
        isLocked = try c.decodeIfPresent(Bool.self, forKey: .isLocked) ?? isLocked
        label = try c.decodeIfPresent(String.self, forKey: .label)
        groups = try c.decodeIfPresent([UUID].self, forKey: .groups) ?? []
    }
}

nonisolated enum Tool: String, CaseIterable, Identifiable, Sendable {
    case selection, direct, pen, addNode, deleteNode, text, rectangle, ellipse, star, eyedropper, hand, zoom

    var id: Self { self }

    var name: String {
        switch self {
        case .selection: String(localized: "Selection")
        case .direct: String(localized: "Direct Selection")
        case .pen: String(localized: "Pen")
        case .addNode: String(localized: "Add Anchor Point")
        case .deleteNode: String(localized: "Delete Anchor Point")
        case .text: String(localized: "Text")
        case .rectangle: String(localized: "Rectangle")
        case .ellipse: String(localized: "Ellipse")
        case .star: String(localized: "Star")
        case .eyedropper: String(localized: "Eyedropper")
        case .hand: String(localized: "Hand")
        case .zoom: String(localized: "Zoom")
        }
    }

    /// Illustrator's shortcuts (+ is also =, as there). Tracing an image is in File › Import (and dropping it).
    var keyEvent: Character {
        switch self {
        case .selection: "v"
        case .direct: "a"
        case .pen: "p"
        case .addNode: "+"
        case .deleteNode: "-"
        case .text: "t"
        case .rectangle: "m"
        case .ellipse: "l"
        case .star: "s"
        case .eyedropper: "i"
        case .hand: "h"
        case .zoom: "z"
        }
    }

    var createsShape: Bool { self == .rectangle || self == .ellipse || self == .star }
    /// The ones that show the nodes of the selected objects.
    var editsNodes: Bool { self == .direct || self == .addNode || self == .deleteNode }
}

/// The data lives outside the MainActor because macOS creates and reads documents on a background thread;
/// editing (extensions below) all happens on the main thread, where the interface uses the document.
@Observable
nonisolated final class Document: @unchecked Sendable {
    static let page = CGSize(width: 210, height: 297)   // A4, mm
    /// Cutting mat margin around the page, for drawing only.
    static let matMargin = 8.0

    var objects: [CanvasObject]
    var selection: Set<CanvasObject.ID> = []
    var tool = Tool.selection
    /// Colors and stroke of the next objects.
    var defaultStroke = CMYK.red
    var defaultFill: CMYK?
    var defaultStrokeWidth = 0.0
    var defaultStyle = StrokeStyleSettings()
    /// Which square of the Color panel is in front (X toggles).
    var colorTarget = ColorTarget.strokeColor
    /// Last colors chosen in the panel (up to 14).
    var recent: [CMYK]
    /// Layers, the top one first (Model/Layers.swift).
    var layers: [Layer]
    var activeLayer: UUID
    var guides: Guides
    /// Print & Cut registration marks on the page (Model/RegistrationMarks.swift): on/off and where they are.
    var marks: Bool
    var marksConfig: MarksConfig
    /// Cut with the cutting mat (the sticky plastic); without it, the machine pulls the sheet directly. New
    /// documents start with the last choice (Page panel).
    var withMat: Bool
    /// The mat chosen in the Page panel (nil = the machine's default; the machine gets one it accepts).
    var cuttingMatSetting: CuttingMat?
    /// Cut by line color (Model/Cutting.swift): saved settings and chosen order.
    var cuts: [CMYK: CutConfig]
    var cutOrder: [CMYK]
    /// Images (PNG or JPEG) used by the objects, by `ImageInShape`'s key.
    var images: [String: Data]
    /// Notice strip in the window (import summary, Pathfinder without a result…), until OK.
    var notice: String?
    /// Text being typed right on the canvas (Model/TextEditing.swift).
    var textEditing: TextEditing?
    /// Font and typography of the next texts: the last ones chosen (Character panel, control bar).
    var defaultText = TextBox(content: "")
    /// Selection in the text being typed (UTF-16): the Character panel and the bar act on it.
    var textSelection = NSRange(location: 0, length: 0)
    /// Style chosen with the cursor still (no selection): applies to the next letters typed.
    var typingStyle: CharacterStyle?
    /// Changes so the canvas gives the keyboard back to the text being edited (after a panel field).
    var focusCanvasText = 0
    /// Changes when File › Import… is chosen (the window opens the file panel).
    var importRequest = 0
    /// Changes when File › Print… is chosen (the window opens the print panel).
    var printRequest = 0
    /// Changes when File › Send… is chosen (the window opens the Send window).
    var sendRequest = 0
    /// Top-left corner of the test cut on the sheet, in mm (Model/Cutting.swift); doesn't go into the file.
    var testPosition = CGPoint(x: 25, y: 25)
    /// Opened from a .studio3: the window detaches the document from that file (see MainWindow).
    @ObservationIgnored var cameFromStudio: Bool
    /// The opened .studio3 and where each object came from, to write over it (Model/StudioSave.swift).
    @ObservationIgnored var studio: StudioOrigin?

    /// Changes on each undo step, so the undo/redo buttons update.
    fileprivate(set) var version = 0
    /// Undo is the window's (the same as the Edit menu); each registration also marks the document as
    /// changed, so macOS asks to save.
    @ObservationIgnored fileprivate weak var manager: UndoManager?
    @ObservationIgnored fileprivate var observers: [NSObjectProtocol] = []
    @ObservationIgnored fileprivate var lastAdjustment: (key: String, time: Date)?
    /// State before the text edit, registered in undo only when something changes (`registerSaved`).
    @ObservationIgnored fileprivate var savedState: ConnectionState?
    @ObservationIgnored fileprivate var decodedImages: [String: CGImage] = [:]

    init(objects: [CanvasObject] = [], cuts: [CMYK: CutConfig] = [:], cutOrder: [CMYK] = [],
         images: [String: Data] = [:], layers: [Layer] = [], activeLayer: UUID? = nil, recent: [CMYK] = [],
         guides: Guides = Guides(), marks: Bool = false, marksConfig: MarksConfig = .defaultValue, withMat: Bool? = nil,
         cuttingMatSetting: CuttingMat?? = nil, notice: String? = nil, cameFromStudio: Bool = false) {
        self.guides = guides
        self.marks = marks
        self.marksConfig = marksConfig
        self.withMat = withMat ?? Self.lastMat
        self.cuttingMatSetting = cuttingMatSetting ?? Self.lastCuttingMat
        let layers = layers.isEmpty ? [Layer(name: String(localized: "Layer \(1)"), color: 0)] : layers
        self.layers = layers
        self.activeLayer = activeLayer.flatMap { id in layers.first { $0.id == id }?.id } ?? layers[0].id
        self.recent = recent
        self.objects = objects
        self.cuts = cuts
        self.cutOrder = cutOrder
        self.images = images
        self.notice = notice
        self.cameFromStudio = cameFromStudio
    }
}

nonisolated enum ColorTarget: Sendable {
    case fill, strokeColor
}

/// What an undo step stores.
nonisolated private struct ConnectionState: Sendable {
    var objects: [CanvasObject]
    var cuts: [CMYK: CutConfig]
    var cutOrder: [CMYK]
    var layers: [Layer]
    var activeLayer: UUID
    var guides: Guides
    var marks: Bool
    var marksConfig: MarksConfig
    var withMat: Bool
    var cuttingMatSetting: CuttingMat?
}

extension Document {
    var selectedObjects: [CanvasObject] { objects.filter { selection.contains($0.id) } }

    func image(_ key: String) -> CGImage? {
        if let ready = decodedImages[key] { return ready }
        guard let payload = images[key], let font = CGImageSourceCreateWithData(payload as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(font, 0, nil) else { return nil }
        decodedImages[key] = image
        return image
    }

    // MARK: Undo

    /// Links the document to the window's undo.
    func use(_ updated: UndoManager?) {
        guard updated !== manager else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        manager = updated
        guard let updated else { return }
        updated.levelsOfUndo = 200
        observers = [Notification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange]
            .map { name in
                NotificationCenter.default.addObserver(forName: name, object: updated, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.version += 1 }
                }
            }
        version += 1
    }

    private var state: ConnectionState {
        get {
            ConnectionState(objects: objects, cuts: cuts, cutOrder: cutOrder, layers: layers, activeLayer: activeLayer,
                   guides: guides, marks: marks, marksConfig: marksConfig, withMat: withMat,
                   cuttingMatSetting: cuttingMatSetting)
        }
        set {
            objects = newValue.objects
            cuts = newValue.cuts
            cutOrder = newValue.cutOrder
            layers = newValue.layers
            activeLayer = newValue.activeLayer
            guides = newValue.guides
            marks = newValue.marks
            marksConfig = newValue.marksConfig
            withMat = newValue.withMat
            cuttingMatSetting = newValue.cuttingMatSetting
            selection.formIntersection(objects.map(\.id))
        }
    }

    var canUndo: Bool {
        _ = version
        return manager?.canUndo ?? false
    }

    var canRedo: Bool {
        _ = version
        return manager?.canRedo ?? false
    }

    /// Stores the state before a change (one ⌘Z step).
    func registrar() {
        let previous = state
        manager?.registerUndo(withTarget: self) { $0.restore(previous) }
        lastAdjustment = nil
        savedState = nil
        version += 1
    }

    /// Stores the current state without registering: text editing puts the text on the canvas before knowing whether
    /// anything will be typed (if empty, it disappears without leaving an undo step).
    func saveState() { savedState = state }

    func discardSavedState() { savedState = nil }

    /// Registers the undo from the stored state (or from the current one, if another change already used it): all the
    /// typing of a text edit becomes a single step.
    func registerSaved() {
        guard let previous = savedState else { return registrar() }
        manager?.registerUndo(withTarget: self) { $0.restore(previous) }
        lastAdjustment = nil
        savedState = nil
        version += 1
    }

    private func restore(_ previous: ConnectionState) {
        // Undo ends typing on the canvas; empty text (left by editing) never comes back.
        textEditing = nil
        savedState = nil
        let current = state
        manager?.registerUndo(withTarget: self) { $0.restore(current) }
        state = previous
        objects.removeAll(where: \.emptyText)
        version += 1
    }

    func undo() { manager?.undo() }
    func redo() { manager?.redo() }

    /// Values that change gradually (cut and color sliders): a single undo step while the same
    /// thing (`key`) is being changed without pausing more than 1.5 s.
    func registerAdjustment(_ key: String) {
        let now = Date()
        if let lastOne = lastAdjustment, lastOne.key == key, now.timeIntervalSince(lastOne.time) < 1.5 {
            lastAdjustment = (key, now)
            return
        }
        registrar()
        lastAdjustment = (key, now)
    }

    // MARK: Editing

    /// New object in the active layer, with the next objects' colors and stroke.
    func add(_ object: CanvasObject) {
        var updated = object
        updated.layer = activeLayer
        registrar()
        // Drawing on a hidden or locked layer shows and unlocks it (otherwise the object would disappear).
        if let i = layers.firstIndex(where: { $0.id == activeLayer }) {
            layers[i].visible = true
            layers[i].locked = false
        }
        objects.append(updated)
        selection = [updated.id]
    }

    /// Imported objects (tracing, PDF) in a single undo step, in the active layer, selected.
    func insertImported(_ newItems: [CanvasObject], images newOnes: [String: Data] = [:]) {
        guard !newItems.isEmpty else { return }
        registrar()
        images.merge(newOnes) { _, newOne in newOne }
        if let i = layers.firstIndex(where: { $0.id == activeLayer }) {
            layers[i].visible = true
            layers[i].locked = false
        }
        objects.append(contentsOf: newItems.map { var o = $0; o.layer = activeLayer; return o })
        selection = Set(newItems.map(\.id))
    }

    /// New object with the next objects' style.
    func newObject(_ shape: ShapeKind, frame: CGRect) -> CanvasObject {
        CanvasObject(shape: shape, frame: frame, strokeColor: defaultStroke, strokeWidth: defaultStrokeWidth, style: defaultStyle,
               fill: defaultFill)
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        registrar()
        objects.removeAll { selection.contains($0.id) }
        selection = []
    }

    /// Arrow keys: move the selection (repeated taps, without pausing more than 1.5 s, are one undo step).
    func moveSelection(dx: Double, dy: Double) {
        guard !selection.isEmpty else { return }
        registerAdjustment("setas")
        for i in objects.indices where selection.contains(objects[i].id) {
            objects[i].frame = objects[i].frame.offsetBy(dx: dx, dy: dy)
        }
    }

    /// Everything that can be moved (neither hidden nor locked).
    func selectAll() {
        selection = Set(objects.filter { !untouchable($0) }.map(\.id))
    }

    /// Copies the selected objects (⌘D offsets 5 mm; ⌥-drag, in place; ⌘ + arrow, beside) and selects the copies
    /// (the copies of a group form a new group).
    func duplicateSelection(offset: CGSize = CGSize(width: 5, height: 5)) {
        let copies = CanvasObject.copies(selectedObjects, offset: offset)
        guard !copies.isEmpty else { return }
        registrar()
        objects.append(contentsOf: copies)
        selection = Set(copies.map(\.id))
    }

    func clearGuides() {
        guard !guides.emptyOnes else { return }
        registrar()
        guides = Guides()
    }

    /// Changes the selected objects in a single undo step.
    func modifySelection(_ change: (inout CanvasObject) -> Void) {
        guard !selection.isEmpty else { return }
        registrar()
        for i in objects.indices where selection.contains(objects[i].id) { change(&objects[i]) }
    }

    // MARK: Colors and stroke (selection or, without a selection, the next objects)

    /// Color shown in the panel: the selection's (nil = none; `mixed` if they differ).
    func color(_ target: ColorTarget) -> (color: CMYK?, mixed: Bool) {
        let read = { (o: CanvasObject) -> CMYK? in target == .strokeColor ? (o.cutsLine ? o.strokeColor : nil) : o.fill }
        guard let first = selectedObjects.first else { return (target == .strokeColor ? defaultStroke : defaultFill, false) }
        let color = read(first)
        return (color, selectedObjects.contains { read($0) != color })
    }

    /// `color` nil = none (on the stroke: the object stops cutting). `final` = choice finished (click,
    /// Enter): goes into the recent colors; while dragging a slider, the steps merge into a single undo.
    func setColor(_ target: ColorTarget, _ color: CMYK?, final: Bool = true) {
        if selection.isEmpty {
            if target == .strokeColor { if let color { defaultStroke = color } } else { defaultFill = color }
        } else if self.color(target) != (color, false) {
            if final { registrar() } else { registerAdjustment("color \(target)") }
            for i in objects.indices where selection.contains(objects[i].id) {
                if target == .fill {
                    objects[i].fill = color
                } else if let color {
                    objects[i].strokeColor = color
                    objects[i].cutsLine = true
                } else {
                    objects[i].cutsLine = false
                }
            }
        }
        if final, let color { remember(color) }
    }

    func remember(_ color: CMYK) {
        recent.removeAll { $0 == color }
        recent.insert(color, at: 0)
        if recent.count > 14 { recent.removeLast(recent.count - 14) }
    }

    /// ⇧X: swaps fill and stroke.
    func swapColors() {
        if selection.isEmpty {
            if let fill = defaultFill { (defaultStroke, defaultFill) = (fill, defaultStroke) }
            return
        }
        modifySelection { o in
            let strokeColor = o.cutsLine ? o.strokeColor : nil
            if let fill = o.fill { o.strokeColor = fill; o.cutsLine = true } else { o.cutsLine = false }
            o.fill = strokeColor
        }
    }

    /// D: the app's default — no fill, solid red 0 pt stroke.
    func defaultColors() {
        let apply = { (o: inout CanvasObject) in
            o.fill = nil
            o.strokeColor = .red
            o.cutsLine = true
            o.strokeWidth = 0
            o.style = StrokeStyleSettings()
        }
        if selection.isEmpty {
            defaultFill = nil
            defaultStroke = .red
            defaultStrokeWidth = 0
            defaultStyle = StrokeStyleSettings()
        } else {
            modifySelection(apply)
        }
    }

    /// Only registers if it changes: the panel field confirms the value again on losing focus.
    func setStrokeWidth(_ pt: Double) {
        let value = max(0, pt)
        if selection.isEmpty { defaultStrokeWidth = value } else if selectedObjects.contains(where: { $0.strokeWidth != value }) {
            modifySelection { $0.strokeWidth = value }
        }
    }

    /// Style shown in the panel: the first selected object's or the next objects'.
    var currentStyle: StrokeStyleSettings { selectedObjects.first?.style ?? defaultStyle }

    func setStyle(_ change: (inout StrokeStyleSettings) -> Void) {
        if selection.isEmpty {
            change(&defaultStyle)
            return
        }
        var test = selectedObjects.map(\.style)
        for i in test.indices { change(&test[i]) }
        guard test != selectedObjects.map(\.style) else { return }
        modifySelection { change(&$0.style) }
    }
}
