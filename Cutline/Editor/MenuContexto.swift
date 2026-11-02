// Menu do clique direito na tela (ou ⌃-clique): recortar, copiar, colar, duplicar e apagar; agrupar e
// desagrupar; organizar na pilha; duplicar ao lado. O clique num objeto fora da seleção o seleciona antes (o
// grupo inteiro, com a ferramenta Seleção), como no Illustrator. Também o `RespondedorEdicao`, que faz o
// Recortar, Copiar e Colar do menu Editar valerem para os objetos.
import AppKit

enum MenuContexto {
    @MainActor static func criar(_ doc: Documento) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let algo = !doc.selecao.isEmpty
        menu.addItem(item(String(localized: "Recortar"), tecla: "x", ativo: algo) { doc.recortarSelecao() })
        menu.addItem(item(String(localized: "Copiar"), tecla: "c", ativo: algo) { doc.copiarSelecao() })
        menu.addItem(item(String(localized: "Colar"), tecla: "v", ativo: doc.podeColar) { doc.colar() })
        menu.addItem(item(String(localized: "Duplicar"), tecla: "d", ativo: algo) { doc.duplicarSelecao() })
        menu.addItem(item(String(localized: "Apagar"), tecla: "\u{8}", modificadores: [], ativo: algo) { doc.apagarSelecao() })
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Agrupar"), tecla: "g", ativo: doc.podeAgrupar) { doc.agrupar() })
        menu.addItem(item(String(localized: "Desagrupar"), tecla: "g", modificadores: [.command, .shift], ativo: doc.podeDesagrupar) {
            doc.desagrupar()
        })
        menu.addItem(.separator())
        menu.addItem(submenu(String(localized: "Organizar"), ativo: algo, Organizar.allCases.map { modo in
            item(modo.nome, tecla: modo == .frente || modo == .avancar ? "]" : "[",
                     modificadores: modo == .frente || modo == .tras ? [.command, .shift] : .command) { doc.organizar(modo) }
        }))
        let seta = { (tecla: Int) in String(utf16CodeUnits: [unichar(tecla)], count: 1) }
        menu.addItem(submenu(String(localized: "Duplicar ao lado"), ativo: algo, [
            item(String(localized: "À esquerda"), tecla: seta(NSLeftArrowFunctionKey)) { doc.duplicarAoLado(.esquerda) },
            item(String(localized: "À direita"), tecla: seta(NSRightArrowFunctionKey)) { doc.duplicarAoLado(.direita) },
            item(String(localized: "Acima"), tecla: seta(NSUpArrowFunctionKey)) { doc.duplicarAoLado(.cima) },
            item(String(localized: "Abaixo"), tecla: seta(NSDownArrowFunctionKey)) { doc.duplicarAoLado(.baixo) },
        ]))
        return menu
    }

    /// Item que roda um bloco (o atalho só aparece; quem o atende é o teclado da tela).
    @MainActor private static func item(_ titulo: String, tecla: String = "", modificadores: NSEvent.ModifierFlags = .command,
                                        ativo: Bool = true, acao: @escaping () -> Void) -> NSMenuItem {
        let alvo = AcaoMenu(acao)
        let item = NSMenuItem(title: titulo, action: #selector(AcaoMenu.executar), keyEquivalent: tecla)
        item.keyEquivalentModifierMask = modificadores
        item.target = alvo
        item.representedObject = alvo   // o target é fraco: o item guarda o alvo
        item.isEnabled = ativo
        return item
    }

    @MainActor private static func submenu(_ titulo: String, ativo: Bool, _ itens: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: titulo, action: nil, keyEquivalent: "")
        item.submenu = NSMenu(title: titulo)
        itens.forEach { item.submenu?.addItem($0) }
        item.isEnabled = ativo
        return item
    }
}

/// O alvo de um item do menu: roda um bloco.
private final class AcaoMenu: NSObject {
    let acao: () -> Void
    init(_ acao: @escaping () -> Void) { self.acao = acao }
    @objc func executar() { acao() }
}

nonisolated(unsafe) private var chaveRespondedor: UInt8 = 0

/// Recortar, Copiar e Colar do menu Editar para os objetos quando nenhum campo de texto está com o teclado (os
/// campos respondem antes, na cadeia de resposta); e o Salvar de um documento que veio do Silhouette Studio
/// (Modelo/SalvarStudio.swift). Fica logo depois da janela, antes do documento. O `nextResponder` é uma
/// referência fraca: a janela o segura (objeto associado), e a cada atualização dela ele confere se continua
/// na cadeia.
final class RespondedorEdicao: NSResponder, NSMenuItemValidation {
    private weak var doc: Documento?
    private weak var janela: NSWindow?
    private var observador: NSObjectProtocol?

    static func instalar(em janela: NSWindow, doc: Documento) {
        var atual = janela.nextResponder
        while let r = atual {
            if let meu = r as? RespondedorEdicao {
                meu.doc = doc
                meu.janela = janela
                return
            }
            atual = r.nextResponder
        }
        let novo = RespondedorEdicao()
        novo.doc = doc
        novo.janela = janela
        objc_setAssociatedObject(janela, &chaveRespondedor, novo, .OBJC_ASSOCIATION_RETAIN)
        novo.encaixar()
        novo.observador = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: janela,
                                                                 queue: .main) { [weak novo] _ in
            MainActor.assumeIsolated { novo?.encaixar() }
        }
    }

    /// Logo depois da janela (se ainda não estiver na cadeia dela).
    private func encaixar() {
        guard let janela else { return }
        var atual = janela.nextResponder
        while let r = atual {
            if r === self { return }
            atual = r.nextResponder
        }
        nextResponder = janela.nextResponder
        janela.nextResponder = self
    }

    isolated deinit {
        if let observador { NotificationCenter.default.removeObserver(observador) }
    }

    @objc func copy(_ sender: Any?) { doc?.copiarSelecao() }
    @objc func cut(_ sender: Any?) { doc?.recortarSelecao() }
    @objc func paste(_ sender: Any?) { doc?.colar() }

    /// ⌘S: o documento que veio do Studio (e ainda não tem arquivo do Cutline) pergunta onde gravar.
    @objc func saveDocument(_ sender: Any?) {
        guard let janela, let documento = janela.windowController?.document as? NSDocument else { return }
        guard let doc, doc.studio?.url != nil, documento.fileURL == nil else { return documento.save(sender) }
        SalvarStudio.salvar(doc, documento, janela: janela)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(saveDocument(_:)) {
            return (janela?.windowController?.document as? NSDocument)?.validateUserInterfaceItem(item) ?? true
        }
        guard let doc, doc.edicaoTexto == nil else { return false }
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)): return !doc.selecao.isEmpty
        case #selector(paste(_:)): return doc.podeColar
        default: return true
        }
    }
}
