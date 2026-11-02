// Seção Página do menu lateral (como o Page Setup do Silhouette Studio): máquina, base de corte, mídia e
// marcas do Print & Cut. A base e as marcas ficam no documento.
import CutlineKit
import SwiftUI

struct SecaoPagina: View {
    @Bindable var doc: Documento
    @Environment(Maquina.self) private var maquina

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 9) {
                GridRow {
                    rotulo("Máquina")
                    HStack(spacing: 6) {
                        Circle().fill(conectada ? Color.green : .secondary).frame(width: 7, height: 7)
                        Text(nomeMaquina).lineLimit(1)
                        Spacer(minLength: 0)
                        if !conectada {
                            Button("Conectar") { Task { await maquina.conectar() } }
                                .controlSize(.small)
                        }
                    }
                }
                GridRow {
                    rotulo("Base de corte")
                    // As bases que o Studio oferece para esta máquina.
                    Picker("Base de corte", selection: Binding(get: { doc.base(para: maquina.hardware) }, set: { doc.definirBase($0) })) {
                        ForEach(maquina.hardware.supportedCuttingMats, id: \.self) { base in
                            Text(base.nome).tag(base)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
                GridRow {
                    rotulo("Mídia")
                    Text("A4 · 210 × 297 mm")
                }
                GridRow {
                    rotulo("Print & Cut")
                    Toggle("Marcas de registro", isOn: Binding(get: { doc.marcas }, set: { if $0 != doc.marcas { doc.alternarMarcas() } }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                if doc.marcas {
                    GridRow {
                        rotulo("Margem")
                        HStack(spacing: 4) {
                            campoMM(Binding(get: { doc.configMarcas.margem ?? doc.configMarcas.esquerda }, set: { nova in
                                var config = doc.configMarcas
                                (config.esquerda, config.topo, config.direita, config.baixo) = (nova, nova, nova, nova)
                                doc.definirMarcas(config)
                            }), faixa: 5...50)
                            Menu("Como") {
                                Button("Como o Cutline (15 mm, cantoneiras de 20 mm)") { doc.definirMarcas(.padrao) }
                                Button("Como o Silhouette Studio (5/8 pol., cantoneiras de 20 mm)") { doc.definirMarcas(.studio) }
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("A margem e as cantoneiras têm de ser as mesmas da folha impressa")
                        }
                    }
                    GridRow {
                        rotulo("Cantoneiras")
                        campoMM(Binding(get: { doc.configMarcas.comprimento }, set: { novo in
                            var config = doc.configMarcas
                            config.comprimento = novo
                            doc.definirMarcas(config)
                        }), faixa: 5...50)
                    }
                }
            }
            .font(.callout)
            if doc.marcas, doc.configMarcas.margem == nil {
                Text("As margens das marcas vieram diferentes em cada lado (do arquivo do Studio); mudar aqui iguala as quatro.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(doc.comBase
                 ? "A folha vai colada na base, no canto superior esquerdo da grade."
                 : "Sem base, a máquina puxa a folha direto: use mídia com fundo firme (adesivo, cartão) e encoste na guia.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Campo em mm com setas (0,5 mm por clique).
    private func campoMM(_ valor: Binding<Double>, faixa: ClosedRange<Double>) -> some View {
        let limitado = Binding(get: { valor.wrappedValue }, set: { valor.wrappedValue = min(max($0, faixa.lowerBound), faixa.upperBound) })
        return HStack(spacing: 2) {
            TextField("", value: limitado, format: .number.precision(.fractionLength(0...3)))
                .labelsHidden()
                .frame(width: 54)
                .multilineTextAlignment(.trailing)
            Text("mm").foregroundStyle(.secondary)
            Stepper("", value: limitado, in: faixa, step: 0.5)
                .labelsHidden()
                .controlSize(.mini)
        }
        .controlSize(.small)
    }

    private func rotulo(_ texto: LocalizedStringKey) -> some View {
        Text(texto).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private var conectada: Bool {
        switch maquina.estado {
        case .conectada, .enviando, .enviado: true
        default: false
        }
    }

    private var nomeMaquina: String {
        if maquina.info != nil { return maquina.nomeModelo }
        return maquina.atual?.model ?? String(localized: "Nenhuma conectada")
    }

}

extension CuttingMat {
    /// Como aparece no painel Página e na janela Enviar.
    var nome: String {
        switch self {
        case .none: String(localized: "Sem base")
        case .cameo12x12: String(localized: "Base 12 × 12 pol.")
        case .cameo12x24: String(localized: "Base 12 × 24 pol.")
        case .portrait8x12: String(localized: "Base 8 × 12 pol.")
        case .cameoPlus15x15: String(localized: "Base 15 × 15 pol.")
        case .cameoPro24x24: String(localized: "Base 24 × 24 pol.")
        case .portrait8_5x12: String(localized: "Base 8,5 × 12 pol.")
        case .mini6x8: String(localized: "Base 6 × 8 pol.")
        case .electrostatic12x12: String(localized: "Base eletrostática 12 × 12 pol.")
        case .electrostatic8_5x12: String(localized: "Base eletrostática 8,5 × 12 pol.")
        case .pixscanCameo, .pixscanPortrait: String(localized: "Base PixScan")
        }
    }
}
