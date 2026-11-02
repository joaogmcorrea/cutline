// Gravação de .studio3 por cima do original: refaz só a lista de objetos do documento (seção 0). O resto do
// arquivo — ajustes da página, cortes por cor, imagens, comandos da máquina, JSONs — fica como estava, e a
// miniatura pode ser trocada. Um objeto de cima sem mudança volta com os mesmos bytes. Um alterado é remontado a
// partir dele mesmo (estilo, camada, id e código ficam; mudam contorno, posição, cor da linha, preenchimento e
// "não corta"), num sistema local que acompanha o deslocamento e o tamanho (a imagem recortada vai junto). Um
// novo sai de um polígono do próprio arquivo. Os marcadores de camada (tipo 36, "Layer 1"/"Layer 0") ficam
// onde estavam; cada objeto vai para o trecho entre marcadores de onde veio. Formato: _docs/FORMATO-STUDIO3.md.
import CoreGraphics
import Foundation

public enum StudioWriter {
    public enum Item: Sendable {
        /// Um objeto da lista de cima do arquivo, intacto (pelo índice).
        case original(Int)
        /// Um objeto novo ou alterado.
        case shape(Shape)
    }

    public enum FillChange: Sendable {
        /// O preenchimento do objeto de origem (também a imagem).
        case keep
        case none
        case color(StudioDocument.Color)
    }

    public struct Shape: Sendable {
        /// Contornos em mm da página (o formato só tem contornos fechados).
        public var subpaths: [[StudioDocument.Node]]
        public var line: StudioDocument.Color
        public var fill: FillChange
        /// Preenchimento de imagem do objeto de origem: pixel → mm da página.
        public var imageToPage: CGAffineTransform?
        public var cuts: Bool
        /// `StudioDocument.Object.source` do objeto de onde veio; nil = novo.
        public var source: [Int]?
        /// Cópia do objeto de `source` (ele continua no arquivo): mesmo estilo e imagem, id e código novos.
        public var copy: Bool

        public init(subpaths: [[StudioDocument.Node]], line: StudioDocument.Color, fill: FillChange,
                    imageToPage: CGAffineTransform? = nil, cuts: Bool, source: [Int]? = nil, copy: Bool = false) {
            self.subpaths = subpaths
            self.line = line
            self.fill = fill
            self.imageToPage = imageToPage
            self.cuts = cuts
            self.source = source
            self.copy = copy
        }
    }

    public enum WriteError: Error, LocalizedError, Equatable {
        case unsupported(String)

        public var errorDescription: String? {
            switch self {
            case .unsupported(let detalhe): localized("Este arquivo do Silhouette Studio não pode ser regravado pelo Cutline (\(detalhe)).")
            }
        }
    }

    /// Dá para regravar o arquivo (a lista de objetos está no lugar de sempre)?
    public static func canWrite(_ original: Data) -> Bool {
        let file = Bytes(Array(original))
        guard file.count >= 0x400, file.starts(with: StudioDocument.magic), let tamanho = try? file.u64(0x10),
              0x400 + tamanho <= file.count else { return false }
        let doc = Bytes(Array(file.b[0x400..<(0x400 + tamanho)]))
        guard let inicio = doc.objectListAfterMarker(), let fimLista = try? doc.block(inicio, limit: doc.count),
              let fimDocumento = try? doc.block(13, limit: doc.count) else { return false }
        return fimDocumento >= fimLista
    }

    /// O arquivo novo; `thumbnail` (PNG 512 × 512) troca a miniatura e `marks`, as marcas do Print & Cut da página.
    public static func write(original: Data, items: [Item], thumbnail: Data? = nil,
                             marks: StudioDocument.RegistrationMarks? = nil) throws -> Data {
        try writeWithMap(original: original, items: items, thumbnail: thumbnail, marks: marks).data
    }

    /// O arquivo novo e, para cada item, o índice dele na lista de cima do arquivo novo (nil = não gravado).
    public static func writeWithMap(original: Data, items: [Item], thumbnail: Data? = nil,
                                    marks: StudioDocument.RegistrationMarks? = nil) throws -> (data: Data, indices: [Int?]) {
        let file = Bytes(Array(original))
        guard file.count >= 0x400, file.starts(with: StudioDocument.magic) else { throw StudioError.notStudio }
        var sections: [[UInt8]] = []
        var offset = 0x400
        for i in 0..<16 {
            let size = try file.u64(0x10 + 8 * i)
            guard offset + size <= file.count else { throw StudioError.damaged("seção \(i) passa do fim do arquivo") }
            sections.append(Array(file.b[offset..<(offset + size)]))
            offset += size
        }
        guard offset == file.count else { throw WriteError.unsupported("dados depois da última seção") }

        let doc = Bytes(sections[0])
        guard doc.starts(with: StudioDocument.magic), let inicio = doc.objectListAfterMarker() else {
            throw WriteError.unsupported("lista de objetos fora do lugar de sempre")
        }
        let fimLista = try doc.block(inicio, limit: doc.count)
        // A lista fica dentro do bloco do documento (em 13); é o único tamanho que muda.
        let fimDocumento = try doc.block(13, limit: doc.count)
        guard fimDocumento >= fimLista else { throw WriteError.unsupported("lista fora do bloco do documento") }
        let lista = try doc.objectList(at: inicio)
        var montador = Montador(doc: doc, lista: lista)

        // Trechos entre marcadores: cada objeto vai para o de onde veio; os novos, para o do último objeto.
        var trecho = 0, trechoDe: [Int: Int] = [:], primeiroFecho: Int?
        for (i, raw) in lista.enumerated() {
            if raw.type == 36 {
                if primeiroFecho == nil, raw.name == "Layer 0" { primeiroFecho = trecho }
                trecho += 1
            } else {
                trechoDe[i] = trecho
            }
        }
        let trechoDosNovos = trechoDe.max { $0.key < $1.key }?.value ?? primeiroFecho ?? 0
        var porTrecho: [Int: [(item: Int, bytes: [UInt8])]] = [:]
        for (n, item) in items.enumerated() {
            switch item {
            case .original(let i):
                guard lista.indices.contains(i), lista[i].type != 36 else { throw WriteError.unsupported("objeto \(i) inexistente") }
                porTrecho[trechoDe[i]!, default: []].append((n, Array(doc.b[lista[i].range])))
            case .shape(let forma):
                guard forma.subpaths.contains(where: { $0.count >= 2 }) else { continue }
                let destino = forma.source.flatMap { $0.first }.flatMap { trechoDe[$0] } ?? trechoDosNovos
                porTrecho[destino, default: []].append((n, try montador.objeto(forma)))
            }
        }

        var corpo: [UInt8] = []
        var atual = 0, total = 0
        var indices = [Int?](repeating: nil, count: items.count)
        let despejar = { (trecho: Int) in
            for (n, objeto) in porTrecho[trecho] ?? [] {
                corpo += objeto
                indices[n] = total
                total += 1
            }
        }
        for raw in lista where raw.type == 36 {
            despejar(atual)
            corpo += doc.b[raw.range]
            total += 1
            atual += 1
        }
        despejar(atual)
        guard total > 0 else { throw WriteError.unsupported("documento vazio") }
        var novaLista: [UInt8] = [1]
        novaLista += u32(4 + 4 + corpo.count)
        novaLista += u32(total - 1)
        novaLista += corpo

        var novoDoc = Array(doc.b[0..<inicio]) + novaLista + Array(doc.b[fimLista...])
        let diferenca = novaLista.count - (fimLista - inicio)
        put(u32(try doc.u32(14) + diferenca), into: &novoDoc, at: 14)
        // Campos de tamanho fixo da página, antes da lista (não mudam de lugar): ver `Bytes.pageSetup`. Uma página
        // que o leitor não entende fica como estava.
        if let marks, (try? doc.pageSetup()) != nil, let p = try? doc.pageFields() {
            novoDoc[p] = marks.on ? 1 : 0
            for (i, valor) in [marks.left, marks.top, marks.right, marks.bottom, marks.length, marks.thickness].enumerated() {
                put(f32(valor), into: &novoDoc, at: p + [1, 5, 9, 13, 25, 29][i])
            }
        }
        sections[0] = novoDoc
        if let thumbnail { sections[2] = Array(thumbnail) }

        var saida = Array(file.b[0..<0x400])
        for (i, secao) in sections.enumerated() { put(u64(secao.count), into: &saida, at: 0x10 + 8 * i) }
        for secao in sections { saida += secao }
        let dados = Data(saida)
        // O que foi gravado tem de se ler de novo.
        _ = try StudioDocument(data: dados)
        return (dados, indices)
    }
}

extension StudioWriter {
    /// Os ids de todos os objetos do documento (para os testes: têm de ser únicos).
    static func objectIDs(_ data: Data) throws -> [Int] {
        let file = Bytes(Array(data))
        let doc = Bytes(Array(file.b[0x400..<(0x400 + (try file.u64(0x10)))]))
        guard let inicio = doc.objectListAfterMarker() else { return [] }
        var ids: [Int] = []
        func varrer(_ objetos: [RawObject]) throws {
            for o in objetos {
                ids.append(try Montador.trailer(doc, o).id)
                try varrer(o.children)
            }
        }
        try varrer(try doc.objectList(at: inicio))
        return ids
    }
}

// MARK: - Montagem dos objetos

private struct Montador {
    let doc: Bytes
    let lista: [RawObject]
    /// Próximo id livre (os ids do Studio são únicos no documento).
    var proximoID: Int

    init(doc: Bytes, lista: [RawObject]) {
        self.doc = doc
        self.lista = lista
        var maior = 0
        func varrer(_ objetos: [RawObject]) {
            for o in objetos {
                if let id = try? Montador.trailer(doc, o).id { maior = max(maior, id) }
                varrer(o.children)
            }
        }
        varrer(lista)
        proximoID = maior + 1
    }

    /// Onde começa o fecho do objeto ([01][u32 id]…) e o id.
    static func trailer(_ doc: Bytes, _ o: RawObject) throws -> (inicio: Int, id: Int) {
        var k = o.bodyEnd + 36 + 24 + 4 + 1
        k = try doc.u8(k) == 1 ? try doc.block(k, limit: o.range.upperBound) : k + 1
        guard try doc.u8(k) == 1 else { throw StudioError.damaged("fecho do objeto em \(k)") }
        return (k, try doc.u32(k + 1))
    }

    /// O objeto do arquivo num caminho da árvore e a transformação dele até a página.
    func origem(_ caminho: [Int]) -> (RawObject, CGAffineTransform)? {
        var objetos = lista, t = CGAffineTransform.identity
        var achado: RawObject?
        for i in caminho {
            guard objetos.indices.contains(i) else { return nil }
            let o = objetos[i]
            t = o.matrix.concatenating(t)
            achado = o
            objetos = o.children
        }
        return achado.map { ($0, t) }
    }

    /// Um polígono (ou retângulo) do arquivo sem imagem, para os objetos novos.
    func modelo() -> RawObject? {
        func achar(_ objetos: [RawObject]) -> RawObject? {
            for o in objetos {
                if o.type == 1 || o.type == 2, let estilo = try? doc.style(at: o.base.lowerBound, limit: o.base.upperBound) {
                    if case .image = estilo.fill { continue }
                    return o
                }
                if let r = achar(o.children) { return r }
            }
            return nil
        }
        return achar(lista)
    }

    mutating func objeto(_ forma: StudioWriter.Shape) throws -> [UInt8] {
        // `daOrigem`: remontado a partir do objeto de onde veio (alterado ou cópia); `novo`: ganha id e código.
        let raw: RawObject, paraPagina: CGAffineTransform, daOrigem: Bool
        if let caminho = forma.source, let (o, t) = origem(caminho), [1, 2, 8].contains(o.type) {
            (raw, paraPagina, daOrigem) = (o, t, true)
        } else if let o = modelo() {
            (raw, paraPagina, daOrigem) = (o, .identity, false)
        } else {
            throw StudioWriter.WriteError.unsupported("nenhum polígono no arquivo para servir de modelo")
        }
        let novo = !daOrigem || forma.copy

        // Sistema local: o do objeto de origem, levado da caixa antiga para a nova (mover e redimensionar não
        // mexem no contorno local nem na imagem); objeto novo = a própria página.
        let pagina = caminhoCG(forma.subpaths)
        let caixaNova = pagina.boundingBoxOfPath
        var local = CGAffineTransform.identity
        var nosOriginais: [[LocalNode]]?
        if daOrigem {
            if raw.type == 1 || raw.type == 2 { nosOriginais = try? doc.localPath(at: raw.base.upperBound, limit: raw.bodyEnd) }
            let antiga: CGRect
            if let nos = nosOriginais {
                antiga = caminhoCG(nos.map { $0.map { absoluto($0) } }).copy(using: [paraPagina])?.boundingBoxOfPath ?? .null
            } else if let cache = raw.cache, let nos = try? doc.cachedPath(at: cache.lowerBound, limit: cache.upperBound) {
                antiga = caminhoCG(nos).boundingBoxOfPath
            } else {
                antiga = .null
            }
            local = paraPagina
            if !antiga.isNull, antiga.width > 1e-6, antiga.height > 1e-6, caixaNova.width > 1e-6, caixaNova.height > 1e-6 {
                let a = CGAffineTransform(translationX: -antiga.minX, y: -antiga.minY)
                    .concatenating(CGAffineTransform(scaleX: caixaNova.width / antiga.width, y: caixaNova.height / antiga.height))
                    .concatenating(CGAffineTransform(translationX: caixaNova.minX, y: caixaNova.minY))
                local = paraPagina.concatenating(a)
            }
            if abs(local.a * local.d - local.b * local.c) < 1e-12 { local = .identity }
        }
        let paraLocal = local.inverted()
        let nosLocais: [[LocalNode]] = forma.subpaths.filter { $0.count >= 2 }.map { nos in
            nos.map { n in
                let p = n.point.applying(paraLocal)
                let rel = { (c: CGPoint) in CGPoint(x: c.applying(paraLocal).x - p.x, y: c.applying(paraLocal).y - p.y) }
                return LocalNode(point: p, controlIn: n.controlIn.map(rel), controlOut: n.controlOut.map(rel))
            }
        }
        // Contorno igual ao de origem (só moveu/redimensionou): os bytes e o tipo (retângulo…) ficam.
        let mesmoContorno = nosOriginais.map { iguais($0, nosLocais) } ?? false
        let tipo: UInt8 = mesmoContorno ? raw.type : 2

        // Base (tipo + estilo + camada): cor da linha, preenchimento, imagem.
        var base = Array(doc.b[raw.base])
        let st = 6
        guard base.count > st + 31, base[st] == 1 else { throw StudioError.damaged("estilo em \(raw.base.lowerBound)") }
        let fimEstilo = st + 1 + Int(le32(base, st + 1))
        let estilo = Bytes(base)
        if try estilo.color(st + 7).hex != forma.line.hex || !daOrigem { put(cor(forma.line), into: &base, at: st + 7) }
        var k = try estilo.block(st + 31, limit: fimEstilo) + 1
        k = try estilo.string(k).1
        k = try estilo.u8(k) == 1 ? try estilo.string(k + 1).1 : k + 1
        var delta = 0
        switch (forma.fill, base[k]) {
        case (.keep, _), (.none, 0):
            break
        case (.none, 1):
            base[k] = 0
            base.removeSubrange((k + 1)..<(k + 17))
            delta = -16
        case (.color(let c), 1):
            put(cor(c), into: &base, at: k + 1)
        case (.color(let c), 0):
            base[k] = 1
            base.insert(contentsOf: cor(c), at: k + 1)
            delta = 16
        default:
            throw StudioWriter.WriteError.unsupported("preenchimento de imagem trocado")
        }
        if let imagem = forma.imageToPage, base[k] == 5 {
            // 2ª das três matrizes depois de [01 00 01]: pixel → sistema local do objeto.
            let depois = try Bytes(base).string(k + 1).1
            guard let j = Bytes(base).firstIndex(of: [1, 0, 1], from: depois, to: fimEstilo + delta), base[j + 39] == 1 else {
                throw StudioWriter.WriteError.unsupported("posição da imagem")
            }
            put(matriz(imagem.concatenating(paraLocal)), into: &base, at: j + 40)
        }
        put(u32(fimEstilo + delta - (st + 1)), into: &base, at: st + 1)
        base[0] = tipo
        put(u32(base.count - 1), into: &base, at: 1)

        let contorno = mesmoContorno ? Array(doc.b[raw.base.upperBound..<raw.bodyEnd]) : caminhoLocal(nosLocais)
        var corpo: [UInt8] = [1] + u32(4 + base.count + contorno.count)
        corpo += base
        corpo += contorno

        // Matriz, caixa (centro e semieixos, no sistema do pai = página), "não corta", caminho na página.
        let caixaLocal = caminhoCG(nosLocais.map { $0.map { absoluto($0) } }).boundingBoxOfPath
        let centro = CGPoint(x: caixaLocal.midX, y: caixaLocal.midY).applying(local)
        let (mw, mh) = (caixaLocal.width / 2, caixaLocal.height / 2)
        var depoisDoCorpo = matriz(local)
        depoisDoCorpo += [centro.x, centro.y, local.a * mw, local.b * mw, local.c * mh, local.d * mh].flatMap { f32($0) }
        let flag = try doc.u32(raw.bodyEnd + 60)
        depoisDoCorpo += u32(forma.cuts == (flag != 1) ? flag : (forma.cuts ? 2 : 1))
        depoisDoCorpo.append(try doc.u8(raw.bodyEnd + 64))
        depoisDoCorpo += caminhoPagina(forma.subpaths.filter { $0.count >= 2 })

        // Fecho: id, nome, código. Objeto novo ganha id e código novos; virando polígono, perde o "create_…".
        let (inicioFecho, _) = try Montador.trailer(doc, raw)
        var fecho = Array(doc.b[inicioFecho..<raw.range.upperBound])
        if novo {
            put(u32(proximoID), into: &fecho, at: 1)
            proximoID += 1
        }
        let f = Bytes(fecho)
        let fimDoze = try f.block(9, limit: fecho.count)
        let (nome, fimNome) = try f.string(fimDoze)
        let fimCodigo = try f.string(fimNome + 4).1
        if novo {
            let codigo = Array(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().utf8)
            fecho.replaceSubrange((fimNome + 8)..<fimCodigo, with: codigo)
        }
        if tipo == 2, nome != "Polygon" {
            // Depois do código: [12 bytes][FFFFFFFF][u32][u32 n][ferramenta "create_…"]; sem ela, n = 0.
            let n = fecho.count >= fimCodigo + 24 ? Int(le32(fecho, fimCodigo + 20)) : -1
            guard fimCodigo + 24 + n == fecho.count else { throw StudioWriter.WriteError.unsupported("fecho do objeto") }
            fecho.replaceSubrange((fimCodigo + 20)..<fecho.count, with: u32(0))
            fecho.replaceSubrange(fimDoze..<fimNome, with: u32(7) + Array("Polygon".utf8))
        }

        var objeto: [UInt8] = [1] + u32(4 + 1 + corpo.count + depoisDoCorpo.count + fecho.count)
        objeto.append(try doc.u8(raw.range.lowerBound + 5))
        objeto += corpo
        objeto += depoisDoCorpo
        objeto += fecho
        return objeto
    }
}

// MARK: - Bytes

private func iguais(_ a: [[LocalNode]], _ b: [[LocalNode]]) -> Bool {
    guard a.count == b.count else { return false }
    let perto = { (p: CGPoint?, q: CGPoint?) -> Bool in
        switch (p, q) {
        case (nil, nil): true
        case let (p?, q?): abs(p.x - q.x) < 1e-3 && abs(p.y - q.y) < 1e-3
        default: false
        }
    }
    return zip(a, b).allSatisfy { x, y in
        x.count == y.count && zip(x, y).allSatisfy { perto($0.point, $1.point) && perto($0.controlIn, $1.controlIn) && perto($0.controlOut, $1.controlOut) }
    }
}

private func absoluto(_ n: LocalNode) -> StudioDocument.Node {
    StudioDocument.Node(point: n.point,
                        controlIn: n.controlIn.map { CGPoint(x: n.point.x + $0.x, y: n.point.y + $0.y) },
                        controlOut: n.controlOut.map { CGPoint(x: n.point.x + $0.x, y: n.point.y + $0.y) })
}

private func caminhoCG(_ subcaminhos: [[StudioDocument.Node]]) -> CGPath {
    StudioDocument.Object(kind: "", subpaths: subcaminhos, line: StudioDocument.Color(red: 0, green: 0, blue: 0, alpha: 1),
                          fill: .none, cuts: true).path
}

/// [01 tam][u32 n − 1] { [01 tam][01][u32 pontos − 1] { [01 tam] x y alça alça [00 suave 00] } }
private func caminhoLocal(_ subcaminhos: [[LocalNode]]) -> [UInt8] {
    var conteudo = u32(subcaminhos.count - 1)
    for nos in subcaminhos {
        var sub: [UInt8] = [1] + u32(nos.count - 1)
        for n in nos {
            var ponto = f32(n.point.x) + f32(n.point.y) + alca(n.controlIn) + alca(n.controlOut)
            ponto += [0, n.controlIn != nil && n.controlOut != nil ? 1 : 0, 0]
            sub += [1] + u32(4 + ponto.count) + ponto
        }
        conteudo += [1] + u32(4 + sub.count) + sub
    }
    return [1] + u32(4 + conteudo.count) + conteudo
}

/// [01 tam][u32 n − 1] { [u32 tam][01][u32 pontos − 1] { x y alça alça } } — na página, alças relativas.
private func caminhoPagina(_ subcaminhos: [[StudioDocument.Node]]) -> [UInt8] {
    var conteudo = u32(subcaminhos.count - 1)
    for nos in subcaminhos {
        var sub: [UInt8] = [1] + u32(nos.count - 1)
        for n in nos {
            let rel = { (c: CGPoint) in CGPoint(x: c.x - n.point.x, y: c.y - n.point.y) }
            sub += f32(n.point.x) + f32(n.point.y) + alca(n.controlIn.map(rel)) + alca(n.controlOut.map(rel))
        }
        conteudo += u32(4 + sub.count) + sub
    }
    return [1] + u32(4 + conteudo.count) + conteudo
}

private func alca(_ h: CGPoint?) -> [UInt8] { h.map { [1] + f32($0.x) + f32($0.y) } ?? [0] }

/// Matriz 3 × 3 por linhas, como o leitor (x' = a·x + c·y + tx; y' = b·x + d·y + ty).
private func matriz(_ t: CGAffineTransform) -> [UInt8] {
    [t.a, t.c, t.tx, t.b, t.d, t.ty, 0, 0, 1].flatMap { f32($0) }
}

private func cor(_ c: StudioDocument.Color) -> [UInt8] { [c.red, c.green, c.blue, c.alpha].flatMap { f32($0) } }

private func f32(_ v: Double) -> [UInt8] { u32(Int(Float(v).bitPattern)) }

private func u32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((UInt32(truncatingIfNeeded: v) >> (8 * UInt32($0))) & 0xFF) } }

private func u64(_ v: Int) -> [UInt8] { (0..<8).map { UInt8((UInt64(v) >> (8 * UInt64($0))) & 0xFF) } }

private func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
}

private func put(_ valor: [UInt8], into b: inout [UInt8], at o: Int) {
    b.replaceSubrange(o..<(o + valor.count), with: valor)
}

extension Bytes {
    /// A lista de objetos pelo marcador de sempre ("auto", "auto"), sem o plano B da leitura.
    func objectListAfterMarker() -> Int? {
        let auto = Array("auto".utf8)
        let marca = [4, 0, 0, 0] + auto + [4, 0, 0, 0] + auto
        guard let i = firstIndex(of: marca, to: 1 << 16), (try? objectList(at: i + marca.count)) != nil else { return nil }
        return i + marca.count
    }
}
