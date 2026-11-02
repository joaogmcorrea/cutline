// Só na compilação de depuração: ajuda a conferir a interface sem permissão de gravação de tela.
//   open --env CUTLINE_FOTO=/caminho/janela.png --env CUTLINE_DEMO=1 Cutline.app
//   CUTLINE_ENVIO=1 abre a janela Enviar; CUTLINE_SIMULAR=1 usa a máquina simulada;
//   CUTLINE_TESTE_ALTERAR=1 altera o documento sozinho; CUTLINE_TESTE_SALVAR=/x.cutline salva uma cópia;
//   CUTLINE_TESTE_IMPORTAR=/x.pdf importa; CUTLINE_TESTE_PATHFINDER=dividir…; CUTLINE_FECHADAS=Cor,Traço;
//   CUTLINE_TESTE_SOLTAR=/x.png faz o mesmo que soltar o arquivo no meio da janela;
//   CUTLINE_TESTE_IMAGEM=imagem|externo|internos|internos-inserir escolhe na pergunta da imagem importada;
//   CUTLINE_TESTE_VETOR=nós,suavização (0–100) muda os ajustes do Vetorizar;
//   CUTLINE_TESTE_ALCA=1|opcao|shift|shift+opcao arrasta o canto inferior direito da seleção (30 × 10 mm),
//   como o mouse, com esses modificadores;
//   CUTLINE_TESTE_SALVAR_STUDIO=gravar|cancelar (num .studio3, depois das teclas) pede ⌘S pela cadeia de resposta
//   da janela e responde à pergunta 2,5 s depois (duas vezes com "gravar2": a 2ª grava direto);
//   CUTLINE_TESTE_TECLAS=cmd+a;cmd+g;clique:120,70;cmd+right… passa teclas (e cliques, em mm) pelo teclado da
//   tela, um a cada 0,3 s; CUTLINE_TESTE_CONTEXTO=/x.txt grava o menu do clique direito (da seleção de então);
//   CUTLINE_MARCAS=1 liga as marcas do Print & Cut; CUTLINE_TESTE_IMPRIMIR=/x.pdf grava a impressão em PDF;
//   CUTLINE_TESTE_ENVIAR=1 (com CUTLINE_SIMULAR) envia sozinho ao abrir a janela Enviar;
//   CUTLINE_TESTE_TESTECORTE=x,y (com CUTLINE_SIMULAR) envia o teste de corte em x,y mm ao abrir a janela Enviar;
//   CUTLINE_TESTE_IGNORAR_STUDIO=1 faz de conta que o Silhouette Studio está fechado;
//   CUTLINE_TESTE_BASE=mini_6x8 escolhe a base de corte ao abrir (valores do CuttingMat);
//   CUTLINE_TESTE_MARCAS=falha (com CUTLINE_SIMULAR) faz a leitura das marcas falhar;
//   CUTLINE_PAINEL_ABERTO=pathfinder abre um painel recolhido;
//   CUTLINE_TESTE_MENUS=/x.txt grava a barra de menus (títulos, atalhos, ✓ e desabilitados) num texto;
//   CUTLINE_TESTE_TEXTO=1|visivel|selecao|tipografia|trechos|estilo|novo (com CUTLINE_DEMO=2) abre a digitação na tela;
//   curvas|curvasDigitando converte o texto da demo em curvas (selecionado, ou pelo ⇧⌘O durante a digitação);
//   CUTLINE_TESTE_ORDEM=1 (com CUTLINE_ENVIO) leva a última cor do corte ao topo, como o arrastar
//   CUTLINE_TESTE_FONTE_DEMO=Família põe o texto da demo nessa família (fonte instalada com o app aberto)
//   (CUTLINE_TESTE_FAMILIA=Montserrat troca a família durante ela);
//   CUTLINE_TESTE_FONTES=1 abre a lista de fontes do painel Caractere.
//   CUTLINE_TESTE_RELATORIO=problema|recurso abre a janela do relatório; CUTLINE_TESTE_RELATORIO_TEXTO=1 preenche
//   um exemplo; CUTLINE_TESTE_RELATORIO_SAIDA=/x.txt grava o endereço do GitHub e o texto, em vez de abrir.
//   CUTLINE_ESCONDIDO=1 (com `open -g`) testa sem aparecer: as janelas ficam atrás da mesa.
#if DEBUG
import AppKit
import CutlineKit
import SwiftUI

enum Depuracao {
    /// CUTLINE_ESCONDIDO=1, aberto com `open -g` (sem tomar o foco): as janelas do teste ficam abaixo da mesa e
    /// fora da área das telas (as folhas, como Vetorizar e Enviar, acompanham a janela), invisíveis para quem
    /// está usando o Mac — e o `screencapture -l` ainda as fotografa. Sem App Nap, que atrasaria o app escondido.
    /// Popovers e menus precisam da janela ativa: esses testes ainda aparecem.
    static func esconderJanelas() {
        guard ProcessInfo.processInfo.environment["CUTLINE_ESCONDIDO"] != nil else { return }
        atividade = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "teste escondido")
        let nivel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        let esconder = {
            MainActor.assumeIsolated {
                for janela in NSApp?.windows ?? [] where janela.sheetParent == nil && janela.parent == nil {
                    if janela.level != nivel { janela.level = nivel }
                    if janela.frame.minX > -20000 { janela.setFrameOrigin(NSPoint(x: -30000, y: janela.frame.minY)) }
                }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { _ in esconder() }
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in esconder() }
    }

    private static var atividade: NSObjectProtocol?

    /// CUTLINE_TESTE_RELATORIO=problema|recurso abre a janela do relatório ao iniciar.
    static var abrirRelatorio: TipoRelatorio? {
        ProcessInfo.processInfo.environment["CUTLINE_TESTE_RELATORIO"].flatMap(TipoRelatorio.init(rawValue:))
    }

    /// CUTLINE_TESTE_RELATORIO_TEXTO=1 preenche a janela com um exemplo; com CUTLINE_TESTE_RELATORIO_SAIDA, ainda
    /// "abre no GitHub" sozinha (o endereço vai para o arquivo, ver `gravarRelatorio`).
    static func preencherRelatorio(_ relatorio: inout Relatorio, enviar: @escaping () -> Void) {
        let ambiente = ProcessInfo.processInfo.environment
        guard ambiente["CUTLINE_TESTE_RELATORIO_TEXTO"] != nil else { return }
        relatorio.resumo = "A estrela sai cortada pela metade"
        relatorio.descricao = "Mandei cortar a cartela de teste e a máquina parou no meio da estrela."
        if relatorio.tipo == .problema {
            relatorio.detalhe = "1. Arquivo › Novo\n2. Desenhar uma estrela de 40 mm\n3. Enviar (⌘E) › Cortar"
            relatorio.esperado = "A estrela inteira cortada."
        }
        guard ambiente["CUTLINE_TESTE_RELATORIO_SAIDA"] != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { enviar() }
    }

    /// CUTLINE_TESTE_RELATORIO_SAIDA=/x.txt: o endereço da issue e o texto vão para o arquivo, sem abrir o navegador.
    static func gravarRelatorio(url: URL, texto: String) -> Bool {
        guard let caminho = ProcessInfo.processInfo.environment["CUTLINE_TESTE_RELATORIO_SAIDA"] else { return false }
        try? (url.absoluteString + "\n\n" + texto).write(toFile: caminho, atomically: true, encoding: .utf8)
        return true
    }

    /// CUTLINE_ENVIO=1 abre a janela Enviar ao iniciar (com CUTLINE_SIMULAR=1, sem máquina).
    static var abrirEnvio: Bool { ProcessInfo.processInfo.environment["CUTLINE_ENVIO"] != nil }

    /// CUTLINE_TESTE_MARCAS=falha com CUTLINE_SIMULAR: a máquina simulada "não acha" as marcas do Print & Cut.
    static var marcasFalham: Bool {
        let ambiente = ProcessInfo.processInfo.environment
        return ambiente["CUTLINE_TESTE_MARCAS"] == "falha" && ambiente["CUTLINE_SIMULAR"] != nil
    }

    /// CUTLINE_TESTE_ENVIAR=1 com CUTLINE_SIMULAR: a janela Enviar envia sozinha (transcrição em ~/Library/Logs/Cutline).
    static var enviarParaTeste: Bool {
        let ambiente = ProcessInfo.processInfo.environment
        return ambiente["CUTLINE_TESTE_ENVIAR"] != nil && ambiente["CUTLINE_SIMULAR"] != nil
    }

    /// CUTLINE_TESTE_TESTECORTE=x,y com CUTLINE_SIMULAR: a janela Enviar põe o teste de corte em x,y mm e o envia.
    static var testeDeCorte: CGPoint? {
        let ambiente = ProcessInfo.processInfo.environment
        guard ambiente["CUTLINE_SIMULAR"] != nil, let valor = ambiente["CUTLINE_TESTE_TESTECORTE"] else { return nil }
        let n = valor.split(separator: ",").compactMap { Double($0) }
        return n.count == 2 ? CGPoint(x: n[0], y: n[1]) : nil
    }

    /// CUTLINE_TESTE_ALTERAR=1 move o primeiro objeto 1 mm logo depois de abrir (registrando o desfazer),
    /// para testar o documento alterado (pedir para salvar, salvamento automático) sem mexer no mouse.
    static func alterarParaTeste(_ doc: Documento) {
        // CUTLINE_TESTE_BASE=mini_6x8 (valor do CuttingMat) escolhe a base no documento (sem lembrar no app,
        // para não mudar a escolha do owner nos documentos novos).
        if let base = ProcessInfo.processInfo.environment["CUTLINE_TESTE_BASE"].flatMap(CuttingMat.init(rawValue:)) {
            doc.comBase = base != .none
            doc.baseDeCorte = base
        }
        guard ProcessInfo.processInfo.environment["CUTLINE_TESTE_ALTERAR"] != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard !doc.objetos.isEmpty else { return }
            doc.registrar()
            doc.objetos[0].quadro.origin.x += 1
        }
    }

    /// CUTLINE_TESTE_SALVAR=/caminho.cutline salva uma cópia do documento ali logo depois de abrir
    /// (o mesmo caminho do Arquivo › Salvar como…), para conferir a gravação e a leitura sem o painel.
    static func salvarParaTeste(_ janela: NSWindow?) {
        guard let caminho = ProcessInfo.processInfo.environment["CUTLINE_TESTE_SALVAR"] else { return }
        // CUTLINE_TESTE_ESPERA=8 salva depois de 8 s (depois de uma sequência de CUTLINE_TESTE_TECLAS).
        let espera = Double(ProcessInfo.processInfo.environment["CUTLINE_TESTE_ESPERA"] ?? "") ?? 3
        DispatchQueue.main.asyncAfter(deadline: .now() + espera) {
            guard let documento = janela?.windowController?.document as? NSDocument else { return }
            documento.save(to: URL(fileURLWithPath: caminho), ofType: "io.github.joaogmcorrea.cutline.documento",
                           for: .saveToOperation) { erro in
                print(erro.map { "falhou: \($0.localizedDescription)" } ?? "salvo em \(caminho)")
            }
        }
    }

    /// CUTLINE_PAINEL_ABERTO=pathfinder abre esse painel recolhido ao lado da faixa de ícones.
    static var painelAberto: Painel? {
        ProcessInfo.processInfo.environment["CUTLINE_PAINEL_ABERTO"].flatMap(Painel.init(rawValue:))
    }

    /// CUTLINE_FECHADAS=Cor,Traço abre o painel lateral com essas seções recolhidas.
    static var secoesFechadas: Set<String> {
        Set((ProcessInfo.processInfo.environment["CUTLINE_FECHADAS"] ?? "").split(separator: ",").map(String.init))
    }

    /// CUTLINE_TESTE_PATHFINDER=unir|subtrairFrente|intersecao|excluir|dividir|subtrairTras desenha um
    /// retângulo e uma elipse sobrepostos e aplica a operação (para conferir o resultado sem o mouse).
    static func pathfinderParaTeste(_ doc: Documento) {
        guard let nome = ProcessInfo.processInfo.environment["CUTLINE_TESTE_PATHFINDER"],
              let operacao = OperacaoPathfinder(rawValue: nome) else { return }
        let retangulo = doc.objetoNovo(.retangulo(raio: 8), quadro: CGRect(x: 30, y: 40, width: 80, height: 70))
        var elipse = doc.objetoNovo(.elipse, quadro: CGRect(x: 70, y: 80, width: 90, height: 70))
        elipse.traco = CMYK(c: 100, m: 50, y: 0, k: 0)
        elipse.preenchimento = CMYK(c: 20, m: 0, y: 0, k: 0)
        doc.objetos = [retangulo, elipse]
        doc.selecao = [retangulo.id, elipse.id]
        doc.aviso = doc.pathfinder(operacao) ?? "\(operacao.nome): \(doc.objetos.count) objeto(s)"
    }

    /// CUTLINE_TESTE_IMPORTAR=/arquivo.pdf|.ai|.png faz o mesmo que Arquivo › Importar… com esse arquivo.
    static var importarParaTeste: URL? {
        ProcessInfo.processInfo.environment["CUTLINE_TESTE_IMPORTAR"].map { URL(fileURLWithPath: $0) }
    }

    /// CUTLINE_TESTE_SOLTAR=/arquivo faz o mesmo que soltar o arquivo no meio da janela.
    static var soltarParaTeste: URL? {
        ProcessInfo.processInfo.environment["CUTLINE_TESTE_SOLTAR"].map { URL(fileURLWithPath: $0) }
    }

    /// CUTLINE_TESTE_IMAGEM=imagem|externo|internos|internos-inserir: a escolha na pergunta da imagem importada.
    static var escolhaImagem: String? { ProcessInfo.processInfo.environment["CUTLINE_TESTE_IMAGEM"] }

    /// CUTLINE_TESTE_VETOR=nós,suavização (de 0 a 100): os ajustes do Vetorizar ao abrir.
    static var ajustesVetor: (nos: Double, suavizacao: Double)? {
        let valores = (ProcessInfo.processInfo.environment["CUTLINE_TESTE_VETOR"] ?? "").split(separator: ",").compactMap { Double($0) }
        return valores.count == 2 ? (valores[0], valores[1]) : nil
    }

    /// CUTLINE_TESTE_ALCA=1: assim que houver seleção, arrasta a alça do canto inferior direito 30 mm para a
    /// direita e 10 mm para baixo, pelo mesmo caminho do mouse (Tela.arrastarAlcaParaTeste).
    static var arrastarAlca: Bool { ProcessInfo.processInfo.environment["CUTLINE_TESTE_ALCA"] != nil }

    static var escondido: Bool { ProcessInfo.processInfo.environment["CUTLINE_ESCONDIDO"] != nil }

    /// CUTLINE_TESTE_SALVAR_STUDIO: a resposta à pergunta do ⌘S de um documento que veio do Studio.
    static var salvarStudio: String? { ProcessInfo.processInfo.environment["CUTLINE_TESTE_SALVAR_STUDIO"] }

    static func responderAlertaParaTeste(_ alerta: NSAlert, janela: NSWindow) {
        guard let resposta = salvarStudio else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            let codigo: NSApplication.ModalResponse = resposta.hasPrefix("gravar") ? .alertFirstButtonReturn : .alertThirdButtonReturn
            janela.endSheet(alerta.window, returnCode: codigo)
        }
    }

    /// Os modificadores que a tela lê nos testes de alça e de teclas (o ⇧ real do Mac não entra).
    static var modificadoresDeTeste: NSEvent.ModifierFlags? {
        let ambiente = ProcessInfo.processInfo.environment
        guard let alca = ambiente["CUTLINE_TESTE_ALCA"] ?? ambiente["CUTLINE_TESTE_TECLAS"].map({ _ in "" }) else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if alca.contains("shift") { flags.insert(.shift) }
        if alca.contains("opcao") { flags.insert(.option) }
        return flags
    }

    /// Nos testes escondidos, copiar e colar usam uma área de transferência só do Cutline (a do owner fica intacta).
    static let areaDeTeste: NSPasteboard? = ProcessInfo.processInfo.environment["CUTLINE_ESCONDIDO"] != nil
        ? NSPasteboard(name: NSPasteboard.Name("io.github.joaogmcorrea.cutline.teste")) : nil

    /// CUTLINE_TESTE_TECLAS=cmd+a;cmd+g;clique:120,70;… (separados por ";").
    static var teclasDeTeste: [String] {
        (ProcessInfo.processInfo.environment["CUTLINE_TESTE_TECLAS"] ?? "").split(separator: ";").map(String.init)
    }

    /// "cmd+shift+]", "cmd+right", "esc"… como um keyDown nesta janela.
    static func tecla(_ texto: String, janela: NSWindow) -> NSEvent? {
        var partes = texto.split(separator: "+").map(String.init)
        guard let nome = partes.popLast() else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if partes.contains("cmd") { flags.insert(.command) }
        if partes.contains("shift") { flags.insert(.shift) }
        if partes.contains("opt") { flags.insert(.option) }
        let seta = { (tecla: Int) in String(utf16CodeUnits: [unichar(tecla)], count: 1) }
        let teclas: [String: (UInt16, String, String)] = [
            "a": (0, "a", "A"), "c": (8, "c", "C"), "d": (2, "d", "D"), "g": (5, "g", "G"), "v": (9, "v", "V"), "x": (7, "x", "X"),
            "[": (33, "[", "{"), "]": (30, "]", "}"), "esc": (53, "\u{1b}", "\u{1b}"),
            "left": (123, seta(NSLeftArrowFunctionKey), seta(NSLeftArrowFunctionKey)),
            "right": (124, seta(NSRightArrowFunctionKey), seta(NSRightArrowFunctionKey)),
            "down": (125, seta(NSDownArrowFunctionKey), seta(NSDownArrowFunctionKey)),
            "up": (126, seta(NSUpArrowFunctionKey), seta(NSUpArrowFunctionKey)),
        ]
        guard let (codigo, simples, comShift) = teclas[nome] else { return nil }
        let caracteres = flags.contains(.shift) ? comShift : simples
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: janela.windowNumber, context: nil, characters: caracteres,
                                charactersIgnoringModifiers: caracteres, isARepeat: false, keyCode: codigo)
    }

    /// CUTLINE_TESTE_CONTEXTO=/x.txt: o menu do clique direito em texto (títulos, atalhos, desligados).
    static func gravarMenuContexto(_ doc: Documento) {
        guard let caminho = ProcessInfo.processInfo.environment["CUTLINE_TESTE_CONTEXTO"] else { return }
        func linhas(_ menu: NSMenu, _ nivel: Int) -> [String] {
            menu.items.flatMap { item -> [String] in
                guard !item.isSeparatorItem else { return [String(repeating: "  ", count: nivel) + "—"] }
                let atalho = item.keyEquivalent.isEmpty ? "" : " [\(item.keyEquivalentModifierMask.contains(.shift) ? "⇧" : "")"
                    + "\(item.keyEquivalentModifierMask.contains(.command) ? "⌘" : "")\(item.keyEquivalent.unicodeScalars.map { String(format: "%X", $0.value) }.joined())]"
                return [String(repeating: "  ", count: nivel) + item.title + atalho + (item.isEnabled ? "" : " (desligado)")]
                    + (item.submenu.map { linhas($0, nivel + 1) } ?? [])
            }
        }
        try? linhas(MenuContexto.criar(doc), 0).joined(separator: "\n").write(toFile: caminho, atomically: true, encoding: .utf8)
    }

    /// CUTLINE_MARCAS=1 liga as marcas do Print & Cut; CUTLINE_TESTE_IMPRIMIR=/caminho.pdf grava a impressão
    /// (o mesmo desenho do Arquivo › Imprimir…) num PDF, sem o painel.
    static func imprimirParaTeste(_ doc: Documento) {
        let ambiente = ProcessInfo.processInfo.environment
        if ambiente["CUTLINE_MARCAS"] != nil { doc.marcas = true }
        guard let caminho = ambiente["CUTLINE_TESTE_IMPRIMIR"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            Impressao.imprimir(doc, na: nil, pdf: URL(fileURLWithPath: caminho))
            print("impresso em \(caminho)")
        }
    }

    /// Abre com algumas formas já desenhadas e uma estrela selecionada.
    static var demo: Bool { ProcessInfo.processInfo.environment["CUTLINE_DEMO"] != nil }

    static func preencher(_ doc: Documento) {
        guard demo, doc.objetos.isEmpty else { return }
        let quadrado = Objeto(forma: .retangulo(raio: 6), quadro: CGRect(x: 30, y: 40, width: 60, height: 60))
        let elipse = Objeto(forma: .elipse, quadro: CGRect(x: 110, y: 50, width: 70, height: 45),
                            traco: CMYK(c: 100, m: 50, y: 0, k: 0))
        let estrela = Objeto(forma: .estrela(pontas: 5, raioInterno: 0.45), quadro: CGRect(x: 60, y: 130, width: 90, height: 86),
                             traco: CMYK(c: 70, m: 0, y: 100, k: 0))
        doc.objetos = [quadrado, elipse, estrela]
        doc.selecao = [estrela.id]
        // CUTLINE_DEMO=2: os mesmos objetos com estilos de traço (picotado, impresso por dentro e por fora).
        if ProcessInfo.processInfo.environment["CUTLINE_DEMO"] == "2" {
            doc.objetos[0].estilo.linha = .picotada3
            doc.objetos[1].espessura = 6
            doc.objetos[1].estilo.alinhamento = .dentro
            doc.objetos[1].preenchimento = CMYK(c: 0, m: 0, y: 20, k: 0)
            doc.objetos[2].espessura = 4
            doc.objetos[2].estilo = EstiloTraco(linha: .picotada2, ponta: .arredondada, canto: .arredondado, alinhamento: .fora)
            // Texto, guias e a seleção direta mostrando os nós da estrela.
            var texto = Texto(conteudo: "Feliz Dia")
            // CUTLINE_TESTE_FONTE_DEMO=Família: o texto da demo nessa família (o quadro sai das letras dela).
            texto.estilo.fonte = ProcessInfo.processInfo.environment["CUTLINE_TESTE_FONTE_DEMO"] ?? "Snell Roundhand"
            texto.estilo.tamanho = 54
            if let teste = textoNaTela {
                // Duas linhas centralizadas, com acento: o cursor e a seleção têm de cair sobre as letras.
                texto.conteudo = "Feliz Dia\nde Ação"
                texto.alinhamento = .centro
                if teste == "tipografia" {
                    texto.estilo.fonte = "Helvetica Neue"
                    texto.estilo.tamanho = 40
                    texto.marcador = .numeros
                    texto.estilo.sublinhado = true
                    texto.estilo.tracking = 50
                    texto.estilo.rotacao = 10
                    texto.alinhamento = .esquerda
                }
                if teste == "trechos" || teste.hasPrefix("curvas") {
                    // Estilo por trecho: H₂O (subscrito), x² (sobrescrito), "Dia" maior e em negrito, "de" sublinhado
                    // e subindo.
                    texto.conteudo = "H2O e x2 Feliz Dia\nde Ação"
                    texto.estilo.fonte = "Helvetica Neue"
                    texto.estilo.tamanho = 36
                    texto.alinhamento = .esquerda
                    texto.aplicar({ $0.posicao = .subscrito }, em: NSRange(location: 1, length: 1))
                    texto.aplicar({ $0.posicao = .sobrescrito }, em: NSRange(location: 7, length: 1))
                    texto.aplicar({ $0.tamanho = 60; $0.postscript = "HelveticaNeue-Bold" }, em: NSRange(location: 15, length: 3))
                    texto.aplicar({ $0.sublinhado = true; $0.deslocamento = 8 }, em: NSRange(location: 19, length: 2))
                }
            }
            doc.objetos.append(Objeto(forma: .texto(texto), quadro: CGRect(origin: CGPoint(x: 40, y: 230), size: texto.tamanhoNatural)))
            doc.guias = Guias(verticais: [60], horizontais: [130])
            doc.ferramenta = .direta
        }
    }

    /// CUTLINE_TESTE_TEXTO=1|visivel|selecao|tipografia (com CUTLINE_DEMO=2): abre a digitação do texto da
    /// demo com o cursor no meio dele. "visivel" mostra o campo invisível em azul (tem de ficar sobre as
    /// letras); "selecao" seleciona "Feliz"; "tipografia" usa números, sublinhado, tracking e rotação. O
    /// cursor não pisca, para sair na foto.
    static var textoNaTela: String? { ProcessInfo.processInfo.environment["CUTLINE_TESTE_TEXTO"] }

    static func editarTextoParaTeste(_ doc: Documento) {
        guard let teste = textoNaTela else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            // CUTLINE_TESTE_FAMILIA=Montserrat troca a família (e põe a face mais pesada) durante a edição.
            if let familia = ProcessInfo.processInfo.environment["CUTLINE_TESTE_FAMILIA"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    doc.mudarEstilo { $0.trocarFamilia(familia) }
                    doc.mudarEstilo { $0.postscript = Fontes.faces(familia).last?.postscript }
                }
            }
            if teste == "novo" {
                doc.ferramenta = .texto
                doc.novoTexto(em: CGPoint(x: 30, y: 40))
                return
            }
            guard let objeto = doc.objetos.last(where: { if case .texto = $0.forma { true } else { false } }) else { return }
            if teste == "curvas" {
                // Texto selecionado → curvas (com a seleção comum, para comparar o contorno com o do texto).
                doc.selecao = [objeto.id]
                doc.converterTextoEmCurvas()
                doc.ferramenta = .selecao
                return
            }
            doc.ferramenta = .texto
            doc.editarTexto(objeto.id, clique: CGPoint(x: objeto.quadro.midX, y: objeto.quadro.minY + 4))
            if teste == "curvasDigitando" {
                // ⇧⌘O pelo menu (o caminho do teclado de verdade) com o texto em edição. O menu só recebe o documento
                // da janela ativa: numa instância aberta em segundo plano ele fica desabilitado, e o teste chama a
                // mesma ação direto (o que importa é converter com a digitação aberta).
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    let janela = NSApp.windows.first { $0.isVisible }
                    let podia = doc.temTextoParaCurvas
                    guard let evento = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
                                                        timestamp: 0, windowNumber: janela?.windowNumber ?? 0, context: nil,
                                                        characters: "O", charactersIgnoringModifiers: "O", isARepeat: false,
                                                        keyCode: 31) else { return }
                    let tratou = NSApp.mainMenu?.performKeyEquivalent(with: evento) ?? false
                    let convertidos = tratou ? -1 : doc.converterTextoEmCurvas()
                    NSLog("CUTLINE_TESTE curvasDigitando: janela ativa = %@, podia = %@, menu tratou = %@, direto = %d, edição depois = %@",
                          "\(janela?.isKeyWindow ?? false)", "\(podia)", "\(tratou)", convertidos, "\(doc.edicaoTexto != nil)")
                }
            }
        }
    }

    /// CUTLINE_TESTE_FONTES=1 abre a lista de fontes do painel Caractere.
    static var listaFontesAberta: Bool { ProcessInfo.processInfo.environment["CUTLINE_TESTE_FONTES"] != nil }

    /// "selecao" seleciona "Feliz"; "novo" digita no campo invisível (o caminho do teclado de verdade);
    /// "estilo" seleciona "Feliz" e, pelo painel, o põe em 60 pt sobrescrito e digita mais letras no fim.
    static func selecionarTextoParaTeste(_ campo: NSTextView) {
        switch textoNaTela {
        case "selecao": campo.setSelectedRange(NSRange(location: 0, length: 5))
        case "estilo":
            campo.setSelectedRange(NSRange(location: 0, length: 5))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let doc = (campo.delegate as? CampoTextoNaTela.Coordenador)?.doc else { return }
                doc.mudarEstilo { $0.tamanho = 30; $0.posicao = .sobrescrito; $0.sublinhado = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    campo.setSelectedRange(NSRange(location: 2, length: 0))
                    campo.insertText("XY", replacementRange: campo.selectedRange())
                }
            }
        case "novo": campo.insertText("Olá, Cutline!\nSegunda linha", replacementRange: campo.selectedRange())
        default: break
        }
    }

    /// Grava a janela em PNG alguns segundos depois de abrir (vidro e desfoques podem não sair fiéis).
    /// CUTLINE_TESTE_MENUS=/x.txt: a barra de menus num texto, para conferir menus e traduções sem clicar.
    static func gravarMenus() {
        guard let caminho = ProcessInfo.processInfo.environment["CUTLINE_TESTE_MENUS"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            func linhas(_ menu: NSMenu, nivel: Int) -> [String] {
                menu.update()
                return menu.items.flatMap { item -> [String] in
                    let recuo = String(repeating: "    ", count: nivel)
                    if item.isSeparatorItem { return [recuo + "—"] }
                    var atalho = ""
                    if !item.keyEquivalent.isEmpty {
                        let m = item.keyEquivalentModifierMask
                        atalho = "  " + (m.contains(.control) ? "⌃" : "") + (m.contains(.option) ? "⌥" : "")
                            + (m.contains(.shift) ? "⇧" : "") + (m.contains(.command) ? "⌘" : "") + item.keyEquivalent.uppercased()
                    }
                    let marca = item.state == .on ? "✓ " : ""
                    // CUTLINE_TESTE_MENUS_ACOES=1: também a ação de cada item (para saber por onde ele passa).
                    let acao = ProcessInfo.processInfo.environment["CUTLINE_TESTE_MENUS_ACOES"] != nil
                        ? item.action.map { "  [" + NSStringFromSelector($0) + "]" } ?? "" : ""
                    let linha = recuo + marca + item.title + atalho + (item.isEnabled ? "" : "  (desabilitado)") + acao
                    return [linha] + (item.submenu.map { linhas($0, nivel: nivel + 1) } ?? [])
                }
            }
            let texto = NSApp.mainMenu.map { linhas($0, nivel: 0) }?.joined(separator: "\n") ?? ""
            try? texto.write(toFile: caminho, atomically: true, encoding: .utf8)
        }
    }

    static func agendarFoto() {
        guard let caminho = ProcessInfo.processInfo.environment["CUTLINE_FOTO"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard let janela = NSApp.windows.first(where: { $0.isVisible }),
                  let quadro = janela.contentView?.superview,
                  let imagem = quadro.bitmapImageRepForCachingDisplay(in: quadro.bounds) else { return }
            quadro.cacheDisplay(in: quadro.bounds, to: imagem)
            try? imagem.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: caminho))
        }
    }
}
#endif
