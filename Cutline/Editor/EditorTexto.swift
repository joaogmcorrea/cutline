// Digitação na tela: um NSTextView invisível, posto sobre as letras, recebe o teclado (acentos, colar,
// atalhos de texto do macOS); cada mudança vai para o documento e a tela redesenha o texto de verdade. O
// estilo de cada trecho viaja como atributo do texto do campo (digitar, apagar e colar levam o estilo junto,
// como num editor de texto). Cursor, seleção, cliques e setas ↑ ↓ usam a diagramação do próprio texto
// (Texto.diagramacao), a mesma das letras — por isso batem com o desenho em qualquer alinhamento.
import AppKit
import SwiftUI

/// Cursor e seleção do campo invisível (não redesenham a tela inteira, só as marcas da edição).
@Observable
final class CursorTexto {
    var selecao = NSRange(location: 0, length: 0)
    /// Texto em composição (acento antes da letra, métodos de entrada).
    var marcado: NSRange?
    /// Última mudança: o cursor fica aceso enquanto se digita e pisca depois.
    var mudou = Date()
}

/// Liga o texto em edição (pt do corpo, y para baixo, a partir do ponto do texto) aos pontos da tela.
struct GeometriaEdicao {
    let edicao: EdicaoTexto
    let texto: Texto
    let vista: Vista
    /// Ponto do texto (mm) e esticamento, como estão agora (Documento.ancoraDaEdicao).
    let origem: CGPoint
    let escala: CGSize

    var diagramacao: Texto.Diagramacao { texto.diagramacao }

    /// pt do corpo → pontos da tela.
    func tela(_ p: CGPoint) -> CGPoint {
        let mm = Texto.mmPorPt
        return vista.tela(CGPoint(x: origem.x + p.x * mm * escala.width, y: origem.y + p.y * mm * escala.height))
    }

    /// mm da página → pt do corpo.
    func corpo(_ p: CGPoint) -> CGPoint {
        let mm = Texto.mmPorPt
        return CGPoint(x: (p.x - origem.x) / (mm * escala.width), y: (p.y - origem.y) / (mm * escala.height))
    }

    /// Área do campo invisível em pt do corpo: as linhas, com folga para o cursor e as letras que passam do
    /// começo da linha (itálicos, caligráficas).
    var limitesDoCampo: CGRect {
        let d = diagramacao, em = texto.maiorCorpo
        let x0 = d.minX - 0.3 * em, x1 = d.maxX + em
        return CGRect(x: x0, y: 0, width: x1 - x0, height: d.altura + 0.2 * em)
    }

    /// A mesma área em pontos da tela.
    var quadroDoCampo: CGRect {
        let r = limitesDoCampo
        let a = tela(CGPoint(x: r.minX, y: r.minY)), b = tela(CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    /// Retângulo (pt do corpo) de um trecho na sua linha, do topo das letras ao pé.
    func retangulo(_ faixa: NSRange) -> CGRect {
        let d = diagramacao
        let (i, x0) = d.posicao(faixa.location)
        let x1 = d.posicao(min(NSMaxRange(faixa), d.linhas[i].fim)).x
        return CGRect(x: x0, y: d.linhas[i].topo, width: max(x1 - x0, 1), height: d.linhas[i].pe - d.linhas[i].topo)
    }
}

/// Cursor (piscando), seleção e sublinhado do texto em composição, sobre as letras.
struct MarcasDaEdicao: View {
    let geometria: GeometriaEdicao
    let cursor: CursorTexto

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { contexto in
            Canvas { ctx, _ in desenhar(&ctx, agora: contexto.date) }
        }
        .allowsHitTesting(false)
    }

    private func desenhar(_ ctx: inout GraphicsContext, agora: Date) {
        let d = geometria.diagramacao
        let selecao = cursor.selecao
        if selecao.length > 0 {
            for linha in d.linhas where selecao.location <= linha.fim && NSMaxRange(selecao) > linha.inicio {
                let x0 = d.posicao(max(selecao.location, linha.inicio)).x
                var x1 = d.posicao(min(NSMaxRange(selecao), linha.fim)).x
                // A quebra de linha selecionada aparece como um pedacinho a mais.
                if NSMaxRange(selecao) > linha.fim { x1 += geometria.texto.maiorCorpo * 0.25 }
                quadrado(&ctx, CGRect(x: x0, y: linha.topo, width: x1 - x0, height: linha.pe - linha.topo))
            }
        } else {
            let tempo = agora.timeIntervalSince(cursor.mudou)
            if tempo < 0.5 || Int(tempo / 0.5) % 2 == 0 || Self.cursorFixo {
                // Altura da letra antes do cursor (sobrescrito, corpos diferentes na mesma linha).
                let c = d.cursor(selecao.location)
                tracar(&ctx, de: CGPoint(x: c.x, y: c.topo), ate: CGPoint(x: c.x, y: c.pe))
            }
        }
        if let marcado = cursor.marcado, marcado.length > 0 {
            let (i, x0) = d.posicao(marcado.location)
            let x1 = d.posicao(NSMaxRange(marcado)).x
            let y = d.linhas[i].base + d.linhas[i].descendente * 0.45
            tracar(&ctx, de: CGPoint(x: x0, y: y), ate: CGPoint(x: x1, y: y))
        }
    }

    private func quadrado(_ ctx: inout GraphicsContext, _ r: CGRect) {
        let a = geometria.tela(CGPoint(x: r.minX, y: r.minY)), b = geometria.tela(CGPoint(x: r.maxX, y: r.maxY))
        ctx.fill(Path(CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)), with: .color(.accentColor.opacity(0.28)))
    }

    private func tracar(_ ctx: inout GraphicsContext, de a: CGPoint, ate b: CGPoint) {
        var linha = Path()
        linha.move(to: geometria.tela(a))
        linha.addLine(to: geometria.tela(b))
        ctx.stroke(linha, with: .color(.accentColor), lineWidth: 1.5)
    }

    #if DEBUG
    private static let cursorFixo = Depuracao.textoNaTela != nil
    #else
    private static let cursorFixo = false
    #endif
}

/// O campo invisível que recebe o teclado, posto sobre as letras; as coordenadas dele são pt do corpo.
struct CampoTextoNaTela: NSViewRepresentable {
    let doc: Documento
    let geometria: GeometriaEdicao
    let cursor: CursorTexto

    func makeCoordinator() -> Coordenador {
        Coordenador(doc: doc, cursor: cursor, sessao: geometria.edicao.sessao)
    }

    func makeNSView(context: Context) -> Suporte {
        let coordenador = context.coordinator
        coordenador.geometria = geometria
        let campo = CampoInvisivel(frame: .zero)
        campo.delegate = coordenador
        campo.textContainerInset = .zero
        campo.textContainer?.lineFragmentPadding = 0
        campo.textContainer?.widthTracksTextView = false
        campo.textContainer?.containerSize = NSSize(width: 1e7, height: 1e7)
        campo.drawsBackground = false
        // Com atributos (o estilo de cada trecho); colar só traz o texto (CampoInvisivel.readablePasteboardTypes).
        campo.isRichText = true
        campo.importsGraphics = false
        campo.usesFontPanel = false
        campo.usesRuler = false
        campo.usesFindBar = false
        campo.allowsUndo = false   // ⌘Z desfaz a edição inteira (um passo do documento)
        campo.isHorizontallyResizable = false
        campo.isVerticallyResizable = false
        campo.isContinuousSpellCheckingEnabled = false
        campo.isGrammarCheckingEnabled = false
        campo.isAutomaticSpellingCorrectionEnabled = false
        campo.isAutomaticTextReplacementEnabled = false
        campo.isAutomaticLinkDetectionEnabled = false
        campo.isAutomaticDataDetectionEnabled = false
        campo.inlinePredictionType = .no
        campo.writingToolsBehavior = .none
        campo.insertionPointColor = .clear
        campo.selectedTextAttributes = [.backgroundColor: NSColor.clear]
        campo.markedTextAttributes = [.foregroundColor: NSColor.clear]
        campo.coordenador = coordenador
        coordenador.campo = campo
        campo.string = geometria.texto.conteudo
        coordenador.escreverTrechos(geometria.texto)
        coordenador.sincronizar()

        let suporte = Suporte(campo: campo)
        suporte.limites = geometria.limitesDoCampo
        // O cursor começa onde foi o clique (ou no fim do texto).
        let inicio = geometria.edicao.clique.map { geometria.diagramacao.indice(em: geometria.corpo($0)) }
            ?? (geometria.texto.conteudo as NSString).length
        suporte.aoEntrarNaJanela = { [weak campo, weak coordenador] janela in
            guard let campo else { return }
            janela.makeFirstResponder(campo)
            campo.setSelectedRange(NSRange(location: inicio, length: 0))
            coordenador?.atualizarCursor()
            #if DEBUG
            Depuracao.selecionarTextoParaTeste(campo)
            #endif
        }
        return suporte
    }

    func updateNSView(_ suporte: Suporte, context: Context) {
        context.coordinator.geometria = geometria
        context.coordinator.sincronizar()
        suporte.limites = geometria.limitesDoCampo
    }

    /// Recebe o tamanho dado pela tela e mostra o campo nele, com as coordenadas em pt do corpo.
    final class Suporte: NSView {
        let campo: CampoInvisivel
        var aoEntrarNaJanela: ((NSWindow) -> Void)?
        var limites = CGRect.zero {
            didSet { if limites != oldValue { needsLayout = true } }
        }

        init(campo: CampoInvisivel) {
            self.campo = campo
            super.init(frame: .zero)
            addSubview(campo)
        }

        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }

        override func layout() {
            super.layout()
            campo.frame = bounds
            guard limites.width > 0, limites.height > 0 else { return }
            campo.setBoundsSize(limites.size)
            campo.setBoundsOrigin(limites.origin)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let aoEntrar = aoEntrarNaJanela else { return }
            aoEntrarNaJanela = nil
            DispatchQueue.main.async { aoEntrar(window) }
        }
    }

    /// NSTextView que usa a diagramação do texto para cliques, setas ↑ ↓ e a posição da janela dos métodos
    /// de entrada, e avisa ao perder o foco.
    final class CampoInvisivel: NSTextView {
        weak var coordenador: Coordenador?

        override func resignFirstResponder() -> Bool {
            let saiu = super.resignFirstResponder()
            if saiu { coordenador?.saiu() }
            return saiu
        }

        /// Clique põe o cursor; arrastar seleciona; duplo clique, a palavra; triplo, a linha; ⇧ estende.
        override func mouseDown(with evento: NSEvent) {
            guard let d = coordenador?.geometria?.diagramacao else { return super.mouseDown(with: evento) }
            window?.makeFirstResponder(self)
            if hasMarkedText() { unmarkText() }
            let granularidade: NSSelectionGranularity = switch evento.clickCount {
            case 1: .selectByCharacter
            case 2: .selectByWord
            default: .selectByParagraph
            }
            func indice(_ e: NSEvent) -> Int { d.indice(em: convert(e.locationInWindow, from: nil)) }
            func faixa(_ a: Int, _ b: Int) -> NSRange {
                let r = NSRange(location: min(a, b), length: abs(a - b))
                return granularidade == .selectByCharacter ? r : selectionRange(forProposedRange: r, granularity: granularidade)
            }
            let atual = selectedRange(), clicado = indice(evento)
            let ancora = evento.modifierFlags.contains(.shift)
                ? (clicado > atual.location ? atual.location : NSMaxRange(atual))
                : clicado
            setSelectedRange(faixa(ancora, clicado))
            while let proximo = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                setSelectedRange(faixa(ancora, indice(proximo)))
                if proximo.type == .leftMouseUp { break }
            }
        }

        /// Colar e arrastar trazem só o texto (com o estilo de onde ele entra).
        override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
        override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [.string] }

        /// ⌘U (Formatar › Sublinhado) liga o sublinhado do painel Caractere nas letras selecionadas.
        override func underline(_ sender: Any?) { coordenador?.doc.mudarEstilo { $0.sublinhado.toggle() } }

        override func moveUp(_ sender: Any?) { mover(-1) }
        override func moveDown(_ sender: Any?) { mover(1) }

        private func mover(_ sentido: Int) {
            guard let d = coordenador?.geometria?.diagramacao else { return }
            let r = selectedRange()
            setSelectedRange(NSRange(location: d.vizinha(sentido < 0 ? r.location : NSMaxRange(r), sentido), length: 0))
        }

        override func firstRect(forCharacterRange faixa: NSRange, actualRange: NSRangePointer?) -> NSRect {
            guard let geometria = coordenador?.geometria, let window else {
                return super.firstRect(forCharacterRange: faixa, actualRange: actualRange)
            }
            actualRange?.pointee = faixa
            return window.convertToScreen(convert(geometria.retangulo(faixa), to: nil))
        }
    }

    /// Estilo guardado como atributo do texto do campo (comparável, para os trechos se juntarem).
    nonisolated final class CaixaEstilo: NSObject, Sendable {
        let estilo: EstiloCaractere
        init(_ estilo: EstiloCaractere) { self.estilo = estilo }
        override func isEqual(_ outro: Any?) -> Bool { (outro as? CaixaEstilo)?.estilo == estilo }
        override var hash: Int { estilo.hashValue }
    }

    static let chaveEstilo = NSAttributedString.Key("cutline.estilo")

    final class Coordenador: NSObject, NSTextViewDelegate {
        let doc: Documento
        let cursor: CursorTexto
        let sessao: UUID
        weak var campo: NSTextView?
        var geometria: GeometriaEdicao?
        private var focoVisto: Int

        init(doc: Documento, cursor: CursorTexto, sessao: UUID) {
            self.doc = doc
            self.cursor = cursor
            self.sessao = sessao
            focoVisto = doc.focarTextoNaTela
        }

        /// Atributos de um trecho no campo: o estilo e a fonte (o campo não aparece, mas o macOS usa a fonte
        /// para os acentos e os métodos de entrada).
        private func atributos(_ e: EstiloCaractere) -> [NSAttributedString.Key: Any] {
            var cor = NSColor.clear
            #if DEBUG
            if Depuracao.textoNaTela == "visivel" { cor = NSColor.systemBlue.withAlphaComponent(0.55) }
            #endif
            return [.font: e.fonteCT(corpo: e.corpoEfetivo) as NSFont, .foregroundColor: cor,
                    CampoTextoNaTela.chaveEstilo: CaixaEstilo(e)]
        }

        /// Trechos do texto do campo, pelo atributo de estilo.
        func lerTrechos() -> [Trecho] {
            guard let armazenamento = campo?.textStorage else { return [] }
            let padrao = geometria?.texto.estilo ?? EstiloCaractere()
            var trechos: [Trecho] = []
            armazenamento.enumerateAttribute(CampoTextoNaTela.chaveEstilo, in: NSRange(location: 0, length: armazenamento.length)) { valor, faixa, _ in
                trechos.append(Trecho(comprimento: faixa.length, estilo: (valor as? CaixaEstilo)?.estilo ?? padrao))
            }
            return trechos
        }

        /// Põe no campo o estilo de cada trecho do documento (o painel mudou as letras selecionadas).
        func escreverTrechos(_ texto: Texto) {
            guard let campo, let armazenamento = campo.textStorage, armazenamento.string == texto.conteudo, !campo.hasMarkedText() else { return }
            armazenamento.beginEditing()
            var posicao = 0
            for t in texto.trechosCompletos {
                armazenamento.setAttributes(atributos(t.estilo), range: NSRange(location: posicao, length: t.comprimento))
                posicao += t.comprimento
            }
            armazenamento.endEditing()
        }

        /// Depois de cada mudança do documento: trechos, estilo da digitação e o foco de volta ao texto.
        func sincronizar() {
            guard let campo, let texto = geometria?.texto else { return }
            if texto.comprimento > 0 {
                var doCampo = texto
                doCampo.trechos = lerTrechos()
                doCampo.normalizar()
                if doCampo.trechos != texto.trechos || doCampo.estilo != texto.estilo { escreverTrechos(texto) }
            }
            if let digitacao = doc.estiloDigitacao ?? (texto.comprimento == 0 ? texto.estilo : nil),
               (campo.typingAttributes[CampoTextoNaTela.chaveEstilo] as? CaixaEstilo)?.estilo != digitacao {
                campo.typingAttributes = atributos(digitacao)
            }
            if doc.focarTextoNaTela != focoVisto {
                focoVisto = doc.focarTextoNaTela
                campo.window?.makeFirstResponder(campo)
            }
        }

        func atualizarCursor() {
            guard let campo else { return }
            let selecao = campo.selectedRange()
            cursor.selecao = selecao
            cursor.marcado = campo.hasMarkedText() ? campo.markedRange() : nil
            cursor.mudou = Date()
            if doc.selecaoTexto != selecao { doc.selecaoTexto = selecao }
            // Mover o cursor descarta o estilo escolhido para a digitação (vale o da letra antes dele).
            if doc.estiloDigitacao != nil { doc.estiloDigitacao = nil }
        }

        /// Perdeu o foco: termina a edição depois (pode ter sido um clique que já abriu outra). Se o foco foi
        /// para um campo da barra ou dos painéis, a edição continua: eles agem nas letras selecionadas.
        func saiu() {
            let doc = doc, sessao = sessao
            DispatchQueue.main.async { [weak campo] in
                if let janela = campo?.window, let foco = janela.firstResponder as? NSText, foco !== campo { return }
                doc.terminarTexto(sessao: sessao)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let campo else { return }
            let digitacao = (campo.typingAttributes[CampoTextoNaTela.chaveEstilo] as? CaixaEstilo)?.estilo
            doc.digitarTexto(campo.string, trechos: lerTrechos(), estiloVazio: digitacao)
            atualizarCursor()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            atualizarCursor()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Esc termina a edição e volta para a seleção com o texto selecionado (como no Illustrator).
            guard selector == #selector(NSResponder.cancelOperation(_:)) || selector == #selector(NSTextView.complete(_:)) else {
                return false
            }
            doc.terminarTexto()
            doc.ferramenta = .selecao
            return true
        }

        /// Quebras de linha de outros sistemas (colar de outro app) viram a quebra comum, a única que as
        /// linhas do texto conhecem.
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString texto: String?) -> Bool {
            guard let texto, texto.contains(where: { $0 == "\r" || $0 == "\r\n" || $0 == "\u{2028}" || $0 == "\u{2029}" }) else {
                return true
            }
            let normal = texto.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n")
            textView.insertText(normal, replacementRange: range)
            return false
        }
    }
}
