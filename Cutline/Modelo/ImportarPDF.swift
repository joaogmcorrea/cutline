// Importar PDF e AI (Illustrator salvo "compatível com PDF"): os caminhos vetoriais da 1ª página viram
// objetos, na mesma posição da página, com a regra de pintura comum (Modelo/ImportarVetor.swift); cores
// CMYK do arquivo entram como estão. Textos e imagens do PDF não entram (contar e avisar). Leitura pelo
// CGPDFScanner (operadores do conteúdo da página).
import CoreGraphics
import Foundation

nonisolated enum ImportarPDF {
    static func ler(_ dados: Data) throws -> ImportacaoVetorial {
        guard let provedor = CGDataProvider(data: dados as CFData), let pdf = CGPDFDocument(provedor), let pagina = pdf.page(at: 1)
        else { throw ImportarVetor.Erro.pdf }
        let caixa = pagina.getBoxRect(.cropBox)
        let leitor = Leitor(caixa: caixa)
        let conteudo = CGPDFContentStreamCreateWithPage(pagina)
        leitor.ler(conteudo)
        return ImportacaoVetorial(objetos: leitor.objetos, textos: leitor.textos, imagens: leitor.imagens)
    }

    /// Estado do intérprete (o CGPDFScanner chama funções C; o estado vai pelo ponteiro `info`).
    nonisolated final class Leitor {
        static let mm = 25.4 / 72

        struct Estado {
            var ctm = CGAffineTransform.identity
            var traco: CMYK? = CMYK(c: 0, m: 0, y: 0, k: 100)
            var preenchimento: CMYK? = CMYK(c: 0, m: 0, y: 0, k: 100)
            var espessura = 1.0
        }

        var estado = Estado()
        var pilha: [Estado] = []
        var caminho = CGMutablePath()
        var objetos: [Objeto] = []
        var textos = 0
        var imagens = 0
        var conteudos: [CGPDFContentStreamRef] = []
        let paraPagina: CGAffineTransform
        private var profundidade = 0

        init(caixa: CGRect) {
            // Espaço do PDF (pt, y para cima) → mm da página com y para baixo.
            paraPagina = CGAffineTransform(translationX: -caixa.minX, y: -caixa.maxY)
                .concatenating(CGAffineTransform(scaleX: Self.mm, y: -Self.mm))
        }

        func ler(_ conteudo: CGPDFContentStreamRef) {
            guard profundidade < 12, let tabela = CGPDFOperatorTableCreate() else { return }
            profundidade += 1
            defer { profundidade -= 1 }
            Self.registrar(tabela)
            conteudos.append(conteudo)
            let scanner = CGPDFScannerCreate(conteudo, tabela, Unmanaged.passUnretained(self).toOpaque())
            CGPDFScannerScan(scanner)
            CGPDFScannerRelease(scanner)
            conteudos.removeLast()
            CGPDFOperatorTableRelease(tabela)
        }

        // MARK: Pintura

        func pintar(traco: Bool, preenchimento: Bool, fechar: Bool = false) {
            if fechar { caminho.closeSubpath() }
            defer { caminho = CGMutablePath() }
            guard !caminho.isEmpty, traco || preenchimento else { return }
            let t = estado.ctm.concatenating(paraPagina)
            guard let pagina = caminho.copy(using: [t]) else { return }
            // Espessura na escala da página (pt).
            let escala = sqrt(abs(estado.ctm.a * estado.ctm.d - estado.ctm.b * estado.ctm.c))
            if let objeto = ImportarVetor.objeto(pagina, traco: traco ? estado.traco : nil, espessura: estado.espessura * escala,
                                                 preenchimento: preenchimento ? estado.preenchimento : nil) {
                objetos.append(objeto)
            }
        }

        // MARK: Operadores

        private static func registrar(_ t: CGPDFOperatorTableRef) {
            CGPDFOperatorTableSetCallback(t, "q") { _, info in
                guard let l = leitor(info) else { return }
                l.pilha.append(l.estado)
            }
            CGPDFOperatorTableSetCallback(t, "Q") { _, info in
                guard let l = leitor(info), let anterior = l.pilha.popLast() else { return }
                l.estado = anterior
            }
            CGPDFOperatorTableSetCallback(t, "cm") { s, info in
                guard let l = leitor(info), let v = numeros(s, 6) else { return }
                l.estado.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(l.estado.ctm)
            }
            CGPDFOperatorTableSetCallback(t, "w") { s, info in
                guard let l = leitor(info), let v = numeros(s, 1) else { return }
                l.estado.espessura = v[0]
            }
            CGPDFOperatorTableSetCallback(t, "m") { s, info in
                guard let l = leitor(info), let v = numeros(s, 2) else { return }
                l.caminho.move(to: CGPoint(x: v[0], y: v[1]))
            }
            CGPDFOperatorTableSetCallback(t, "l") { s, info in
                guard let l = leitor(info), let v = numeros(s, 2), !l.caminho.isEmpty else { return }
                l.caminho.addLine(to: CGPoint(x: v[0], y: v[1]))
            }
            CGPDFOperatorTableSetCallback(t, "c") { s, info in
                guard let l = leitor(info), let v = numeros(s, 6), !l.caminho.isEmpty else { return }
                l.caminho.addCurve(to: CGPoint(x: v[4], y: v[5]), control1: CGPoint(x: v[0], y: v[1]), control2: CGPoint(x: v[2], y: v[3]))
            }
            CGPDFOperatorTableSetCallback(t, "v") { s, info in
                guard let l = leitor(info), let v = numeros(s, 4), !l.caminho.isEmpty else { return }
                l.caminho.addCurve(to: CGPoint(x: v[2], y: v[3]), control1: l.caminho.currentPoint, control2: CGPoint(x: v[0], y: v[1]))
            }
            CGPDFOperatorTableSetCallback(t, "y") { s, info in
                guard let l = leitor(info), let v = numeros(s, 4), !l.caminho.isEmpty else { return }
                let fim = CGPoint(x: v[2], y: v[3])
                l.caminho.addCurve(to: fim, control1: CGPoint(x: v[0], y: v[1]), control2: fim)
            }
            CGPDFOperatorTableSetCallback(t, "h") { _, info in leitor(info)?.caminho.closeSubpath() }
            CGPDFOperatorTableSetCallback(t, "re") { s, info in
                guard let l = leitor(info), let v = numeros(s, 4) else { return }
                l.caminho.addRect(CGRect(x: v[0], y: v[1], width: v[2], height: v[3]))
            }
            // Pintura.
            CGPDFOperatorTableSetCallback(t, "S") { _, info in leitor(info)?.pintar(traco: true, preenchimento: false) }
            CGPDFOperatorTableSetCallback(t, "s") { _, info in leitor(info)?.pintar(traco: true, preenchimento: false, fechar: true) }
            for op in ["f", "F", "f*"] {
                CGPDFOperatorTableSetCallback(t, op) { _, info in leitor(info)?.pintar(traco: false, preenchimento: true) }
            }
            for op in ["B", "B*"] {
                CGPDFOperatorTableSetCallback(t, op) { _, info in leitor(info)?.pintar(traco: true, preenchimento: true) }
            }
            for op in ["b", "b*"] {
                CGPDFOperatorTableSetCallback(t, op) { _, info in leitor(info)?.pintar(traco: true, preenchimento: true, fechar: true) }
            }
            // Recorte (W/W* + n) e caminho sem pintura: descarta.
            CGPDFOperatorTableSetCallback(t, "n") { _, info in leitor(info)?.caminho = CGMutablePath() }
            // Cores.
            CGPDFOperatorTableSetCallback(t, "G") { s, info in leitor(info)?.estado.traco = numeros(s, 1).flatMap(cor) }
            CGPDFOperatorTableSetCallback(t, "g") { s, info in leitor(info)?.estado.preenchimento = numeros(s, 1).flatMap(cor) }
            CGPDFOperatorTableSetCallback(t, "RG") { s, info in leitor(info)?.estado.traco = numeros(s, 3).flatMap(cor) }
            CGPDFOperatorTableSetCallback(t, "rg") { s, info in leitor(info)?.estado.preenchimento = numeros(s, 3).flatMap(cor) }
            CGPDFOperatorTableSetCallback(t, "K") { s, info in leitor(info)?.estado.traco = numeros(s, 4).flatMap(cor) }
            CGPDFOperatorTableSetCallback(t, "k") { s, info in leitor(info)?.estado.preenchimento = numeros(s, 4).flatMap(cor) }
            for op in ["SC", "SCN"] {
                CGPDFOperatorTableSetCallback(t, op) { s, info in
                    guard let l = leitor(info) else { return }
                    if let c = cor(todosNumeros(s)) { l.estado.traco = c }
                }
            }
            for op in ["sc", "scn"] {
                CGPDFOperatorTableSetCallback(t, op) { s, info in
                    guard let l = leitor(info) else { return }
                    if let c = cor(todosNumeros(s)) { l.estado.preenchimento = c }
                }
            }
            // Texto e imagens: só contam.
            for op in ["Tj", "TJ", "'", "\""] {
                CGPDFOperatorTableSetCallback(t, op) { _, info in leitor(info)?.textos += 1 }
            }
            CGPDFOperatorTableSetCallback(t, "BI") { _, info in leitor(info)?.imagens += 1 }
            // XObject: formulário (conteúdo aninhado, comum no Illustrator) ou imagem.
            CGPDFOperatorTableSetCallback(t, "Do") { s, info in
                guard let l = leitor(info), let conteudo = l.conteudos.last else { return }
                var nome: UnsafePointer<CChar>?
                guard CGPDFScannerPopName(s, &nome), let nome,
                      let objeto = CGPDFContentStreamGetResource(conteudo, "XObject", nome) else { return }
                var fluxo: CGPDFStreamRef?
                guard CGPDFObjectGetValue(objeto, .stream, &fluxo), let fluxo, let dicionario = CGPDFStreamGetDictionary(fluxo) else { return }
                var subtipo: UnsafePointer<CChar>?
                guard CGPDFDictionaryGetName(dicionario, "Subtype", &subtipo), let subtipo else { return }
                switch String(cString: subtipo) {
                case "Image":
                    l.imagens += 1
                case "Form":
                    let anterior = l.estado
                    var matriz: CGPDFArrayRef?
                    if CGPDFDictionaryGetArray(dicionario, "Matrix", &matriz), let matriz, CGPDFArrayGetCount(matriz) == 6 {
                        var m = [CGFloat](repeating: 0, count: 6)
                        for i in 0..<6 { var x: CGPDFReal = 0; CGPDFArrayGetNumber(matriz, i, &x); m[i] = x }
                        l.estado.ctm = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]).concatenating(l.estado.ctm)
                    }
                    var recursos: CGPDFDictionaryRef?
                    CGPDFDictionaryGetDictionary(dicionario, "Resources", &recursos)
                    let aninhado = CGPDFContentStreamCreateWithStream(fluxo, recursos ?? dicionario, conteudo)
                    l.ler(aninhado)
                    CGPDFContentStreamRelease(aninhado)
                    l.estado = anterior
                default:
                    break
                }
            }
        }
    }
}

// Funções soltas: os callbacks do CGPDFScanner são ponteiros de função C e não podem capturar nada.
private nonisolated func leitor(_ info: UnsafeMutableRawPointer?) -> ImportarPDF.Leitor? {
    info.map { Unmanaged<ImportarPDF.Leitor>.fromOpaque($0).takeUnretainedValue() }
}

private nonisolated func numeros(_ scanner: CGPDFScannerRef, _ n: Int) -> [Double]? {
    var v = [Double](repeating: 0, count: n)
    for i in stride(from: n - 1, through: 0, by: -1) {
        var x: CGPDFReal = 0
        guard CGPDFScannerPopNumber(scanner, &x) else { return nil }
        v[i] = Double(x)
    }
    return v
}

/// Todos os números da pilha (cores com quantidade variável de componentes).
private nonisolated func todosNumeros(_ scanner: CGPDFScannerRef) -> [Double] {
    var v: [Double] = []
    var x: CGPDFReal = 0
    while CGPDFScannerPopNumber(scanner, &x) { v.insert(Double(x), at: 0) }
    return v
}

private nonisolated func cor(_ v: [Double]) -> CMYK? { ImportarVetor.cor(v) }
