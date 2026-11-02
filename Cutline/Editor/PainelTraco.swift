// Seções Traço (estilo do Silhouette Studio: contínua ou picotada; espessura; ponta, canto e
// alinhamento só para traço impresso) e Pathfinder do painel lateral.
import SwiftUI

struct SecaoTraco: View {
    @Bindable var doc: Documento

    private var espessura: Double { doc.selecionados.first?.espessura ?? doc.espessuraPadrao }

    var body: some View {
        let estilo = doc.estiloAtual
        VStack(alignment: .leading, spacing: 8) {
            linha("Estilo") {
                Menu {
                    Picker("Estilo", selection: Binding(get: { estilo.linha }, set: { nova in doc.definirEstilo { $0.linha = nova } })) {
                        ForEach(EstiloLinha.allCases) { e in
                            Label { Text(e.nome) } icon: { Image(nsImage: Icones.linha(e)) }.tag(e)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Image(nsImage: Icones.linha(estilo.linha))
                }
                .menuIndicator(.visible)
                .fixedSize()
                .help(estilo.linha == .continua ? "Contínua" : "Picotada: o corte é tracejado")
            }
            linha("Espessura") {
                HStack(spacing: 6) {
                    TextField("Espessura", value: Binding(get: { espessura }, set: { doc.definirEspessura($0) }),
                              format: .number.precision(.fractionLength(0...2)))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 56)
                    Text("pt").foregroundStyle(.secondary)
                }
            }
            Text(espessura > 0 ? "Este traço também será impresso." : "0 pt aparece na tela, não imprime e indica o corte.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 78)
                .fixedSize(horizontal: false, vertical: true)
            if espessura > 0 {
                linha("Ponta") {
                    segmentos(Ponta.allCases, atual: estilo.ponta, icone: Icones.ponta, dica: \.dica) { v in doc.definirEstilo { $0.ponta = v } }
                }
                linha("Canto") {
                    HStack(spacing: 6) {
                        segmentos(Canto.allCases, atual: estilo.canto, icone: Icones.canto, dica: \.dica) { v in doc.definirEstilo { $0.canto = v } }
                        Text("Lim.").foregroundStyle(.secondary)
                        TextField("Limite", value: Binding(get: { estilo.limiteCanto }, set: { novo in
                            let v = min(max(novo, 1), 500)
                            if v != estilo.limiteCanto { doc.definirEstilo { $0.limiteCanto = v } }
                        }), format: .number.precision(.fractionLength(0...1)))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 40)
                            .help("Limite do canto vivo")
                            .disabled(estilo.canto != .vivo)
                    }
                }
                linha("Alinhar") {
                    segmentos(AlinhamentoTraco.allCases, atual: estilo.alinhamento, icone: Icones.alinhamento, dica: \.dica) { v in
                        doc.definirEstilo { $0.alinhamento = v }
                    }
                }
            }
        }
    }

    private func linha<Conteudo: View>(_ rotulo: LocalizedStringKey, @ViewBuilder conteudo: () -> Conteudo) -> some View {
        HStack(spacing: 8) {
            Text(rotulo)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            conteudo()
            Spacer(minLength: 0)
        }
    }

    private func segmentos<Valor: Hashable & Identifiable>(_ valores: [Valor], atual: Valor, icone: @escaping (Valor) -> NSImage,
                                                           dica: KeyPath<Valor, String>, escolher: @escaping @MainActor @Sendable (Valor) -> Void) -> some View {
        Picker("", selection: Binding(get: { atual }, set: escolher)) {
            ForEach(valores) { v in
                Image(nsImage: icone(v)).help(v[keyPath: dica]).tag(v)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

private extension Ponta {
    var dica: String {
        switch self {
        case .reta: String(localized: "Ponta reta")
        case .arredondada: String(localized: "Ponta arredondada")
        case .projetada: String(localized: "Ponta projetada")
        }
    }
}

private extension Canto {
    var dica: String {
        switch self {
        case .vivo: String(localized: "Canto vivo")
        case .arredondado: String(localized: "Canto arredondado")
        case .chanfrado: String(localized: "Canto chanfrado")
        }
    }
}

private extension AlinhamentoTraco {
    var dica: String {
        switch self {
        case .centro: String(localized: "Traço centralizado")
        case .dentro: String(localized: "Traço por dentro")
        case .fora: String(localized: "Traço por fora")
        }
    }
}

struct SecaoPathfinder: View {
    @Bindable var doc: Documento

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Modos de forma:").font(.caption).foregroundStyle(.secondary)
            botoes(OperacaoPathfinder.allCases.filter(\.ehModoDeForma))
            Text("Pathfinders:").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            botoes(OperacaoPathfinder.allCases.filter { !$0.ehModoDeForma })
        }
    }

    private func botoes(_ operacoes: [OperacaoPathfinder]) -> some View {
        HStack(spacing: 6) {
            ForEach(operacoes) { op in
                Button {
                    if let aviso = doc.pathfinder(op) { withAnimation(.snappy(duration: 0.2)) { doc.aviso = aviso } }
                } label: {
                    Image(nsImage: Icones.pathfinder(op))
                        .frame(width: 40, height: 32)
                        .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .help(op.nome)
            }
        }
    }
}
