// Corte por cor de linha (modelo do Silhouette Studio): cada cor de traço tem material e ajustes, e pode ser desligada.
import CutlineKit
import SwiftUI

nonisolated struct Material: Hashable, Identifiable, Codable, Sendable {
    let nome: String
    let ajustes: CutSettings
    var id: String { nome }

    /// Os dois de papel adesivo foram validados na Portrait 4; os demais são chutes a calibrar.
    static let todos = [
        Material(nome: "Papel adesivo — meio-corte", ajustes: CutSettings(speed: 5, force: 8, blade: 1, passes: 1)),
        Material(nome: "Papel adesivo — corte total", ajustes: CutSettings(speed: 3, force: 25, blade: 5, passes: 2)),
        Material(nome: "Cartolina lisa", ajustes: CutSettings(speed: 4, force: 20, blade: 3, passes: 1)),
        Material(nome: "Papel sulfite 75 g", ajustes: CutSettings(speed: 5, force: 10, blade: 2, passes: 1)),
        Material(nome: "Papel fotográfico", ajustes: CutSettings(speed: 5, force: 18, blade: 3, passes: 1)),
        Material(nome: "Vinil adesivo", ajustes: CutSettings(speed: 5, force: 10, blade: 1, passes: 1)),
    ]

    /// Só os do app (os do usuário estão em `AjustesGlobais`).
    static func chamado(_ nome: String) -> Material? { todos.first { $0.nome == nome } }

    /// Na tela: os do app traduzidos; os do usuário como ele escreveu. O nome em português continua sendo o
    /// que fica no arquivo (assim um arquivo abre igual em qualquer idioma).
    static func exibir(_ nome: String) -> String {
        chamado(nome) != nil ? String(localized: String.LocalizationValue(nome)) : nome
    }
}

nonisolated struct ConfigCorte: Hashable, Codable, Sendable {
    var ligado = true
    var material: String
    var ajustes: CutSettings

    init(material: Material) {
        self.material = material.nome
        self.ajustes = material.ajustes
    }

    private enum CodingKeys: String, CodingKey { case ligado, acao, material, ajustes }

    /// Até a 0.7.1 havia também a ação Cortar/Não cortar, que fazia o mesmo que desligar a cor: "Não cortar"
    /// de um arquivo antigo (ou da memória do app) abre desligado.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        material = try c.decode(String.self, forKey: .material)
        ajustes = try c.decode(CutSettings.self, forKey: .ajustes)
        ligado = try c.decodeIfPresent(Bool.self, forKey: .ligado) ?? true
        if try c.decodeIfPresent(String.self, forKey: .acao) == "Não cortar" { ligado = false }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ligado, forKey: .ligado)
        try c.encode(material, forKey: .material)
        try c.encode(ajustes, forKey: .ajustes)
    }

    var envia: Bool { ligado }
    /// Valores do material (do app ou "Meus materiais"); nil se o material não existe aqui (arquivo de
    /// outro Mac, material apagado) — os ajustes do arquivo continuam valendo.
    @MainActor var valoresDoMaterial: CutSettings? { AjustesGlobais.shared.material(material)?.ajustes }
    @MainActor var modificado: Bool { valoresDoMaterial.map { $0 != ajustes } ?? false }
}

/// Os objetos que têm a mesma cor de traço.
struct LinhaCorte: Identifiable {
    let cor: CMYK
    let objetos: [Objeto]
    var id: CMYK { cor }

    /// Caminhos em mm prontos para a máquina (curvas viram segmentos de até 0,02 mm de desvio; linhas
    /// picotadas viram trechos separados).
    var polilinhas: [[CGPoint]] {
        objetos.flatMap { objeto in
            let linhas = objeto.caminho.cgPath.cutPolylines()
            guard let padrao = objeto.estilo.linha.padrao else { return linhas }
            return linhas.flatMap { $0.dashed(padrao.map { CGFloat($0) }) }
        }
    }

    var comprimentoMM: Double {
        polilinhas.reduce(0) { total, linha in
            total + zip(linha, linha.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        }
    }
}

extension Documento {
    /// Os do arquivo; senão, os lembrados pelo app para esta cor; senão, o padrão.
    func config(_ cor: CMYK) -> ConfigCorte { cortes[cor] ?? AjustesGlobais.shared.porCor[cor] ?? Self.configPadrao(cor) }

    /// Magenta = meio-corte (contorno da vetorização); outras cores começam como cartolina.
    nonisolated static func configPadrao(_ cor: CMYK) -> ConfigCorte {
        let magenta = CMYK(c: 0, m: 100, y: 0, k: 0)
        return ConfigCorte(material: Material.chamado(cor == magenta ? "Papel adesivo — meio-corte" : "Cartolina lisa")!)
    }

    /// Guarda no arquivo (com desfazer) e no app, para os próximos arquivos.
    func definirConfig(_ config: ConfigCorte, para cor: CMYK) {
        AjustesGlobais.shared.lembrar(config, para: cor)
        guard cortes[cor] != config else { return }
        registrarAjuste("corte \(cor.descricao)")
        cortes[cor] = config
    }

    /// Ao enviar: os ajustes de todas as cores da tabela passam a ficar no arquivo (mesmo os que vieram
    /// do padrão ou da memória do app), para o arquivo reabrir exatamente como foi cortado.
    func fixarAjustesDoEnvio() {
        let linhas = linhasDeCorte
        for linha in linhas { AjustesGlobais.shared.lembrar(config(linha.cor), para: linha.cor) }
        let faltando = linhas.filter { cortes[$0.cor] == nil }
        let ordem = linhas.map(\.cor)
        guard !faltando.isEmpty || ordemCortes != ordem else { return }
        registrar()
        for linha in faltando { cortes[linha.cor] = config(linha.cor) }
        ordemCortes = ordem
    }

    /// Uma linha por cor de traço, na ordem escolhida; cores novas entram pela força
    /// (mais leve primeiro: o meio-corte de dentro antes do corte total de fora). Ficam de fora os
    /// objetos sem traço (não cortam), os ocultos e os que estão inteiros fora da página (como no Studio).
    var linhasDeCorte: [LinhaCorte] {
        var ordemDeChegada: [CMYK] = []
        var grupos: [CMYK: [Objeto]] = [:]
        let pagina = CGRect(origin: .zero, size: Self.pagina)
        for objeto in objetosEmOrdem where objeto.corta && visivel(objeto) && objeto.caminho.boundingRect.intersects(pagina) {
            if grupos[objeto.traco] == nil { ordemDeChegada.append(objeto.traco) }
            grupos[objeto.traco, default: []].append(objeto)
        }
        let posicao = { (cor: CMYK) -> Int in self.ordemCortes.firstIndex(of: cor) ?? 1000 + self.config(cor).ajustes.force }
        return ordemDeChegada
            .sorted { posicao($0) < posicao($1) }
            .map { LinhaCorte(cor: $0, objetos: grupos[$0]!) }
    }

    func moverLinha(_ cor: CMYK, paraCima: Bool) {
        var ordem = linhasDeCorte.map(\.cor)
        guard let i = ordem.firstIndex(of: cor) else { return }
        let j = paraCima ? i - 1 : i + 1
        guard ordem.indices.contains(j) else { return }
        ordem.swapAt(i, j)
        registrar()
        ordemCortes = ordem
    }

    /// Arrastar na tabela: a cor vai para a posição `destino`. Um arrasto que passa por várias linhas vira um
    /// passo só de desfazer.
    func moverLinha(_ cor: CMYK, para destino: Int) {
        var ordem = linhasDeCorte.map(\.cor)
        guard let i = ordem.firstIndex(of: cor), ordem.indices.contains(destino), i != destino else { return }
        ordem.remove(at: i)
        ordem.insert(cor, at: destino)
        registrarAjuste("ordem do corte")
        ordemCortes = ordem
    }

    /// O que vai para a máquina: só as cores ligadas e com ação "Cortar", na ordem da tabela.
    var camadasParaEnviar: [CutLayer] {
        linhasDeCorte.compactMap { linha in
            let config = config(linha.cor)
            guard config.envia else { return nil }
            return CutLayer(name: "\(config.material) (\(linha.cor.descricao))", paths: linha.polilinhas,
                            settings: config.ajustes)
        }
    }
}

// MARK: - Teste de corte

/// Teste de corte (como o do Silhouette Studio): um quadrado com um triângulo dentro, no lugar escolhido na
/// prévia da janela Enviar e com os ajustes de uma cor, para conferir a lâmina antes de cortar tudo.
nonisolated enum TesteCorte {
    static let lado = 10.0

    /// Em mm da página: o triângulo de dentro primeiro e o quadrado por último (a peça não solta antes).
    static func caminhos(em p: CGPoint) -> [[CGPoint]] {
        let l = lado, m = 2.0
        let triangulo = [CGPoint(x: p.x + l / 2, y: p.y + m), CGPoint(x: p.x + l - m, y: p.y + l - m),
                         CGPoint(x: p.x + m, y: p.y + l - m), CGPoint(x: p.x + l / 2, y: p.y + m)]
        return [triangulo, TestShapes.square(x: p.x, y: p.y, side: l)]
    }
}

extension Documento {
    /// Onde o teste pode ficar: entre as marcas no Print & Cut (o resto não é cortado); senão, na página.
    var areaDoTeste: CGRect { marcas ? configMarcas.area : CGRect(origin: .zero, size: Self.pagina) }

    /// Põe o teste num lugar da folha (sem passar da área).
    func moverTeste(para p: CGPoint) {
        let a = areaDoTeste, l = TesteCorte.lado
        posicaoTeste = CGPoint(x: min(max(p.x, a.minX), a.maxX - l), y: min(max(p.y, a.minY), a.maxY - l))
    }

    /// Só o teste, com os ajustes da cor; no Print & Cut a máquina lê as marcas antes, como no corte de verdade.
    func trabalhoDeTeste(_ cor: CMYK) -> Trabalho {
        moverTeste(para: posicaoTeste)
        let config = config(cor)
        let camada = CutLayer(name: String(localized: "Teste de corte (\(Material.exibir(config.material)))"),
                              paths: TesteCorte.caminhos(em: posicaoTeste), settings: config.ajustes)
        return Trabalho(nome: String(localized: "Teste de corte"), origem: ObjectIdentifier(self), camadas: [camada],
                        registro: registroParaEnviar, comBase: comBase, base: baseDeCorte)
    }
}
