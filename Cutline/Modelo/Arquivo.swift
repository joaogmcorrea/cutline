// Arquivo do documento: o formato próprio (.cutline, property list binária com as imagens dentro)
// e a abertura de arquivos do Silhouette Studio (.studio3). O macOS nunca grava o .studio3: ⌘S pergunta se
// grava por cima dele (Modelo/SalvarStudio.swift) ou como documento do Cutline.
import CutlineKit
import SwiftUI
import UniformTypeIdentifiers

nonisolated extension UTType {
    /// Declarado em Cutline-Info.plist.
    static let documentoCutline = UTType(exportedAs: "io.github.joaogmcorrea.cutline.documento")
    /// O identificador que o próprio Silhouette Studio declara.
    static let studio3 = UTType(importedAs: "public.studio3")
}

/// O que vai para o disco. Mudanças incompatíveis sobem `versao`.
nonisolated struct Arquivo: Codable, Sendable {
    static let versaoAtual = 1

    struct CortePorCor: Codable, Sendable {
        var cor: CMYK
        var config: ConfigCorte
    }

    var versao = versaoAtual
    var objetos: [Objeto]
    var cortes: [CortePorCor]
    var ordemCortes: [CMYK]
    var imagens: [String: Data]
    var camadas: [Camada] = []
    var camadaAtiva: UUID?
    var recentes: [CMYK] = []
    var guias = Guias()
    var marcas = false
    var configMarcas = ConfigMarcas.padrao
    var comBase = true
    var baseDeCorte: CuttingMat?

    static func ler(_ dados: Data) throws -> Arquivo {
        let arquivo = try PropertyListDecoder().decode(Arquivo.self, from: dados)
        guard arquivo.versao <= versaoAtual else { throw ErroArquivo.versaoNova }
        return arquivo
    }

    func dados() throws -> Data {
        let codificador = PropertyListEncoder()
        codificador.outputFormat = .binary
        return try codificador.encode(self)
    }
}

/// Leitura tolerante: o que faltar (arquivos de versões anteriores) fica vazio.
extension Arquivo {
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        versao = try c.decodeIfPresent(Int.self, forKey: .versao) ?? 1
        objetos = try c.decodeIfPresent([Objeto].self, forKey: .objetos) ?? []
        cortes = try c.decodeIfPresent([CortePorCor].self, forKey: .cortes) ?? []
        ordemCortes = try c.decodeIfPresent([CMYK].self, forKey: .ordemCortes) ?? []
        imagens = try c.decodeIfPresent([String: Data].self, forKey: .imagens) ?? [:]
        camadas = try c.decodeIfPresent([Camada].self, forKey: .camadas) ?? []
        camadaAtiva = try c.decodeIfPresent(UUID.self, forKey: .camadaAtiva)
        recentes = try c.decodeIfPresent([CMYK].self, forKey: .recentes) ?? []
        guias = try c.decodeIfPresent(Guias.self, forKey: .guias) ?? Guias()
        marcas = try c.decodeIfPresent(Bool.self, forKey: .marcas) ?? false
        configMarcas = try c.decodeIfPresent(ConfigMarcas.self, forKey: .configMarcas) ?? .padrao
        comBase = try c.decodeIfPresent(Bool.self, forKey: .comBase) ?? true
        baseDeCorte = try c.decodeIfPresent(CuttingMat.self, forKey: .baseDeCorte)
    }
}

nonisolated enum ErroArquivo: LocalizedError {
    case vazio
    case versaoNova
    case soLeitura
    case studioMudou
    case imagemNovaNoStudio

    var errorDescription: String? {
        switch self {
        case .vazio: String(localized: "O arquivo está vazio.")
        case .versaoNova: String(localized: "Este documento foi salvo por uma versão mais nova do Cutline.")
        case .soLeitura: String(localized: "O arquivo do Silhouette Studio não é alterado. Use Arquivo › Salvar como… para guardar como documento do Cutline.")
        case .studioMudou: String(localized: "O arquivo .studio3 mudou desde que foi aberto (foi gravado por outro programa?). Para não perder essas mudanças, ele não foi gravado; salve como documento do Cutline ou abra o arquivo de novo.")
        case .imagemNovaNoStudio: String(localized: "O documento tem imagens novas, que o Cutline ainda não sabe pôr num .studio3. Salve como documento do Cutline.")
        }
    }
}

// O macOS cria e lê o documento fora da thread principal (e grava o arquivo fora dela também): a
// leitura monta os dados antes e só então cria o Documento; o retrato (`snapshot`) é feito na principal.
nonisolated extension Documento: ReferenceFileDocument {
    static var readableContentTypes: [UTType] { [.documentoCutline, .studio3] }
    static var writableContentTypes: [UTType] { [.documentoCutline] }

    convenience init(configuration: ReadConfiguration) throws {
        guard let dados = configuration.file.regularFileContents, !dados.isEmpty else { throw ErroArquivo.vazio }
        if configuration.contentType.conforms(to: .studio3) {
            let studio = try StudioDocument(data: dados)
            let (objetos, cortes, imagens, aviso, pecas) = Self.importacao(studio)
            // O Print & Cut como o Studio deixou: ligado ou não, e as marcas no mesmo lugar da folha que ele imprime.
            let marcas = studio.registrationMarks
            self.init(objetos: objetos, cortes: cortes, imagens: imagens, marcas: marcas?.on ?? false,
                      configMarcas: marcas.map(ConfigMarcas.init) ?? .padrao, aviso: aviso, veioDoStudio: true)
            self.studio = OrigemStudio(dados: dados, pecas: pecas, imagens: Set(studio.images.keys))
        } else {
            let arquivo = try Arquivo.ler(dados)
            self.init(objetos: arquivo.objetos,
                      cortes: Dictionary(arquivo.cortes.map { ($0.cor, $0.config) }, uniquingKeysWith: { _, ultima in ultima }),
                      ordemCortes: arquivo.ordemCortes, imagens: arquivo.imagens, camadas: arquivo.camadas,
                      camadaAtiva: arquivo.camadaAtiva, recentes: arquivo.recentes, guias: arquivo.guias,
                      marcas: arquivo.marcas, configMarcas: arquivo.configMarcas, comBase: arquivo.comBase,
                      baseDeCorte: .some(arquivo.baseDeCorte))
        }
    }

    func snapshot(contentType: UTType) throws -> Data {
        // Nunca grava por cima do arquivo do Studio, mesmo que o macOS tente salvar no lugar.
        guard contentType.conforms(to: .documentoCutline) else { throw ErroArquivo.soLeitura }
        let usadas = Set(objetos.compactMap { $0.imagem?.chave })
        // Texto vazio só existe enquanto se digita na tela: não vai para o arquivo.
        return try Arquivo(objetos: objetos.filter { !$0.textoVazio }, cortes: cortes.map { Arquivo.CortePorCor(cor: $0.key, config: $0.value) },
                           ordemCortes: ordemCortes, imagens: imagens.filter { usadas.contains($0.key) },
                           camadas: camadas, camadaAtiva: camadaAtiva, recentes: recentes, guias: guias, marcas: marcas,
                           configMarcas: configMarcas, comBase: comBase, baseDeCorte: baseDeCorte).dados()
    }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        guard configuration.contentType.conforms(to: .documentoCutline) else { throw ErroArquivo.soLeitura }
        return FileWrapper(regularFileWithContents: snapshot)
    }
}

nonisolated extension Documento {
    /// Objetos de um documento do Silhouette Studio: cada contorno vira um caminho com a cor da linha
    /// (que define o corte), o preenchimento e a imagem recortada; grupos e rotações já vêm desfeitos.
    /// Devolve também as cores desligadas no envio do Studio, as imagens usadas, o resumo para a janela e de
    /// onde veio cada objeto (para gravar por cima).
    static func importacao(_ studio: StudioDocument) -> ([Objeto], [CMYK: ConfigCorte], [String: Data], String, [Objeto.ID: PecaStudio]) {
        var novos: [Objeto] = []
        var pecas: [Objeto.ID: PecaStudio] = [:]
        var cortes: [CMYK: ConfigCorte] = [:]
        var imagens: [String: Data] = [:]
        for o in studio.objects {
            let caixa = o.path.boundingBoxOfPath
            guard !caixa.isNull else { continue }
            let largura = caixa.width > 0 ? caixa.width : 1, altura = caixa.height > 0 ? caixa.height : 1
            let relativo = { (p: CGPoint) in CGPoint(x: (p.x - caixa.minX) / largura, y: (p.y - caixa.minY) / altura) }
            let subcaminhos = o.subpaths.map { nos in
                Subcaminho(nos: nos.map { No(ponto: relativo($0.point), entrada: $0.controlIn.map(relativo),
                                             saida: $0.controlOut.map(relativo)) })
            }
            var objeto = Objeto(forma: .caminho(subcaminhos), quadro: caixa,
                                traco: CMYK(vermelho: o.line.red, verde: o.line.green, azul: o.line.blue), corta: o.cuts)
            objeto.rotulo = ["Rectangle": String(localized: "Retângulo"), "Ellipse": String(localized: "Elipse"),
                             "Rounded Rectangle": String(localized: "Retângulo arredondado")][o.kind]
            if studio.lineColorCuts[o.line.hex] == false, cortes[objeto.traco] == nil {
                var config = configPadrao(objeto.traco)
                config.ligado = false
                cortes[objeto.traco] = config
            }
            switch o.fill {
            case .none:
                break
            case .color(let c):
                objeto.preenchimento = CMYK(vermelho: c.red, verde: c.green, azul: c.blue)
            case .image(let chave, let pixelParaPagina):
                guard let imagem = studio.images[chave] else { break }
                let paginaParaQuadro = CGAffineTransform(translationX: -caixa.minX, y: -caixa.minY)
                    .concatenating(CGAffineTransform(scaleX: 1 / largura, y: 1 / altura))
                imagens[chave] = imagem.data
                objeto.imagem = ImagemNaForma(chave: chave, transformacao: Transformacao(pixelParaPagina.concatenating(paginaParaQuadro)))
            }
            novos.append(objeto)
            pecas[objeto.id] = PecaStudio(caminho: o.source, objeto: objeto, linha: o.line)
        }
        let fora = novos.filter { !$0.quadro.intersects(CGRect(origin: .zero, size: Self.pagina)) }.count
        let semCorte = novos.filter { !$0.corta }.count
        var partes = [String(localized: "\(novos.count) objetos")]
        if studio.images.count > 0 { partes.append(String(localized: "\(studio.images.count) imagens")) }
        if semCorte > 0 { partes.append(String(localized: "\(semCorte) sem corte")) }
        if !cortes.isEmpty { partes.append(String(localized: "\(cortes.count) cores desligadas como no Studio")) }
        if fora > 0 { partes.append(String(localized: "\(fora) fora da página")) }
        if studio.skipped > 0 { partes.append(String(localized: "\(studio.skipped) não lidos")) }
        if studio.registrationMarks?.on == true { partes.append(String(localized: "Print & Cut ligado")) }
        let aviso = String(localized: "Importado do Silhouette Studio: \(partes.joined(separator: " · ")). ⌘S grava por cima do .studio3 ou como documento do Cutline.")
        return (novos, cortes, imagens, aviso, pecas)
    }
}
