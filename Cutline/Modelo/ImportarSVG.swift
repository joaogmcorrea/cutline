// Importar SVG (e .svgz): os desenhos viram caminhos livres com a regra de pintura comum
// (Modelo/ImportarVetor.swift). O topo-esquerdo do SVG fica no topo-esquerdo da página.
// Lê svg, g, a, switch, use (também de symbol), path (a gramática toda; arcos viram cúbicas), rect (cantos
// arredondados), circle, ellipse, line, polyline e polygon, com transform; estilos dos atributos, do CSS do
// <style> (.classe, #id, tag, tag.classe, *) e do style=, herdados como no navegador. Degradê vira a média
// das cores das paradas. text e image não entram (contados); defs, clipPath, mask, pattern e marker não desenham.
// Unidades: mm, cm, in, pt, pc e px (1/96"; nos arquivos do Illustrator e nos sem tamanho, 1 px = 1 pt, como ele exporta).
import CoreGraphics
import Foundation

nonisolated enum ImportarSVG {
    static func ler(_ dados: Data) throws -> ImportacaoVetorial {
        let construtor = Construtor()
        let parser = XMLParser(data: dados)
        parser.delegate = construtor
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        let ok = parser.parse()
        // Um erro no meio (uma entidade estranha, o fim cortado) ainda deixa o que veio antes.
        guard let raiz = construtor.raiz, raiz.nome == "svg", ok || !raiz.filhos.isEmpty else { throw ImportarVetor.Erro.svg }
        // O Illustrator exporta 1 unidade = 1 pt; no "Exportar como" ele nem escreve o comentário nem o tamanho
        // (só o viewBox). Sem tamanho próprio, vale o costume dele; com tamanho em px, o do CSS (1/96").
        let texto = String(decoding: dados.prefix(4096), as: UTF8.self)
        let doIllustrator = texto.contains("Adobe Illustrator") || raiz["data-name"] != nil || (raiz["width"] == nil && raiz["height"] == nil)
        var leitor = Leitor(raiz: raiz, dpi: doIllustrator ? 72 : 96)
        leitor.desenhar()
        return leitor.resultado
    }

    // MARK: Árvore

    nonisolated final class No {
        let nome: String
        let atributos: [String: String]
        var filhos: [No] = []
        var texto = ""

        init(nome: String, atributos: [String: String]) {
            // "svg:path" → "path" (arquivos com o prefixo do espaço de nomes).
            self.nome = nome.split(separator: ":").last.map(String.init) ?? nome
            self.atributos = atributos
        }

        subscript(_ chave: String) -> String? { atributos[chave] }
        var classes: [String] { (atributos["class"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init) }
        var href: String? { atributos["href"] ?? atributos["xlink:href"] }
    }

    nonisolated final class Construtor: NSObject, XMLParserDelegate {
        var raiz: No?
        private var pilha: [No] = []

        func parser(_ parser: XMLParser, didStartElement nome: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            let no = No(nome: nome, atributos: attributes)
            if let pai = pilha.last { pai.filhos.append(no) } else if raiz == nil { raiz = no }
            pilha.append(no)
        }

        func parser(_ parser: XMLParser, didEndElement nome: String, namespaceURI: String?, qualifiedName: String?) {
            _ = pilha.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters texto: String) {
            if let no = pilha.last, no.nome == "style" { no.texto += texto }
        }

        func parser(_ parser: XMLParser, foundCDATA dados: Data) {
            if let no = pilha.last, no.nome == "style" { no.texto += String(decoding: dados, as: UTF8.self) }
        }
    }

    // MARK: Estilo

    nonisolated enum Pintura {
        case nenhuma, cor(CMYK), atual, url(String)
    }

    nonisolated struct Estilo {
        var fill = Pintura.cor(CMYK(c: 0, m: 0, y: 0, k: 100))
        var stroke = Pintura.nenhuma
        /// Em unidades do usuário.
        var espessura = 1.0
        var color = CMYK(c: 0, m: 0, y: 0, k: 100)
        var visivel = true
        var opacidadeFill = 1.0
        var opacidadeStroke = 1.0
    }

    /// Regra do CSS: só seletores simples (o último trecho de um seletor composto, sem pseudo-classes).
    nonisolated struct Regra {
        nonisolated struct Seletor {
            var tag: String?
            var id: String?
            var classes: [String] = []
        }

        var seletores: [Seletor]
        var declaracoes: [(String, String)]

        func vale(para no: No) -> Bool {
            let classes = no.classes
            return seletores.contains { s in
                (s.tag == nil || s.tag == no.nome) && (s.id == nil || s.id == no["id"]) && s.classes.allSatisfy(classes.contains)
            }
        }
    }

    static func regras(_ css: String) -> [Regra] {
        var texto = css
        while let a = texto.range(of: "/*") {
            let b = texto.range(of: "*/", range: a.upperBound..<texto.endIndex)?.upperBound ?? texto.endIndex
            texto.removeSubrange(a.lowerBound..<b)
        }
        var regras: [Regra] = []
        var i = texto.startIndex
        while i < texto.endIndex {
            guard let abre = texto[i...].firstIndex(of: "{") else { break }
            let seletor = texto[i..<abre].trimmingCharacters(in: .whitespacesAndNewlines)
            // Bloco equilibrado (as regras @media trazem blocos dentro).
            var profundidade = 0, fecha = abre
            for j in texto[abre...].indices {
                if texto[j] == "{" { profundidade += 1 } else if texto[j] == "}" { profundidade -= 1; if profundidade == 0 { fecha = j; break } }
            }
            // Sem a chave que fecha: o resto do texto é o corpo da última regra.
            let incompleto = fecha == abre
            let corpo = String(texto[texto.index(after: abre)..<(incompleto ? texto.endIndex : fecha)])
            i = incompleto ? texto.endIndex : texto.index(after: fecha)
            if seletor.hasPrefix("@") {
                if seletor.hasPrefix("@media") { regras += Self.regras(corpo) }
                continue
            }
            let seletores = seletor.split(separator: ",").compactMap { Self.seletor(String($0)) }
            guard !seletores.isEmpty else { continue }
            regras.append(Regra(seletores: seletores, declaracoes: declaracoes(corpo)))
        }
        return regras
    }

    private static func seletor(_ texto: String) -> Regra.Seletor? {
        guard let ultimo = texto.split(whereSeparator: { $0.isWhitespace || $0 == ">" || $0 == "+" || $0 == "~" }).last,
              !ultimo.contains(":"), !ultimo.contains("[") else { return nil }
        var s = Regra.Seletor()
        var atual = "", tipo: Character = "t"
        func fechar() {
            if !atual.isEmpty {
                switch tipo {
                case "#": s.id = atual
                case ".": s.classes.append(atual)
                default: if atual != "*" { s.tag = atual }
                }
            }
            atual = ""
        }
        for c in ultimo {
            if c == "." || c == "#" { fechar(); tipo = c } else { atual.append(c) }
        }
        fechar()
        return s
    }

    static func declaracoes(_ texto: String) -> [(String, String)] {
        texto.split(separator: ";").compactMap { item in
            guard let dois = item.firstIndex(of: ":") else { return nil }
            let nome = item[..<dois].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let valor = item[item.index(after: dois)...].replacingOccurrences(of: "!important", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return nome.isEmpty ? nil : (nome, valor)
        }
    }

    // MARK: Leitura

    nonisolated struct Leitor {
        let raiz: No
        /// Pontos por polegada do px (96 no padrão do CSS; 72 nos SVG do Illustrator).
        let dpi: Double
        var resultado = ImportacaoVetorial()
        private var regras: [Regra] = []
        private var porId: [String: No] = [:]
        private var profundidadeUse = 0

        static let propriedades: Set<String> = ["fill", "stroke", "stroke-width", "color", "display", "visibility", "opacity",
                                                "fill-opacity", "stroke-opacity"]

        init(raiz: No, dpi: Double) {
            self.raiz = raiz
            self.dpi = dpi
            func visitar(_ no: No) {
                if let id = no["id"], porId[id] == nil { porId[id] = no }
                if no.nome == "style" { regras += ImportarSVG.regras(no.texto) }
                no.filhos.forEach(visitar)
            }
            visitar(raiz)
        }

        mutating func desenhar() {
            // Unidade do usuário → mm: o tamanho do SVG (width/height) e o viewBox.
            let mmPorPx = 25.4 / dpi
            let caixa = Self.viewBox(raiz["viewBox"])
            let largura = comprimentoAbsoluto(raiz["width"]).map { $0 * mmPorPx } ?? caixa.map { $0.width * mmPorPx }
            let altura = comprimentoAbsoluto(raiz["height"]).map { $0 * mmPorPx } ?? caixa.map { $0.height * mmPorPx }
            var t = CGAffineTransform(scaleX: mmPorPx, y: mmPorPx)
            if let caixa, caixa.width > 0, caixa.height > 0 {
                let l = largura ?? caixa.width * mmPorPx, a = altura ?? caixa.height * mmPorPx
                t = Self.ajuste(caixa, em: CGSize(width: l, height: a), raiz["preserveAspectRatio"])
            }
            desenhar(raiz, ctm: t, estilo: Estilo(), raizSVG: true)
        }

        /// viewBox na área (x, y, largura, altura), com preserveAspectRatio (padrão: xMidYMid meet).
        static func ajuste(_ caixa: CGRect, em area: CGSize, _ proporcao: String?, origem: CGPoint = .zero) -> CGAffineTransform {
            let partes = (proporcao ?? "xMidYMid meet").split(separator: " ").map(String.init)
            let alinhar = partes.first ?? "xMidYMid"
            var sx = area.width / caixa.width, sy = area.height / caixa.height
            if alinhar != "none" {
                let s = partes.contains("slice") ? max(sx, sy) : min(sx, sy)
                sx = s
                sy = s
            }
            func fator(_ eixo: String) -> Double { alinhar.contains(eixo + "Min") ? 0 : alinhar.contains(eixo + "Max") ? 1 : 0.5 }
            let dx = alinhar == "none" ? 0 : (area.width - caixa.width * sx) * fator("x")
            let dy = alinhar == "none" ? 0 : (area.height - caixa.height * sy) * fator("Y")
            return CGAffineTransform(translationX: -caixa.minX, y: -caixa.minY)
                .concatenating(CGAffineTransform(scaleX: sx, y: sy))
                .concatenating(CGAffineTransform(translationX: origem.x + dx, y: origem.y + dy))
        }

        static func viewBox(_ texto: String?) -> CGRect? {
            guard let texto else { return nil }
            let v = ImportarSVG.numeros(texto)
            return v.count == 4 ? CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) : nil
        }

        /// Comprimento com unidade absoluta, em px (nil sem valor ou em %).
        func comprimentoAbsoluto(_ texto: String?) -> Double? {
            guard let texto, !texto.hasSuffix("%") else { return nil }
            return comprimento(texto)
        }

        /// Comprimento em unidades do usuário (px); % de `referencia`.
        func comprimento(_ texto: String?, referencia: Double = 0) -> Double? {
            guard var t = texto?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
            var fator = 1.0
            let unidades: [(String, Double)] = [("px", 1), ("pt", dpi / 72), ("pc", dpi / 6), ("mm", dpi / 25.4), ("cm", dpi / 2.54),
                                                ("in", dpi), ("em", 16), ("ex", 8), ("%", referencia / 100)]
            for (sufixo, f) in unidades where t.hasSuffix(sufixo) {
                t.removeLast(sufixo.count)
                fator = f
                break
            }
            return Double(t.trimmingCharacters(in: .whitespaces)).map { $0 * fator }
        }

        // MARK: Elementos

        private mutating func desenhar(_ no: No, ctm pai: CGAffineTransform, estilo herdado: Estilo, raizSVG: Bool = false) {
            let declarado = propriedades(de: no)
            if declarado["display"] == "none" { return }
            if let o = declarado["opacity"].flatMap(Double.init), o <= 0 { return }
            let estilo = aplicar(declarado, a: herdado)
            var ctm = ImportarSVG.transformacao(no["transform"]).concatenating(pai)
            switch no.nome {
            case "svg":
                if !raizSVG {
                    // SVG dentro de SVG: uma nova área com o próprio viewBox.
                    let x = comprimento(no["x"]) ?? 0, y = comprimento(no["y"]) ?? 0
                    if let caixa = Self.viewBox(no["viewBox"]), caixa.width > 0, caixa.height > 0 {
                        let area = CGSize(width: comprimento(no["width"]) ?? caixa.width, height: comprimento(no["height"]) ?? caixa.height)
                        ctm = Self.ajuste(caixa, em: area, no["preserveAspectRatio"], origem: CGPoint(x: x, y: y)).concatenating(ctm)
                    } else {
                        ctm = CGAffineTransform(translationX: x, y: y).concatenating(ctm)
                    }
                }
                for filho in no.filhos { desenhar(filho, ctm: ctm, estilo: estilo) }
            case "g", "a":
                for filho in no.filhos { desenhar(filho, ctm: ctm, estilo: estilo) }
            case "switch":
                // O primeiro filho que vale: o do Illustrator traz antes um foreignObject só dele.
                if let filho = no.filhos.first(where: { $0.nome != "foreignObject" && $0["requiredExtensions"] == nil }) {
                    desenhar(filho, ctm: ctm, estilo: estilo)
                }
            case "use":
                guard profundidadeUse < 20, let alvo = no.href.flatMap({ $0.hasPrefix("#") ? porId[String($0.dropFirst())] : nil })
                else { return }
                ctm = CGAffineTransform(translationX: comprimento(no["x"]) ?? 0, y: comprimento(no["y"]) ?? 0).concatenating(ctm)
                profundidadeUse += 1
                defer { profundidadeUse -= 1 }
                if alvo.nome == "symbol" {
                    if let caixa = Self.viewBox(alvo["viewBox"]), caixa.width > 0, caixa.height > 0 {
                        let area = CGSize(width: comprimento(no["width"]) ?? caixa.width, height: comprimento(no["height"]) ?? caixa.height)
                        ctm = Self.ajuste(caixa, em: area, alvo["preserveAspectRatio"]).concatenating(ctm)
                    }
                    let estiloSimbolo = aplicar(propriedades(de: alvo), a: estilo)
                    for filho in alvo.filhos { desenhar(filho, ctm: ctm, estilo: estiloSimbolo) }
                } else {
                    desenhar(alvo, ctm: ctm, estilo: estilo)
                }
            case "text":
                resultado.textos += 1
            case "image":
                resultado.imagens += 1
            case "path", "rect", "circle", "ellipse", "line", "polyline", "polygon":
                guard let forma = forma(no) else { return }
                pintar(forma, ctm: ctm, estilo: estilo, comPreenchimento: no.nome != "line")
            default:
                // defs, symbol, clipPath, mask, pattern, marker, style, metadata, foreignObject… não desenham.
                break
            }
        }

        /// Contorno do elemento, em unidades do usuário.
        private func forma(_ no: No) -> CGPath? {
            let p = CGMutablePath()
            func n(_ chave: String, _ referencia: Double = 0) -> Double { comprimento(no[chave], referencia: referencia) ?? 0 }
            switch no.nome {
            case "path":
                ImportarSVG.caminho(no["d"] ?? "", em: p)
            case "rect":
                let r = CGRect(x: n("x"), y: n("y"), width: n("width"), height: n("height"))
                guard r.width > 0, r.height > 0 else { return nil }
                var rx = comprimento(no["rx"]), ry = comprimento(no["ry"])
                if rx == nil { rx = ry }
                if ry == nil { ry = rx }
                let cx = min(max(rx ?? 0, 0), r.width / 2), cy = min(max(ry ?? 0, 0), r.height / 2)
                if cx > 0, cy > 0 { p.addRoundedRect(in: r, cornerWidth: cx, cornerHeight: cy) } else { p.addRect(r) }
            case "circle":
                let r = n("r")
                guard r > 0 else { return nil }
                p.addEllipse(in: CGRect(x: n("cx") - r, y: n("cy") - r, width: 2 * r, height: 2 * r))
            case "ellipse":
                var rx = comprimento(no["rx"]), ry = comprimento(no["ry"])
                if rx == nil { rx = ry }
                if ry == nil { ry = rx }
                guard let rx, let ry, rx > 0, ry > 0 else { return nil }
                p.addEllipse(in: CGRect(x: n("cx") - rx, y: n("cy") - ry, width: 2 * rx, height: 2 * ry))
            case "line":
                p.move(to: CGPoint(x: n("x1"), y: n("y1")))
                p.addLine(to: CGPoint(x: n("x2"), y: n("y2")))
            default:   // polyline, polygon
                let v = ImportarSVG.numeros(no["points"] ?? "")
                guard v.count >= 4 else { return nil }
                p.move(to: CGPoint(x: v[0], y: v[1]))
                for i in stride(from: 2, to: v.count - 1, by: 2) { p.addLine(to: CGPoint(x: v[i], y: v[i + 1])) }
                if no.nome == "polygon" { p.closeSubpath() }
            }
            return p.isEmpty ? nil : p
        }

        private mutating func pintar(_ forma: CGPath, ctm: CGAffineTransform, estilo: Estilo, comPreenchimento: Bool) {
            guard estilo.visivel, let mm = forma.copy(using: [ctm]) else { return }
            let preenchimento = comPreenchimento && estilo.opacidadeFill > 0 ? cor(estilo.fill, estilo) : nil
            let traco = estilo.espessura > 0 && estilo.opacidadeStroke > 0 ? cor(estilo.stroke, estilo) : nil
            // Espessura em pt na escala da página.
            let escala = sqrt(abs(ctm.a * ctm.d - ctm.b * ctm.c))
            if let objeto = ImportarVetor.objeto(mm, traco: traco, espessura: estilo.espessura * escala * 72 / 25.4,
                                                 preenchimento: preenchimento) {
                resultado.objetos.append(objeto)
            }
        }

        private func cor(_ pintura: Pintura, _ estilo: Estilo) -> CMYK? {
            switch pintura {
            case .nenhuma: nil
            case .cor(let c): c
            case .atual: estilo.color
            case .url(let id): corDoDegrade(id)
            }
        }

        /// Média das cores das paradas do degradê (seguindo o href); padrão, cinza médio.
        private func corDoDegrade(_ id: String) -> CMYK? {
            var no = porId[id], voltas = 0
            while let atual = no, atual.filhos.allSatisfy({ $0.nome != "stop" }), let href = atual.href, voltas < 10 {
                no = porId[String(href.drop(while: { $0 == "#" }))]
                voltas += 1
            }
            guard let no else { return nil }
            guard no.nome == "linearGradient" || no.nome == "radialGradient" else { return CMYK(c: 0, m: 0, y: 0, k: 50) }
            let cores = no.filhos.filter { $0.nome == "stop" }.compactMap { parada -> (Double, Double, Double)? in
                let props = propriedades(de: parada, extras: ["stop-color"])
                guard let texto = props["stop-color"], let rgb = ImportarSVG.rgb(texto) else { return (0, 0, 0) }
                return rgb
            }
            guard !cores.isEmpty else { return nil }
            let n = Double(cores.count)
            return CMYK(vermelho: cores.map(\.0).reduce(0, +) / n, verde: cores.map(\.1).reduce(0, +) / n,
                        azul: cores.map(\.2).reduce(0, +) / n)
        }

        /// Propriedades declaradas no elemento: atributos < CSS < style=.
        private func propriedades(de no: No, extras: Set<String> = []) -> [String: String] {
            let nomes = Self.propriedades.union(extras)
            var p: [String: String] = [:]
            for (chave, valor) in no.atributos where nomes.contains(chave) { p[chave] = valor.trimmingCharacters(in: .whitespaces) }
            for regra in regras where regra.vale(para: no) {
                for (chave, valor) in regra.declaracoes where nomes.contains(chave) { p[chave] = valor }
            }
            if let style = no["style"] {
                for (chave, valor) in ImportarSVG.declaracoes(style) where nomes.contains(chave) { p[chave] = valor }
            }
            return p
        }

        private func aplicar(_ p: [String: String], a herdado: Estilo) -> Estilo {
            var e = herdado
            func pintura(_ texto: String) -> Pintura? {
                let t = texto.trimmingCharacters(in: .whitespaces)
                if t == "none" || t == "transparent" { return Pintura.nenhuma }
                if t.lowercased() == "currentcolor" { return .atual }
                if t.hasPrefix("url(") {
                    let dentro = t.dropFirst(4).prefix { $0 != ")" }.trimmingCharacters(in: CharacterSet(charactersIn: " '\"#"))
                    return .url(dentro)
                }
                guard let rgb = ImportarSVG.rgb(t) else { return nil }
                if ImportarSVG.transparente(t) { return Pintura.nenhuma }
                return .cor(CMYK(vermelho: rgb.0, verde: rgb.1, azul: rgb.2))
            }
            if let v = p["color"], let rgb = ImportarSVG.rgb(v) { e.color = CMYK(vermelho: rgb.0, verde: rgb.1, azul: rgb.2) }
            if let v = p["fill"], v != "inherit", let nova = pintura(v) { e.fill = nova }
            if let v = p["stroke"], v != "inherit", let nova = pintura(v) { e.stroke = nova }
            if let v = p["stroke-width"], v != "inherit", let w = comprimento(v) { e.espessura = max(w, 0) }
            if let v = p["visibility"] { e.visivel = v == "inherit" ? herdado.visivel : v == "visible" }
            if let v = p["fill-opacity"].flatMap(Double.init) { e.opacidadeFill = v }
            if let v = p["stroke-opacity"].flatMap(Double.init) { e.opacidadeStroke = v }
            return e
        }
    }

    // MARK: Valores

    /// Números de uma lista (espaços ou vírgulas; "1.5.5" são dois números, "-1-2" também).
    static func numeros(_ texto: String) -> [Double] {
        var leitor = LeitorNumeros(Array(texto.utf8))
        var v: [Double] = []
        while let n = leitor.numero() { v.append(n) }
        return v
    }

    nonisolated struct LeitorNumeros {
        let b: [UInt8]
        var i = 0

        init(_ b: [UInt8]) { self.b = b }

        mutating func pularSeparadores() {
            while i < b.count, b[i] == 32 || b[i] == 9 || b[i] == 10 || b[i] == 13 || b[i] == 44 { i += 1 }
        }

        mutating func numero() -> Double? {
            pularSeparadores()
            let inicio = i
            if i < b.count, b[i] == 43 || b[i] == 45 { i += 1 }
            var digitos = false, ponto = false
            while i < b.count {
                let c = b[i]
                if c >= 48 && c <= 57 { digitos = true; i += 1 } else if c == 46 && !ponto { ponto = true; i += 1 } else { break }
            }
            guard digitos else { i = inicio; return nil }
            if i < b.count, b[i] == 101 || b[i] == 69 {
                var j = i + 1
                if j < b.count, b[j] == 43 || b[j] == 45 { j += 1 }
                if j < b.count, b[j] >= 48 && b[j] <= 57 {
                    while j < b.count, b[j] >= 48 && b[j] <= 57 { j += 1 }
                    i = j
                }
            }
            return Double(String(decoding: b[inicio..<i], as: UTF8.self)).flatMap { $0.isFinite ? $0 : nil }
        }

        /// Bandeira dos arcos: um só caractere, mesmo sem separador ("a1 1 0 01 10 10").
        mutating func bandeira() -> Bool? {
            pularSeparadores()
            guard i < b.count, b[i] == 48 || b[i] == 49 else { return nil }
            i += 1
            return b[i - 1] == 49
        }

        mutating func comando() -> UInt8? {
            pularSeparadores()
            guard i < b.count else { return nil }
            let c = b[i]
            if (c >= 65 && c <= 90) || (c >= 97 && c <= 122), c != 101, c != 69 {
                i += 1
                return c
            }
            return nil
        }

        var fim: Bool {
            mutating get {
                pularSeparadores()
                return i >= b.count
            }
        }
    }

    /// Lista de transformações do SVG ("translate(10) rotate(45 5 5) …"), aplicadas da direita para a esquerda.
    static func transformacao(_ texto: String?) -> CGAffineTransform {
        guard let texto, !texto.isEmpty else { return .identity }
        var total = CGAffineTransform.identity
        var resto = Substring(texto)
        while let abre = resto.firstIndex(of: "("), let fecha = resto[abre...].firstIndex(of: ")") {
            let nome = resto[..<abre].trimmingCharacters(in: CharacterSet(charactersIn: " ,\t\n\r")).lowercased()
            let v = numeros(String(resto[resto.index(after: abre)..<fecha]))
            resto = resto[resto.index(after: fecha)...]
            func a(_ i: Int, _ padrao: Double = 0) -> Double { i < v.count ? v[i] : padrao }
            let t: CGAffineTransform
            switch nome {
            case "matrix" where v.count == 6: t = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            case "translate": t = CGAffineTransform(translationX: a(0), y: a(1))
            case "scale": t = CGAffineTransform(scaleX: a(0, 1), y: a(1, a(0, 1)))
            case "rotate":
                let giro = CGAffineTransform(rotationAngle: a(0) * .pi / 180)
                t = v.count >= 3
                    ? CGAffineTransform(translationX: -v[1], y: -v[2]).concatenating(giro).concatenating(CGAffineTransform(translationX: v[1], y: v[2]))
                    : giro
            case "skewx": t = CGAffineTransform(a: 1, b: 0, c: tan(a(0) * .pi / 180), d: 1, tx: 0, ty: 0)
            case "skewy": t = CGAffineTransform(a: 1, b: tan(a(0) * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
            default: t = .identity
            }
            // "A B" = A(B(p)): B se aplica antes.
            total = t.concatenating(total)
        }
        return total
    }

    /// RGB de 0 a 1 de uma cor do CSS (#rgb, #rrggbb, #rrggbbaa, rgb(), rgba(), hsl() e nomes); nil se não for cor.
    static func rgb(_ texto: String) -> (Double, Double, Double)? {
        let t = texto.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("#") {
            let h = Array(t.dropFirst())
            func hex(_ s: [Character]) -> Double? { Int(String(s), radix: 16).map { Double($0) / (s.count == 1 ? 15 : 255) } }
            switch h.count {
            case 3, 4: if let r = hex([h[0]]), let g = hex([h[1]]), let b = hex([h[2]]) { return (r, g, b) }
            case 6, 8: if let r = hex(Array(h[0..<2])), let g = hex(Array(h[2..<4])), let b = hex(Array(h[4..<6])) { return (r, g, b) }
            default: break
            }
            return nil
        }
        if t.hasPrefix("rgb") || t.hasPrefix("hsl") {
            guard let abre = t.firstIndex(of: "(") else { return nil }
            let partes = t[t.index(after: abre)...].prefix { $0 != ")" }
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).map(String.init)
            guard partes.count >= 3 else { return nil }
            if t.hasPrefix("rgb") {
                func canal(_ s: String) -> Double {
                    s.hasSuffix("%") ? (Double(s.dropLast()) ?? 0) / 100 : (Double(s) ?? 0) / 255
                }
                return (canal(partes[0]), canal(partes[1]), canal(partes[2]))
            }
            let h = (Double(partes[0].replacingOccurrences(of: "deg", with: "")) ?? 0) / 360
            let s = (Double(partes[1].replacingOccurrences(of: "%", with: "")) ?? 0) / 100
            let l = (Double(partes[2].replacingOccurrences(of: "%", with: "")) ?? 0) / 100
            let q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q
            func f(_ x: Double) -> Double {
                let t = x < 0 ? x + 1 : x > 1 ? x - 1 : x
                return t < 1 / 6 ? p + (q - p) * 6 * t : t < 1 / 2 ? q : t < 2 / 3 ? p + (q - p) * (2 / 3 - t) * 6 : p
            }
            return (f(h + 1 / 3), f(h), f(h - 1 / 3))
        }
        return nomes[t].map { (Double(($0 >> 16) & 255) / 255, Double(($0 >> 8) & 255) / 255, Double($0 & 255) / 255) }
    }

    /// Cor com alfa zero (#rgba, #rrggbbaa, rgba(…, 0)).
    static func transparente(_ texto: String) -> Bool {
        let t = texto.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("#") { return (t.count == 5 && t.hasSuffix("0")) || (t.count == 9 && t.hasSuffix("00")) }
        if t.hasPrefix("rgba") || t.hasPrefix("hsla") || t.contains("/") {
            let partes = t.prefix { $0 != ")" }.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" || $0 == "(" })
            if partes.count >= 5, let alfa = Double(partes[4].replacingOccurrences(of: "%", with: "")) { return alfa == 0 }
        }
        return false
    }

    /// Nomes de cor do CSS mais usados.
    static let nomes: [String: Int] = [
        "black": 0x000000, "white": 0xFFFFFF, "red": 0xFF0000, "green": 0x008000, "blue": 0x0000FF, "yellow": 0xFFFF00,
        "cyan": 0x00FFFF, "aqua": 0x00FFFF, "magenta": 0xFF00FF, "fuchsia": 0xFF00FF, "gray": 0x808080, "grey": 0x808080,
        "silver": 0xC0C0C0, "maroon": 0x800000, "olive": 0x808000, "lime": 0x00FF00, "teal": 0x008080, "navy": 0x000080,
        "purple": 0x800080, "orange": 0xFFA500, "pink": 0xFFC0CB, "brown": 0xA52A2A, "gold": 0xFFD700, "beige": 0xF5F5DC,
        "coral": 0xFF7F50, "crimson": 0xDC143C, "darkblue": 0x00008B, "darkgreen": 0x006400, "darkred": 0x8B0000,
        "darkgray": 0xA9A9A9, "darkgrey": 0xA9A9A9, "lightgray": 0xD3D3D3, "lightgrey": 0xD3D3D3, "dimgray": 0x696969,
        "indigo": 0x4B0082, "violet": 0xEE82EE, "khaki": 0xF0E68C, "salmon": 0xFA8072, "tomato": 0xFF6347,
        "turquoise": 0x40E0D0, "tan": 0xD2B48C, "orchid": 0xDA70D6, "plum": 0xDDA0DD, "skyblue": 0x87CEEB,
        "steelblue": 0x4682B4, "royalblue": 0x4169E1, "seagreen": 0x2E8B57, "forestgreen": 0x228B22, "chocolate": 0xD2691E,
        "firebrick": 0xB22222, "darkorange": 0xFF8C00, "hotpink": 0xFF69B4, "deeppink": 0xFF1493, "lightblue": 0xADD8E6,
        "lightgreen": 0x90EE90, "whitesmoke": 0xF5F5F5, "ivory": 0xFFFFF0, "lavender": 0xE6E6FA, "slategray": 0x708090,
    ]

    // MARK: Caminho (atributo d)

    /// Acrescenta o caminho do atributo `d` (unidades do usuário).
    static func caminho(_ d: String, em p: CGMutablePath) {
        var l = LeitorNumeros(Array(d.utf8))
        var atual = CGPoint.zero, inicio = CGPoint.zero
        var controle: CGPoint?, tipoControle: UInt8 = 0
        var comando: UInt8 = 0
        var precisaMover = true
        func garantir() {
            if precisaMover { p.move(to: atual); inicio = atual; precisaMover = false }
        }
        while !l.fim {
            if let c = l.comando() { comando = c } else if comando == 0 { break }
            let relativo = comando >= 97
            let base = relativo ? atual : .zero
            func ponto() -> CGPoint? {
                guard let x = l.numero(), let y = l.numero() else { return nil }
                return CGPoint(x: base.x + x, y: base.y + y)
            }
            var anterior = tipoControle
            tipoControle = 0
            switch comando | 0x20 {   // minúscula
            case 109:   // m
                guard let q = ponto() else { return }
                p.move(to: q)
                atual = q
                inicio = q
                precisaMover = false
                // Pares seguintes ao M são linhas.
                comando = relativo ? 108 : 76
                anterior = 0
            case 122:   // z
                if !p.isEmpty, !precisaMover { p.closeSubpath() }
                atual = inicio
                precisaMover = true
                comando = 0
            case 108:   // l
                guard let q = ponto() else { return }
                garantir()
                p.addLine(to: q)
                atual = q
            case 104:   // h
                guard let x = l.numero() else { return }
                garantir()
                atual = CGPoint(x: relativo ? atual.x + x : x, y: atual.y)
                p.addLine(to: atual)
            case 118:   // v
                guard let y = l.numero() else { return }
                garantir()
                atual = CGPoint(x: atual.x, y: relativo ? atual.y + y : y)
                p.addLine(to: atual)
            case 99:   // c
                guard let c1 = ponto(), let c2 = ponto(), let q = ponto() else { return }
                garantir()
                p.addCurve(to: q, control1: c1, control2: c2)
                (atual, controle, tipoControle) = (q, c2, 99)
            case 115:   // s
                guard let c2 = ponto(), let q = ponto() else { return }
                garantir()
                let c1 = anterior == 99 ? CGPoint(x: 2 * atual.x - controle!.x, y: 2 * atual.y - controle!.y) : atual
                p.addCurve(to: q, control1: c1, control2: c2)
                (atual, controle, tipoControle) = (q, c2, 99)
            case 113:   // q
                guard let c1 = ponto(), let q = ponto() else { return }
                garantir()
                p.addQuadCurve(to: q, control: c1)
                (atual, controle, tipoControle) = (q, c1, 113)
            case 116:   // t
                guard let q = ponto() else { return }
                garantir()
                let c1 = anterior == 113 ? CGPoint(x: 2 * atual.x - controle!.x, y: 2 * atual.y - controle!.y) : atual
                p.addQuadCurve(to: q, control: c1)
                (atual, controle, tipoControle) = (q, c1, 113)
            case 97:   // a
                guard let rx = l.numero(), let ry = l.numero(), let giro = l.numero(), let grande = l.bandeira(),
                      let horario = l.bandeira(), let q = ponto() else { return }
                garantir()
                arco(em: p, de: atual, ate: q, rx: rx, ry: ry, giro: giro, grande: grande, horario: horario)
                atual = q
            default:
                return
            }
        }
    }

    /// Arco elíptico do SVG (de ponto a ponto) em cúbicas de até 90°.
    static func arco(em p: CGMutablePath, de a: CGPoint, ate b: CGPoint, rx: Double, ry: Double, giro: Double, grande: Bool, horario: Bool) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, a != b else { p.addLine(to: b); return }
        let phi = giro * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (a.x - b.x) / 2, dy = (a.y - b.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        let lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = den > 0 ? sqrt(max(num / den, 0)) : 0
        if grande == horario { coef = -coef }
        let cxl = coef * rx * y1 / ry, cyl = -coef * ry * x1 / rx
        let cx = cosPhi * cxl - sinPhi * cyl + (a.x + b.x) / 2, cy = sinPhi * cxl + cosPhi * cyl + (a.y + b.y) / 2
        func angulo(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let s = ux * vy - uy * vx >= 0 ? 1.0 : -1.0
            let d = (ux * vx + uy * vy) / (hypot(ux, uy) * hypot(vx, vy))
            return s * acos(min(max(d, -1), 1))
        }
        let t1 = angulo(1, 0, (x1 - cxl) / rx, (y1 - cyl) / ry)
        var dt = angulo((x1 - cxl) / rx, (y1 - cyl) / ry, (-x1 - cxl) / rx, (-y1 - cyl) / ry)
        if !horario, dt > 0 { dt -= 2 * .pi } else if horario, dt < 0 { dt += 2 * .pi }
        let partes = max(1, Int(ceil(abs(dt) / (.pi / 2) - 1e-9)))
        let passo = dt / Double(partes)
        let k = 4.0 / 3 * tan(passo / 4)
        func ponto(_ t: Double) -> CGPoint {
            CGPoint(x: cx + rx * cos(t) * cosPhi - ry * sin(t) * sinPhi, y: cy + rx * cos(t) * sinPhi + ry * sin(t) * cosPhi)
        }
        func derivada(_ t: Double) -> CGPoint {
            CGPoint(x: -rx * sin(t) * cosPhi - ry * cos(t) * sinPhi, y: -rx * sin(t) * sinPhi + ry * cos(t) * cosPhi)
        }
        var t = t1
        for i in 0..<partes {
            let t2 = t + passo
            let p1 = ponto(t), p2 = i == partes - 1 ? b : ponto(t2), d1 = derivada(t), d2 = derivada(t2)
            p.addCurve(to: p2, control1: CGPoint(x: p1.x + k * d1.x, y: p1.y + k * d1.y),
                       control2: CGPoint(x: p2.x - k * d2.x, y: p2.y - k * d2.y))
            t = t2
        }
    }
}
