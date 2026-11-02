// Copiar, recortar e colar objetos (⌘C, ⌘X, ⌘V; também pelo menu Editar e pelo clique direito), inclusive de
// uma janela do Cutline para outra: vão para a área de transferência do macOS num tipo próprio, com as imagens
// que usam. Colar põe na camada ativa, no mesmo lugar da folha (ou 5 mm abaixo e à direita, quantas vezes for
// preciso, se ali já houver um igual) e seleciona. ⌘ + seta duplica a seleção encostada nela, para aquele
// lado, como no Silhouette Studio.
import AppKit

nonisolated struct Recorte: Codable {
    var objetos: [Objeto]
    var imagens: [String: Data]
}

extension NSPasteboard.PasteboardType {
    static let objetosCutline = Self("io.github.joaogmcorrea.cutline.objetos")
}

nonisolated enum Direcao: Sendable {
    case esquerda, direita, cima, baixo
}

extension Documento {
    /// A geral do macOS (nos testes escondidos, uma só do Cutline, para não mexer na do owner).
    private var area: NSPasteboard {
        #if DEBUG
        if let teste = Depuracao.areaDeTeste { return teste }
        #endif
        return .general
    }

    func copiarSelecao() {
        let copiados = objetosEmOrdem.filter { selecao.contains($0.id) }
        let chaves = Set(copiados.compactMap(\.imagem?.chave))
        guard !copiados.isEmpty,
              let dados = try? PropertyListEncoder().encode(Recorte(objetos: copiados, imagens: imagens.filter { chaves.contains($0.key) }))
        else { return }
        area.clearContents()
        area.setData(dados, forType: .objetosCutline)
    }

    func recortarSelecao() {
        copiarSelecao()
        apagarSelecao()
    }

    var podeColar: Bool { area.availableType(from: [.objetosCutline]) != nil }

    func colar() {
        guard let dados = area.data(forType: .objetosCutline),
              let recorte = try? PropertyListDecoder().decode(Recorte.self, from: dados), !recorte.objetos.isEmpty else { return }
        let igual = { (a: CGRect, b: CGRect) in
            abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01 && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
        }
        var deslocamento = 0.0
        while deslocamento < 250, recorte.objetos.contains(where: { colado in
            objetos.contains { igual($0.quadro, colado.quadro.offsetBy(dx: deslocamento, dy: deslocamento)) }
        }) { deslocamento += 5 }
        inserirImportados(Objeto.copias(recorte.objetos, deslocamento: CGSize(width: deslocamento, height: deslocamento)),
                          imagens: recorte.imagens)
    }

    /// Uma cópia da seleção encostada nela, do lado escolhido.
    func duplicarAoLado(_ direcao: Direcao) {
        guard let caixa = caixaSelecao else { return }
        switch direcao {
        case .esquerda: duplicarSelecao(deslocamento: CGSize(width: -caixa.width, height: 0))
        case .direita: duplicarSelecao(deslocamento: CGSize(width: caixa.width, height: 0))
        case .cima: duplicarSelecao(deslocamento: CGSize(width: 0, height: -caixa.height))
        case .baixo: duplicarSelecao(deslocamento: CGSize(width: 0, height: caixa.height))
        }
    }
}
