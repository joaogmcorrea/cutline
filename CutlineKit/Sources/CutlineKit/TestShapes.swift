// Formas fixas do teste de corte (cartela de adesivo) e folha de Print & Cut.
// Porte de formas.py e pnc.py, do protótipo em Python que conferiu o driver (fora do repositório) — mesmos pontos.
import CoreGraphics
import Foundation

public enum TestShapes {
    public struct Shape: Sendable {
        public let id: String
        public let name: String
        /// Em mm, origem no canto superior esquerdo da cartela.
        public let paths: [[CGPoint]]
        public let defaults: CutSettings
    }

    /// Resolução dos arcos arredondados.
    static let arcStepDegrees = 6.0

    // MARK: Cartela de adesivo

    static let squareSide = 60.0
    static let center = squareSide / 2

    /// Ordem = ordem de corte: primeiro o meio-corte de dentro, por último o corte total de fora
    /// (cortar o contorno externo antes deixaria a peça solta na base).
    public static let sticker: [Shape] = [
        Shape(id: "estrela", name: "Estrela — meio-corte (só o adesivo)",
              paths: [roundedStar(cx: center, cy: center + 1.5, outerRadius: 23, innerRadius: 10.5,
                                  tipRadius: 3.0, valleyRadius: 1.5)],
              defaults: CutSettings(speed: 5, force: 8, blade: 1, passes: 1)),
        Shape(id: "quadrado", name: "Quadrado — corte total (adesivo + fundo)",
              paths: [square(x: 0, y: 0, side: squareSide)],
              defaults: CutSettings(speed: 3, force: 25, blade: 5, passes: 2)),
    ]

    /// Posição padrão da cartela na base A4.
    public static let stickerPosition = CGPoint(x: 20, y: 20)

    // MARK: Print & Cut

    /// Marcas no padrão Silhouette: origem 15/15 mm, 180 × 267 mm entre marcas.
    public static let printAndCutRegistration = Cutter.Registration(originX: 15, originY: 15, width: 210 - 2 * 15,
                                                                    length: 297 - 2 * 15)
    /// Canto superior esquerdo de cada cópia da cartela na folha (em diagonal).
    public static let printAndCutCopies = [CGPoint(x: 35, y: 40), CGPoint(x: 75, y: 118), CGPoint(x: 115, y: 196)]

    /// Caminhos de uma forma em todas as cópias da folha.
    public static func printAndCutPaths(_ shape: Shape) -> [[CGPoint]] {
        printAndCutCopies.flatMap { translated(shape.paths, by: $0) }
    }

    public static func translated(_ paths: [[CGPoint]], by delta: CGPoint) -> [[CGPoint]] {
        paths.map { path in path.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) } }
    }

    // MARK: Geometria

    public static func square(x: Double, y: Double, side: Double) -> [CGPoint] {
        [CGPoint(x: x, y: y), CGPoint(x: x + side, y: y), CGPoint(x: x + side, y: y + side),
         CGPoint(x: x, y: y + side), CGPoint(x: x, y: y)]
    }

    public static func roundedStar(cx: Double, cy: Double, outerRadius: Double, innerRadius: Double, points: Int = 5,
                                   tipRadius: Double = 3, valleyRadius: Double = 1.5) -> [CGPoint] {
        var vertices: [(Double, Double)] = []
        var radii: [Double] = []
        for i in 0..<(points * 2) {
            let outer = i % 2 == 0
            let r = outer ? outerRadius : innerRadius
            let a = -Double.pi / 2 + Double(i) * Double.pi / Double(points)   // primeira ponta para cima
            vertices.append((cx + r * cos(a), cy + r * sin(a)))
            radii.append(outer ? tipRadius : valleyRadius)
        }
        return roundPolygon(vertices, radii: radii)
    }

    /// Troca cada vértice por um arco tangente às duas arestas (raio por vértice).
    /// Funciona para vértices convexos e côncavos. Retorna o polígono fechado.
    static func roundPolygon(_ vertices: [(Double, Double)], radii: [Double]) -> [CGPoint] {
        let n = vertices.count
        var points: [CGPoint] = []
        for i in 0..<n {
            let (px, py) = vertices[i]
            let (ax, ay) = vertices[(i - 1 + n) % n]
            let (bx, by) = vertices[(i + 1) % n]
            // vetores unitários do vértice para os vizinhos
            var ux = ax - px, uy = ay - py
            var vx = bx - px, vy = by - py
            let lu = hypot(ux, uy), lv = hypot(vx, vy)
            ux /= lu; uy /= lu; vx /= lv; vy /= lv
            let angle = acos(max(-1.0, min(1.0, ux * vx + uy * vy)))
            var r = radii[i]
            if r <= 0 || angle < 1e-6 || abs(angle - Double.pi) < 1e-6 {
                points.append(CGPoint(x: px, y: py))
                continue
            }
            var d = r / tan(angle / 2)                 // distância do vértice ao ponto de tangência
            d = min(d, lu * 0.49, lv * 0.49)           // não ultrapassar metade da aresta
            r = d * tan(angle / 2)
            let bxs = ux + vx, bys = uy + vy           // bissetriz
            let lb = hypot(bxs, bys)
            let h = r / sin(angle / 2)
            let cx = px + bxs / lb * h, cy = py + bys / lb * h
            let t1 = (px + ux * d, py + uy * d)
            let t2 = (px + vx * d, py + vy * d)
            let a1 = atan2(t1.1 - cy, t1.0 - cx)
            let a2 = atan2(t2.1 - cy, t2.0 - cx)
            let delta = pythonModulo(a2 - a1 + Double.pi, 2 * Double.pi) - Double.pi   // arco menor
            let steps = max(2, Int(abs(delta * (180.0 / Double.pi)) / arcStepDegrees))
            for k in 0...steps {
                let a = a1 + delta * Double(k) / Double(steps)
                points.append(CGPoint(x: cx + r * cos(a), y: cy + r * sin(a)))
            }
        }
        points.append(points[0])
        return points
    }

    /// `%` do Python para floats: o resultado tem o sinal do divisor.
    static func pythonModulo(_ x: Double, _ m: Double) -> Double {
        var r = fmod(x, m)
        if r != 0 {
            if (m < 0) != (r < 0) { r += m }
        } else {
            r = copysign(0, m)
        }
        return r
    }
}
