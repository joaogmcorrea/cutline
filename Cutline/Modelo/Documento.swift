// Documento do editor: objetos em mm sobre a página A4, seleção, ferramenta e desfazer.
// O arquivo (salvar, abrir, importar do Studio) fica em Modelo/Arquivo.swift.
import CutlineKit
import ImageIO
import Observation
import SwiftUI

/// Cor sempre em CMYK (o documento vai para impressão); RGB é só para mostrar na tela.
nonisolated struct CMYK: Hashable, Codable, Sendable {
    var c: Double, m: Double, y: Double, k: Double   // 0–100

    /// Conversão ingênua, sem perfil ICC (no futuro: ColorSync com perfil CMYK real).
    var cor: Color {
        let f = { (v: Double) in 1 - v / 100 }
        return Color(red: f(c) * f(k), green: f(m) * f(k), blue: f(y) * f(k))
    }

    var descricao: String { "CMYK (\(Int(c)), \(Int(m)), \(Int(y)), \(Int(k)))" }

    static let vermelho = CMYK(c: 0, m: 100, y: 100, k: 0)

    /// De RGB (0–1), com a mesma conversão ingênua, arredondada a 1 % para as cores iguais se agruparem.
    init(vermelho r: Double, verde g: Double, azul b: Double) {
        let limitar = { (v: Double) in min(max(v, 0), 1) }
        let (r, g, b) = (limitar(r), limitar(g), limitar(b))
        let k = 1 - max(r, g, b)
        guard k < 1 else {
            self.init(c: 0, m: 0, y: 0, k: 100)
            return
        }
        let canal = { (v: Double) in ((1 - v - k) / (1 - k) * 100).rounded() }
        self.init(c: canal(r), m: canal(g), y: canal(b), k: (k * 100).rounded())
    }

    init(c: Double, m: Double, y: Double, k: Double) {
        self.c = c
        self.m = m
        self.y = y
        self.k = k
    }

    /// Paleta como a do Silhouette Studio: cinzas + 12 matizes em 5 tons.
    static let amostras: [CMYK] = {
        let cinzas = [0.0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 95, 100].map { CMYK(c: 0, m: 0, y: 0, k: $0) }
        let matizes: [[Double]] = [[0, 100, 100, 0], [0, 100, 40, 0], [30, 100, 0, 0], [70, 80, 0, 0], [100, 50, 0, 0],
                                   [100, 0, 0, 0], [80, 0, 50, 0], [70, 0, 100, 0], [30, 0, 100, 0], [0, 0, 100, 0],
                                   [0, 50, 100, 0], [0, 60, 100, 45]]
        let tons = [1, 0.75, 0.5, 0.3, 0.15].flatMap { f in
            matizes.map { v in CMYK(c: (v[0] * f).rounded(), m: (v[1] * f).rounded(), y: (v[2] * f).rounded(), k: (v[3] * f).rounded()) }
        }
        return cinzas + tons
    }()
}

/// Nó de um caminho livre. As coordenadas são relativas ao quadro do objeto (0…1 nos dois eixos), para o
/// caminho acompanhar o quadro ao mover e redimensionar; `entrada`/`saida` são os pontos de controle.
nonisolated struct No: Hashable, Codable, Sendable {
    var ponto: CGPoint
    var entrada: CGPoint?
    var saida: CGPoint?
}

nonisolated struct Subcaminho: Hashable, Codable, Sendable {
    var nos: [No]
    var fechado = true
}

nonisolated enum Forma: Hashable, Codable, Sendable {
    /// Raio dos cantos em mm.
    case retangulo(raio: Double)
    case elipse
    /// Raio interno como fração do externo.
    case estrela(pontas: Int, raioInterno: Double)
    /// Caminho livre (caneta, Pathfinder, importados, formas editadas ponto a ponto).
    case caminho([Subcaminho])
    /// Texto: contorno das letras (CoreText) esticado para o quadro; corta pelas bordas das letras.
    case texto(Texto)

    var nome: String {
        switch self {
        case .retangulo: String(localized: "Retângulo")
        case .elipse: String(localized: "Elipse")
        case .estrela: String(localized: "Estrela")
        case .caminho: String(localized: "Caminho")
        case .texto(let t): t.conteudo.isEmpty ? String(localized: "Texto") : t.conteudo
        }
    }
}

nonisolated struct Texto: Hashable, Codable, Sendable {
    var conteudo = String(localized: "Texto")
    /// Estilo do texto inteiro quando ele é uniforme (`trechos` vazio) e do texto vazio.
    var estilo = EstiloCaractere()
    /// Estilo por trecho, em ordem, cobrindo o texto todo (comprimentos em UTF-16, como o NSRange do campo de
    /// texto); vazio = o texto inteiro com `estilo`. Sempre normalizado (Modelo/EdicaoTexto.swift).
    var trechos: [Trecho] = []

    // Painel Parágrafo (cada linha é um parágrafo; o texto não quebra sozinho): vale para o texto inteiro.
    var alinhamento = AlinhamentoTexto.esquerda
    var marcador = MarcadorTexto.nenhum
    /// Recuos e espaços entre parágrafos, em pt.
    var recuoEsquerda = 0.0
    var recuoDireita = 0.0
    var recuoPrimeira = 0.0
    var espacoAntes = 0.0
    var espacoDepois = 0.0

    init(conteudo: String = String(localized: "Texto"), estilo: EstiloCaractere = EstiloCaractere()) {
        self.conteudo = conteudo
        self.estilo = estilo
    }
}

/// Estilo de um trecho do texto (painel Caractere e barra de controle).
nonisolated struct EstiloCaractere: Hashable, Codable, Sendable {
    /// Nome da família (ex.: "Helvetica Neue").
    var fonte = "Helvetica Neue"
    /// Corpo em pt.
    var tamanho = 36.0
    /// Face escolhida no menu Estilo (nome PostScript, ex.: "Montserrat-Bold"); nil = a normal da família.
    var postscript: String?
    /// Distância da linha de base anterior até a desta linha, em pt (a linha usa a maior); nil = automática.
    var entrelinha: Double?
    /// Kerning em milésimos de em; nil = o da fonte (métrico); 0 = sem kerning.
    var kerning: Double?
    /// Espaço a mais entre as letras, em milésimos de em.
    var tracking = 0.0
    /// Deslocamento da linha de base, em pt (positivo = sobe).
    var deslocamento = 0.0
    var posicao = PosicaoCaractere.normal
    /// Cada letra girada em torno do próprio centro, em graus (positivo = anti-horário, como no Illustrator).
    var rotacao = 0.0
    var caixaAlta = false
    var versalete = false
    var sublinhado = false
    var tachado = false

    init() {}

    /// Leitura tolerante (campos que faltam ficam no padrão).
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(lendo: c)
    }

    /// Lê os campos de um contêiner com as mesmas chaves (também o do `Texto` antigo, que os tinha soltos).
    nonisolated init<Chave: CodingKey>(lendo c: KeyedDecodingContainer<Chave>) throws {
        func valor<T: Decodable>(_ nome: String, _ tipo: T.Type) throws -> T? {
            guard let chave = Chave(stringValue: nome) else { return nil }
            return try c.decodeIfPresent(tipo, forKey: chave)
        }
        fonte = try valor("fonte", String.self) ?? fonte
        tamanho = try valor("tamanho", Double.self) ?? tamanho
        postscript = try valor("postscript", String.self)
        entrelinha = try valor("entrelinha", Double.self)
        kerning = try valor("kerning", Double.self)
        tracking = try valor("tracking", Double.self) ?? tracking
        deslocamento = try valor("deslocamento", Double.self) ?? deslocamento
        posicao = try valor("posicao", PosicaoCaractere.self) ?? posicao
        rotacao = try valor("rotacao", Double.self) ?? rotacao
        caixaAlta = try valor("caixaAlta", Bool.self) ?? caixaAlta
        versalete = try valor("versalete", Bool.self) ?? versalete
        sublinhado = try valor("sublinhado", Bool.self) ?? sublinhado
        tachado = try valor("tachado", Bool.self) ?? tachado
    }
}

/// Sobrescrito e subscrito como os do Illustrator: 58,3 % do corpo, a 33,3 % do corpo da linha de base.
nonisolated enum PosicaoCaractere: String, Codable, CaseIterable, Identifiable, Sendable {
    case normal, sobrescrito, subscrito
    var id: Self { self }
}

/// Trecho com um estilo (comprimento em UTF-16).
nonisolated struct Trecho: Hashable, Codable, Sendable {
    var comprimento: Int
    var estilo: EstiloCaractere
}

/// Leitura tolerante: arquivos da v0.6.0 só têm conteúdo, fonte e corpo, soltos no texto.
extension Texto {
    nonisolated private struct ChaveLivre: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conteudo = try c.decodeIfPresent(String.self, forKey: .conteudo) ?? ""
        if let estilo = try c.decodeIfPresent(EstiloCaractere.self, forKey: .estilo) {
            self.estilo = estilo
        } else {
            estilo = try EstiloCaractere(lendo: decoder.container(keyedBy: ChaveLivre.self))
        }
        trechos = try c.decodeIfPresent([Trecho].self, forKey: .trechos) ?? []
        alinhamento = try c.decodeIfPresent(AlinhamentoTexto.self, forKey: .alinhamento) ?? alinhamento
        marcador = try c.decodeIfPresent(MarcadorTexto.self, forKey: .marcador) ?? marcador
        recuoEsquerda = try c.decodeIfPresent(Double.self, forKey: .recuoEsquerda) ?? recuoEsquerda
        recuoDireita = try c.decodeIfPresent(Double.self, forKey: .recuoDireita) ?? recuoDireita
        recuoPrimeira = try c.decodeIfPresent(Double.self, forKey: .recuoPrimeira) ?? recuoPrimeira
        espacoAntes = try c.decodeIfPresent(Double.self, forKey: .espacoAntes) ?? espacoAntes
        espacoDepois = try c.decodeIfPresent(Double.self, forKey: .espacoDepois) ?? espacoDepois
    }
}

/// Alinhamento das linhas em relação ao ponto do texto (como o texto de ponto do Illustrator).
nonisolated enum AlinhamentoTexto: String, Codable, CaseIterable, Identifiable, Sendable {
    case esquerda, centro, direita
    var id: Self { self }
}

/// Marcador antes de cada parágrafo com letras.
nonisolated enum MarcadorTexto: String, Codable, CaseIterable, Identifiable, Sendable {
    case nenhum, bolinha, numeros
    var id: Self { self }
}

/// Guias em mm (verticais em x, horizontais em y), arrastadas das réguas.
nonisolated struct Guias: Hashable, Codable, Sendable {
    var verticais: [Double] = []
    var horizontais: [Double] = []
    var vazias: Bool { verticais.isEmpty && horizontais.isEmpty }
}

/// Transformação afim guardada no arquivo (x' = a·x + c·y + tx; y' = b·x + d·y + ty).
nonisolated struct Transformacao: Hashable, Codable, Sendable {
    var a, b, c, d, tx, ty: Double

    init(_ t: CGAffineTransform) {
        a = t.a
        b = t.b
        c = t.c
        d = t.d
        tx = t.tx
        ty = t.ty
    }

    var cg: CGAffineTransform { CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty) }
}

/// Imagem que preenche a forma (a arte do Print & Cut), recortada pelo contorno.
nonisolated struct ImagemNaForma: Hashable, Codable, Sendable {
    /// Chave em `Documento.imagens`.
    var chave: String
    /// Pixel da imagem (origem no canto superior esquerdo) → coordenadas relativas ao quadro (0…1).
    var transformacao: Transformacao
}

/// Estilos de linha do Silhouette Studio: os tracejados viram cortes picotados.
nonisolated enum EstiloLinha: Int, Codable, CaseIterable, Identifiable, Sendable {
    case continua, picotada1, picotada2, picotada3, picotada4

    var id: Self { self }

    /// Trecho com corte e trecho sem corte, em mm (nil = contínua).
    var padrao: [Double]? {
        switch self {
        case .continua: nil
        case .picotada1: [0.8, 0.8]
        case .picotada2: [2, 1.5]
        case .picotada3: [3, 4]
        case .picotada4: [4, 1]
        }
    }

    var nome: String {
        guard let padrao else { return String(localized: "Contínua") }
        let mm = padrao.map { $0.formatted(.number.precision(.fractionLength(0...1))) }
        return String(localized: "Picotada \(mm[0]) / \(mm[1]) mm")
    }
}

nonisolated enum Ponta: String, Codable, CaseIterable, Identifiable, Sendable {
    case reta, arredondada, projetada
    var id: Self { self }
    var cg: CGLineCap {
        switch self {
        case .reta: .butt
        case .arredondada: .round
        case .projetada: .square
        }
    }
}

nonisolated enum Canto: String, Codable, CaseIterable, Identifiable, Sendable {
    case vivo, arredondado, chanfrado
    var id: Self { self }
    var cg: CGLineJoin {
        switch self {
        case .vivo: .miter
        case .arredondado: .round
        case .chanfrado: .bevel
        }
    }
}

nonisolated enum AlinhamentoTraco: String, Codable, CaseIterable, Identifiable, Sendable {
    case centro, dentro, fora
    var id: Self { self }
}

/// Como o traço é desenhado e cortado (a cor e a espessura ficam no objeto, como antes).
nonisolated struct EstiloTraco: Hashable, Codable, Sendable {
    var linha = EstiloLinha.continua
    /// Ponta, canto e alinhamento só valem com espessura > 0 (traço impresso).
    var ponta = Ponta.reta
    var canto = Canto.vivo
    var limiteCanto = 10.0
    var alinhamento = AlinhamentoTraco.centro
}

nonisolated struct Objeto: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var forma: Forma
    /// Caixa da forma, em mm na página (origem no canto superior esquerdo).
    var quadro: CGRect
    /// A cor do traço define o corte (como no Silhouette Studio).
    var traco = CMYK.vermelho
    /// Em pt. 0 = fio visível na tela que não imprime — só corte.
    var espessura = 0.0
    var estilo = EstiloTraco()
    var preenchimento: CMYK?
    var imagem: ImagemNaForma?
    /// Falso: fica no desenho (e na impressão), mas não vai para a máquina.
    var corta = true
    /// Camada do objeto (nil ou uma que não existe mais = a de cima).
    var camada: UUID?
    var oculto = false
    var travado = false
    /// Nome dado pelo app (ex.: "União" no Pathfinder); sem ele, o nome da forma.
    var rotulo: String?
    /// Grupos do objeto, do de fora para o de dentro (Modelo/Grupos.swift); vazio = solto.
    var grupos: [UUID] = []

    var nome: String { rotulo ?? (imagem != nil ? String(localized: "Imagem") : forma.nome) }
}

/// Leitura tolerante: campos que faltam (arquivos de versões anteriores) ficam com o valor padrão.
extension Objeto {
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(forma: try c.decode(Forma.self, forKey: .forma), quadro: try c.decode(CGRect.self, forKey: .quadro))
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? id
        traco = try c.decodeIfPresent(CMYK.self, forKey: .traco) ?? traco
        espessura = try c.decodeIfPresent(Double.self, forKey: .espessura) ?? espessura
        estilo = try c.decodeIfPresent(EstiloTraco.self, forKey: .estilo) ?? estilo
        preenchimento = try c.decodeIfPresent(CMYK.self, forKey: .preenchimento)
        imagem = try c.decodeIfPresent(ImagemNaForma.self, forKey: .imagem)
        corta = try c.decodeIfPresent(Bool.self, forKey: .corta) ?? corta
        camada = try c.decodeIfPresent(UUID.self, forKey: .camada)
        oculto = try c.decodeIfPresent(Bool.self, forKey: .oculto) ?? oculto
        travado = try c.decodeIfPresent(Bool.self, forKey: .travado) ?? travado
        rotulo = try c.decodeIfPresent(String.self, forKey: .rotulo)
        grupos = try c.decodeIfPresent([UUID].self, forKey: .grupos) ?? []
    }
}

nonisolated enum Ferramenta: String, CaseIterable, Identifiable, Sendable {
    case selecao, direta, caneta, texto, retangulo, elipse, estrela, vetorizar, mao

    var id: Self { self }

    var nome: String {
        switch self {
        case .selecao: String(localized: "Seleção")
        case .direta: String(localized: "Seleção direta")
        case .caneta: String(localized: "Caneta")
        case .texto: String(localized: "Texto")
        case .retangulo: String(localized: "Retângulo")
        case .elipse: String(localized: "Elipse")
        case .estrela: String(localized: "Estrela")
        case .vetorizar: String(localized: "Vetorizar imagem")
        case .mao: String(localized: "Mão")
        }
    }

    /// Atalhos do Illustrator.
    var tecla: Character {
        switch self {
        case .selecao: "v"
        case .direta: "a"
        case .caneta: "p"
        case .texto: "t"
        case .retangulo: "m"
        case .elipse: "l"
        case .estrela: "s"
        case .vetorizar: "i"
        case .mao: "h"
        }
    }

    var criaForma: Bool { self == .retangulo || self == .elipse || self == .estrela }
}

/// Os dados ficam fora da MainActor porque o macOS cria e lê os documentos numa thread de fundo;
/// a edição (extensões abaixo) é toda na principal, onde a interface usa o documento.
@Observable
nonisolated final class Documento: @unchecked Sendable {
    static let pagina = CGSize(width: 210, height: 297)   // A4, mm
    /// Margem da base de corte em volta da página, só para desenho.
    static let margemBase = 8.0

    var objetos: [Objeto]
    var selecao: Set<Objeto.ID> = []
    var ferramenta = Ferramenta.selecao
    /// Cores e traço dos próximos objetos.
    var tracoPadrao = CMYK.vermelho
    var preenchimentoPadrao: CMYK?
    var espessuraPadrao = 0.0
    var estiloPadrao = EstiloTraco()
    /// Qual quadrado do painel Cor está na frente (X alterna).
    var alvoCor = AlvoCor.traco
    /// Últimas cores escolhidas no painel (até 14).
    var recentes: [CMYK]
    /// Camadas, a de cima primeiro (Modelo/Camadas.swift).
    var camadas: [Camada]
    var camadaAtiva: UUID
    var guias: Guias
    /// Marcas de registro do Print & Cut na página (Modelo/MarcasRegistro.swift): ligadas e onde ficam.
    var marcas: Bool
    var configMarcas: ConfigMarcas
    /// Cortar com a base de corte (o plástico adesivo); sem ela, a máquina puxa a folha direto. Os documentos
    /// novos começam com a última escolha (painel Página).
    var comBase: Bool
    /// A base escolhida no painel Página (nil = a padrão da máquina; a máquina recebe uma que ela aceita).
    var baseDeCorte: CuttingMat?
    /// Corte por cor de linha (Modelo/Corte.swift): ajustes salvos e ordem escolhida.
    var cortes: [CMYK: ConfigCorte]
    var ordemCortes: [CMYK]
    /// Imagens (PNG ou JPEG) usadas pelos objetos, pela chave de `ImagemNaForma`.
    var imagens: [String: Data]
    /// Faixa de aviso na janela (resumo da importação, Pathfinder sem resultado…), até o OK.
    var aviso: String?
    /// Texto sendo digitado direto na tela (Modelo/EdicaoTexto.swift).
    var edicaoTexto: EdicaoTexto?
    /// Fonte e tipografia dos próximos textos: as últimas escolhidas (painel Caractere, barra de controle).
    var textoPadrao = Texto(conteudo: "")
    /// Seleção no texto sendo digitado (UTF-16): os painéis Caractere e a barra agem nela.
    var selecaoTexto = NSRange(location: 0, length: 0)
    /// Estilo escolhido com o cursor parado (sem seleção): vale para as próximas letras digitadas.
    var estiloDigitacao: EstiloCaractere?
    /// Muda para a tela devolver o teclado ao texto em edição (depois de um campo dos painéis).
    var focarTextoNaTela = 0
    /// Muda quando o menu Arquivo › Importar… é escolhido (a janela abre o painel de arquivos).
    var pedidoImportar = 0
    /// Muda quando o menu Arquivo › Imprimir… é escolhido (a janela abre o painel de impressão).
    var pedidoImprimir = 0
    /// Muda quando o menu Arquivo › Enviar… é escolhido (a janela abre a janela Enviar).
    var pedidoEnviar = 0
    /// Canto superior esquerdo do teste de corte na folha, em mm (Modelo/Corte.swift); não vai para o arquivo.
    var posicaoTeste = CGPoint(x: 25, y: 25)
    /// Aberto de um .studio3: a janela desliga o documento desse arquivo (ver JanelaPrincipal).
    @ObservationIgnored var veioDoStudio: Bool
    /// O .studio3 aberto e de onde veio cada objeto, para gravar por cima dele (Modelo/SalvarStudio.swift).
    @ObservationIgnored var studio: OrigemStudio?

    /// Muda a cada passo de desfazer, para os botões de desfazer/refazer se atualizarem.
    fileprivate(set) var versao = 0
    /// O desfazer é o da janela (o mesmo do menu Editar); cada registro também marca o documento como
    /// alterado, para o macOS pedir para salvar.
    @ObservationIgnored fileprivate weak var gerenciador: UndoManager?
    @ObservationIgnored fileprivate var observadores: [NSObjectProtocol] = []
    @ObservationIgnored fileprivate var ultimoAjuste: (chave: String, quando: Date)?
    /// Estado de antes da edição de texto, registrado no desfazer só quando algo mudar (`registrarGuardado`).
    @ObservationIgnored fileprivate var estadoGuardado: Estado?
    @ObservationIgnored fileprivate var imagensDecodificadas: [String: CGImage] = [:]

    init(objetos: [Objeto] = [], cortes: [CMYK: ConfigCorte] = [:], ordemCortes: [CMYK] = [],
         imagens: [String: Data] = [:], camadas: [Camada] = [], camadaAtiva: UUID? = nil, recentes: [CMYK] = [],
         guias: Guias = Guias(), marcas: Bool = false, configMarcas: ConfigMarcas = .padrao, comBase: Bool? = nil,
         baseDeCorte: CuttingMat?? = nil, aviso: String? = nil, veioDoStudio: Bool = false) {
        self.guias = guias
        self.marcas = marcas
        self.configMarcas = configMarcas
        self.comBase = comBase ?? Self.ultimaBase
        self.baseDeCorte = baseDeCorte ?? Self.ultimaBaseDeCorte
        let camadas = camadas.isEmpty ? [Camada(nome: String(localized: "Camada \(1)"), cor: 0)] : camadas
        self.camadas = camadas
        self.camadaAtiva = camadaAtiva.flatMap { id in camadas.first { $0.id == id }?.id } ?? camadas[0].id
        self.recentes = recentes
        self.objetos = objetos
        self.cortes = cortes
        self.ordemCortes = ordemCortes
        self.imagens = imagens
        self.aviso = aviso
        self.veioDoStudio = veioDoStudio
    }
}

nonisolated enum AlvoCor: Sendable {
    case preenchimento, traco
}

/// O que um passo de desfazer guarda.
nonisolated private struct Estado: Sendable {
    var objetos: [Objeto]
    var cortes: [CMYK: ConfigCorte]
    var ordemCortes: [CMYK]
    var camadas: [Camada]
    var camadaAtiva: UUID
    var guias: Guias
    var marcas: Bool
    var configMarcas: ConfigMarcas
    var comBase: Bool
    var baseDeCorte: CuttingMat?
}

extension Documento {
    var selecionados: [Objeto] { objetos.filter { selecao.contains($0.id) } }

    func imagem(_ chave: String) -> CGImage? {
        if let pronta = imagensDecodificadas[chave] { return pronta }
        guard let dados = imagens[chave], let fonte = CGImageSourceCreateWithData(dados as CFData, nil),
              let imagem = CGImageSourceCreateImageAtIndex(fonte, 0, nil) else { return nil }
        imagensDecodificadas[chave] = imagem
        return imagem
    }

    // MARK: Desfazer

    /// Liga o documento ao desfazer da janela.
    func usar(_ novo: UndoManager?) {
        guard novo !== gerenciador else { return }
        observadores.forEach(NotificationCenter.default.removeObserver)
        observadores = []
        gerenciador = novo
        guard let novo else { return }
        novo.levelsOfUndo = 200
        observadores = [Notification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange]
            .map { nome in
                NotificationCenter.default.addObserver(forName: nome, object: novo, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.versao += 1 }
                }
            }
        versao += 1
    }

    private var estado: Estado {
        get {
            Estado(objetos: objetos, cortes: cortes, ordemCortes: ordemCortes, camadas: camadas, camadaAtiva: camadaAtiva,
                   guias: guias, marcas: marcas, configMarcas: configMarcas, comBase: comBase,
                   baseDeCorte: baseDeCorte)
        }
        set {
            objetos = newValue.objetos
            cortes = newValue.cortes
            ordemCortes = newValue.ordemCortes
            camadas = newValue.camadas
            camadaAtiva = newValue.camadaAtiva
            guias = newValue.guias
            marcas = newValue.marcas
            configMarcas = newValue.configMarcas
            comBase = newValue.comBase
            baseDeCorte = newValue.baseDeCorte
            selecao.formIntersection(objetos.map(\.id))
        }
    }

    var podeDesfazer: Bool {
        _ = versao
        return gerenciador?.canUndo ?? false
    }

    var podeRefazer: Bool {
        _ = versao
        return gerenciador?.canRedo ?? false
    }

    /// Guarda o estado antes de uma alteração (um passo de ⌘Z).
    func registrar() {
        let anterior = estado
        gerenciador?.registerUndo(withTarget: self) { $0.restaurar(anterior) }
        ultimoAjuste = nil
        estadoGuardado = nil
        versao += 1
    }

    /// Guarda o estado de agora sem registrar: a edição de texto põe o texto na tela antes de saber se
    /// algo vai ser digitado (vazio, ele some sem deixar um passo de desfazer).
    func guardarEstado() { estadoGuardado = estado }

    func descartarEstadoGuardado() { estadoGuardado = nil }

    /// Registra o desfazer a partir do estado guardado (ou do atual, se outra alteração já o usou): toda a
    /// digitação de uma edição de texto vira um passo só.
    func registrarGuardado() {
        guard let anterior = estadoGuardado else { return registrar() }
        gerenciador?.registerUndo(withTarget: self) { $0.restaurar(anterior) }
        ultimoAjuste = nil
        estadoGuardado = nil
        versao += 1
    }

    private func restaurar(_ anterior: Estado) {
        // Desfazer encerra a digitação na tela; texto vazio (deixado pela edição) nunca volta.
        edicaoTexto = nil
        estadoGuardado = nil
        let atual = estado
        gerenciador?.registerUndo(withTarget: self) { $0.restaurar(atual) }
        estado = anterior
        objetos.removeAll(where: \.textoVazio)
        versao += 1
    }

    func desfazer() { gerenciador?.undo() }
    func refazer() { gerenciador?.redo() }

    /// Valores que mudam aos poucos (sliders de corte e de cor): um passo de desfazer só enquanto se
    /// mexe na mesma coisa (`chave`) sem parar mais de 1,5 s.
    func registrarAjuste(_ chave: String) {
        let agora = Date()
        if let ultimo = ultimoAjuste, ultimo.chave == chave, agora.timeIntervalSince(ultimo.quando) < 1.5 {
            ultimoAjuste = (chave, agora)
            return
        }
        registrar()
        ultimoAjuste = (chave, agora)
    }

    // MARK: Edição

    /// Novo objeto na camada ativa, com as cores e o traço dos próximos objetos.
    func adicionar(_ objeto: Objeto) {
        var novo = objeto
        novo.camada = camadaAtiva
        registrar()
        // Desenhar numa camada oculta ou travada a mostra e destrava (senão o objeto sumiria).
        if let i = camadas.firstIndex(where: { $0.id == camadaAtiva }) {
            camadas[i].visivel = true
            camadas[i].travada = false
        }
        objetos.append(novo)
        selecao = [novo.id]
    }

    /// Objetos importados (vetorização, PDF) num passo só de desfazer, na camada ativa, selecionados.
    func inserirImportados(_ novos: [Objeto], imagens novas: [String: Data] = [:]) {
        guard !novos.isEmpty else { return }
        registrar()
        imagens.merge(novas) { _, nova in nova }
        if let i = camadas.firstIndex(where: { $0.id == camadaAtiva }) {
            camadas[i].visivel = true
            camadas[i].travada = false
        }
        objetos.append(contentsOf: novos.map { var o = $0; o.camada = camadaAtiva; return o })
        selecao = Set(novos.map(\.id))
    }

    /// Objeto novo com o estilo dos próximos objetos.
    func objetoNovo(_ forma: Forma, quadro: CGRect) -> Objeto {
        Objeto(forma: forma, quadro: quadro, traco: tracoPadrao, espessura: espessuraPadrao, estilo: estiloPadrao,
               preenchimento: preenchimentoPadrao)
    }

    func apagarSelecao() {
        guard !selecao.isEmpty else { return }
        registrar()
        objetos.removeAll { selecao.contains($0.id) }
        selecao = []
    }

    /// Setas do teclado: move a seleção (os toques seguidos, sem parar mais de 1,5 s, são um passo de desfazer).
    func moverSelecao(dx: Double, dy: Double) {
        guard !selecao.isEmpty else { return }
        registrarAjuste("setas")
        for i in objetos.indices where selecao.contains(objetos[i].id) {
            objetos[i].quadro = objetos[i].quadro.offsetBy(dx: dx, dy: dy)
        }
    }

    /// Tudo o que dá para mexer (nem oculto nem travado).
    func selecionarTudo() {
        selecao = Set(objetos.filter { !intocavel($0) }.map(\.id))
    }

    /// Copia os selecionados (⌘D desloca 5 mm; ⌥-arrastar, no lugar; ⌘ + seta, ao lado) e seleciona as cópias
    /// (as de um grupo formam um grupo novo).
    func duplicarSelecao(deslocamento: CGSize = CGSize(width: 5, height: 5)) {
        let copias = Objeto.copias(selecionados, deslocamento: deslocamento)
        guard !copias.isEmpty else { return }
        registrar()
        objetos.append(contentsOf: copias)
        selecao = Set(copias.map(\.id))
    }

    func apagarGuias() {
        guard !guias.vazias else { return }
        registrar()
        guias = Guias()
    }

    /// Altera os objetos selecionados num passo só de desfazer.
    func alterarSelecao(_ mudar: (inout Objeto) -> Void) {
        guard !selecao.isEmpty else { return }
        registrar()
        for i in objetos.indices where selecao.contains(objetos[i].id) { mudar(&objetos[i]) }
    }

    // MARK: Cores e traço (seleção ou, sem seleção, os próximos objetos)

    /// Cor mostrada no painel: a da seleção (nil = nenhuma; `misturadas` se forem diferentes).
    func cor(_ alvo: AlvoCor) -> (cor: CMYK?, misturadas: Bool) {
        let ler = { (o: Objeto) -> CMYK? in alvo == .traco ? (o.corta ? o.traco : nil) : o.preenchimento }
        guard let primeiro = selecionados.first else { return (alvo == .traco ? tracoPadrao : preenchimentoPadrao, false) }
        let cor = ler(primeiro)
        return (cor, selecionados.contains { ler($0) != cor })
    }

    /// `cor` nil = nenhuma (no traço: o objeto deixa de cortar). `final` = escolha terminada (clique,
    /// Enter): entra nas recentes; enquanto arrasta um slider, os passos se juntam num só desfazer.
    func definirCor(_ alvo: AlvoCor, _ cor: CMYK?, final: Bool = true) {
        if selecao.isEmpty {
            if alvo == .traco { if let cor { tracoPadrao = cor } } else { preenchimentoPadrao = cor }
        } else if self.cor(alvo) != (cor, false) {
            if final { registrar() } else { registrarAjuste("cor \(alvo)") }
            for i in objetos.indices where selecao.contains(objetos[i].id) {
                if alvo == .preenchimento {
                    objetos[i].preenchimento = cor
                } else if let cor {
                    objetos[i].traco = cor
                    objetos[i].corta = true
                } else {
                    objetos[i].corta = false
                }
            }
        }
        if final, let cor { lembrar(cor) }
    }

    func lembrar(_ cor: CMYK) {
        recentes.removeAll { $0 == cor }
        recentes.insert(cor, at: 0)
        if recentes.count > 14 { recentes.removeLast(recentes.count - 14) }
    }

    /// ⇧X: troca preenchimento e traço.
    func trocarCores() {
        if selecao.isEmpty {
            if let preenchimento = preenchimentoPadrao { (tracoPadrao, preenchimentoPadrao) = (preenchimento, tracoPadrao) }
            return
        }
        alterarSelecao { o in
            let traco = o.corta ? o.traco : nil
            if let preenchimento = o.preenchimento { o.traco = preenchimento; o.corta = true } else { o.corta = false }
            o.preenchimento = traco
        }
    }

    /// D: o padrão do app — sem preenchimento, traço vermelho de 0 pt contínuo.
    func coresPadrao() {
        let aplicar = { (o: inout Objeto) in
            o.preenchimento = nil
            o.traco = .vermelho
            o.corta = true
            o.espessura = 0
            o.estilo = EstiloTraco()
        }
        if selecao.isEmpty {
            preenchimentoPadrao = nil
            tracoPadrao = .vermelho
            espessuraPadrao = 0
            estiloPadrao = EstiloTraco()
        } else {
            alterarSelecao(aplicar)
        }
    }

    /// Só registra se mudar: o campo do painel confirma o valor de novo ao perder o foco.
    func definirEspessura(_ pt: Double) {
        let valor = max(0, pt)
        if selecao.isEmpty { espessuraPadrao = valor } else if selecionados.contains(where: { $0.espessura != valor }) {
            alterarSelecao { $0.espessura = valor }
        }
    }

    /// Estilo mostrado no painel: o do primeiro selecionado ou o dos próximos objetos.
    var estiloAtual: EstiloTraco { selecionados.first?.estilo ?? estiloPadrao }

    func definirEstilo(_ mudar: (inout EstiloTraco) -> Void) {
        if selecao.isEmpty {
            mudar(&estiloPadrao)
            return
        }
        var teste = selecionados.map(\.estilo)
        for i in teste.indices { mudar(&teste[i]) }
        guard teste != selecionados.map(\.estilo) else { return }
        alterarSelecao { mudar(&$0.estilo) }
    }
}
