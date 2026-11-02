// Fila de trabalhos: a lista (na janela Enviar e no menu da máquina na toolbar) e a pílula da máquina.
import CutlineKit
import SwiftUI

/// Os trabalhos desta sessão, na ordem em que vão para a máquina.
struct ListaFila: View {
    @Environment(Maquina.self) private var maquina

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Fila de trabalhos").font(.headline)
                Spacer()
                if maquina.fila.contains(where: { $0.situacao == .feito }) {
                    Button("Limpar concluídos") { maquina.limparConcluidos() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
            if maquina.fila.isEmpty {
                Text("Nada na fila. Cada Enviar entra aqui; a máquina corta um trabalho por vez.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 2) {
                ForEach(maquina.fila) { trabalho in LinhaFila(trabalho: trabalho) }
            }
            if let parada = maquina.parada, maquina.pendentes > 0 {
                Label("A fila parou em “\(parada.nome)”: tente de novo ou tire da fila para seguir.", image: .pausa)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct LinhaFila: View {
    @Environment(Maquina.self) private var maquina
    let trabalho: Trabalho

    var body: some View {
        HStack(spacing: 10) {
            icone.frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(trabalho.nome).lineLimit(1)
                Text(detalhe)
                    .font(.caption)
                    .foregroundStyle(trabalho.situacao.parou ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            if trabalho.situacao.parou {
                Button("Tentar de novo", image: .atualizar) { maquina.tentarDeNovo(trabalho.id) }
                    .help("Tentar de novo")
            }
            if !trabalho.emAndamento {
                Button("Tirar da fila", image: .fechar) { maquina.remover(trabalho.id) }
                    .help(trabalho.situacao == .feito ? "Tirar da lista" : "Tirar da fila")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(trabalho.emAndamento ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var icone: some View {
        switch trabalho.situacao {
        case .aguardando: Image(.relogio).foregroundStyle(.secondary)
        case .cortando: ProgressView().controlSize(.small)
        case .feito: Image(.concluido).foregroundStyle(.green)
        case .erro: Image(.alerta).foregroundStyle(.orange)
        case .marcasNaoEncontradas: Image(.marcas).foregroundStyle(.orange)
        }
    }

    private var detalhe: String {
        let cores = String(localized: "\(trabalho.camadas.count) cores")
        let extras = [trabalho.registro != nil ? "Print & Cut" : nil, trabalho.comBase ? nil : String(localized: "sem base")].compactMap(\.self)
        let resumo = ([cores] + extras).joined(separator: " · ")
        switch trabalho.situacao {
        case .aguardando:
            let frente = maquina.naFrente(de: trabalho.id)
            return resumo + " · " + (frente == 0 ? String(localized: "é o próximo") : String(localized: "\(frente) na frente"))
        case .cortando(let texto): return texto
        case .feito: return resumo + " · " + String(localized: "cortado")
        case .erro(let texto): return texto
        case .marcasNaoEncontradas: return String(localized: "A máquina não achou as marcas — nada foi cortado.")
        }
    }
}

/// Pílula da máquina na toolbar (● Portrait 4), como no protótipo: o estado e, ao clicar, a máquina e a fila.
struct PilulaMaquina: View {
    @Environment(Maquina.self) private var maquina
    @State private var aberta = false

    var body: some View {
        Button { aberta.toggle() } label: {
            HStack(spacing: 6) {
                Circle().fill(cor).frame(width: 7, height: 7)
                Text(texto).lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .help(maquina.studioAberto ? "Feche o Silhouette Studio: os dois não usam a máquina ao mesmo tempo" as LocalizedStringKey
              : "Máquina e fila de trabalhos")
        .popover(isPresented: $aberta, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 16) {
                AvisoStudio()
                CartaoMaquina()
                ListaFila()
            }
            .padding(16)
            .frame(width: 440)
        }
    }

    private var nome: String { maquina.info == nil ? maquina.atual?.model ?? String(localized: "Máquina") : maquina.nomeModelo }

    private var texto: String {
        if maquina.studioAberto { return String(localized: "Feche o Silhouette Studio") }
        if maquina.parada != nil { return String(localized: "\(nome) · fila parada") }
        let pendentes = maquina.pendentes
        if pendentes > 1 { return String(localized: "\(nome) · \(pendentes) na fila") }
        if pendentes == 1 { return String(localized: "\(nome) · cortando") }
        return nome
    }

    private var cor: Color {
        if maquina.studioAberto || maquina.parada != nil { return .orange }
        switch maquina.estado {
        case .conectada, .enviado: return maquina.info?.status == .unloaded ? .orange : .green
        case .enviando, .conectando: return .accentColor
        case .escolher: return .orange
        case .desconectada, .erro: return .secondary
        }
    }
}

/// Silhouette Studio aberto: o Cutline e ele não conseguem usar a cortadora ao mesmo tempo (janela Enviar e
/// menu da máquina na toolbar).
struct AvisoStudio: View {
    @Environment(Maquina.self) private var maquina

    var body: some View {
        if maquina.studioAberto {
            HStack(alignment: .top, spacing: 10) {
                Image(.alerta)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Feche o Silhouette Studio").font(.headline)
                    Text("O Cutline e o Silhouette Studio não conseguem usar a cortadora ao mesmo tempo. Enquanto o Studio estiver aberto, o Cutline não conecta nem envia; quando ele fechar, a conexão volta sozinha.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Fechar o Silhouette Studio") { maquina.fecharStudio() }
                        .help("Pede para o Studio sair; se houver algo sem salvar, ele pergunta antes")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
