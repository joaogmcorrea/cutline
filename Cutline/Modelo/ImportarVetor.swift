// Importar arquivos vetoriais (Arquivo › Importar…): PDF, AI, SVG e EPS viram caminhos livres na camada ativa.
// O formato é reconhecido pelo conteúdo, não pela extensão (o .ai moderno é um PDF; o antigo, PostScript).
// A regra de pintura é a mesma nos quatro: traço → cor de corte (traços finos, até 0,5 pt, viram 0 pt: só
// corte); só preenchimento → cor impressa, sem corte; textos e imagens não entram (são contados para o aviso).
// Leitores: Modelo/ImportarPDF.swift, Modelo/ImportarSVG.swift e Modelo/ImportarEPS.swift.
import Compression
import CoreGraphics
import Foundation

/// O que um arquivo vetorial trouxe.
nonisolated struct ImportacaoVetorial {
    var objetos: [Objeto] = []
    /// Textos e imagens encontrados e deixados de fora.
    var textos = 0
    var imagens = 0
}

nonisolated enum ImportarVetor {
    nonisolated enum Formato {
        case pdf, postscript, svg
    }

    nonisolated enum Erro: LocalizedError {
        case desconhecido, pdf, aiSemPDF, svg, postscript

        var errorDescription: String? {
            switch self {
            case .desconhecido: String(localized: "O arquivo não é um PDF, AI, SVG ou EPS que o Cutline saiba ler.")
            case .pdf: String(localized: "Não foi possível abrir o arquivo como PDF.")
            case .aiSemPDF:
                String(localized: "Este arquivo do Illustrator foi salvo sem o conteúdo PDF. No Illustrator, salve de novo com “Criar arquivo compatível com PDF” ligado.")
            case .svg: String(localized: "Não foi possível ler o SVG: o arquivo parece estar incompleto ou corrompido.")
            case .postscript: String(localized: "Não foi possível ler o EPS.")
            }
        }
    }

    /// Lê qualquer um dos formatos (pelo conteúdo).
    static func ler(_ dados: Data) throws -> ImportacaoVetorial {
        switch formato(dados) {
        case .pdf:
            let resultado = try ImportarPDF.ler(dados)
            // AI salvo sem "compatível com PDF": a página só tem o recado do Illustrator (texto, sem desenho nem imagem).
            if resultado.objetos.isEmpty, resultado.imagens == 0, resultado.textos > 0,
               dados.range(of: Data("AIPrivateData".utf8)) != nil { throw Erro.aiSemPDF }
            return resultado
        case .postscript:
            return try ImportarEPS.ler(dados)
        case .svg:
            return try ImportarSVG.ler(descompactarGzip(dados) ?? dados)
        case nil:
            throw Erro.desconhecido
        }
    }

    /// PDF (também o .ai moderno), PostScript (EPS e o .ai antigo) ou SVG (também o .svgz); nil = outra coisa
    /// (uma imagem, por exemplo).
    static func formato(_ dados: Data) -> Formato? {
        let inicio = dados.prefix(1024)
        if inicio.starts(with: [0xC5, 0xD0, 0xD3, 0xC6]) || inicio.starts(with: Array("%!".utf8)) { return .postscript }
        // O cabeçalho do PDF pode vir depois de algum lixo, até o byte 1024.
        if inicio.range(of: Data("%PDF-".utf8)) != nil { return .pdf }
        if inicio.starts(with: [0x1F, 0x8B]) {
            return descompactarGzip(dados).flatMap { formato($0) == .svg ? .svg : nil }
        }
        let texto = String(decoding: dados.prefix(8192), as: UTF8.self)
        if texto.drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" }).hasPrefix("<"), texto.contains("<svg") { return .svg }
        return nil
    }

    /// Objeto com um contorno em mm da página. `espessura` em pt, já na escala da página.
    static func objeto(_ caminho: CGPath, traco: CMYK?, espessura: Double, preenchimento: CMYK?) -> Objeto? {
        guard traco != nil || preenchimento != nil, let livre = Objeto.caminhoLivre(caminho) else { return nil }
        var objeto = Objeto(forma: .caminho(livre.subcaminhos), quadro: livre.quadro)
        if let traco {
            objeto.traco = traco
            objeto.espessura = espessura <= 0.5 ? 0 : (espessura * 100).rounded() / 100
        } else {
            objeto.corta = false
        }
        objeto.preenchimento = preenchimento
        return objeto
    }

    /// Cor de 1 (cinza, 1 = branco), 3 (RGB) ou 4 (CMYK) componentes de 0 a 1.
    static func cor(_ v: [Double]) -> CMYK? {
        let limitar = { (x: Double) in min(max(x, 0), 1) }
        switch v.count {
        case 1: return CMYK(c: 0, m: 0, y: 0, k: ((1 - limitar(v[0])) * 100).rounded())
        case 3: return CMYK(vermelho: v[0], verde: v[1], azul: v[2])
        case 4:
            return CMYK(c: (limitar(v[0]) * 100).rounded(), m: (limitar(v[1]) * 100).rounded(),
                        y: (limitar(v[2]) * 100).rounded(), k: (limitar(v[3]) * 100).rounded())
        default: return nil
        }
    }

    /// Conteúdo de um arquivo gzip (o .svgz); nil se não for gzip.
    static func descompactarGzip(_ dados: Data) -> Data? {
        let b = [UInt8](dados)
        guard b.count > 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 4 != 0, i + 2 <= b.count { i += 2 + Int(b[i]) + Int(b[i + 1]) << 8 }
        if flags & 8 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 16 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 2 != 0 { i += 2 }
        guard i < b.count - 8 else { return nil }
        let n = b.count
        let tamanho = Int(b[n - 4]) | Int(b[n - 3]) << 8 | Int(b[n - 2]) << 16 | Int(b[n - 1]) << 24
        guard tamanho > 0, tamanho < 512 << 20 else { return nil }
        var saida = [UInt8](repeating: 0, count: tamanho)
        let lidos = b[i..<(n - 8)].withUnsafeBufferPointer { entrada in
            saida.withUnsafeMutableBufferPointer { destino in
                // COMPRESSION_ZLIB é o deflate cru (sem o cabeçalho do zlib), o que o gzip carrega.
                compression_decode_buffer(destino.baseAddress!, tamanho, entrada.baseAddress!, entrada.count, nil, COMPRESSION_ZLIB)
            }
        }
        return lidos > 0 ? Data(saida.prefix(lidos)) : nil
    }
}
