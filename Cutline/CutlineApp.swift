// Cutline — editor e corte para cortadoras Silhouette (macOS, SwiftUI, Liquid Glass).
import SwiftUI

@main
struct CutlineApp: App {
    /// Uma conexão com a cortadora para o app todo.
    @State private var maquina = Maquina()

    init() {
        // Ao abrir o app, um documento novo em branco (e não o painel de abrir arquivo).
        UserDefaults.standard.register(defaults: ["NSShowAppCentricOpenPanelInsteadOfUntitledFile": false])
        // Documentos em abas, como no Illustrator e no Silhouette Studio: a preferência do sistema
        // ("Preferir abas ao abrir documentos") vale só para este app.
        UserDefaults.standard.set("always", forKey: "AppleWindowTabbingMode")
        // Fontes ativadas com o app aberto (Adobe Fonts) passam a valer nos textos já desenhados.
        Fontes.observarMudancas()
        // O Sparkle procura versões novas desde a abertura (na depuração, nunca).
        _ = Atualizacoes.controlador
        #if DEBUG
        Depuracao.esconderJanelas()
        #endif
    }

    var body: some Scene {
        // Arquivo › Novo, Abrir (também .studio3), Abrir Recente, Salvar, Duplicar, Reverter… vêm do sistema.
        DocumentGroup(newDocument: { Documento() }) { arquivo in
            JanelaPrincipal(doc: arquivo.document)
                .environment(maquina)
        }
        .defaultSize(width: 1400, height: 900)
        .windowToolbarStyle(.unified)
        .commands {
            ComandosEditor()
            ComandoAtualizacoes()
            ComandosAjuda()
        }

        // Ajuda › Relatar um Problema… / Sugerir um Recurso… (uma janela de cada; sem itens no menu Arquivo).
        WindowGroup(for: TipoRelatorio.self) { $tipo in
            JanelaRelatorio(tipo: tipo ?? .problema)
                .environment(maquina)
        }
        .defaultSize(width: 600, height: 760)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .commandsRemoved()
    }
}
