// Barra de controle (como no protótipo): alinhar, posição e tamanho da seleção — um ou vários objetos —
// e converter forma paramétrica em caminho.
import SwiftUI

nonisolated enum ModoAlinhar: String, CaseIterable, Identifiable, Sendable {
    case esquerda, centroH, direita, centro, topo, centroV, base

    var id: Self { self }

    /// Em Assets.xcassets (ícones do protótipo).
    var icone: String {
        switch self {
        case .esquerda: "alinharEsquerda"
        case .centroH: "alinharCentroH"
        case .direita: "alinharDireita"
        case .centro: "alinharCentro"
        case .topo: "alinharTopo"
        case .centroV: "alinharCentroV"
        case .base: "alinharBase"
        }
    }

    var nome: String {
        switch self {
        case .esquerda: String(localized: "à esquerda")
        case .centroH: String(localized: "ao centro (horizontal)")
        case .direita: String(localized: "à direita")
        case .centro: String(localized: "ao centro (horizontal e vertical)")
        case .topo: String(localized: "ao topo")
        case .centroV: String(localized: "ao centro (vertical)")
        case .base: String(localized: "à base")
        }
    }
}

extension Forma {
    /// Retângulo, elipse e estrela: têm parâmetros e viram caminho para editar os nós.
    nonisolated var parametrica: Bool {
        switch self {
        case .retangulo, .elipse, .estrela: true
        case .caminho, .texto: false
        }
    }
}

extension Documento {
    /// Caixa da seleção, em mm.
    var caixaSelecao: CGRect? {
        let quadros = selecionados.map(\.quadro.standardized)
        guard let primeiro = quadros.first else { return nil }
        return quadros.dropFirst().reduce(primeiro) { $0.union($1) }
    }

    /// Uma peça (um objeto, ou um grupo inteiro): alinha à folha; várias: à caixa da seleção (como no protótipo
    /// e no Illustrator). Um grupo se move inteiro.
    func alinhar(_ modo: ModoAlinhar) {
        guard let caixa = caixaSelecao else { return }
        let pecas = pecasSelecionadas
        let alvo = pecas.count == 1 ? CGRect(origin: .zero, size: Self.pagina) : caixa
        registrar()
        for peca in pecas {
            let b = peca.dropFirst().reduce(peca[0].quadro.standardized) { $0.union($1.quadro.standardized) }
            let dx: Double = switch modo {
            case .esquerda: alvo.minX - b.minX
            case .centroH, .centro: alvo.midX - b.midX
            case .direita: alvo.maxX - b.maxX
            default: 0
            }
            let dy: Double = switch modo {
            case .topo: alvo.minY - b.minY
            case .centroV, .centro: alvo.midY - b.midY
            case .base: alvo.maxY - b.maxY
            default: 0
            }
            let ids = Set(peca.map(\.id))
            for i in objetos.indices where ids.contains(objetos[i].id) {
                objetos[i].quadro = objetos[i].quadro.standardized.offsetBy(dx: dx, dy: dy)
            }
        }
    }

    /// Leva a caixa da seleção para `nova`: move e estica cada objeto na mesma proporção.
    func ajustarSelecao(para nova: CGRect) {
        guard let antiga = caixaSelecao, antiga != nova else { return }
        alterarSelecao { o in o.quadro = Self.esticar(o.quadro.standardized, de: antiga, para: nova) }
    }

    /// Onde fica o quadro `q` quando a caixa `antiga` (que o contém) vira `nova`.
    static func esticar(_ q: CGRect, de antiga: CGRect, para nova: CGRect) -> CGRect {
        let sx = antiga.width > 0 ? nova.width / antiga.width : 1
        let sy = antiga.height > 0 ? nova.height / antiga.height : 1
        return CGRect(x: nova.minX + (q.minX - antiga.minX) * sx, y: nova.minY + (q.minY - antiga.minY) * sy,
                      width: max(q.width * sx, 0.1), height: max(q.height * sy, 0.1))
    }

    /// Retângulo, elipse ou estrela → caminho livre (mesmo contorno), já na seleção direta.
    func converterEmCaminho() {
        guard selecionados.contains(where: { $0.forma.parametrica }) else { return }
        alterarSelecao { o in if o.forma.parametrica { o.definirNos(o.nosAbsolutos) } }
        ferramenta = .direta
    }

    /// Algum texto com letras na seleção (ou sendo digitado) para converter em curvas.
    var temTextoParaCurvas: Bool {
        if objetoEmEdicao.map({ !$0.textoVazio }) == true { return true }
        return selecionados.contains { if case .texto = $0.forma { !$0.textoVazio } else { false } }
    }

    /// Texto → curvas (o Criar contornos do Illustrator, ⇧⌘O): cada texto selecionado, ou o que se digita, vira
    /// um caminho livre com o contorno das letras, o mesmo que a máquina cortaria. Fica no mesmo lugar da pilha,
    /// com as mesmas cores, e o nome continua sendo o texto; os pontos se editam com a seleção direta. Não volta
    /// a ser texto (só com ⌘Z). Devolve quantos textos converteu.
    @discardableResult
    func converterTextoEmCurvas() -> Int {
        if edicaoTexto != nil {
            terminarTexto()
            ferramenta = .selecao
        }
        var curvas: [Objeto.ID: (quadro: CGRect, subcaminhos: [Subcaminho], nome: String)] = [:]
        for objeto in selecionados {
            guard case .texto(let texto) = objeto.forma, let livre = Objeto.caminhoLivre(objeto.caminho.cgPath) else { continue }
            let nome = texto.conteudo.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            curvas[objeto.id] = (livre.quadro, livre.subcaminhos, nome)
        }
        guard !curvas.isEmpty else { return 0 }
        registrar()
        for i in objetos.indices {
            guard let curva = curvas[objetos[i].id] else { continue }
            objetos[i].forma = .caminho(curva.subcaminhos)
            objetos[i].quadro = curva.quadro
            if objetos[i].rotulo == nil, !curva.nome.isEmpty { objetos[i].rotulo = curva.nome }
        }
        if ferramenta == .texto { ferramenta = .selecao }
        return curvas.count
    }

    /// Fecha os subcaminhos abertos (caneta) da seleção.
    func fecharCaminhos() {
        alterarSelecao { o in
            guard case .caminho(var subs) = o.forma else { return }
            for i in subs.indices { subs[i].fechado = true }
            o.forma = .caminho(subs)
        }
    }
}
