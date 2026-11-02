// Peça flutuante de vidro sobre a tela: ferramentas (esquerda). A barra de controle fica em BarraControle.swift.
import SwiftUI

/// Cápsula vertical de ferramentas, como a do Illustrator (atalhos de uma letra).
struct PainelFerramentas: View {
    @Bindable var doc: Documento

    private let grupos: [[Ferramenta]] = [[.selecao, .direta], [.caneta, .texto], [.retangulo, .elipse, .estrela], [.vetorizar, .mao]]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(grupos.indices, id: \.self) { g in
                if g > 0 { Divider().frame(width: 22).padding(.vertical, 2) }
                ForEach(grupos[g]) { ferramenta in botao(ferramenta) }
            }
        }
        .padding(6)
        .glassEffect(.regular, in: .capsule)
    }

    private func botao(_ ferramenta: Ferramenta) -> some View {
        let ativa = doc.ferramenta == ferramenta
        return Button {
            doc.ferramenta = ferramenta
        } label: {
            Image(ferramenta.icone)
                .resizable()
                .frame(width: 20, height: 20)
                .frame(width: 36, height: 36)
                .foregroundStyle(ativa ? Color.white : Color.primary)
                .background(Circle().fill(ativa ? Color.accentColor : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("\(ferramenta.nome) (\(ferramenta.tecla.uppercased()))")
    }
}

extension Ferramenta {
    /// Ícones do protótipo (Assets.xcassets).
    var icone: String {
        switch self {
        case .selecao: "ferramentaSelecao"
        case .direta: "ferramentaDireta"
        case .caneta: "ferramentaCaneta"
        case .texto: "ferramentaTexto"
        case .retangulo: "ferramentaRetangulo"
        case .elipse: "ferramentaElipse"
        case .estrela: "ferramentaEstrela"
        case .vetorizar: "ferramentaImagem"
        case .mao: "ferramentaMao"
        }
    }
}
