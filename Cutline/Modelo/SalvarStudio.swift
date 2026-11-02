// Salvar por cima do .studio3. Um arquivo do Silhouette Studio aberto no Cutline fica sem arquivo do Cutline
// (JanelaPrincipal), e ⌘S pergunta se grava por cima do .studio3 ou como documento do Cutline. O .studio3 é
// refeito pelo CutlineKit (Studio3Escrita.swift): os objetos de cima que não mudaram voltam como estavam, os
// outros são remontados a partir do objeto de onde vieram. Antes da primeira gravação, uma cópia do original
// vai para o Lixo; se o arquivo mudou desde que foi aberto (gravado pelo Studio), não grava.
import AppKit
import CutlineKit
import ImageIO
import UniformTypeIdentifiers

/// De onde veio um objeto do Cutline no .studio3.
nonisolated struct PecaStudio: Sendable {
    /// `StudioDocument.Object.source`: onde está na árvore do arquivo.
    var caminho: [Int]
    /// Como estava ao abrir (ou na última gravação): igual = não mudou.
    var objeto: Objeto
    /// A cor da linha como está no arquivo (a do Cutline passa por CMYK e arredonda).
    var linha: StudioDocument.Color
}

/// O .studio3 aberto: os bytes (o modelo da gravação) e de onde veio cada objeto.
nonisolated struct OrigemStudio: Sendable {
    var dados: Data
    var url: URL?
    var pecas: [Objeto.ID: PecaStudio]
    var imagens: Set<String>
    /// Já escolheu gravar no .studio3: os próximos ⌘S gravam direto.
    var confirmado = false
    var copiaNoLixo = false
}

extension Documento {
    struct GravacaoStudio {
        var dados: Data
        var pecas: [Objeto.ID: PecaStudio]
        /// Caminhos abertos (o .studio3 só tem contornos fechados).
        var abertos: Int
    }

    /// O .studio3 com o documento de agora e as novas origens dos objetos.
    func gravacaoStudio(_ origem: OrigemStudio) throws -> GravacaoStudio {
        let ordem = objetosEmOrdem.filter { !$0.textoVazio }
        // Um objeto de cima do arquivo volta intacto quando todos os que saíram dele estão aí, sem mudança.
        var contagem: [Int: Int] = [:], vivos: [Int: [Objeto]] = [:]
        for peca in origem.pecas.values { contagem[peca.caminho[0], default: 0] += 1 }
        for objeto in ordem {
            if let peca = origem.pecas[objeto.id] { vivos[peca.caminho[0], default: []].append(objeto) }
        }
        let intactos = Set(vivos.compactMap { topo, objetos in
            objetos.count == contagem[topo] && objetos.allSatisfy { Self.igual($0, origem.pecas[$0.id]!.objeto) } ? topo : nil
        })

        var itens: [StudioWriter.Item] = [], deQuem: [[Objeto]] = [], linhas: [StudioDocument.Color?] = []
        var feitos = Set<Int>(), abertos = 0
        for objeto in ordem {
            if let peca = origem.pecas[objeto.id], intactos.contains(peca.caminho[0]) {
                guard feitos.insert(peca.caminho[0]).inserted else { continue }
                itens.append(.original(peca.caminho[0]))
                deQuem.append(vivos[peca.caminho[0]] ?? [])
                linhas.append(nil)
                continue
            }
            let subcaminhos = objeto.nosAbsolutos
            abertos += subcaminhos.filter { !$0.fechado && $0.nos.count > 2 }.count
            let forma = try formaStudio(objeto, subcaminhos, origem)
            itens.append(.shape(forma))
            deQuem.append([objeto])
            linhas.append(forma.line)
        }

        let c = configMarcas
        let marcasStudio = StudioDocument.RegistrationMarks(on: marcas, left: c.esquerda, top: c.topo, right: c.direita,
                                                            bottom: c.baixo, length: c.comprimento, thickness: c.espessura)
        let (dados, indices) = try StudioWriter.writeWithMap(original: origem.dados, items: itens, thumbnail: miniaturaStudio(ordem),
                                                             marks: marcasStudio)
        var pecas: [Objeto.ID: PecaStudio] = [:]
        for (n, objetos) in deQuem.enumerated() {
            guard let topo = indices[n] else { continue }
            for objeto in objetos {
                if let linha = linhas[n] {
                    pecas[objeto.id] = PecaStudio(caminho: [topo], objeto: objeto, linha: linha)
                } else if let antiga = origem.pecas[objeto.id] {
                    pecas[objeto.id] = PecaStudio(caminho: [topo] + antiga.caminho.dropFirst(), objeto: objeto, linha: antiga.linha)
                }
            }
        }
        return GravacaoStudio(dados: dados, pecas: pecas, abertos: abertos)
    }

    /// O que o .studio3 guarda de um objeto: contorno, cor da linha, preenchimento ou imagem, "não corta".
    private static func igual(_ a: Objeto, _ b: Objeto) -> Bool {
        a.forma == b.forma && a.quadro == b.quadro && a.traco == b.traco && a.preenchimento == b.preenchimento
            && a.imagem == b.imagem && a.corta == b.corta
    }

    private func formaStudio(_ objeto: Objeto, _ subcaminhos: [Subcaminho], _ origem: OrigemStudio) throws -> StudioWriter.Shape {
        let peca = origem.pecas[objeto.id]
        let nos = subcaminhos.map { $0.nos.map { StudioDocument.Node(point: $0.ponto, controlIn: $0.entrada, controlOut: $0.saida) } }
        let linha = peca.map { $0.objeto.traco == objeto.traco } == true ? peca!.linha : Self.cor(objeto.traco)
        var fonte = peca?.caminho, copia = false, imagemNaPagina: CGAffineTransform?
        let preenchimento: StudioWriter.FillChange
        if let imagem = objeto.imagem {
            guard origem.imagens.contains(imagem.chave) else { throw ErroArquivo.imagemNovaNoStudio }
            if peca?.objeto.imagem?.chave != imagem.chave {
                // Cópia (⌘D, colar) de um objeto com essa imagem: o estilo e a imagem vêm dele.
                guard let modelo = origem.pecas.values.first(where: { $0.objeto.imagem?.chave == imagem.chave }) else {
                    throw ErroArquivo.imagemNovaNoStudio
                }
                (fonte, copia) = (modelo.caminho, true)
            }
            imagemNaPagina = imagem.transformacao.cg.concatenating(objeto.quadroParaPagina)
            preenchimento = .keep
        } else if let peca, peca.objeto.preenchimento == objeto.preenchimento, peca.objeto.imagem == nil {
            preenchimento = .keep
        } else {
            preenchimento = objeto.preenchimento.map { .color(Self.cor($0)) } ?? .none
        }
        return StudioWriter.Shape(subpaths: nos, line: linha, fill: preenchimento, imageToPage: imagemNaPagina,
                                  cuts: objeto.corta, source: fonte, copy: copia)
    }

    private static func cor(_ c: CMYK) -> StudioDocument.Color {
        let rgb = c.rgb255.map { Double($0) / 255 }
        return StudioDocument.Color(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
    }

    /// Miniatura como a do Studio: 512 × 512, fundo transparente, tudo enquadrado (também o que está fora da página).
    private func miniaturaStudio(_ objetos: [Objeto]) -> Data? {
        let caminhos = objetos.map { ($0, $0.caminho.cgPath) }
        var caixa = caminhos.reduce(CGRect.null) { $0.union($1.1.boundingBoxOfPath) }
        guard !caixa.isNull, max(caixa.width, caixa.height) > 0 else { return nil }
        caixa = caixa.insetBy(dx: -max(caixa.width, caixa.height) * 0.02, dy: -max(caixa.width, caixa.height) * 0.02)
        let lado = 512.0, escala = lado / max(caixa.width, caixa.height)
        guard let espaco = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGContext(data: nil, width: Int(lado), height: Int(lado), bitsPerComponent: 8, bytesPerRow: 0, space: espaco,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // y para baixo, como no documento.
        cg.translateBy(x: (lado - caixa.width * escala) / 2, y: lado - (lado - caixa.height * escala) / 2)
        cg.scaleBy(x: escala, y: -escala)
        cg.translateBy(x: -caixa.minX, y: -caixa.minY)
        for (objeto, caminho) in caminhos {
            if let cor = objeto.preenchimento {
                cg.addPath(caminho)
                cg.setFillColor(cor.cgCMYK)
                cg.fillPath(using: .evenOdd)
            }
            if let naForma = objeto.imagem, let pixels = imagem(naForma.chave) {
                cg.saveGState()
                cg.addPath(caminho)
                cg.clip(using: .evenOdd)
                cg.concatenate(naForma.transformacao.cg.concatenating(objeto.quadroParaPagina))
                cg.translateBy(x: 0, y: CGFloat(pixels.height))
                cg.scaleBy(x: 1, y: -1)
                cg.draw(pixels, in: CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
                cg.restoreGState()
            }
            cg.addPath(caminho)
            cg.setStrokeColor(objeto.traco.cgCMYK)
            cg.setLineWidth(1 / escala)
            cg.strokePath()
        }
        guard let imagem = cg.makeImage() else { return nil }
        let saida = NSMutableData()
        guard let destino = CGImageDestinationCreateWithData(saida, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destino, imagem, nil)
        return CGImageDestinationFinalize(destino) ? saida as Data : nil
    }
}

/// ⌘S num documento que veio do Studio e ainda não foi salvo como documento do Cutline.
@MainActor
enum SalvarStudio {
    static func salvar(_ doc: Documento, _ documento: NSDocument, janela: NSWindow) {
        #if DEBUG
        NSLog("CUTLINE_TESTE salvar studio3: url %@", String(describing: doc.studio?.url))
        #endif
        guard let origem = doc.studio, let url = origem.url else { return documento.save(nil) }
        if origem.confirmado { return gravar(doc, documento, janela: janela) }
        let gravavel = StudioWriter.canWrite(origem.dados)
        let alerta = NSAlert()
        alerta.messageText = String(localized: "Salvar “\(url.lastPathComponent)”")
        if gravavel {
            alerta.informativeText = String(localized: "Este documento veio do Silhouette Studio. Dá para gravar por cima do arquivo .studio3, que continua abrindo no Studio, ou guardar como documento do Cutline. Antes de gravar por cima, uma cópia do original vai para o Lixo.")
            alerta.addButton(withTitle: String(localized: "Gravar no .studio3"))
        } else {
            alerta.informativeText = String(localized: "Este arquivo do Silhouette Studio tem uma organização que o Cutline ainda não sabe regravar. Guarde como documento do Cutline.")
        }
        alerta.addButton(withTitle: String(localized: "Salvar como Cutline…"))
        alerta.addButton(withTitle: String(localized: "Cancelar"))
        alerta.beginSheetModal(for: janela) { resposta in
            switch (gravavel, resposta) {
            case (true, .alertFirstButtonReturn): gravar(doc, documento, janela: janela)
            case (true, .alertSecondButtonReturn), (false, .alertFirstButtonReturn): documento.saveAs(nil)
            default: break
            }
        }
        #if DEBUG
        Depuracao.responderAlertaParaTeste(alerta, janela: janela)
        #endif
    }

    static func gravar(_ doc: Documento, _ documento: NSDocument, janela: NSWindow) {
        guard var origem = doc.studio, let url = origem.url else { return }
        doc.terminarTexto()
        do {
            guard (try? Data(contentsOf: url)) == origem.dados else { throw ErroArquivo.studioMudou }
            let gravacao = try doc.gravacaoStudio(origem)
            if !origem.copiaNoLixo {
                var pasta = FileManager.default.temporaryDirectory
                #if DEBUG
                // Nos testes escondidos, a cópia fica ao lado do arquivo de teste, não no Lixo do owner.
                if Depuracao.escondido { pasta = url.deletingLastPathComponent() }
                #endif
                let copia = pasta.appending(path: url.deletingPathExtension().lastPathComponent + String(localized: " (antes do Cutline)") + ".studio3")
                try? FileManager.default.removeItem(at: copia)
                try origem.dados.write(to: copia)
                #if DEBUG
                if !Depuracao.escondido { try FileManager.default.trashItem(at: copia, resultingItemURL: nil) }
                #else
                try FileManager.default.trashItem(at: copia, resultingItemURL: nil)
                #endif
                origem.copiaNoLixo = true
            }
            try gravacao.dados.write(to: url, options: .atomic)
            origem.dados = gravacao.dados
            origem.pecas = gravacao.pecas
            origem.confirmado = true
            doc.studio = origem
            documento.updateChangeCount(.changeCleared)
            doc.aviso = gravacao.abertos > 0
                ? String(localized: "Gravado em “\(url.lastPathComponent)”. \(gravacao.abertos) caminhos abertos foram fechados (o .studio3 não tem caminho aberto).")
                : String(localized: "Gravado em “\(url.lastPathComponent)”.")
        } catch {
            #if DEBUG
            NSLog("CUTLINE_TESTE gravar studio3: %@", String(describing: error))
            #endif
            NSAlert(error: error).beginSheetModal(for: janela)
        }
    }
}
