// Print & Cut: quando a máquina não acha as marcas, uma janela sobre a Enviar com a ilustração animada
// (folha encostando no canto da base e o sensor procurando as três marcas), os defeitos mais comuns e o
// atalho para tentar ler de novo.
import SwiftUI

struct JanelaMarcas: View {
    let trabalho: Trabalho
    @Environment(Maquina.self) private var maquina
    @Environment(\.dismiss) private var fechar

    private struct Dica: Identifiable {
        let icone: ImageResource
        let titulo: String
        let texto: String
        var id: String { titulo }
    }

    private var dicas: [Dica] {
        [Dica(icone: .cantoFolha, titulo: String(localized: "Folha no canto, reta"),
              texto: trabalho.comBase
                ? String(localized: "Encoste no canto superior esquerdo da grade da base, com o quadrado preto em cima à esquerda — ele entra primeiro na máquina.")
                : String(localized: "Encoste a folha na guia da esquerda, reta, com o quadrado preto em cima à esquerda — ele entra primeiro na máquina.")),
         Dica(icone: .imprimir, titulo: String(localized: "Impressa em 100 %"),
              texto: String(localized: "Sem “ajustar ao papel”. O quadrado deve ficar a 15 mm das bordas da folha — dá para conferir com uma régua.")),
         Dica(icone: .contraste, titulo: String(localized: "Marcas bem pretas"),
              texto: String(localized: "Sem modo rascunho ou economia de tinta. Papel brilhante ou laminado reflete a luz e esconde as marcas.")),
         Dica(icone: .luz, titulo: String(localized: "Luz e área livre"),
              texto: String(localized: "Luz forte sobre a máquina (sol, luminária) atrapalha o sensor. Nada impresso perto das marcas (a área hachurada na tela)."))]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 28) {
                AnimacaoMarcas(comBase: trabalho.comBase)
                    .frame(width: 290)
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("A máquina não achou as marcas")
                            .font(.title2.weight(.semibold))
                        Text("Nada foi cortado. Se precisar acertar a folha, descarregue a base, ajuste e carregue de novo.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(dicas) { dica in
                        HStack(alignment: .top, spacing: 12) {
                            Image(dica.icone)
                                .resizable()
                                .frame(width: 18, height: 18)
                                .foregroundStyle(.tint)
                                .frame(width: 30, height: 30)
                                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(dica.titulo).fontWeight(.semibold)
                                Text(dica.texto)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(28)
            HStack(spacing: 12) {
                Button("Tirar da fila") {
                    maquina.remover(trabalho.id)
                    fechar()
                }
                Spacer()
                Button("Fechar") { fechar() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    maquina.tentarDeNovo(trabalho.id)
                    fechar()
                } label: {
                    Label("Tentar ler de novo", image: .atualizar)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
        .frame(width: 780)
    }
}

/// A folha encosta no canto da base (sem base: na guia) e o sensor da máquina passa pelo quadrado e pelas
/// duas cantoneiras, que acendem quando encontradas. Em laço de 8 s.
struct AnimacaoMarcas: View {
    let comBase: Bool
    @State private var inicio = Date()

    private static let ciclo = 8.0

    var body: some View {
        TimelineView(.animation) { contexto in
            let t = contexto.date.timeIntervalSince(inicio).truncatingRemainder(dividingBy: Self.ciclo)
            VStack(spacing: 12) {
                Canvas { ctx, tamanho in desenhar(&ctx, tamanho: tamanho, t: t) }
                    .frame(width: 290, height: 290 * 262 / 300)
                Text(legenda(t))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(height: 38, alignment: .top)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: legenda(t))
            }
        }
    }

    private func legenda(_ t: Double) -> String {
        if t < 2.4 {
            return comBase ? String(localized: "Encoste a folha no canto superior esquerdo da base, bem reta.")
                : String(localized: "Encoste a folha na guia da esquerda, bem reta.")
        }
        if t < 6.6 { return String(localized: "A máquina procura o quadrado e as duas cantoneiras…") }
        return String(localized: "Achou as três marcas: aí ela corta em cima da impressão.")
    }

    // MARK: Desenho (unidades de 300 × 262)

    private static let base = CGRect(x: 72, y: 46, width: 156, height: 214)
    private static let folha = CGSize(width: 148, height: 206)
    /// Marcas maiores que as de verdade, para aparecerem na ilustração.
    private static let recuo = 12.0, quadrado = 10.0, cantoneira = 24.0, espessura = 2.6

    private func desenhar(_ ctx: inout GraphicsContext, tamanho: CGSize, t: Double) {
        let e = min(tamanho.width / 300, tamanho.height / 262)
        ctx.scaleBy(x: e, y: e)
        let base = Self.base
        let origemFolha = CGPoint(x: base.minX + 4, y: base.minY + 4)

        // Base de corte (plástico com grade) ou só a guia da máquina.
        if comBase {
            ctx.fill(Path(roundedRect: base, cornerRadius: 5), with: .color(Color(red: 0.62, green: 0.76, blue: 0.9).opacity(0.55)))
            var grade = Path()
            var x = base.minX + 4
            while x <= base.maxX - 4 { grade.move(to: CGPoint(x: x, y: base.minY + 4)); grade.addLine(to: CGPoint(x: x, y: base.maxY - 4)); x += 18.4 }
            var y = base.minY + 4
            while y <= base.maxY - 4 { grade.move(to: CGPoint(x: base.minX + 4, y: y)); grade.addLine(to: CGPoint(x: base.maxX - 4, y: y)); y += 18.4 }
            ctx.stroke(grade, with: .color(Color(red: 0.25, green: 0.45, blue: 0.7).opacity(0.35)), lineWidth: 0.6)
        } else {
            var guia = Path()
            guia.move(to: CGPoint(x: origemFolha.x - 3, y: base.minY))
            guia.addLine(to: CGPoint(x: origemFolha.x - 3, y: base.maxY))
            ctx.stroke(guia, with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }

        // Folha chegando ao canto: torta e deslocada → encaixada.
        let chegada = Self.suave((t - 0.2) / 1.6)
        let deslocamento = CGSize(width: 18 * (1 - chegada), height: 26 * (1 - chegada))
        let giro = Angle.degrees(6 * (1 - chegada))
        var folha = ctx
        folha.translateBy(x: origemFolha.x + deslocamento.width, y: origemFolha.y + deslocamento.height)
        folha.rotate(by: giro)
        let caixa = CGRect(origin: .zero, size: Self.folha)
        var sombra = folha
        sombra.addFilter(.shadow(color: .black.opacity(0.18), radius: 3, y: 1.5))
        sombra.fill(Path(caixa), with: .color(.white))
        // Arte impressa com o contorno de corte por cima.
        let adesivo = CGRect(x: 34, y: 52, width: 62, height: 46)
        folha.fill(Path(roundedRect: adesivo, cornerRadius: 10), with: .color(Color(red: 0.98, green: 0.55, blue: 0.62)))
        folha.stroke(Path(roundedRect: adesivo.insetBy(dx: -4, dy: -4), cornerRadius: 13), with: .color(.red), style: StrokeStyle(lineWidth: 0.9, dash: [3, 2]))
        let circulo = CGRect(x: 72, y: 118, width: 44, height: 44)
        folha.fill(Path(ellipseIn: circulo), with: .color(Color(red: 0.99, green: 0.82, blue: 0.3)))
        folha.stroke(Path(ellipseIn: circulo.insetBy(dx: -4, dy: -4)), with: .color(.red), style: StrokeStyle(lineWidth: 0.9, dash: [3, 2]))
        for retangulo in Self.marcas { folha.fill(Path(retangulo), with: .color(.black)) }

        // Canto da base em destaque enquanto a folha encosta; verde quando encaixou.
        if t < 2.6 {
            let encaixou = t > 1.8
            var canto = Path()
            canto.move(to: CGPoint(x: origemFolha.x - 3, y: origemFolha.y + 34))
            canto.addLine(to: CGPoint(x: origemFolha.x - 3, y: origemFolha.y - 3))
            canto.addLine(to: CGPoint(x: origemFolha.x + 34, y: origemFolha.y - 3))
            let pulso = 0.55 + 0.45 * sin(t * 6)
            ctx.stroke(canto, with: .color((encaixou ? Color.green : .accentColor).opacity(encaixou ? 1 : pulso)),
                       style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
        }

        // Sensor: passa pelas três marcas; cada uma acende ao ser encontrada.
        let alvos = Self.alvos.map { CGPoint(x: $0.x + origemFolha.x, y: $0.y + origemFolha.y) }
        let casa = CGPoint(x: 236, y: 40)
        let trechos: [(inicio: Double, fim: Double, de: CGPoint, para: CGPoint)] = [
            (2.4, 3.2, casa, alvos[0]), (3.7, 4.5, alvos[0], alvos[1]), (5.0, 6.1, alvos[1], alvos[2]),
        ]
        let achou = [3.2, 4.5, 6.1].map { t >= $0 }
        var sensor: CGPoint? = nil
        if t >= 2.4, t < 7.6 {
            sensor = alvos[2]
            for trecho in trechos where t < trecho.fim {
                let p = t < trecho.inicio ? 0 : Self.suave((t - trecho.inicio) / (trecho.fim - trecho.inicio))
                sensor = CGPoint(x: trecho.de.x + (trecho.para.x - trecho.de.x) * p, y: trecho.de.y + (trecho.para.y - trecho.de.y) * p)
                break
            }
        }
        for (i, alvo) in alvos.enumerated() where achou[i] && t < 7.6 {
            let anel = Path(ellipseIn: CGRect(x: alvo.x - 11, y: alvo.y - 11, width: 22, height: 22))
            ctx.fill(anel, with: .color(.green.opacity(0.18)))
            ctx.stroke(anel, with: .color(.green), lineWidth: 1.6)
        }

        // Máquina por cima (a folha entra por baixo dela), com o carro que leva o sensor.
        let corpo = CGRect(x: 40, y: 4, width: 220, height: 40)
        ctx.fill(Path(roundedRect: corpo, cornerRadius: 12), with: .color(Color(white: 0.32)))
        ctx.fill(Path(roundedRect: corpo.insetBy(dx: 10, dy: 8).offsetBy(dx: 0, dy: -2), cornerRadius: 6), with: .color(Color(white: 0.42)))
        var fenda = Path()
        fenda.move(to: CGPoint(x: corpo.minX + 14, y: corpo.maxY - 3))
        fenda.addLine(to: CGPoint(x: corpo.maxX - 14, y: corpo.maxY - 3))
        ctx.stroke(fenda, with: .color(.black.opacity(0.55)), lineWidth: 2)
        let carroX = sensor?.x ?? casa.x
        let carro = CGRect(x: carroX - 9, y: corpo.maxY - 12, width: 18, height: 12)
        ctx.fill(Path(roundedRect: carro, cornerRadius: 3), with: .color(Color(white: 0.85)))
        if let sensor {
            var feixe = Path()
            feixe.move(to: CGPoint(x: carro.midX - 3, y: carro.maxY))
            feixe.addLine(to: CGPoint(x: sensor.x - 7, y: sensor.y))
            feixe.addLine(to: CGPoint(x: sensor.x + 7, y: sensor.y))
            feixe.addLine(to: CGPoint(x: carro.midX + 3, y: carro.maxY))
            feixe.closeSubpath()
            ctx.fill(feixe, with: .color(Color.accentColor.opacity(0.16)))
            let brilho = Path(ellipseIn: CGRect(x: sensor.x - 8, y: sensor.y - 8, width: 16, height: 16))
            ctx.fill(brilho, with: .radialGradient(Gradient(colors: [Color.accentColor.opacity(0.9), Color.accentColor.opacity(0)]),
                                                     center: sensor, startRadius: 0, endRadius: 8))
        }
    }

    /// Marcas da folha da ilustração (no sistema da folha).
    private static var marcas: [CGRect] {
        let f = folha, r = recuo, q = quadrado, l = cantoneira, e = espessura
        return [CGRect(x: r, y: r, width: q, height: q),
                CGRect(x: f.width - r - l, y: r, width: l, height: e), CGRect(x: f.width - r - e, y: r, width: e, height: l),
                CGRect(x: r, y: f.height - r - e, width: l, height: e), CGRect(x: r, y: f.height - r - l, width: e, height: l)]
    }

    /// Centro do quadrado e cantos das duas cantoneiras (no sistema da folha).
    private static var alvos: [CGPoint] {
        let f = folha, r = recuo
        return [CGPoint(x: r + quadrado / 2, y: r + quadrado / 2),
                CGPoint(x: f.width - r - 4, y: r + 4),
                CGPoint(x: r + 4, y: f.height - r - 4)]
    }

    private static func suave(_ x: Double) -> Double {
        let v = min(max(x, 0), 1)
        return v * v * (3 - 2 * v)
    }
}
