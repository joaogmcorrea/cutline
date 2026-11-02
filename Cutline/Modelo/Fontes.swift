// Fontes instaladas no Mac, como o macOS as vê: as do sistema, as do usuário (Catálogo de Fontes) e as
// ativadas por outros apps, como as Adobe Fonts do Creative Cloud.
import AppKit
import CoreText

enum Fontes {
    /// Uma face da família (Regular, Bold Italic…).
    struct Face: Hashable, Identifiable {
        let postscript: String
        /// Nome da face como o macOS mostra.
        let nome: String
        var id: String { postscript }
    }

    /// Famílias em ordem alfabética, sem as escondidas do sistema (as que começam com ".").
    static func familias() -> [String] {
        NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Faces da família, na ordem do macOS (do mais leve ao mais pesado).
    static func faces(_ familia: String) -> [Face] {
        (NSFontManager.shared.availableMembers(ofFontFamily: familia) ?? []).compactMap { membro in
            guard membro.count >= 2, let postscript = membro[0] as? String, let nome = membro[1] as? String else { return nil }
            return Face(postscript: postscript, nome: nome)
        }
    }

    /// A família numa fonte para mostrar na lista (no corpo pedido).
    static func amostra(_ familia: String, tamanho: Double) -> CTFont {
        let descritor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: familia] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descritor, tamanho, nil)
    }

    /// Fonte de símbolos (Webdings, Zapf Dingbats…): o nome escrito nela não dá para ler.
    static func ehSimbolos(_ fonte: CTFont) -> Bool {
        let classe = CTFontGetSymbolicTraits(fonte).rawValue & CTFontSymbolicTraits.traitClassMask.rawValue
        return classe == CTFontStylisticClass.classSymbolic.rawValue
    }

    /// Fontes instaladas, ativadas ou removidas com o app aberto (Catálogo de Fontes, arrastar para
    /// ~/Library/Fonts, Adobe Fonts): o macOS avisa em cerca de 1 s, mesmo com o app em segundo plano, e o
    /// catálogo atualiza a lista, os menus e as letras já desenhadas.
    @MainActor static func observarMudancas() {
        for nome in [NSFont.fontSetChangedNotification, Notification.Name(kCTFontManagerRegisteredFontsChangedNotification as String)] {
            NotificationCenter.default.addObserver(forName: nome, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { CatalogoFontes.shared.mudou() }
            }
        }
    }
}

/// As famílias instaladas agora. A lista de fontes, o menu de estilo e a tela leem daqui, e por isso se
/// refazem sozinhos quando o conjunto de fontes do Mac muda (sem fechar e abrir o app).
@Observable
final class CatalogoFontes {
    static let shared = CatalogoFontes()

    private(set) var familias: [String]
    private(set) var instaladas: Set<String>
    /// Muda a cada mudança no conjunto de fontes (a tela redesenha os textos com as fontes de agora).
    private(set) var versao = 0
    @ObservationIgnored private var agendado = false

    private init() {
        let agora = Fontes.familias()
        familias = agora
        instaladas = Set(agora)
    }

    /// Faces da família como estão agora (Regular, Bold…).
    func faces(_ familia: String) -> [Fontes.Face] {
        _ = versao
        return Fontes.faces(familia)
    }

    /// As duas notificações chegam juntas (e uma por arquivo quando chegam várias fontes): uma atualização
    /// só, um instante depois.
    func mudou() {
        guard !agendado else { return }
        agendado = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            agendado = false
            Texto.esquecerFontes()
            let novas = Fontes.familias()
            if novas != familias {
                familias = novas
                instaladas = Set(novas)
            }
            versao += 1
        }
    }
}

extension EstiloCaractere {
    /// Face em uso (a escolhida ou a que a família dá quando nenhuma foi escolhida).
    var postscriptEmUso: String { CTFontCopyPostScriptName(fonteCT()) as String }

    /// Troca a família tentando manter a face (Bold continua Bold, se a nova família tiver).
    mutating func trocarFamilia(_ familia: String) {
        guard familia != fonte else { return }
        let faceAtual = Fontes.faces(fonte).first { $0.postscript == postscriptEmUso }?.nome
        fonte = familia
        postscript = Fontes.faces(familia).first { $0.nome == faceAtual }?.postscript
    }
}
