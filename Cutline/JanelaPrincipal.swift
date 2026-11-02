// Janela do editor, na ordem do Silhouette Studio: toolbar (arquivo à esquerda, Enviar à direita), barra
// de controle, abas e a tela; sobre a tela, ferramentas e painel lateral flutuando como peças de vidro.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension FocusedValues {
    @Entry var documento: Documento?
}

/// O que o painel de abrir arquivo aceita: Importar… (PDF, AI, SVG, EPS e imagens) ou a ferramenta Vetorizar (imagens).
private enum Importacao {
    case arquivo, imagem

    static let illustrator = UTType("com.adobe.illustrator.ai-image") ?? UTType(filenameExtension: "ai") ?? .pdf
    static let eps = UTType("com.adobe.encapsulated-postscript") ?? UTType(filenameExtension: "eps") ?? .data

    var tipos: [UTType] { self == .arquivo ? [.pdf, Self.illustrator, .svg, Self.eps, .image] : [.image] }
}

struct JanelaPrincipal: View {
    let doc: Documento
    @Environment(\.undoManager) private var gerenciador
    @Environment(Maquina.self) private var maquina
    @Environment(\.openWindow) private var abrirJanela
    @State private var controle = ControleVista()
    @State private var tamanhoTela = CGSize.zero
    @AppStorage("paineisRecolhidos") private var paineisRecolhidos = Painel.recolhidosPadrao
    // Menu Janela: o que aparece (vale para todas as janelas, como no Illustrator).
    @AppStorage("paineisOcultos") private var paineisOcultos = ""
    @AppStorage("ferramentasVisiveis") private var ferramentasVisiveis = true
    @AppStorage("barraControleVisivel") private var barraVisivel = true
    @State private var janela = JanelaFraca()
    @State private var envioAberto = false
    @AppStorage("reguas") private var reguasLigadas = true
    @State private var importacao: Importacao?
    /// A última pedida (o painel de arquivo pode fechar antes de devolver o arquivo escolhido).
    @State private var ultimaImportacao = Importacao.arquivo
    @State private var vetorizando: ImagemParaVetorizar?
    /// Arquivo sendo arrastado sobre a janela.
    @State private var soltando = false

    var body: some View {
        GeometryReader { _ in
            ZStack {
                if ferramentasVisiveis {
                    PainelFerramentas(doc: doc)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .padding(.leading, 14)
                }
                // Aviso e dica centrados na área à esquerda do painel lateral.
                ZStack {
                    if let aviso = doc.aviso { avisoImportacao(aviso) } else if doc.objetos.isEmpty { dicaVazia }
                }
                .padding(.trailing, larguraPainel)
                PainelLateral(doc: doc)
                    .padding(EdgeInsets(top: 8, leading: 0, bottom: 12, trailing: 12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        // Arquivos arrastados do Finder para a janela (o ponto está no espaço da tela, que fica atrás).
        .dropDestination(for: URL.self) { urls, ponto in soltar(urls, em: ponto) } isTargeted: { soltando = $0 }
        .overlay {
            if soltando {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .background {
            // A tela começa abaixo das abas (fora da área da barra de título).
            Tela(doc: doc, vista: $controle.vista, reguas: geometriaReguas)
                .onGeometryChange(for: CGSize.self, of: \.size) { tamanhoTela = $0 }
        }
        // A página se reajusta à janela (e às réguas e ao painel) até o usuário mexer no zoom ou na posição.
        .onChange(of: areaLivre, initial: true) { _, nova in
            controle.areaLivre = nova
            if !controle.vista.manual, tamanhoTela.width > 300, tamanhoTela.height > 300 { controle.ajustar() }
        }
        // O nome do documento fica só na aba.
        .toolbar(removing: .title)
        .toolbar { barraDeFerramentas }
        .sheet(isPresented: $envioAberto) { JanelaEnvio(doc: doc) }
        // Print & Cut sem as marcas lidas: a janela Enviar abre (se estava fechada) com as dicas por cima.
        .onChange(of: maquina.fila.contains { $0.origem == ObjectIdentifier(doc) && $0.situacao == .marcasNaoEncontradas }) { _, novo in
            if novo { envioAberto = true }
        }
        .background { Color.clear.sheet(item: $vetorizando) { JanelaVetorizar(doc: doc, origem: $0) } }
        .fileImporter(isPresented: Binding(get: { importacao != nil }, set: { if !$0 { importacao = nil } }),
                      allowedContentTypes: importacao?.tipos ?? [.image]) { resultado in
            if case .success(let url) = resultado { abrirImportado(url, perguntar: ultimaImportacao == .arquivo) }
        }
        .onChange(of: doc.ferramenta) { _, nova in
            // A ferramenta Vetorizar (I) abre a escolha da imagem e volta para a seleção.
            guard nova == .vetorizar else { return }
            doc.ferramenta = .selecao
            importar(.imagem)
        }
        .focusedSceneValue(\.documento, doc)
        .focusedSceneValue(\.controleVista, controle)
        .onChange(of: doc.pedidoImportar) { _, _ in importar(.arquivo) }
        .onChange(of: doc.pedidoImprimir) { _, _ in imprimir() }
        .onChange(of: doc.pedidoEnviar) { _, _ in if !doc.objetos.isEmpty { envioAberto = true } }
        .onChange(of: barraVisivel) { _, visivel in
            if let janela = janela.janela { BarraControle.mostrar(visivel, em: janela) }
        }
        .background(LeitorJanela { janela in
            // Barra de controle entre a toolbar e as abas; barra de abas sempre à mostra (também com um
            // documento só).
            self.janela.janela = janela
            if let janela { BarraControle.instalar(em: janela, doc: doc, controle: controle) }
            if let janela, let grupo = janela.tabGroup, !grupo.isTabBarVisible { janela.toggleTabBar(nil) }
            // O AppKit põe o foco no primeiro campo (espessura) ao abrir a janela, e aí as teclas de
            // atalho ficam com o campo: a janela abre com o foco na tela.
            DispatchQueue.main.async { if janela?.firstResponder is NSText { janela?.makeFirstResponder(nil) } }
            desligarDoArquivoDoStudio(janela)
            #if DEBUG
            Depuracao.salvarParaTeste(janela)
            #endif
        })
        .onAppear { doc.usar(gerenciador) }
        .onChange(of: gerenciador) { _, novo in doc.usar(novo) }
        .onDisappear { doc.usar(nil) }
        #if DEBUG
        .onAppear {
            Depuracao.preencher(doc)
            Depuracao.editarTextoParaTeste(doc)
            Depuracao.alterarParaTeste(doc)
            Depuracao.pathfinderParaTeste(doc)
            if let url = Depuracao.importarParaTeste { abrirImportado(url) }
            if let url = Depuracao.soltarParaTeste {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    _ = soltar([url], em: CGPoint(x: tamanhoTela.width / 2, y: tamanhoTela.height / 2))
                }
            }
            Depuracao.imprimirParaTeste(doc)
            Depuracao.agendarFoto()
            Depuracao.gravarMenus()
            if Depuracao.abrirEnvio { envioAberto = true }
            if let tipo = Depuracao.abrirRelatorio { abrirJanela(value: tipo) }
        }
        #endif
    }

    /// Um .studio3 aberto vira um documento novo do Cutline, ainda sem arquivo (como o Keynote faz com
    /// um PowerPoint): o macOS nunca grava o original, e ⌘S pergunta se grava por cima dele (o endereço fica em
    /// `doc.studio`) ou como documento do Cutline (Modelo/SalvarStudio.swift).
    private func desligarDoArquivoDoStudio(_ janela: NSWindow?) {
        guard doc.veioDoStudio, let documento = janela?.windowController?.document as? NSDocument else { return }
        doc.veioDoStudio = false
        guard let tipo = documento.fileType.flatMap({ UTType($0) }), tipo.conforms(to: .studio3) else { return }
        let nome = documento.fileURL?.deletingPathExtension().lastPathComponent
        doc.studio?.url = documento.fileURL
        documento.fileURL = nil
        documento.fileType = UTType.documentoCutline.identifier
        if let nome {
            documento.displayName = nome
            janela?.windowController?.synchronizeWindowTitleWithDocumentName()
        }
    }

    private func importar(_ tipo: Importacao) {
        importacao = tipo
        ultimaImportacao = tipo
    }

    /// Arquivos soltos na janela: documentos (.cutline, .studio3) abrem cada um na sua janela; o resto entra
    /// como em Importar… — uma imagem pergunta o que fazer e fica centrada onde foi solta.
    private func soltar(_ urls: [URL], em ponto: CGPoint) -> Bool {
        let arquivos = urls.filter(\.isFileURL)
        for url in arquivos {
            let tipo = UTType(filenameExtension: url.pathExtension) ?? .data
            if tipo.conforms(to: .documentoCutline) || tipo.conforms(to: .studio3) {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            } else {
                abrirImportado(url, centro: controle.vista.mm(ponto))
            }
        }
        return !arquivos.isEmpty
    }

    /// PDF, AI, SVG e EPS (Modelo/ImportarVetor.swift) → os caminhos entram na camada ativa, com um aviso do que
    /// ficou de fora; outra imagem → janela Vetorizar, que pergunta antes se a imagem vai sozinha, com o contorno
    /// externo ou com os internos (`perguntar`; a ferramenta Vetorizar vai direto aos ajustes). Quem decide é o
    /// conteúdo: o .ai e o .svg também são "imagem" para o macOS, e o painel da ferramenta Vetorizar aceita os dois.
    private func abrirImportado(_ url: URL, perguntar: Bool = true, centro: CGPoint? = nil) {
        let acesso = url.startAccessingSecurityScopedResource()
        defer { if acesso { url.stopAccessingSecurityScopedResource() } }
        guard let dados = try? Data(contentsOf: url) else {
            doc.aviso = String(localized: "Não foi possível abrir “\(url.lastPathComponent)”.")
            return
        }
        let tipo = UTType(filenameExtension: url.pathExtension) ?? .data
        let vetorialPeloNome = [.pdf, Importacao.illustrator, .svg, Importacao.eps].contains { tipo.conforms(to: $0) }
        guard ImportarVetor.formato(dados) != nil || vetorialPeloNome else {
            guard var imagem = ImagemParaVetorizar(url: url) else { doc.aviso = String(localized: "Não foi possível abrir a imagem."); return }
            imagem.perguntar = perguntar
            imagem.centro = centro
            vetorizando = imagem
            return
        }
        do {
            let resultado = try ImportarVetor.ler(dados)
            doc.inserirImportados(resultado.objetos)
            var partes: [String] = []
            if resultado.textos > 0 { partes.append(String(localized: "textos não importados (converta em contornos no Illustrator)")) }
            if resultado.imagens > 0 { partes.append(String(localized: "\(resultado.imagens) imagens não importadas")) }
            if resultado.objetos.isEmpty {
                doc.aviso = partes.isEmpty ? String(localized: "Nenhum caminho para importar em “\(url.lastPathComponent)”.")
                    : String(localized: "Nenhum caminho para importar em “\(url.lastPathComponent)”: \(partes.joined(separator: " · ")).")
            } else {
                partes.insert(String(localized: "\(resultado.objetos.count) caminhos"), at: 0)
                doc.aviso = String(localized: "Importado de “\(url.lastPathComponent)”: \(partes.joined(separator: " · ")).")
            }
        } catch {
            doc.aviso = error.localizedDescription
        }
    }

    /// Resumo da importação do Silhouette Studio, até o usuário dispensar.
    private func avisoImportacao(_ texto: String) -> some View {
        HStack(spacing: 10) {
            Image(.info)
                .foregroundStyle(.secondary)
            Text(texto)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button("OK") { withAnimation(.snappy(duration: 0.2)) { doc.aviso = nil } }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: 640)
        .glassEffect(.regular, in: .capsule)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 16)
    }

    /// Espaço que o menu lateral ocupa à direita (coluna fixa, faixa de ícones e margens).
    private var larguraPainel: Double { PainelLateral.ocupado(recolhidos: paineisRecolhidos, ocultos: paineisOcultos) }

    /// Até onde vão as ferramentas (ou só a margem, com elas ocultas).
    private var larguraFerramentas: Double { ferramentasVisiveis ? 62 : 10 }

    private var dicaVazia: some View {
        Text("Desenhe com as ferramentas à esquerda (P caneta, T texto, M, L e S formas) ou importe com ⇧⌘I.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .glassEffect(.regular, in: .capsule)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 16)
            .allowsHitTesting(false)
    }

    /// Réguas: logo abaixo das abas e à direita das ferramentas, até o painel lateral.
    private var geometriaReguas: GeometriaReguas? {
        guard reguasLigadas, tamanhoTela.width > 300 else { return nil }
        let topo = 8.0, esquerda = larguraFerramentas + 4, direita = tamanhoTela.width - max(larguraPainel - 4, 12)
        return GeometriaReguas(area: CGRect(x: esquerda, y: topo, width: max(direita - esquerda, 50),
                                            height: max(tamanhoTela.height - topo - 12, 50)))
    }

    /// Área da tela sem as peças flutuantes (ferramentas, réguas, painel lateral).
    private var areaLivre: CGRect {
        let esquerda = larguraFerramentas + (reguasLigadas ? 34 : 14), topo = reguasLigadas ? 40.0 : 16
        return CGRect(x: esquerda, y: topo, width: max(tamanhoTela.width - esquerda - 28 - larguraPainel, 50),
                      height: max(tamanhoTela.height - topo - 28, 50))
    }

    /// Painel de impressão sobre esta janela (com a janela Enviar aberta, sobre a do documento).
    private func imprimir() {
        let janela = NSApp.keyWindow.map { $0.sheetParent ?? $0 }
        Impressao.imprimir(doc, na: janela)
    }

    /// Ícone da toolbar no tamanho dos do sistema (os SVG têm 16 pt).
    private func rotulo(_ titulo: LocalizedStringKey, _ icone: ImageResource, tamanho: Double = 20) -> some View {
        Label { Text(titulo) } icon: { Image(icone).resizable().frame(width: tamanho, height: tamanho) }
    }

    /// Como a primeira linha do Studio: arquivo à esquerda; à direita a máquina (e a fila) e Enviar.
    /// Desfazer, zoom e as ajudas de desenho ficam na barra de controle; Importar, no menu Arquivo.
    @ToolbarContentBuilder
    private var barraDeFerramentas: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { NSDocumentController.shared.newDocument(nil) } label: { rotulo("Novo", .novo) }
                .help("Novo documento (⌘N)")
            Button { NSDocumentController.shared.openDocument(nil) } label: { rotulo("Abrir", .abrir) }
                .help("Abrir um documento do Cutline ou do Silhouette Studio (⌘O)")
            Button { NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil) } label: { rotulo("Salvar", .salvar) }
                .help("Salvar (⌘S)")
            Button { imprimir() } label: { rotulo("Imprimir", .imprimir) }
                .help("Imprimir em tamanho real (⌘P)")
        }
        // Sem o título no meio, é o espaçador que leva a máquina e o Enviar para a direita.
        ToolbarSpacer(.flexible)
        ToolbarItem {
            PilulaMaquina()
        }
        ToolbarSpacer(.fixed)
        ToolbarItem {
            // Ícone: o porta-lâmina (agulha) da máquina cortando o papel — desenho do owner no rascunho.
            Button { envioAberto = true } label: { rotulo("Enviar", .agulha, tamanho: 18) }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.glassProminent)
                .disabled(doc.objetos.isEmpty)
                .help("Enviar para a cortadora (⌘E)")
        }
        // O botão já é vidro (prominente): sem o fundo compartilhado da toolbar por trás (vidro sobre vidro).
        .sharedBackgroundVisibility(.hidden)
    }
}

/// Referência fraca à janela (guardar a NSWindow num @State a manteria viva depois de fechada).
final class JanelaFraca {
    weak var janela: NSWindow?
}
