// Contornos das formas (em mm) e a conversão entre mm da página e pontos da tela.
import CoreText
import SwiftUI

extension Objeto {
    /// Contorno em mm, coordenadas da página.
    var caminho: Path {
        let r = quadro.standardized
        switch forma {
        case .retangulo(let raio):
            // Cantos de arco circular (como o Illustrator), não o canto "contínuo" do iOS.
            return Path(roundedRect: r, cornerRadius: min(max(raio, 0), min(r.width, r.height) / 2), style: .circular)
        case .elipse:
            return Path(ellipseIn: r)
        case .estrela(let pontas, let interno):
            return Self.estrela(em: r, pontas: pontas, raioInterno: interno)
        case .caminho(let subcaminhos):
            return Self.caminho(subcaminhos, em: r)
        case .texto(let texto):
            // Sem letras (só enquanto se digita um texto novo): nada a desenhar nem cortar.
            guard let contorno = texto.contorno else { return Path() }
            let natural = contorno.boundingBoxOfPath
            let ajuste = CGAffineTransform(translationX: -natural.minX, y: -natural.minY)
                .concatenating(CGAffineTransform(scaleX: r.width / max(natural.width, 0.001), y: r.height / max(natural.height, 0.001)))
                .concatenating(CGAffineTransform(translationX: r.minX, y: r.minY))
            return Path(contorno.copy(using: [ajuste]) ?? contorno)
        }
    }

    /// Subcaminhos com coordenadas em mm da página (qualquer forma; as paramétricas viram caminho).
    var nosAbsolutos: [Subcaminho] {
        if case .caminho(let subs) = forma {
            let t = quadroParaPagina
            return subs.map { s in
                Subcaminho(nos: s.nos.map { No(ponto: $0.ponto.applying(t), entrada: $0.entrada?.applying(t), saida: $0.saida?.applying(t)) },
                           fechado: s.fechado)
            }
        }
        guard let livre = Objeto.caminhoLivre(caminho.cgPath) else { return [] }
        return Objeto(forma: .caminho(livre.subcaminhos), quadro: livre.quadro).nosAbsolutos
    }

    /// Troca a forma por um caminho livre com estes nós (em mm da página); o quadro acompanha.
    mutating func definirNos(_ absolutos: [Subcaminho]) {
        let path = Self.caminho(absolutos, em: CGRect(x: 0, y: 0, width: 1, height: 1)).cgPath
        guard let livre = Objeto.caminhoLivre(path) else { return }
        forma = .caminho(livre.subcaminhos)
        quadro = livre.quadro
    }

    /// Pontos de encaixe (snap): nós dos caminhos; nas outras formas, cantos, meios e centro do quadro.
    var ancoras: [CGPoint] {
        if case .caminho = forma { return nosAbsolutos.flatMap { $0.nos.map(\.ponto) } }
        let r = quadro.standardized
        return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.midX, y: r.midY), CGPoint(x: r.maxX, y: r.midY),
                CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
    }

    /// Unidade do quadro (0…1) → mm da página.
    var quadroParaPagina: CGAffineTransform {
        let r = quadro.standardized
        return CGAffineTransform(a: r.width, b: 0, c: 0, d: r.height, tx: r.minX, ty: r.minY)
    }

    static func caminho(_ subcaminhos: [Subcaminho], em r: CGRect) -> Path {
        let mm = { (p: CGPoint) in CGPoint(x: r.minX + p.x * r.width, y: r.minY + p.y * r.height) }
        var path = Path()
        for sub in subcaminhos where !sub.nos.isEmpty {
            path.move(to: mm(sub.nos[0].ponto))
            let n = sub.nos.count
            for i in 0..<(sub.fechado ? n : n - 1) {
                let a = sub.nos[i], b = sub.nos[(i + 1) % n]
                if a.saida == nil, b.entrada == nil {
                    path.addLine(to: mm(b.ponto))
                } else {
                    path.addCurve(to: mm(b.ponto), control1: mm(a.saida ?? a.ponto), control2: mm(b.entrada ?? b.ponto))
                }
            }
            if sub.fechado { path.closeSubpath() }
        }
        return path
    }

    /// Estrela com a primeira ponta para cima, esticada para preencher exatamente o quadro.
    static func estrela(em r: CGRect, pontas: Int, raioInterno: Double) -> Path {
        let n = max(3, pontas)
        let unitarios = (0..<(2 * n)).map { i -> CGPoint in
            let raio = i % 2 == 0 ? 1 : min(max(raioInterno, 0.05), 1)
            let a = -Double.pi / 2 + Double(i) * Double.pi / Double(n)
            return CGPoint(x: raio * cos(a), y: raio * sin(a))
        }
        let minX = unitarios.map(\.x).min()!, maxX = unitarios.map(\.x).max()!
        let minY = unitarios.map(\.y).min()!, maxY = unitarios.map(\.y).max()!
        var path = Path()
        for (i, p) in unitarios.enumerated() {
            let q = CGPoint(x: r.minX + (p.x - minX) / (maxX - minX) * r.width,
                            y: r.minY + (p.y - minY) / (maxY - minY) * r.height)
            if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
        }
        path.closeSubpath()
        return path
    }
}

/// Posição e escala da página na tela.
struct Vista: Equatable {
    static let pontosPorMM = 72.0 / 25.4

    /// 1 = tamanho real (100%).
    var zoom = 1.0
    /// Onde fica o (0, 0) da página, em pontos da tela.
    var origem = CGPoint.zero
    /// Falso enquanto o usuário não mexe no zoom ou na posição: a página se reajusta à janela.
    var manual = false

    var escala: Double { zoom * Self.pontosPorMM }
    var transformacao: CGAffineTransform { CGAffineTransform(a: escala, b: 0, c: 0, d: escala, tx: origem.x, ty: origem.y) }

    func tela(_ p: CGPoint) -> CGPoint { CGPoint(x: origem.x + p.x * escala, y: origem.y + p.y * escala) }
    func tela(_ r: CGRect) -> CGRect { r.applying(transformacao) }
    func mm(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - origem.x) / escala, y: (p.y - origem.y) / escala) }

    static let zoomMinimo = 0.1, zoomMaximo = 16.0

    /// Muda o zoom mantendo fixo o ponto `ancora` da tela.
    mutating func ampliar(para novo: Double, ancora: CGPoint) {
        let z = min(max(novo, Self.zoomMinimo), Self.zoomMaximo)
        let fator = z / zoom
        manual = true
        origem = CGPoint(x: ancora.x - (ancora.x - origem.x) * fator, y: ancora.y - (ancora.y - origem.y) * fator)
        zoom = z
    }

    /// Página inteira (com a base) dentro da área livre.
    mutating func ajustar(em area: CGRect) {
        let m = Documento.margemBase
        let base = CGSize(width: Documento.pagina.width + 2 * m, height: Documento.pagina.height + 2 * m)
        let escalaAjuste = min(area.width / base.width, area.height / base.height)
        zoom = min(max(escalaAjuste / Self.pontosPorMM, Self.zoomMinimo), Self.zoomMaximo)
        let tamanho = CGSize(width: Documento.pagina.width * escala, height: Documento.pagina.height * escala)
        origem = CGPoint(x: area.midX - tamanho.width / 2, y: area.midY - tamanho.height / 2)
        manual = false
    }

    mutating func deslocar(dx: Double, dy: Double) {
        origem.x += dx
        origem.y += dy
        manual = true
    }
}

extension CGRect {
    /// Retângulo entre dois pontos; com `proporcional`, quadrado; com `doCentro`, `a` é o centro.
    static func entre(_ a: CGPoint, _ b: CGPoint, proporcional: Bool, doCentro: Bool) -> CGRect {
        var dx = b.x - a.x, dy = b.y - a.y
        if proporcional {
            let lado = max(abs(dx), abs(dy))
            dx = dx < 0 ? -lado : lado
            dy = dy < 0 ? -lado : lado
        }
        if doCentro { return CGRect(x: a.x - abs(dx), y: a.y - abs(dy), width: 2 * abs(dx), height: 2 * abs(dy)) }
        return CGRect(x: a.x, y: a.y, width: dx, height: dy).standardized
    }
}

extension EstiloCaractere {
    /// Sobrescrito e subscrito: corpo reduzido (58,3 %) e a distância da linha de base (33,3 % do corpo).
    static let fatorPosicao = 0.583, alturaPosicao = 0.333

    /// Corpo em que as letras são desenhadas.
    var corpoEfetivo: Double { posicao == .normal ? tamanho : tamanho * Self.fatorPosicao }

    /// Quanto a linha de base do trecho sobe (pt): deslocamento + sobrescrito/subscrito.
    var subida: Double {
        switch posicao {
        case .normal: deslocamento
        case .sobrescrito: deslocamento + tamanho * Self.alturaPosicao
        case .subscrito: deslocamento - tamanho * Self.alturaPosicao
        }
    }

    /// Fonte no corpo pedido: a face escolhida (PostScript) ou a normal da família. Fonte que não está
    /// instalada cai na do sistema (o CoreText escolhe outra).
    func fonteCT(corpo: Double? = nil) -> CTFont {
        let corpo = corpo ?? tamanho
        if let postscript {
            let fonte = CTFontCreateWithName(postscript as CFString, corpo, nil)
            if CTFontCopyPostScriptName(fonte) as String == postscript { return fonte }
        }
        let descritor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: fonte] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descritor, corpo, nil)
    }

    /// Entrelinha automática: 115 % da altura da fonte (a de sempre do Cutline).
    var entrelinhaAutomatica: Double { Self.entrelinhaAutomatica(fonteCT()) }

    static func entrelinhaAutomatica(_ f: CTFont) -> Double {
        (CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f)) * 1.15
    }
}

/// Atributos próprios das corridas do CoreText (passam para os CTRun junto com a fonte).
private extension NSAttributedString.Key {
    static let subida = NSAttributedString.Key("cutline.subida")
    static let rotacao = NSAttributedString.Key("cutline.rotacao")
    static let sublinhado = NSAttributedString.Key("cutline.sublinhado")
    static let tachado = NSAttributedString.Key("cutline.tachado")
    static let entrelinha = NSAttributedString.Key("cutline.entrelinha")
}

extension Texto {
    /// pt do corpo → mm.
    static let mmPorPt = 25.4 / 72

    /// Comprimento em UTF-16.
    var comprimento: Int { (conteudo as NSString).length }

    /// Trechos cobrindo o texto todo (um só, com `estilo`, quando ele é uniforme).
    var trechosCompletos: [Trecho] {
        trechos.isEmpty ? (comprimento > 0 ? [Trecho(comprimento: comprimento, estilo: estilo)] : []) : trechos
    }

    /// Estilo da letra na posição (UTF-16); texto vazio = `estilo`.
    func estilo(em indice: Int) -> EstiloCaractere {
        var fim = 0
        for t in trechos {
            fim += t.comprimento
            if indice < fim { return t.estilo }
        }
        return trechos.last?.estilo ?? estilo
    }

    /// Maior corpo do texto (folgas da edição na tela).
    var maiorCorpo: Double { trechosCompletos.map(\.estilo.tamanho).max() ?? estilo.tamanho }

    /// Linhas como o CoreText as compõe, em pt do corpo, y para baixo: o topo da 1ª linha em y = 0 e x = 0 no
    /// ponto do texto (começo das linhas à esquerda, meio no centro, fim à direita). Serve ao contorno das
    /// letras e ao cursor, à seleção e aos cliques da edição na tela — as duas coisas sempre batem.
    struct Diagramacao {
        struct Linha {
            let ct: CTLine
            /// Posição na string inteira, em UTF-16 (como o NSRange do campo de texto).
            let inicio: Int
            let comprimento: Int
            /// Onde começa o texto da linha.
            let x: Double
            let base: Double
            /// Altura acima e abaixo da linha de base (a maior letra da linha, com o deslocamento).
            let ascendente: Double
            let descendente: Double
            /// Largura sem os espaços do fim (alinhamento, sublinhado) e com eles (área de clique).
            let largura: Double
            let larguraTotal: Double
            /// Marcador ou número do parágrafo (fora da string: não se seleciona).
            let marcador: CTLine?
            let xMarcador: Double
            var fim: Int { inicio + comprimento }
            var topo: Double { base - ascendente }
            var pe: Double { base + descendente }
        }

        /// Fonte e subida de cada trecho (UTF-16), para a altura do cursor.
        struct Corpo {
            let inicio: Int
            let fim: Int
            let fonte: CTFont
            let subida: Double
        }

        let linhas: [Linha]
        let corpos: [Corpo]

        var minX: Double { linhas.map { $0.marcador == nil ? $0.x : min($0.x, $0.xMarcador) }.min() ?? 0 }
        var maxX: Double { linhas.map { $0.x + $0.larguraTotal }.max() ?? 0 }
        var altura: Double { linhas.last?.pe ?? 0 }

        /// Linha onde fica a posição (UTF-16) e o x dela.
        func posicao(_ indice: Int) -> (linha: Int, x: Double) {
            let i = linhas.firstIndex { indice <= $0.fim } ?? linhas.count - 1
            let local = min(max(indice - linhas[i].inicio, 0), linhas[i].comprimento)
            return (i, linhas[i].x + CTLineGetOffsetForStringIndex(linhas[i].ct, local, nil))
        }

        /// Cursor na posição: x, topo e pé, na altura da letra antes dele (ou da linha, se vazia).
        func cursor(_ indice: Int) -> (x: Double, topo: Double, pe: Double) {
            let (i, x) = posicao(indice)
            let linha = linhas[i]
            let referencia = indice > linha.inicio ? indice - 1 : indice
            guard linha.comprimento > 0, let corpo = corpos.first(where: { referencia >= $0.inicio && referencia < $0.fim }) else {
                return (x, linha.topo, linha.pe)
            }
            return (x, linha.base - CTFontGetAscent(corpo.fonte) - corpo.subida, linha.base + CTFontGetDescent(corpo.fonte) - corpo.subida)
        }

        /// Posição (UTF-16) mais perto de um ponto (pt do corpo).
        func indice(em p: CGPoint) -> Int {
            var i = linhas.count - 1
            for k in 0..<(linhas.count - 1) where p.y < (linhas[k].pe + linhas[k + 1].topo) / 2 {
                i = k
                break
            }
            let linha = linhas[i]
            let local = CTLineGetStringIndexForPosition(linha.ct, CGPoint(x: p.x - linha.x, y: 0))
            return linha.inicio + min(max(local == kCFNotFound ? 0 : local, 0), linha.comprimento)
        }

        /// Posição na linha de cima (−1) ou de baixo (+1), no mesmo x (setas ↑ ↓).
        func vizinha(_ de: Int, _ sentido: Int) -> Int {
            let (i, x) = posicao(de)
            let alvo = i + sentido
            guard linhas.indices.contains(alvo) else { return sentido < 0 ? 0 : linhas.last?.fim ?? 0 }
            return indice(em: CGPoint(x: x, y: linhas[alvo].base))
        }
    }

    @MainActor private static var diagramacoes: [Texto: Diagramacao] = [:]
    @MainActor private static var contornos: [Texto: CGPath] = [:]
    @MainActor private static var versaletesDaFonte: [String: Bool] = [:]

    /// Fontes ativadas ou desativadas (Adobe Fonts, Catálogo de Fontes): refaz as letras com as de agora.
    @MainActor static func esquecerFontes() {
        diagramacoes = [:]
        contornos = [:]
        versaletesDaFonte = [:]
    }

    /// A fonte com o versalete de verdade (recurso "smcp" do OpenType).
    private static func comVersalete(_ fonte: CTFont) -> CTFont {
        let recurso = [kCTFontOpenTypeFeatureTag as String: "smcp", kCTFontOpenTypeFeatureValue as String: 1] as [String: Any]
        let descritor = CTFontDescriptorCreateWithAttributes([kCTFontFeatureSettingsAttribute as String: [recurso]] as CFDictionary)
        return CTFontCreateCopyWithAttributes(fonte, 0, nil, descritor)
    }

    /// A fonte tem versalete próprio? (Senão ele é feito com maiúsculas a 70 %, como no Illustrator.)
    private static func temVersalete(_ fonte: CTFont) -> Bool {
        let nome = CTFontCopyPostScriptName(fonte) as String
        if let sabido = versaletesDaFonte[nome] { return sabido }
        func glifos(_ f: CTFont) -> [CGGlyph] {
            let linha = CTLineCreateWithAttributedString(NSAttributedString(string: "abc", attributes: [.font: f]))
            return (CTLineGetGlyphRuns(linha) as? [CTRun] ?? []).flatMap { corrida in
                var g = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(corrida))
                CTRunGetGlyphs(corrida, CFRange(location: 0, length: g.count), &g)
                return g
            }
        }
        let tem = glifos(fonte) != glifos(comVersalete(fonte))
        versaletesDaFonte[nome] = tem
        return tem
    }

    /// Atributos do CoreText de um trecho (fonte no corpo efetivo, kerning, tracking) e os próprios do Cutline.
    private static func atributos(_ e: EstiloCaractere) -> [NSAttributedString.Key: Any] {
        let corpo = e.corpoEfetivo
        var a: [NSAttributedString.Key: Any] = [.font: e.fonteCT(corpo: corpo), .subida: e.subida, .rotacao: e.rotacao,
                                                .sublinhado: e.sublinhado, .tachado: e.tachado]
        // Kerning fixo desliga o da fonte (0 = sem kerning); o tracking soma ao kerning da fonte.
        if let kerning = e.kerning { a[NSAttributedString.Key(kCTKernAttributeName as String)] = kerning / 1000 * corpo }
        if e.tracking != 0 { a[NSAttributedString.Key(kCTTrackingAttributeName as String)] = e.tracking / 1000 * corpo }
        if let entrelinha = e.entrelinha { a[.entrelinha] = entrelinha }
        return a
    }

    /// Um trecho como é desenhado: caixa alta e versalete trocam letras sem mudar o comprimento (os índices
    /// do cursor continuam valendo).
    private static func exibir(_ pedaco: String, _ e: EstiloCaractere) -> NSAttributedString {
        let atributos = atributos(e)
        guard e.caixaAlta || e.versalete else { return NSAttributedString(string: pedaco, attributes: atributos) }
        let fonte = atributos[.font] as! CTFont
        if !e.caixaAlta, temVersalete(fonte) {
            var comFonte = atributos
            comFonte[.font] = comVersalete(fonte)
            return NSAttributedString(string: pedaco, attributes: comFonte)
        }
        var pequena = atributos
        pequena[.font] = CTFontCreateCopyWithAttributes(fonte, e.corpoEfetivo * 0.7, nil, nil)
        let resultado = NSMutableAttributedString()
        for letra in pedaco {
            let original = String(letra), maiuscula = original.uppercased()
            let troca = maiuscula != original && maiuscula.utf16.count == original.utf16.count
            resultado.append(NSAttributedString(string: troca ? maiuscula : original,
                                                attributes: troca && !e.caixaAlta ? pequena : atributos))
        }
        return resultado
    }

    var diagramacao: Diagramacao {
        if let pronta = Self.diagramacoes[self] { return pronta }
        let texto = conteudo as NSString
        // Trechos com início e fim (UTF-16) e as fontes para a altura do cursor.
        var faixas: [(inicio: Int, fim: Int, estilo: EstiloCaractere)] = [], soma = 0
        for t in trechosCompletos {
            faixas.append((soma, soma + t.comprimento, t.estilo))
            soma += t.comprimento
        }
        let corpos = faixas.map { Diagramacao.Corpo(inicio: $0.inicio, fim: $0.fim, fonte: $0.estilo.fonteCT(corpo: $0.estilo.corpoEfetivo),
                                                    subida: $0.estilo.subida) }

        struct Bruta {
            let ct: CTLine, inicio: Int, comprimento: Int, largura: Double, total: Double, marcador: CTLine?
            let ascendente: Double, descendente: Double, passo: Double
        }
        var brutas: [Bruta] = [], inicio = 0, numero = 0
        for linha in texto.components(separatedBy: "\n") {
            let comprimento = (linha as NSString).length
            let fim = inicio + comprimento
            let exibida = NSMutableAttributedString()
            for f in faixas where f.fim > inicio && f.inicio < fim {
                let a = max(f.inicio, inicio), b = min(f.fim, fim)
                exibida.append(Self.exibir(texto.substring(with: NSRange(location: a, length: b - a)), f.estilo))
            }
            let ct = CTLineCreateWithAttributedString(exibida)
            let total = CTLineGetTypographicBounds(ct, nil, nil, nil)
            // Alturas e entrelinha da linha: as da maior letra (como no Illustrator); vazia, as do estilo ali.
            var ascendente = 0.0, descendente = 0.0, passo = 0.0
            let corridas = CTLineGetGlyphRuns(ct) as? [CTRun] ?? []
            for corrida in corridas {
                let atributos = CTRunGetAttributes(corrida) as NSDictionary
                let fonte = atributos[kCTFontAttributeName as String].map { $0 as! CTFont } ?? estilo.fonteCT()
                let subida = atributos[NSAttributedString.Key.subida.rawValue] as? Double ?? 0
                ascendente = max(ascendente, CTFontGetAscent(fonte) + subida)
                descendente = max(descendente, CTFontGetDescent(fonte) - subida)
                passo = max(passo, atributos[NSAttributedString.Key.entrelinha.rawValue] as? Double
                            ?? EstiloCaractere.entrelinhaAutomatica(fonte))
            }
            let aqui = estilo(em: comprimento > 0 ? inicio : max(inicio - 1, 0))
            if corridas.isEmpty {
                let fonte = aqui.fonteCT(corpo: aqui.corpoEfetivo)
                ascendente = CTFontGetAscent(fonte) + aqui.subida
                descendente = CTFontGetDescent(fonte) - aqui.subida
                passo = aqui.entrelinha ?? EstiloCaractere.entrelinhaAutomatica(fonte)
            }
            var marcador: CTLine?
            if self.marcador != .nenhum, !linha.allSatisfy(\.isWhitespace) {
                numero += 1
                let sinal = self.marcador == .bolinha ? "•" : "\(numero)."
                marcador = CTLineCreateWithAttributedString(NSAttributedString(string: sinal, attributes: [.font: aqui.fonteCT()]))
            }
            brutas.append(Bruta(ct: ct, inicio: inicio, comprimento: comprimento, largura: total - CTLineGetTrailingWhitespaceWidth(ct),
                                total: total, marcador: marcador, ascendente: ascendente, descendente: descendente, passo: passo))
            inicio = fim + 1
        }
        // Coluna dos marcadores: a do maior (1. a 10. alinhados) e meio em de folga até o texto.
        let larguraMarcador = brutas.compactMap { $0.marcador.map { CTLineGetTypographicBounds($0, nil, nil, nil) } }.max()
        let coluna = larguraMarcador.map { $0 + estilo(em: 0).tamanho * 0.5 } ?? 0
        var linhas: [Diagramacao.Linha] = [], base = 0.0
        for (i, b) in brutas.enumerated() {
            base = i == 0 ? b.ascendente : base + b.passo + espacoAntes + espacoDepois
            let ocupada = coluna + b.largura
            let comeco: Double = switch alinhamento {
            case .esquerda: recuoEsquerda + recuoPrimeira
            case .centro: (recuoEsquerda + recuoPrimeira - recuoDireita) / 2 - ocupada / 2
            case .direita: -recuoDireita - ocupada
            }
            linhas.append(.init(ct: b.ct, inicio: b.inicio, comprimento: b.comprimento, x: comeco + coluna, base: base,
                                ascendente: b.ascendente, descendente: b.descendente, largura: b.largura, larguraTotal: b.total,
                                marcador: b.marcador, xMarcador: comeco))
        }
        let pronta = Diagramacao(linhas: linhas, corpos: corpos)
        // Digitar na tela passa por muitos textos intermediários: o cache não cresce sem limite.
        if Self.diagramacoes.count > 300 { Self.diagramacoes = [:] }
        Self.diagramacoes[self] = pronta
        return pronta
    }

    /// Contorno das letras em mm, y para baixo, no mesmo sistema da diagramação (nil sem letras).
    var contorno: CGPath? {
        if let pronto = Self.contornos[self] { return pronto }
        let d = diagramacao
        let mm = Self.mmPorPt
        let path = CGMutablePath()

        func letras(_ linha: CTLine, x: Double, base: Double, faixas limite: Double? = nil) {
            for corrida in CTLineGetGlyphRuns(linha) as? [CTRun] ?? [] {
                let n = CTRunGetGlyphCount(corrida)
                var glifos = [CGGlyph](repeating: 0, count: n), posicoes = [CGPoint](repeating: .zero, count: n)
                CTRunGetGlyphs(corrida, CFRange(location: 0, length: n), &glifos)
                CTRunGetPositions(corrida, CFRange(location: 0, length: n), &posicoes)
                let atributos = CTRunGetAttributes(corrida) as NSDictionary
                let fonte = atributos[kCTFontAttributeName as String].map { $0 as! CTFont } ?? estilo.fonteCT()
                let subida = atributos[NSAttributedString.Key.subida.rawValue] as? Double ?? 0
                let giro = (atributos[NSAttributedString.Key.rotacao.rawValue] as? Double ?? 0) * .pi / 180
                for (glifo, posicao) in zip(glifos, posicoes) {
                    // y da fonte para cima a partir da linha de base → mm com y para baixo.
                    var t = CGAffineTransform(a: mm, b: 0, c: 0, d: -mm, tx: (x + posicao.x) * mm, ty: (base - posicao.y - subida) * mm)
                    if giro != 0 {
                        var caixa = CGRect.zero
                        var g = glifo
                        CTFontGetBoundingRectsForGlyphs(fonte, .horizontal, &g, &caixa, 1)
                        t = CGAffineTransform(translationX: caixa.midX, y: caixa.midY).rotated(by: giro)
                            .translatedBy(x: -caixa.midX, y: -caixa.midY).concatenating(t)
                    }
                    if let letra = CTFontCreatePathForGlyph(fonte, glifo, &t) { path.addPath(letra) }
                }
                // Sublinhado e tachado do trecho, até o fim das letras da linha (sem os espaços do fim).
                guard let limite, n > 0 else { continue }
                let comeco = x + posicoes[0].x
                let final = min(comeco + CTRunGetTypographicBounds(corrida, CFRange(location: 0, length: 0), nil, nil, nil), x + limite)
                guard final > comeco else { continue }
                let espessura = CTFontGetUnderlineThickness(fonte) > 0 ? CTFontGetUnderlineThickness(fonte) : CTFontGetSize(fonte) / 20
                func faixa(_ centro: Double) {
                    path.addRect(CGRect(x: comeco * mm, y: (centro - espessura / 2) * mm, width: (final - comeco) * mm, height: espessura * mm))
                }
                if atributos[NSAttributedString.Key.sublinhado.rawValue] as? Bool == true {
                    faixa(base - subida - CTFontGetUnderlinePosition(fonte))
                }
                if atributos[NSAttributedString.Key.tachado.rawValue] as? Bool == true {
                    faixa(base - subida - CTFontGetXHeight(fonte) / 2)
                }
            }
        }

        for linha in d.linhas {
            letras(linha.ct, x: linha.x, base: linha.base, faixas: linha.largura)
            if let marcador = linha.marcador { letras(marcador, x: linha.xMarcador, base: linha.base) }
        }
        guard !path.isEmpty else { return nil }
        if Self.contornos.count > 300 { Self.contornos = [:] }
        Self.contornos[self] = path
        return path
    }

    /// Caixa natural das letras, em mm (para o quadro ao criar ou mudar o texto).
    var tamanhoNatural: CGSize { contorno?.boundingBoxOfPath.size ?? CGSize(width: 10, height: 5) }
}
