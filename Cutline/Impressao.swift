// Arquivo › Imprimir… (⌘P): a página A4 em tamanho real com o que é impresso — preenchimentos, imagens
// e traços com espessura — e, no Print & Cut, as marcas de registro. Traços de 0 pt só indicam o corte
// e não saem. As cores vão em CMYK (perfil CMYK genérico do sistema; o ColorSync converte para a impressora).
import AppKit
import SwiftUI

enum Impressao {
    static let pontosPorMM = 72 / 25.4

    /// Painel de impressão do sistema (em folha sobre a janela). Com `pdf`, grava direto no arquivo, sem painel.
    static func imprimir(_ doc: Documento, na janela: NSWindow?, pdf: URL? = nil) {
        let info = NSPrintInfo()
        // A4, sem margens nem centralização: a página sai na mesma posição e escala do documento.
        info.paperSize = NSSize(width: Documento.pagina.width * pontosPorMM, height: Documento.pagina.height * pontosPorMM)
        info.orientation = .portrait
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        if let pdf {
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL.rawValue] = pdf
        }
        let operacao = NSPrintOperation(view: FolhaImpressa(doc: doc), printInfo: info)
        operacao.jobTitle = janela?.title ?? "Cutline"
        if pdf != nil {
            operacao.showsPrintPanel = false
            operacao.showsProgressPanel = false
            operacao.run()
        } else if let janela {
            operacao.runModal(for: janela, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operacao.run()
        }
    }

    /// Desenha a página em mm (y para baixo) num contexto em pontos.
    static func desenhar(_ doc: Documento, em cg: CGContext) {
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.scaleBy(x: pontosPorMM, y: pontosPorMM)
        for objeto in doc.objetosEmOrdem where doc.visivel(objeto) {
            let caminho = objeto.caminho.cgPath
            if let cor = objeto.preenchimento {
                cg.addPath(caminho)
                cg.setFillColor(cor.cgCMYK)
                cg.fillPath(using: .evenOdd)
            }
            if let imagem = objeto.imagem, let cgImagem = doc.imagem(imagem.chave) {
                // Recortada pelo contorno (regra par-ímpar, como na tela).
                cg.saveGState()
                cg.addPath(caminho)
                cg.clip(using: .evenOdd)
                cg.concatenate(imagem.transformacao.cg.concatenating(objeto.quadroParaPagina))
                // Pixels com y para baixo: desvira a imagem (o CoreGraphics desenha com y para cima).
                cg.translateBy(x: 0, y: CGFloat(cgImagem.height))
                cg.scaleBy(x: 1, y: -1)
                cg.draw(cgImagem, in: CGRect(x: 0, y: 0, width: cgImagem.width, height: cgImagem.height))
                cg.restoreGState()
            }
            if objeto.espessura > 0 { tracar(objeto, caminho, em: cg) }
        }
        if doc.marcas {
            cg.setFillColor(CMYK(c: 0, m: 0, y: 0, k: 100).cgCMYK)
            cg.fill(doc.configMarcas.retangulos)
        }
    }

    /// Traço com espessura (pt → mm), ponta, canto, picotado e alinhamento — como na tela.
    private static func tracar(_ objeto: Objeto, _ caminho: CGPath, em cg: CGContext) {
        let e = objeto.estilo
        cg.saveGState()
        defer { cg.restoreGState() }
        var largura = objeto.espessura / pontosPorMM
        if e.alinhamento != .centro {
            // Dentro/fora: o dobro da espessura, recortado pelo próprio contorno (ou pelo lado de fora dele).
            if e.alinhamento == .fora { cg.addRect(CGRect(origin: .zero, size: Documento.pagina).insetBy(dx: -50, dy: -50)) }
            cg.addPath(caminho)
            cg.clip(using: .evenOdd)
            largura *= 2
        }
        cg.setStrokeColor(objeto.traco.cgCMYK)
        cg.setLineWidth(largura)
        cg.setLineCap(e.ponta.cg)
        cg.setLineJoin(e.canto.cg)
        cg.setMiterLimit(e.limiteCanto)
        if let padrao = e.linha.padrao { cg.setLineDash(phase: 0, lengths: padrao.map { CGFloat($0) }) }
        cg.addPath(caminho)
        cg.strokePath()
    }
}

extension CMYK {
    /// Cor no perfil CMYK genérico do sistema (para impressão).
    var cgCMYK: CGColor {
        let espaco = CGColorSpace(name: CGColorSpace.genericCMYK)!
        return CGColor(colorSpace: espaco, components: [c / 100, m / 100, y / 100, k / 100, 1])!
    }
}

/// A página a imprimir, do tamanho do papel (A4 em pontos), com y para baixo.
private final class FolhaImpressa: NSView {
    let doc: Documento

    init(doc: Documento) {
        self.doc = doc
        super.init(frame: NSRect(x: 0, y: 0, width: Documento.pagina.width * Impressao.pontosPorMM,
                                 height: Documento.pagina.height * Impressao.pontosPorMM))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // Uma página, a folha inteira, encostada na borda do papel. Sem isto, o AppKit pagina pela área
    // imprimível da impressora e a põe no canto dela (3 mm para dentro na padrão): o desenho sai deslocado.
    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: 1)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect { bounds }

    override func locationOfPrintRect(_ rect: NSRect) -> NSPoint { .zero }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        Impressao.desenhar(doc, em: cg)
    }
}
