// Leitura dos arquivos .studio3 do Silhouette Studio (formato fechado, sem documentação pública).
// Estrutura deduzida só dos dados dos arquivos (interoperabilidade), sem usar o programa do Studio. A gravação
// (que refaz só a lista de objetos) fica em Studio3Escrita.swift.
//
// Arquivo: "silhouette05;" + 16 tamanhos (u64) a partir de 0x10; as seções começam em 0x400.
//   0 = documento (árvore de objetos) · 1 = imagens (PNG) · 2 = miniatura 512 × 512
//   5/6 = últimos comandos enviados à máquina (GPGL com XOR 0xA9) · 9 = condições de corte (CSV)
// Documento: blocos [marca u8][tamanho u32, contado a partir do próprio campo]; listas guardam
// "quantidade − 1". Objeto = corpo (tipo + estilo + dados) + matriz 3 × 3 + caixa + caminho já na
// página (cache) + nome. Unidade: mm; origem no canto superior esquerdo da página, y para baixo.
import CoreGraphics
import Foundation
import ImageIO

public struct StudioDocument: Sendable {
    public struct Color: Sendable, Hashable {
        public var red, green, blue, alpha: Double

        public init(red: Double, green: Double, blue: Double, alpha: Double) {
            (self.red, self.green, self.blue, self.alpha) = (red, green, blue, alpha)
        }

        /// "RRGGBB", como o Studio nomeia as cores de linha no painel de envio.
        public var hex: String {
            let canal = { (v: Double) in Int((min(max(v, 0), 1) * 255).rounded()) }
            return String(format: "%02X%02X%02X", canal(red), canal(green), canal(blue))
        }
    }

    /// Nó de Bézier em mm da página; os pontos de controle são absolutos (nil = sem alça).
    public struct Node: Sendable, Equatable {
        public var point: CGPoint
        public var controlIn: CGPoint?
        public var controlOut: CGPoint?

        public init(point: CGPoint, controlIn: CGPoint? = nil, controlOut: CGPoint? = nil) {
            (self.point, self.controlIn, self.controlOut) = (point, controlIn, controlOut)
        }
    }

    public enum Fill: Sendable {
        case none
        case color(Color)
        /// `transform` leva o pixel da imagem para mm da página; a imagem fica recortada pelo contorno.
        case image(key: String, transform: CGAffineTransform)
    }

    public struct Object: Sendable {
        /// Nome no Studio: "Polygon", "Rectangle", "Ellipse", "Rounded Rectangle"…
        public var kind: String
        /// Subcaminhos sempre fechados (o formato não marca caminhos abertos).
        public var subpaths: [[Node]]
        /// A cor da linha define o corte (como no Cutline).
        public var line: Color
        public var fill: Fill
        /// Falso quando o objeto está marcado para não cortar no Studio (provável; ver MEMORIA.md).
        public var cuts: Bool
        /// Onde ele está na árvore do arquivo: o índice na lista de cima e, dentro dos grupos, nos filhos.
        public var source: [Int] = []

        public var path: CGPath {
            let path = CGMutablePath()
            for nodes in subpaths where !nodes.isEmpty {
                path.move(to: nodes[0].point)
                for (i, a) in nodes.enumerated() {
                    let b = nodes[(i + 1) % nodes.count]
                    if a.controlOut == nil, b.controlIn == nil {
                        path.addLine(to: b.point)
                    } else {
                        path.addCurve(to: b.point, control1: a.controlOut ?? a.point, control2: b.controlIn ?? b.point)
                    }
                }
                path.closeSubpath()
            }
            return path
        }
    }

    public struct Image: Sendable {
        /// PNG ou JPEG, como veio no arquivo.
        public var data: Data
        public var pixelWidth: Int
        public var pixelHeight: Int
    }

    /// Marcas de registro do Print & Cut, como o Studio guarda na página (mm).
    public struct RegistrationMarks: Sendable, Equatable {
        public init(on: Bool, left: Double, top: Double, right: Double, bottom: Double, length: Double, thickness: Double) {
            (self.on, self.left, self.top, self.right, self.bottom) = (on, left, top, right, bottom)
            (self.length, self.thickness) = (length, thickness)
        }

        /// Ligadas no documento (o Studio lê as marcas antes de cortar).
        public var on: Bool
        /// Da borda da página ao canto externo das marcas.
        public var left, top, right, bottom: Double
        /// Comprimento das cantoneiras e espessura das linhas.
        public var length, thickness: Double
    }

    public var pageSize: CGSize
    public var registrationMarks: RegistrationMarks?
    public var objects: [Object]
    public var images: [String: Image]
    /// Objetos que não deu para ler (tipo sem contorno conhecido, imagem ausente…).
    public var skipped: Int
    /// Cores de linha ligadas (true) ou desligadas no painel de envio do Studio, por `Color.hex`.
    /// Só aparecem as cores que o arquivo guarda.
    public var lineColorCuts: [String: Bool]

    public init(data: Data) throws {
        let file = Bytes(Array(data))
        guard file.count >= 0x400, file.starts(with: Self.magic) else { throw StudioError.notStudio }
        var sections: [Bytes] = []
        var offset = 0x400
        for i in 0..<16 {
            let size = try file.u64(0x10 + 8 * i)
            guard offset + size <= file.count else { throw StudioError.damaged("seção \(i) passa do fim do arquivo") }
            sections.append(Bytes(Array(file.b[offset..<(offset + size)])))
            offset += size
        }
        let doc = sections[0]
        guard doc.starts(with: Self.magic) else { throw StudioError.damaged("documento sem cabeçalho") }

        let pagina = try? doc.pageSetup()
        pageSize = pagina?.size ?? CGSize(width: 210, height: 297)
        registrationMarks = pagina?.marks
        images = (try? sections[1].images()) ?? [:]
        objects = []
        skipped = 0
        lineColorCuts = doc.lineColorCuts()
        let raw = try doc.objectList(at: try doc.findObjectList())
        flatten(raw, in: doc, transform: .identity, path: [])
    }

    static let magic = Array("silhouette05;".utf8)

    /// Desfaz os grupos (compondo as matrizes) e leva tudo para mm da página.
    private mutating func flatten(_ list: [RawObject], in doc: Bytes, transform parent: CGAffineTransform, path: [Int]) {
        for (indice, raw) in list.enumerated() {
            let t = raw.matrix.concatenating(parent)
            switch raw.type {
            case 5:   // grupo
                flatten(raw.children, in: doc, transform: t, path: path + [indice])
                continue
            case 36:  // marcadores internos do Studio, sem desenho
                continue
            default:
                break
            }
            guard let style = try? doc.style(at: raw.base.lowerBound, limit: raw.base.upperBound) else {
                skipped += 1
                continue
            }
            let subpaths: [[Node]]
            if raw.type == 1 || raw.type == 2 {
                // 1 = forma de ferramenta (retângulo, elipse), 2 = polígono/caminho: contorno local × matriz.
                guard let local = try? doc.localPath(at: raw.base.upperBound, limit: raw.bodyEnd) else {
                    skipped += 1
                    continue
                }
                subpaths = local.map { nodes in
                    nodes.map { n in
                        Node(point: n.point.applying(t),
                             controlIn: n.controlIn.map { CGPoint(x: n.point.x + $0.x, y: n.point.y + $0.y).applying(t) },
                             controlOut: n.controlOut.map { CGPoint(x: n.point.x + $0.x, y: n.point.y + $0.y).applying(t) })
                    }
                }
            } else if let cache = raw.cache, let cached = try? doc.cachedPath(at: cache.lowerBound, limit: cache.upperBound) {
                // Outros tipos (ex.: retângulo arredondado guarda só parâmetros): o caminho que o Studio
                // deixou pronto, já na página. Nos tipos 1 e 2 ele bate com o calculado (< 0,0001 mm).
                subpaths = cached
            } else {
                skipped += 1
                continue
            }
            guard subpaths.contains(where: { !$0.isEmpty }) else { continue }
            var fill = Fill.none
            switch style.fill {
            case .none: break
            case .color(let c): fill = .color(c)
            case .image(let key, let toLocal):
                if images[key] != nil { fill = .image(key: key, transform: toLocal.concatenating(t)) }
            }
            objects.append(Object(kind: raw.name, subpaths: subpaths, line: style.line, fill: fill, cuts: raw.flag != 1,
                                  source: path + [indice]))
        }
    }
}

public enum StudioError: Error, LocalizedError, Equatable {
    case notStudio
    case damaged(String)

    public var errorDescription: String? {
        switch self {
        case .notStudio: localized("O arquivo não é um documento do Silhouette Studio (.studio3).")
        case .damaged(let detalhe): localized("Não foi possível ler o arquivo do Silhouette Studio (\(detalhe)).")
        }
    }
}

// MARK: - Leitura dos bytes

/// Objeto como está no arquivo, antes de achatar grupos e aplicar matrizes.
struct RawObject {
    /// O objeto inteiro no documento.
    var range: Range<Int>
    var type: UInt8
    /// Bloco de base (tipo + estilo); o conteúdo próprio do tipo vem logo depois, até `bodyEnd`.
    var base: Range<Int>
    var bodyEnd: Int
    var matrix: CGAffineTransform
    /// 1 nos objetos que não cortam (fundo, peças fora da página…), 2 nos demais.
    var flag: Int
    var cache: Range<Int>?
    var name: String
    var children: [RawObject]
}

struct LocalNode {
    var point: CGPoint
    /// Alças relativas ao ponto.
    var controlIn: CGPoint?
    var controlOut: CGPoint?
}

enum RawFill {
    case none
    case color(StudioDocument.Color)
    /// Pixel da imagem → coordenadas locais do objeto.
    case image(key: String, toLocal: CGAffineTransform)
}

struct Bytes {
    let b: [UInt8]
    init(_ b: [UInt8]) { self.b = b }

    var count: Int { b.count }

    func starts(with prefix: [UInt8]) -> Bool { b.count >= prefix.count && Array(b[0..<prefix.count]) == prefix }

    func check(_ o: Int, _ n: Int) throws {
        guard o >= 0, n >= 0, o + n <= b.count else { throw StudioError.damaged("leitura fora do lugar em \(o)") }
    }

    func u8(_ o: Int) throws -> UInt8 {
        try check(o, 1)
        return b[o]
    }

    func u32(_ o: Int) throws -> Int {
        try check(o, 4)
        return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
    }

    func u64(_ o: Int) throws -> Int {
        try check(o, 8)
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(b[o + i]) << (8 * UInt64(i)) }
        guard v <= UInt64(Int32.max) else { throw StudioError.damaged("tamanho inválido em \(o)") }
        return Int(v)
    }

    func f32(_ o: Int) throws -> Double { Double(Float(bitPattern: UInt32(try u32(o)))) }

    func color(_ o: Int) throws -> StudioDocument.Color {
        StudioDocument.Color(red: try f32(o), green: try f32(o + 4), blue: try f32(o + 8), alpha: try f32(o + 12))
    }

    /// Texto com tamanho u32 na frente; devolve também onde termina.
    func string(_ o: Int) throws -> (String, Int) {
        let n = try u32(o)
        try check(o + 4, n)
        return (String(decoding: b[(o + 4)..<(o + 4 + n)], as: UTF8.self), o + 4 + n)
    }

    /// Bloco [marca][tamanho u32]: devolve o fim (exclusivo). O tamanho conta a partir do próprio campo.
    func block(_ o: Int, marker: UInt8 = 1, limit: Int) throws -> Int {
        guard try u8(o) == marker else { throw StudioError.damaged("bloco esperado em \(o)") }
        let end = o + 1 + (try u32(o + 1))
        guard end >= o + 5, end <= limit else { throw StudioError.damaged("bloco com tamanho inválido em \(o)") }
        return end
    }

    /// Matriz 3 × 3 por linhas (x' = m0·x + m1·y + m2; y' = m3·x + m4·y + m5).
    func matrix(_ o: Int) throws -> CGAffineTransform {
        let m = try (0..<9).map { try f32(o + 4 * $0) }
        return CGAffineTransform(a: m[0], b: m[3], c: m[1], d: m[4], tx: m[2], ty: m[5])
    }

    func firstIndex(of pattern: [UInt8], from start: Int = 0, to end: Int? = nil) -> Int? {
        let fim = min(end ?? b.count, b.count) - pattern.count
        guard start <= fim else { return nil }
        for i in start...fim where b[i] == pattern[0] && b[i..<(i + pattern.count)].elementsEqual(pattern) { return i }
        return nil
    }

    // MARK: Documento (seção 0)

    /// Onde começam os campos da página: no segundo bloco do cabeçalho, depois do bloco de 60 bytes da base
    /// e do nome do tamanho de papel (texto, vazio nos arquivos vistos).
    func pageFields() throws -> Int {
        let doc = try block(13, limit: count)
        let primeiro = try block(18, limit: doc)
        _ = try block(primeiro, limit: doc)
        return try string(primeiro + 5).1
    }

    /// Página (o mesmo que o Studio lê, na ordem): [u8 marcas ligadas] [f32 margens esquerda, topo, direita,
    /// baixo] [i32] [i32] [f32 comprimento] [f32 espessura] [f32 borda] [f32 largura] [f32 altura].
    func pageSetup() throws -> (size: CGSize, marks: StudioDocument.RegistrationMarks) {
        let p = try pageFields()
        let size = CGSize(width: try f32(p + 37), height: try f32(p + 41))
        guard (10...3000).contains(size.width), (10...3000).contains(size.height) else {
            throw StudioError.damaged("tamanho de página inesperado")
        }
        let marks = StudioDocument.RegistrationMarks(
            on: try u8(p) != 0, left: try f32(p + 1), top: try f32(p + 5), right: try f32(p + 9), bottom: try f32(p + 13),
            length: try f32(p + 25), thickness: try f32(p + 29))
        return (size, marks)
    }

    /// Cortes por cor de linha: ["@line:RRGGBB"][texto de 16–64 caracteres (material)][u8 ligado].
    func lineColorCuts() -> [String: Bool] {
        let marca = Array("@line:".utf8)
        var cores: [String: Bool] = [:]
        var i = 4
        while let j = firstIndex(of: marca, from: i) {
            i = j + 1
            guard (try? u32(j - 4)) == 12, j + 16 <= count else { continue }
            let hex = String(decoding: b[(j + 6)..<(j + 12)], as: UTF8.self)
            guard hex.allSatisfy(\.isHexDigit), let n = try? u32(j + 12), (16...64).contains(n), j + 16 + n < count,
                  b[(j + 16)..<(j + 16 + n)].allSatisfy({ (0x30..<0x7F).contains($0) }), b[j + 16 + n] <= 1 else { continue }
            cores[hex.uppercased()] = b[j + 16 + n] == 1
        }
        return cores
    }

    /// A lista de objetos vem depois dos ajustes do documento, que terminam com "auto", "auto".
    func findObjectList() throws -> Int {
        let auto = Array("auto".utf8)
        let marca = [4, 0, 0, 0] + auto + [4, 0, 0, 0] + auto
        if let i = firstIndex(of: marca, to: 1 << 16), (try? objectList(at: i + marca.count)) != nil {
            return i + marca.count
        }
        // Plano B: o primeiro bloco do começo do arquivo que se lê inteiro como lista de objetos.
        for p in 18..<min(count, 1 << 16) where b[p] == 1 {
            if (try? objectList(at: p)) != nil { return p }
        }
        throw StudioError.damaged("lista de objetos não encontrada")
    }

    func objectList(at p: Int, limit: Int? = nil, depth: Int = 0) throws -> [RawObject] {
        guard depth < 64 else { throw StudioError.damaged("grupos aninhados demais") }
        let end = try block(p, limit: limit ?? count)
        let quantidade = (try u32(p + 5) + 1) & 0xFFFF_FFFF
        var objetos: [RawObject] = []
        var q = p + 9
        while q < end {
            let (objeto, fim) = try object(at: q, limit: end, depth: depth)
            objetos.append(objeto)
            q = fim
        }
        guard q == end, objetos.count == quantidade else { throw StudioError.damaged("lista de objetos inconsistente em \(p)") }
        return objetos
    }

    func object(at p: Int, limit: Int, depth: Int) throws -> (RawObject, Int) {
        let end = try block(p, limit: limit)
        let q = p + 6                                   // [01][tamanho][u8]
        let bodyEnd = try block(q, limit: end)
        let type = try u8(q + 5)
        let baseEnd = q + 6 + (try u32(q + 6))          // [tipo][tamanho]
        guard baseEnd <= bodyEnd else { throw StudioError.damaged("objeto inconsistente em \(p)") }
        let children = type == 5 ? try objectList(at: baseEnd, limit: bodyEnd, depth: depth + 1) : []
        let matrix = try matrix(bodyEnd)
        var k = bodyEnd + 36 + 24                       // matriz + caixa (centro e semieixos)
        let flag = try u32(k)
        k += 5
        var cache: Range<Int>?
        if try u8(k) == 1 {
            let fim = try block(k, limit: end)
            cache = k..<fim
            k = fim
        } else {
            k += 1
        }
        // [01 id][u32][01 tamanho 12 …][nome]
        var name = ""
        if (try? u8(k)) == 1, (try? u8(k + 9)) == 1, let fim = try? block(k + 9, limit: end) {
            name = (try? string(fim).0) ?? ""
        }
        return (RawObject(range: p..<end, type: type, base: (q + 5)..<baseEnd, bodyEnd: bodyEnd, matrix: matrix, flag: flag,
                          cache: cache, name: name, children: children), end)
    }

    /// Estilo no bloco de base: cor da linha, estilo de corte, junção/ponta e preenchimento.
    func style(at base: Int, limit: Int) throws -> (line: StudioDocument.Color, fill: RawFill) {
        let st = base + 6                               // [tipo][tamanho][u8] → bloco do estilo
        let fim = try block(st, limit: limit)
        let line = try color(st + 7)
        var k = try block(st + 31, limit: fim)          // estilo de corte ("cut", "Cut", "0", cor)
        k += 1
        k = try string(k).1                             // junção ("rounded")
        if try u8(k) == 1 { k = try string(k + 1).1 } else { k += 1 }   // ponta
        let tipo = try u8(k)
        switch tipo {
        case 0:
            return (line, .none)
        case 1:
            return (line, .color(try color(k + 1)))
        case 5:
            let (key, depois) = try string(k + 1)
            // Três matrizes depois de [01 00 01]: a 2ª leva o pixel da imagem para o objeto.
            guard let j = firstIndex(of: [1, 0, 1], from: depois, to: fim), try u8(j + 39) == 1 else {
                throw StudioError.damaged("posição da imagem não encontrada")
            }
            return (line, .image(key: key, toLocal: try matrix(j + 40)))
        default:
            return (line, .none)
        }
    }

    /// Contorno em coordenadas locais: [01 tam][u32 subcaminhos − 1] { [01 tam][01 pontos − 1] { [01 tam] x y alças flags } }.
    func localPath(at p: Int, limit: Int) throws -> [[LocalNode]] {
        let end = try block(p, limit: limit)
        let quantidade = try u32(p + 5) + 1
        var q = p + 9
        var subcaminhos: [[LocalNode]] = []
        for _ in 0..<quantidade {
            let fimSub = try block(q, limit: end)
            q += 5
            guard try u8(q) == 1 else { throw StudioError.damaged("subcaminho inválido em \(q)") }
            let pontos = try u32(q + 1) + 1
            q += 5
            var nos: [LocalNode] = []
            nos.reserveCapacity(pontos)
            for _ in 0..<pontos {
                let fimPonto = try block(q, limit: fimSub)
                var x = q + 5
                let ponto = CGPoint(x: try f32(x), y: try f32(x + 4))
                x += 8
                let entrada = try handle(&x), saida = try handle(&x)
                nos.append(LocalNode(point: ponto, controlIn: entrada, controlOut: saida))
                q = fimPonto
            }
            guard q == fimSub else { throw StudioError.damaged("subcaminho inconsistente em \(q)") }
            subcaminhos.append(nos)
        }
        guard q == end else { throw StudioError.damaged("caminho inconsistente em \(p)") }
        return subcaminhos
    }

    /// Caminho já na página (sem marcas nem tamanhos por ponto): [01 tam][u32 n − 1] { [u32 tam][01 pontos − 1] { x y alças } }.
    func cachedPath(at p: Int, limit: Int) throws -> [[StudioDocument.Node]] {
        let end = try block(p, limit: limit)
        let quantidade = try u32(p + 5) + 1
        var q = p + 9
        var subcaminhos: [[StudioDocument.Node]] = []
        for _ in 0..<quantidade {
            let fimSub = q + (try u32(q))
            guard fimSub <= end, try u8(q + 4) == 1 else { throw StudioError.damaged("subcaminho inválido em \(q)") }
            let pontos = try u32(q + 5) + 1
            q += 9
            var nos: [StudioDocument.Node] = []
            for _ in 0..<pontos {
                let ponto = CGPoint(x: try f32(q), y: try f32(q + 4))
                q += 8
                let entrada = try handle(&q), saida = try handle(&q)
                nos.append(StudioDocument.Node(point: ponto,
                                               controlIn: entrada.map { CGPoint(x: ponto.x + $0.x, y: ponto.y + $0.y) },
                                               controlOut: saida.map { CGPoint(x: ponto.x + $0.x, y: ponto.y + $0.y) }))
            }
            guard q == fimSub else { throw StudioError.damaged("subcaminho inconsistente em \(q)") }
            subcaminhos.append(nos)
        }
        return subcaminhos
    }

    /// Alça opcional: [00] ou [01 dx dy].
    private func handle(_ o: inout Int) throws -> CGPoint? {
        switch try u8(o) {
        case 0:
            o += 1
            return nil
        case 1:
            let h = CGPoint(x: try f32(o + 1), y: try f32(o + 5))
            o += 9
            return h
        default:
            throw StudioError.damaged("alça inválida em \(o)")
        }
    }

    // MARK: Imagens (seção 1)

    /// [01 tam][u32][u64 n − 1] { [u64 tam][u64 + chave][…][u64 tamanho][PNG/JPEG][…] }
    func images() throws -> [String: StudioDocument.Image] {
        guard count > 17 else { return [:] }
        let quantidade = try u64(9) + 1
        var q = 17
        var saida: [String: StudioDocument.Image] = [:]
        for _ in 0..<quantidade {
            let fim = q + (try u64(q))
            guard fim > q, fim <= count else { throw StudioError.damaged("imagem inconsistente em \(q)") }
            let tamanhoChave = try u64(q + 8)
            try check(q + 16, tamanhoChave)
            let chave = String(decoding: b[(q + 16)..<(q + 16 + tamanhoChave)], as: UTF8.self)
            let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], jpeg: [UInt8] = [0xFF, 0xD8, 0xFF]
            if let inicio = firstIndex(of: png, from: q + 16, to: fim) ?? firstIndex(of: jpeg, from: q + 16, to: fim) {
                let tamanho = try u64(inicio - 8)
                if inicio + tamanho <= fim {
                    let dados = Data(b[inicio..<(inicio + tamanho)])
                    if let fonte = CGImageSourceCreateWithData(dados as CFData, nil),
                       let props = CGImageSourceCopyPropertiesAtIndex(fonte, 0, nil) as? [CFString: Any],
                       let largura = props[kCGImagePropertyPixelWidth] as? Int,
                       let altura = props[kCGImagePropertyPixelHeight] as? Int {
                        saida[chave] = StudioDocument.Image(data: dados, pixelWidth: largura, pixelHeight: altura)
                    }
                }
            }
            q = fim
        }
        return saida
    }
}
