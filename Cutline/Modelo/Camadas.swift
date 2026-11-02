// Camadas, como no Illustrator: a de cima no painel é desenhada por último; cada uma pode ser
// ocultada (some da tela e do corte) ou travada (não seleciona). Objetos também ocultam e travam.
import SwiftUI

nonisolated struct Camada: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var nome: String
    /// Índice em `Camada.cores` (cor da barra e da seleção).
    var cor: Int
    var visivel = true
    var travada = false
    /// Mostra os objetos da camada no painel.
    var aberta = true

    /// As do protótipo.
    static let cores: [Color] = [0x4F8DF5, 0xE5484D, 0x30A46C, 0x8E4EC6, 0xF5A524, 0xE93D82, 0x12A594].map {
        Color(.sRGB, red: Double(($0 >> 16) & 0xFF) / 255, green: Double(($0 >> 8) & 0xFF) / 255, blue: Double($0 & 0xFF) / 255)
    }

    var corDaBarra: Color { Self.cores[((cor % Self.cores.count) + Self.cores.count) % Self.cores.count] }
}

extension Documento {
    /// A camada do objeto (a de cima, se a dele não existir mais).
    func camada(de objeto: Objeto) -> Camada {
        camadas.first { $0.id == objeto.camada } ?? camadas[0]
    }

    func visivel(_ objeto: Objeto) -> Bool { !objeto.oculto && camada(de: objeto).visivel }

    /// Travado ou oculto: não seleciona nem mexe.
    func intocavel(_ objeto: Objeto) -> Bool { objeto.travado || camada(de: objeto).travada || !visivel(objeto) }

    /// De trás para a frente: camadas de baixo primeiro; dentro da camada, a ordem dos objetos.
    var objetosEmOrdem: [Objeto] {
        let posicao = Dictionary(uniqueKeysWithValues: camadas.enumerated().map { ($0.element.id, $0.offset) })
        return objetos.enumerated()
            .sorted { a, b in
                let ca = posicao[a.element.camada ?? camadas[0].id] ?? 0, cb = posicao[b.element.camada ?? camadas[0].id] ?? 0
                return ca != cb ? ca > cb : a.offset < b.offset
            }
            .map(\.element)
    }

    func objetos(da camada: Camada) -> [Objeto] { objetos.filter { self.camada(de: $0).id == camada.id } }

    // MARK: Edição de camadas (cada uma é um passo de desfazer)

    func alterarCamada(_ id: Camada.ID, _ mudar: (inout Camada) -> Void) {
        guard let i = camadas.firstIndex(where: { $0.id == id }) else { return }
        registrar()
        mudar(&camadas[i])
        // Oculta ou travada não fica selecionada.
        selecao = selecao.filter { id in objetos.first { $0.id == id }.map { !intocavel($0) } ?? false }
    }

    func alterarObjeto(_ id: Objeto.ID, _ mudar: (inout Objeto) -> Void) {
        guard let i = objetos.firstIndex(where: { $0.id == id }) else { return }
        registrar()
        mudar(&objetos[i])
        if intocavel(objetos[i]) { selecao.remove(id) }
    }

    func novaCamada() {
        registrar()
        let nova = Camada(nome: String(localized: "Camada \(camadas.count + 1)"), cor: camadas.count)
        camadas.insert(nova, at: 0)
        camadaAtiva = nova.id
    }

    /// Apaga a camada ativa e os objetos dela (sempre fica ao menos uma).
    func apagarCamadaAtiva() {
        guard camadas.count > 1, let alvo = camadas.first(where: { $0.id == camadaAtiva }) else { return }
        registrar()
        let ids = Set(objetos(da: alvo).map(\.id))
        objetos.removeAll { ids.contains($0.id) }
        selecao.subtract(ids)
        camadas.removeAll { $0.id == alvo.id }
        camadaAtiva = camadas[0].id
    }

    func moverSelecaoParaCamadaAtiva() {
        guard !selecao.isEmpty else { return }
        alterarSelecao { $0.camada = camadaAtiva }
    }

    /// Seleciona tudo o que dá para mexer na camada (e a torna ativa).
    func selecionarCamada(_ camada: Camada) {
        camadaAtiva = camada.id
        selecao = Set(objetos(da: camada).filter { !intocavel($0) }.map(\.id))
    }
}
