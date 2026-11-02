// Menu lateral (direita), como as dockas da Adobe: cada painel fica fixo na coluna de vidro (seções
// separadas por divisórias, recolhíveis pelo título) ou recolhido num ícone da faixa ao lado, que abre o
// painel flutuando ao clicar. O alfinete fixa ou recolhe; » recolhe todos, « fixa todos. As seções Cor e
// Traço ficam em PainelCor.swift e PainelTraco.swift; a Página em PainelPagina.swift; Caractere e Parágrafo
// em PainelTexto.swift.
import SwiftUI

/// Painéis do menu lateral, na ordem em que aparecem.
enum Painel: String, CaseIterable, Identifiable {
    case pagina, cor, traco, caractere, paragrafo, pathfinder, camadas

    var id: Self { self }

    var titulo: String {
        switch self {
        case .pagina: String(localized: "Página")
        case .cor: String(localized: "Cor")
        case .traco: String(localized: "Traço")
        case .caractere: String(localized: "Caractere")
        case .paragrafo: String(localized: "Parágrafo")
        case .pathfinder: String(localized: "Pathfinder")
        case .camadas: String(localized: "Camadas")
        }
    }

    var icone: ImageResource {
        switch self {
        case .pagina: .painelPagina
        case .cor: .painelCor
        case .traco: .painelTraco
        case .caractere: .painelCaractere
        case .paragrafo: .painelParagrafo
        case .pathfinder: .painelPathfinder
        case .camadas: .painelCamadas
        }
    }

    /// Recolhidos em ícone ao abrir o app pela primeira vez.
    static let recolhidosPadrao = "pathfinder"

    /// Os recolhidos (ou ocultos), guardados como "pathfinder,camadas" (preferência do app).
    static func conjunto(_ texto: String) -> Set<Painel> {
        Set(texto.split(separator: ",").compactMap { Painel(rawValue: String($0)) })
    }

    static func texto(_ conjunto: Set<Painel>) -> String {
        allCases.filter { conjunto.contains($0) }.map(\.rawValue).joined(separator: ",")
    }
}

struct PainelLateral: View {
    @Bindable var doc: Documento
    @State private var fechadas: Set<String> = {
        #if DEBUG
        Depuracao.secoesFechadas
        #else
        []
        #endif
    }()
    @AppStorage("modoCor") private var modoCor = ModoCor.cmyk
    @AppStorage("paineisRecolhidos") private var recolhidosTexto = Painel.recolhidosPadrao
    /// Desmarcados no menu Janela: não aparecem nem na coluna nem na faixa de ícones.
    @AppStorage("paineisOcultos") private var ocultosTexto = ""
    /// Painel recolhido aberto ao lado da faixa de ícones.
    @State private var aberto: Painel? = {
        #if DEBUG
        Depuracao.painelAberto
        #else
        nil
        #endif
    }()

    static let largura = 284.0
    static let larguraFaixa = 62.0
    private static let alturaIcone = 52.0

    /// Espaço que o menu ocupa à direita (coluna + faixa + margens), para as réguas e a área livre.
    static func ocupado(recolhidos: String, ocultos: String) -> Double {
        let visiveis = Set(Painel.allCases).subtracting(Painel.conjunto(ocultos))
        let iconizados = visiveis.intersection(Painel.conjunto(recolhidos))
        let coluna = visiveis.count > iconizados.count ? largura : 0
        let faixa = iconizados.isEmpty ? 0 : larguraFaixa + (coluna > 0 ? 8 : 0)
        return coluna + faixa > 0 ? coluna + faixa + 24 : 0
    }

    private var recolhidos: Set<Painel> { Painel.conjunto(recolhidosTexto) }
    private var ocultos: Set<Painel> { Painel.conjunto(ocultosTexto) }

    var body: some View {
        let visiveis = Painel.allCases.filter { !ocultos.contains($0) }
        let fixos = visiveis.filter { !recolhidos.contains($0) }
        let iconizados = visiveis.filter { recolhidos.contains($0) }
        HStack(alignment: .top, spacing: 8) {
            if !iconizados.isEmpty { faixa(iconizados) }
            if !fixos.isEmpty { coluna(fixos) }
        }
        .onChange(of: recolhidosTexto + "|" + ocultosTexto) { _, _ in
            if let aberto, !recolhidos.contains(aberto) || ocultos.contains(aberto) { self.aberto = nil }
        }
    }

    private func definirRecolhidos(_ novos: Set<Painel>) {
        withAnimation(.snappy(duration: 0.22)) { recolhidosTexto = Painel.texto(novos) }
    }

    // MARK: Coluna fixa

    private func coluna(_ fixos: [Painel]) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Recolher todos em ícones", image: .recolherTodos) { definirRecolhidos(Set(Painel.allCases)) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Recolher todos os painéis em ícones")
                }
                .padding(EdgeInsets(top: 8, leading: 16, bottom: -6, trailing: 12))
                ForEach(Array(fixos.enumerated()), id: \.element) { indice, painel in
                    if indice > 0 { Divider() }
                    secao(painel)
                }
            }
            .padding(.bottom, 4)
        }
        .frame(width: Self.largura)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
    }

    private func secao(_ painel: Painel) -> some View {
        let aberta = !fechadas.contains(painel.titulo)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        if aberta { fechadas.insert(painel.titulo) } else { fechadas.remove(painel.titulo) }
                    }
                } label: {
                    CabecalhoSecao(titulo: painel.titulo, aberta: aberta)
                }
                .buttonStyle(.plain)
                if aberta { acessorio(painel) }
                BotaoAlfinete(fixo: true) { definirRecolhidos(recolhidos.union([painel])) }
            }
            .padding(EdgeInsets(top: 13, leading: 16, bottom: 6, trailing: 12))
            if aberta {
                conteudo(painel)
                    .padding(EdgeInsets(top: 4, leading: 16, bottom: 14, trailing: 16))
            }
        }
    }

    // MARK: Faixa de ícones

    private func faixa(_ iconizados: [Painel]) -> some View {
        VStack(spacing: 0) {
            Button("Fixar todos", image: .fixarTodos) { definirRecolhidos([]) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .frame(height: 26)
                .help("Fixar todos os painéis na coluna")
            ForEach(iconizados) { painel in
                Button {
                    withAnimation(.snappy(duration: 0.18)) { aberto = aberto == painel ? nil : painel }
                } label: {
                    VStack(spacing: 3) {
                        Image(painel.icone).resizable().frame(width: 20, height: 20)
                        Text(painel.titulo).font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(width: Self.larguraFaixa - 10, height: Self.alturaIcone - 6)
                    .foregroundStyle(aberto == painel ? Color.white : Color.primary)
                    .background(RoundedRectangle(cornerRadius: 12).fill(aberto == painel ? Color.accentColor : .clear))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .frame(height: Self.alturaIcone)
                .help(painel.titulo)
            }
        }
        .padding(.vertical, 5)
        .frame(width: Self.larguraFaixa)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
        .overlay(alignment: .topLeading) {
            if let aberto, let i = iconizados.firstIndex(of: aberto) {
                // À esquerda da faixa, na altura do ícone.
                flutuante(aberto)
                    .offset(x: -(Self.largura + 8), y: Double(i) * Self.alturaIcone)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
            }
        }
    }

    /// Painel recolhido aberto ao lado do ícone: título, alfinete (fixar na coluna) e fechar.
    private func flutuante(_ painel: Painel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(painel.titulo).fontWeight(.semibold)
                Spacer()
                acessorio(painel)
                BotaoAlfinete(fixo: false) { definirRecolhidos(recolhidos.subtracting([painel])) }
                Button("Fechar", image: .fechar) { withAnimation(.snappy(duration: 0.18)) { aberto = nil } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .padding(EdgeInsets(top: 13, leading: 16, bottom: 6, trailing: 12))
            ScrollView {
                conteudo(painel)
                    .padding(EdgeInsets(top: 4, leading: 16, bottom: 14, trailing: 16))
            }
            .frame(maxHeight: 560)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: Self.largura)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
    }

    // MARK: Conteúdo

    @ViewBuilder
    private func conteudo(_ painel: Painel) -> some View {
        switch painel {
        case .pagina: SecaoPagina(doc: doc)
        case .cor: SecaoCor(doc: doc, modo: modoCor)
        case .traco: SecaoTraco(doc: doc)
        case .caractere: SecaoCaractere(doc: doc)
        case .paragrafo: SecaoParagrafo(doc: doc)
        case .pathfinder: SecaoPathfinder(doc: doc)
        case .camadas: SecaoCamadas(doc: doc)
        }
    }

    @ViewBuilder
    private func acessorio(_ painel: Painel) -> some View {
        if painel == .cor {
            Picker("Modo", selection: $modoCor) {
                ForEach(ModoCor.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
            .help("Modo de entrada (o documento guarda sempre CMYK)")
        }
    }
}

/// Alfinete do cabeçalho: no painel fixo, recolhe em ícone; no aberto pelo ícone, fixa na coluna.
private struct BotaoAlfinete: View {
    let fixo: Bool
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            Image(fixo ? .alfineteFixo : .alfinete).resizable().frame(width: 13, height: 13)
        }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(fixo ? "Recolher este painel em ícone" : "Fixar este painel na coluna")
    }
}

/// Título da seção; a seta aparece ao passar o mouse e gira quando a seção está aberta.
private struct CabecalhoSecao: View {
    let titulo: String
    let aberta: Bool
    @State private var sobre = false

    var body: some View {
        HStack(spacing: 8) {
            Text(titulo).fontWeight(.semibold)
            Image(.abrirSecao)
                .resizable()
                .frame(width: 11, height: 11)
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(aberta ? 90 : 0))
                .opacity(sobre || !aberta ? 1 : 0)
            Spacer()
        }
        .contentShape(Rectangle())
        .onHover { sobre = $0 }
    }
}

// MARK: - Camadas

/// Camadas como no Illustrator (a de cima é desenhada por último) e, dentro das abertas, os objetos.
private struct SecaoCamadas: View {
    @Bindable var doc: Documento
    @State private var renomeando: Camada.ID?
    @State private var confirmarApagar = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(doc.camadas) { camada in
                LinhaCamada(doc: doc, camada: camada, renomeando: $renomeando)
                if camada.aberta {
                    ForEach(doc.objetos(da: camada).reversed()) { objeto in
                        LinhaObjeto(doc: doc, objeto: objeto, camada: camada)
                    }
                }
            }
            Divider().padding(.top, 6)
            HStack(spacing: 4) {
                Text(verbatim: String(localized: "\(doc.camadas.count) camadas") + " · " + String(localized: "\(doc.objetos.count) objetos"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Mover seleção para a camada ativa", image: .moverParaCamada) { doc.moverSelecaoParaCamadaAtiva() }
                    .disabled(doc.selecao.isEmpty)
                    .help("Mover seleção para a camada ativa")
                Button("Nova camada", image: .novaCamada) { doc.novaCamada() }
                    .help("Nova camada")
                Button("Apagar camada ativa", image: .apagar) {
                    if let ativa = doc.camadas.first(where: { $0.id == doc.camadaAtiva }), !doc.objetos(da: ativa).isEmpty {
                        confirmarApagar = true
                    } else {
                        doc.apagarCamadaAtiva()
                    }
                }
                .disabled(doc.camadas.count < 2)
                .help("Apagar camada ativa")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.top, 6)
            .padding(.horizontal, 6)
        }
        .padding(.horizontal, -8)
        .confirmationDialog(textoApagar, isPresented: $confirmarApagar) {
            Button("Apagar", role: .destructive) { doc.apagarCamadaAtiva() }
        }
    }

    private var textoApagar: String {
        guard let ativa = doc.camadas.first(where: { $0.id == doc.camadaAtiva }) else { return "" }
        let n = doc.objetos(da: ativa).count
        return n == 1 ? String(localized: "Apagar “\(ativa.nome)” e o objeto dela?")
            : String(localized: "Apagar “\(ativa.nome)” e os \(n) objetos dela?")
    }
}

private struct LinhaCamada: View {
    @Bindable var doc: Documento
    let camada: Camada
    @Binding var renomeando: Camada.ID?
    @State private var nome = ""
    @State private var sobre = false
    @FocusState private var editando: Bool

    var body: some View {
        let ativa = camada.id == doc.camadaAtiva
        let temSelecao = doc.objetos(da: camada).contains { doc.selecao.contains($0.id) }
        HStack(spacing: 4) {
            BotaoIcone(icone: camada.visivel ? .olho : .olhoFechado, dica: camada.visivel ? "Ocultar camada" : "Mostrar camada",
                       apagado: !camada.visivel) {
                doc.alterarCamada(camada.id) { $0.visivel.toggle() }
            }
            BotaoIcone(icone: camada.travada ? .cadeado : .cadeadoAberto, dica: camada.travada ? "Destravar camada" : "Travar camada",
                       apagado: !camada.travada) {
                doc.alterarCamada(camada.id) { $0.travada.toggle() }
            }
            RoundedRectangle(cornerRadius: 1.5)
                .fill(camada.corDaBarra)
                .frame(width: 3, height: 16)
            Button {
                // Abrir e fechar não é edição (não entra no desfazer).
                if let i = doc.camadas.firstIndex(where: { $0.id == camada.id }) { doc.camadas[i].aberta.toggle() }
            } label: {
                Image(.abrirSecao)
                    .resizable()
                    .frame(width: 10, height: 10)
                    .rotationEffect(.degrees(camada.aberta ? 90 : 0))
                    .frame(width: 14, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            if renomeando == camada.id {
                TextField("Nome", text: $nome)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .focused($editando)
                    .onSubmit(terminarNome)
                    .onChange(of: editando) { _, foco in if !foco { terminarNome() } }
                    .onAppear {
                        nome = camada.nome
                        editando = true
                    }
            } else {
                Text(camada.nome)
                    .fontWeight(ativa ? .semibold : .regular)
                    .lineLimit(1)
                    .opacity(camada.visivel ? 1 : 0.4)
                    .onTapGesture(count: 2) { renomeando = camada.id }
                    .help("Duplo clique para renomear")
            }
            Spacer(minLength: 4)
            if temSelecao {
                RoundedRectangle(cornerRadius: 1.5).fill(camada.corDaBarra).frame(width: 7, height: 7)
            }
            Button {
                doc.selecionarCamada(camada)
            } label: {
                Circle()
                    .strokeBorder(.secondary, lineWidth: 1.5)
                    .background(Circle().fill(temSelecao ? Color.secondary : .clear).padding(2.5))
                    .frame(width: 11, height: 11)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Selecionar tudo da camada")
        }
        .padding(.horizontal, 6)
        .frame(height: 28)
        .background(ativa ? Color.primary.opacity(0.08) : (sobre ? Color.primary.opacity(0.04) : .clear), in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture { doc.camadaAtiva = camada.id }
        .onHover { sobre = $0 }
    }

    private func terminarNome() {
        guard renomeando == camada.id else { return }
        let novo = nome.trimmingCharacters(in: .whitespaces)
        if !novo.isEmpty, novo != camada.nome { doc.alterarCamada(camada.id) { $0.nome = novo } }
        renomeando = nil
    }
}

private struct LinhaObjeto: View {
    @Bindable var doc: Documento
    let objeto: Objeto
    let camada: Camada
    @State private var sobre = false

    var body: some View {
        let selecionado = doc.selecao.contains(objeto.id)
        HStack(spacing: 4) {
            BotaoIcone(icone: objeto.oculto ? .olhoFechado : .olho, dica: objeto.oculto ? "Mostrar" : "Ocultar", apagado: objeto.oculto) {
                doc.alterarObjeto(objeto.id) { $0.oculto.toggle() }
            }
            BotaoIcone(icone: objeto.travado ? .cadeado : .cadeadoAberto, dica: objeto.travado ? "Destravar" : "Travar",
                       apagado: !objeto.travado) {
                doc.alterarObjeto(objeto.id) { $0.travado.toggle() }
            }
            // Objetos de um grupo um pouco para dentro (um degrau por grupo).
            Color.clear.frame(width: 21 + 12 * Double(objeto.grupos.count))
            amostra
            Text(objeto.nome)
                .fontWeight(selecionado ? .semibold : .regular)
                .lineLimit(1)
                .opacity(doc.visivel(objeto) ? 1 : 0.4)
            if !objeto.corta {
                Image(.naoCorta)
                    .resizable()
                    .frame(width: 12, height: 12)
                    .foregroundStyle(.secondary)
                    .help("Sem traço: não vai para a máquina")
            }
            Spacer(minLength: 4)
            Text("\(Int(objeto.quadro.width.rounded())) × \(Int(objeto.quadro.height.rounded()))")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(selecionado ? camada.corDaBarra : .clear)
                .frame(width: 7, height: 7)
                .frame(width: 18)
        }
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(selecionado ? Color.accentColor.opacity(0.18) : (sobre ? Color.primary.opacity(0.04) : .clear),
                    in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture {
            guard !doc.intocavel(objeto) else { return }
            if NSEvent.modifierFlags.contains(.shift) {
                doc.selecao.formSymmetricDifference([objeto.id])
            } else {
                doc.selecao = [objeto.id]
            }
            doc.camadaAtiva = camada.id
        }
        .onHover { sobre = $0 }
    }

    /// Preenchimento dentro e traço como moldura (como no protótipo); imagem = cinza.
    private var amostra: some View {
        let forma = Rectangle()
        return ZStack {
            if objeto.imagem != nil {
                forma.fill(.gray.opacity(0.35))
            } else if let preenchimento = objeto.preenchimento {
                forma.fill(preenchimento.cor)
            }
            if objeto.corta { forma.strokeBorder(objeto.traco.cor, lineWidth: 2) }
        }
        .frame(width: 12, height: 12)
        .overlay(forma.strokeBorder(.primary.opacity(0.25), lineWidth: 0.5))
    }
}

/// Botãozinho de ícone das linhas de camada (olho, cadeado).
private struct BotaoIcone: View {
    let icone: ImageResource
    let dica: LocalizedStringKey
    let apagado: Bool
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            Image(icone)
                .resizable()
                .frame(width: 13, height: 13)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(apagado ? 0.45 : 1)
        .help(dica)
    }
}
