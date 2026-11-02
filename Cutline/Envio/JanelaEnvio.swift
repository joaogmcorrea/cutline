// Janela Enviar (estilo Silhouette Studio): prévia da folha, máquina, "cortar por cor de linha"
// e os ajustes da cor escolhida (sliders horizontais).
import AppKit
import CutlineKit
import SwiftUI
import UniformTypeIdentifiers

struct JanelaEnvio: View {
    @Bindable var doc: Documento
    @Environment(Maquina.self) private var maquina
    @Environment(\.dismiss) private var fechar
    @State private var corEscolhida: CMYK?
    @State private var nomeMaterial = ""
    @State private var salvandoMaterial = false
    @State private var apagandoMaterial = false
    /// Trabalho deste documento em que a máquina não achou as marcas (abre a janela das dicas).
    @State private var avisoMarcas: Trabalho?
    /// Cor sendo arrastada na tabela (para mudar a ordem do corte).
    @State private var arrastando: CMYK?
    private var globais: AjustesGlobais { .shared }

    private var marcasNaoLidas: Trabalho? {
        maquina.fila.first { $0.origem == ObjectIdentifier(doc) && $0.situacao == .marcasNaoEncontradas }
    }

    /// O último envio deste documento (o rodapé mostra como ele está).
    private var ultimoEnvio: Trabalho? { maquina.fila.last { $0.origem == ObjectIdentifier(doc) } }

    var body: some View {
        let linhas = doc.linhasDeCorte
        let atual = linhas.first { $0.cor == corEscolhida } ?? linhas.first
        HStack(spacing: 0) {
            PreviaFolha(doc: doc, linhas: linhas, destaque: atual?.cor)
                .padding(28)
                .frame(width: 380)
                .frame(maxHeight: .infinity)
                .background(.black.opacity(0.06))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    AvisoStudio()
                    CartaoMaquina(comBase: doc.comBase, base: doc.base(para: maquina.hardware))
                    if !maquina.fila.isEmpty { ListaFila() }
                    tabela(linhas, atual: atual?.cor)
                    if doc.marcas { printAndCut }
                    if let atual { detalhe(atual) }
                }
                .padding(20)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { rodape(linhas, atual: atual?.cor) }
        .frame(width: 1000, height: 680)
        .task {
            if case .desconectada = maquina.estado { await maquina.conectar() }
            if case .erro = maquina.estado { await maquina.conectar() }
            #if DEBUG
            // CUTLINE_TESTE_ENVIAR=1 (só com a máquina simulada): envia sozinho, sem fixar os ajustes no arquivo.
            if Depuracao.enviarParaTeste { maquina.enfileirar(doc.trabalho(nome: "Teste")) }
            // CUTLINE_TESTE_TESTECORTE=x,y (com CUTLINE_SIMULAR): põe o teste de corte em x,y mm e o envia.
            if let alvo = Depuracao.testeDeCorte, let cor = doc.linhasDeCorte.first?.cor {
                doc.moverTeste(para: alvo)
                maquina.enfileirar(doc.trabalhoDeTeste(cor))
            }
            // CUTLINE_TESTE_ORDEM=1: a última cor vai para o topo, pelo mesmo caminho do arrastar.
            if ProcessInfo.processInfo.environment["CUTLINE_TESTE_ORDEM"] != nil, let ultima = doc.linhasDeCorte.last {
                doc.moverLinha(ultima.cor, para: 0)
            }
            #endif
        }
        .onChange(of: marcasNaoLidas?.id, initial: true) { _, novo in if novo != nil { avisoMarcas = marcasNaoLidas } }
        .sheet(item: $avisoMarcas) { JanelaMarcas(trabalho: $0) }
    }

    // MARK: Tabela por cor

    private func tabela(_ linhas: [LinhaCorte], atual: CMYK?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cortar por cor de linha").font(.headline)
            if linhas.count > 1 {
                Text("A máquina corta de cima para baixo. Arraste uma cor (ou use as setas) para mudar a ordem.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 2) {
                ForEach(Array(linhas.enumerated()), id: \.element.id) { indice, linha in
                    linhaTabela(linha, indice: indice, total: linhas.count, escolhida: linha.cor == atual)
                        // Arrastar a linha inteira muda a ordem na hora, enquanto passa pelas outras.
                        .onDrag {
                            arrastando = linha.cor
                            return NSItemProvider(object: linha.cor.descricao as NSString)
                        }
                        .onDrop(of: [.text], delegate: SoltarCor(cor: linha.cor, doc: doc, arrastando: $arrastando))
                }
            }
        }
    }

    private func linhaTabela(_ linha: LinhaCorte, indice: Int, total: Int, escolhida: Bool) -> some View {
        let config = doc.config(linha.cor)
        return HStack(spacing: 10) {
            Image(.arrastar)
                .foregroundStyle(.tertiary)
                .opacity(total > 1 ? 1 : 0)
                .help("Arraste para mudar a ordem do corte")
            Toggle("Ligado", isOn: vinculo(linha.cor).ligado)
                .labelsHidden()
                .toggleStyle(.checkbox)
            Text("\(indice + 1)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 14)
            RoundedRectangle(cornerRadius: 4)
                .fill(linha.cor.cor)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.15)))
                .frame(width: 26, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(Material.exibir(config.material))
                Text(verbatim: [String(localized: "\(linha.objetos.count) objetos"),
                                config.ligado ? nil : String(localized: "não corta"), config.modificado ? String(localized: "modificado") : nil].compactMap(\.self).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .opacity(config.envia ? 1 : 0.45)
            Spacer()
            HStack(spacing: 2) {
                Button("Cortar antes", image: .subir) { doc.moverLinha(linha.cor, paraCima: true) }
                    .disabled(indice == 0)
                Button("Cortar depois", image: .descer) { doc.moverLinha(linha.cor, paraCima: false) }
                    .disabled(indice == total - 1)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(escolhida ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture { corEscolhida = linha.cor }
    }

    // MARK: Print & Cut

    /// Lembrete do Print & Cut e aviso dos cortes que passam da área entre as marcas.
    private var printAndCut: some View {
        let fora = doc.objetosForaDasMarcas
        return VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("**Print & Cut:** imprima a página em 100 % (⌘P) e ponha a folha na base na mesma posição da tela, com o quadrado no canto superior esquerdo. A máquina lê as marcas antes de cortar (até 40 s).")
            } icon: {
                Image(.marcas)
            }
            Text(descricaoMarcas)
                .foregroundStyle(.secondary)
            if fora > 0 {
                Label("\(fora) objetos passam da área entre as marcas — o que ficar de fora não é cortado.", image: .alerta)
                    .foregroundStyle(.orange)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Onde a máquina vai procurar as marcas (tem de ser onde a folha foi impressa).
    private var descricaoMarcas: String {
        let c = doc.configMarcas
        let mm = { (v: Double) in v.formatted(.number.precision(.fractionLength(0...3))) }
        let margem = c.margem.map { String(localized: "\(mm($0)) mm da borda") }
            ?? String(localized: "margens de \(mm(c.esquerda)), \(mm(c.topo)), \(mm(c.direita)) e \(mm(c.baixo)) mm")
        return String(localized: "Marcas a \(margem), cantoneiras de \(mm(c.comprimento)) mm. Muda no painel Página.")
    }

    // MARK: Detalhe da cor escolhida

    private func detalhe(_ linha: LinhaCorte) -> some View {
        let cor = linha.cor
        let config = doc.config(cor)
        let padrao = config.valoresDoMaterial ?? config.ajustes
        let ajustes = vinculo(cor).ajustes
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Picker("Material", selection: Binding(
                    get: { config.material },
                    set: { nome in
                        guard let material = globais.material(nome) else { return }
                        var nova = config
                        nova.material = nome
                        nova.ajustes = material.ajustes
                        doc.definirConfig(nova, para: cor)
                    })) {
                    ForEach(Material.todos) { Text(Material.exibir($0.nome)).tag($0.nome) }
                    if !globais.materiais.isEmpty {
                        Divider()
                        Section("Meus materiais") {
                            ForEach(globais.materiais) { Text($0.nome).tag($0.nome) }
                        }
                    }
                    // Material que veio no arquivo e não existe neste Mac: continua aparecendo.
                    if globais.material(config.material) == nil {
                        Divider()
                        Text("\(config.material) (do arquivo)").tag(config.material)
                    }
                }
                menuMaterial(config, cor: cor)
            }
            LabeledContent("Ferramenta") {
                Text(maquina.info?.autoblade == false ? "Lâmina manual" : "AutoBlade (ajuste automático)")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Text("Ajustes").fontWeight(.semibold)
                Text(config.modificado ? "· modificado" : globais.material(config.material) == nil ? "· do arquivo" : "· do material")
                    .foregroundStyle(.secondary)
                if config.modificado {
                    Button("Reverter") {
                        var nova = config
                        nova.ajustes = padrao
                        doc.definirConfig(nova, para: cor)
                    }
                    .buttonStyle(.link)
                }
            }

            // Uma linha por ajuste (slider horizontal compacto).
            VStack(spacing: 10) {
                Ajuste(titulo: "Força", unidade: "pressão", faixa: CutSettings.forceRange, valor: ajustes.force,
                       padrao: padrao.force) { Image(.forca).resizable().scaledToFit() }
                Ajuste(titulo: "Velocidade", unidade: "cm/s", faixa: 1...maquina.velocidadeMaxima, valor: ajustes.speed,
                       padrao: padrao.speed) { Image(.velocidade).resizable().scaledToFit() }
                Ajuste(titulo: "Lâmina", unidade: "profundidade", faixa: CutSettings.bladeRange, valor: ajustes.blade,
                       padrao: padrao.blade) { Image(.lamina).resizable().scaledToFit() }
                Ajuste(titulo: "Passadas", unidade: "repetições", faixa: CutSettings.passesRange, valor: ajustes.passes,
                       padrao: padrao.passes) { Image(.passadas).resizable().scaledToFit() }
            }
            .padding(.vertical, 4)
            .disabled(!config.envia)
            .opacity(config.envia ? 1 : 0.4)

            Text("Guardados neste arquivo e lembrados pelo app para esta cor nos próximos arquivos.")
                .font(.caption)
                .foregroundStyle(.secondary)

            let (mm, segundos) = estimativa(linha, config.ajustes)
            HStack(spacing: 14) {
                Text("**\(mm / 10, format: .number.precision(.fractionLength(1))) cm** de corte")
                if config.ajustes.passes > 1 {
                    Text("≈ \(Text(tempo(segundos)).fontWeight(.semibold)) em \(config.ajustes.passes) passadas")
                } else {
                    Text("≈ \(Text(tempo(segundos)).fontWeight(.semibold))")
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    /// Salvar os ajustes como material próprio, atualizar ou apagar um dos "Meus materiais".
    private func menuMaterial(_ config: ConfigCorte, cor: CMYK) -> some View {
        let proprio = globais.ehDoUsuario(config.material)
        return Menu {
            Button("Salvar ajustes como material…") {
                nomeMaterial = ""
                salvandoMaterial = true
            }
            if proprio {
                Button("Atualizar “\(config.material)” com estes ajustes") {
                    globais.salvarMaterial(config.material, ajustes: config.ajustes)
                }
                .disabled(!config.modificado)
                Divider()
                Button("Apagar “\(config.material)”…", role: .destructive) { apagandoMaterial = true }
            }
        } label: {
            Image(.mais)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Meus materiais")
        .alert("Salvar como material", isPresented: $salvandoMaterial) {
            TextField("Nome do material", text: $nomeMaterial)
            Button("Salvar") {
                let nome = nomeMaterial.trimmingCharacters(in: .whitespaces)
                guard globais.salvarMaterial(nome, ajustes: config.ajustes) else { return }
                var nova = config
                nova.material = nome
                doc.definirConfig(nova, para: cor)
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Força \(config.ajustes.force), velocidade \(config.ajustes.speed), lâmina \(config.ajustes.blade), \(String(localized: "\(config.ajustes.passes) passadas")). Fica disponível em todos os arquivos.")
        }
        .confirmationDialog("Apagar “\(config.material)” de Meus materiais?", isPresented: $apagandoMaterial) {
            Button("Apagar", role: .destructive) { globais.apagarMaterial(config.material) }
        } message: {
            Text("Os arquivos que usam este material continuam com os ajustes guardados neles.")
        }
    }

    // MARK: Rodapé

    private func rodape(_ linhas: [LinhaCorte], atual: CMYK?) -> some View {
        let camadas = doc.camadasParaEnviar
        let segundos = linhas.reduce(0.0) { total, linha in
            let config = doc.config(linha.cor)
            return config.envia ? total + estimativa(linha, config.ajustes).1 : total
        }
        return HStack(spacing: 14) {
            situacao
            Spacer()
            if !camadas.isEmpty {
                Text(verbatim: String(localized: "\(camadas.count) cores") + " · ≈ " + tempo(segundos))
                    .foregroundStyle(.secondary)
            }
            Button("Fechar") { fechar() }
                .keyboardShortcut(.cancelAction)
            Button("Testar corte") {
                if let atual { maquina.enfileirar(doc.trabalhoDeTeste(atual)) }
            }
            .controlSize(.large)
            .disabled(atual == nil || maquina.studioAberto)
            .help(atual.map { "Corta só o quadrado com o triângulo, no lugar marcado na folha (arraste para mudar), com os ajustes de \(Material.exibir(doc.config($0).material))" as LocalizedStringKey }
                  ?? "Corta só o quadrado com o triângulo, no lugar marcado na folha")
            Button {
                // Entra na fila: se a máquina estiver ocupada, corta quando ela terminar o anterior.
                doc.fixarAjustesDoEnvio()
                let janela = NSApp.keyWindow.map { $0.sheetParent ?? $0 }
                maquina.enfileirar(doc.trabalho(nome: janela?.title ?? String(localized: "Sem título")))
            } label: {
                Label("Enviar", image: .agulha)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(camadas.isEmpty || maquina.studioAberto)
            .help(maquina.studioAberto ? "Feche o Silhouette Studio para enviar" as LocalizedStringKey
                  : maquina.pendentes > 0 ? "Entra na fila: a máquina corta quando terminar o trabalho anterior" : "Enviar para a cortadora")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private var situacao: some View {
        if maquina.studioAberto {
            Label("Feche o Silhouette Studio para enviar.", image: .alerta)
                .foregroundStyle(.orange)
        } else if marcasNaoLidas != nil {
            HStack(spacing: 8) {
                Label("A máquina não achou as marcas de registro.", image: .alerta)
                    .foregroundStyle(.orange)
                Button("O que conferir") { avisoMarcas = marcasNaoLidas }
            }
        } else if let ultimo = ultimoEnvio, case .erro(let texto) = ultimo.situacao {
            HStack(spacing: 8) {
                Label(texto, image: .alerta)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                Button("Tentar de novo") { maquina.tentarDeNovo(ultimo.id) }
            }
        } else if let ultimo = ultimoEnvio, ultimo.situacao == .aguardando {
            let frente = maquina.naFrente(de: ultimo.id)
            Label(frente == 0 ? "Na fila: é o próximo." as LocalizedStringKey : "Na fila: \(frente) trabalhos na frente.", image: .relogio)
                .foregroundStyle(.secondary)
        } else {
            situacaoMaquina
        }
    }

    @ViewBuilder
    private var situacaoMaquina: some View {
        switch maquina.estado {
        case .enviando(let texto):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(texto)
            }
        case .enviado:
            Label("Enviado. A máquina terminou o corte.", image: .concluido)
                .foregroundStyle(.green)
        case .erro(let mensagem):
            Label(mensagem, image: .alerta)
                .foregroundStyle(.orange)
                .lineLimit(2)
        default:
            EmptyView()
        }
    }

    // MARK: Apoio

    private func vinculo(_ cor: CMYK) -> Binding<ConfigCorte> {
        Binding(get: { doc.config(cor) }, set: { doc.definirConfig($0, para: cor) })
    }

    /// Comprimento × passadas ÷ velocidade (≈ cm/s).
    private func estimativa(_ linha: LinhaCorte, _ ajustes: CutSettings) -> (Double, Double) {
        let mm = linha.comprimentoMM
        return (mm, mm / 10 * Double(ajustes.passes) / Double(max(ajustes.speed, 1)))
    }

    private func tempo(_ segundos: Double) -> String {
        segundos < 60 ? "\(max(1, Int(segundos.rounded()))) s" : "\(Int(segundos) / 60) min \(Int(segundos) % 60) s"
    }
}

/// Folha A4 com os cortes: a cor escolhida em destaque; as desligadas somem. No Print & Cut, com as marcas.
/// O teste de corte aparece tracejado e se arrasta para qualquer lugar da folha.
struct PreviaFolha: View {
    let doc: Documento
    let linhas: [LinhaCorte]
    let destaque: CMYK?
    /// Onde estava o teste quando o arrasto começou (mm).
    @State private var testeNoInicio: CGPoint?

    /// mm da página → pontos da prévia.
    private static func transformacao(_ tamanho: CGSize) -> CGAffineTransform {
        let pagina = Documento.pagina
        let m = 8.0
        let escala = min(tamanho.width / (pagina.width + 2 * m), tamanho.height / (pagina.height + 2 * m))
        let origem = CGPoint(x: (tamanho.width - pagina.width * escala) / 2, y: (tamanho.height - pagina.height * escala) / 2)
        return CGAffineTransform(a: escala, b: 0, c: 0, d: escala, tx: origem.x, ty: origem.y)
    }

    var body: some View {
        GeometryReader { geometria in
            folha
                .gesture(arrastarTeste(Self.transformacao(geometria.size)))
                .help("Arraste o teste de corte (o quadrado tracejado) para onde quiser testar na folha")
        }
    }

    /// Arrastar o teste; clicar em outro lugar da folha o leva para lá.
    private func arrastarTeste(_ t: CGAffineTransform) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesto in
                let paraMM = t.inverted()
                if testeNoInicio == nil {
                    let p = gesto.startLocation.applying(paraMM)
                    let caixa = CGRect(origin: doc.posicaoTeste, size: CGSize(width: TesteCorte.lado, height: TesteCorte.lado))
                    testeNoInicio = caixa.insetBy(dx: -3, dy: -3).contains(p)
                        ? doc.posicaoTeste : CGPoint(x: p.x - TesteCorte.lado / 2, y: p.y - TesteCorte.lado / 2)
                }
                guard let inicio = testeNoInicio else { return }
                doc.moverTeste(para: CGPoint(x: inicio.x + gesto.translation.width / t.a, y: inicio.y + gesto.translation.height / t.d))
            }
            .onEnded { _ in testeNoInicio = nil }
    }

    private var folha: some View {
        Canvas { ctx, tamanho in
            let pagina = Documento.pagina
            let m = 8.0
            let t = Self.transformacao(tamanho)
            let escala = t.a
            let folha = CGRect(origin: .zero, size: pagina)
            ctx.fill(Path(roundedRect: folha.insetBy(dx: -m, dy: -m).applying(t), cornerRadius: 3 * escala),
                     with: .color(.gray.opacity(0.35)))
            var sombra = ctx
            sombra.addFilter(.shadow(color: .black.opacity(0.18), radius: 10, y: 4))
            sombra.fill(Path(folha.applying(t)), with: .color(.white))
            if doc.marcas {
                for retangulo in doc.configMarcas.retangulos { ctx.fill(Path(retangulo.applying(t)), with: .color(.black)) }
            }
            for linha in linhas where doc.config(linha.cor).envia {
                let forte = linha.cor == destaque
                for objeto in linha.objetos {
                    let tracejado = objeto.estilo.linha.padrao?.map { CGFloat($0 * escala) } ?? []
                    ctx.stroke(objeto.caminho.applying(t), with: .color(linha.cor.cor.opacity(forte ? 1 : 0.35)),
                               style: StrokeStyle(lineWidth: forte ? 1.6 : 0.8, dash: tracejado))
                }
            }
            var teste = Path()
            for caminho in TesteCorte.caminhos(em: doc.posicaoTeste) { teste.addLines(caminho.map { $0.applying(t) }) }
            ctx.stroke(teste, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
        }
    }
}

/// Cartão da cortadora: ilustração, modelo, conexão e estado; com mais de uma ao alcance, a escolha.
struct CartaoMaquina: View {
    @Environment(Maquina.self) private var maquina
    /// Base de corte do documento (na janela Enviar); nil no menu da máquina da toolbar.
    var comBase: Bool?
    /// A base que vai para a máquina (na janela Enviar).
    var base: CuttingMat?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                IlustracaoPortrait()
                    .frame(width: 96, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(maquina.info == nil ? maquina.atual?.model ?? String(localized: "Cortadora Silhouette") : maquina.nomeModelo)
                        .font(.headline)
                    Text([maquina.atual?.link == .usb ? "USB" : "Bluetooth", maquina.atual?.serial.map { String(localized: "nº \($0)") }, maquina.firmware]
                        .compactMap(\.self).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let comBase {
                        Text(comBase ? "\(base?.nome ?? String(localized: "Com base de corte")) · muda no painel Página"
                             : "Sem base de corte (folha direto) · muda no painel Página")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                estado
            }
            if case .escolher(let lista) = maquina.estado {
                escolha(lista)
            }
        }
        .padding(12)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private func escolha(_ lista: [DiscoveredCutter]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Encontrei \(lista.count) cortadoras. Qual delas?")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(lista) { cortadora in
                HStack {
                    Text(Self.rotulo(cortadora))
                    Spacer()
                    Button("Conectar") { Task { await maquina.conectar(cortadora) } }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.leading, 110)
    }

    /// "Portrait 4 · nº 0000001" (no cabo, "· USB") — o número de série distingue máquinas do mesmo modelo.
    static func rotulo(_ cortadora: DiscoveredCutter) -> String {
        [cortadora.model, cortadora.serial.map { String(localized: "nº \($0)") }, cortadora.link == .usb ? "USB" : nil]
            .compactMap(\.self).joined(separator: " · ")
    }

    @ViewBuilder
    private var estado: some View {
        if maquina.studioAberto {
            indicador(.orange, "Silhouette Studio aberto")
        } else {
            estadoDaConexao
        }
    }

    @ViewBuilder
    private var estadoDaConexao: some View {
        switch maquina.estado {
        case .desconectada, .erro:
            HStack(spacing: 8) {
                indicador(.secondary, "Desconectada")
                Button("Conectar") { Task { await maquina.conectar() } }
            }
        case .conectando:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Procurando a máquina…").foregroundStyle(.secondary)
            }
        case .enviando:
            indicador(.accentColor, "Cortando")
        case .conectada, .enviado:
            HStack(spacing: 8) {
                switch maquina.info?.status {
                case .unloaded: indicador(.orange, comBase == false ? "Carregue a folha" : "Sem base — carregue a base")
                case .moving: indicador(.accentColor, "Em movimento")
                default: indicador(.green, "Pronta")
                }
                Button("Verificar", image: .atualizar) { Task { await maquina.conectar() } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Ler o estado da máquina de novo")
                if maquina.encontradas.count > 1 { trocar }
            }
        case .escolher:
            indicador(.orange, "Escolha a máquina")
        }
    }

    private var trocar: some View {
        Menu("Trocar de máquina", image: .trocar) {
            ForEach(maquina.encontradas) { cortadora in
                Button(Self.rotulo(cortadora)) { Task { await maquina.conectar(cortadora) } }
                    .disabled(cortadora == maquina.atual)
            }
        }
        .labelStyle(.iconOnly)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Trocar de máquina")
    }

    private func indicador(_ cor: Color, _ texto: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Circle().fill(cor).frame(width: 8, height: 8)
            Text(texto).font(.callout)
        }
    }
}

/// Desenho da Portrait 4 (do protótipo, viewBox 96 × 44).
struct IlustracaoPortrait: View {
    var body: some View {
        Canvas { ctx, tamanho in
            let e = min(tamanho.width / 96, tamanho.height / 44)
            ctx.scaleBy(x: e, y: e)
            let linha = GraphicsContext.Shading.color(.primary)
            var corpo = Path()
            corpo.move(to: CGPoint(x: 10, y: 14))
            corpo.addQuadCurve(to: CGPoint(x: 6, y: 18), control: CGPoint(x: 8, y: 14))
            corpo.addLine(to: CGPoint(x: 4, y: 30))
            corpo.addQuadCurve(to: CGPoint(x: 9, y: 36), control: CGPoint(x: 3.5, y: 36))
            corpo.addLine(to: CGPoint(x: 87, y: 36))
            corpo.addQuadCurve(to: CGPoint(x: 92, y: 30), control: CGPoint(x: 92.5, y: 36))
            corpo.addLine(to: CGPoint(x: 90, y: 18))
            corpo.addQuadCurve(to: CGPoint(x: 86, y: 14), control: CGPoint(x: 88, y: 14))
            corpo.closeSubpath()
            ctx.fill(corpo, with: .color(.primary.opacity(0.06)))
            ctx.stroke(corpo, with: linha, lineWidth: 1.4)

            var tampa = Path()
            tampa.move(to: CGPoint(x: 14, y: 14))
            tampa.addQuadCurve(to: CGPoint(x: 26, y: 7), control: CGPoint(x: 16, y: 7))
            tampa.addLine(to: CGPoint(x: 70, y: 7))
            tampa.addQuadCurve(to: CGPoint(x: 82, y: 14), control: CGPoint(x: 80, y: 7))
            ctx.fill(tampa, with: .color(.primary.opacity(0.1)))
            ctx.stroke(tampa, with: linha, lineWidth: 1.4)

            ctx.stroke(Path { $0.move(to: CGPoint(x: 8, y: 24)); $0.addLine(to: CGPoint(x: 88, y: 24)) },
                       with: .color(.primary.opacity(0.55)), lineWidth: 1)
            ctx.fill(Path(roundedRect: CGRect(x: 12, y: 25.5, width: 72, height: 2.2), cornerRadius: 1), with: .color(.primary.opacity(0.8)))
            var base = Path()
            base.move(to: CGPoint(x: 6.5, y: 36))
            base.addQuadCurve(to: CGPoint(x: 11, y: 39.5), control: CGPoint(x: 7, y: 39.5))
            base.addLine(to: CGPoint(x: 85, y: 39.5))
            base.addQuadCurve(to: CGPoint(x: 89.5, y: 36), control: CGPoint(x: 89, y: 39.5))
            ctx.stroke(base, with: .color(.primary.opacity(0.6)), lineWidth: 1.2)
            ctx.stroke(Path(ellipseIn: CGRect(x: 78, y: 17, width: 4, height: 4)), with: linha, lineWidth: 1.1)
            ctx.stroke(Path { $0.move(to: CGPoint(x: 30, y: 31)); $0.addLine(to: CGPoint(x: 66, y: 31)) },
                       with: .color(.primary.opacity(0.35)), lineWidth: 1)
        }
    }
}

/// Soltar uma cor arrastada sobre outra linha da tabela: ela passa para o lugar dessa linha.
private struct SoltarCor: DropDelegate {
    let cor: CMYK
    let doc: Documento
    @Binding var arrastando: CMYK?

    func dropEntered(info: DropInfo) {
        guard let arrastando, arrastando != cor, let destino = doc.linhasDeCorte.firstIndex(where: { $0.cor == cor }) else { return }
        withAnimation(.snappy(duration: 0.2)) { doc.moverLinha(arrastando, para: destino) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        arrastando = nil
        return true
    }
}
