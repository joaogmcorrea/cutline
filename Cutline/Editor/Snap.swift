// Snap to point (como no Illustrator): encaixa em cantos, meios e centro da página, nos pontos dos
// outros objetos e nas guias. Os alvos são calculados uma vez por gesto.
import SwiftUI

struct AlvosSnap {
    private(set) var pontos: [CGPoint]
    let guias: Guias

    @MainActor
    init(doc: Documento, excluir: Set<Objeto.ID>) {
        let pagina = CGRect(origin: .zero, size: Documento.pagina)
        pontos = [CGPoint(x: pagina.minX, y: pagina.minY), CGPoint(x: pagina.midX, y: pagina.minY), CGPoint(x: pagina.maxX, y: pagina.minY),
                  CGPoint(x: pagina.minX, y: pagina.midY), CGPoint(x: pagina.midX, y: pagina.midY), CGPoint(x: pagina.maxX, y: pagina.midY),
                  CGPoint(x: pagina.minX, y: pagina.maxY), CGPoint(x: pagina.midX, y: pagina.maxY), CGPoint(x: pagina.maxX, y: pagina.maxY)]
        for objeto in doc.objetosEmOrdem where doc.visivel(objeto) && !excluir.contains(objeto.id) {
            pontos.append(contentsOf: objeto.ancoras)
        }
        guias = doc.guias
    }

    /// Ponto encaixado (ou o próprio) e onde mostrar a marca do encaixe. Tolerância em mm.
    func encaixar(_ p: CGPoint, tolerancia: Double) -> (ponto: CGPoint, marca: CGPoint?) {
        var melhor: CGPoint?, distancia = tolerancia
        for q in pontos {
            let d = hypot(q.x - p.x, q.y - p.y)
            if d < distancia { distancia = d; melhor = q }
        }
        if let melhor { return (melhor, melhor) }
        // Guias: encaixa por eixo.
        var q = p, achou = false
        if let x = guias.verticais.min(by: { abs($0 - p.x) < abs($1 - p.x) }), abs(x - p.x) < tolerancia { q.x = x; achou = true }
        if let y = guias.horizontais.min(by: { abs($0 - p.y) < abs($1 - p.y) }), abs(y - p.y) < tolerancia { q.y = y; achou = true }
        return (q, achou ? q : nil)
    }

    /// Deslocamento que encaixa algum dos pontos que se movem num alvo (ou numa guia, por eixo).
    func encaixar(_ moveis: [CGPoint], dx: Double, dy: Double, tolerancia: Double) -> (dx: Double, dy: Double, marca: CGPoint?) {
        var melhor: (Double, Double, CGPoint)?, distancia = tolerancia
        for m in moveis {
            let x = m.x + dx, y = m.y + dy
            for q in pontos {
                let d = hypot(q.x - x, q.y - y)
                if d < distancia { distancia = d; melhor = (q.x - m.x, q.y - m.y, q) }
            }
        }
        if let melhor { return (melhor.0, melhor.1, melhor.2) }
        var bx: Double?, by: Double?, mx = tolerancia, my = tolerancia
        for m in moveis {
            for x in guias.verticais where abs(m.x + dx - x) < mx { mx = abs(m.x + dx - x); bx = x - m.x }
            for y in guias.horizontais where abs(m.y + dy - y) < my { my = abs(m.y + dy - y); by = y - m.y }
        }
        return (bx ?? dx, by ?? dy, nil)
    }
}

extension Objeto {
    /// Pontos que puxam o snap ao mover: os do objeto, ou só a caixa quando são muitos.
    static func pontosMoveis(_ objetos: [Objeto]) -> [CGPoint] {
        let todos = objetos.flatMap(\.ancoras)
        guard todos.count > 64, let primeiro = objetos.first else { return todos }
        let caixa = objetos.dropFirst().reduce(primeiro.quadro.standardized) { $0.union($1.quadro.standardized) }
        return Objeto(forma: .elipse, quadro: caixa).ancoras
    }
}
