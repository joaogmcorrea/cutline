// Importar EPS (e o .ai antigo, que é PostScript): o macOS 26 não interpreta mais PostScript (o CGPSConverter
// devolve nada, o NSEPSImageRep não abre, não há pstopdf), então o Cutline tem um mini-intérprete próprio.
// Os caminhos pintados viram objetos com a regra de pintura comum (Modelo/ImportarVetor.swift); o EPS não tem
// página, então a arte (a %%BoundingBox) fica no centro da A4. Três dialetos:
// - Illustrator moderno (prólogo Adobe_AGM_Core, versões 9 em diante): o prólogo é pulado e só a página roda,
//   com os atalhos do AGM (mo li cv cp f ef @ clp ct cmyk rgb sep…) definidos aqui. Degradê (shfill) vira o
//   contorno do recorte com a cor média.
// - Illustrator clássico (até a versão 8, "Illustrator 3" etc.): o corpo depois do %%EndSetup roda com os
//   operadores do formato AI (m L C f S B, k K x X, *u … *U para caminhos compostos).
// - Qualquer outro programa: o arquivo inteiro roda no intérprete.
// Textos e imagens não entram (contados). Um erro num comando não derruba o resto; há limite de operações.
import CoreGraphics
import Foundation

nonisolated enum ImportarEPS {
    nonisolated enum Dialeto {
        case agm, classico, generico
    }

    static func ler(_ dados: Data) throws -> ImportacaoVetorial {
        var b = [UInt8](dados)
        // EPS com cabeçalho binário (prévia TIFF/WMF): o PostScript está no deslocamento e no tamanho dos bytes 4–11.
        if b.starts(with: [0xC5, 0xD0, 0xD3, 0xC6]), b.count >= 12 {
            let inicio = le32(b, 4), tamanho = le32(b, 8)
            guard inicio < b.count, tamanho > 0 else { throw ImportarVetor.Erro.postscript }
            b = Array(b[inicio..<min(inicio + tamanho, b.count)])
        }
        guard b.starts(with: Array("%!".utf8)) else { throw ImportarVetor.Erro.postscript }
        let dialeto: Dialeto = buscar(b, "Adobe_AGM_Core") != nil ? .agm
            : (buscar(b, "procset Adobe_Illustrator") != nil || buscar(b, "%AI5_") != nil || buscar(b, "%AI3_") != nil) ? .classico
            : .generico
        let (inicio, fim) = trecho(b, dialeto)
        let interprete = Interprete(fonte: Fonte(b, inicio: inicio, fim: fim), dialeto: dialeto)
        interprete.rodar()

        // Caixa da arte (pt, y para cima): a do cabeçalho ou a dos desenhos.
        // Contas com números absurdos podem dar infinito: esses desenhos ficam de fora.
        let pinturas = interprete.pinturas.filter { p in
            let c = p.caminho.boundingBoxOfPath
            return c.minX.isFinite && c.minY.isFinite && c.width.isFinite && c.height.isFinite
        }
        var caixa = caixaDoCabecalho(b)
        if caixa == nil || caixa!.width <= 0 || caixa!.height <= 0 {
            caixa = pinturas.reduce(CGRect.null) { $0.union($1.caminho.boundingBoxOfPath) }
        }
        var resultado = ImportacaoVetorial(textos: interprete.textos, imagens: interprete.imagens + interprete.fonte.imagensPuladas)
        guard let caixa, !caixa.isNull, !caixa.isInfinite else { return resultado }
        let mm = 25.4 / 72
        let dx = (Documento.pagina.width - caixa.width * mm) / 2, dy = (Documento.pagina.height - caixa.height * mm) / 2
        let paraPagina = CGAffineTransform(translationX: -caixa.minX, y: -caixa.maxY)
            .concatenating(CGAffineTransform(scaleX: mm, y: -mm))
            .concatenating(CGAffineTransform(translationX: dx, y: dy))
        resultado.objetos = pinturas.compactMap { p in
            guard let pagina = p.caminho.copy(using: [paraPagina]) else { return nil }
            return ImportarVetor.objeto(pagina, traco: p.traco, espessura: p.espessura, preenchimento: p.preenchimento)
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["CUTLINE_TESTE_EPS"] != nil {
            print("EPS \(dialeto): \(pinturas.count) pinturas, \(interprete.erros) erros, desconhecidos:",
                  interprete.desconhecidos.sorted { $0.value > $1.value }.prefix(30).map { "\($0.key)×\($0.value)" })
        }
        #endif
        return resultado
    }

    static func le32(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24
    }

    /// Posição de `texto` em `b` a partir de `desde` (nil se não houver).
    static func buscar(_ b: [UInt8], _ texto: String, desde: Int = 0, ate: Int? = nil) -> Int? {
        let agulha = Array(texto.utf8), fim = min(ate ?? b.count, b.count)
        guard desde < fim, agulha.count <= fim - desde else { return nil }
        return b.withUnsafeBufferPointer { p -> Int? in
            agulha.withUnsafeBufferPointer { a -> Int? in
                guard let achou = memmem(p.baseAddress! + desde, fim - desde, a.baseAddress!, a.count) else { return nil }
                return p.baseAddress!.distance(to: achou.assumingMemoryBound(to: UInt8.self))
            }
        }
    }

    /// Comentário DSC no começo de uma linha.
    static func linha(_ b: [UInt8], _ marca: String, desde: Int = 0) -> Int? {
        var i = desde
        while let achou = buscar(b, marca, desde: i) {
            if achou == 0 || b[achou - 1] == 10 || b[achou - 1] == 13 { return achou }
            i = achou + 1
        }
        return nil
    }

    static func depoisDaLinha(_ b: [UInt8], _ i: Int) -> Int {
        var j = i
        while j < b.count, b[j] != 10, b[j] != 13 { j += 1 }
        return j
    }

    /// Parte do arquivo que roda: no Illustrator, só a página (os prólogos dele são enormes e não fazem falta).
    static func trecho(_ b: [UInt8], _ dialeto: Dialeto) -> (Int, Int) {
        let marcas: [String] = switch dialeto {
        case .agm: ["%%EndPageSetup", "%%EndSetup", "%%EndProlog"]
        case .classico: ["%%EndSetup", "%%EndProlog"]
        case .generico: []
        }
        var inicio = 0
        for marca in marcas {
            if let i = linha(b, marca) { inicio = depoisDaLinha(b, i); break }
        }
        var fim = b.count
        if dialeto != .generico {
            for marca in ["%%PageTrailer", "%%Trailer", "%%EOF"] {
                if let i = linha(b, marca, desde: inicio) { fim = i; break }
            }
        }
        return (inicio, fim)
    }

    /// %%HiResBoundingBox ou %%BoundingBox (também no fim do arquivo, com "(atend)").
    static func caixaDoCabecalho(_ b: [UInt8]) -> CGRect? {
        for marca in ["%%HiResBoundingBox:", "%%BoundingBox:"] {
            var i = 0
            while let achou = linha(b, marca, desde: i) {
                let fim = depoisDaLinha(b, achou)
                let texto = String(decoding: b[(achou + marca.utf8.count)..<fim], as: UTF8.self)
                let v = texto.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Double($0) }
                if v.count == 4, v[2] > v[0], v[3] > v[1] { return CGRect(x: v[0], y: v[1], width: v[2] - v[0], height: v[3] - v[1]) }
                i = fim
            }
        }
        return nil
    }

    /// Um caminho pintado, em pt (espaço padrão do PostScript, y para cima).
    nonisolated struct Pintura {
        var caminho: CGPath
        var traco: CMYK?
        /// Em pt.
        var espessura: Double
        var preenchimento: CMYK?
    }
}

// MARK: - Valores

extension ImportarEPS {
    nonisolated final class Cadeia {
        var b: [UInt8]
        init(_ b: [UInt8]) { self.b = b }
        var texto: String { String(decoding: b, as: UTF8.self) }
    }

    nonisolated final class Lista {
        var v: [Valor]
        init(_ v: [Valor]) { self.v = v }
    }

    nonisolated final class Dicionario {
        var d: [String: (chave: Valor, valor: Valor)] = [:]

        subscript(_ nome: String) -> Valor? {
            get { d[nome]?.valor }
            set { d[nome] = newValue.map { (chave: Valor.nome(nome, executavel: false), valor: $0) } }
        }
    }

    nonisolated indirect enum Valor {
        case int(Int), real(Double), bool(Bool), null, marca
        case nome(String, executavel: Bool)
        case texto(Cadeia, executavel: Bool)
        case lista(Lista, executavel: Bool)
        case dicionario(Dicionario)
        case operador(String)
        case arquivo(Arquivo)
        case salvo(Int)

        var numero: Double? {
            switch self {
            case .int(let i): Double(i)
            case .real(let r): r
            default: nil
            }
        }

        /// Chave de dicionário (nomes e textos valem pelo texto, como no PostScript).
        var chave: String {
            switch self {
            case .nome(let n, _): n
            case .texto(let c, _): c.texto
            case .int(let i): "#\(i)"
            case .real(let r): r == r.rounded() && abs(r) < 1e15 ? "#\(Int(r))" : "#r\(r)"
            case .bool(let b): "#b\(b)"
            case .operador(let n): "#o\(n)"
            default: "#?"
            }
        }
    }
}

// MARK: - Leitura do arquivo (tokens e currentfile)

extension ImportarEPS {
    nonisolated final class Fonte {
        let b: [UInt8]
        var i: Int
        let fim: Int
        var acabou = false
        /// Blocos de dados pulados (%%BeginData, documentos embutidos): imagens, quase sempre.
        var imagensPuladas = 0

        init(_ b: [UInt8], inicio: Int, fim: Int) {
            self.b = b
            i = inicio
            self.fim = fim
        }

        static func espaco(_ c: UInt8) -> Bool { c == 32 || c == 10 || c == 13 || c == 9 || c == 12 || c == 0 }
        static func delimitador(_ c: UInt8) -> Bool {
            c == 40 || c == 41 || c == 60 || c == 62 || c == 91 || c == 93 || c == 123 || c == 125 || c == 47 || c == 37
        }

        func byte() -> UInt8? {
            guard i < fim else { return nil }
            i += 1
            return b[i - 1]
        }

        func espiar(_ d: Int = 0) -> UInt8? { i + d < fim ? b[i + d] : nil }

        nonisolated enum Token {
            case valor(Valor)
            case imediato(String)
            case fechaProcedimento
        }

        /// Próximo token (nil no fim).
        func token() -> Token? {
            while true {
                guard !acabou, let c = espiar() else { return nil }
                if Self.espaco(c) { i += 1; continue }
                if c == 37 { comentario(); continue }
                break
            }
            let c = b[i]
            switch c {
            case 40:
                i += 1
                return .valor(.texto(Cadeia(lerTexto()), executavel: false))
            case 60:
                if espiar(1) == 60 { i += 2; return .valor(.nome("<<", executavel: true)) }
                if espiar(1) == 126 { i += 2; return .valor(.texto(Cadeia(lerASCII85()), executavel: false)) }
                i += 1
                return .valor(.texto(Cadeia(lerHex()), executavel: false))
            case 62:
                if espiar(1) == 62 { i += 2; return .valor(.nome(">>", executavel: true)) }
                i += 1
                return token()
            case 91, 93:
                i += 1
                return .valor(.nome(c == 91 ? "[" : "]", executavel: true))
            case 123:
                i += 1
                return .valor(.lista(Lista([]), executavel: true))   // o intérprete lê o resto (ver procedimento)
            case 125:
                i += 1
                return .fechaProcedimento
            case 41:
                i += 1
                return token()
            case 47:
                i += 1
                if espiar() == 47 {
                    i += 1
                    return .imediato(lerPalavra())
                }
                return .valor(.nome(lerPalavra(), executavel: false))
            default:
                let palavra = lerPalavra()
                return .valor(Self.numero(palavra) ?? .nome(palavra, executavel: true))
            }
        }

        private func lerPalavra() -> String {
            let inicio = i
            while i < fim, !Self.espaco(b[i]), !Self.delimitador(b[i]) { i += 1 }
            let palavra = String(decoding: b[inicio..<i], as: UTF8.self)
            // O PostScript consome um espaço depois do nome (o currentfile lê a partir dali).
            if i < fim, Self.espaco(b[i]) {
                if b[i] == 13, i + 1 < fim, b[i + 1] == 10 { i += 2 } else { i += 1 }
            }
            return palavra
        }

        static func numero(_ s: String) -> Valor? {
            guard let primeiro = s.utf8.first, (primeiro >= 48 && primeiro <= 57) || primeiro == 43 || primeiro == 45 || primeiro == 46
            else { return nil }
            if let n = Int(s) { return .int(n) }
            if let jogo = s.firstIndex(of: "#"), let base = Int(s[..<jogo]), (2...36).contains(base),
               let n = Int(s[s.index(after: jogo)...], radix: base) { return .int(n) }
            guard s.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || $0 == 43 || $0 == 45 || $0 == 46 || $0 == 101 || $0 == 69 }),
                  let r = Double(s), r.isFinite else { return nil }
            return .real(r)
        }

        private func comentario() {
            let inicio = i
            let comecoDeLinha = i == 0 || b[i - 1] == 10 || b[i - 1] == 13
            while i < fim, b[i] != 10, b[i] != 13 { i += 1 }
            guard comecoDeLinha, i - inicio >= 5, b[inicio + 1] == 37 else { return }
            let texto = String(decoding: b[inicio..<min(i, inicio + 20)], as: UTF8.self)
            func pularAte(_ marca: String) {
                if let j = ImportarEPS.linha(b, marca, desde: i), j < fim { i = ImportarEPS.depoisDaLinha(b, j) } else { i = fim }
            }
            if texto.hasPrefix("%%EOF") {
                acabou = true
            } else if texto.hasPrefix("%%BeginData") {
                pularAte("%%EndData")
                imagensPuladas += 1
            } else if texto.hasPrefix("%%BeginDocument") {
                pularAte("%%EndDocument")
                imagensPuladas += 1
            } else if texto.hasPrefix("%%BeginBinary") {
                pularAte("%%EndBinary")
            }
        }

        private func lerTexto() -> [UInt8] {
            var saida: [UInt8] = [], nivel = 1
            while let c = byte() {
                switch c {
                case 40: nivel += 1; saida.append(c)
                case 41:
                    nivel -= 1
                    if nivel == 0 { return saida }
                    saida.append(c)
                case 92:
                    guard let e = byte() else { return saida }
                    switch e {
                    case 110: saida.append(10)
                    case 114: saida.append(13)
                    case 116: saida.append(9)
                    case 98: saida.append(8)
                    case 102: saida.append(12)
                    case 13: if espiar() == 10 { i += 1 }
                    case 10: break
                    case 48...55:
                        var v = Int(e - 48)
                        for _ in 0..<2 {
                            guard let d = espiar(), d >= 48, d <= 55 else { break }
                            v = v * 8 + Int(d - 48)
                            i += 1
                        }
                        saida.append(UInt8(v & 255))
                    default: saida.append(e)
                    }
                default: saida.append(c)
                }
            }
            return saida
        }

        static func hex(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: c - 48
            case 65...70: c - 55
            case 97...102: c - 87
            default: nil
            }
        }

        private func lerHex() -> [UInt8] {
            var saida: [UInt8] = [], alto: UInt8?
            while let c = byte(), c != 62 {
                guard let v = Self.hex(c) else { continue }
                if let a = alto { saida.append(a << 4 | v); alto = nil } else { alto = v }
            }
            if let a = alto { saida.append(a << 4) }
            return saida
        }

        private func lerASCII85() -> [UInt8] {
            var saida: [UInt8] = [], grupo: [UInt32] = []
            func soltar(_ n: Int) {
                var v: UInt32 = 0
                for k in 0..<5 { v = v &* 85 &+ (k < grupo.count ? grupo[k] : 84) }
                let bytes = [UInt8(v >> 24), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)]
                saida += bytes.prefix(n)
            }
            while let c = byte() {
                if c == 126 { if espiar() == 62 { i += 1 }; break }
                if c == 122, grupo.isEmpty { saida += [0, 0, 0, 0]; continue }
                guard c >= 33, c <= 117 else { continue }
                grupo.append(UInt32(c - 33))
                if grupo.count == 5 { soltar(4); grupo = [] }
            }
            if grupo.count > 1 { soltar(grupo.count - 1) }
            return saida
        }

        // currentfile

        func lerLinha() -> [UInt8]? {
            guard i < fim else { return nil }
            let inicio = i
            while i < fim, b[i] != 10, b[i] != 13 { i += 1 }
            let linha = Array(b[inicio..<i])
            if i < fim { if b[i] == 13, i + 1 < fim, b[i + 1] == 10 { i += 2 } else { i += 1 } }
            return linha
        }

        /// Pula o trecho criptografado do eexec (fontes): vai até o cleartomark do fim dele.
        func pularEexec() {
            if let j = ImportarEPS.buscar(b, "cleartomark", desde: i, ate: fim) { i = j } else { i = fim }
        }
    }

    /// Arquivo do PostScript: o próprio programa (currentfile) ou um filtro sobre ele.
    nonisolated final class Arquivo {
        nonisolated enum Tipo {
            case fonte, ascii85, asciiHex, subArquivo(contagem: Int, fim: [UInt8]), outro
        }

        let tipo: Tipo
        let base: Arquivo?
        let fonte: Fonte
        private var terminou = false
        private var pendentes: [UInt8] = []
        /// SubFileDecode: bytes que faltam (sem marca) ou ocorrências da marca a deixar passar.
        private var restante = 0

        init(fonte: Fonte, tipo: Tipo = .fonte, base: Arquivo? = nil) {
            self.fonte = fonte
            self.tipo = tipo
            self.base = base
            if case .subArquivo(let n, _) = tipo { restante = n }
        }

        private func cru() -> UInt8? { base?.lerByte() ?? (base == nil ? fonte.byte() : nil) }

        func lerByte() -> UInt8? {
            if !pendentes.isEmpty { return pendentes.removeFirst() }
            guard !terminou else { return nil }
            switch tipo {
            case .fonte:
                return fonte.byte()
            case .outro:
                return cru()
            case .asciiHex:
                var alto: UInt8?
                while let c = cru() {
                    if c == 62 { terminou = true; return alto.map { $0 << 4 } }
                    guard let v = Fonte.hex(c) else { continue }
                    if let a = alto { return a << 4 | v }
                    alto = v
                }
                terminou = true
                return nil
            case .ascii85:
                var grupo: [UInt32] = []
                while grupo.count < 5, let c = cru() {
                    if c == 126 { _ = cru(); terminou = true; break }
                    if c == 122, grupo.isEmpty { pendentes = [0, 0, 0]; return 0 }
                    guard c >= 33, c <= 117 else { continue }
                    grupo.append(UInt32(c - 33))
                }
                if grupo.count < 5 { terminou = true }
                guard grupo.count >= 2 else { return nil }
                var v: UInt32 = 0
                for k in 0..<5 { v = v &* 85 &+ (k < grupo.count ? grupo[k] : 84) }
                let bytes = [UInt8(v >> 24), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)]
                pendentes = Array(bytes.prefix(grupo.count == 5 ? 4 : grupo.count - 1))
                return pendentes.removeFirst()
            case .subArquivo(_, let fim):
                if fim.isEmpty {
                    guard restante > 0 else { terminou = true; return nil }
                    restante -= 1
                    return cru()
                }
                // Sobre o próprio programa: confere a marca do fim antes de cada byte.
                if base.map({ if case .fonte = $0.tipo { true } else { false } }) ?? true {
                    let f = fonte
                    if f.i + fim.count <= f.fim, Array(f.b[f.i..<(f.i + fim.count)]) == fim {
                        if restante == 0 { f.i += fim.count; terminou = true; return nil }
                        restante -= 1
                    }
                }
                return cru()
            }
        }

        /// Lê (e descarta) até o fim do filtro, ou `bytes` bytes do programa.
        func pular(bytes: Int) {
            switch tipo {
            case .fonte: fonte.i = min(fonte.i + min(bytes, fonte.fim), fonte.fim)
            case .outro:
                if let base { base.pular(bytes: bytes) } else { fonte.i = min(fonte.i + min(bytes, fonte.fim), fonte.fim) }
            default:
                var n = 0
                while lerByte() != nil, n < 64 << 20 { n += 1 }
            }
        }
    }
}

// MARK: - Intérprete

extension ImportarEPS {
    nonisolated enum Falha: Error {
        case pilhaVazia, tipo, indefinido(String), intervalo, sair, parar, limite, fim
    }

    nonisolated indirect enum EspacoCor {
        case cinza, rgb, cmyk, padrao
        case separacao(nome: String, alternativo: EspacoCor, transformacao: Valor)
        case deviceN(n: Int, alternativo: EspacoCor, transformacao: Valor)
        case indexado(base: EspacoCor, tabela: Valor)
        /// Cor especial do AGM sem transformação: a cor cheia no espaço alternativo, vezes a tinta.
        case tinta(nome: String, cheia: [Double], alternativo: EspacoCor)
        case outro(Int)

        var componentes: Int {
            switch self {
            case .cinza, .separacao, .indexado, .tinta: 1
            case .rgb: 3
            case .cmyk: 4
            case .padrao: 0
            case .deviceN(let n, _, _), .outro(let n): n
            }
        }
    }

    nonisolated struct Grafico {
        var ctm = CGAffineTransform.identity
        var caminho = CGMutablePath()
        var recorte: CGPath?
        var espaco = EspacoCor.cinza
        /// Cor atual (PostScript: a mesma para preencher e traçar).
        var cor: CMYK? = CMYK(c: 0, m: 0, y: 0, k: 100)
        /// Formato AI: cores separadas de preenchimento e de traço.
        var preenchimento: CMYK? = CMYK(c: 0, m: 0, y: 0, k: 100)
        var traco: CMYK? = CMYK(c: 0, m: 0, y: 0, k: 100)
        var espessura = 1.0
        var corpoFonte = 12.0

        func copia() -> Grafico {
            var g = self
            g.caminho = caminho.mutableCopy() ?? CGMutablePath()
            return g
        }
    }

    nonisolated final class Interprete {
        let fonte: Fonte
        let dialeto: Dialeto
        var pilha: [Valor] = []
        var dicts: [Dicionario]
        let sistema = Dicionario(), global = Dicionario(), usuario = Dicionario()
        var g = Grafico()
        var pilhaGrafica: [Grafico] = []
        var pinturas: [Pintura] = []
        var textos = 0, imagens = 0, erros = 0
        var desconhecidos: [String: Int] = [:]
        private var operacoes = 0, profundidade = 0
        private var recursos: [String: Valor] = [:]
        /// Caminho composto do formato AI (*u … *U): os subcaminhos se juntam num objeto.
        private var composto: (caminho: CGMutablePath, preencher: Bool, tracar: Bool)?
        private let arquivoAtual: Arquivo
        static let limite = 40_000_000

        init(fonte: Fonte, dialeto: Dialeto) {
            self.fonte = fonte
            self.dialeto = dialeto
            arquivoAtual = Arquivo(fonte: fonte)
            dicts = [sistema, global, usuario]
            for nome in Self.operadores { sistema[nome] = .operador(nome) }
            let nativos: [String] = switch dialeto {
            case .agm: Self.operadoresAGM
            case .classico: Self.operadoresAI
            case .generico: []
            }
            for nome in nativos { sistema[nome] = .operador(nome) }
            sistema["systemdict"] = .dicionario(sistema)
            sistema["userdict"] = .dicionario(usuario)
            sistema["globaldict"] = .dicionario(global)
            for nome in ["statusdict", "errordict", "$error", "FontDirectory", "GlobalFontDirectory", "SharedFontDirectory", "serverdict"] {
                sistema[nome] = .dicionario(Dicionario())
            }
            let codificacao = Valor.lista(Lista(Array(repeating: .nome(".notdef", executavel: false), count: 256)), executavel: false)
            sistema["StandardEncoding"] = codificacao
            sistema["ISOLatin1Encoding"] = codificacao
        }

        // MARK: Execução

        func rodar() {
            while let token = fonte.token() {
                do {
                    switch token {
                    case .fechaProcedimento: continue
                    case .imediato(let nome): pilha.append(buscar(nome) ?? .nome(nome, executavel: false))
                    case .valor(let v):
                        if case .lista(_, true) = v { pilha.append(.lista(procedimento(), executavel: true)) } else { try executar(v) }
                    }
                } catch Falha.limite {
                    break
                } catch Falha.fim {
                    break
                } catch {
                    erros += 1
                }
                if operacoes > Self.limite { break }
            }
        }

        /// Lê um procedimento até a chave que fecha (a que abre já foi lida).
        private func procedimento(de f: Fonte? = nil) -> Lista {
            let fonte = f ?? self.fonte
            var itens: [Valor] = []
            while let token = fonte.token() {
                switch token {
                case .fechaProcedimento: return Lista(itens)
                case .imediato(let nome): itens.append(buscar(nome) ?? .nome(nome, executavel: false))
                case .valor(let v):
                    if case .lista(_, true) = v { itens.append(.lista(procedimento(de: fonte), executavel: true)) } else { itens.append(v) }
                }
            }
            return Lista(itens)
        }

        func buscar(_ nome: String) -> Valor? {
            for d in dicts.reversed() { if let v = d[nome] { return v } }
            return nil
        }

        func executar(_ v: Valor) throws {
            operacoes += 1
            if operacoes > Self.limite { throw Falha.limite }
            switch v {
            case .nome(let nome, true):
                guard let valor = buscar(nome) else {
                    desconhecidos[nome, default: 0] += 1
                    throw Falha.indefinido(nome)
                }
                switch valor {
                case .lista(let l, true): try rodar(l)
                case .operador(let n): try operador(n)
                case .nome(_, true): try executar(valor)
                default: pilha.append(valor)
                }
            case .lista(let l, true): try rodar(l)
            case .operador(let n): try operador(n)
            case .texto(let c, true):
                let sub = Fonte(c.b, inicio: 0, fim: c.b.count)
                while let token = sub.token() {
                    switch token {
                    case .fechaProcedimento: continue
                    case .imediato(let nome): pilha.append(buscar(nome) ?? .nome(nome, executavel: false))
                    case .valor(let v):
                        if case .lista(_, true) = v { pilha.append(.lista(procedimento(de: sub), executavel: true)) } else { try executar(v) }
                    }
                }
            default:
                pilha.append(v)
            }
        }

        func rodar(_ proc: Lista) throws {
            profundidade += 1
            defer { profundidade -= 1 }
            // Recursão sem fim (ou um arquivo hostil) falha só aquele comando; o limite cabe na pilha da thread principal.
            guard profundidade < 120 else { throw Falha.intervalo }
            for item in proc.v {
                switch item {
                case .lista(_, true): pilha.append(item)
                case .nome(_, true), .operador: try executar(item)
                default: pilha.append(item)
                }
            }
        }

        // MARK: Pilha

        func tirar() throws -> Valor {
            guard let v = pilha.popLast() else { throw Falha.pilhaVazia }
            return v
        }

        func num() throws -> Double {
            guard let n = try tirar().numero else { throw Falha.tipo }
            guard n.isFinite else { throw Falha.intervalo }
            return n
        }

        func inteiro() throws -> Int { try Self.paraInteiro(try num()) }

        /// Arquivos malformados trazem números absurdos: fora do intervalo é erro (nunca uma conversão que derruba o app).
        static func paraInteiro(_ n: Double) throws -> Int {
            guard n.isFinite, abs(n) < 1e15 else { throw Falha.intervalo }
            return Int(n)
        }

        func logico() throws -> Bool {
            guard case .bool(let b) = try tirar() else { throw Falha.tipo }
            return b
        }

        func lista() throws -> Lista {
            guard case .lista(let l, _) = try tirar() else { throw Falha.tipo }
            return l
        }

        func dicionario() throws -> Dicionario {
            guard case .dicionario(let d) = try tirar() else { throw Falha.tipo }
            return d
        }

        func cadeia() throws -> Cadeia {
            guard case .texto(let c, _) = try tirar() else { throw Falha.tipo }
            return c
        }

        func procedimentoNaPilha() throws -> Valor {
            let v = try tirar()
            guard case .lista = v else { throw Falha.tipo }
            return v
        }

        func numeros(_ n: Int) throws -> [Double] {
            guard pilha.count >= n else { throw Falha.pilhaVazia }
            var v = [Double](repeating: 0, count: n)
            for k in stride(from: n - 1, through: 0, by: -1) { v[k] = try num() }
            return v
        }

        func empurrar(_ x: Double) { pilha.append(.real(x)) }

        static func matriz(_ l: Lista) throws -> CGAffineTransform {
            let v = l.v.compactMap(\.numero)
            guard v.count == 6 else { throw Falha.tipo }
            return CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
        }

        static func lista(_ t: CGAffineTransform) -> [Valor] { [t.a, t.b, t.c, t.d, t.tx, t.ty].map { .real($0) } }

        /// Matriz opcional no topo (as formas "x y matriz transform", "tx ty matriz translate").
        func matrizNoTopo() -> Lista? {
            if case .lista(let l, _) = pilha.last, l.v.count == 6, l.v.allSatisfy({ $0.numero != nil }) {
                pilha.removeLast()
                return l
            }
            return nil
        }

        func igual(_ a: Valor, _ b: Valor) -> Bool {
            switch (a, b) {
            case (.int, _), (.real, _): if let x = a.numero, let y = b.numero { return x == y }; return false
            case (.bool(let x), .bool(let y)): return x == y
            case (.null, .null), (.marca, .marca): return true
            case (.nome, .nome), (.nome, .texto), (.texto, .nome), (.texto, .texto): return a.chave == b.chave
            case (.lista(let x, _), .lista(let y, _)): return x === y
            case (.dicionario(let x), .dicionario(let y)): return x === y
            case (.operador(let x), .operador(let y)): return x == y
            default: return false
            }
        }

        // MARK: Pintura

        private var escalaAtual: Double { sqrt(abs(g.ctm.a * g.ctm.d - g.ctm.b * g.ctm.c)) }

        func emitir(_ caminho: CGPath, traco: CMYK?, preenchimento: CMYK?) {
            guard !caminho.isEmpty, traco != nil || preenchimento != nil else { return }
            let espessura = g.espessura * escalaAtual
            // Preencher e depois traçar o mesmo caminho (como o PostScript faz um objeto com os dois): um objeto só.
            if let traco, preenchimento == nil, let ultimo = pinturas.last, ultimo.traco == nil, ultimo.caminho == caminho {
                pinturas[pinturas.count - 1].traco = traco
                pinturas[pinturas.count - 1].espessura = espessura
                return
            }
            pinturas.append(Pintura(caminho: caminho.copy() ?? caminho, traco: traco, espessura: espessura, preenchimento: preenchimento))
        }

        func novoCaminho() { g.caminho = CGMutablePath() }

        func ponto(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y).applying(g.ctm) }

        func pontoAtualUsuario() throws -> CGPoint {
            guard !g.caminho.isEmpty else { throw Falha.intervalo }
            return g.caminho.currentPoint.applying(g.ctm.inverted())
        }

        /// Pintura do formato AI: `fechar` (minúscula), preencher e traçar; dentro de *u … *U, junta.
        func pintarAI(fechar: Bool, preencher: Bool, tracar: Bool) {
            if fechar, !g.caminho.isEmpty { g.caminho.closeSubpath() }
            if var c = composto {
                c.caminho.addPath(g.caminho)
                c.preencher = c.preencher || preencher
                c.tracar = c.tracar || tracar
                composto = c
            } else {
                emitir(g.caminho, traco: tracar ? g.traco : nil, preenchimento: preencher ? g.preenchimento : nil)
            }
            novoCaminho()
            pilha.removeAll()
        }

        // MARK: Cores

        func espaco(de v: Valor) -> EspacoCor {
            func porNome(_ n: String) -> EspacoCor {
                switch n {
                case "DeviceGray", "CalGray", "G", "CIEBasedA": .cinza
                case "DeviceRGB", "CalRGB", "RGB", "CIEBasedABC", "CIEBasedDEF": .rgb
                case "DeviceCMYK", "CMYK", "CIEBasedDEFG": .cmyk
                case "Pattern": .padrao
                default: .cinza
                }
            }
            switch v {
            case .nome(let n, _): return porNome(n)
            case .lista(let l, _):
                guard let primeiro = l.v.first, case .nome(let tipo, _) = primeiro else { return .cinza }
                switch tipo {
                case "Separation" where l.v.count >= 4:
                    let nome = l.v[1].chave
                    return .separacao(nome: nome, alternativo: espaco(de: l.v[2]), transformacao: l.v[3])
                case "DeviceN" where l.v.count >= 4:
                    var n = 1
                    if case .lista(let nomes, _) = l.v[1] { n = nomes.v.count }
                    return .deviceN(n: n, alternativo: espaco(de: l.v[2]), transformacao: l.v[3])
                case "Indexed" where l.v.count >= 4:
                    return .indexado(base: espaco(de: l.v[1]), tabela: l.v[3])
                case "ICCBased":
                    if l.v.count >= 2, case .dicionario(let d) = l.v[1], let n = d["N"]?.numero, let i = try? Self.paraInteiro(n) {
                        return .outro(min(max(i, 1), 32))
                    }
                    return .rgb
                default:
                    return porNome(tipo)
                }
            default:
                return .cinza
            }
        }

        /// Cor do espaço com estes componentes, em CMYK (executa as transformações de tinta das cores especiais).
        func resolver(_ espaco: EspacoCor, _ v: [Double], nivel: Int = 0) -> CMYK? {
            guard nivel < 5 else { return nil }
            func transformar(_ entrada: [Double], _ proc: Valor, _ alternativo: EspacoCor) -> CMYK? {
                let antes = pilha.count
                entrada.forEach(empurrar)
                if (try? executar(proc)) == nil { pilha.removeLast(max(0, pilha.count - antes)); return nil }
                let n = alternativo.componentes
                guard pilha.count - antes >= n else { pilha.removeLast(max(0, pilha.count - antes)); return nil }
                let saida = pilha.suffix(n).compactMap(\.numero)
                pilha.removeLast(pilha.count - antes)
                return saida.count == n ? resolver(alternativo, saida, nivel: nivel + 1) : nil
            }
            switch espaco {
            case .cinza: return v.first.flatMap { ImportarVetor.cor([$0]) }
            case .rgb: return v.count >= 3 ? ImportarVetor.cor(Array(v.prefix(3))) : nil
            case .cmyk: return v.count >= 4 ? ImportarVetor.cor(Array(v.prefix(4))) : nil
            case .padrao: return CMYK(c: 0, m: 0, y: 0, k: 50)
            case .outro(let n): return v.count >= n ? ImportarVetor.cor(Array(v.prefix(n))) : nil
            case .separacao(let nome, let alternativo, let proc):
                let tinta = v.first ?? 1
                if nome == "None" { return nil }
                if nome == "All" { return CMYK(c: 0, m: 0, y: 0, k: (min(max(tinta, 0), 1) * 100).rounded()) }
                return transformar([tinta], proc, alternativo)
            case .deviceN(let n, let alternativo, let proc):
                return transformar(Array((v + Array(repeating: 1, count: n)).prefix(n)), proc, alternativo)
            case .tinta(let nome, let cheia, let alternativo):
                let t = min(max(v.first ?? 1, 0), 1)
                if nome == "All" || cheia.isEmpty { return CMYK(c: 0, m: 0, y: 0, k: (t * 100).rounded()) }
                // Subtrativo (CMYK, cinza como tinta): proporcional; aditivo (RGB): do branco até a cor.
                let aditivo = if case .rgb = alternativo { true } else { false }
                return resolver(alternativo, cheia.map { aditivo ? 1 - (1 - $0) * t : $0 * t }, nivel: nivel + 1)
            case .indexado(let base, let tabela):
                guard let indice = try? Self.paraInteiro(v.first ?? 0), indice >= 0, indice < 65536 else { return nil }
                let i = indice, n = base.componentes
                switch tabela {
                case .texto(let c, _):
                    guard n > 0, (i + 1) * n <= c.b.count else { return nil }
                    return resolver(base, c.b[(i * n)..<((i + 1) * n)].map { Double($0) / 255 }, nivel: nivel + 1)
                case .lista:
                    return transformar([Double(i)], tabela, base)
                default: return nil
                }
            }
        }

        func definirEspaco(_ e: EspacoCor) {
            g.espaco = e
            let inicial: [Double] = switch e {
            case .cmyk: [0, 0, 0, 1]
            case .separacao: [1]
            case .deviceN(let n, _, _): Array(repeating: 1, count: n)
            default: Array(repeating: 0, count: e.componentes)
            }
            g.cor = resolver(e, inicial)
        }

        /// Cor média de um degradê (shfill): as C0/C1 das funções.
        func corDoDegrade(_ d: Dicionario) -> CMYK? {
            let espaco = d["ColorSpace"].map(espaco(de:)) ?? g.espaco
            var amostras: [[Double]] = []
            func visitar(_ v: Valor?, nivel: Int) {
                guard nivel < 6, let v else { return }
                switch v {
                case .dicionario(let f):
                    for chave in ["C0", "C1"] {
                        if case .lista(let l, _) = f[chave] { amostras.append(l.v.compactMap(\.numero)) }
                    }
                    visitar(f["Functions"], nivel: nivel + 1)
                case .lista(let l, _):
                    for item in l.v { visitar(item, nivel: nivel + 1) }
                default: break
                }
            }
            visitar(d["Function"], nivel: 0)
            let n = espaco.componentes
            let validas = amostras.filter { $0.count == n }
            guard !validas.isEmpty else { return CMYK(c: 0, m: 0, y: 0, k: 50) }
            let media = (0..<n).map { k in validas.map { $0[k] }.reduce(0, +) / Double(validas.count) }
            return resolver(espaco, media)
        }

        // MARK: Imagens

        /// Pula os dados de uma imagem (string, procedimento que lê do arquivo ou filtro).
        func pularDados(_ fontes: [Valor], bytes: Int) {
            imagens += 1
            for fonte in fontes {
                switch fonte {
                case .lista(_, true):
                    var lidos = 0, voltas = 0
                    while lidos < bytes, voltas < 1_000_000 {
                        voltas += 1
                        let antes = pilha.count
                        guard (try? executar(fonte)) != nil, pilha.count > antes, case .texto(let c, _) = pilha.removeLast(),
                              !c.b.isEmpty else { break }
                        lidos += c.b.count
                        pilha.removeLast(max(0, pilha.count - antes))
                    }
                case .arquivo(let a):
                    a.pular(bytes: bytes)
                default:
                    break
                }
            }
        }

        /// Tamanho dos dados de uma imagem, limitado (dimensões absurdas não estouram a conta).
        private static func tamanho(_ w: Double, _ h: Double, _ bpc: Double, _ n: Double) -> Int {
            let lim = { (x: Double) in x.isFinite ? min(max(x, 0), 100_000) : 0 }
            return Int(min(((lim(w) * lim(bpc) * lim(n) + 7) / 8).rounded(.down) * lim(h), 1e12))
        }

        func imagem(mascara: Bool, colorida: Bool = false) throws {
            if case .dicionario(let d) = pilha.last {
                pilha.removeLast()
                let n = mascara ? 1 : max(g.espaco.componentes, 1)
                pularDados([d["DataSource"] ?? .null], bytes: Self.tamanho(d["Width"]?.numero ?? 0, d["Height"]?.numero ?? 0,
                                                                         d["BitsPerComponent"]?.numero ?? 1, Double(n)))
                return
            }
            if colorida {
                let ncomp = try inteiro(), multi = try logico()
                guard (1...4).contains(ncomp) else { throw Falha.intervalo }
                var fontes: [Valor] = []
                for _ in 0..<(multi ? ncomp : 1) { fontes.insert(try tirar(), at: 0) }
                _ = try tirar()   // matriz
                let bpc = try num(), h = try num(), w = try num()
                pularDados(fontes, bytes: Self.tamanho(w, h, bpc, Double(multi ? 1 : ncomp)))
                return
            }
            let fonte = try tirar()
            _ = try tirar()   // matriz
            let terceiro = try tirar()   // bits por componente (ou a polaridade da máscara)
            let h = try num(), w = try num()
            pularDados([fonte], bytes: Self.tamanho(w, h, mascara ? 1 : terceiro.numero ?? 8, 1))
        }

        // MARK: Operadores

        static let operadoresAGM = ["mo", "li", "cv", "cp", "np", "f", "ef", "@", "clp", "eclp", "nclp", "ct", "pgsv", "pgrs", "sop",
                                    "lw", "lc", "lj", "ml", "dsh", "sadj", "gry", "rgb", "cmyk", "nzopmsc", "sep", "sepcs", "devn",
                                    "devncs", "idx", "idxcs", "colr", "csacrd", "level3", "add_res", "get_res", "del_res", "clonedict",
                                    "gx", "cf", "fl", "rs"]

        static let operadoresAI = ["m", "l", "L", "c", "C", "v", "V", "y", "Y", "N", "n", "F", "f", "S", "s", "B", "b", "H", "h", "*u",
                                   "*U", "u", "U", "q", "Q", "W", "D", "A", "O", "R", "XR", "J", "j", "w", "M", "d", "Ar", "i", "k", "K",
                                   "g", "G", "x", "X", "Xa", "XA", "Xx", "XX", "Xk", "XK", "To", "XI", "XG", "Ln", "LB", "p", "P"]

        static let operadores: [String] = """
        pop exch dup copy index roll clear count mark cleartomark counttomark [ ] << >> \
        add sub mul div idiv mod neg abs ceiling floor round truncate sqrt atan cos sin exp ln log rand srand rrand cvi cvr \
        eq ne gt ge lt le and or xor not bitshift true false null \
        exec if ifelse for repeat loop exit forall stop stopped quit countexecstack execstack \
        type cvn cvs cvrs cvlit cvx xcheck rcheck wcheck readonly executeonly noaccess \
        dict begin end def load store known where undef currentdict countdictstack dictstack cleardictstack maxlength \
        array string length get put getinterval putinterval aload astore search anchorsearch token packedarray \
        bind version languagelevel product revision serialnumber realtime usertime vmstatus vmreclaim setvmthreshold \
        currentglobal setglobal gcheck currentpacking setpacking internaldict \
        save restore gsave grestore grestoreall initgraphics \
        setlinewidth currentlinewidth setlinecap currentlinecap setlinejoin currentlinejoin setmiterlimit currentmiterlimit \
        setdash currentdash setflat currentflat setstrokeadjust currentstrokeadjust setoverprint currentoverprint setsmoothness \
        setscreen currentscreen setcolorscreen settransfer currenttransfer setcolortransfer currentcolortransfer \
        setblackgeneration currentblackgeneration setundercolorremoval currentundercolorremoval sethalftone currenthalftone \
        setcolorrendering currentcolorrendering setgray currentgray setrgbcolor currentrgbcolor setcmykcolor currentcmykcolor \
        sethsbcolor currenthsbcolor setcolorspace currentcolorspace setcolor currentcolor setpattern makepattern \
        matrix identmatrix defaultmatrix currentmatrix setmatrix initmatrix concat concatmatrix translate scale rotate \
        transform itransform dtransform idtransform invertmatrix \
        newpath moveto rmoveto lineto rlineto curveto rcurveto closepath arc arcn arct arcto currentpoint pathbbox \
        flattenpath reversepath strokepath clippath initclip clip eoclip rectclip rectfill rectstroke fill eofill stroke \
        ufill ueofill ustroke shfill pathforall \
        image imagemask colorimage \
        findfont scalefont makefont setfont currentfont definefont undefinefont selectfont rootfont stringwidth \
        show ashow widthshow awidthshow xshow xyshow yshow kshow cshow glyphshow charpath setcachedevice setcachedevice2 \
        setcharwidth findencoding \
        findresource defineresource undefineresource resourcestatus resourceforall \
        currentfile readstring readhexstring readline read flushfile closefile filter eexec bytesavailable status file run \
        print = == stack pstack flush echo write writestring setfileposition fileposition \
        setpagedevice currentpagedevice showpage copypage erasepage nulldevice setcachelimit
        """.split(whereSeparator: \.isWhitespace).map(String.init)

        private func circular(_ n: Int, _ k: Int) -> Int { ((k % n) + n) % n }

        func operador(_ nome: String) throws {
            // Atalhos dos dialetos do Illustrator primeiro.
            if dialeto == .agm, try operadorAGM(nome) { return }
            if dialeto == .classico, try operadorAI(nome) { return }
            switch nome {
            // Pilha
            case "pop": _ = try tirar()
            case "exch":
                let b = try tirar(), a = try tirar()
                pilha += [b, a]
            case "dup":
                guard let v = pilha.last else { throw Falha.pilhaVazia }
                pilha.append(v)
            case "copy":
                if case .int = pilha.last {
                    let n = try inteiro()
                    guard n >= 0, n <= pilha.count else { throw Falha.intervalo }
                    pilha += pilha.suffix(n)
                } else {
                    let destino = try tirar(), origem = try tirar()
                    switch (origem, destino) {
                    case (.lista(let a, _), .lista(let b, let x)):
                        guard a.v.count <= b.v.count else { throw Falha.intervalo }
                        b.v.replaceSubrange(0..<a.v.count, with: a.v)
                        pilha.append(.lista(a.v.count == b.v.count ? b : Lista(Array(b.v.prefix(a.v.count))), executavel: x))
                    case (.texto(let a, _), .texto(let b, let x)):
                        guard a.b.count <= b.b.count else { throw Falha.intervalo }
                        b.b.replaceSubrange(0..<a.b.count, with: a.b)
                        pilha.append(.texto(a.b.count == b.b.count ? b : Cadeia(Array(b.b.prefix(a.b.count))), executavel: x))
                    case (.dicionario(let a), .dicionario(let b)):
                        b.d.merge(a.d) { _, novo in novo }
                        pilha.append(.dicionario(b))
                    default: throw Falha.tipo
                    }
                }
            case "index":
                let n = try inteiro()
                guard n >= 0, n < pilha.count else { throw Falha.intervalo }
                pilha.append(pilha[pilha.count - 1 - n])
            case "roll":
                let j = try inteiro(), n = try inteiro()
                guard n >= 0, n <= pilha.count else { throw Falha.intervalo }
                guard n > 0 else { break }
                let topo = Array(pilha.suffix(n))
                pilha.removeLast(n)
                let k = circular(n, j)
                pilha += Array(topo[(n - k)...] + topo[..<(n - k)])
            case "clear": pilha.removeAll()
            case "count": pilha.append(.int(pilha.count))
            case "mark", "[", "<<": pilha.append(.marca)
            case "cleartomark":
                guard let i = pilha.lastIndex(where: { if case .marca = $0 { true } else { false } }) else { throw Falha.pilhaVazia }
                pilha.removeSubrange(i...)
            case "counttomark":
                guard let i = pilha.lastIndex(where: { if case .marca = $0 { true } else { false } }) else { throw Falha.pilhaVazia }
                pilha.append(.int(pilha.count - 1 - i))
            case "]":
                guard let i = pilha.lastIndex(where: { if case .marca = $0 { true } else { false } }) else { throw Falha.pilhaVazia }
                let itens = Array(pilha[(i + 1)...])
                pilha.removeSubrange(i...)
                pilha.append(.lista(Lista(itens), executavel: false))
            case ">>":
                guard let i = pilha.lastIndex(where: { if case .marca = $0 { true } else { false } }) else { throw Falha.pilhaVazia }
                let itens = Array(pilha[(i + 1)...])
                pilha.removeSubrange(i...)
                let d = Dicionario()
                for k in stride(from: 0, to: itens.count - 1, by: 2) { d.d[itens[k].chave] = (itens[k], itens[k + 1]) }
                pilha.append(.dicionario(d))

            // Aritmética
            case "add", "sub", "mul":
                let b = try tirar(), a = try tirar()
                if case .int(let x) = a, case .int(let y) = b {
                    let (r, estourou) = nome == "add" ? x.addingReportingOverflow(y) : nome == "sub" ? x.subtractingReportingOverflow(y)
                        : x.multipliedReportingOverflow(by: y)
                    if !estourou { pilha.append(.int(r)); break }
                }
                guard let x = a.numero, let y = b.numero else { throw Falha.tipo }
                pilha.append(.real(nome == "add" ? x + y : nome == "sub" ? x - y : x * y))
            case "div":
                let b = try num(), a = try num()
                guard b != 0 else { throw Falha.intervalo }
                pilha.append(.real(a / b))
            case "idiv", "mod":
                let b = try inteiro(), a = try inteiro()
                guard b != 0 else { throw Falha.intervalo }
                pilha.append(.int(nome == "idiv" ? a / b : a % b))
            case "neg":
                guard let x = try tirar().numero else { throw Falha.tipo }
                pilha.append(x == x.rounded() && abs(x) < 1e15 ? .int(Int(-x)) : .real(-x))
            case "abs":
                guard let x = try tirar().numero else { throw Falha.tipo }
                pilha.append(x == x.rounded() && abs(x) < 1e15 ? .int(Int(abs(x))) : .real(abs(x)))
            case "ceiling", "floor", "round", "truncate":
                let a = try tirar()
                if case .int = a { pilha.append(a); break }
                guard let x = a.numero else { throw Falha.tipo }
                let r: Double = switch nome {
                case "ceiling": x.rounded(.up)
                case "floor": x.rounded(.down)
                case "round": (x + 0.5).rounded(.down)
                default: x.rounded(.towardZero)
                }
                pilha.append(.real(r))
            case "sqrt": pilha.append(.real(sqrt(max(try num(), 0))))
            case "atan":
                let den = try num(), numr = try num()
                var a = atan2(numr, den) * 180 / .pi
                if a < 0 { a += 360 }
                pilha.append(.real(a))
            case "cos": pilha.append(.real(cos(try num() * .pi / 180)))
            case "sin": pilha.append(.real(sin(try num() * .pi / 180)))
            case "exp":
                let e = try num(), b = try num()
                pilha.append(.real(pow(b, e)))
            case "ln": pilha.append(.real(log(max(try num(), 1e-300))))
            case "log": pilha.append(.real(log10(max(try num(), 1e-300))))
            case "rand": pilha.append(.int(Int.random(in: 0...Int(Int32.max))))
            case "srand": _ = try tirar()
            case "rrand": pilha.append(.int(0))
            case "cvi":
                let a = try tirar()
                if case .texto(let c, _) = a { pilha.append(.int(try Self.paraInteiro(Double(c.texto.trimmingCharacters(in: .whitespaces)) ?? 0))) }
                else if let x = a.numero { pilha.append(.int(try Self.paraInteiro(x.rounded(.towardZero)))) } else { throw Falha.tipo }
            case "cvr":
                let a = try tirar()
                if case .texto(let c, _) = a { pilha.append(.real(Double(c.texto.trimmingCharacters(in: .whitespaces)) ?? 0)) }
                else if let x = a.numero { pilha.append(.real(x)) } else { throw Falha.tipo }

            // Relações e lógica
            case "eq", "ne":
                let b = try tirar(), a = try tirar()
                pilha.append(.bool(igual(a, b) == (nome == "eq")))
            case "gt", "ge", "lt", "le":
                let b = try tirar(), a = try tirar()
                let r: Bool
                if let x = a.numero, let y = b.numero {
                    r = nome == "gt" ? x > y : nome == "ge" ? x >= y : nome == "lt" ? x < y : x <= y
                } else if case .texto(let x, _) = a, case .texto(let y, _) = b {
                    r = nome == "gt" ? x.b.lexicographicallyPrecedes(y.b) == false && x.b != y.b
                        : nome == "ge" ? !x.b.lexicographicallyPrecedes(y.b)
                        : nome == "lt" ? x.b.lexicographicallyPrecedes(y.b) : (x.b.lexicographicallyPrecedes(y.b) || x.b == y.b)
                } else { throw Falha.tipo }
                pilha.append(.bool(r))
            case "and", "or", "xor":
                let b = try tirar(), a = try tirar()
                if case .bool(let x) = a, case .bool(let y) = b {
                    pilha.append(.bool(nome == "and" ? x && y : nome == "or" ? x || y : x != y))
                } else if case .int(let x) = a, case .int(let y) = b {
                    pilha.append(.int(nome == "and" ? x & y : nome == "or" ? x | y : x ^ y))
                } else { throw Falha.tipo }
            case "not":
                let a = try tirar()
                if case .bool(let x) = a { pilha.append(.bool(!x)) } else if case .int(let x) = a { pilha.append(.int(~x)) } else { throw Falha.tipo }
            case "bitshift":
                let s = try inteiro(), x = try inteiro()
                pilha.append(.int(s >= 0 ? x << s : x >> -s))
            case "true": pilha.append(.bool(true))
            case "false": pilha.append(.bool(false))
            case "null": pilha.append(.null)

            // Controle
            case "exec": try executar(try tirar())
            case "if":
                let p = try procedimentoNaPilha(), c = try logico()
                if c { try executar(p) }
            case "ifelse":
                let nao = try procedimentoNaPilha(), sim = try procedimentoNaPilha(), c = try logico()
                try executar(c ? sim : nao)
            case "for":
                let p = try procedimentoNaPilha(), limite = try tirar(), passo = try tirar(), inicio = try tirar()
                guard let l = limite.numero, let s = passo.numero, var x = inicio.numero, s != 0 else { throw Falha.tipo }
                let inteiros: Bool = if case .int = inicio, case .int = passo { true } else { false }
                do {
                    while s > 0 ? x <= l : x >= l {
                        pilha.append(inteiros ? .int(try Self.paraInteiro(x)) : .real(x))
                        try executar(p)
                        x += s
                    }
                } catch Falha.sair {}
            case "repeat":
                let p = try procedimentoNaPilha(), n = try inteiro()
                do { for _ in 0..<max(n, 0) { try executar(p) } } catch Falha.sair {}
            case "loop":
                let p = try procedimentoNaPilha()
                do { while true { try executar(p) } } catch Falha.sair {}
            case "exit": throw Falha.sair
            case "forall":
                let p = try procedimentoNaPilha(), alvo = try tirar()
                do {
                    switch alvo {
                    case .lista(let l, _): for item in l.v { pilha.append(item); try executar(p) }
                    case .texto(let c, _): for b in c.b { pilha.append(.int(Int(b))); try executar(p) }
                    case .dicionario(let d): for (_, par) in d.d { pilha += [par.chave, par.valor]; try executar(p) }
                    default: throw Falha.tipo
                    }
                } catch Falha.sair {}
            case "stop": throw Falha.parar
            case "stopped":
                let p = try tirar()
                do {
                    try executar(p)
                    pilha.append(.bool(false))
                } catch Falha.limite {
                    throw Falha.limite
                } catch Falha.fim {
                    throw Falha.fim
                } catch {
                    pilha.append(.bool(true))
                }
            case "quit": throw Falha.fim
            case "countexecstack": pilha.append(.int(profundidade))
            case "execstack": _ = try tirar(); pilha.append(.lista(Lista([]), executavel: false))

            // Tipos
            case "type":
                let a = try tirar()
                let t: String = switch a {
                case .int: "integertype"
                case .real: "realtype"
                case .bool: "booleantype"
                case .null: "nulltype"
                case .marca: "marktype"
                case .nome: "nametype"
                case .texto: "stringtype"
                case .lista: "arraytype"
                case .dicionario: "dicttype"
                case .operador: "operatortype"
                case .arquivo: "filetype"
                case .salvo: "savetype"
                }
                pilha.append(.nome(t, executavel: true))
            case "cvn":
                let c = try cadeia()
                pilha.append(.nome(c.texto, executavel: false))
            case "cvs", "cvrs":
                let destino = try cadeia()
                if nome == "cvrs" { _ = try tirar() }
                let a = try tirar()
                let texto: String = switch a {
                case .int(let i): "\(i)"
                case .real(let r): r == r.rounded() && abs(r) < 1e15 ? "\(Int(r)).0" : "\(r)"
                case .bool(let b): b ? "true" : "false"
                case .nome(let n, _), .operador(let n): n
                case .texto(let c, _): c.texto
                default: "--nostringval--"
                }
                let bytes = Array(texto.utf8)
                let n = min(bytes.count, destino.b.count)
                destino.b.replaceSubrange(0..<n, with: bytes.prefix(n))
                pilha.append(.texto(Cadeia(Array(bytes.prefix(max(n, 0)))), executavel: false))
            case "cvlit":
                let a = try tirar()
                switch a {
                case .nome(let n, _): pilha.append(.nome(n, executavel: false))
                case .lista(let l, _): pilha.append(.lista(l, executavel: false))
                case .texto(let c, _): pilha.append(.texto(c, executavel: false))
                default: pilha.append(a)
                }
            case "cvx":
                let a = try tirar()
                switch a {
                case .nome(let n, _): pilha.append(.nome(n, executavel: true))
                case .lista(let l, _): pilha.append(.lista(l, executavel: true))
                case .texto(let c, _): pilha.append(.texto(c, executavel: true))
                default: pilha.append(a)
                }
            case "xcheck":
                let a = try tirar()
                let x: Bool = switch a {
                case .nome(_, let e), .lista(_, let e), .texto(_, let e): e
                case .operador: true
                default: false
                }
                pilha.append(.bool(x))
            case "rcheck", "wcheck": _ = try tirar(); pilha.append(.bool(true))
            case "readonly", "executeonly", "noaccess": break

            // Dicionários
            case "dict": _ = try tirar(); pilha.append(.dicionario(Dicionario()))
            case "begin": dicts.append(try dicionario())
            case "end": if dicts.count > 3 { dicts.removeLast() }
            case "def":
                let valor = try tirar(), chave = try tirar()
                dicts.last!.d[chave.chave] = (chave, valor)
            case "load":
                let chave = try tirar()
                guard let v = buscar(chave.chave) else { throw Falha.indefinido(chave.chave) }
                pilha.append(v)
            case "store":
                let valor = try tirar(), chave = try tirar()
                let alvo = dicts.last { $0.d[chave.chave] != nil } ?? dicts.last!
                alvo.d[chave.chave] = (chave, valor)
            case "known":
                let chave = try tirar(), d = try dicionario()
                pilha.append(.bool(d.d[chave.chave] != nil))
            case "where":
                let chave = try tirar()
                if let d = dicts.last(where: { $0.d[chave.chave] != nil }) { pilha += [.dicionario(d), .bool(true)] } else { pilha.append(.bool(false)) }
            case "undef":
                let chave = try tirar(), d = try dicionario()
                d.d[chave.chave] = nil
            case "currentdict": pilha.append(.dicionario(dicts.last!))
            case "countdictstack": pilha.append(.int(dicts.count))
            case "dictstack":
                _ = try tirar()
                pilha.append(.lista(Lista(dicts.map { .dicionario($0) }), executavel: false))
            case "cleardictstack": dicts = Array(dicts.prefix(3))
            case "maxlength": _ = try tirar(); pilha.append(.int(1000))

            // Listas e textos
            case "array", "packedarray":
                if nome == "packedarray" {
                    let n = try inteiro()
                    guard n >= 0, n <= pilha.count else { throw Falha.intervalo }
                    let itens = Array(pilha.suffix(n))
                    pilha.removeLast(n)
                    pilha.append(.lista(Lista(itens), executavel: false))
                } else {
                    let n = try inteiro()
                    guard n >= 0, n < 10_000_000 else { throw Falha.intervalo }
                    pilha.append(.lista(Lista(Array(repeating: .null, count: n)), executavel: false))
                }
            case "string":
                let n = try inteiro()
                guard n >= 0, n < 16_000_000 else { throw Falha.intervalo }
                pilha.append(.texto(Cadeia([UInt8](repeating: 0, count: n)), executavel: false))
            case "length":
                let a = try tirar()
                switch a {
                case .lista(let l, _): pilha.append(.int(l.v.count))
                case .texto(let c, _): pilha.append(.int(c.b.count))
                case .dicionario(let d): pilha.append(.int(d.d.count))
                case .nome(let n, _): pilha.append(.int(n.utf8.count))
                default: throw Falha.tipo
                }
            case "get":
                let chave = try tirar(), alvo = try tirar()
                switch alvo {
                case .lista(let l, _):
                    guard let i = chave.numero.flatMap({ try? Self.paraInteiro($0) }), i >= 0, i < l.v.count else { throw Falha.intervalo }
                    pilha.append(l.v[i])
                case .texto(let c, _):
                    guard let i = chave.numero.flatMap({ try? Self.paraInteiro($0) }), i >= 0, i < c.b.count else { throw Falha.intervalo }
                    pilha.append(.int(Int(c.b[i])))
                case .dicionario(let d):
                    guard let v = d.d[chave.chave]?.valor else { throw Falha.indefinido(chave.chave) }
                    pilha.append(v)
                default: throw Falha.tipo
                }
            case "put":
                let valor = try tirar(), chave = try tirar(), alvo = try tirar()
                switch alvo {
                case .lista(let l, _):
                    guard let i = chave.numero.flatMap({ try? Self.paraInteiro($0) }), i >= 0, i < l.v.count else { throw Falha.intervalo }
                    l.v[i] = valor
                case .texto(let c, _):
                    guard let i = chave.numero.flatMap({ try? Self.paraInteiro($0) }), i >= 0, i < c.b.count, let x = valor.numero else { throw Falha.intervalo }
                    c.b[i] = UInt8(try Self.paraInteiro(x) & 255)
                case .dicionario(let d): d.d[chave.chave] = (chave, valor)
                default: throw Falha.tipo
                }
            case "getinterval":
                let n = try inteiro(), i = try inteiro(), alvo = try tirar()
                switch alvo {
                case .lista(let l, let x):
                    guard i >= 0, n >= 0, i + n <= l.v.count else { throw Falha.intervalo }
                    pilha.append(.lista(Lista(Array(l.v[i..<(i + n)])), executavel: x))
                case .texto(let c, let x):
                    guard i >= 0, n >= 0, i + n <= c.b.count else { throw Falha.intervalo }
                    pilha.append(.texto(Cadeia(Array(c.b[i..<(i + n)])), executavel: x))
                default: throw Falha.tipo
                }
            case "putinterval":
                let origem = try tirar(), i = try inteiro(), destino = try tirar()
                switch (destino, origem) {
                case (.lista(let d, _), .lista(let o, _)):
                    guard i >= 0, i + o.v.count <= d.v.count else { throw Falha.intervalo }
                    d.v.replaceSubrange(i..<(i + o.v.count), with: o.v)
                case (.texto(let d, _), .texto(let o, _)):
                    guard i >= 0, i + o.b.count <= d.b.count else { throw Falha.intervalo }
                    d.b.replaceSubrange(i..<(i + o.b.count), with: o.b)
                default: throw Falha.tipo
                }
            case "aload":
                let l = try lista()
                pilha += l.v
                pilha.append(.lista(l, executavel: false))
            case "astore":
                let l = try lista()
                guard pilha.count >= l.v.count else { throw Falha.pilhaVazia }
                l.v = Array(pilha.suffix(l.v.count))
                pilha.removeLast(l.v.count)
                pilha.append(.lista(l, executavel: false))
            case "search", "anchorsearch":
                let procura = try cadeia(), alvo = try cadeia()
                let p = procura.b, t = alvo.b
                var achou: Int?
                if nome == "anchorsearch" {
                    if t.starts(with: p) { achou = 0 }
                } else if p.count <= t.count {
                    achou = (0...(t.count - p.count)).first { Array(t[$0..<($0 + p.count)]) == p }
                }
                if let k = achou {
                    pilha.append(.texto(Cadeia(Array(t[(k + p.count)...])), executavel: false))
                    pilha.append(.texto(Cadeia(p), executavel: false))
                    if nome == "search" { pilha.append(.texto(Cadeia(Array(t[..<k])), executavel: false)) }
                    pilha.append(.bool(true))
                } else {
                    pilha += [.texto(alvo, executavel: false), .bool(false)]
                }
            case "token":
                let a = try tirar()
                guard case .texto(let c, _) = a else { pilha.append(.bool(false)); break }
                let sub = Fonte(c.b, inicio: 0, fim: c.b.count)
                guard let t = sub.token() else { pilha.append(.bool(false)); break }
                var valor: Valor = .null
                switch t {
                case .valor(let v):
                    if case .lista(_, true) = v { valor = .lista(procedimento(de: sub), executavel: true) } else { valor = v }
                case .imediato(let n): valor = buscar(n) ?? .null
                case .fechaProcedimento: break
                }
                pilha += [.texto(Cadeia(Array(c.b[sub.i...])), executavel: false), valor, .bool(true)]

            // Sistema
            case "bind":
                guard case .lista(let l, _) = pilha.last else { break }
                ligar(l, nivel: 0)
            case "version": pilha.append(.texto(Cadeia(Array("3011".utf8)), executavel: false))
            case "languagelevel": pilha.append(.int(3))
            case "product": pilha.append(.texto(Cadeia(Array("Cutline".utf8)), executavel: false))
            case "revision", "serialnumber", "realtime", "usertime": pilha.append(.int(0))
            case "vmstatus": pilha += [.int(0), .int(0), .int(100_000_000)]
            case "vmreclaim", "setvmthreshold", "setglobal", "setpacking": _ = try tirar()
            case "currentglobal", "currentpacking": pilha.append(.bool(false))
            case "gcheck": _ = try tirar(); pilha.append(.bool(false))
            case "internaldict": _ = try tirar(); pilha.append(.dicionario(Dicionario()))

            // Estado gráfico
            case "gsave": pilhaGrafica.append(g.copia())
            case "grestore": if let anterior = pilhaGrafica.popLast() { g = anterior }
            case "grestoreall": if let primeiro = pilhaGrafica.first { g = primeiro; pilhaGrafica.removeAll() }
            case "save":
                pilhaGrafica.append(g.copia())
                pilha.append(.salvo(pilhaGrafica.count))
            case "restore":
                guard case .salvo(let nivel) = try tirar() else { throw Falha.tipo }
                if nivel >= 1, nivel <= pilhaGrafica.count {
                    g = pilhaGrafica[nivel - 1]
                    pilhaGrafica.removeSubrange((nivel - 1)...)
                }
            case "initgraphics": g = Grafico()
            case "setlinewidth": g.espessura = abs(try num())
            case "currentlinewidth": pilha.append(.real(g.espessura))
            case "setlinecap", "setlinejoin", "setmiterlimit", "setflat", "setstrokeadjust", "setoverprint", "setsmoothness",
                 "settransfer", "setblackgeneration", "setundercolorremoval", "sethalftone", "setcolorrendering":
                _ = try tirar()
            case "currentlinecap", "currentlinejoin": pilha.append(.int(0))
            case "currentmiterlimit": pilha.append(.real(10))
            case "currentflat": pilha.append(.real(1))
            case "currentstrokeadjust", "currentoverprint": pilha.append(.bool(false))
            case "setdash": _ = try tirar(); _ = try tirar()
            case "currentdash": pilha += [.lista(Lista([]), executavel: false), .int(0)]
            case "setscreen": _ = try numerosOuQualquer(3)
            case "setcolorscreen": _ = try numerosOuQualquer(12)
            case "setcolortransfer": _ = try numerosOuQualquer(4)
            case "currentscreen": pilha += [.real(60), .real(45), .lista(Lista([]), executavel: true)]
            case "currenttransfer", "currentblackgeneration", "currentundercolorremoval": pilha.append(.lista(Lista([]), executavel: true))
            case "currentcolortransfer": for _ in 0..<4 { pilha.append(.lista(Lista([]), executavel: true)) }
            case "currenthalftone", "currentcolorrendering": pilha.append(.dicionario(Dicionario()))
            case "setgray":
                g.espaco = .cinza
                g.cor = ImportarVetor.cor([try num()])
            case "currentgray": pilha.append(.real(1 - (g.cor?.k ?? 0) / 100))
            case "setrgbcolor":
                g.espaco = .rgb
                g.cor = ImportarVetor.cor(try numeros(3))
            case "currentrgbcolor": pilha += [.real(0), .real(0), .real(0)]
            case "setcmykcolor":
                g.espaco = .cmyk
                g.cor = ImportarVetor.cor(try numeros(4))
            case "currentcmykcolor":
                let c = g.cor ?? CMYK(c: 0, m: 0, y: 0, k: 0)
                pilha += [.real(c.c / 100), .real(c.m / 100), .real(c.y / 100), .real(c.k / 100)]
            case "sethsbcolor":
                let v = try numeros(3)
                let (h, s, b) = (v[0] * 6, v[1], v[2])
                let i = Int(h.rounded(.down)) % 6, f = h - h.rounded(.down)
                let p = b * (1 - s), q = b * (1 - s * f), t = b * (1 - s * (1 - f))
                let rgb: [Double] = [[b, t, p], [q, b, p], [p, b, t], [p, q, b], [t, p, b], [b, p, q]][max(i, 0)]
                g.espaco = .rgb
                g.cor = ImportarVetor.cor(rgb)
            case "currenthsbcolor": pilha += [.real(0), .real(0), .real(0)]
            case "setcolorspace": definirEspaco(espaco(de: try tirar()))
            case "currentcolorspace": pilha.append(.lista(Lista([.nome("DeviceGray", executavel: false)]), executavel: false))
            case "setcolor":
                if case .padrao = g.espaco {
                    _ = try tirar()
                    g.cor = CMYK(c: 0, m: 0, y: 0, k: 50)
                } else {
                    g.cor = resolver(g.espaco, try numeros(g.espaco.componentes))
                }
            case "currentcolor": pilha.append(.real(0))
            case "setpattern":
                _ = try tirar()
                g.espaco = .padrao
                g.cor = CMYK(c: 0, m: 0, y: 0, k: 50)
            case "makepattern":
                _ = try tirar()
                let d = try tirar()
                pilha.append(d)

            // Matrizes
            case "matrix": pilha.append(.lista(Lista(Self.lista(.identity)), executavel: false))
            case "identmatrix", "defaultmatrix":
                let l = try lista()
                l.v = Self.lista(.identity)
                pilha.append(.lista(l, executavel: false))
            case "currentmatrix":
                let l = try lista()
                l.v = Self.lista(g.ctm)
                pilha.append(.lista(l, executavel: false))
            case "setmatrix": g.ctm = try Self.matriz(try lista())
            case "initmatrix": g.ctm = .identity
            case "concat": g.ctm = try Self.matriz(try lista()).concatenating(g.ctm)
            case "concatmatrix":
                let destino = try lista(), b = try Self.matriz(try lista()), a = try Self.matriz(try lista())
                destino.v = Self.lista(a.concatenating(b))
                pilha.append(.lista(destino, executavel: false))
            case "invertmatrix":
                let destino = try lista(), a = try Self.matriz(try lista())
                destino.v = Self.lista(a.inverted())
                pilha.append(.lista(destino, executavel: false))
            case "translate", "scale", "rotate":
                let m = matrizNoTopo()
                let t: CGAffineTransform
                if nome == "rotate" {
                    t = CGAffineTransform(rotationAngle: try num() * .pi / 180)
                } else {
                    let y = try num(), x = try num()
                    t = nome == "translate" ? CGAffineTransform(translationX: x, y: y) : CGAffineTransform(scaleX: x, y: y)
                }
                if let m {
                    m.v = Self.lista(t)
                    pilha.append(.lista(m, executavel: false))
                } else {
                    g.ctm = t.concatenating(g.ctm)
                }
            case "transform", "itransform", "dtransform", "idtransform":
                let m = try matrizNoTopo().map(Self.matriz) ?? g.ctm
                let y = try num(), x = try num()
                let t = nome.hasPrefix("i") ? m.inverted() : m
                let p = nome.contains("d")
                    ? CGPoint(x: x * t.a + y * t.c, y: x * t.b + y * t.d)
                    : CGPoint(x: x, y: y).applying(t)
                pilha += [.real(p.x), .real(p.y)]

            // Caminho
            case "newpath": novoCaminho()
            case "moveto":
                let v = try numeros(2)
                g.caminho.move(to: ponto(v[0], v[1]))
            case "rmoveto":
                let v = try numeros(2), p = try pontoAtualUsuario()
                g.caminho.move(to: ponto(p.x + v[0], p.y + v[1]))
            case "lineto":
                let v = try numeros(2)
                guard !g.caminho.isEmpty else { throw Falha.intervalo }
                g.caminho.addLine(to: ponto(v[0], v[1]))
            case "rlineto":
                let v = try numeros(2), p = try pontoAtualUsuario()
                g.caminho.addLine(to: ponto(p.x + v[0], p.y + v[1]))
            case "curveto":
                let v = try numeros(6)
                guard !g.caminho.isEmpty else { throw Falha.intervalo }
                g.caminho.addCurve(to: ponto(v[4], v[5]), control1: ponto(v[0], v[1]), control2: ponto(v[2], v[3]))
            case "rcurveto":
                let v = try numeros(6), p = try pontoAtualUsuario()
                g.caminho.addCurve(to: ponto(p.x + v[4], p.y + v[5]), control1: ponto(p.x + v[0], p.y + v[1]),
                                   control2: ponto(p.x + v[2], p.y + v[3]))
            case "closepath": if !g.caminho.isEmpty { g.caminho.closeSubpath() }
            case "arc", "arcn":
                let v = try numeros(5)
                guard v[2] > 0 else { break }
                g.caminho.addArc(center: CGPoint(x: v[0], y: v[1]), radius: v[2], startAngle: v[3] * .pi / 180,
                                 endAngle: v[4] * .pi / 180, clockwise: nome == "arcn", transform: g.ctm)
            case "arct", "arcto":
                let v = try numeros(5)
                if g.caminho.isEmpty { throw Falha.intervalo }
                g.caminho.addArc(tangent1End: CGPoint(x: v[0], y: v[1]), tangent2End: CGPoint(x: v[2], y: v[3]), radius: v[4], transform: g.ctm)
                if nome == "arcto" { pilha += [.real(v[0]), .real(v[1]), .real(v[0]), .real(v[1])] }
            case "currentpoint":
                let p = try pontoAtualUsuario()
                pilha += [.real(p.x), .real(p.y)]
            case "pathbbox":
                let caixa = g.caminho.isEmpty ? CGRect.zero : g.caminho.boundingBoxOfPath.applying(g.ctm.inverted())
                pilha += [.real(caixa.minX), .real(caixa.minY), .real(caixa.maxX), .real(caixa.maxY)]
            case "flattenpath", "reversepath", "strokepath": break
            case "clippath":
                g.caminho = (g.recorte?.mutableCopy()) ?? CGMutablePath()
            case "initclip": g.recorte = nil
            case "clip", "eoclip": g.recorte = g.caminho.copy()
            case "rectclip":
                if let r = try retangulos().first { g.recorte = CGPath(rect: r, transform: [g.ctm]) }
                novoCaminho()
            case "rectfill", "rectstroke":
                if nome == "rectstroke" { _ = matrizNoTopo() }
                let p = CGMutablePath()
                for r in try retangulos() { p.addRect(r, transform: g.ctm) }
                emitir(p, traco: nome == "rectstroke" ? g.cor : nil, preenchimento: nome == "rectfill" ? g.cor : nil)
            case "fill", "eofill":
                emitir(g.caminho, traco: nil, preenchimento: g.cor)
                novoCaminho()
            case "stroke":
                emitir(g.caminho, traco: g.cor, preenchimento: nil)
                novoCaminho()
            case "ufill", "ueofill", "ustroke": _ = try tirar()
            case "shfill":
                let d = try dicionario()
                if let recorte = g.recorte { emitir(recorte, traco: nil, preenchimento: corDoDegrade(d)) }
            case "pathforall": for _ in 0..<4 { _ = try tirar() }

            // Imagens
            case "image": try imagem(mascara: false)
            case "imagemask": try imagem(mascara: true)
            case "colorimage": try imagem(mascara: false, colorida: true)

            // Fontes e texto
            case "findfont":
                let n = try tirar()
                let d = Dicionario()
                d["FontName"] = n
                d["FontType"] = .int(1)
                d["FontMatrix"] = .lista(Lista([.real(0.001), .real(0), .real(0), .real(0.001), .real(0), .real(0)]), executavel: false)
                pilha.append(.dicionario(d))
            case "scalefont":
                let s = try num()
                g.corpoFonte = s
            case "makefont": _ = try tirar()
            case "setfont", "undefinefont": _ = try tirar()
            case "currentfont", "rootfont": pilha.append(.dicionario(Dicionario()))
            case "definefont":
                let f = try tirar()
                _ = try tirar()
                pilha.append(f)
            case "selectfont":
                g.corpoFonte = (try? num()) ?? 12
                _ = try tirar()
            case "stringwidth":
                let c = try cadeia()
                pilha += [.real(Double(c.b.count) * g.corpoFonte * 0.5), .real(0)]
            case "show", "charpath", "glyphshow":
                if nome == "charpath" { _ = try tirar() }
                _ = try tirar()
                textos += 1
            case "ashow": _ = try tirar(); _ = try numeros(2); textos += 1
            case "widthshow": _ = try tirar(); _ = try numeros(3); textos += 1
            case "awidthshow": _ = try tirar(); _ = try numeros(5); textos += 1
            case "xshow", "yshow", "xyshow", "kshow", "cshow": _ = try tirar(); _ = try tirar(); textos += 1
            case "setcachedevice": _ = try numeros(6)
            case "setcachedevice2": _ = try numeros(10)
            case "setcharwidth": _ = try numeros(2)
            case "findencoding":
                _ = try tirar()
                pilha.append(buscar("StandardEncoding") ?? .null)
            case "setcachelimit": _ = try tirar()

            // Recursos
            case "findresource":
                let categoria = try tirar(), chave = try tirar()
                if let v = recursos[categoria.chave + "/" + chave.chave] { pilha.append(v); break }
                if categoria.chave == "Font" { pilha.append(chave); try operador("findfont"); break }
                pilha.append(.dicionario(Dicionario()))
            case "defineresource":
                let categoria = try tirar(), instancia = try tirar(), chave = try tirar()
                recursos[categoria.chave + "/" + chave.chave] = instancia
                pilha.append(instancia)
            case "undefineresource": _ = try tirar(); _ = try tirar()
            case "resourcestatus": _ = try tirar(); _ = try tirar(); pilha.append(.bool(false))
            case "resourceforall": for _ in 0..<4 { _ = try tirar() }

            // Arquivos (o próprio programa)
            case "currentfile": pilha.append(.arquivo(arquivoAtual))
            case "readstring", "readhexstring":
                let c = try cadeia()
                guard case .arquivo(let a) = try tirar() else { throw Falha.tipo }
                var lidos: [UInt8] = []
                lidos.reserveCapacity(c.b.count)
                while lidos.count < c.b.count {
                    if nome == "readhexstring" {
                        var alto: UInt8?, par: UInt8?
                        while let x = a.lerByte() {
                            guard let v = Fonte.hex(x) else { if x == 62 { break } else { continue } }
                            if let h = alto { par = h << 4 | v; break }
                            alto = v
                        }
                        guard let par else { break }
                        lidos.append(par)
                    } else {
                        guard let x = a.lerByte() else { break }
                        lidos.append(x)
                    }
                }
                c.b.replaceSubrange(0..<lidos.count, with: lidos)
                pilha += [.texto(Cadeia(lidos), executavel: false), .bool(lidos.count == c.b.count)]
            case "readline":
                let c = try cadeia()
                guard case .arquivo(let a) = try tirar() else { throw Falha.tipo }
                if case .fonte = a.tipo, let linha = a.fonte.lerLinha() {
                    pilha += [.texto(Cadeia(linha), executavel: false), .bool(true)]
                } else {
                    var linha: [UInt8] = [], achou = false
                    while let x = a.lerByte() {
                        achou = true
                        if x == 10 || x == 13 { break }
                        linha.append(x)
                    }
                    pilha += [.texto(Cadeia(linha), executavel: false), .bool(achou)]
                }
            case "read":
                guard case .arquivo(let a) = try tirar() else { throw Falha.tipo }
                if let x = a.lerByte() { pilha += [.int(Int(x)), .bool(true)] } else { pilha.append(.bool(false)) }
            case "flushfile", "closefile":
                guard case .arquivo(let a) = try tirar() else { break }
                if case .fonte = a.tipo { if nome == "flushfile" { break } } else { a.pular(bytes: 0) }
            case "filter":
                guard case .nome(let tipo, _) = try tirar() else { throw Falha.tipo }
                if case .dicionario = pilha.last { pilha.removeLast() }
                var contagem = 0, marca: [UInt8] = []
                if tipo == "SubFileDecode" {
                    marca = try cadeia().b
                    contagem = try inteiro()
                }
                let origem = try tirar()
                let base: Arquivo? = if case .arquivo(let a) = origem { a } else { nil }
                let t: Arquivo.Tipo = switch tipo {
                case "ASCII85Decode": .ascii85
                case "ASCIIHexDecode": .asciiHex
                case "SubFileDecode": .subArquivo(contagem: contagem, fim: marca)
                default: .outro
                }
                pilha.append(.arquivo(Arquivo(fonte: fonte, tipo: t, base: base ?? arquivoAtual)))
            case "eexec":
                _ = try tirar()
                fonte.pularEexec()
            case "bytesavailable": _ = try tirar(); pilha.append(.int(-1))
            case "status": _ = try tirar(); pilha.append(.bool(true))
            case "file": _ = try tirar(); _ = try tirar(); throw Falha.tipo
            case "run", "print", "=", "==", "echo", "setfileposition": _ = try tirar()
            case "write", "writestring": _ = try tirar(); _ = try tirar()
            case "fileposition": _ = try tirar(); pilha.append(.int(0))
            case "stack", "pstack", "flush": break

            // Página
            case "setpagedevice": _ = try tirar()
            case "currentpagedevice":
                let d = Dicionario()
                d["PageSize"] = .lista(Lista([.real(612), .real(792)]), executavel: false)
                pilha.append(.dicionario(d))
            case "showpage", "copypage", "erasepage", "nulldevice": break

            default:
                desconhecidos[nome, default: 0] += 1
                throw Falha.indefinido(nome)
            }
        }

        /// Tira `n` valores (de qualquer tipo).
        private func numerosOuQualquer(_ n: Int) throws -> [Valor] {
            guard pilha.count >= n else { throw Falha.pilhaVazia }
            let v = Array(pilha.suffix(n))
            pilha.removeLast(n)
            return v
        }

        /// Operandos de rectfill/rectstroke/rectclip: x y l a ou uma lista de números.
        private func retangulos() throws -> [CGRect] {
            if case .lista(let l, _) = pilha.last {
                pilha.removeLast()
                let v = l.v.compactMap(\.numero)
                return stride(from: 0, to: v.count - 3, by: 4).map { CGRect(x: v[$0], y: v[$0 + 1], width: v[$0 + 2], height: v[$0 + 3]) }
            }
            let v = try numeros(4)
            return [CGRect(x: v[0], y: v[1], width: v[2], height: v[3])]
        }

        /// bind: os nomes que já são operadores viram o próprio operador (também nos procedimentos de dentro).
        private func ligar(_ l: Lista, nivel: Int) {
            guard nivel < 50 else { return }
            for (i, item) in l.v.enumerated() {
                switch item {
                case .nome(let n, true): if case .operador = buscar(n) { l.v[i] = buscar(n)! }
                case .lista(let interna, true): ligar(interna, nivel: nivel + 1)
                default: break
                }
            }
        }

        // MARK: Dialeto AGM (Illustrator 9 em diante)

        private func operadorAGM(_ nome: String) throws -> Bool {
            switch nome {
            case "mo": try operador("moveto")
            case "li": try operador("lineto")
            case "cv": try operador("curveto")
            case "cp": try operador("closepath")
            case "np": novoCaminho()
            case "f", "ef":
                emitir(g.caminho, traco: nil, preenchimento: g.cor)
                novoCaminho()
            case "@":
                emitir(g.caminho, traco: g.cor, preenchimento: nil)
                novoCaminho()
            case "clp", "eclp", "nclp":
                g.recorte = g.caminho.copy()
                novoCaminho()
            case "ct": try operador("concat")
            case "pgsv": try operador("gsave")
            case "pgrs": try operador("grestore")
            case "sop", "sadj", "lc", "lj", "ml": _ = try tirar()
            case "lw": try operador("setlinewidth")
            case "dsh": try operador("setdash")
            case "gry": try operador("setgray")
            case "rgb": try operador("setrgbcolor")
            case "cmyk", "nzopmsc": try operador("setcmykcolor")
            case "sepcs", "devncs", "idxcs", "csacrd":
                // O AGM passa um dicionário (Name, CSA, TintTransform ou Components) em vez da lista do PostScript.
                let v = try tirar()
                guard case .dicionario(let d) = v else { definirEspaco(espaco(de: v)); break }
                let alternativo = espacoCSA(d["CSA"]) ?? .cmyk
                if nome == "csacrd" { definirEspaco(alternativo); break }
                let transformacao = d["TintTransform"] ?? d["TintProc"]
                let temProc = if case .lista(_, true) = transformacao { true } else { false }
                if nome == "devncs" {
                    var n = 1
                    if case .lista(let nomes, _) = d["Names"] { n = max(nomes.v.count, 1) }
                    definirEspaco(temProc ? .deviceN(n: n, alternativo: alternativo, transformacao: transformacao!) : alternativo)
                } else if nome == "sepcs" {
                    let cheia: [Double] = if case .lista(let l, _) = d["Components"] { l.v.compactMap(\.numero) } else { [] }
                    let nomeCor = d["Name"]?.chave ?? ""
                    definirEspaco(temProc ? .separacao(nome: nomeCor, alternativo: alternativo, transformacao: transformacao!)
                                  : .tinta(nome: nomeCor, cheia: cheia, alternativo: alternativo))
                } else {
                    definirEspaco(alternativo)
                }
            case "sep", "devn", "idx", "colr": try operador("setcolor")
            case "level3": pilha.append(.bool(true))
            case "add_res":
                let categoria = try tirar(), valor = try tirar(), chave = try tirar()
                recursos[categoria.chave + "/" + chave.chave] = valor
            case "get_res":
                let categoria = try tirar(), chave = try tirar()
                pilha.append(recursos[categoria.chave + "/" + chave.chave] ?? .null)
            case "del_res": _ = try tirar()
            case "clonedict":
                let d = try dicionario(), copia = Dicionario()
                copia.d = d.d
                pilha.append(.dicionario(copia))
            case "gx":
                let chave = try tirar(), d = try tirar()
                if case .dicionario(let dic) = d, let v = dic[chave.chave] { try executar(v) }
            case "cf": try operador("currentfile")
            case "fl": try operador("filter")
            case "rs": try operador("readstring")
            default: return false
            }
            return true
        }

        /// Espaço de cor de um recurso CSA do AGM (o nome do recurso ou a própria lista).
        private func espacoCSA(_ v: Valor?) -> EspacoCor? {
            guard let v else { return nil }
            if case .nome(let n, _) = v, let recurso = recursos["CSA/" + n] { return espaco(de: recurso) }
            if case .lista = v { return espaco(de: v) }
            if case .nome = v { return espaco(de: v) }
            return nil
        }

        // MARK: Dialeto AI clássico (até o Illustrator 8)

        private func operadorAI(_ nome: String) throws -> Bool {
            switch nome {
            case "m": try operador("moveto")
            case "l", "L": try operador("lineto")
            case "c", "C": try operador("curveto")
            case "v", "V":
                let v = try numeros(4)
                guard !g.caminho.isEmpty else { throw Falha.intervalo }
                g.caminho.addCurve(to: ponto(v[2], v[3]), control1: g.caminho.currentPoint, control2: ponto(v[0], v[1]))
            case "y", "Y":
                let v = try numeros(4)
                guard !g.caminho.isEmpty else { throw Falha.intervalo }
                let fim = ponto(v[2], v[3])
                g.caminho.addCurve(to: fim, control1: ponto(v[0], v[1]), control2: fim)
            case "N": pintarAI(fechar: false, preencher: false, tracar: false)
            case "n", "h", "H": pintarAI(fechar: true, preencher: false, tracar: false)
            case "F": pintarAI(fechar: false, preencher: true, tracar: false)
            case "f": pintarAI(fechar: true, preencher: true, tracar: false)
            case "S": pintarAI(fechar: false, preencher: false, tracar: true)
            case "s": pintarAI(fechar: true, preencher: false, tracar: true)
            case "B": pintarAI(fechar: false, preencher: true, tracar: true)
            case "b": pintarAI(fechar: true, preencher: true, tracar: true)
            case "*u": composto = (CGMutablePath(), false, false)
            case "*U":
                if let c = composto {
                    composto = nil
                    emitir(c.caminho, traco: c.tracar ? g.traco : nil, preenchimento: c.preencher ? g.preenchimento : nil)
                }
            case "u", "U", "q", "Q", "W", "LB": break
            case "D", "A", "O", "R", "XR", "J", "j", "M", "Ar", "i", "Ln": _ = try tirar()
            case "w": try operador("setlinewidth")
            case "d": _ = try tirar(); _ = try tirar()
            case "g": g.preenchimento = ImportarVetor.cor([try num()])
            case "G": g.traco = ImportarVetor.cor([try num()])
            case "k": g.preenchimento = ImportarVetor.cor(try numeros(4))
            case "K": g.traco = ImportarVetor.cor(try numeros(4))
            case "x", "X":
                // c m y k (nome) tinta: a tinta 0 é a cor cheia.
                let tinta = try num()
                _ = try tirar()
                let v = try numeros(4)
                let cor = ImportarVetor.cor(v.map { $0 * (1 - tinta) })
                if nome == "x" { g.preenchimento = cor } else { g.traco = cor }
            case "Xa", "XA":
                let cor = ImportarVetor.cor(try numeros(3))
                if nome == "Xa" { g.preenchimento = cor } else { g.traco = cor }
            case "Xx", "XX", "Xk", "XK":
                // c m y k (nome) tinta 0, ou r g b (nome) tinta 1.
                let tipo = try inteiro(), tinta = try num()
                _ = try tirar()
                let v = try numeros(tipo == 1 ? 3 : 4)
                let cor = tipo == 1 ? ImportarVetor.cor(v.map { 1 - (1 - $0) * (1 - tinta) }) : ImportarVetor.cor(v.map { $0 * (1 - tinta) })
                if nome == "Xx" || nome == "Xk" { g.preenchimento = cor } else { g.traco = cor }
            case "p", "P":
                // Preenchimento ou traço de padrão: um cinza médio.
                pilha.removeAll()
                if nome == "p" { g.preenchimento = CMYK(c: 0, m: 0, y: 0, k: 50) } else { g.traco = CMYK(c: 0, m: 0, y: 0, k: 50) }
            case "To":
                textos += 1
                pilha.removeAll()
            case "XI", "XG":
                imagens += 1
                pilha.removeAll()
            default: return false
            }
            return true
        }
    }
}
