// Ajuste da janela Enviar: slider horizontal compacto (uma linha por ajuste), com a semântica do
// mostrador aprovado — trilha verde; entalhe no valor do material; acima dele, degradê verde → amarelo
// → vermelho; o pino é a única peça de vidro. Ajuste: arrastar, clicar na trilha, digitar o valor,
// setas (⇧ = 5), Home/End.
import SwiftUI

struct Ajuste<Icone: View>: View {
    let titulo: LocalizedStringKey
    let unidade: LocalizedStringKey
    let faixa: ClosedRange<Int>
    @Binding var valor: Int
    /// Valor do material escolhido.
    let padrao: Int
    @ViewBuilder let icone: () -> Icone

    @Environment(\.colorScheme) private var esquema
    @State private var arrastando = false
    @State private var sobrePino = false
    @FocusState private var focado: Bool

    private let alturaTrilha = 6.0
    private let pino = 18.0

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                icone()
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                Text(titulo)
            }
            .frame(width: 104, alignment: .leading)

            trilha
                .frame(height: 26)

            TextField(titulo, value: Binding(get: { valor }, set: { valor = limitar($0) }), format: .number)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 44)

            Text(unidade)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)

            Button {
                valor = padrao
            } label: {
                HStack(spacing: 4) {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                    Text("material \(padrao)").monospacedDigit()
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Voltar ao valor do material (\(padrao))")
            .opacity(valor == padrao ? 0 : 1)
            .disabled(valor == padrao)
            .frame(width: 86, alignment: .leading)
        }
        .font(.callout)
    }

    // MARK: Trilha

    private var trilha: some View {
        GeometryReader { geo in
            let largura = geo.size.width - pino
            let x = { (v: Int) in pino / 2 + largura * fracao(v) }
            ZStack(alignment: .leading) {
                Canvas { ctx, tamanho in desenhar(&ctx, tamanho, x: x) }
                Circle()
                    .fill(.clear)
                    .frame(width: pino, height: pino)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
                    .background(Circle().fill(paleta.halo).frame(width: 28, height: 28).opacity(arrastando ? 1 : 0))
                    .scaleEffect(arrastando ? 1.2 : (sobrePino ? 1.08 : 1))
                    .animation(.spring(duration: 0.18), value: arrastando)
                    .animation(.spring(duration: 0.18), value: sobrePino)
                    .onHover { sobrePino = $0 }
                    .position(x: x(valor), y: geo.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { arraste in
                        arrastando = true
                        focado = true
                        valor = valor(em: arraste.location.x, largura: largura)
                    }
                    .onEnded { _ in arrastando = false }
            )
            .pointerStyle(arrastando ? .grabActive : .grabIdle)
        }
        .focusable(interactions: .edit)
        .focusEffectDisabled()
        .focused($focado)
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5).padding(-3).opacity(focado ? 1 : 0))
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .home, .end], phases: .down) { tecla in
            let passo = tecla.modifiers.contains(.shift) ? 5 : 1
            switch tecla.key {
            case .rightArrow, .upArrow: valor = limitar(valor + passo)
            case .leftArrow, .downArrow: valor = limitar(valor - passo)
            case .home: valor = faixa.lowerBound
            default: valor = faixa.upperBound
            }
            return .handled
        }
        .help(Text(titulo) + Text(verbatim: ": \(faixa.lowerBound)–\(faixa.upperBound)"))
    }

    private func desenhar(_ ctx: inout GraphicsContext, _ tamanho: CGSize, x: (Int) -> Double) {
        let meio = tamanho.height / 2
        let faixaTrilha = { (de: Double, ate: Double) in
            Path(roundedRect: CGRect(x: de, y: meio - alturaTrilha / 2, width: max(ate - de, 0), height: alturaTrilha),
                 cornerRadius: alturaTrilha / 2)
        }
        let inicio = x(faixa.lowerBound) - alturaTrilha / 2, fim = x(faixa.upperBound) + alturaTrilha / 2
        ctx.fill(faixaTrilha(inicio, fim), with: .color(paleta.sulco))

        let xValor = x(valor), xPadrao = x(padrao)
        if valor > faixa.lowerBound {
            // verde até o padrão (ou até o valor, se abaixo dele)
            let fimVerde = min(xValor, xPadrao)
            let verdeNoPadrao = RGB.misturaSRGB(paleta.fraco, paleta.valor, fracao(min(valor, padrao)))
            ctx.fill(faixaTrilha(inicio, max(fimVerde, inicio + alturaTrilha)),
                     with: .linearGradient(Gradient(colors: [paleta.fraco.cor, verdeNoPadrao.cor]),
                                           startPoint: CGPoint(x: inicio, y: meio), endPoint: CGPoint(x: fimVerde, y: meio)))
            // acima do padrão: verde → amarelo → vermelho (OKLab), vermelho pleno no valor
            if valor > padrao {
                let paradas = (0...12).map { i -> Gradient.Stop in
                    let t = Double(i) / 12
                    let cor = t < 0.5 ? RGB.misturaOKLab(verdeNoPadrao, paleta.amarelo, t / 0.5)
                                      : RGB.misturaOKLab(paleta.amarelo, paleta.acima, (t - 0.5) / 0.5)
                    return Gradient.Stop(color: cor.cor, location: t)
                }
                ctx.fill(Path(CGRect(x: xPadrao, y: meio - alturaTrilha / 2, width: xValor - xPadrao, height: alturaTrilha)),
                         with: .linearGradient(Gradient(stops: paradas), startPoint: CGPoint(x: xPadrao, y: meio),
                                               endPoint: CGPoint(x: xValor, y: meio)))
            }
        }
        // Entalhe do limite do material: sempre visível, alguns pontos à direita do pino quando ele está
        // no valor do material (marca onde começa o excesso).
        let xEntalhe = xPadrao + pino / 2 + 3
        var entalhe = Path()
        entalhe.move(to: CGPoint(x: xEntalhe, y: meio - 7))
        entalhe.addLine(to: CGPoint(x: xEntalhe, y: meio + 7))
        ctx.stroke(entalhe, with: .color(.primary.opacity(0.55)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
    }

    // MARK: Apoio

    private func fracao(_ v: Int) -> Double {
        Double(limitar(v) - faixa.lowerBound) / Double(max(1, faixa.upperBound - faixa.lowerBound))
    }

    private func valor(em x: Double, largura: Double) -> Int {
        let fr = min(max((x - pino / 2) / max(largura, 1), 0), 1)
        return faixa.lowerBound + Int((fr * Double(faixa.upperBound - faixa.lowerBound)).rounded())
    }

    private func limitar(_ v: Int) -> Int { min(max(v, faixa.lowerBound), faixa.upperBound) }

    private var paleta: PaletaAjuste { esquema == .dark ? .escura : .clara }
}

/// Cores do ajuste (verde, amarelo e vermelho do sistema, claro e escuro).
private struct PaletaAjuste {
    let valor, fraco, amarelo, acima: RGB
    let sulco: Color
    let halo: Color

    static let clara = PaletaAjuste(valor: RGB(0x34C759), fraco: RGB(0xA3E6B4), amarelo: RGB(0xFFCC00),
                                    acima: RGB(0xFF3B30), sulco: .black.opacity(0.09),
                                    halo: Color(red: 0.2, green: 0.78, blue: 0.35).opacity(0.2))
    static let escura = PaletaAjuste(valor: RGB(0x30D158), fraco: RGB(0x86DFA0), amarelo: RGB(0xFFD60A),
                                     acima: RGB(0xFF453A), sulco: .white.opacity(0.13),
                                     halo: Color(red: 0.19, green: 0.82, blue: 0.35).opacity(0.26))
}
