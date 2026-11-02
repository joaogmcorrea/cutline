// Atualizações pelo Sparkle 2: o app lê o appcast.xml da última versão no GitHub Releases (SUFeedURL no
// Cutline-Info.plist) e só instala o que vier assinado com a chave EdDSA do projeto (SUPublicEDKey).
// O instalador e o appcast saem do distribuir.sh.
import Combine
import Sparkle
import SwiftUI

/// Um atualizador para o app todo. Na compilação de depuração ele não procura nada: as cópias de teste
/// rodam escondidas e a janela do Sparkle apareceria na tela.
enum Atualizacoes {
    static let controlador = SPUStandardUpdaterController(
        startingUpdater: !depurando, updaterDelegate: nil, userDriverDelegate: nil)

    private static var depurando: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }
}

/// Cutline › Procurar Atualizações…, logo abaixo de Sobre o Cutline.
struct ComandoAtualizacoes: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            BotaoAtualizacoes(atualizador: Atualizacoes.controlador.updater)
        }
    }
}

/// Fica desligado enquanto o Sparkle já está procurando ou instalando (e sempre na depuração).
private struct BotaoAtualizacoes: View {
    let atualizador: SPUUpdater
    @State private var pode = false

    var body: some View {
        Button("Procurar Atualizações…") { atualizador.checkForUpdates() }
            .disabled(!pode)
            .onReceive(atualizador.publisher(for: \.canCheckForUpdates)) { pode = $0 }
    }
}
