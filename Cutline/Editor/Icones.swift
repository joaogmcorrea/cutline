// Ícones do painel desenhados como os SVG do protótipo (grade de 24 × 24), em imagens-modelo do
// macOS (tingidas pelo sistema: funcionam no claro, no escuro e nos controles segmentados).
import AppKit
import SwiftUI

enum Icones {
    /// Desenho numa grade de 24 × 24 com y para baixo, como no SVG.
    private static func imagem(_ tamanho: CGFloat, grade: CGFloat = 24, _ desenhar: @escaping () -> Void) -> NSImage {
        let imagem = NSImage(size: NSSize(width: tamanho, height: tamanho), flipped: true) { _ in
            let escala = tamanho / grade
            NSGraphicsContext.current?.cgContext.scaleBy(x: escala, y: escala)
            NSColor.black.set()
            desenhar()
            return true
        }
        imagem.isTemplate = true
        return imagem
    }

    private static func linhas(_ pontos: [(CGFloat, CGFloat)], largura: CGFloat, ponta: NSBezierPath.LineCapStyle = .butt,
                               canto: NSBezierPath.LineJoinStyle = .miter, alfa: CGFloat = 1) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: pontos[0].0, y: pontos[0].1))
        for q in pontos.dropFirst() { p.line(to: NSPoint(x: q.0, y: q.1)) }
        p.lineWidth = largura
        p.lineCapStyle = ponta
        p.lineJoinStyle = canto
        NSColor.black.withAlphaComponent(alfa).setStroke()
        p.stroke()
    }

    private static func poligono(_ pontos: [(CGFloat, CGFloat)], alfa: CGFloat = 1) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: pontos[0].0, y: pontos[0].1))
        for q in pontos.dropFirst() { p.line(to: NSPoint(x: q.0, y: q.1)) }
        p.close()
        NSColor.black.withAlphaComponent(alfa).setFill()
        p.fill()
    }

    private static func quadro(_ r: CGRect, largura: CGFloat, tracejado: Bool = false, alfa: CGFloat = 1) {
        let p = NSBezierPath(rect: r)
        p.lineWidth = largura
        if tracejado { p.setLineDash([2, 1.5], count: 2, phase: 0) }
        NSColor.black.withAlphaComponent(alfa).setStroke()
        p.stroke()
    }

    static func ponta(_ ponta: Ponta) -> NSImage {
        imagem(16) {
            let estilo: NSBezierPath.LineCapStyle = switch ponta {
            case .reta: .butt
            case .arredondada: .round
            case .projetada: .square
            }
            linhas([(4, 12), (16, 12)], largura: 5, ponta: estilo)
            linhas([(16, 6), (16, 18)], largura: 1)
        }
    }

    static func canto(_ canto: Canto) -> NSImage {
        imagem(16) {
            let estilo: NSBezierPath.LineJoinStyle = switch canto {
            case .vivo: .miter
            case .arredondado: .round
            case .chanfrado: .bevel
            }
            linhas([(6, 20), (6, 6), (20, 6)], largura: 5, canto: estilo)
        }
    }

    static func alinhamento(_ alinhamento: AlinhamentoTraco) -> NSImage {
        imagem(16) {
            quadro(CGRect(x: 5, y: 5, width: 14, height: 14), largura: 1)
            let r: CGRect = switch alinhamento {
            case .centro: CGRect(x: 5, y: 5, width: 14, height: 14)
            case .dentro: CGRect(x: 7, y: 7, width: 10, height: 10)
            case .fora: CGRect(x: 3, y: 3, width: 18, height: 18)
            }
            quadro(r, largura: 4, alfa: 0.5)
        }
    }

    /// Amostra da linha (contínua ou picotada), para o menu de estilo.
    static func linha(_ estilo: EstiloLinha, largura: CGFloat = 110) -> NSImage {
        let imagem = NSImage(size: NSSize(width: largura, height: 8), flipped: true) { _ in
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 0, y: 4))
            p.line(to: NSPoint(x: largura, y: 4))
            p.lineWidth = 1.5
            if let padrao = estilo.padrao { p.setLineDash(padrao.map { CGFloat($0) * 3 }, count: padrao.count, phase: 0) }
            NSColor.black.setStroke()
            p.stroke()
            return true
        }
        imagem.isTemplate = true
        return imagem
    }

    static func pathfinder(_ operacao: OperacaoPathfinder) -> NSImage {
        imagem(22) {
            switch operacao {
            case .unir:
                poligono([(3, 3), (14, 3), (14, 8), (21, 8), (21, 21), (10, 21), (10, 16), (3, 16)])
            case .subtrairFrente:
                poligono([(3, 3), (14, 3), (14, 8), (8, 8), (8, 16), (3, 16)])
                quadro(CGRect(x: 8.5, y: 8.5, width: 12, height: 12), largura: 1, tracejado: true)
            case .intersecao:
                quadro(CGRect(x: 3.5, y: 3.5, width: 10, height: 10), largura: 1, tracejado: true)
                quadro(CGRect(x: 10.5, y: 10.5, width: 10, height: 10), largura: 1, tracejado: true)
                poligono([(10, 10), (14, 10), (14, 14), (10, 14)])
            case .excluir:
                poligono([(3, 3), (14, 3), (14, 10), (10, 10), (10, 14), (3, 14)])
                poligono([(14, 10), (21, 10), (21, 21), (10, 21), (10, 14), (14, 14)])
            case .dividir:
                poligono([(3, 3), (14, 3), (14, 10), (10, 10), (10, 14), (3, 14)])
                poligono([(10.5, 10.5), (13.5, 10.5), (13.5, 13.5), (10.5, 13.5)])
                poligono([(14, 10), (21, 10), (21, 21), (10, 21), (10, 14), (14, 14)], alfa: 0.55)
            case .subtrairTras:
                quadro(CGRect(x: 3.5, y: 3.5, width: 11, height: 11), largura: 1, tracejado: true)
                poligono([(15, 9), (21, 9), (21, 21), (9, 21), (9, 15), (15, 15)])
            }
        }
    }

}
