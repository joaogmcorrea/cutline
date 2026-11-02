// Edição de texto direto na tela, como no Illustrator: a ferramenta Texto (ou o duplo clique num texto)
// abre a edição; cada letra digitada muda o objeto na hora (a tela mostra o contorno de verdade). Toda a
// digitação é um passo só de desfazer; texto que termina vazio some.
import CoreGraphics
import Foundation

/// Texto sendo digitado na tela. O campo invisível que recebe o teclado fica em Editor/EditorTexto.swift.
nonisolated struct EdicaoTexto: Equatable, Sendable {
    /// Muda a cada edição (a tela recria o campo invisível).
    let sessao = UUID()
    let id: Objeto.ID
    /// Ponto do texto, em mm da página: topo da 1ª linha e x do alinhamento (começo das linhas à esquerda,
    /// meio no centro, fim à direita). Fica parado enquanto se digita.
    var origem: CGPoint
    /// Esticamento do objeto em relação ao tamanho natural das letras (1 = sem esticar): as escalas
    /// horizontal e vertical do painel Caractere.
    var escala: CGSize
    /// Onde caiu o clique que abriu a edição (mm da página): o cursor começa ali; nil = no fim do texto.
    let clique: CGPoint?
    /// Já entrou no desfazer.
    var registrado = false
}

extension Objeto {
    /// Texto sem letras (só existe enquanto se digita um texto novo na tela).
    nonisolated var textoVazio: Bool {
        if case .texto(let t) = forma { t.conteudo.allSatisfy(\.isWhitespace) } else { false }
    }

    /// Texto: o ponto do texto (topo da 1ª linha e x do alinhamento, mm da página) e o esticamento do quadro
    /// em relação ao tamanho natural das letras.
    var ancoraTexto: (origem: CGPoint, escala: CGSize)? {
        guard case .texto(let t) = forma else { return nil }
        let r = quadro.standardized
        guard let n = t.contorno?.boundingBoxOfPath, n.width > 0, n.height > 0 else {
            return (r.origin, CGSize(width: 1, height: 1))
        }
        let escala = CGSize(width: r.width / n.width, height: r.height / n.height)
        return (CGPoint(x: r.minX - n.minX * escala.width, y: r.minY - n.minY * escala.height), escala)
    }

    /// Troca o texto mantendo o ponto do texto no lugar e o esticamento (o quadro acompanha as letras).
    mutating func trocarTexto(_ novo: Texto, origem: CGPoint, escala: CGSize) {
        forma = .texto(novo)
        guard let n = novo.contorno?.boundingBoxOfPath else {
            quadro = CGRect(origin: origem, size: .zero)
            return
        }
        quadro = CGRect(x: origem.x + n.minX * escala.width, y: origem.y + n.minY * escala.height,
                        width: n.width * escala.width, height: n.height * escala.height)
    }
}

extension Texto {
    /// Aplica a mudança ao trecho (UTF-16) ou, sem trecho, ao texto inteiro (também ao estilo do texto vazio).
    mutating func aplicar(_ mudar: (inout EstiloCaractere) -> Void, em faixa: NSRange? = nil) {
        guard let faixa, faixa.length > 0 else {
            mudar(&estilo)
            for i in trechos.indices { mudar(&trechos[i].estilo) }
            normalizar()
            return
        }
        var novos: [Trecho] = [], posicao = 0
        for t in trechosCompletos {
            let inicio = posicao, fim = posicao + t.comprimento
            posicao = fim
            let a = min(max(faixa.location, inicio), fim), b = min(max(NSMaxRange(faixa), inicio), fim)
            if a > inicio { novos.append(Trecho(comprimento: a - inicio, estilo: t.estilo)) }
            if b > a {
                var e = t.estilo
                mudar(&e)
                novos.append(Trecho(comprimento: b - a, estilo: e))
            }
            if fim > b { novos.append(Trecho(comprimento: fim - b, estilo: t.estilo)) }
        }
        trechos = novos
        normalizar()
    }

    /// Conteúdo e trechos vindos do campo da tela (texto vazio fica com `estiloVazio`, o da digitação).
    mutating func definir(conteudo: String, trechos: [Trecho], estiloVazio: EstiloCaractere?) {
        self.conteudo = conteudo
        self.trechos = trechos
        if conteudo.isEmpty, let estiloVazio { estilo = estiloVazio }
        normalizar()
    }

    /// Trechos cobrindo exatamente o texto, os vizinhos iguais juntos; uniforme = só `estilo`.
    mutating func normalizar() {
        let total = comprimento
        guard total > 0 else {
            trechos = []
            return
        }
        var lista: [Trecho] = [], soma = 0
        for t in trechos where t.comprimento > 0 && soma < total {
            let c = min(t.comprimento, total - soma)
            soma += c
            if let ultimo = lista.last, ultimo.estilo == t.estilo {
                lista[lista.count - 1].comprimento += c
            } else {
                lista.append(Trecho(comprimento: c, estilo: t.estilo))
            }
        }
        if soma < total {
            if lista.isEmpty { lista.append(Trecho(comprimento: total, estilo: estilo)) } else { lista[lista.count - 1].comprimento += total - soma }
        }
        if lista.count == 1 {
            estilo = lista[0].estilo
            trechos = []
        } else {
            trechos = lista
        }
    }
}

extension Documento {
    /// Objeto da edição em andamento.
    var objetoEmEdicao: Objeto? {
        guard let edicaoTexto else { return nil }
        return objetos.first { $0.id == edicaoTexto.id }
    }

    /// Ponto do texto e esticamento da edição, lidos do objeto como está agora (pode ter sido movido pela
    /// barra de controle durante a edição); sem letras, os guardados na edição.
    var ancoraDaEdicao: (origem: CGPoint, escala: CGSize)? {
        guard let edicao = edicaoTexto, let objeto = objetoEmEdicao else { return nil }
        if objeto.textoVazio { return (objeto.quadro.standardized.origin, edicao.escala) }
        return objeto.ancoraTexto
    }

    /// Ferramenta Texto num lugar vazio: texto novo, ainda sem letras, com a linha de base da 1ª linha em
    /// `ponto` (mm). Ele já fica selecionado (a barra de controle mostra a fonte), mas só entra no
    /// desfazer quando algo for digitado; se terminar vazio, some.
    func novoTexto(em ponto: CGPoint) {
        terminarTexto()
        var texto = textoPadrao
        texto.conteudo = ""
        texto.trechos = []
        let origem = CGPoint(x: ponto.x, y: ponto.y - (texto.diagramacao.linhas.first?.ascendente ?? 0) * Texto.mmPorPt)
        guardarEstado()
        var objeto = objetoNovo(.texto(texto), quadro: CGRect(origin: origem, size: .zero))
        objeto.camada = camadaAtiva
        // Escrever numa camada oculta ou travada a mostra e destrava (senão o texto sumiria).
        if let i = camadas.firstIndex(where: { $0.id == camadaAtiva }) {
            camadas[i].visivel = true
            camadas[i].travada = false
        }
        objetos.append(objeto)
        selecao = [objeto.id]
        edicaoTexto = EdicaoTexto(id: objeto.id, origem: origem, escala: CGSize(width: 1, height: 1), clique: nil)
    }

    /// Abre a edição de um texto que já existe; `clique` (mm da página) põe o cursor ali.
    func editarTexto(_ id: Objeto.ID, clique: CGPoint?) {
        terminarTexto()
        guard let objeto = objetos.first(where: { $0.id == id }), !intocavel(objeto),
              let ancora = objeto.ancoraTexto else { return }
        guardarEstado()
        selecao = [id]
        camadaAtiva = camada(de: objeto).id
        edicaoTexto = EdicaoTexto(id: id, origem: ancora.origem, escala: ancora.escala, clique: clique)
    }

    /// O que está no campo invisível da tela vira o texto do objeto, letra a letra, com o estilo de cada trecho.
    func digitarTexto(_ conteudo: String, trechos: [Trecho], estiloVazio: EstiloCaractere?) {
        alterarEmEdicao { $0.definir(conteudo: conteudo, trechos: trechos, estiloVazio: estiloVazio) }
    }

    /// Texto mostrado no painel Parágrafo: o que se digita, o 1º texto selecionado ou o dos próximos textos.
    var textoAtual: Texto {
        if let objeto = objetoEmEdicao, case .texto(let t) = objeto.forma { return t }
        for objeto in selecionados { if case .texto(let t) = objeto.forma { return t } }
        return textoPadrao
    }

    /// Estilo mostrado no painel Caractere e na barra: o das letras selecionadas na tela (a 1ª), o do cursor
    /// (o que será digitado), o do 1º texto selecionado ou o dos próximos textos.
    var estiloDoTexto: EstiloCaractere {
        if let objeto = objetoEmEdicao, case .texto(let t) = objeto.forma {
            if selecaoTexto.length > 0 { return t.estilo(em: selecaoTexto.location) }
            return estiloDigitacao ?? t.estilo(em: max(selecaoTexto.location - 1, 0))
        }
        for objeto in selecionados { if case .texto(let t) = objeto.forma { return t.estilo(em: 0) } }
        return textoPadrao.estilo
    }

    /// Para onde vai uma mudança do painel Caractere (legenda do painel).
    enum AlvoEstilo { case letras, digitacao, textos, proximos }

    var alvoEstilo: AlvoEstilo {
        if objetoEmEdicao != nil { return selecaoTexto.length > 0 ? .letras : .digitacao }
        return objetoTextoAtual == nil ? .proximos : .textos
    }

    /// Objeto de texto dos painéis (nil = nenhum texto selecionado: os painéis mudam os próximos textos).
    var objetoTextoAtual: Objeto? {
        objetoEmEdicao ?? selecionados.first { if case .texto = $0.forma { true } else { false } }
    }

    /// Painel Caractere e barra de controle: digitando, valem para as letras selecionadas na tela (ou, com o
    /// cursor parado, para o que for digitado a seguir); fora da edição, para os textos selecionados inteiros;
    /// sem nenhum, para os próximos textos. Também vira o padrão dos próximos (o último usado, como no
    /// Illustrator).
    func mudarEstilo(_ mudar: (inout EstiloCaractere) -> Void) {
        var padrao = textoPadrao.estilo
        mudar(&padrao)
        if padrao != textoPadrao.estilo { textoPadrao.estilo = padrao }

        if let objeto = objetoEmEdicao, case .texto(let texto) = objeto.forma {
            let faixa = selecaoTexto
            if faixa.length > 0 {
                alterarEmEdicao { $0.aplicar(mudar, em: faixa) }
            } else {
                var e = estiloDigitacao ?? texto.estilo(em: max(faixa.location - 1, 0))
                mudar(&e)
                estiloDigitacao = e
                // Texto ainda vazio: o estilo dele muda junto (o cursor já mostra o corpo novo).
                if texto.comprimento == 0 { alterarEmEdicao { $0.estilo = e } }
            }
            return
        }
        let mudam = selecionados.contains { o in
            guard case .texto(var texto) = o.forma else { return false }
            let antes = texto
            texto.aplicar(mudar)
            return texto != antes
        }
        guard mudam else { return }
        alterarSelecao { o in
            guard case .texto(var texto) = o.forma, let ancora = o.ancoraTexto else { return }
            texto.aplicar(mudar)
            o.trocarTexto(texto, origem: ancora.origem, escala: ancora.escala)
        }
    }

    /// Painel Parágrafo (vale para o texto inteiro): do texto em edição, dos textos selecionados ou, sem
    /// nenhum, dos próximos textos. O ponto do texto fica no lugar; ao trocar o alinhamento, o bloco não sai
    /// do lugar.
    func mudarTexto(_ mudar: (inout Texto) -> Void) {
        var padrao = textoPadrao
        mudar(&padrao)
        padrao.conteudo = ""
        padrao.trechos = []
        if padrao != textoPadrao { textoPadrao = padrao }

        if objetoEmEdicao != nil {
            alterarEmEdicao(mudar)
            return
        }
        let mudam = selecionados.contains { o in
            guard case .texto(var texto) = o.forma else { return false }
            let antes = texto
            mudar(&texto)
            return texto != antes
        }
        guard mudam else { return }
        alterarSelecao { o in
            guard case .texto(var texto) = o.forma, let ancora = o.ancoraTexto else { return }
            let alinhamentoAntes = texto.alinhamento, quadroAntes = o.quadro
            mudar(&texto)
            o.trocarTexto(texto, origem: ancora.origem, escala: ancora.escala)
            if texto.alinhamento != alinhamentoAntes { o.quadro.origin.x += quadroAntes.minX - o.quadro.minX }
        }
    }

    /// Escalas horizontal e vertical do painel Caractere (1 = 100 %): esticam as letras como as alças da
    /// seleção, a partir do ponto do texto.
    func definirEscalaTexto(horizontal: Double? = nil, vertical: Double? = nil) {
        func nova(_ atual: CGSize) -> CGSize {
            CGSize(width: max(horizontal ?? atual.width, 0.01), height: max(vertical ?? atual.height, 0.01))
        }
        if let i = objetos.firstIndex(where: { $0.id == edicaoTexto?.id }), case .texto(let texto) = objetos[i].forma,
           let ancora = ancoraDaEdicao {
            let escala = nova(ancora.escala)
            guard escala != ancora.escala else { return }
            registrarEdicao()
            objetos[i].trocarTexto(texto, origem: ancora.origem, escala: escala)
            edicaoTexto?.origem = ancora.origem
            edicaoTexto?.escala = escala
            return
        }
        guard selecionados.contains(where: { $0.ancoraTexto.map { nova($0.escala) != $0.escala } ?? false }) else { return }
        alterarSelecao { o in
            guard case .texto(let texto) = o.forma, let ancora = o.ancoraTexto else { return }
            o.trocarTexto(texto, origem: ancora.origem, escala: nova(ancora.escala))
        }
    }

    /// Enter num campo dos painéis ou da barra: o teclado volta para o texto em edição na tela.
    func devolverFocoAoTexto() {
        if edicaoTexto != nil { focarTextoNaTela += 1 }
    }

    /// Termina a edição (clique fora, Esc, outra ferramenta). `sessao`: só se ainda for aquela edição — o
    /// campo invisível avisa depois de perder o foco, quando outra edição já pode ter começado.
    func terminarTexto(sessao: UUID? = nil) {
        guard let edicao = edicaoTexto, sessao == nil || sessao == edicao.sessao else { return }
        edicaoTexto = nil
        selecaoTexto = NSRange(location: 0, length: 0)
        estiloDigitacao = nil
        descartarEstadoGuardado()
        // Terminou sem letras: o texto some (se já estava no desfazer, apagar faz parte do mesmo passo).
        if let objeto = objetos.first(where: { $0.id == edicao.id }), objeto.textoVazio {
            objetos.removeAll { $0.id == edicao.id }
            selecao.remove(edicao.id)
        }
    }

    /// Muda o texto em edição mantendo o ponto do texto (lido do objeto agora) e o esticamento; trocar o
    /// alinhamento não tira o bloco do lugar.
    private func alterarEmEdicao(_ mudar: (inout Texto) -> Void) {
        guard let i = objetos.firstIndex(where: { $0.id == edicaoTexto?.id }), case .texto(var texto) = objetos[i].forma,
              let ancora = ancoraDaEdicao else { return }
        let antes = texto, estavaVazio = objetos[i].textoVazio, quadroAntes = objetos[i].quadro
        mudar(&texto)
        guard texto != antes else { return }
        registrarEdicao()
        objetos[i].trocarTexto(texto, origem: ancora.origem, escala: ancora.escala)
        var origem = ancora.origem
        if texto.alinhamento != antes.alinhamento, !estavaVazio, !objetos[i].textoVazio {
            let dx = quadroAntes.minX - objetos[i].quadro.minX
            objetos[i].quadro.origin.x += dx
            origem.x += dx
        }
        edicaoTexto?.origem = origem
        edicaoTexto?.escala = ancora.escala
    }

    /// A 1ª mudança de uma edição registra o desfazer a partir de antes da edição; as outras se somam a ela.
    private func registrarEdicao() {
        guard edicaoTexto?.registrado == false else { return }
        registrarGuardado()
        edicaoTexto?.registrado = true
    }
}
