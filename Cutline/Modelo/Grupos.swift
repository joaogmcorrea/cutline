// Grupos e ordem dos objetos, como no Illustrator. ⌘G agrupa a seleção: os objetos vão para a camada do que
// está mais à frente e ficam juntos na pilha, no lugar dele. ⇧⌘G desfaz o grupo de fora. Grupos se aninham:
// `Objeto.grupos` guarda os ids do de fora para o de dentro. Clicar num objeto de um grupo seleciona o grupo
// inteiro (o de fora); o duplo clique, a seleção direta e o painel Camadas pegam só ele. Organizar (⇧⌘] ⌘]
// ⌘[ ⇧⌘[) move a seleção na pilha da própria camada, cada grupo como uma peça só.
import Foundation

nonisolated enum Organizar: CaseIterable, Identifiable, Sendable {
    case frente, avancar, recuar, tras

    var id: Self { self }

    var nome: String {
        switch self {
        case .frente: String(localized: "Trazer para a frente")
        case .avancar: String(localized: "Avançar")
        case .recuar: String(localized: "Recuar")
        case .tras: String(localized: "Enviar para trás")
        }
    }
}

/// Um grupo de fora inteiro (ou um objeto solto) na pilha de uma camada.
nonisolated struct PecaPilha {
    var objetos: [Objeto]
    var selecionada: Bool
}

extension Objeto {
    /// Cópias com ids novos, deslocadas; os grupos também ganham ids novos (as cópias de um grupo formam outro).
    static func copias(_ originais: [Objeto], deslocamento: CGSize = .zero) -> [Objeto] {
        var novos: [UUID: UUID] = [:]
        return originais.map { original in
            var copia = original
            copia.id = UUID()
            copia.grupos = original.grupos.map { grupo in
                if let novo = novos[grupo] { return novo }
                let novo = UUID()
                novos[grupo] = novo
                return novo
            }
            copia.quadro = original.quadro.offsetBy(dx: deslocamento.width, dy: deslocamento.height)
            return copia
        }
    }
}

extension Documento {
    /// O que um clique no objeto seleciona: o grupo de fora dele inteiro (sem os ocultos e travados), ou só ele.
    func unidade(de id: Objeto.ID) -> Set<Objeto.ID> {
        guard let grupo = objetos.first(where: { $0.id == id })?.grupos.first else { return [id] }
        return Set(objetos.filter { $0.grupos.first == grupo && !intocavel($0) }.map(\.id)).union([id])
    }

    /// Os objetos e os grupos de fora deles inteiros (seleção por área).
    func comGrupos(_ ids: Set<Objeto.ID>) -> Set<Objeto.ID> {
        let grupos = Set(objetos.filter { ids.contains($0.id) }.compactMap(\.grupos.first))
        return ids.union(objetos.filter { $0.grupos.first.map(grupos.contains) == true && !intocavel($0) }.map(\.id))
    }

    /// A seleção em peças: cada grupo de fora é uma; cada objeto solto, outra.
    var pecasSelecionadas: [[Objeto]] {
        var ordem: [UUID] = [], pecas: [UUID: [Objeto]] = [:]
        for objeto in selecionados {
            let chave = objeto.grupos.first ?? objeto.id
            if pecas[chave] == nil { ordem.append(chave) }
            pecas[chave, default: []].append(objeto)
        }
        return ordem.map { pecas[$0]! }
    }

    /// A seleção é um grupo (de fora) só.
    var selecaoEhUmGrupo: Bool {
        let pecas = pecasSelecionadas
        return pecas.count == 1 && pecas[0].first?.grupos.isEmpty == false
    }

    var podeAgrupar: Bool { pecasSelecionadas.count > 1 }
    var podeDesagrupar: Bool { selecionados.contains { !$0.grupos.isEmpty } }

    func agrupar() {
        guard podeAgrupar, let frente = objetosEmOrdem.last(where: { selecao.contains($0.id) }) else { return }
        registrar()
        let grupo = UUID()
        for i in objetos.indices where selecao.contains(objetos[i].id) {
            objetos[i].grupos.insert(grupo, at: 0)
            objetos[i].camada = frente.camada
        }
        objetos = pilha { $0 }
    }

    /// Desfaz o grupo de fora dos selecionados (os de dentro continuam); a seleção fica.
    func desagrupar() {
        guard podeDesagrupar else { return }
        registrar()
        for i in objetos.indices where selecao.contains(objetos[i].id) && !objetos[i].grupos.isEmpty {
            objetos[i].grupos.removeFirst()
        }
    }

    func organizar(_ modo: Organizar) {
        guard !selecao.isEmpty else { return }
        let nova = pilha { pecas in
            var p = pecas
            switch modo {
            case .frente: return p.filter { !$0.selecionada } + p.filter(\.selecionada)
            case .tras: return p.filter(\.selecionada) + p.filter { !$0.selecionada }
            case .avancar:
                // Da frente para trás, cada peça selecionada passa a de cima (as vizinhas sobem juntas).
                for i in stride(from: p.count - 2, through: 0, by: -1) where p[i].selecionada && !p[i + 1].selecionada {
                    p.swapAt(i, i + 1)
                }
            case .recuar:
                for i in p.indices.dropFirst() where p[i].selecionada && !p[i - 1].selecionada {
                    p.swapAt(i, i - 1)
                }
            }
            return p
        }
        guard nova.map(\.id) != objetos.map(\.id) else { return }
        registrar()
        objetos = nova
    }

    /// A pilha refeita por camada: as peças (grupo de fora inteiro, ou objeto; a parte selecionada de um grupo
    /// é outra peça) ficam no lugar do objeto mais à frente de cada uma e `mudar` as reordena.
    private func pilha(_ mudar: ([PecaPilha]) -> [PecaPilha]) -> [Objeto] {
        var ordemCamadas: [UUID] = [], porCamada: [UUID: [Objeto]] = [:]
        for objeto in objetos {
            let camada = camada(de: objeto).id
            if porCamada[camada] == nil { ordemCamadas.append(camada) }
            porCamada[camada, default: []].append(objeto)
        }
        return ordemCamadas.flatMap { camada -> [Objeto] in
            var chaves: [String] = [], pecas: [String: PecaPilha] = [:], frente: [String: Int] = [:]
            for (i, objeto) in porCamada[camada]!.enumerated() {
                let selecionada = selecao.contains(objeto.id)
                let chave = (objeto.grupos.first ?? objeto.id).uuidString + (selecionada ? "*" : "")
                if pecas[chave] == nil {
                    chaves.append(chave)
                    pecas[chave] = PecaPilha(objetos: [], selecionada: selecionada)
                }
                pecas[chave]!.objetos.append(objeto)
                frente[chave] = i
            }
            return mudar(chaves.sorted { frente[$0]! < frente[$1]! }.map { pecas[$0]! }).flatMap(\.objetos)
        }
    }
}
