// Réguas em mm (origem no canto superior esquerdo da página), como no protótipo: faixas de vidro no
// topo e à esquerda da área livre, com a marca do ponteiro. Arrastar delas cria guias (na Tela, que
// recebe o gesto — as réguas só desenham).
import SwiftUI

/// Posição do ponteiro sobre a tela. Fica fora do estado da Tela: só quem lê (réguas, prévia da
/// caneta) redesenha ao mover o mouse.
@Observable
final class Ponteiro {
    var tela: CGPoint?
    var mm: CGPoint?
}

enum Eixo {
    /// Guia vertical (posição em x) ou horizontal (em y).
    case vertical, horizontal
}

struct GeometriaReguas {
    static let espessura = 18.0
    /// Canto superior esquerdo das réguas e até onde vão (pontos da tela).
    let area: CGRect

    var canto: CGRect { CGRect(x: area.minX, y: area.minY, width: Self.espessura, height: Self.espessura) }
    var horizontal: CGRect {
        CGRect(x: area.minX + Self.espessura + 2, y: area.minY, width: max(area.width - Self.espessura - 2, 0), height: Self.espessura)
    }
    var vertical: CGRect {
        CGRect(x: area.minX, y: area.minY + Self.espessura + 2, width: Self.espessura, height: max(area.height - Self.espessura - 2, 0))
    }
}

struct Reguas: View {
    let geometria: GeometriaReguas
    let vista: Vista
    let ponteiro: Ponteiro
    let temGuias: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            faixa(geometria.horizontal, horizontal: true)
            faixa(geometria.vertical, horizontal: false)
            RoundedRectangle(cornerRadius: 6)
                .fill(.clear)
                .frame(width: geometria.canto.width, height: geometria.canto.height)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    if temGuias {
                        Image(.fechar).resizable().frame(width: 9, height: 9).foregroundStyle(.secondary)
                    }
                }
                .help("Duplo clique apaga as guias")
                .offset(x: geometria.canto.minX, y: geometria.canto.minY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func faixa(_ r: CGRect, horizontal: Bool) -> some View {
        Canvas { ctx, tamanho in
            desenhar(&ctx, tamanho: tamanho, origem: horizontal ? vista.origem.x - r.minX : vista.origem.y - r.minY, horizontal: horizontal)
        }
        .frame(width: r.width, height: r.height)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 6))
        .offset(x: r.minX, y: r.minY)
    }

    /// Passo das marcas maiores para ficarem a ≥ 55 pt umas das outras; subdivisões de 5 ou 10.
    private func desenhar(_ ctx: inout GraphicsContext, tamanho: CGSize, origem: Double, horizontal: Bool) {
        let e = vista.escala, rg = GeometriaReguas.espessura
        let passo = [1.0, 2, 5, 10, 20, 50, 100, 200, 500].first { $0 * e >= 55 } ?? 500
        var sub = passo / (String(Int(passo)).first == "5" ? 5 : 10)
        if sub * e < 4 { sub *= 5 }
        let comprimento = horizontal ? tamanho.width : tamanho.height
        let inicio = (-origem / e / sub).rounded(.down) * sub, fim = (comprimento - origem) / e
        var marcas = Path()
        var v = inicio
        while v <= fim {
            let pos = (origem + v * e).rounded() + 0.5
            let maior = abs(v / passo - (v / passo).rounded()) < 1e-6
            let meio = !maior && abs(v * 2 / passo - (v * 2 / passo).rounded()) < 1e-6
            let t = maior ? rg * 0.55 : meio ? 6 : 3.5
            if horizontal {
                marcas.move(to: CGPoint(x: pos, y: rg))
                marcas.addLine(to: CGPoint(x: pos, y: rg - t))
            } else {
                marcas.move(to: CGPoint(x: rg, y: pos))
                marcas.addLine(to: CGPoint(x: rg - t, y: pos))
            }
            if maior {
                let texto = ctx.resolve(Text("\(Int(v.rounded()))").font(.system(size: 8.5)).foregroundStyle(.secondary))
                if horizontal {
                    ctx.draw(texto, at: CGPoint(x: pos + 2, y: 1), anchor: .topLeading)
                } else {
                    var girado = ctx
                    girado.translateBy(x: 1, y: pos - 2)
                    girado.rotate(by: .degrees(-90))
                    girado.draw(texto, at: .zero, anchor: .topLeading)
                }
            }
            v += sub
        }
        ctx.stroke(marcas, with: .color(.secondary), lineWidth: 0.6)
        if let p = ponteiro.mm {
            let pos = (origem + (horizontal ? p.x : p.y) * e).rounded() + 0.5
            var marca = Path()
            if horizontal {
                marca.move(to: CGPoint(x: pos, y: 0))
                marca.addLine(to: CGPoint(x: pos, y: rg))
            } else {
                marca.move(to: CGPoint(x: 0, y: pos))
                marca.addLine(to: CGPoint(x: rg, y: pos))
            }
            ctx.stroke(marca, with: .color(.accentColor), lineWidth: 1)
        }
    }
}
