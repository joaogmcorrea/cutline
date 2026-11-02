// Menus da barra do macOS, como os do Illustrator, só com o que o Cutline faz: Arquivo (Importar, Imprimir,
// Enviar), Editar (Apagar, Duplicar), Objeto (Agrupar, Organizar, Alinhar, Pathfinder…), Selecionar,
// Visualizar (zoom, réguas, snap, guias, marcas) e Janela (ferramentas, barra de controle e painéis, que se
// ocultam de vez). Agem sobre a janela ativa (FocusedValues); desfazer/refazer e Selecionar Tudo dos campos de
// texto são os do sistema, e recortar/copiar/colar também, que chegam aos objetos pelo `RespondedorEdicao`.
// Na tela, os atalhos com ⌘ dos objetos são lidos pelo teclado dela (Tela.teclado), não pelos menus.
import AppKit
import SwiftUI

struct ComandosEditor: Commands {
    @FocusedValue(\.documento) private var doc
    @FocusedValue(\.controleVista) private var controle
    @AppStorage("reguas") private var reguas = true
    @AppStorage("snap") private var snap = true
    @AppStorage("ferramentasVisiveis") private var ferramentasVisiveis = true
    @AppStorage("barraControleVisivel") private var barraVisivel = true
    @AppStorage("paineisOcultos") private var ocultosTexto = ""

    var body: some Commands {
        arquivo
        editar
        visualizar
        janela
        CommandMenu("Objeto") { objeto }
        CommandMenu("Selecionar") { selecionar }
    }

    /// Só age no documento quando não há uma janela por cima dele (Enviar, Vetorizar, Imprimir).
    private func agir(_ acao: (Documento) -> Void) {
        guard let doc, NSApp.keyWindow?.sheetParent == nil else { return }
        acao(doc)
    }

    private var semSelecao: Bool { doc?.selecao.isEmpty ?? true }

    /// Digitando na tela: ⌘⌫, ⌘D e ⇧⌘A ficam com o texto (apagar até o começo da linha etc.), não com o objeto.
    private var digitando: Bool { doc?.edicaoTexto != nil }

    // MARK: Arquivo e Editar

    @CommandsBuilder
    private var arquivo: some Commands {
        CommandGroup(after: .importExport) {
            Button("Importar…") { agir { $0.pedidoImportar += 1 } }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(doc == nil)
        }
        CommandGroup(replacing: .printItem) {
            // A4 em tamanho real; no Print & Cut, com as marcas de registro.
            Button("Imprimir…") { agir { $0.pedidoImprimir += 1 } }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(doc == nil)
            Button("Enviar para a máquina…") { agir { $0.pedidoEnviar += 1 } }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(doc?.objetos.isEmpty ?? true)
        }
    }

    @CommandsBuilder
    private var editar: some Commands {
        CommandGroup(after: .pasteboard) {
            // Delete sozinho apaga com a tela em foco; ⌘⌫ funciona de qualquer lugar.
            Button("Apagar") { agir { $0.apagarSelecao() } }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(semSelecao || digitando)
            Button("Duplicar") { agir { $0.duplicarSelecao() } }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(semSelecao || digitando)
        }
    }

    // MARK: Objeto e Selecionar

    @ViewBuilder
    private var objeto: some View {
        let selecionados = doc?.selecionados ?? []
        Menu("Alinhar") {
            ForEach(ModoAlinhar.allCases) { modo in
                Button("Alinhar \(modo.nome)") { agir { $0.alinhar(modo) } }
            }
        }
        .disabled(selecionados.isEmpty)
        Menu("Pathfinder") {
            ForEach(OperacaoPathfinder.allCases) { operacao in
                Button(operacao.nome) {
                    agir { doc in if let aviso = doc.pathfinder(operacao) { doc.aviso = aviso } }
                }
            }
        }
        .disabled(selecionados.isEmpty)
        Divider()
        Button("Agrupar") { agir { $0.agrupar() } }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(!(doc?.podeAgrupar ?? false) || digitando)
        Button("Desagrupar") { agir { $0.desagrupar() } }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(!(doc?.podeDesagrupar ?? false) || digitando)
        Menu("Organizar") {
            ForEach(Organizar.allCases) { modo in
                Button(modo.nome) { agir { $0.organizar(modo) } }
                    .keyboardShortcut(modo == .frente || modo == .avancar ? "]" : "[",
                                      modifiers: modo == .frente || modo == .tras ? [.command, .shift] : .command)
            }
        }
        .disabled(selecionados.isEmpty || digitando)
        Divider()
        Button("Converter em caminho") { agir { $0.converterEmCaminho() } }
            .disabled(!selecionados.contains { $0.forma.parametrica })
        // ⇧⌘O é o Criar contornos do Illustrator; digitando, converte o texto em edição.
        Button("Converter texto em curvas") { agir { $0.converterTextoEmCurvas() } }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(!(doc?.temTextoParaCurvas ?? false))
        Button("Fechar caminho") { agir { $0.fecharCaminhos() } }
            .disabled(!selecionados.contains { if case .caminho(let subs) = $0.forma { subs.contains { !$0.fechado } } else { false } })
        Divider()
        Button("Mover para a camada ativa") { agir { $0.moverSelecaoParaCamadaAtiva() } }
            .disabled(selecionados.isEmpty)
    }

    @ViewBuilder
    private var selecionar: some View {
        // ⌘A na tela é lido pelo teclado da tela; nos campos de texto, fica com o Editar › Selecionar Tudo.
        Button("Tudo") { agir { $0.selecionarTudo() } }
            .disabled(doc?.objetos.isEmpty ?? true)
        Button("Nada") { agir { $0.selecao = [] } }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(semSelecao || digitando)
        Divider()
        Button("Tudo da camada ativa") {
            agir { doc in if let ativa = doc.camadas.first(where: { $0.id == doc.camadaAtiva }) { doc.selecionarCamada(ativa) } }
        }
        .disabled(doc == nil)
    }

    // MARK: Visualizar e Janela

    @CommandsBuilder
    private var visualizar: some Commands {
        CommandGroup(before: .toolbar) {
            Button("Ampliar") { controle?.zoom(1.25) }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(controle == nil)
            Button("Reduzir") { controle?.zoom(1 / 1.25) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(controle == nil)
            Button("Ajustar à janela") { controle?.ajustar() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(controle == nil)
            Button("Tamanho real") { controle?.definirZoom(1) }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(controle == nil)
            Divider()
            Toggle("Réguas", isOn: $reguas)
                .keyboardShortcut("r", modifiers: .command)
            Toggle("Snap", isOn: $snap)
                .keyboardShortcut(";", modifiers: .command)
            Button("Apagar guias") { agir { $0.apagarGuias() } }
                .disabled(doc?.guias.vazias ?? true)
            Toggle("Marcas de registro (Print & Cut)", isOn: Binding(get: { doc?.marcas ?? false }, set: { novo in
                agir { if $0.marcas != novo { $0.alternarMarcas() } }
            }))
            .disabled(doc == nil)
            Divider()
        }
    }

    @CommandsBuilder
    private var janela: some Commands {
        CommandGroup(before: .windowArrangement) {
            Toggle("Ferramentas", isOn: $ferramentasVisiveis)
            Toggle("Barra de controle", isOn: $barraVisivel)
            Divider()
            ForEach(Painel.allCases) { painel in
                Toggle(painel.titulo, isOn: Binding(get: { !Painel.conjunto(ocultosTexto).contains(painel) }, set: { visivel in
                    var ocultos = Painel.conjunto(ocultosTexto)
                    if visivel { ocultos.remove(painel) } else { ocultos.insert(painel) }
                    ocultosTexto = Painel.texto(ocultos)
                }))
            }
            Divider()
        }
    }
}
