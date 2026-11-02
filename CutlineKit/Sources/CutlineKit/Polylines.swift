// Contornos (curvas) → polilinhas para o corte. A máquina só anda em linha reta (comandos D),
// então curvas viram sequências de segmentos curtos.
import CoreGraphics

extension CGPath {
    /// Polilinhas em que cada subcaminho vira uma lista de pontos; subcaminhos fechados repetem o
    /// primeiro ponto no fim (para a lâmina fechar o corte). `tolerance` = desvio máximo da curva, nas
    /// unidades do caminho (em mm: 0,02 mm, abaixo da resolução da máquina, que é 0,05 mm).
    public func cutPolylines(tolerance: CGFloat = 0.02) -> [[CGPoint]] {
        var result: [[CGPoint]] = []
        var current: [CGPoint] = []
        func finish() {
            if current.count >= 2 { result.append(current) }
            current = []
        }
        flattened(threshold: tolerance).applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint:
                finish()
                current = [element.points[0]]
            case .addLineToPoint:
                if current.last != element.points[0] { current.append(element.points[0]) }
            case .closeSubpath:
                if let first = current.first, current.last != first { current.append(first) }
                finish()
            default:
                // `flattened` só devolve retas; curvas não chegam aqui.
                break
            }
        }
        finish()
        return result
    }
}

extension Array where Element == CGPoint {
    /// Corte picotado: a polilinha vira trechos de `pattern[0]` com corte, `pattern[1]` sem corte, e assim
    /// por diante (unidades do caminho — mm). Sem padrão válido, devolve a polilinha inteira.
    public func dashed(_ pattern: [CGFloat]) -> [[CGPoint]] {
        guard count >= 2 else { return [] }
        guard pattern.count >= 2, pattern.allSatisfy({ $0 > 0 }) else { return [self] }
        var result: [[CGPoint]] = []
        var current: [CGPoint] = [self[0]]
        var index = 0
        var left = pattern[0]
        var cutting = true
        for i in 0..<(count - 1) {
            var a = self[i]
            let b = self[i + 1]
            var remaining = hypot(b.x - a.x, b.y - a.y)
            while remaining > 0 {
                if remaining < left {
                    left -= remaining
                    remaining = 0
                    if cutting { current.append(b) }
                } else {
                    let t = left / remaining
                    let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                    if cutting {
                        current.append(p)
                        if current.count >= 2 { result.append(current) }
                        current = []
                    } else {
                        current = [p]
                    }
                    cutting.toggle()
                    remaining -= left
                    a = p
                    index = (index + 1) % pattern.count
                    left = pattern[index]
                }
            }
        }
        if cutting, current.count >= 2 { result.append(current) }
        return result
    }
}
