// Vetorização (como no protótipo): o contorno externo da imagem, com margem — o que está dentro da arte é
// ignorado —, ou também os contornos internos (os vazados, como o miolo de um O). Máscara (transparência ou
// distância da cor do fundo) → preenche os buracos (só no externo) → dilata pela margem (distância de
// chanfro) → marching squares → simplificação (Douglas–Peucker, pela quantidade de nós) → nós suaves ou cantos
// (pela suavização).
import CoreGraphics
import Foundation

nonisolated struct ParametrosVetorizacao: Equatable, Sendable {
    /// Também os contornos internos (os vazados da arte); senão, só o externo.
    var internos = false
    /// Largura da imagem na página, em mm (a de entrada; depois se redimensiona na tela).
    var largura = 60.0
    /// Distância do contorno à arte, em mm.
    var margem = 2.0
    /// Quantidade de nós, de 0 (o mínimo que segura a forma) a 100 (todos os detalhes da imagem).
    var nos = 50.0
    /// Quanto os nós se arredondam, de 0 (todos cantos, retas entre eles) a 100 (todos suaves).
    var suavizacao = 40.0
    /// Diferença de cor para separar a arte do fundo (imagens sem transparência).
    var tolerancia = 40.0

    /// Tolerância do Douglas–Peucker, em pixels da imagem reduzida: de 8 (poucos nós) a 0,5 (todos os
    /// detalhes; abaixo disso, ficariam os degraus dos pixels).
    var simplificacao: Double { 0.5 * pow(16, 1 - min(max(nos, 0), 100) / 100) }
}

nonisolated struct ResultadoVetorizacao: Sendable {
    /// Laços fechados em mm, com origem no canto superior esquerdo da imagem.
    var lacos: [[CGPoint]]
    /// A imagem tinha transparência (senão, o fundo foi detectado pela cor da borda).
    var transparente: Bool
    var pontos: Int { lacos.reduce(0) { $0 + $1.count } }
}

nonisolated enum Vetorizacao {
    /// Pixels RGBA (não pré-multiplicados) da imagem reduzida para no máximo `maximo` px no lado maior.
    struct Pixels: Sendable {
        let largura: Int, altura: Int
        let rgba: [UInt8]
    }

    static func pixels(_ imagem: CGImage, maximo: Int = 500) -> Pixels? {
        let escala = min(1, Double(maximo) / Double(max(imagem.width, imagem.height)))
        let w = max(1, Int((Double(imagem.width) * escala).rounded())), h = max(1, Int((Double(imagem.height) * escala).rounded()))
        var dados = [UInt8](repeating: 0, count: w * h * 4)
        let ok = dados.withUnsafeMutableBytes { bytes -> Bool in
            guard let ctx = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(imagem, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? Pixels(largura: w, altura: h, rgba: dados) : nil
    }

    static func vetorizar(_ px: Pixels, _ prm: ParametrosVetorizacao) -> ResultadoVetorizacao {
        let iw = px.largura, ih = px.altura, d = px.rgba
        let pxmm = Double(iw) / max(prm.largura, 1), r = prm.margem * pxmm
        let pad = Int(r.rounded(.up)) + 2
        let W = iw + 2 * pad, H = ih + 2 * pad

        // 1. Máscara: transparência, se houver; senão, distância da cor média da borda.
        var transparente = false
        for i in stride(from: 3, to: d.count, by: 4) where d[i] < 250 { transparente = true; break }
        var fundo = (0.0, 0.0, 0.0), n = 0.0
        if !transparente {
            for y in 0..<ih { for x in 0..<iw where x == 0 || y == 0 || x == iw - 1 || y == ih - 1 {
                let i = (y * iw + x) * 4
                fundo.0 += Double(d[i]); fundo.1 += Double(d[i + 1]); fundo.2 += Double(d[i + 2]); n += 1
            } }
            fundo = (fundo.0 / max(n, 1), fundo.1 / max(n, 1), fundo.2 / max(n, 1))
        }
        var mascara = [Bool](repeating: false, count: W * H)
        for y in 0..<ih { for x in 0..<iw {
            let i = (y * iw + x) * 4
            let dentro = transparente
                ? d[i + 3] > 100
                : sqrt(pow(Double(d[i]) - fundo.0, 2) + pow(Double(d[i + 1]) - fundo.1, 2) + pow(Double(d[i + 2]) - fundo.2, 2)) > prm.tolerancia
            if dentro { mascara[(y + pad) * W + x + pad] = true }
        } }

        // 2. Só o externo: preenche os buracos — o que não se alcança a partir da borda vira "dentro".
        //    Com os internos, os vazados ficam (e a margem os estreita).
        var fora = mascara.map { !$0 }
        if !prm.internos {
            fora = [Bool](repeating: false, count: W * H)
            var pilha = [0]
            fora[0] = true
            while let k = pilha.popLast() {
                let x = k % W, y = k / W
                for (nx, ny) in [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)] where nx >= 0 && ny >= 0 && nx < W && ny < H {
                    let j = ny * W + nx
                    if !fora[j], !mascara[j] { fora[j] = true; pilha.append(j) }
                }
            }
        }

        // 3. Margem: dilata pela distância (chanfro 1 / √2), em duas passadas.
        var dist = fora.map { $0 ? 1e9 : 0 }
        if r > 0 {
            let s = 2.0.squareRoot()
            for y in 0..<H { for x in 0..<W {
                let i = y * W + x
                var v = dist[i]
                if x > 0 { v = min(v, dist[i - 1] + 1) }
                if y > 0 {
                    v = min(v, dist[i - W] + 1)
                    if x > 0 { v = min(v, dist[i - W - 1] + s) }
                    if x < W - 1 { v = min(v, dist[i - W + 1] + s) }
                }
                dist[i] = v
            } }
            for y in stride(from: H - 1, through: 0, by: -1) { for x in stride(from: W - 1, through: 0, by: -1) {
                let i = y * W + x
                var v = dist[i]
                if x < W - 1 { v = min(v, dist[i + 1] + 1) }
                if y < H - 1 {
                    v = min(v, dist[i + W] + 1)
                    if x < W - 1 { v = min(v, dist[i + W + 1] + s) }
                    if x > 0 { v = min(v, dist[i + W - 1] + s) }
                }
                dist[i] = v
            } }
        }
        let g = dist.map { $0 <= r }

        // 4. Marching squares → laços (coordenadas dobradas: meios de pixel viram inteiros).
        let tabela: [Int: [(Character, Character)]] = [
            1: [("L", "B")], 2: [("B", "R")], 3: [("L", "R")], 4: [("T", "R")], 5: [("L", "B"), ("T", "R")], 6: [("T", "B")],
            7: [("T", "L")], 8: [("T", "L")], 9: [("T", "B")], 10: [("T", "L"), ("B", "R")], 11: [("T", "R")], 12: [("L", "R")],
            13: [("B", "R")], 14: [("L", "B")],
        ]
        var vizinhos: [Int: [Int]] = [:]
        let chave = { (x: Int, y: Int) in x * 1_000_003 + y }
        for y in 0..<(H - 1) { for x in 0..<(W - 1) {
            let caso = (g[y * W + x] ? 8 : 0) + (g[y * W + x + 1] ? 4 : 0) + (g[(y + 1) * W + x + 1] ? 2 : 0) + (g[(y + 1) * W + x] ? 1 : 0)
            guard let segmentos = tabela[caso] else { continue }
            let ponto: [Character: (Int, Int)] = ["T": (2 * x + 1, 2 * y), "R": (2 * x + 2, 2 * y + 1), "B": (2 * x + 1, 2 * y + 2), "L": (2 * x, 2 * y + 1)]
            for (a, b) in segmentos {
                let pa = ponto[a]!, pb = ponto[b]!
                vizinhos[chave(pa.0, pa.1), default: []].append(chave(pb.0, pb.1))
                vizinhos[chave(pb.0, pb.1), default: []].append(chave(pa.0, pa.1))
            }
        } }
        var visto = Set<Int>()
        var lacos: [[CGPoint]] = []
        for inicio in vizinhos.keys where !visto.contains(inicio) {
            var laco: [CGPoint] = []
            var anterior: Int?, atual: Int? = inicio
            while let k = atual, !visto.contains(k) {
                visto.insert(k)
                laco.append(CGPoint(x: Double(k / 1_000_003) / 2, y: Double(k % 1_000_003) / 2))
                let proximo = vizinhos[k]?.first { $0 != anterior && !visto.contains($0) }
                anterior = k
                atual = proximo
            }
            if laco.count > 8 { lacos.append(laco) }
        }
        let area = { (l: [CGPoint]) -> Double in
            abs(zip(l, l.dropFirst() + [l[0]]).reduce(0) { $0 + $1.0.x * $1.1.y - $1.1.x * $1.0.y }) / 2
        }
        // Descarta sujeira: laços pequenos demais perto do maior (com os internos, aceita vazados menores).
        let maior = max(1, lacos.map(area).max() ?? 1)
        let minimo = maior * (prm.internos ? 0.0005 : 0.004)
        // Simplificado, um vazado estreito pode virar um risco (2 nós): sai também.
        let finais = lacos.filter { area($0) > minimo }.map { laco in
            Array(simplificar(laco + [laco[0]], prm.simplificacao).dropLast())
                .map { CGPoint(x: ($0.x - Double(pad)) / pxmm, y: ($0.y - Double(pad)) / pxmm) }
        }.filter { $0.count >= 3 }
        return ResultadoVetorizacao(lacos: finais, transparente: transparente)
    }

    /// Douglas–Peucker.
    static func simplificar(_ pts: [CGPoint], _ eps: Double) -> [CGPoint] {
        guard pts.count >= 3, let a = pts.first, let b = pts.last else { return pts }
        let comprimento = hypot(b.x - a.x, b.y - a.y)
        var maximo = 0.0, indice = 0
        for i in 1..<(pts.count - 1) {
            let p = pts[i]
            let dd = comprimento == 0 ? hypot(p.x - a.x, p.y - a.y)
                : abs((b.y - a.y) * p.x - (b.x - a.x) * p.y + b.x * a.y - b.y * a.x) / comprimento
            if dd > maximo { maximo = dd; indice = i }
        }
        guard maximo > eps else { return [a, b] }
        return Array(simplificar(Array(pts[...indice]), eps).dropLast()) + simplificar(Array(pts[indice...]), eps)
    }

    /// Nós de um laço fechado: suave onde a curva vira até o ângulo que a suavização deixa (0 = nenhum,
    /// 100 = todos, até as quinas), canto no resto. As alças vão na direção dos vizinhos, com um terço do
    /// segmento de cada lado (assim um polígono de muitos lados vira um círculo, sem laçadas).
    static func suavizar(_ pts: [CGPoint], _ suavizacao: Double) -> [No] {
        let limite = min(max(suavizacao, 0), 100) / 100 * .pi
        let n = pts.count
        return pts.enumerated().map { i, p in
            let a = pts[(i - 1 + n) % n], b = pts[(i + 1) % n]
            let giro = abs(remainder(atan2(b.y - p.y, b.x - p.x) - atan2(p.y - a.y, p.x - a.x), 2 * .pi))
            let d = hypot(b.x - a.x, b.y - a.y)
            guard limite > 0, giro <= limite, d > 0 else { return No(ponto: p) }
            let ux = (b.x - a.x) / d, uy = (b.y - a.y) / d
            let antes = hypot(p.x - a.x, p.y - a.y) / 3, depois = hypot(b.x - p.x, b.y - p.y) / 3
            return No(ponto: p, entrada: CGPoint(x: p.x - ux * antes, y: p.y - uy * antes),
                      saida: CGPoint(x: p.x + ux * depois, y: p.y + uy * depois))
        }
    }
}
