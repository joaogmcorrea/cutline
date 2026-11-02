// Tela de desenho: base de corte + página A4, objetos, guias e réguas; ferramentas de seleção, seleção
// direta (pontos e alças), caneta, texto e formas; snap; zoom e panorâmica. Clicar num objeto de um grupo
// seleciona o grupo; o clique direito abre o menu de contexto (Editor/MenuContexto.swift).
import AppKit
import SwiftUI

/// Alças de redimensionamento da seleção (sentido horário a partir do canto superior esquerdo).
enum Alca: CaseIterable {
    case supEsq, sup, supDir, dir, infDir, inf, infEsq, esq

    func ponto(em r: CGRect) -> CGPoint {
        switch self {
        case .supEsq: CGPoint(x: r.minX, y: r.minY)
        case .sup: CGPoint(x: r.midX, y: r.minY)
        case .supDir: CGPoint(x: r.maxX, y: r.minY)
        case .dir: CGPoint(x: r.maxX, y: r.midY)
        case .infDir: CGPoint(x: r.maxX, y: r.maxY)
        case .inf: CGPoint(x: r.midX, y: r.maxY)
        case .infEsq: CGPoint(x: r.minX, y: r.maxY)
        case .esq: CGPoint(x: r.minX, y: r.midY)
        }
    }

    var ehCanto: Bool { [.supEsq, .supDir, .infDir, .infEsq].contains(self) }
    var mexeEsquerda: Bool { [.supEsq, .esq, .infEsq].contains(self) }
    var mexeDireita: Bool { [.supDir, .dir, .infDir].contains(self) }
    var mexeTopo: Bool { [.supEsq, .sup, .supDir].contains(self) }
    var mexeBase: Bool { [.infEsq, .inf, .infDir].contains(self) }
}

/// Um nó de um objeto (seleção direta).
struct RefNo: Equatable {
    let objeto: Objeto.ID
    let sub: Int
    let no: Int
}

enum ParteNo { case ponto, entrada, saida }

/// Caminho sendo desenhado com a caneta (nós em mm da página).
struct Caneta {
    var objeto: Objeto.ID?
    var nos: [No]
}

struct Tela: View {
    @Bindable var doc: Documento
    @Binding var vista: Vista
    /// Onde ficam as réguas (nil = escondidas), em pontos desta tela.
    let reguas: GeometriaReguas?

    @State private var gesto: Gesto?
    @State private var ponteiro = Ponteiro()
    @State private var rastreio = Rastreio()
    @State private var monitorRolagem: Any?
    @State private var monitorTeclado: Any?
    @State private var monitorCliqueDireito: Any?
    /// Janela desta tela: os atalhos só valem nela (e não com uma sheet aberta).
    @State private var janela: NSWindow?
    @State private var zoomNoInicioDaPinca: Double?
    @State private var espaco = false
    @State private var caneta: Caneta?
    @State private var noSelecionado: RefNo?
    @State private var marcaSnap: CGPoint?
    @State private var guiaArrastada: (eixo: Eixo, valor: Double?)?
    /// Cursor e seleção do texto sendo digitado na tela (Editor/EditorTexto.swift).
    @State private var cursorTexto = CursorTexto()
    @AppStorage("snap") private var snapLigado = true
    @Environment(\.colorScheme) private var esquema
    @Environment(\.displayScale) private var escalaDaTela

    private enum Gesto {
        case criando(inicio: CGPoint, atual: CGPoint)                                                          // mm
        case movendo(inicio: CGPoint, originais: [Objeto.ID: CGRect], pontos: [CGPoint], registrado: Bool)     // mm
        case redimensionando(alca: Alca, originais: [Objeto.ID: CGRect], caixa: CGRect, registrado: Bool)      // mm
        case selecionandoArea(inicio: CGPoint, atual: CGPoint, somar: Bool)                                    // mm
        case panoramica(inicio: CGPoint, origem: CGPoint)                                                      // tela
        case guia(eixo: Eixo)
        case no(RefNo, parte: ParteNo, original: [Subcaminho], inicio: CGPoint, registrado: Bool)
        case caneta(indice: Int, inicio: CGPoint)
    }

    private var escuro: Bool { esquema == .dark }
    private var corFundo: Color { escuro ? Color(white: 0.1) : Color(red: 0.89, green: 0.89, blue: 0.9) }
    private var corBase: Color { escuro ? Color(red: 0.17, green: 0.18, blue: 0.17) : Color(red: 0.8, green: 0.82, blue: 0.8) }
    private static let corGuia = Color(red: 0.0, green: 0.72, blue: 1.0)

    var body: some View {
        Canvas { ctx, tamanho in
            // Fonte instalada ou removida com o app aberto: os textos se redesenham com as fontes de agora.
            _ = CatalogoFontes.shared.versao
            desenhar(&ctx, tamanho: tamanho)
        }
            .background(corFundo)
            .contentShape(Rectangle())
            .gesture(arrastar)
            .simultaneousGesture(pinca)
            .onContinuousHover { fase in
                switch fase {
                case .active(let p):
                    rastreio.ponteiro = p
                    ponteiro.tela = p
                    ponteiro.mm = vista.mm(p)
                case .ended:
                    rastreio.ponteiro = nil
                    ponteiro.tela = nil
                    ponteiro.mm = nil
                }
            }
            .pointerStyle(estiloPonteiro)
            .overlay { edicaoDeTexto }
            .overlay {
                if let reguas {
                    Reguas(geometria: reguas, vista: vista, ponteiro: ponteiro, temGuias: !doc.guias.vazias)
                }
            }
            .background(LeitorJanela { nova in
                janela = nova
                if let nova { RespondedorEdicao.instalar(em: nova, doc: doc) }
            })
            .onAppear {
                monitorRolagem = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { evento in rolar(evento) }
                // Teclas lidas na janela, sem depender do foco do SwiftUI (que um campo da barra de controle
                // pode tomar): só ficam com o campo enquanto se digita nele.
                monitorTeclado = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { evento in teclado(evento) }
                monitorCliqueDireito = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { evento in
                    cliqueDireito(evento)
                }
            }
            .onDisappear {
                if let monitorRolagem { NSEvent.removeMonitor(monitorRolagem) }
                if let monitorTeclado { NSEvent.removeMonitor(monitorTeclado) }
                if let monitorCliqueDireito { NSEvent.removeMonitor(monitorCliqueDireito) }
            }
            .onChange(of: doc.ferramenta) { _, nova in
                if nova != .caneta { terminarCaneta() }
                if nova != .direta { noSelecionado = nil }
                if nova != .texto { doc.terminarTexto() }
            }
            // Selecionar outra coisa (camadas, Selecionar › Nada…) termina a digitação.
            .onChange(of: doc.selecao) { _, nova in
                if let edicao = doc.edicaoTexto, nova != [edicao.id] { doc.terminarTexto() }
            }
            #if DEBUG
            .task {
                await arrastarAlcaParaTeste()
                await teclasParaTeste()
            }
            #endif
    }

    #if DEBUG
    /// CUTLINE_TESTE_ALCA=1 (Depuracao.swift): o arrastar da alça, pelos mesmos passos do mouse.
    private func arrastarAlcaParaTeste() async {
        guard Depuracao.arrastarAlca else { return }
        for _ in 0..<100 where doc.selecao.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .milliseconds(500))
        guard let caixa = caixaSelecao else { return }
        let inicio = Alca.infDir.ponto(em: caixa), fim = CGPoint(x: inicio.x + 30 * vista.escala, y: inicio.y + 10 * vista.escala)
        comecar(em: inicio)
        try? await Task.sleep(for: .milliseconds(100))
        continuar(em: fim)
        try? await Task.sleep(for: .milliseconds(100))
        terminar(em: fim)
        comecou = false
    }

    /// CUTLINE_TESTE_TECLAS (Depuracao.swift): as teclas pelo teclado da tela e os cliques pelos passos do mouse;
    /// no fim, CUTLINE_TESTE_CONTEXTO grava o menu do clique direito.
    private func teclasParaTeste() async {
        let teclas = Depuracao.teclasDeTeste
        guard !teclas.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(1200))
        for texto in teclas {
            if texto.hasPrefix("clique:") {
                let mm = texto.dropFirst(7).split(separator: ",").compactMap { Double($0) }
                guard mm.count == 2 else { continue }
                let p = vista.tela(CGPoint(x: mm[0], y: mm[1]))
                comecar(em: p)
                terminar(em: p)
                comecou = false
            } else if let janela, let evento = Depuracao.tecla(texto, janela: janela) {
                _ = teclado(evento)
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        Depuracao.gravarMenuContexto(doc)
        // ⌘S pela cadeia de resposta da janela (como o menu Arquivo › Salvar).
        if let resposta = Depuracao.salvarStudio, let janela {
            _ = janela.tryToPerform(#selector(RespondedorEdicao.saveDocument(_:)), with: nil)
            if resposta == "gravar2" {
                try? await Task.sleep(for: .seconds(4))
                doc.moverSelecao(dx: 0, dy: 5)
                _ = janela.tryToPerform(#selector(RespondedorEdicao.saveDocument(_:)), with: nil)
            }
        }
    }
    #endif

    /// Texto sendo digitado: o campo invisível sobre as letras e, por cima, o cursor e a seleção.
    @ViewBuilder private var edicaoDeTexto: some View {
        if let edicao = doc.edicaoTexto, let objeto = doc.objetoEmEdicao, case .texto(let texto) = objeto.forma,
           let ancora = doc.ancoraDaEdicao {
            let geometria = GeometriaEdicao(edicao: edicao, texto: texto, vista: vista, origem: ancora.origem, escala: ancora.escala)
            let quadro = geometria.quadroDoCampo
            ZStack {
                CampoTextoNaTela(doc: doc, geometria: geometria, cursor: cursorTexto)
                    .id(edicao.sessao)
                    .frame(width: max(quadro.width, 1), height: max(quadro.height, 1))
                    .position(x: quadro.midX, y: quadro.midY)
                MarcasDaEdicao(geometria: geometria, cursor: cursorTexto)
            }
        }
    }

    private var estiloPonteiro: PointerStyle? {
        if espaco || doc.ferramenta == .mao {
            if case .panoramica = gesto { return .grabActive }
            return .grabIdle
        }
        switch doc.ferramenta {
        case .texto: return .horizontalText
        case .caneta: return .rectSelection
        default: return doc.ferramenta.criaForma ? .rectSelection : nil
        }
    }

    /// Tolerância do snap e dos cliques em pontos: 8 pontos da tela, em mm.
    private var tolerancia: Double { 8 / vista.escala }

    // MARK: Desenho

    private func desenhar(_ ctx: inout GraphicsContext, tamanho: CGSize) {
        let pagina = CGRect(origin: .zero, size: Documento.pagina)
        let base = pagina.insetBy(dx: -Documento.margemBase, dy: -Documento.margemBase)
        ctx.fill(Path(roundedRect: vista.tela(base), cornerRadius: 3 * vista.escala), with: .color(corBase))
        var comSombra = ctx
        comSombra.addFilter(.shadow(color: .black.opacity(0.16), radius: 8, y: 3))
        comSombra.fill(Path(vista.tela(pagina)), with: .color(.white))   // a folha é branca também no modo escuro

        for objeto in doc.objetosEmOrdem where doc.visivel(objeto) {
            pintar(objeto, em: &ctx)
            if objeto.corta || objeto.espessura > 0 { tracar(objeto, em: &ctx) }
        }
        if doc.marcas { desenharMarcas(&ctx, tamanho: tamanho) }

        if case .criando(let inicio, let atual) = gesto {
            let previa = doc.objetoNovo(formaNova, quadro: retanguloCriacao(inicio, atual))
            pintar(previa, em: &ctx)
            tracar(previa, em: &ctx)
        }

        desenharGuias(&ctx, tamanho: tamanho)

        // Seleção: contorno em destaque, caixa e alças (de um objeto ou de vários juntos, como a imagem e o
        // contorno recém-vetorizados; na seleção direta, os nós). O texto sendo digitado aparece como é (cor e
        // traço de verdade), só com o cursor.
        let selecionados = doc.edicaoTexto == nil ? doc.selecionados : []
        for objeto in selecionados {
            ctx.stroke(objeto.caminho.applying(vista.transformacao), with: .color(.accentColor), lineWidth: 1.5)
        }
        if doc.ferramenta == .direta {
            desenharNos(selecionados, em: &ctx)
        } else if doc.edicaoTexto == nil, let caixa = caixaSelecao {
            ctx.stroke(Path(caixa), with: .color(.accentColor.opacity(0.7)), lineWidth: 1)
            for alca in Alca.allCases {
                let p = alca.ponto(em: caixa)
                let quadrado = Path(CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7))
                ctx.fill(quadrado, with: .color(.white))
                ctx.stroke(quadrado, with: .color(.accentColor), lineWidth: 1)
            }
        }

        if let caneta { desenharCaneta(caneta, em: &ctx) }

        if case .selecionandoArea(let inicio, let atual, _) = gesto {
            let area = Path(vista.tela(CGRect.entre(inicio, atual, proporcional: false, doCentro: false)))
            ctx.fill(area, with: .color(.accentColor.opacity(0.08)))
            ctx.stroke(area, with: .color(.accentColor.opacity(0.6)), lineWidth: 1)
        }

        if let marcaSnap {
            let p = vista.tela(marcaSnap)
            let marca = Path(CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
            ctx.stroke(marca, with: .color(.accentColor), lineWidth: 1.5)
        }
    }

    /// Preenchimento e imagem (a imagem fica recortada pelo contorno; regra par-ímpar, como no Studio).
    private func pintar(_ objeto: Objeto, em ctx: inout GraphicsContext) {
        guard objeto.preenchimento != nil || objeto.imagem != nil else { return }
        let caminho = objeto.caminho.applying(vista.transformacao)
        let regra = FillStyle(eoFill: true)
        if let cor = objeto.preenchimento { ctx.fill(caminho, with: .color(cor.cor), style: regra) }
        if let imagem = objeto.imagem, let cg = doc.imagem(imagem.chave) {
            var recorte = ctx
            recorte.clip(to: caminho, style: regra)
            recorte.concatenate(imagem.transformacao.cg.concatenating(objeto.quadroParaPagina).concatenating(vista.transformacao))
            recorte.draw(Image(decorative: cg, scale: 1), in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
    }

    /// 0 pt: fio de um pixel da tela (o mais fino possível; não imprime); acima disso, espessura real no
    /// zoom atual — nunca mais fina que o fio —, com ponta, canto e alinhamento. O picotado (em mm)
    /// acompanha o zoom nos dois casos.
    private func tracar(_ objeto: Objeto, em ctx: inout GraphicsContext) {
        let caminho = objeto.caminho.applying(vista.transformacao)
        let cor = GraphicsContext.Shading.color(objeto.traco.cor)
        let tracejado = objeto.estilo.linha.padrao?.map { CGFloat($0 * vista.escala) } ?? []
        let fio = 1 / max(escalaDaTela, 1)
        guard objeto.espessura > 0 else {
            ctx.stroke(caminho, with: cor, style: StrokeStyle(lineWidth: fio, lineJoin: .round, dash: tracejado))
            return
        }
        let e = objeto.estilo
        var estilo = StrokeStyle(lineWidth: max(objeto.espessura * vista.zoom, fio), lineCap: e.ponta.cg, lineJoin: e.canto.cg,
                                 miterLimit: e.limiteCanto, dash: tracejado)
        switch e.alinhamento {
        case .centro:
            ctx.stroke(caminho, with: cor, style: estilo)
        case .dentro, .fora:
            // Dentro/fora: o dobro da espessura, recortado pelo próprio contorno (ou pelo lado de fora dele).
            var recorte = ctx
            recorte.clip(to: caminho, style: FillStyle(eoFill: true), options: e.alinhamento == .fora ? .inverse : [])
            estilo.lineWidth *= 2
            recorte.stroke(caminho, with: cor, style: estilo)
        }
    }

    /// Print & Cut: as marcas como saem na impressão e, hachurado, onde não pôr arte nem cortes (fora da
    /// área entre as marcas e em volta delas).
    private func desenharMarcas(_ ctx: inout GraphicsContext, tamanho: CGSize) {
        var proibida = ctx
        proibida.clip(to: doc.configMarcas.zonaProibida.applying(vista.transformacao), style: FillStyle(eoFill: true))
        let caixa = vista.tela(CGRect(origin: .zero, size: Documento.pagina)).intersection(CGRect(origin: .zero, size: tamanho))
        if !caixa.isNull {
            var hachura = Path()
            var x = caixa.minX - caixa.height
            while x < caixa.maxX {
                hachura.move(to: CGPoint(x: x, y: caixa.maxY))
                hachura.addLine(to: CGPoint(x: x + caixa.height, y: caixa.minY))
                x += 7
            }
            proibida.stroke(hachura, with: .color(.gray.opacity(0.45)), lineWidth: 0.7)
        }
        for retangulo in doc.configMarcas.retangulos { ctx.fill(Path(vista.tela(retangulo)), with: .color(.black)) }
    }

    private func desenharGuias(_ ctx: inout GraphicsContext, tamanho: CGSize) {
        var linhas = Path()
        var verticais = doc.guias.verticais, horizontais = doc.guias.horizontais
        if let arrastada = guiaArrastada, let valor = arrastada.valor {
            if arrastada.eixo == .vertical { verticais.append(valor) } else { horizontais.append(valor) }
        }
        for x in verticais {
            let px = vista.tela(CGPoint(x: x, y: 0)).x.rounded() + 0.5
            linhas.move(to: CGPoint(x: px, y: 0))
            linhas.addLine(to: CGPoint(x: px, y: tamanho.height))
        }
        for y in horizontais {
            let py = vista.tela(CGPoint(x: 0, y: y)).y.rounded() + 0.5
            linhas.move(to: CGPoint(x: 0, y: py))
            linhas.addLine(to: CGPoint(x: tamanho.width, y: py))
        }
        ctx.stroke(linhas, with: .color(Self.corGuia.opacity(0.85)), lineWidth: 0.75)
    }

    /// Nós dos selecionados; o nó escolhido em destaque, com as alças.
    private func desenharNos(_ objetos: [Objeto], em ctx: inout GraphicsContext) {
        for objeto in objetos {
            let subs = objeto.nosAbsolutos
            for (s, sub) in subs.enumerated() {
                for (n, no) in sub.nos.enumerated() {
                    let ref = RefNo(objeto: objeto.id, sub: s, no: n)
                    let p = vista.tela(no.ponto)
                    let quadrado = Path(CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
                    if ref == noSelecionado {
                        for alca in [no.entrada, no.saida].compactMap(\.self) {
                            let q = vista.tela(alca)
                            ctx.stroke(Path { $0.move(to: p); $0.addLine(to: q) }, with: .color(.accentColor), lineWidth: 1)
                            let bolinha = Path(ellipseIn: CGRect(x: q.x - 3, y: q.y - 3, width: 6, height: 6))
                            ctx.fill(bolinha, with: .color(.accentColor))
                        }
                        ctx.fill(quadrado, with: .color(.accentColor))
                    } else {
                        ctx.fill(quadrado, with: .color(.white))
                        ctx.stroke(quadrado, with: .color(.accentColor), lineWidth: 1)
                    }
                }
            }
        }
    }

    /// Caminho da caneta: nós, alças do último e a linha até o ponteiro.
    private func desenharCaneta(_ caneta: Caneta, em ctx: inout GraphicsContext) {
        guard let ultimo = caneta.nos.last else { return }
        if caneta.objeto == nil, caneta.nos.count == 1 {
            let p = vista.tela(ultimo.ponto)
            ctx.fill(Path(CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.accentColor))
        }
        if gesto == nil, let mm = ponteiro.mm {
            var elastico = Path()
            elastico.move(to: vista.tela(ultimo.ponto))
            if let saida = ultimo.saida {
                elastico.addQuadCurve(to: vista.tela(mm), control: vista.tela(saida))
            } else {
                elastico.addLine(to: vista.tela(mm))
            }
            ctx.stroke(elastico, with: .color(.accentColor.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            if let primeiro = caneta.nos.first, caneta.nos.count >= 2,
               hypot(primeiro.ponto.x - mm.x, primeiro.ponto.y - mm.y) < tolerancia {
                let p = vista.tela(primeiro.ponto)
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(.accentColor), lineWidth: 1.5)
            }
        }
        for alca in [ultimo.entrada, ultimo.saida].compactMap(\.self) {
            let p = vista.tela(ultimo.ponto), q = vista.tela(alca)
            ctx.stroke(Path { $0.move(to: p); $0.addLine(to: q) }, with: .color(.accentColor), lineWidth: 1)
            ctx.fill(Path(ellipseIn: CGRect(x: q.x - 3, y: q.y - 3, width: 6, height: 6)), with: .color(.accentColor))
        }
    }

    /// Caixa da seleção, em pontos da tela.
    private var caixaSelecao: CGRect? {
        let quadros = doc.selecionados.map { $0.caminho.boundingRect }
        guard let primeiro = quadros.first else { return nil }
        return vista.tela(quadros.dropFirst().reduce(primeiro) { $0.union($1) })
    }

    // MARK: Gestos

    private var arrastar: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { valor in
                if gesto == nil, !comecou { comecar(em: valor.startLocation) }
                continuar(em: valor.location)
            }
            .onEnded { valor in
                terminar(em: valor.location)
                comecou = false
            }
    }

    /// Alguns cliques (régua, texto, caneta) não abrem um `gesto`; isto evita recomeçar a cada movimento.
    @State private var comecou = false

    private var pinca: some Gesture {
        MagnifyGesture()
            .onChanged { valor in
                let inicial = zoomNoInicioDaPinca ?? vista.zoom
                zoomNoInicioDaPinca = inicial
                vista.ampliar(para: inicial * valor.magnification, ancora: valor.startLocation)
            }
            .onEnded { _ in zoomNoInicioDaPinca = nil }
    }

    private var modificadores: NSEvent.ModifierFlags {
        #if DEBUG
        if let teste = Depuracao.modificadoresDeTeste { return teste }
        #endif
        return NSEvent.modifierFlags
    }
    private var shift: Bool { modificadores.contains(.shift) }
    private var option: Bool { modificadores.contains(.option) }
    /// Só um evento de mouse tem contagem de cliques (pedir a outro derruba o app).
    private var cliques: Int {
        guard let evento = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp, .leftMouseDragged].contains(evento.type) else { return 1 }
        return evento.clickCount
    }

    private var formaNova: Forma {
        switch doc.ferramenta {
        case .elipse: .elipse
        case .estrela: .estrela(pontas: 5, raioInterno: 0.5)
        default: .retangulo(raio: 0)
        }
    }

    private func retanguloCriacao(_ inicio: CGPoint, _ atual: CGPoint) -> CGRect {
        CGRect.entre(inicio, atual, proporcional: shift, doCentro: option)
    }

    /// Alvos do snap do gesto em andamento (calculados no começo).
    private func encaixe(_ p: CGPoint) -> CGPoint {
        guard snapLigado, let alvos = rastreio.alvos else { marcaSnap = nil; return p }
        let (q, marca) = alvos.encaixar(p, tolerancia: tolerancia)
        marcaSnap = marca
        return q
    }

    private func prepararSnap(excluir: Set<Objeto.ID>) {
        rastreio.alvos = snapLigado ? AlvosSnap(doc: doc, excluir: excluir) : nil
    }

    private func comecar(em pTela: CGPoint) {
        comecou = true
        // Clicar na tela encerra a edição de um campo (e devolve o teclado à tela) e a digitação de um texto
        // (o clique dentro do texto em edição vai direto para o campo invisível, não chega aqui).
        if janela?.firstResponder is NSText { janela?.makeFirstResponder(nil) }
        doc.terminarTexto()
        let p = vista.mm(pTela)
        if espaco || doc.ferramenta == .mao {
            gesto = .panoramica(inicio: pTela, origem: vista.origem)
            return
        }
        if let reguas, comecarNaRegua(pTela, reguas) { return }
        switch doc.ferramenta {
        case .caneta:
            prepararSnap(excluir: Set([caneta?.objeto].compactMap(\.self)))
            clicarCaneta(encaixe(p))
        case .texto:
            // Num texto: o cursor vai para onde foi o clique; fora: texto novo com a linha de base no clique.
            if let alvo = objetoEm(pTela), let objeto = doc.objetos.first(where: { $0.id == alvo }), case .texto = objeto.forma {
                doc.editarTexto(alvo, clique: p)
            } else {
                doc.novoTexto(em: p)
            }
        case .direta:
            comecarDireta(pTela, p)
        case _ where doc.ferramenta.criaForma:
            prepararSnap(excluir: [])
            let q = encaixe(p)
            gesto = .criando(inicio: q, atual: q)
        default:
            comecarSelecao(pTela, p)
        }
    }

    private func comecarSelecao(_ pTela: CGPoint, _ p: CGPoint) {
        if let alca = alcaEm(pTela), let caixa = doc.caixaSelecao {
            prepararSnap(excluir: doc.selecao)
            gesto = .redimensionando(alca: alca, originais: Dictionary(uniqueKeysWithValues: doc.selecionados.map { ($0.id, $0.quadro.standardized) }),
                                     caixa: caixa, registrado: false)
        } else if let alvo = objetoEm(pTela) {
            if cliques >= 2, let objeto = doc.objetos.first(where: { $0.id == alvo }) {
                // Duplo clique: texto abre a digitação na tela (cursor no clique); caminho, a seleção direta.
                if case .texto = objeto.forma {
                    doc.ferramenta = .texto
                    doc.editarTexto(alvo, clique: p)
                } else {
                    doc.selecao = [alvo]
                    doc.ferramenta = .direta
                }
                return
            }
            // Num grupo, o grupo de fora inteiro.
            let unidade = doc.unidade(de: alvo)
            if shift {
                if doc.selecao.contains(alvo) { doc.selecao.subtract(unidade) } else { doc.selecao.formUnion(unidade) }
            } else if !doc.selecao.contains(alvo) {
                doc.selecao = unidade
            }
            if let objeto = doc.objetos.first(where: { $0.id == alvo }) { doc.camadaAtiva = doc.camada(de: objeto).id }
            comecarMovimento(p)
        } else if let (eixo, indice) = guiaEm(pTela) {
            // Guia existente: tira do documento enquanto arrasta; solta na régua para apagar.
            doc.registrar()
            let valor: Double
            switch eixo {
            case .vertical: valor = doc.guias.verticais.remove(at: indice)
            case .horizontal: valor = doc.guias.horizontais.remove(at: indice)
            }
            guiaArrastada = (eixo, valor)
            gesto = .guia(eixo: eixo)
        } else {
            if !shift { doc.selecao = [] }
            gesto = .selecionandoArea(inicio: p, atual: p, somar: shift)
        }
    }

    /// Arrastar a seleção (⌥: uma cópia dela).
    private func comecarMovimento(_ p: CGPoint) {
        var registrado = false
        if option, !doc.selecao.isEmpty {
            registrado = true
            doc.duplicarSelecao(deslocamento: .zero)
        }
        prepararSnap(excluir: doc.selecao)
        let selecionados = doc.selecionados
        gesto = .movendo(inicio: p, originais: Dictionary(uniqueKeysWithValues: selecionados.map { ($0.id, $0.quadro) }),
                         pontos: Objeto.pontosMoveis(selecionados), registrado: registrado)
    }

    /// Clique na régua: começa uma guia nova; duplo clique no canto apaga todas.
    private func comecarNaRegua(_ pTela: CGPoint, _ reguas: GeometriaReguas) -> Bool {
        if reguas.canto.contains(pTela) {
            if cliques >= 2, !doc.guias.vazias {
                doc.registrar()
                doc.guias = Guias()
            }
            return true
        }
        let eixo: Eixo
        if reguas.horizontal.contains(pTela) { eixo = .horizontal } else if reguas.vertical.contains(pTela) { eixo = .vertical } else { return false }
        doc.registrar()
        guiaArrastada = (eixo, nil)
        gesto = .guia(eixo: eixo)
        prepararSnap(excluir: [])
        return true
    }

    private func comecarDireta(_ pTela: CGPoint, _ p: CGPoint) {
        // 1. Alças do nó escolhido; 2. nós dos selecionados; 3. objetos.
        if let ref = noSelecionado, let objeto = doc.objetos.first(where: { $0.id == ref.objeto }) {
            let subs = objeto.nosAbsolutos
            if subs.indices.contains(ref.sub), subs[ref.sub].nos.indices.contains(ref.no) {
                let no = subs[ref.sub].nos[ref.no]
                for (parte, alca) in [(ParteNo.entrada, no.entrada), (.saida, no.saida)] {
                    if let alca, hypot(vista.tela(alca).x - pTela.x, vista.tela(alca).y - pTela.y) <= 6 {
                        gesto = .no(ref, parte: parte, original: subs, inicio: p, registrado: false)
                        return
                    }
                }
            }
        }
        for objeto in doc.selecionados.reversed() {
            let subs = objeto.nosAbsolutos
            for (s, sub) in subs.enumerated() {
                for (n, no) in sub.nos.enumerated() {
                    let q = vista.tela(no.ponto)
                    guard abs(q.x - pTela.x) <= 6, abs(q.y - pTela.y) <= 6 else { continue }
                    let ref = RefNo(objeto: objeto.id, sub: s, no: n)
                    noSelecionado = ref
                    if cliques >= 2 {
                        alternarSuave(ref, subs)
                        return
                    }
                    prepararSnap(excluir: [objeto.id])
                    gesto = .no(ref, parte: .ponto, original: subs, inicio: p, registrado: false)
                    return
                }
            }
        }
        noSelecionado = nil
        if let alvo = objetoEm(pTela) {
            doc.selecao = shift ? doc.selecao.symmetricDifference([alvo]) : [alvo]
        } else {
            if !shift { doc.selecao = [] }
            gesto = .selecionandoArea(inicio: p, atual: p, somar: shift)
        }
    }

    private func continuar(em pTela: CGPoint) {
        let p = vista.mm(pTela)
        switch gesto {
        case .criando(let inicio, _):
            gesto = .criando(inicio: inicio, atual: encaixe(p))
        case .movendo(let inicio, let originais, let pontos, let registrado):
            var dx = p.x - inicio.x, dy = p.y - inicio.y
            guard registrado || hypot(dx, dy) * vista.escala > 2 else { return }
            if shift { if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 } }
            if snapLigado, let alvos = rastreio.alvos {
                let encaixado = alvos.encaixar(pontos, dx: dx, dy: dy, tolerancia: tolerancia)
                (dx, dy, marcaSnap) = (encaixado.dx, encaixado.dy, encaixado.marca)
            }
            if !registrado { doc.registrar() }
            for i in doc.objetos.indices {
                if let original = originais[doc.objetos[i].id] { doc.objetos[i].quadro = original.offsetBy(dx: dx, dy: dy) }
            }
            gesto = .movendo(inicio: inicio, originais: originais, pontos: pontos, registrado: true)
        case .redimensionando(let alca, let originais, let caixa, let registrado):
            // A caixa da seleção vai até o ponteiro; cada objeto estica na mesma proporção.
            if !registrado { doc.registrar() }
            let nova = redimensionar(caixa, alca: alca, para: encaixe(p), proporcional: shift, doCentro: option)
            for i in doc.objetos.indices {
                if let original = originais[doc.objetos[i].id] { doc.objetos[i].quadro = Documento.esticar(original, de: caixa, para: nova) }
            }
            gesto = .redimensionando(alca: alca, originais: originais, caixa: caixa, registrado: true)
        case .selecionandoArea(let inicio, _, let somar):
            gesto = .selecionandoArea(inicio: inicio, atual: p, somar: somar)
        case .panoramica(let inicio, let origem):
            vista.origem = CGPoint(x: origem.x + pTela.x - inicio.x, y: origem.y + pTela.y - inicio.y)
            vista.manual = true
        case .guia(let eixo):
            let q = encaixe(p)
            guiaArrastada = (eixo, ((eixo == .vertical ? q.x : q.y) * 100).rounded() / 100)
            ponteiro.mm = p
        case .no(let ref, let parte, let original, let inicio, let registrado):
            arrastarNo(ref, parte: parte, original: original, inicio: inicio, p: p, registrado: registrado)
        case .caneta(let indice, let inicio):
            arrastarCaneta(indice, inicio: inicio, p: p)
        case nil:
            break
        }
    }

    private func terminar(em pTela: CGPoint) {
        defer {
            gesto = nil
            marcaSnap = nil
            rastreio.alvos = nil
        }
        switch gesto {
        case .criando(let inicio, let atual):
            var quadro = retanguloCriacao(inicio, atual)
            // Clique sem arrastar: forma de 30 mm centrada no clique.
            if quadro.width * vista.escala < 4 || quadro.height * vista.escala < 4 {
                quadro = CGRect(x: inicio.x - 15, y: inicio.y - 15, width: 30, height: 30)
            }
            doc.adicionar(doc.objetoNovo(formaNova, quadro: quadro))
        case .selecionandoArea(let inicio, let atual, let somar):
            let area = CGRect.entre(inicio, atual, proporcional: false, doCentro: false)
            // Um clique sem arrastar num vazio só tira a seleção (a área de tamanho zero pegava a caixa dos objetos).
            guard max(area.width, area.height) * vista.escala >= 3 else { break }
            let tocados = doc.comGrupos(Set(doc.objetos.filter { !doc.intocavel($0) && $0.caminho.boundingRect.intersects(area) }.map(\.id)))
            doc.selecao = somar ? doc.selecao.union(tocados) : tocados
        case .guia(let eixo):
            // Solta na régua (ou sem mover) = sem guia.
            if let valor = guiaArrastada?.valor, let reguas, !(reguas.horizontal.union(reguas.vertical).union(reguas.canto).contains(pTela)) {
                switch eixo {
                case .vertical: doc.guias.verticais.append(valor)
                case .horizontal: doc.guias.horizontais.append(valor)
                }
            }
            guiaArrastada = nil
        default:
            break
        }
    }

    // MARK: Seleção direta

    private func arrastarNo(_ ref: RefNo, parte: ParteNo, original: [Subcaminho], inicio: CGPoint, p: CGPoint, registrado: Bool) {
        guard original.indices.contains(ref.sub), original[ref.sub].nos.indices.contains(ref.no),
              let i = doc.objetos.firstIndex(where: { $0.id == ref.objeto }) else { return }
        guard registrado || hypot(p.x - inicio.x, p.y - inicio.y) * vista.escala > 1 else { return }
        if !registrado { doc.registrar() }
        var subs = original
        var no = subs[ref.sub].nos[ref.no]
        switch parte {
        case .ponto:
            let q = encaixe(p)
            let dx = q.x - no.ponto.x, dy = q.y - no.ponto.y
            no.ponto = q
            no.entrada = no.entrada.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            no.saida = no.saida.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        case .entrada, .saida:
            // A alça oposta acompanha, com o próprio comprimento (⌥ quebra o nó).
            let oposta = parte == .entrada ? no.saida : no.entrada
            if parte == .entrada { no.entrada = p } else { no.saida = p }
            if !option, let oposta {
                let comprimento = hypot(oposta.x - no.ponto.x, oposta.y - no.ponto.y)
                let d = hypot(p.x - no.ponto.x, p.y - no.ponto.y)
                if d > 0 {
                    let espelho = CGPoint(x: no.ponto.x - (p.x - no.ponto.x) / d * comprimento, y: no.ponto.y - (p.y - no.ponto.y) / d * comprimento)
                    if parte == .entrada { no.saida = espelho } else { no.entrada = espelho }
                }
            }
        }
        subs[ref.sub].nos[ref.no] = no
        doc.objetos[i].definirNos(subs)
        gesto = .no(ref, parte: parte, original: original, inicio: inicio, registrado: true)
    }

    /// Duplo clique num nó: canto ↔ suave (alças na direção dos vizinhos, como no protótipo).
    private func alternarSuave(_ ref: RefNo, _ subs: [Subcaminho]) {
        guard let i = doc.objetos.firstIndex(where: { $0.id == ref.objeto }) else { return }
        var subs = subs
        var no = subs[ref.sub].nos[ref.no]
        let nos = subs[ref.sub].nos
        if no.entrada != nil || no.saida != nil {
            no.entrada = nil
            no.saida = nil
        } else {
            let anterior = nos[(ref.no - 1 + nos.count) % nos.count].ponto, proximo = nos[(ref.no + 1) % nos.count].ponto
            let dx = (proximo.x - anterior.x) / 6, dy = (proximo.y - anterior.y) / 6
            no.entrada = CGPoint(x: no.ponto.x - dx, y: no.ponto.y - dy)
            no.saida = CGPoint(x: no.ponto.x + dx, y: no.ponto.y + dy)
        }
        subs[ref.sub].nos[ref.no] = no
        doc.registrar()
        doc.objetos[i].definirNos(subs)
    }

    // MARK: Caneta

    /// Clique: ponto de canto (arrastar puxa as alças); clicar no primeiro ponto fecha o caminho.
    private func clicarCaneta(_ p: CGPoint) {
        if var atual = caneta {
            if atual.objeto.flatMap({ id in doc.objetos.first { $0.id == id } }) == nil, atual.objeto != nil {
                caneta = nil   // o objeto sumiu (⌘Z): recomeça
                clicarCaneta(p)
                return
            }
            if atual.nos.count >= 2, let primeiro = atual.nos.first, hypot(primeiro.ponto.x - p.x, primeiro.ponto.y - p.y) < tolerancia {
                gravarCaneta(atual, fechado: true)
                caneta = nil
                return
            }
            atual.nos.append(No(ponto: p))
            caneta = atual
            gravarCaneta(atual, fechado: false)
            gesto = .caneta(indice: atual.nos.count - 1, inicio: p)
        } else {
            caneta = Caneta(objeto: nil, nos: [No(ponto: p)])
            gesto = .caneta(indice: 0, inicio: p)
        }
    }

    private func arrastarCaneta(_ indice: Int, inicio: CGPoint, p: CGPoint) {
        guard var atual = caneta, atual.nos.indices.contains(indice), hypot(p.x - inicio.x, p.y - inicio.y) > 0.4 else { return }
        let ponto = atual.nos[indice].ponto
        atual.nos[indice].saida = p
        atual.nos[indice].entrada = CGPoint(x: 2 * ponto.x - p.x, y: 2 * ponto.y - p.y)
        caneta = atual
        gravarCaneta(atual, fechado: false)
    }

    /// Leva o caminho da caneta para o documento (cria o objeto no 2º ponto).
    private func gravarCaneta(_ atual: Caneta, fechado: Bool) {
        guard atual.nos.count >= 2 else { return }
        let subs = [Subcaminho(nos: atual.nos, fechado: fechado)]
        if let id = atual.objeto, let i = doc.objetos.firstIndex(where: { $0.id == id }) {
            doc.objetos[i].definirNos(subs)
        } else {
            var novo = doc.objetoNovo(.caminho([]), quadro: .zero)
            novo.definirNos(subs)
            doc.adicionar(novo)
            caneta?.objeto = novo.id
        }
    }

    private func terminarCaneta() {
        caneta = nil
        marcaSnap = nil
    }

    // MARK: Alvos do clique

    /// Objeto mais à frente sob o ponto, em duas etapas. 1) O que está de fato ali: a caixa das letras de um
    /// texto, o traço (ou perto dele; o traço grosso inteiro) ou o miolo de uma forma com preenchimento ou imagem.
    /// 2) Só se nada estiver: o miolo de uma forma sem preenchimento. Assim uma forma vazia por cima não tampa
    /// o que está embaixo dela, e clicar no vazio dela ainda a seleciona.
    private func objetoEm(_ pTela: CGPoint) -> Objeto.ID? {
        let ordem = doc.objetosEmOrdem.reversed().filter { !doc.intocavel($0) }
        for objeto in ordem {
            // Texto: qualquer ponto da caixa das letras (não só em cima delas, como no Illustrator).
            if case .texto = objeto.forma, vista.tela(objeto.quadro.standardized).insetBy(dx: -4, dy: -4).contains(pTela) {
                return objeto.id
            }
            let caminho = objeto.caminho.applying(vista.transformacao)
            let cheio = objeto.preenchimento != nil || objeto.imagem != nil
            let traco = caminho.strokedPath(StrokeStyle(lineWidth: max(8, 2 * objeto.espessura * vista.zoom)))
            if cheio && caminho.contains(pTela, eoFill: true) || traco.contains(pTela) {
                return objeto.id
            }
        }
        return ordem.first { $0.caminho.applying(vista.transformacao).contains(pTela, eoFill: true) }?.id
    }

    private func alcaEm(_ pTela: CGPoint) -> Alca? {
        guard let caixa = caixaSelecao else { return nil }
        return Alca.allCases.first { alca in
            let p = alca.ponto(em: caixa)
            return abs(p.x - pTela.x) <= 6 && abs(p.y - pTela.y) <= 6
        }
    }

    private func guiaEm(_ pTela: CGPoint) -> (Eixo, Int)? {
        if let i = doc.guias.verticais.firstIndex(where: { abs(vista.tela(CGPoint(x: $0, y: 0)).x - pTela.x) <= 3 }) { return (.vertical, i) }
        if let i = doc.guias.horizontais.firstIndex(where: { abs(vista.tela(CGPoint(x: 0, y: $0)).y - pTela.y) <= 3 }) { return (.horizontal, i) }
        return nil
    }

    /// Novo quadro arrastando uma alça; com shift nos cantos, mantém a proporção; com ⌥, cresce para os dois
    /// lados (o centro fica parado e o lado oposto acompanha, espelhado).
    private func redimensionar(_ r: CGRect, alca: Alca, para p: CGPoint, proporcional: Bool, doCentro: Bool) -> CGRect {
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        if alca.mexeEsquerda { minX = p.x }
        if alca.mexeDireita { maxX = p.x }
        if alca.mexeTopo { minY = p.y }
        if alca.mexeBase { maxY = p.y }
        if doCentro {
            if alca.mexeEsquerda || alca.mexeDireita { (minX, maxX) = (r.midX - abs(p.x - r.midX), r.midX + abs(p.x - r.midX)) }
            if alca.mexeTopo || alca.mexeBase { (minY, maxY) = (r.midY - abs(p.y - r.midY), r.midY + abs(p.y - r.midY)) }
            if proporcional, alca.ehCanto, r.width > 0, r.height > 0 {
                let s = max((maxX - minX) / r.width, (maxY - minY) / r.height)
                return CGRect(x: r.midX - r.width * s / 2, y: r.midY - r.height * s / 2, width: r.width * s, height: r.height * s)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        if proporcional, alca.ehCanto, r.width > 0, r.height > 0 {
            // âncora = canto oposto
            let ax = alca.mexeEsquerda ? r.maxX : r.minX
            let ay = alca.mexeTopo ? r.maxY : r.minY
            let s = max(abs(p.x - ax) / r.width, abs(p.y - ay) / r.height)
            let sx: Double = p.x < ax ? -1 : 1, sy: Double = p.y < ay ? -1 : 1
            return CGRect.entre(CGPoint(x: ax, y: ay), CGPoint(x: ax + sx * r.width * s, y: ay + sy * r.height * s),
                                proporcional: false, doCentro: false)
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }


    // MARK: Teclado e rolagem

    /// Delete apaga, Esc limpa a seleção (ou termina a caneta), Enter termina a caneta, espaço segura a
    /// mão, setas movem a seleção (1 mm; ⇧ 10 mm; ⌥ 0,1 mm), letras trocam a ferramenta (V, A, P, T, M, L, S,
    /// I, H); cores como no Illustrator: X alterna
    /// preenchimento/traço, ⇧X troca os dois, D padrão, / nenhum. Com ⌘, os atalhos dos objetos são lidos
    /// aqui (fora dos campos de texto, que ficam com os deles), sem depender do estado dos menus: ⌘A tudo,
    /// ⌘C/⌘X/⌘V, ⌘D duplica, ⌘ + seta duplica ao lado, ⌘G/⇧⌘G agrupa e desagrupa, ⌘] ⌘[ ⇧⌘] ⇧⌘[ organizam.
    /// ⌘R e ⌘; são do menu Visualizar.
    private func teclado(_ evento: NSEvent) -> NSEvent? {
        guard let janela, evento.window === janela, janela.attachedSheet == nil,
              !(janela.firstResponder is NSText) else { return evento }
        let comando = evento.modifierFlags.contains(.command)
        let comModificador = !evento.modifierFlags.intersection([.command, .option, .control]).isEmpty
        let descendo = evento.type == .keyDown
        if descendo, comando, evento.modifierFlags.isDisjoint(with: [.option, .control]) {
            let maiuscula = evento.modifierFlags.contains(.shift)
            let setas: [UInt16: Direcao] = [123: .esquerda, 124: .direita, 125: .baixo, 126: .cima]
            if let direcao = setas[evento.keyCode] {
                guard !maiuscula else { return evento }
                doc.duplicarAoLado(direcao)
                return nil
            }
            switch (evento.charactersIgnoringModifiers?.lowercased(), maiuscula) {
            case ("a", false): doc.selecionarTudo()
            case ("c", false): doc.copiarSelecao()
            case ("x", false): doc.recortarSelecao()
            case ("v", false): doc.colar()
            case ("d", false): doc.duplicarSelecao()
            case ("g", false): doc.agrupar()
            case ("g", true): doc.desagrupar()
            case ("]", _), ("}", _): doc.organizar(maiuscula ? .frente : .avancar)
            case ("[", _), ("{", _): doc.organizar(maiuscula ? .tras : .recuar)
            default: return evento
            }
            return nil
        }
        switch evento.keyCode {
        case 49:   // espaço
            guard !comModificador else { return evento }
            espaco = descendo
            return nil
        case 36 where caneta != nil, 76 where caneta != nil:   // enter
            guard descendo else { return nil }
            terminarCaneta()
            return nil
        case 51, 117:   // delete, delete à frente (⌘⌫ fica com o menu Editar › Apagar)
            guard descendo, !comModificador else { return evento }
            doc.apagarSelecao()
            noSelecionado = nil
            return nil
        case 53:   // esc
            guard descendo else { return evento }
            if caneta != nil { terminarCaneta() } else {
                doc.selecao = []
                noSelecionado = nil
            }
            return nil
        case 7 where descendo && !comModificador:   // x
            if evento.modifierFlags.contains(.shift) {
                doc.trocarCores()
            } else {
                doc.alvoCor = doc.alvoCor == .traco ? .preenchimento : .traco
            }
            return nil
        case 2 where descendo && !comModificador && !evento.modifierFlags.contains(.shift):   // d
            doc.coresPadrao()
            return nil
        case 123...126 where evento.modifierFlags.isDisjoint(with: [.command, .control]):   // setas
            // Movem a seleção: 1 mm; com ⇧, 10 mm; com ⌥, 0,1 mm. Sem seleção, ficam com quem vier depois.
            guard !doc.selecao.isEmpty else { return evento }
            guard descendo else { return nil }
            let passo = evento.modifierFlags.contains(.shift) ? 10 : evento.modifierFlags.contains(.option) ? 0.1 : 1.0
            let deslocamentos: [UInt16: (Double, Double)] = [123: (-passo, 0), 124: (passo, 0), 125: (0, passo), 126: (0, -passo)]
            if let (dx, dy) = deslocamentos[evento.keyCode] { doc.moverSelecao(dx: dx, dy: dy) }
            return nil
        case 44 where descendo && !comModificador && !evento.modifierFlags.contains(.shift):   // /
            doc.definirCor(doc.alvoCor, nil)
            return nil
        default:
            guard descendo, !comModificador, !evento.modifierFlags.contains(.shift),
                  let letra = evento.charactersIgnoringModifiers?.lowercased().first,
                  let ferramenta = Ferramenta.allCases.first(where: { $0.tecla == letra }) else { return evento }
            doc.ferramenta = ferramenta
            return nil
        }
    }

    /// Clique direito (ou ⌃-clique) na tela: seleciona o que está embaixo, se não estiver selecionado, e abre o
    /// menu de contexto. Digitando um texto, o menu é o do texto.
    private func cliqueDireito(_ evento: NSEvent) -> NSEvent? {
        guard let janela, evento.window === janela, janela.attachedSheet == nil, let p = rastreio.ponteiro,
              evento.type == .rightMouseDown || evento.modifierFlags.contains(.control),
              doc.edicaoTexto == nil, gesto == nil, caneta == nil else { return evento }
        if let reguas, reguas.horizontal.union(reguas.vertical).union(reguas.canto).contains(p) { return evento }
        if let alvo = objetoEm(p), !doc.selecao.contains(alvo), let objeto = doc.objetos.first(where: { $0.id == alvo }) {
            doc.selecao = doc.ferramenta == .direta ? [alvo] : doc.unidade(de: alvo)
            doc.camadaAtiva = doc.camada(de: objeto).id
            noSelecionado = nil
        }
        NSMenu.popUpContextMenu(MenuContexto.criar(doc), with: evento, for: janela.contentView ?? NSView())
        return nil
    }

    /// Dois dedos no trackpad (ou roda do mouse) movem a página; com ⌘, zoom no ponteiro.
    private func rolar(_ evento: NSEvent) -> NSEvent? {
        guard let p = rastreio.ponteiro, evento.window?.isKeyWindow == true else { return evento }
        let fator = evento.hasPreciseScrollingDeltas ? 1.0 : 10.0
        if evento.modifierFlags.contains(.command) {
            vista.ampliar(para: vista.zoom * exp(evento.scrollingDeltaY * fator * 0.01), ancora: p)
        } else {
            vista.deslocar(dx: evento.scrollingDeltaX * fator, dy: evento.scrollingDeltaY * fator)
        }
        ponteiro.mm = vista.mm(p)
        return nil
    }
}

/// Estado da tela que não deve redesenhar quando muda.
private final class Rastreio {
    var ponteiro: CGPoint?
    var alvos: AlvosSnap?
}

/// Descobre a NSWindow que contém a view.
struct LeitorJanela: NSViewRepresentable {
    let encontrou: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { Sonda(encontrou: encontrou) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Sonda: NSView {
        let encontrou: (NSWindow?) -> Void
        init(encontrou: @escaping (NSWindow?) -> Void) {
            self.encontrou = encontrou
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let janela = window
            DispatchQueue.main.async { self.encontrou(janela) }
        }
    }
}
