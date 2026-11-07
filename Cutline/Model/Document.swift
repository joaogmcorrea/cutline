// The editor's document: objects in mm on the canvas (the 1st artboard's top-left corner is the origin), artboards,
// selection, tool and undo.
// The file (save, open, import from Studio) is in Model/DocumentFile.swift.
import CutlineKit
import ImageIO
import Observation
import SwiftUI

/// Color always in CMYK (the document goes to print): ink in the document's CMYK profile. Showing it, RGB and the
/// other conversions are the document's `colors` (Model/ColorConversion.swift, through ColorSync).
nonisolated struct CMYK: Hashable, Codable, Sendable {
    var c: Double, m: Double, y: Double, k: Double   // 0–100

    var summaryText: String { "CMYK (\(Int(c)), \(Int(m)), \(Int(y)), \(Int(k)))" }

    static let red = CMYK(c: 0, m: 100, y: 100, k: 0)

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

/// A linked image, as Illustrator's (File › Import… with Link): the file isn't copied into the document. The .cutline keeps
/// where it is (the absolute path, the path relative to the document and a bookmark, which follows the file when it moves),
/// its size and date (to notice when it changes) and a small preview, which the canvas, the print and the Finder's previews
/// use while the file is missing (the Finder's extensions run in a sandbox and can't read it).
nonisolated struct ImageLink: Hashable, Codable, Sendable {
    /// The keys stored on disk follow the names of the 1.0 format (Portuguese), like the others.
    enum CodingKeys: String, CodingKey {
        case path = "caminho", relativePath = "caminhoRelativo", bookmark = "marcador", preview = "previa",
             pixelWidth = "largura", pixelHeight = "altura", modified = "modificado", fileSize = "tamanhoArquivo"
    }

    var path: String
    /// From the document's folder ("../Images/photo.png"); nil while the document has no file.
    var relativePath: String?
    var bookmark: Data?
    /// PNG, at most `previewSide` pixels on the long side.
    var preview: Data?
    /// The full image's size, in pixels (the objects' `ImageInShape.transform` places it by these).
    var pixelWidth: Int
    var pixelHeight: Int
    /// The file's modification date and size when it was last read: different = changed on disk.
    var modified: Date?
    var fileSize: Int?

    static let previewSide = 512

    var fileName: String { (path as NSString).lastPathComponent }
}

/// A linked image now: found as it was read, missing, or changed on disk since (Links panel).
nonisolated enum LinkState: Sendable {
    case ok, missing, modified
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

        case id, shape = "forma", frame = "quadro", strokeColor = "traco", strokeWidth = "espessura", style = "estilo", fill = "preenchimento", image = "imagem", cutsLine = "corta", layer = "camada", isHidden = "oculto", isLocked = "travado", label = "rotulo", groups = "grupos", polygon = "poligono", gradient = "degrade", textPath = "textoNoCaminho", rotation = "rotacao", imageFit = "imagemNaForma"

    }

    var id = UUID()
    var shape: ShapeKind
    /// The shape's box, in page mm (origin at the top-left corner), before the rotation: the object turns by `rotation`
    /// around this box's center. A new size places an image inside the shape again by its fitting (Fill keeps covering it).
    var frame: CGRect {
        didSet { if imageFit != nil, frame.size != oldValue.size { refitImage() } }
    }
    /// Degrees, counterclockwise as in Illustrator, in (−180, 180]; 0 = upright. Every kind of object turns the same way
    /// (the shape keeps its parameters, the text stays text): Model/Geometry.swift turns the outline, Model/Rotation.swift
    /// the editing. In the file it goes in `rotacao` (`ObjectRotation`), beside the outline already turned.
    var rotation = 0.0
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
    /// Regular polygon: the shape is a path with the polygon's nodes and this keeps its parameter (`polygonSides`).
    var polygon: PolygonShape?
    /// Gradient fill (Gradient panel); `fill` keeps its first stop's color, which is what the versions before it show
    /// and what a .studio3 gets. nil = the solid `fill`.
    var gradient: GradientFill?
    /// Type on a Path: the text (the `.text` shape) goes along this path instead of in lines (`TextOnPath`).
    var textPath: TextOnPath?
    /// An image inside the shape (dropped on it, Paste Inside, Make Clipping Mask): how `image` sits in it
    /// (Model/ImageFitting.swift). Setting it places the image again. nil = an image on its own, placed as `image` says.
    var imageFit: ImageFitting? {
        didSet { refitImage() }
    }

    var name: String {
        if let label { return label }
        let shapeName = polygonSides != nil ? String(localized: "Polygon") : shape.name
        if imageFit != nil, image != nil { return String(localized: "\(shapeName) with Image") }
        return image != nil ? String(localized: "Image") : shapeName
    }
}

/// Regular polygon (Polygon tool). In the file it is a path (`caminho`) with this parameter beside it (`poligono`):
/// the versions before it don't know the key, ignore it and open the polygon as a plain path. (A new `ShapeKind`
/// case would make them fail to open the whole file.)
nonisolated struct PolygonShape: Hashable, Codable, Sendable {
    /// The keys stored on disk follow the names of the 1.0 format (Portuguese), like the others.
    enum CodingKeys: String, CodingKey {
        case sides = "lados"
    }

    static let sideRange = 3...40
    static let defaultSides = 6

    var sides: Int
}

/// A rotated object in the file (`rotacao`). The object's own keys hold the outline already turned, as a path (`caminho`)
/// in its box, with the image's place in that box: what the versions before it open, draw and cut (a new `ShapeKind` case,
/// or the angle alone, would make them refuse the file or cut it upright). Here are the angle and the object as Cutline
/// edits it: the shape (a rectangle with its radius, a text…), its box before the rotation and the image's place in it.
/// Shape and box are left out when the turned outline isn't there (a text whose letters weren't laid out) or another key
/// keeps them (`textoNoCaminho`).
nonisolated struct ObjectRotation: Hashable, Codable, Sendable {
    /// The keys stored on disk follow the names of the 1.0 format (Portuguese), like the others.
    enum CodingKeys: String, CodingKey {
        case angle = "angulo", shape = "forma", frame = "quadro", imageTransform = "transformacaoImagem"
    }

    /// Degrees, counterclockwise (`CanvasObject.rotation`).
    var angle: Double
    var shape: ShapeKind?
    var frame: CGRect?
    var imageTransform: Transform?
}

/// Object › Transform › Rotate… (Editor/RotateWindow.swift) open on the window: around `pivot` (page mm; nil = the
/// selection's center). Here, not there: the Finder's previews compile the document without the editor.
nonisolated struct RotateRequest: Identifiable, Sendable {
    let id = UUID()
    var pivot: CGPoint?
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
        polygon = try c.decodeIfPresent(PolygonShape.self, forKey: .polygon)
        // A gradient a later version wrote in a way this one doesn't know stays the solid fill.
        gradient = (try? c.decodeIfPresent(GradientFill.self, forKey: .gradient)).flatMap { $0 }
        if gradient != nil, fill == nil { gradient = nil }
        // Rotated: on disk the shape is the outline already turned (what the versions before it draw and cut); the angle and
        // the object before the rotation are in `rotacao`. One a later version wrote in a way this one doesn't know stays as
        // the turned outline.
        if let turned = (try? c.decodeIfPresent(ObjectRotation.self, forKey: .rotation)).flatMap({ $0 }) {
            rotation = CanvasObject.normalizedAngle(turned.angle)
            if let original = turned.shape { shape = original }
            if let box = turned.frame { frame = box }
            if let placed = turned.imageTransform, image != nil { image?.transform = placed }
        }
        // Type on a Path: on disk the shape is the letters' outline (what the versions before it draw and cut); the text,
        // the path and its box are in `textoNoCaminho`.
        if var onPath = (try? c.decodeIfPresent(TextOnPath.self, forKey: .textPath)).flatMap({ $0 }),
           let text = onPath.text, let box = onPath.frame {
            onPath.text = nil
            onPath.frame = nil
            shape = .text(text)
            frame = box
            textPath = onPath
        }
        // An image inside the shape: its placement comes from the fitting, now that the frame is the final one. When the
        // file has it already drawn in `imagem` (tiled or transparent, for the versions before it), the original comes back.
        // One a later version wrote in a way this one doesn't know stays the image as `imagem` places it.
        if image != nil, var fitting = (try? c.decodeIfPresent(ImageFitting.self, forKey: .imageFit)).flatMap({ $0 }) {
            if let original = fitting.fileKey { image?.key = original }
            fitting.fileKey = nil
            imageFit = fitting
            refitImage()
        }
    }

    /// The synthesized encoding, key by key in the same order (so files without Type on a Path or a rotation stay the
    /// same, byte by byte), except for a text on a path: its letters' outline as the shape (with their box), and the text,
    /// the path's box and the path in `textoNoCaminho`; and a rotated object: the outline already turned as the shape (with
    /// its box, and the image's place in that box), and the angle and the object before the rotation in `rotacao`.
    nonisolated func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        var onPath: TextOnPath?
        if var path = textPath, case .text(let text) = shape {
            path.text = text
            path.frame = frame
            onPath = path
        }
        let turned = rotation != 0 ? turnedForFile() : nil
        if let turned {
            try c.encode(ShapeKind.shapePath(turned.subpaths), forKey: .shape)
            try c.encode(turned.frame, forKey: .frame)
        } else if rotation == 0, onPath != nil, let outline = PathTextOutlines.outline(of: self) {
            try c.encode(ShapeKind.shapePath(outline.subpaths), forKey: .shape)
            try c.encode(outline.frame, forKey: .frame)
        } else {
            try c.encode(shape, forKey: .shape)
            try c.encode(frame, forKey: .frame)
        }
        try c.encode(strokeColor, forKey: .strokeColor)
        try c.encode(strokeWidth, forKey: .strokeWidth)
        try c.encode(style, forKey: .style)
        try c.encodeIfPresent(fill, forKey: .fill)
        if let image, let placed = turned?.image {
            try c.encode(ImageInShape(key: image.key, transform: placed), forKey: .image)
        } else {
            try c.encodeIfPresent(image, forKey: .image)
        }
        try c.encode(cutsLine, forKey: .cutsLine)
        try c.encodeIfPresent(layer, forKey: .layer)
        try c.encode(isHidden, forKey: .isHidden)
        try c.encode(isLocked, forKey: .isLocked)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encode(groups, forKey: .groups)
        try c.encodeIfPresent(polygon, forKey: .polygon)
        try c.encodeIfPresent(gradient, forKey: .gradient)
        try c.encodeIfPresent(onPath, forKey: .textPath)
        if rotation != 0 {
            // The shape and the box are only needed when the turned outline took their place (a text on a path keeps them in
            // `textoNoCaminho`); the image's place, when it was turned too.
            let original = turned != nil && onPath == nil
            try c.encode(ObjectRotation(angle: rotation, shape: original ? shape : nil, frame: original ? frame : nil,
                                        imageTransform: turned?.image != nil ? image?.transform : nil), forKey: .rotation)
        }
        // After everything else, so objects without an image inside stay the same, byte by byte.
        if image != nil { try c.encodeIfPresent(imageFit, forKey: .imageFit) }
    }

    /// The outline turned, for the file: a path relative to its box, the box, and the image's place in it. A text's letters
    /// come from `PathTextOutlines` (laid out on the main thread); nil when they aren't there (the file then keeps the text
    /// upright with the angle beside it: only the versions before it show it upright).
    nonisolated private func turnedForFile() -> (subpaths: [Subpath], frame: CGRect, image: Transform?)? {
        let local: CGPath
        if case .text = shape {
            guard let outline = PathTextOutlines.outline(of: self) else { return nil }
            local = CanvasObject.shapePath(outline.subpaths, in: outline.frame).cgPath
        } else {
            guard let outline = localOutlineWithoutText else { return nil }
            local = outline
        }
        guard let turned = local.copy(using: [rotationTransform]), let free = CanvasObject.freePath(turned) else { return nil }
        var placed: Transform?
        let box = free.frame.standardized
        if let image, box.width > 0, box.height > 0 {
            let toBox = CGAffineTransform(a: box.width, b: 0, c: 0, d: box.height, tx: box.minX, ty: box.minY).inverted()
            placed = Transform(image.transform.cg.concatenating(unrotatedFrameToPage).concatenating(rotationTransform).concatenating(toBox))
        }
        return (free.subpaths, free.frame, placed)
    }



    /// Sets the gradient fill (nil = back to the solid fill): `fill` follows its first stop.
    mutating func setGradient(_ updated: GradientFill?) {
        gradient = updated?.sorted
        if let first = gradient?.stops.first { fill = first.color }
    }
}

/// Type on a Path, as in Illustrator: the text runs along a path from `start` to `end` (fractions of its length), on
/// one side or the other (`flipped`), with Illustrator's options (effect, alignment to the path, spacing). The path is
/// in the object's frame (0…1), like a path's nodes, so moving and resizing the object moves and stretches the path (the
/// letters keep their size). It cuts along the letters' outline. In the file (`textoNoCaminho`) it also carries the
/// text and the path's box: the shape on disk is the letters' outline, so the versions before it open the object as that
/// path (a new `ShapeKind` case would make them refuse the whole file).
nonisolated struct TextOnPath: Hashable, Codable, Sendable {
    /// The keys stored on disk follow the names of the 1.0 format (Portuguese), like the others.
    enum CodingKeys: String, CodingKey {
        case subpaths = "caminho", start = "inicio", end = "fim", flipped = "virado", effect = "efeito",
             alignment = "alinhamento", spacing = "espacamento", text = "texto", frame = "quadro"
    }

    var subpaths: [Subpath]
    var start = 0.0
    var end = 1.0
    var flipped = false
    var effect = PathTextEffect.rainbow
    var alignment = PathTextAlignment.baseline
    /// Extra space between the letters along the path, in pt (Illustrator's Spacing).
    var spacing = 0.0
    /// Only in the file (see above).
    var text: TextBox?
    var frame: CGRect?

    init(subpaths: [Subpath], start: Double = 0, end: Double = 1) {
        self.subpaths = subpaths
        self.start = start
        self.end = end
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subpaths = try c.decode([Subpath].self, forKey: .subpaths)
        start = min(max(try c.decodeIfPresent(Double.self, forKey: .start) ?? 0, 0), 1)
        end = min(max(try c.decodeIfPresent(Double.self, forKey: .end) ?? 1, 0), 1)
        flipped = try c.decodeIfPresent(Bool.self, forKey: .flipped) ?? false
        effect = (try? c.decodeIfPresent(PathTextEffect.self, forKey: .effect)).flatMap { $0 } ?? .rainbow
        alignment = (try? c.decodeIfPresent(PathTextAlignment.self, forKey: .alignment)).flatMap { $0 } ?? .baseline
        spacing = try c.decodeIfPresent(Double.self, forKey: .spacing) ?? 0
        text = try c.decodeIfPresent(TextBox.self, forKey: .text)
        frame = try c.decodeIfPresent(CGRect.self, forKey: .frame)
    }
}

/// Illustrator's Type on a Path effects (the ones that keep the letters' shapes).
nonisolated enum PathTextEffect: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Each letter turns with the path.
    case rainbow = "arcoIris"
    /// The letters' sides stay vertical; they lean along the path.
    case skew = "inclinar"
    /// The letters stay upright, each on the path.
    case stairStep = "escada"
    var id: Self { self }
}

/// What of the letters sits on the path (Illustrator's Align to Path).
nonisolated enum PathTextAlignment: String, Codable, CaseIterable, Identifiable, Sendable {
    case baseline = "linhaBase", ascender = "ascendente", descender = "descendente", center = "centro"
    var id: Self { self }
}

/// Gradient fill, like Illustrator's Gradient panel: linear (at an angle) or radial, with CMYK stops. It only prints: the
/// cut is still the stroke. In the file it goes beside the solid fill (`degrade`), which keeps the first stop's color, so
/// the versions before it open the object with that color.
nonisolated struct GradientFill: Hashable, Codable, Sendable {
    /// The keys stored on disk follow the names of the 1.0 format (Portuguese), like the others.
    enum CodingKeys: String, CodingKey {
        case kind = "tipo", angle = "angulo", stops = "paradas"
    }

    var kind = GradientKind.linear
    /// Degrees, counterclockwise from left → right (linear only), as in Illustrator.
    var angle = 0.0
    /// At least two, in order of location.
    var stops: [GradientStop]

    /// Illustrator's default: white to black.
    static let standard = GradientFill(stops: [GradientStop(color: CMYK(c: 0, m: 0, y: 0, k: 0), location: 0),
                                               GradientStop(color: CMYK(c: 0, m: 0, y: 0, k: 100), location: 1)])

    init(kind: GradientKind = .linear, angle: Double = 0, stops: [GradientStop]) {
        self.kind = kind
        self.angle = angle
        self.stops = stops
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(GradientKind.self, forKey: .kind) ?? .linear
        angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? 0
        stops = try c.decode([GradientStop].self, forKey: .stops)
        guard stops.count >= 2 else { throw DecodingError.dataCorruptedError(forKey: .stops, in: c, debugDescription: "< 2 stops") }
    }

    /// The stops in order of location, each between 0 and 1.
    var sorted: GradientFill {
        var g = self
        g.stops = stops.map { GradientStop(color: $0.color, location: min(max($0.location, 0), 1)) }
            .enumerated().sorted { $0.element.location != $1.element.location ? $0.element.location < $1.element.location : $0.offset < $1.offset }
            .map(\.element)
        return g
    }

    /// The color at a location (0–1), mixed in CMYK between the stops around it.
    func color(at t: Double) -> CMYK {
        guard let first = stops.first, let last = stops.last else { return CMYK(c: 0, m: 0, y: 0, k: 0) }
        if t <= first.location { return first.color }
        if t >= last.location { return last.color }
        for (a, b) in zip(stops, stops.dropFirst()) where t <= b.location {
            let f = b.location > a.location ? (t - a.location) / (b.location - a.location) : 1
            let mix = { (x: Double, y: Double) in x + (y - x) * f }
            return CMYK(c: mix(a.color.c, b.color.c), m: mix(a.color.m, b.color.m), y: mix(a.color.y, b.color.y), k: mix(a.color.k, b.color.k))
        }
        return last.color
    }

    /// Where the gradient goes over a box (page mm, y down), as Illustrator puts a new one: linear through the box's
    /// center at the angle, long enough to cross the whole box; radial from the center to the farthest side.
    func geometry(in box: CGRect) -> (start: CGPoint, end: CGPoint, radius: Double) {
        let center = CGPoint(x: box.midX, y: box.midY)
        switch kind {
        case .linear:
            let a = angle * .pi / 180
            let dx = cos(a), dy = -sin(a)
            let half = (abs(box.width * dx) + abs(box.height * dy)) / 2
            return (CGPoint(x: center.x - dx * half, y: center.y - dy * half), CGPoint(x: center.x + dx * half, y: center.y + dy * half), 0)
        case .radial:
            return (center, center, max(box.width, box.height) / 2)
        }
    }
}

nonisolated enum GradientKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case linear, radial
    var id: Self { self }
}

nonisolated struct GradientStop: Hashable, Codable, Sendable {
    enum CodingKeys: String, CodingKey {
        case color = "cor", location = "posicao"
    }

    var color: CMYK
    /// 0–1 along the gradient.
    var location: Double
}

nonisolated enum Tool: String, CaseIterable, Identifiable, Sendable {
    case selection, direct, pen, addNode, deleteNode, text, typeOnPath, line, rectangle, ellipse, polygon, star, rotate, eyedropper, artboard, hand, zoom

    var id: Self { self }

    var name: String {
        switch self {
        case .rotate: String(localized: "Rotate")
        case .selection: String(localized: "Selection")
        case .direct: String(localized: "Direct Selection")
        case .pen: String(localized: "Pen")
        case .addNode: String(localized: "Add Anchor Point")
        case .deleteNode: String(localized: "Delete Anchor Point")
        case .text: String(localized: "Text")
        case .typeOnPath: String(localized: "Type on a Path")
        case .line: String(localized: "Line")
        case .rectangle: String(localized: "Rectangle")
        case .ellipse: String(localized: "Ellipse")
        case .polygon: String(localized: "Polygon")
        case .star: String(localized: "Star")
        case .eyedropper: String(localized: "Eyedropper")
        case .artboard: String(localized: "Artboard")
        case .hand: String(localized: "Hand")
        case .zoom: String(localized: "Zoom")
        }
    }

    /// Illustrator's shortcuts (+ is also =, as there); nil = none (Illustrator's Polygon has none either). Tracing an
    /// image is in File › Import (and dropping it).
    var keyEvent: Character? {
        switch self {
        case .selection: "v"
        case .direct: "a"
        case .pen: "p"
        case .addNode: "+"
        case .deleteNode: "-"
        case .text: "t"
        case .typeOnPath: nil
        case .line: "\\"
        case .rectangle: "m"
        case .ellipse: "l"
        case .polygon: nil
        case .star: "s"
        case .rotate: "r"
        case .eyedropper: "i"
        case .artboard: nil   // ⇧O, as in Illustrator (the canvas's keyboard takes it)
        case .hand: "h"
        case .zoom: "z"
        }
    }

    var createsShape: Bool { self == .rectangle || self == .ellipse || self == .polygon || self == .star }
    /// The shortcut as the tooltips show it (⇧O for the Artboard tool).
    var shortcutLabel: String? { self == .artboard ? "⇧O" : keyEvent.map { String($0).uppercased() } }
    /// The ones that show the nodes of the selected objects.
    var editsNodes: Bool { self == .direct || self == .addNode || self == .deleteNode }
}

/// The data lives outside the MainActor because macOS creates and reads documents on a background thread;
/// editing (extensions below) all happens on the main thread, where the interface uses the document.
@Observable
nonisolated final class Document: @unchecked Sendable {
    /// Cutting mat margin around each artboard, for drawing only.
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
    /// The pages (Model/Artboards.swift): never empty; the 1st one at the origin.
    var artboards: [Artboard]
    /// The one the rulers, the snap and Fit in Window follow (doesn't go into the file: a file opens on the 1st).
    var activeArtboardID: UUID
    /// How far the canvas's origin moved since the document opened (`anchorFirstArtboard`): the window moves the view by
    /// the same amount, so the objects stay put on screen (also on undo). Doesn't go into the file.
    var anchor = CGPoint.zero
    /// The artboard the Send window cuts (nil = the active one); doesn't go into the file.
    var sendArtboardID: UUID?
    /// Print & Cut registration marks on the page (Model/RegistrationMarks.swift): on/off and where they are.
    var marks: Bool
    var marksConfig: MarksConfig
    /// Print bleed with Print & Cut (Model/PrintBleed.swift; experimental).
    var bleed: PrintBleed
    /// Cut with the cutting mat (the sticky plastic); without it, the machine pulls the sheet directly. New
    /// documents start with the last choice (Page panel).
    var withMat: Bool
    /// The mat chosen in the Page panel (nil = the machine's default; the machine gets one it accepts).
    var cuttingMatSetting: CuttingMat?
    /// Track enhancing in the Send window: the rollers run the sheet forward and back before cutting (once per send).
    var trackEnhancing: Bool
    /// The CMYK profile the colors are in (Edit › Assign Profile…); nil = the app's (Settings › Color).
    var colorProfile: ColorProfile?
    /// Cut by line color (Model/Cutting.swift): saved settings and chosen order.
    var cuts: [CMYK: CutConfig]
    var cutOrder: [CMYK]
    /// Images (PNG or JPEG) used by the objects, by `ImageInShape`'s key. A linked image's is the file as last read
    /// (only in memory: the file isn't copied into the document); nil while it is missing (its preview shows).
    var images: [String: Data]
    /// Linked images (File › Import… with Link), by the same key: where the file is and its small preview.
    var links: [String: ImageLink]
    /// Each linked image's state now (Editor/LinksPanel.swift checks the files); doesn't go into the file.
    var linkStates: [String: LinkState] = [:]
    /// Linked images that changed on disk and are waiting for the question (Update / Not Now).
    var linksToAsk: [String] = []
    /// Where this document's file is (for the links' relative paths); the window keeps it.
    @ObservationIgnored var documentURL: URL?
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
    /// Changes when File › Save Selection… is chosen (the window opens the save panel).
    var saveSelectionRequest = 0
    /// Changes when File › Merge… is chosen (the window opens the file panel).
    var mergeRequest = 0
    /// Changes when Edit › Assign Profile… is chosen (the window opens its sheet: Editor/ColorProfileViews.swift).
    var assignProfileRequest = 0
    /// Changes when File › Send… is chosen (the window opens the Send window).
    var sendRequest = 0
    /// The Color Picker open on the window (Editor/ColorPicker.swift); nil = closed.
    var colorPicker: ColorPickerRequest?
    /// Type on a Path Options open on the window (Editor/TypeOnPathOptions.swift).
    var pathTextOptionsOpen = false
    /// Object › Transform › Rotate… open on the window (Editor/RotateWindow.swift); nil = closed.
    var rotateRequest: RotateRequest?
    /// The gradient the Gradient panel applies when the selection has none (the last one used); doesn't go into the file.
    var lastGradient = GradientFill.standard
    /// The shape whose image is being moved, scaled and turned inside it (double click; Esc leaves: Editor/ImageInsideShape.swift);
    /// doesn't go into the file.
    var imageContentEditing: CanvasObject.ID?
    /// The shape an image dragged over the window (or over the sheet, with ⌘) would go into: highlighted on the canvas.
    var imageDropTarget: CanvasObject.ID?
    /// Top-left corner of the test cut on the sheet, in mm (Model/Cutting.swift); doesn't go into the file.
    var testPosition = CGPoint(x: 25, y: 25)
    /// Side of the test cut's square, in mm; doesn't go into the file.
    var testSide = TestCut.defaultSide
    /// The Send window's "Test Shape" checkbox: shows the test on the sheet and lets it be cut. Starts off
    /// each time the document opens; doesn't go into the file.
    var testShape = false
    /// Center of what the window shows, in page mm (MainWindow keeps it): where vectors pasted from other apps go.
    @ObservationIgnored var visibleCenter: CGPoint?
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
         images: [String: Data] = [:], links: [String: ImageLink] = [:], layers: [Layer] = [], activeLayer: UUID? = nil, recent: [CMYK] = [],
         guides: Guides = Guides(), artboards: [Artboard] = [], marks: Bool = false, marksConfig: MarksConfig = .defaultValue,
         bleed: PrintBleed = PrintBleed(), withMat: Bool? = nil,
         cuttingMatSetting: CuttingMat?? = nil, trackEnhancing: Bool = false, colorProfile: ColorProfile? = nil,
         notice: String? = nil, cameFromStudio: Bool = false) {
        self.guides = guides
        let artboards = artboards.isEmpty ? [Artboard(rect: Artboard.standard.rect)] : artboards
        self.artboards = artboards
        activeArtboardID = artboards[0].id
        self.marks = marks
        self.marksConfig = marksConfig
        self.bleed = bleed
        self.withMat = withMat ?? Self.lastMat
        self.cuttingMatSetting = cuttingMatSetting ?? Self.lastCuttingMat
        self.trackEnhancing = trackEnhancing
        self.colorProfile = colorProfile
        let layers = layers.isEmpty ? [Layer(name: String(localized: "Layer \(1)"), color: 0)] : layers
        self.layers = layers
        self.activeLayer = activeLayer.flatMap { id in layers.first { $0.id == id }?.id } ?? layers[0].id
        self.recent = recent
        // An object without a layer (every one from a .studio3, and some old files) belongs to the top one: it says so
        // now, so it stays there when a new layer goes on top (it used to jump into the new one).
        let known = Set(layers.map(\.id))
        self.objects = objects.map { o in
            guard o.layer.map(known.contains) != true else { return o }
            var o = o
            o.layer = layers[0].id
            return o
        }
        self.cuts = cuts
        self.cutOrder = cutOrder
        self.images = images
        self.links = links
        self.notice = notice
        self.cameFromStudio = cameFromStudio
    }
}

nonisolated enum ColorTarget: Sendable {
    case fill, strokeColor
}

/// What the Color Picker was opened for (Editor/ColorPicker.swift). Here, not there: the Finder's previews compile the
/// document without the editor.
nonisolated enum ColorPickerTarget: Hashable, Sendable {
    case fill, strokeColor
    /// A stop of the Gradient panel's gradient (Editor/GradientPanel.swift).
    case gradientStop(Int)
}

nonisolated struct ColorPickerRequest: Identifiable, Sendable {
    let id = UUID()
    let target: ColorPickerTarget
}

/// What an undo step stores.
nonisolated private struct ConnectionState: Sendable {
    var objects: [CanvasObject]
    var cuts: [CMYK: CutConfig]
    var cutOrder: [CMYK]
    var layers: [Layer]
    var activeLayer: UUID
    var guides: Guides
    var artboards: [Artboard]
    var activeArtboardID: UUID
    var anchor: CGPoint
    var marks: Bool
    var marksConfig: MarksConfig
    var bleed: PrintBleed
    var withMat: Bool
    var cuttingMatSetting: CuttingMat?
    var trackEnhancing: Bool
    var colorProfile: ColorProfile?
    var links: [String: ImageLink]
}

extension Document {
    var selectedObjects: [CanvasObject] { objects.filter { selection.contains($0.id) } }

    /// The image to draw for a key: the file's, or a missing linked image's small preview (drawn over the same pixels:
    /// `pixelSize`).
    func image(_ key: String) -> CGImage? {
        if let ready = decodedImages[key] { return ready }
        guard let payload = images[key] ?? links[key]?.preview, let font = CGImageSourceCreateWithData(payload as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(font, 0, nil) else { return nil }
        decodedImages[key] = image
        return image
    }

    /// The size, in pixels, `ImageInShape.transform` places the image by: a linked image's full size, also while only its
    /// preview is there; else the image's own.
    func pixelSize(_ key: String, of image: CGImage) -> CGSize {
        if let link = links[key], link.pixelWidth > 0, link.pixelHeight > 0 { return CGSize(width: link.pixelWidth, height: link.pixelHeight) }
        return CGSize(width: image.width, height: image.height)
    }

    /// The image of a key was read again (a linked file found or updated): draw it from the new data.
    func forgetDecodedImage(_ key: String) { decodedImages[key] = nil }

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
                   guides: guides, artboards: artboards, activeArtboardID: activeArtboardID, anchor: anchor, marks: marks, marksConfig: marksConfig, bleed: bleed, withMat: withMat,
                   cuttingMatSetting: cuttingMatSetting, trackEnhancing: trackEnhancing, colorProfile: colorProfile, links: links)
        }
        set {
            objects = newValue.objects
            cuts = newValue.cuts
            cutOrder = newValue.cutOrder
            layers = newValue.layers
            activeLayer = newValue.activeLayer
            guides = newValue.guides
            artboards = newValue.artboards
            activeArtboardID = newValue.activeArtboardID
            anchor = newValue.anchor
            marks = newValue.marks
            marksConfig = newValue.marksConfig
            bleed = newValue.bleed
            withMat = newValue.withMat
            cuttingMatSetting = newValue.cuttingMatSetting
            trackEnhancing = newValue.trackEnhancing
            colorProfile = newValue.colorProfile
            links = newValue.links
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
    func insertImported(_ newItems: [CanvasObject], images newOnes: [String: Data] = [:], links newLinks: [String: ImageLink] = [:]) {
        guard !newItems.isEmpty else { return }
        registrar()
        images.merge(newOnes) { _, newOne in newOne }
        links.merge(newLinks) { _, newOne in newOne }
        for key in newLinks.keys { linkStates[key] = .ok }
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
        return (color, selectedObjects.contains { read($0) != color || (target == .fill && $0.gradient != first.gradient) })
    }

    /// `color` nil = none (on the stroke: the object stops cutting). `final` = choice finished (click,
    /// Enter): goes into the recent colors; while dragging a slider, the steps merge into a single undo.
    func setColor(_ target: ColorTarget, _ color: CMYK?, final: Bool = true) {
        if selection.isEmpty {
            if target == .strokeColor { if let color { defaultStroke = color } } else { defaultFill = color }
        } else if self.color(target) != (color, false) || (target == .fill && selectedObjects.contains { $0.gradient != nil }) {
            if final { registrar() } else { registerAdjustment("color \(target)") }
            for i in objects.indices where selection.contains(objects[i].id) {
                if target == .fill {
                    // A solid color (or none) takes the gradient's place, as in Illustrator.
                    objects[i].fill = color
                    objects[i].gradient = nil
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
            o.gradient = nil
        }
    }

    /// D: the app's default — no fill, solid red 0 pt stroke.
    func defaultColors() {
        let apply = { (o: inout CanvasObject) in
            o.fill = nil
            o.gradient = nil
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
