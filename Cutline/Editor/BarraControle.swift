// Barra de controle: faixa sob a toolbar e acima das abas (acessório da barra de título), como a barra de
// ajustes do Silhouette Studio e a de controle do Illustrator.
import AppKit
import SwiftUI

/// Zoom e posição da página. Fica num objeto observável porque a barra de controle mora fora da
/// hierarquia da janela (no acessório da barra de título) e também mexe no zoom.
@Observable
final class ControleVista {
    var vista = Vista()
    /// Área da tela sem as peças flutuantes, onde a página se ajusta.
    var areaLivre = CGRect.zero

    func ajustar() { vista.ajustar(em: areaLivre) }

    func zoom(_ fator: Double) { definirZoom(vista.zoom * fator) }

    func definirZoom(_ zoom: Double) {
        vista.ampliar(para: zoom, ancora: CGPoint(x: areaLivre.midX, y: areaLivre.midY))
    }
}

extension FocusedValues {
    /// Para os comandos de zoom do menu Visualizar.
    @Entry var controleVista: ControleVista?
}

/// Desfazer/refazer e zoom fixos; nome, traço (estilo e espessura), posição e tamanho (ponto de referência,
/// X/Y/L/A em mm, cadeado), parâmetros da forma e alinhamentos da seleção (um objeto: à folha; vários: à
/// seleção) — sem seleção, o traço é o dos próximos objetos; à direita snap, réguas e marcas do Print & Cut.
struct BarraControle: View {
    @Bindable var doc: Documento
    let controle: ControleVista
    /// Ponto de referência do X/Y e de onde o tamanho cresce (0, 0,5 ou 1 em cada eixo).
    @AppStorage("referenciaX") private var referenciaX = 0.0
    @AppStorage("referenciaY") private var referenciaY = 0.0
    @AppStorage("travaProporcao") private var travaProporcao = false
    @AppStorage("reguas") private var reguasLigadas = true
    @AppStorage("snap") private var snapLigado = true

    static let altura = 32.0

    /// Para colocar a barra entre a toolbar e as abas (o SwiftUI não tem acessórios da barra de título).
    static func instalar(em janela: NSWindow, doc: Documento, controle: ControleVista) {
        let id = NSUserInterfaceItemIdentifier("barraControle")
        guard !janela.titlebarAccessoryViewControllers.contains(where: { $0.identifier == id }) else { return }
        let hospedeira = NSHostingView(rootView: BarraControle(doc: doc, controle: controle))
        hospedeira.sizingOptions = []
        hospedeira.frame.size = CGSize(width: janela.frame.width, height: altura)
        let acessorio = NSTitlebarAccessoryViewController()
        acessorio.identifier = id
        acessorio.view = hospedeira
        acessorio.layoutAttribute = .bottom
        acessorio.isHidden = !(UserDefaults.standard.object(forKey: "barraControleVisivel") as? Bool ?? true)
        janela.addTitlebarAccessoryViewController(acessorio)
    }

    /// Janela › Barra de controle.
    static func mostrar(_ visivel: Bool, em janela: NSWindow) {
        janela.titlebarAccessoryViewControllers.first { $0.identifier == NSUserInterfaceItemIdentifier("barraControle") }?
            .isHidden = !visivel
    }

    var body: some View {
        HStack(spacing: 8) {
            historicoEZoom
            separador
            // Sem espaço, os alinhamentos viram um menu (como no Illustrator); numa janela muito estreita, a
            // parte da seleção rola de lado em vez de espremer os campos.
            ViewThatFits(in: .horizontal) {
                selecao(alinharEmMenu: false)
                selecao(alinharEmMenu: true)
                ScrollView(.horizontal, showsIndicators: false) { selecao(alinharEmMenu: true) }
            }
            separador
            ajudas
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: Self.altura)
        // Mais escura que a toolbar (como no rascunho e no Final Cut), com um fio em cima e embaixo.
        .background(Self.fundo)
        .overlay(alignment: .top) { Self.fio.frame(height: 1) }
        .overlay(alignment: .bottom) { Self.fio.frame(height: 1) }
    }

    /// Escuro: #1D1D1D do rascunho; claro: um cinza perto do da tela.
    private static let fundo = Color(nsColor: NSColor(name: nil) { aparencia in
        aparencia.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.114, alpha: 1) : NSColor(white: 0.9, alpha: 1)
    })
    private static let fio = Color(nsColor: NSColor(name: nil) { aparencia in
        aparencia.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : NSColor(white: 0.78, alpha: 1)
    })

    private var separador: some View { Divider().frame(height: 16) }

    // MARK: Fixos

    private var historicoEZoom: some View {
        HStack(spacing: 2) {
            acao("Desfazer (⌘Z)", .desfazer) { doc.desfazer() }
                .disabled(!doc.podeDesfazer)
            acao("Refazer (⇧⌘Z)", .refazer) { doc.refazer() }
                .disabled(!doc.podeRefazer)
            separador.padding(.horizontal, 6)
            acao("Reduzir (⌘−)", .reduzir) { controle.zoom(1 / 1.25) }
            Menu {
                ForEach([0.5, 1, 2, 4], id: \.self) { z in
                    Button("\(Int(z * 100))%") { controle.definirZoom(z) }
                }
                Divider()
                Button("Ajustar à janela") { controle.ajustar() }
            } label: {
                Text("\(Int((controle.vista.zoom * 100).rounded()))%").monospacedDigit()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(minWidth: 44)
            .help("Zoom")
            acao("Ampliar (⌘+)", .ampliar) { controle.zoom(1.25) }
            acao("Ajustar à janela (⌘0)", .ajustarJanela) { controle.ajustar() }
        }
    }

    private var ajudas: some View {
        HStack(spacing: 2) {
            alternar("Snap: encaixar nos pontos, na página e nas guias (⌘;)", .snap, ligado: snapLigado) {
                snapLigado.toggle()
            }
            alternar("Réguas e guias (⌘R) — arraste da régua para criar uma guia", .reguas, ligado: reguasLigadas) {
                reguasLigadas.toggle()
            }
            alternar("Marcas de registro (Print & Cut): imprima com elas e a máquina as lê antes de cortar",
                     .marcas, ligado: doc.marcas) { doc.alternarMarcas() }
        }
    }

    private func acao(_ dica: LocalizedStringKey, _ icone: ImageResource, executar: @escaping () -> Void) -> some View {
        Button(action: executar) {
            Image(icone).resizable().frame(width: 18, height: 18).frame(width: 28, height: 26)
        }
        .buttonStyle(.borderless)
        .help(dica)
    }

    /// Botão que liga e desliga: aceso na cor de destaque, como o cadeado de proporção.
    private func alternar(_ dica: LocalizedStringKey, _ icone: ImageResource, ligado: Bool, mudar: @escaping () -> Void) -> some View {
        Button(action: mudar) {
            Image(icone)
                .resizable()
                .frame(width: 18, height: 18)
                .foregroundStyle(ligado ? Color.accentColor : .secondary)
                .frame(width: 28, height: 26)
                .background(ligado ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(dica)
    }

    // MARK: Seleção

    private func selecao(alinharEmMenu: Bool) -> some View {
        HStack(spacing: 8) {
            let selecionados = doc.selecionados
            if selecionados.isEmpty {
                Text("Nada selecionado").foregroundStyle(.secondary)
            } else {
                Group {
                    if selecionados.count == 1 { Text(selecionados[0].nome) } else if doc.selecaoEhUmGrupo { Text("Grupo") } else {
                        Text("\(selecionados.count) objetos")
                    }
                }
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            traco
            separador
            if let caixa = doc.caixaSelecao {
                GradeReferencia(x: $referenciaX, y: $referenciaY)
                posicaoETamanho(caixa)
                if let objeto = selecionados.first, selecionados.count == 1 {
                    parametros(objeto)
                    if objeto.forma.parametrica {
                        Button("→ Caminho") { doc.converterEmCaminho() }
                            .controlSize(.small)
                            .help("Converter em caminho para editar os pontos (seleção direta)")
                    }
                }
            } else {
                Text("Base A4 · 210 × 297 mm").foregroundStyle(.secondary)
            }
            separador
            // Um grupo alinha à folha, como um objeto só.
            let pecas = doc.pecasSelecionadas.count
            if alinharEmMenu { menuAlinhar(pecas) } else { alinhamentos(pecas) }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func menuAlinhar(_ quantos: Int) -> some View {
        Menu {
            ForEach(ModoAlinhar.allCases) { modo in
                Button { doc.alinhar(modo) } label: { Label("Alinhar \(modo.nome)", image: modo.icone) }
            }
        } label: {
            Label("Alinhar", image: ModoAlinhar.centroH.icone)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(quantos == 0)
        .help(quantos > 1 ? "Alinhar à seleção" as LocalizedStringKey : "Alinhar à folha")
    }

    /// Estilo (contínua ou picotada) e espessura do traço, como na barra do Studio.
    private var traco: some View {
        let estilo = doc.estiloAtual
        let espessura = doc.selecionados.first?.espessura ?? doc.espessuraPadrao
        return HStack(spacing: 6) {
            Menu {
                Picker("Estilo", selection: Binding(get: { estilo.linha }, set: { nova in doc.definirEstilo { $0.linha = nova } })) {
                    ForEach(EstiloLinha.allCases) { e in
                        Label { Text(e.nome) } icon: { Image(nsImage: Icones.linha(e)) }.tag(e)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Image(nsImage: Icones.linha(estilo.linha, largura: 44))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .help(estilo.linha == .continua ? "Traço contínuo" as LocalizedStringKey : "Traço picotado: o corte é tracejado")
            campo(nil, espessura, minimo: 0, maximo: 100, unidade: "pt", largura: 34) { doc.definirEspessura($0) }
                .help(espessura > 0 ? "Espessura: este traço também será impresso" as LocalizedStringKey
                      : "Espessura: 0 pt aparece na tela, não imprime e indica o corte")
        }
    }

    private func posicaoETamanho(_ caixa: CGRect) -> some View {
        HStack(spacing: 6) {
            campo("X", caixa.minX + caixa.width * referenciaX, unidade: "") { v in
                doc.ajustarSelecao(para: caixa.offsetBy(dx: v - (caixa.minX + caixa.width * referenciaX), dy: 0))
            }
            campo("Y", caixa.minY + caixa.height * referenciaY, unidade: "") { v in
                doc.ajustarSelecao(para: caixa.offsetBy(dx: 0, dy: v - (caixa.minY + caixa.height * referenciaY)))
            }
            campo("L", caixa.width, minimo: 0.1, unidade: "") { v in
                redimensionar(caixa, largura: v, altura: travaProporcao ? caixa.height * v / max(caixa.width, 0.001) : caixa.height)
            }
            Button {
                travaProporcao.toggle()
            } label: {
                Image(.proporcao)
                    .resizable()
                    .frame(width: 17, height: 17)
                    .foregroundStyle(travaProporcao ? Color.accentColor : .secondary)
                    .frame(width: 24, height: 24)
                    .background(travaProporcao ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(travaProporcao ? "Proporção travada" as LocalizedStringKey : "Manter proporção")
            campo("A", caixa.height, minimo: 0.1, unidade: "") { v in
                redimensionar(caixa, largura: travaProporcao ? caixa.width * v / max(caixa.height, 0.001) : caixa.width, altura: v)
            }
            Text("mm").foregroundStyle(.secondary)
        }
    }

    private func alinhamentos(_ quantos: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(ModoAlinhar.allCases) { modo in
                Button {
                    doc.alinhar(modo)
                } label: {
                    Image(modo.icone)
                        .resizable()
                        .frame(width: 18, height: 18)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(quantos == 0)
                .opacity(quantos == 0 ? 0.35 : 1)
                .help(quantos == 1 ? "Alinhar \(modo.nome) da folha" as LocalizedStringKey
                      : quantos > 1 ? "Alinhar \(modo.nome) da seleção" : "Alinhar \(modo.nome)")
            }
        }
    }

    /// Novo tamanho preso ao ponto de referência.
    private func redimensionar(_ caixa: CGRect, largura: Double, altura: Double) {
        let l = max(largura, 0.1), a = max(altura, 0.1)
        doc.ajustarSelecao(para: CGRect(x: caixa.minX + (caixa.width - l) * referenciaX, y: caixa.minY + (caixa.height - a) * referenciaY,
                                        width: l, height: a))
    }

    @ViewBuilder
    private func parametros(_ objeto: Objeto) -> some View {
        switch objeto.forma {
        case .retangulo(let raio):
            campo("Raio", raio, minimo: 0) { v in doc.alterarSelecao { $0.forma = .retangulo(raio: v) } }
        case .estrela(let pontas, let interno):
            campo("Pontas", Double(pontas), minimo: 3, maximo: 40, unidade: "") { v in
                doc.alterarSelecao { $0.forma = .estrela(pontas: Int(v.rounded()), raioInterno: interno) }
            }
            campo("Raio int.", interno * 100, minimo: 5, maximo: 100, unidade: "%") { v in
                doc.alterarSelecao { $0.forma = .estrela(pontas: pontas, raioInterno: v / 100) }
            }
        case .texto:
            CamposTexto(doc: doc)
        case .caminho(let subs):
            let pontos = subs.reduce(0) { $0 + $1.nos.count }, aberto = subs.contains { !$0.fechado }
            Text(aberto ? "\(pontos) pontos · aberto" as LocalizedStringKey : "\(pontos) pontos · fechado").foregroundStyle(.secondary)
            if aberto {
                Button("Fechar") { doc.fecharCaminhos() }
                    .controlSize(.small)
            }
        case .elipse:
            EmptyView()
        }
    }

    /// Campo numérico: aplica ao confirmar (Enter ou sair do campo), como no Illustrator.
    private func campo(_ rotulo: LocalizedStringKey?, _ valor: Double, minimo: Double = -10_000, maximo: Double = 10_000,
                       unidade: String = "mm", largura: Double = 42, aplicar: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 4) {
            if let rotulo { Text(rotulo).foregroundStyle(.secondary).fixedSize() }
            // O campo confirma o valor de novo ao perder o foco: só aplica (e registra o desfazer) se mudou.
            TextField(rotulo ?? "", value: Binding(get: { valor }, set: { novo in
                let v = min(max(novo, minimo), maximo)
                if v != valor { aplicar(v) }
            }),
                      format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: largura)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            if !unidade.isEmpty { Text(unidade).foregroundStyle(.secondary).fixedSize() }
        }
    }
}

/// Fonte, estilo e corpo (o texto em si se digita na tela; o resto fica no painel Caractere). Digitando, valem
/// para as letras selecionadas, como no painel.
private struct CamposTexto: View {
    @Bindable var doc: Documento

    var body: some View {
        let estilo = doc.estiloDoTexto
        HStack(spacing: 8) {
            BotaoFonte(doc: doc, estilo: estilo, compacto: true)
                .frame(width: 150)
            MenuEstilo(doc: doc, estilo: estilo, compacto: true)
                .frame(width: 110)
            HStack(spacing: 5) {
                TextField("Corpo", value: Binding(get: { estilo.tamanho }, set: { novo in
                    let v = min(max(novo, 1), 1000)
                    if v != estilo.tamanho { doc.mudarEstilo { $0.tamanho = v } }
                }), format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(width: 40)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .onSubmit { doc.devolverFocoAoTexto() }
                Text("pt").foregroundStyle(.secondary).fixedSize()
            }
        }
    }
}

/// Ponto de referência 3 × 3 (como no Illustrator): de onde valem o X/Y e para onde o tamanho cresce.
private struct GradeReferencia: View {
    @Binding var x: Double
    @Binding var y: Double

    var body: some View {
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            ForEach([0.0, 0.5, 1.0], id: \.self) { fy in
                GridRow {
                    ForEach([0.0, 0.5, 1.0], id: \.self) { fx in
                        let ativo = x == fx && y == fy
                        Rectangle()
                            .fill(ativo ? Color.accentColor : Color.secondary.opacity(0.35))
                            .frame(width: 5, height: 5)
                            .padding(1)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                x = fx
                                y = fy
                            }
                    }
                }
            }
        }
        .help("Ponto de referência")
    }
}
