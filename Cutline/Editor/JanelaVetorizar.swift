// Janela Vetorizar (como no protótipo): prévia da imagem com o contorno e os ajustes — margem, quantidade de
// nós, suavização (o quanto os nós se arredondam) e tolerância do fundo —, com só o contorno externo ou também
// os internos (os vazados da arte). Inserir põe a imagem (imprime, não corta) e o contorno em magenta
// (meio-corte) na camada ativa, agrupados (um clique pega os dois; ⇧⌘G separa). Uma imagem importada
// ou arrastada para a janela pergunta antes o que fazer: só a imagem, contorno externo ou internos.
import ImageIO
import SwiftUI

struct ImagemParaVetorizar: Identifiable {
    let id = UUID()
    let nome: String
    let dados: Data
    let imagem: CGImage
    /// Importada ou arrastada: pergunta antes o que fazer (a ferramenta Vetorizar vai direto aos ajustes).
    var perguntar = false
    /// Onde foi solta, em mm da página: a imagem entra centrada aí (senão, a 20 mm do canto).
    var centro: CGPoint?

    var proporcao: Double { Double(imagem.height) / Double(max(imagem.width, 1)) }

    /// 60 mm de largura, menos se a altura não couber na página (o tamanho se acerta depois, na tela).
    var larguraInicial: Double { min(ParametrosVetorizacao().largura, (Documento.pagina.height - 40) / proporcao) }

    /// Onde a imagem fica na página com essa largura.
    func quadro(largura: Double) -> CGRect {
        let tamanho = CGSize(width: largura, height: largura * proporcao)
        let canto = centro.map { CGPoint(x: $0.x - tamanho.width / 2, y: $0.y - tamanho.height / 2) } ?? CGPoint(x: 20, y: 20)
        return CGRect(origin: canto, size: tamanho)
    }
}

struct JanelaVetorizar: View {
    let doc: Documento
    let origem: ImagemParaVetorizar
    @Environment(\.dismiss) private var fechar
    /// Primeiro a escolha (imagem importada ou arrastada), depois os ajustes.
    @State private var escolhendo: Bool
    @State private var parametros = ParametrosVetorizacao()
    @State private var resultado: ResultadoVetorizacao?
    @State private var pixels: Vetorizacao.Pixels?
    /// Prévias da escolha, com os ajustes de agora: só o externo e com os internos.
    @State private var previaExterno: [[CGPoint]]?
    @State private var previaInternos: [[CGPoint]]?

    init(doc: Documento, origem: ImagemParaVetorizar) {
        self.doc = doc
        self.origem = origem
        _escolhendo = State(initialValue: origem.perguntar)
    }

    var body: some View {
        Group {
            if escolhendo { escolha } else { ajustes }
        }
        .padding(22)
        .task {
            parametros.largura = origem.larguraInicial
            #if DEBUG
            if let ajustes = Depuracao.ajustesVetor { (parametros.nos, parametros.suavizacao) = ajustes }
            #endif
            pixels = Vetorizacao.pixels(origem.imagem)
            guard escolhendo else { return recalcular() }
            await calcularPrevias()
            #if DEBUG
            switch Depuracao.escolhaImagem {
            case "imagem": inserirSoImagem()
            case "externo": escolher(internos: false)
            case "internos": escolher(internos: true)
            case "internos-inserir":
                escolher(internos: true)
                try? await Task.sleep(for: .milliseconds(400))
                inserir()
            default: break
            }
            #endif
        }
        .task(id: parametros) {
            try? await Task.sleep(for: .milliseconds(60))
            recalcular()
        }
    }

    // MARK: Escolha

    private var escolha: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("O que fazer com “\(origem.nome)”?").font(.headline)
            HStack(alignment: .top, spacing: 12) {
                OpcaoImagem(titulo: "Só a imagem", detalhe: "Entra para imprimir, sem linha de corte.") {
                    previa([])
                } acao: { inserirSoImagem() }
                OpcaoImagem(titulo: "Contorno externo", detalhe: "Corta em volta da arte, com margem. O que está dentro dela é ignorado.",
                            padrao: true) {
                    previa(previaExterno)
                } acao: { escolher(internos: false) }
                OpcaoImagem(titulo: "Contornos internos também", detalhe: "Corta também os vazados da arte, como o miolo de um O. A margem os estreita; os pequenos somem.") {
                    previa(previaInternos)
                } acao: { escolher(internos: true) }
            }
            HStack {
                Spacer()
                Button("Cancelar") { fechar() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func escolher(internos: Bool) {
        parametros.internos = internos
        escolhendo = false
    }

    /// As duas prévias da escolha, fora da linha principal (a janela abre sem esperar).
    private func calcularPrevias() async {
        guard let pixels else { return }
        var externo = parametros, internos = parametros
        externo.internos = false
        internos.internos = true
        let (prmExterno, prmInternos) = (externo, internos)
        (previaExterno, previaInternos) = await Task.detached {
            (Vetorizacao.vetorizar(pixels, prmExterno).lacos, Vetorizacao.vetorizar(pixels, prmInternos).lacos)
        }.value
    }

    // MARK: Ajustes

    private var ajustes: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Vetorizar “\(origem.nome)”").font(.headline)
            HStack(alignment: .top, spacing: 18) {
                previa(resultado?.lacos)
                    .frame(width: 420, height: 360)
                    .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Contorno", selection: $parametros.internos) {
                        Text("Só o externo").tag(false)
                        Text("Externo e internos").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(parametros.internos
                         ? "Corta também os vazados da arte, como o miolo de um O. A margem os estreita; os pequenos somem." as LocalizedStringKey
                         : "Detecta só o formato externo — o que está dentro da arte é ignorado.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    controle("Margem", unidade: "mm", valor: $parametros.margem, faixa: 0...10, passo: 0.5)
                    controle("Quantidade de nós", unidade: "%", valor: $parametros.nos, faixa: 0...100, passo: 1)
                    controle("Suavização", unidade: "%", valor: $parametros.suavizacao, faixa: 0...100, passo: 1)
                    controle("Tolerância do fundo", unidade: "", valor: $parametros.tolerancia, faixa: 5...150, passo: 1)
                        .disabled(resultado?.transparente == true)
                    if let resultado {
                        Text(verbatim: [String(localized: "\(resultado.lacos.count) contornos"), String(localized: "\(resultado.pontos) nós"),
                                        resultado.transparente ? String(localized: "fundo transparente") : String(localized: "fundo sólido detectado")]
                            .joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 240)
            }
            HStack {
                if origem.perguntar {
                    Button("Voltar") {
                        escolhendo = true
                        Task { await calcularPrevias() }
                    }
                }
                Spacer()
                Button("Cancelar") { fechar() }
                    .keyboardShortcut(.cancelAction)
                Button("Inserir") { inserir() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(resultado?.lacos.isEmpty ?? true)
            }
        }
    }

    private func recalcular() {
        guard let pixels else { return }
        resultado = Vetorizacao.vetorizar(pixels, parametros)
    }

    private func previa(_ lacos: [[CGPoint]]?) -> PreviaVetorizacao {
        PreviaVetorizacao(imagem: origem.imagem, largura: parametros.largura, margem: parametros.margem,
                          suavizacao: parametros.suavizacao, lacos: lacos ?? [])
    }

    private func controle(_ titulo: LocalizedStringKey, unidade: String, valor: Binding<Double>, faixa: ClosedRange<Double>, passo: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(titulo)
                Spacer()
                TextField(titulo, value: valor, format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                if !unidade.isEmpty { Text(unidade).foregroundStyle(.secondary) }
            }
            // Com muitos passos (as porcentagens), sem as marcas, que viram um tracejado: só arredonda.
            if (faixa.upperBound - faixa.lowerBound) / passo > 25 {
                Slider(value: Binding { valor.wrappedValue } set: { valor.wrappedValue = ($0 / passo).rounded() * passo }, in: faixa)
                    .labelsHidden()
            } else {
                Slider(value: valor, in: faixa, step: passo)
                    .labelsHidden()
            }
        }
    }

    // MARK: Inserir

    /// A imagem no quadro (imprime, não corta); `chave` é onde os dados dela ficam no documento.
    private func objetoImagem(_ quadro: CGRect, chave: String) -> Objeto {
        var imagem = doc.objetoNovo(.retangulo(raio: 0), quadro: quadro)
        imagem.imagem = ImagemNaForma(chave: chave, transformacao: Transformacao(
            CGAffineTransform(scaleX: 1 / Double(origem.imagem.width), y: 1 / Double(origem.imagem.height))))
        imagem.preenchimento = nil
        imagem.corta = false
        imagem.rotulo = origem.nome
        return imagem
    }

    private func inserir() {
        guard let resultado, !resultado.lacos.isEmpty else { return }
        let quadro = origem.quadro(largura: parametros.largura), chave = UUID().uuidString
        var contorno = doc.objetoNovo(.caminho([]), quadro: .zero)
        contorno.definirNos(resultado.lacos.map { laco in
            Subcaminho(nos: Vetorizacao.suavizar(laco.map { CGPoint(x: $0.x + quadro.minX, y: $0.y + quadro.minY) }, parametros.suavizacao),
                       fechado: true)
        })
        contorno.preenchimento = nil
        contorno.traco = CMYK(c: 0, m: 100, y: 0, k: 0)
        contorno.corta = true
        contorno.espessura = 0
        contorno.rotulo = String(localized: "Contorno \(origem.nome)")
        // Agrupados: a imagem e o contorno se movem e redimensionam juntos.
        var imagem = objetoImagem(quadro, chave: chave)
        let grupo = UUID()
        imagem.grupos = [grupo]
        contorno.grupos = [grupo]
        doc.inserirImportados([imagem, contorno], imagens: [chave: origem.dados])
        doc.ferramenta = .selecao
        fechar()
    }

    /// Só a imagem, sem linha de corte.
    private func inserirSoImagem() {
        let chave = UUID().uuidString
        doc.inserirImportados([objetoImagem(origem.quadro(largura: parametros.largura), chave: chave)], imagens: [chave: origem.dados])
        doc.ferramenta = .selecao
        fechar()
    }
}

/// A imagem com o contorno (em mm, a partir do canto da imagem) por cima, com as curvas como vão entrar.
private struct PreviaVetorizacao: View {
    let imagem: CGImage
    let largura: Double
    let margem: Double
    let suavizacao: Double
    let lacos: [[CGPoint]]

    var body: some View {
        Canvas { ctx, tamanho in
            let proporcao = Double(imagem.height) / Double(max(imagem.width, 1))
            let folga = margem + 2
            let total = CGSize(width: largura + 2 * folga, height: largura * proporcao + 2 * folga)
            let e = min(tamanho.width / total.width, tamanho.height / total.height)
            let origemX = (tamanho.width - total.width * e) / 2 + folga * e, origemY = (tamanho.height - total.height * e) / 2 + folga * e
            ctx.draw(Image(decorative: imagem, scale: 1),
                     in: CGRect(x: origemX, y: origemY, width: largura * e, height: largura * proporcao * e))
            let contorno = Objeto.caminho(lacos.map { laco in
                Subcaminho(nos: Vetorizacao.suavizar(laco.map { CGPoint(x: origemX + $0.x * e, y: origemY + $0.y * e) }, suavizacao))
            }, em: CGRect(x: 0, y: 0, width: 1, height: 1))
            ctx.stroke(contorno, with: .color(Color(red: 0.89, green: 0.29, blue: 0.29)), lineWidth: 1.5)
        }
    }
}

/// Uma das escolhas para a imagem importada: a prévia do resultado, o nome e o que faz.
private struct OpcaoImagem<Previa: View>: View {
    let titulo: LocalizedStringKey
    let detalhe: LocalizedStringKey
    /// Escolhida com Return (destacada).
    var padrao = false
    @ViewBuilder let previa: Previa
    let acao: () -> Void
    @State private var sobre = false

    var body: some View {
        Button(action: acao) {
            VStack(alignment: .leading, spacing: 8) {
                previa
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                    .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                Text(titulo)
                    .font(.body.weight(.semibold))
                Text(detalhe)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(width: 210, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(.quaternary.opacity(sobre ? 0.9 : 0.4), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(padrao ? Color.accentColor : .clear, lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(padrao ? .defaultAction : nil)
        .onHover { sobre = $0 }
    }
}

extension ImagemParaVetorizar {
    /// PNG, JPEG, HEIC, TIFF… (o que o ImageIO abre).
    init?(url: URL) {
        guard let dados = try? Data(contentsOf: url), let fonte = CGImageSourceCreateWithData(dados as CFData, nil),
              let imagem = CGImageSourceCreateImageAtIndex(fonte, 0, nil) else { return nil }
        self.init(nome: url.deletingPathExtension().lastPathComponent, dados: dados, imagem: imagem)
    }
}
