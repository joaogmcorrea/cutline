// Ajuda › Relatar um Problema… / Sugerir um Recurso…: uma janela com o que aconteceu, como reproduzir e o que se
// esperava (ou o recurso e para que serviria), mais os dados técnicos (versões, Mac, máquina e o registro do
// driver), que a pessoa vê antes de mandar. Vai como issue no GitHub (página de nova issue preenchida) ou por
// e-mail (com o último registro de corte anexado); também dá para só copiar.
import AppKit
import CutlineKit
import SwiftUI

enum TipoRelatorio: String, Codable, Hashable, CaseIterable {
    case problema, recurso

    var titulo: String {
        switch self {
        case .problema: String(localized: "Relatar um problema")
        case .recurso: String(localized: "Sugerir um recurso")
        }
    }
}

/// Para onde vão os relatórios.
enum Contato {
    static let repositorio = "joaogmcorrea/cutline"
    static let email = "cutline@joaocorrea.design"
    static var paginaGitHub: URL { URL(string: "https://github.com/\(repositorio)")! }
}

/// Os campos que a pessoa preenche e o texto montado a partir deles.
struct Relatorio {
    var tipo: TipoRelatorio
    var resumo = ""
    /// Problema: o que aconteceu. Recurso: o que o Cutline deveria fazer.
    var descricao = ""
    /// Problema: os passos. Recurso: para que serviria.
    var detalhe = ""
    /// Problema: o que deveria ter acontecido.
    var esperado = ""
    var incluirTecnico = true

    /// O GitHub não abre páginas com endereços muito longos: o registro encolhe até caber.
    static let limiteURL = 7_500

    var completo: Bool {
        !resumo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !descricao.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var tituloFinal: String {
        let resumo = resumo.trimmingCharacters(in: .whitespacesAndNewlines)
        return tipo == .problema ? resumo : "[" + String(localized: "Recurso") + "] " + resumo
    }

    /// O texto em Markdown. No GitHub, o registro vai num bloco recolhível.
    func texto(_ tecnico: InfoTecnica?, linhasDoRegistro: Int? = nil, paraGitHub: Bool = true) -> String {
        var partes: [String] = []
        func secao(_ titulo: String, _ corpo: String) {
            let corpo = corpo.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !corpo.isEmpty else { return }
            partes.append("### \(titulo)\n\n\(corpo)")
        }
        switch tipo {
        case .problema:
            secao(String(localized: "O que aconteceu"), descricao)
            secao(String(localized: "Como reproduzir"), detalhe == Self.passosVazios ? "" : detalhe)
            secao(String(localized: "O que deveria acontecer"), esperado)
        case .recurso:
            secao(String(localized: "O que o Cutline deveria fazer"), descricao)
            secao(String(localized: "Para que serviria"), detalhe)
        }
        if let tecnico {
            partes.append("### " + String(localized: "Informações técnicas") + "\n\n" + tecnico.resumo)
            let linhas = tecnico.registro.suffix(linhasDoRegistro ?? tecnico.registro.count)
            if !linhas.isEmpty {
                let titulo = String(localized: "Registro da máquina (últimas \(linhas.count) linhas)")
                let bloco = "```\n" + linhas.joined(separator: "\n") + "\n```"
                partes.append(paraGitHub ? "<details><summary>\(titulo)</summary>\n\n\(bloco)\n\n</details>"
                                         : "\(titulo):\n\n\(bloco)")
            }
        }
        return partes.joined(separator: "\n\n") + "\n"
    }

    static let passosVazios = "1. \n2. \n3. "

    /// A página de nova issue preenchida. Se nem sem o registro couber, o texto vai cortado e `cortado` = true.
    func urlGitHub(_ tecnico: InfoTecnica?) -> (url: URL, cortado: Bool) {
        func url(_ corpo: String) -> URL {
            var componentes = URLComponents(string: "https://github.com/\(Contato.repositorio)/issues/new")!
            componentes.queryItems = [URLQueryItem(name: "title", value: tituloFinal),
                                      URLQueryItem(name: "body", value: corpo),
                                      URLQueryItem(name: "labels", value: tipo == .problema ? "bug" : "enhancement")]
            return componentes.url!
        }
        var linhas = tecnico?.registro.count ?? 0
        while true {
            let candidata = url(texto(tecnico, linhasDoRegistro: linhas))
            if candidata.absoluteString.count <= Self.limiteURL { return (candidata, false) }
            if linhas == 0 { break }
            linhas = linhas > 10 ? linhas / 2 : 0
        }
        var corpo = texto(tecnico, linhasDoRegistro: 0)
        let aviso = "\n\n" + String(localized: "(Texto cortado: o relatório completo foi copiado; cole aqui.)")
        while url(corpo + aviso).absoluteString.count > Self.limiteURL, !corpo.isEmpty {
            corpo.removeLast(min(200, corpo.count))
        }
        return (url(corpo + aviso), true)
    }
}

/// O que vai junto do relatório (a pessoa vê tudo antes de mandar).
struct InfoTecnica {
    let resumo: String
    let registro: [String]
    /// A transcrição do último corte (~/Library/Logs/Cutline), para anexar no e-mail.
    let ultimoCorte: URL?

    static var pastaRegistros: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Cutline")
    }

    /// Tudo o que vai junto, como a pessoa vê antes de mandar.
    var previa: String {
        var texto = resumo
        if !registro.isEmpty { texto += "\n\n" + registro.joined(separator: "\n") }
        if let ultimoCorte {
            texto += "\n\n" + String(localized: "No e-mail, anexo: \(ultimoCorte.lastPathComponent)")
        }
        return texto
    }

    @MainActor
    init(maquina: Maquina) {
        let info = Bundle.main.infoDictionary ?? [:]
        let versao = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        #if arch(arm64)
        let processador = "Apple Silicon"
        #else
        let processador = "Intel"
        #endif
        let idioma = [Bundle.main.preferredLocalizations.first, Locale.preferredLanguages.first]
            .compactMap(\.self).joined(separator: " / ")
        let conexao = maquina.atual.map { $0.link == .usb ? "USB" : "Bluetooth" }
        let maquinaTexto: String
        if maquina.info != nil {
            maquinaTexto = [maquina.nomeModelo, maquina.firmware, conexao, Self.estado(maquina)]
                .compactMap(\.self).joined(separator: " · ")
        } else if let atual = maquina.atual {
            maquinaTexto = String(localized: "não conectada (última: \(atual.model) · \(conexao ?? "?"))")
        } else {
            maquinaTexto = String(localized: "nenhuma usada ainda")
        }
        resumo = [
            "- Cutline \(versao) (build \(build))",
            "- macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "- Mac: \(Self.modeloDoMac) · \(processador) · \(idioma)",
            "- " + String(localized: "Máquina: \(maquinaTexto)"),
            "- Silhouette Studio " + (maquina.studioAberto ? String(localized: "aberto") : String(localized: "fechado")),
        ].joined(separator: "\n")
        registro = Array(maquina.registro.suffix(60))
        ultimoCorte = (try? FileManager.default.contentsOfDirectory(at: Self.pastaRegistros,
                                                                    includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.pathExtension == "gpgl" }
            .max { Self.data($0) < Self.data($1) }
    }

    private static func data(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    @MainActor
    private static func estado(_ maquina: Maquina) -> String? {
        switch maquina.estado {
        case .erro(let mensagem): String(localized: "erro: \(mensagem)")
        default:
            switch maquina.info?.status {
            case .ready: String(localized: "pronta")
            case .moving: String(localized: "em movimento")
            case .unloaded: String(localized: "sem folha ou base")
            case .noResponse: String(localized: "sem resposta")
            case .other(let texto): texto
            case nil: nil
            }
        }
    }

    /// "Mac16,10".
    private static var modeloDoMac: String {
        var tamanho = 0
        sysctlbyname("hw.model", nil, &tamanho, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(tamanho, 1))
        sysctlbyname("hw.model", &bytes, &tamanho, nil, 0)
        return String(decoding: bytes.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
    }
}

struct JanelaRelatorio: View {
    @Environment(Maquina.self) private var maquina
    @State private var relatorio: Relatorio
    @State private var aviso: String?

    init(tipo: TipoRelatorio) {
        _relatorio = State(initialValue: Relatorio(tipo: tipo, detalhe: tipo == .problema ? Relatorio.passosVazios : ""))
    }

    private var tecnico: InfoTecnica? { relatorio.incluirTecnico ? InfoTecnica(maquina: maquina) : nil }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Tipo", selection: $relatorio.tipo) {
                        Text("Problema").tag(TipoRelatorio.problema)
                        Text("Sugestão de recurso").tag(TipoRelatorio.recurso)
                    }
                    .pickerStyle(.segmented)
                    TextField("Resumo", text: $relatorio.resumo,
                              prompt: Text(relatorio.tipo == .problema ? "Em uma linha, o que deu errado"
                                                                       : "Em uma linha, o que você gostaria"))
                }
                if relatorio.tipo == .problema {
                    campo("O que aconteceu?", $relatorio.descricao,
                          "Conte o que você fez e o que o Cutline fez (mensagem de erro, o que a máquina cortou…)")
                    campo("Como reproduzir", $relatorio.detalhe, "Os passos, um por linha")
                    campo("O que deveria acontecer?", $relatorio.esperado, "O que você esperava ver")
                } else {
                    campo("O que o Cutline deveria fazer?", $relatorio.descricao, "Descreva o recurso")
                    campo("Para que serviria?", $relatorio.detalhe,
                          "O que você faria com ele (e como faz hoje, no Silhouette Studio ou em outro programa)")
                }
                Section {
                    Toggle("Incluir dados do Cutline, do Mac e da máquina", isOn: $relatorio.incluirTecnico)
                    if let tecnico {
                        DisclosureGroup("Ver o que vai junto") {
                            Text(tecnico.previa)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } footer: {
                    if relatorio.tipo == .problema {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Se o problema acontece com um arquivo, anexe o documento (.cutline, .studio3, PDF…). Os registros de corte ficam em ~/Library/Logs/Cutline; no e-mail, o último vai anexado.")
                            Button("Mostrar os registros de corte") { mostrarRegistros() }
                                .buttonStyle(.link)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack(spacing: 10) {
                Button("Copiar", action: copiar)
                if let aviso {
                    Text(aviso)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("Enviar por e-mail", action: enviarEmail)
                Button("Abrir no GitHub", action: abrirGitHub)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(!relatorio.completo)
            .padding(14)
        }
        .frame(minWidth: 540, idealWidth: 580, minHeight: 640, idealHeight: 720)
        .navigationTitle(relatorio.tipo.titulo)
        .background(SemAbas())
        .onChange(of: relatorio.tipo) { _, tipo in
            // Os passos numerados só servem para o problema.
            if tipo == .recurso, relatorio.detalhe == Relatorio.passosVazios { relatorio.detalhe = "" }
            if tipo == .problema, relatorio.detalhe.isEmpty { relatorio.detalhe = Relatorio.passosVazios }
        }
        #if DEBUG
        .onAppear { Depuracao.preencherRelatorio(&relatorio, enviar: { abrirGitHub() }) }
        #endif
    }

    private func campo(_ titulo: LocalizedStringKey, _ texto: Binding<String>, _ dica: LocalizedStringKey) -> some View {
        Section(titulo) {
            TextField(titulo, text: texto, prompt: Text(dica), axis: .vertical)
                .labelsHidden()
                .lineLimit(3...10)
        }
    }

    // MARK: Envio

    private func copiar() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(relatorio.tituloFinal + "\n\n" + relatorio.texto(tecnico, paraGitHub: false),
                                       forType: .string)
        aviso = String(localized: "Relatório copiado.")
    }

    private func abrirGitHub() {
        let tecnico = tecnico
        let (url, cortado) = relatorio.urlGitHub(tecnico)
        if cortado {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(relatorio.texto(tecnico), forType: .string)
        }
        #if DEBUG
        if Depuracao.gravarRelatorio(url: url, texto: relatorio.texto(tecnico)) { return }
        #endif
        NSWorkspace.shared.open(url)
        aviso = cortado ? String(localized: "O texto era longo demais para o endereço: o completo foi copiado, cole na issue.")
                        : String(localized: "Abri a página do GitHub (é preciso uma conta gratuita).")
    }

    private func enviarEmail() {
        let tecnico = tecnico
        let corpo = relatorio.texto(tecnico, paraGitHub: false)
        if let servico = NSSharingService(named: .composeEmail) {
            servico.recipients = [Contato.email]
            servico.subject = "Cutline: " + relatorio.tituloFinal
            let itens: [Any] = [corpo] + [tecnico?.ultimoCorte].compactMap(\.self)
            if servico.canPerform(withItems: itens) {
                servico.perform(withItems: itens)
                aviso = String(localized: "Abri o e-mail para \(Contato.email).")
                return
            }
        }
        // Sem o Mail configurado: o endereço (curto) por mailto e o texto copiado.
        var componentes = URLComponents()
        componentes.scheme = "mailto"
        componentes.path = Contato.email
        componentes.queryItems = [URLQueryItem(name: "subject", value: "Cutline: " + relatorio.tituloFinal)]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(corpo, forType: .string)
        if let url = componentes.url, NSWorkspace.shared.open(url) {
            aviso = String(localized: "O relatório foi copiado: cole no corpo do e-mail.")
        } else {
            aviso = String(localized: "Não achei um programa de e-mail. O relatório foi copiado; mande para \(Contato.email).")
        }
    }

    private func mostrarRegistros() {
        let pasta = InfoTecnica.pastaRegistros
        try? FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
        if let ultimo = tecnico?.ultimoCorte {
            NSWorkspace.shared.activateFileViewerSelecting([ultimo])
        } else {
            NSWorkspace.shared.open(pasta)
        }
    }
}

/// O app abre documentos sempre em abas; a janela do relatório fica sozinha.
private struct SemAbas: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Sonda() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Sonda: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.tabbingMode = .disallowed
        }
    }
}

/// Ajuda: relatar um problema, sugerir um recurso e a página do projeto.
struct ComandosAjuda: Commands {
    @Environment(\.openWindow) private var abrirJanela

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Relatar um Problema…") { abrirJanela(value: TipoRelatorio.problema) }
            Button("Sugerir um Recurso…") { abrirJanela(value: TipoRelatorio.recurso) }
            Divider()
            Link("Cutline no GitHub", destination: Contato.paginaGitHub)
        }
    }
}
