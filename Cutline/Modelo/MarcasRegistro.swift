// Print & Cut: marcas de registro no padrão Silhouette (as mesmas do Studio e do inkscape-silhouette).
// A máquina lê as marcas com o sensor óptico antes de cortar e corrige posição, escala e rotação;
// os cortes ficam relativos a elas, então só a área entre as marcas é cortada.
import CutlineKit
import SwiftUI

/// Onde ficam as marcas na página (mm), do documento. O padrão do Cutline é o validado na Portrait 4; um .studio3
/// traz as do Studio (margem de 15,875 mm = 5/8" e cantoneiras de 20 ou 10 mm), que a máquina tem de procurar
/// no lugar certo para achar uma folha impressa pelo Studio.
nonisolated struct ConfigMarcas: Hashable, Codable, Sendable {
    /// Da borda da página ao canto externo das marcas.
    var esquerda = 15.0, topo = 15.0, direita = 15.0, baixo = 15.0
    /// Comprimento das cantoneiras em L e espessura das linhas (TB51 e TB53 do envio).
    var comprimento = 20.0, espessura = 0.5

    static let padrao = ConfigMarcas()
    /// O padrão do Silhouette Studio numa folha A4 (5/8 pol. da borda), visto nos arquivos dele.
    static let studio = ConfigMarcas(margem: 15.875)
    /// Quadrado do canto superior esquerdo.
    static let quadrado = 5.0
    /// Folga em volta de cada marca onde não se deve imprimir nada (o sensor se confunde).
    static let folga = 2.0

    init() {}

    init(margem: Double, comprimento: Double = 20) {
        (esquerda, topo, direita, baixo) = (margem, margem, margem, margem)
        self.comprimento = comprimento
    }

    /// As do arquivo do Silhouette Studio.
    init(_ studio: StudioDocument.RegistrationMarks) {
        esquerda = studio.left
        topo = studio.top
        direita = studio.right
        baixo = studio.bottom
        comprimento = studio.length
        espessura = studio.thickness
    }

    /// Área entre as marcas (mm da página): o driver só corta aqui dentro.
    var area: CGRect {
        let pagina = Documento.pagina
        return CGRect(x: esquerda, y: topo, width: pagina.width - esquerda - direita, height: pagina.height - topo - baixo)
    }

    /// O que a máquina procura antes de cortar.
    var registro: Cutter.Registration {
        let a = area
        return Cutter.Registration(originX: a.minX, originY: a.minY, width: a.width, length: a.height,
                                   markLength: comprimento, markThickness: espessura)
    }

    /// Retângulos pretos que formam as marcas (mm da página): o quadrado no canto superior esquerdo e as
    /// cantoneiras em L nos cantos superior direito e inferior esquerdo.
    var retangulos: [CGRect] {
        let a = area, e = espessura, l = comprimento, q = Self.quadrado
        return [
            CGRect(x: a.minX, y: a.minY, width: q, height: q),
            CGRect(x: a.maxX - l, y: a.minY, width: l, height: e), CGRect(x: a.maxX - e, y: a.minY, width: e, height: l),   // ┐
            CGRect(x: a.minX, y: a.maxY - e, width: l, height: e), CGRect(x: a.minX, y: a.maxY - l, width: e, height: l),   // └
        ]
    }

    /// Onde não pôr arte nem cortes: fora da área entre as marcas e em volta de cada marca.
    /// Pintar com a regra par-ímpar.
    var zonaProibida: Path {
        let a = area, l = comprimento, q = Self.quadrado
        var zona = Path(CGRect(origin: .zero, size: Documento.pagina))
        zona.addRect(a)
        let caixas = [CGRect(x: a.minX, y: a.minY, width: q, height: q),
                      CGRect(x: a.maxX - l, y: a.minY, width: l, height: l),
                      CGRect(x: a.minX, y: a.maxY - l, width: l, height: l)]
        for caixa in caixas { zona.addRect(caixa.insetBy(dx: -Self.folga, dy: -Self.folga).intersection(a)) }
        return zona
    }

    /// Margem igual nos quatro lados (o painel Página edita assim); nil se forem diferentes.
    var margem: Double? { Set([esquerda, topo, direita, baixo]).count == 1 ? esquerda : nil }
}

extension Documento {
    /// Liga ou desliga as marcas (fica no arquivo; um passo de desfazer).
    func alternarMarcas() {
        registrar()
        marcas.toggle()
    }

    /// O que a máquina lê antes de cortar (nil sem as marcas).
    var registroParaEnviar: Cutter.Registration? { marcas ? configMarcas.registro : nil }

    /// Muda a posição ou o tamanho das marcas (fica no arquivo; ajustes seguidos são um passo de desfazer).
    func definirMarcas(_ nova: ConfigMarcas) {
        guard nova != configMarcas else { return }
        registrarAjuste("marcas")
        configMarcas = nova
    }

    /// Objetos que vão para a máquina e passam da área entre as marcas (o que fica de fora não é cortado).
    var objetosForaDasMarcas: Int {
        let area = configMarcas.area
        return linhasDeCorte.filter { config($0.cor).envia }
            .flatMap(\.objetos)
            .filter { !area.contains($0.caminho.boundingRect) }
            .count
    }
}

// MARK: - Página (base de corte) e envio

extension Documento {
    /// Última escolha da base de corte (para os documentos novos).
    nonisolated static var ultimaBase: Bool {
        UserDefaults.standard.object(forKey: "comBase") as? Bool ?? true
    }

    /// Com ou sem a base de corte (fica no arquivo, com desfazer, e vale para os próximos documentos).
    func definirBase(_ nova: Bool) {
        UserDefaults.standard.set(nova, forKey: "comBase")
        guard nova != comBase else { return }
        registrar()
        comBase = nova
    }

    /// Última base escolhida (para os documentos novos); nil = a padrão da máquina.
    nonisolated static var ultimaBaseDeCorte: CuttingMat? {
        UserDefaults.standard.string(forKey: "baseDeCorte").flatMap(CuttingMat.init(rawValue:))
    }

    /// A base que vai para a máquina: a escolhida, se ela aceitar; senão, a padrão dela. "Sem base" = `.none`.
    func base(para hardware: Hardware) -> CuttingMat {
        guard comBase else { return .none }
        if let baseDeCorte, hardware.supportedCuttingMats.contains(baseDeCorte) { return baseDeCorte }
        return hardware.defaultCuttingMat ?? .none
    }

    /// Escolhe a base (painel Página): "sem base" desliga a base; as outras a ligam. Fica no arquivo, com desfazer,
    /// e vale para os próximos documentos.
    func definirBase(_ nova: CuttingMat) {
        if nova == .none { return definirBase(false) }
        UserDefaults.standard.set(true, forKey: "comBase")
        UserDefaults.standard.set(nova.rawValue, forKey: "baseDeCorte")
        guard !comBase || baseDeCorte != nova else { return }
        registrar()
        comBase = true
        baseDeCorte = nova
    }

    /// O que vai para a fila da máquina: as cores ligadas, as marcas (Print & Cut) e a base.
    func trabalho(nome: String) -> Trabalho {
        Trabalho(nome: nome, origem: ObjectIdentifier(self), camadas: camadasParaEnviar, registro: registroParaEnviar,
                 comBase: comBase, base: baseDeCorte)
    }
}
