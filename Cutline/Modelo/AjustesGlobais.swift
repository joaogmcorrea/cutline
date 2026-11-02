// Ajustes de corte guardados no app (valem para qualquer arquivo): os últimos usados em cada cor de
// linha e os materiais do usuário ("Meus materiais"). Cada arquivo continua guardando os seus — ao
// abrir, valem os do arquivo; cores que o arquivo não tem começam com os lembrados aqui.
import Foundation
import Observation
import CutlineKit

@Observable
final class AjustesGlobais {
    static let shared = AjustesGlobais()

    private(set) var porCor: [CMYK: ConfigCorte] = [:]
    private(set) var materiais: [Material] = []

    private static let chaveCores = "ajustesPorCor"
    private static let chaveMateriais = "meusMateriais"

    private struct CorGuardada: Codable {
        var cor: CMYK
        var config: ConfigCorte
    }

    private init() {
        let padroes = UserDefaults.standard
        if let dados = padroes.data(forKey: Self.chaveCores),
           let lista = try? JSONDecoder().decode([CorGuardada].self, from: dados) {
            porCor = Dictionary(lista.map { ($0.cor, $0.config) }, uniquingKeysWith: { _, ultima in ultima })
        }
        if let dados = padroes.data(forKey: Self.chaveMateriais), let lista = try? JSONDecoder().decode([Material].self, from: dados) {
            materiais = lista
        }
    }

    /// Lembra os ajustes desta cor para os próximos arquivos.
    func lembrar(_ config: ConfigCorte, para cor: CMYK) {
        guard porCor[cor] != config else { return }
        porCor[cor] = config
        let lista = porCor.map { CorGuardada(cor: $0.key, config: $0.value) }
        if let dados = try? JSONEncoder().encode(lista) { UserDefaults.standard.set(dados, forKey: Self.chaveCores) }
    }

    // MARK: Meus materiais

    /// Os do app e os do usuário, nessa ordem.
    var todosMateriais: [Material] { Material.todos + materiais }

    func material(_ nome: String) -> Material? { todosMateriais.first { $0.nome == nome } }

    func ehDoUsuario(_ nome: String) -> Bool { materiais.contains { $0.nome == nome } }

    /// Cria ou atualiza um material do usuário (os do app não mudam). Devolve falso se o nome for de um do app.
    @discardableResult
    func salvarMaterial(_ nome: String, ajustes: CutSettings) -> Bool {
        let nome = nome.trimmingCharacters(in: .whitespaces)
        guard !nome.isEmpty, !Material.todos.contains(where: { $0.nome == nome }) else { return false }
        let novo = Material(nome: nome, ajustes: ajustes)
        if let i = materiais.firstIndex(where: { $0.nome == nome }) { materiais[i] = novo } else { materiais.append(novo) }
        gravarMateriais()
        return true
    }

    func apagarMaterial(_ nome: String) {
        materiais.removeAll { $0.nome == nome }
        gravarMateriais()
    }

    private func gravarMateriais() {
        if let dados = try? JSONEncoder().encode(materiais) { UserDefaults.standard.set(dados, forKey: Self.chaveMateriais) }
    }
}
