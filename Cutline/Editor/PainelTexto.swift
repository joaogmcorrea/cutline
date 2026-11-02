// Painéis Caractere e Parágrafo do menu lateral (como os do Illustrator) e a lista de fontes, que também
// aparece na barra de controle. Caractere: digitando na tela, vale para as letras selecionadas (ou o que for
// digitado a seguir); fora da edição, para os textos selecionados inteiros; sem nenhum, para os próximos
// (Documento.mudarEstilo). Parágrafo: sempre o texto inteiro (Documento.mudarTexto).
import AppKit
import SwiftUI

// MARK: Caractere

struct SecaoCaractere: View {
    @Bindable var doc: Documento

    var body: some View {
        let estilo = doc.estiloDoTexto
        let objeto = doc.objetoTextoAtual
        let escala = doc.ancoraDaEdicao?.escala ?? objeto?.ancoraTexto?.escala ?? CGSize(width: 1, height: 1)
        VStack(alignment: .leading, spacing: 8) {
            BotaoFonte(doc: doc, estilo: estilo)
            MenuEstilo(doc: doc, estilo: estilo)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    CampoTipo(icone: .textoTamanho, dica: "Corpo da fonte", valor: estilo.tamanho, unidade: "pt",
                              sugestoes: [6, 8, 9, 10, 11, 12, 14, 18, 24, 30, 36, 48, 60, 72, 96, 144], minimo: 1, maximo: 1000) { v in
                        if let v { doc.mudarEstilo { $0.tamanho = v } }
                    }
                    CampoTipo(icone: .textoEntrelinha, dica: "Entrelinha (vazio = automática; a linha usa a maior)", valor: estilo.entrelinha,
                              automatico: "(\(numero(estilo.entrelinhaAutomatica)))", unidade: "pt",
                              sugestoes: [6, 8, 9, 10, 11, 12, 14, 18, 24, 30, 36, 48, 60, 72], minimo: 0, maximo: 5000) { v in
                        doc.mudarEstilo { $0.entrelinha = v }
                    }
                }
                GridRow {
                    CampoTipo(icone: .textoKerning, dica: "Kerning: vazio = o da fonte (Auto); 0 = sem kerning",
                              valor: estilo.kerning, automatico: String(localized: "Auto"), unidade: "",
                              sugestoes: [-100, -75, -50, -25, -10, -5, 0, 5, 10, 25, 50, 75, 100], minimo: -1000, maximo: 10_000) { v in
                        doc.mudarEstilo { $0.kerning = v }
                    }
                    CampoTipo(icone: .textoTracking, dica: "Tracking: espaço entre todas as letras (milésimos de em)",
                              valor: estilo.tracking, unidade: "",
                              sugestoes: [-100, -75, -50, -25, -10, -5, 0, 5, 10, 25, 50, 75, 100, 200], minimo: -1000, maximo: 10_000) { v in
                        if let v { doc.mudarEstilo { $0.tracking = v } }
                    }
                }
                GridRow {
                    CampoTipo(icone: .textoEscalaV, dica: "Escala vertical (do texto inteiro)", valor: escala.height * 100, unidade: "%",
                              sugestoes: [25, 50, 75, 100, 125, 150, 200], minimo: 1, maximo: 10_000) { v in
                        if let v { doc.definirEscalaTexto(vertical: v / 100) }
                    }
                    .disabled(objeto == nil)
                    CampoTipo(icone: .textoEscalaH, dica: "Escala horizontal (do texto inteiro)", valor: escala.width * 100, unidade: "%",
                              sugestoes: [25, 50, 75, 100, 125, 150, 200], minimo: 1, maximo: 10_000) { v in
                        if let v { doc.definirEscalaTexto(horizontal: v / 100) }
                    }
                    .disabled(objeto == nil)
                }
                GridRow {
                    CampoTipo(icone: .textoDeslocamento, dica: "Deslocamento da linha de base (positivo sobe)", valor: estilo.deslocamento,
                              unidade: "pt", sugestoes: [-12, -6, -3, -1, 0, 1, 3, 6, 12], minimo: -5000, maximo: 5000) { v in
                        if let v { doc.mudarEstilo { $0.deslocamento = v } }
                    }
                    CampoTipo(icone: .textoRotacao, dica: "Rotação de cada letra", valor: estilo.rotacao, unidade: "°",
                              sugestoes: [-90, -45, -30, -15, 0, 15, 30, 45, 90, 180], minimo: -360, maximo: 360) { v in
                        if let v { doc.mudarEstilo { $0.rotacao = v } }
                    }
                }
            }
            HStack(spacing: 2) {
                BotaoAlternar(icone: .textoCaixaAlta, dica: "Caixa alta", ligado: estilo.caixaAlta) {
                    doc.mudarEstilo { $0.caixaAlta.toggle() }
                }
                BotaoAlternar(icone: .textoVersalete, dica: "Versalete (o da fonte; sem ele, maiúsculas a 70 %)", ligado: estilo.versalete) {
                    doc.mudarEstilo { $0.versalete.toggle() }
                }
                BotaoAlternar(icone: .textoSobrescrito, dica: "Sobrescrito", ligado: estilo.posicao == .sobrescrito) {
                    doc.mudarEstilo { $0.posicao = $0.posicao == .sobrescrito ? .normal : .sobrescrito }
                }
                BotaoAlternar(icone: .textoSubscrito, dica: "Subscrito", ligado: estilo.posicao == .subscrito) {
                    doc.mudarEstilo { $0.posicao = $0.posicao == .subscrito ? .normal : .subscrito }
                }
                Spacer(minLength: 0)
                BotaoAlternar(icone: .textoSublinhado, dica: "Sublinhado (também é cortado)", ligado: estilo.sublinhado) {
                    doc.mudarEstilo { $0.sublinhado.toggle() }
                }
                BotaoAlternar(icone: .textoTachado, dica: "Tachado (também é cortado)", ligado: estilo.tachado) {
                    doc.mudarEstilo { $0.tachado.toggle() }
                }
            }
            Group {
                switch doc.alvoEstilo {
                case .letras: Text("Vale para as letras selecionadas.")
                case .digitacao: Text("Vale para o que for digitado agora. Selecione letras para mudá-las.")
                case .textos: Text("Vale para o texto inteiro. Para mudar só algumas letras, selecione-as digitando (T).")
                case .proximos: Text("Nenhum texto selecionado: vale para os próximos textos.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            // Como as ações rápidas do Illustrator para texto (Criar contornos); também no menu Objeto (⇧⌘O).
            if doc.temTextoParaCurvas {
                Button { doc.converterTextoEmCurvas() } label: {
                    Text("Converter em curvas").frame(maxWidth: .infinity)
                }
                .help("As letras viram caminhos com pontos editáveis e não dependem mais da fonte (⇧⌘O). Só volta a ser texto com ⌘Z.")
            }
        }
        // Enter num campo devolve o teclado ao texto que se digita na tela (a seleção continua lá).
        .onSubmit { doc.devolverFocoAoTexto() }
    }
}

// MARK: Parágrafo

struct SecaoParagrafo: View {
    @Bindable var doc: Documento

    var body: some View {
        let texto = doc.textoAtual
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(AlinhamentoTexto.allCases) { alinhamento in
                    BotaoAlternar(icone: alinhamento.icone, dica: alinhamento.dica, ligado: texto.alinhamento == alinhamento) {
                        doc.mudarTexto { $0.alinhamento = alinhamento }
                    }
                }
                Spacer()
                BotaoAlternar(icone: .textoMarcadores, dica: "Marcadores", ligado: texto.marcador == .bolinha) {
                    doc.mudarTexto { $0.marcador = $0.marcador == .bolinha ? .nenhum : .bolinha }
                }
                BotaoAlternar(icone: .textoNumeros, dica: "Numeração", ligado: texto.marcador == .numeros) {
                    doc.mudarTexto { $0.marcador = $0.marcador == .numeros ? .nenhum : .numeros }
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    CampoTipo(icone: .textoRecuoEsquerda, dica: "Recuo à esquerda", valor: texto.recuoEsquerda, unidade: "pt",
                              sugestoes: [0, 6, 12, 18, 24, 36, 48, 72], minimo: -5000, maximo: 5000) { v in
                        if let v { doc.mudarTexto { $0.recuoEsquerda = v } }
                    }
                    CampoTipo(icone: .textoRecuoDireita, dica: "Recuo à direita (texto alinhado à direita ou ao centro)",
                              valor: texto.recuoDireita, unidade: "pt",
                              sugestoes: [0, 6, 12, 18, 24, 36, 48, 72], minimo: -5000, maximo: 5000) { v in
                        if let v { doc.mudarTexto { $0.recuoDireita = v } }
                    }
                }
                GridRow {
                    CampoTipo(icone: .textoRecuoPrimeira, dica: "Recuo da primeira linha de cada parágrafo",
                              valor: texto.recuoPrimeira, unidade: "pt",
                              sugestoes: [0, 6, 12, 18, 24, 36, 48, 72], minimo: -5000, maximo: 5000) { v in
                        if let v { doc.mudarTexto { $0.recuoPrimeira = v } }
                    }
                }
                GridRow {
                    CampoTipo(icone: .textoEspacoAntes, dica: "Espaço antes do parágrafo", valor: texto.espacoAntes, unidade: "pt",
                              sugestoes: [0, 3, 6, 9, 12, 18, 24, 36], minimo: 0, maximo: 5000) { v in
                        if let v { doc.mudarTexto { $0.espacoAntes = v } }
                    }
                    CampoTipo(icone: .textoEspacoDepois, dica: "Espaço depois do parágrafo", valor: texto.espacoDepois, unidade: "pt",
                              sugestoes: [0, 3, 6, 9, 12, 18, 24, 36], minimo: 0, maximo: 5000) { v in
                        if let v { doc.mudarTexto { $0.espacoDepois = v } }
                    }
                }
            }
            Text("Cada linha é um parágrafo: o texto só quebra onde se tecla Enter. Vale para o texto inteiro.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onSubmit { doc.devolverFocoAoTexto() }
    }
}

private extension AlinhamentoTexto {
    var icone: ImageResource {
        switch self {
        case .esquerda: .textoEsquerda
        case .centro: .textoCentro
        case .direita: .textoDireita
        }
    }

    var dica: LocalizedStringKey {
        switch self {
        case .esquerda: "Alinhar à esquerda"
        case .centro: "Centralizar"
        case .direita: "Alinhar à direita"
        }
    }
}

// MARK: Peças

/// Número como nos campos (até duas casas, vírgula da região).
private func numero(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...1))) }

/// Campo numérico com ícone e menu de valores comuns, como os do painel Caractere do Illustrator. `valor`
/// nil = automático (o campo fica vazio e mostra `automatico`).
struct CampoTipo: View {
    let icone: ImageResource
    let dica: LocalizedStringKey
    let valor: Double?
    var automatico: String?
    let unidade: String
    let sugestoes: [Double]
    let minimo: Double
    let maximo: Double
    let definir: (Double?) -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(icone).resizable().frame(width: 16, height: 16).foregroundStyle(.secondary)
            HStack(spacing: 2) {
                // Confirma ao teclar Enter ou sair do campo; só aplica (e registra o desfazer) se mudou.
                TextField(dica, value: Binding<Double?>(get: { valor }, set: { novo in
                    let v = novo.map { min(max($0, minimo), maximo) }
                    if v != valor, v != nil || automatico != nil { definir(v) }
                }), format: .number.precision(.fractionLength(0...2)), prompt: automatico.map { Text($0) })
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                if !unidade.isEmpty { Text(unidade).foregroundStyle(.secondary) }
                Menu {
                    if automatico != nil {
                        Button("Auto") { definir(nil) }
                        Divider()
                    }
                    ForEach(sugestoes, id: \.self) { s in
                        Button(numero(s) + (unidade.isEmpty ? "" : " " + unidade)) { definir(s) }
                    }
                } label: {
                    Image(.descer).resizable().frame(width: 10, height: 10)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        }
        .frame(width: 118)
        .help(dica)
    }
}

/// Botão que liga e desliga, aceso na cor de destaque (como os da barra de controle).
struct BotaoAlternar: View {
    let icone: ImageResource
    let dica: LocalizedStringKey
    let ligado: Bool
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            Image(icone)
                .resizable()
                .frame(width: 18, height: 18)
                .foregroundStyle(ligado ? Color.accentColor : .secondary)
                .frame(width: 30, height: 26)
                .background(ligado ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(dica)
    }
}

/// Família do texto; abre a lista de todas as fontes do Mac, com busca.
struct BotaoFonte: View {
    let doc: Documento
    let estilo: EstiloCaractere
    var compacto = false
    @State private var aberta = false

    var body: some View {
        let instalada = CatalogoFontes.shared.instaladas.contains(estilo.fonte)
        Button { aberta.toggle() } label: {
            RotuloMenu(texto: estilo.fonte, compacto: compacto, faltando: !instalada)
        }
        .buttonStyle(.plain)
        .help(instalada ? "Fonte" as LocalizedStringKey
              : "Fonte não instalada neste Mac: o texto aparece com outra até ela ser instalada ou ativada (sem precisar fechar o Cutline)")
        #if DEBUG
        .onAppear { if Depuracao.listaFontesAberta, !compacto { aberta = true } }
        #endif
        .popover(isPresented: $aberta, arrowEdge: .bottom) {
            ListaFontes(atual: estilo.fonte) { familia in
                doc.mudarEstilo { $0.trocarFamilia(familia) }
                aberta = false
            }
        }
    }
}

/// Faces da família (Regular, Bold Italic…).
struct MenuEstilo: View {
    let doc: Documento
    let estilo: EstiloCaractere
    var compacto = false

    var body: some View {
        let faces = CatalogoFontes.shared.faces(estilo.fonte)
        let emUso = estilo.postscriptEmUso
        Menu {
            Picker("Estilo", selection: Binding(get: { emUso }, set: { novo in doc.mudarEstilo { $0.postscript = novo } })) {
                ForEach(faces) { Text($0.nome).tag($0.postscript) }
                if !faces.contains(where: { $0.postscript == emUso }) { Text(emUso).tag(emUso) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            RotuloMenu(texto: faces.first { $0.postscript == emUso }?.nome ?? emUso, compacto: compacto)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Estilo da fonte")
    }
}

/// Aparência dos menus de fonte e estilo: o nome e a setinha num campo, como os da barra de controle.
private struct RotuloMenu: View {
    let texto: String
    let compacto: Bool
    /// Fonte que não está instalada neste Mac (o texto aparece com outra até ela ser instalada).
    var faltando = false

    var body: some View {
        HStack(spacing: 6) {
            if faltando {
                Image(.alerta).resizable().frame(width: 13, height: 13).foregroundStyle(.orange)
            }
            Text(texto).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Image(.descer).resizable().frame(width: 10, height: 10).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, compacto ? 3 : 5)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}

/// Todas as famílias instaladas (sistema, usuário e Adobe Fonts ativadas), cada uma escrita nela mesma.
struct ListaFontes: View {
    let atual: String
    let escolher: (String) -> Void
    @State private var posicao: String?
    @State private var busca = ""
    @FocusState private var buscando: Bool

    /// Do catálogo: uma fonte instalada com a lista aberta já aparece nela.
    private var familias: [String] { CatalogoFontes.shared.familias }

    private var filtradas: [String] {
        busca.isEmpty ? familias : familias.filter { $0.localizedCaseInsensitiveContains(busca) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(.buscar).resizable().frame(width: 14, height: 14).foregroundStyle(.secondary)
                TextField("Buscar fonte", text: $busca)
                    .textFieldStyle(.plain)
                    .focused($buscando)
                    .onSubmit { if let primeira = filtradas.first { escolher(primeira) } }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .padding(10)
            Divider()
            if filtradas.isEmpty {
                Text("Nenhuma fonte encontrada").foregroundStyle(.secondary).frame(maxHeight: .infinity)
            } else {
                // Linhas da mesma altura: a lista abre já na fonte atual (scrollPosition), sem medir todas.
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtradas, id: \.self) { familia in
                            LinhaFonte(familia: familia, atual: familia == atual) { escolher(familia) }
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.vertical, 4)
                }
                .scrollPosition(id: $posicao, anchor: .center)
            }
            Divider()
            Text("\(familias.count) famílias instaladas")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(6)
        }
        .frame(width: 300, height: 440)
        .onAppear {
            posicao = atual
            buscando = true
        }
    }
}

private struct LinhaFonte: View {
    let familia: String
    let atual: Bool
    let escolher: () -> Void
    @State private var sobre = false

    var body: some View {
        let fonte = Fontes.amostra(familia, tamanho: 15)
        Button(action: escolher) {
            HStack(spacing: 8) {
                Image(.marcado).resizable().frame(width: 12, height: 12).foregroundStyle(Color.accentColor).opacity(atual ? 1 : 0)
                if Fontes.ehSimbolos(fonte) {
                    // Fonte de símbolos: o nome na fonte do sistema e uma amostra ao lado.
                    Text(familia).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(verbatim: "Abc").font(Font(fonte)).foregroundStyle(.secondary)
                } else {
                    Text(familia).font(Font(fonte)).lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .clipped()
            .background(sobre ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { sobre = $0 }
    }
}
