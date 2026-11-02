// Pathfinder (como no Illustrator e no protótipo): operações booleanas entre os objetos selecionados,
// com as do próprio CoreGraphics (macOS 14+). O resultado vira caminho livre e herda o estilo.
import CoreGraphics
import SwiftUI

nonisolated enum OperacaoPathfinder: String, CaseIterable, Identifiable, Sendable {
    case unir, subtrairFrente, intersecao, excluir, dividir, subtrairTras

    var id: Self { self }

    var nome: String {
        switch self {
        case .unir: String(localized: "Unir")
        case .subtrairFrente: String(localized: "Subtrair frente")
        case .intersecao: String(localized: "Interseção")
        case .excluir: String(localized: "Excluir sobreposição")
        case .dividir: String(localized: "Dividir")
        case .subtrairTras: String(localized: "Subtrair trás")
        }
    }

    /// Nome dos objetos que saem da operação.
    var resultado: String {
        switch self {
        case .unir: String(localized: "União")
        case .subtrairFrente, .subtrairTras: String(localized: "Subtração")
        case .intersecao: String(localized: "Interseção", comment: "Nome do objeto que sai do Pathfinder")
        case .excluir: String(localized: "Exclusão")
        case .dividir: String(localized: "Parte")
        }
    }

    /// Os quatro primeiros são "modos de forma"; os dois últimos, "pathfinders".
    var ehModoDeForma: Bool { self != .dividir && self != .subtrairTras }
}

extension Objeto {
    /// Caminho livre a partir de um contorno em mm da página: o quadro é a caixa do contorno.
    nonisolated static func caminhoLivre(_ path: CGPath) -> (quadro: CGRect, subcaminhos: [Subcaminho])? {
        let caixa = path.boundingBoxOfPath
        guard !caixa.isNull, !caixa.isInfinite else { return nil }
        let largura = caixa.width > 0 ? caixa.width : 1, altura = caixa.height > 0 ? caixa.height : 1
        let relativo = { (p: CGPoint) in CGPoint(x: (p.x - caixa.minX) / largura, y: (p.y - caixa.minY) / altura) }
        var subcaminhos: [Subcaminho] = []
        var atual: [No] = []
        func fechar(_ fechado: Bool) {
            var nos = atual
            // O fechamento costuma repetir o primeiro ponto: junta os dois.
            if fechado, nos.count > 1, let primeiro = nos.first, let ultimo = nos.last,
               hypot(primeiro.ponto.x - ultimo.ponto.x, primeiro.ponto.y - ultimo.ponto.y) < 1e-6 {
                nos[0].entrada = ultimo.entrada
                nos.removeLast()
            }
            if nos.count > 1 {
                subcaminhos.append(Subcaminho(nos: nos.map { No(ponto: relativo($0.ponto), entrada: $0.entrada.map(relativo),
                                                                saida: $0.saida.map(relativo)) }, fechado: fechado))
            }
            atual = []
        }
        path.applyWithBlock { elemento in
            let e = elemento.pointee
            switch e.type {
            case .moveToPoint:
                if !atual.isEmpty { fechar(false) }
                atual = [No(ponto: e.points[0])]
            case .addLineToPoint:
                atual.append(No(ponto: e.points[0]))
            case .addQuadCurveToPoint:
                guard let anterior = atual.last?.ponto else { return }
                let q = e.points[0], p = e.points[1]
                atual[atual.count - 1].saida = CGPoint(x: anterior.x + 2 / 3 * (q.x - anterior.x), y: anterior.y + 2 / 3 * (q.y - anterior.y))
                atual.append(No(ponto: p, entrada: CGPoint(x: p.x + 2 / 3 * (q.x - p.x), y: p.y + 2 / 3 * (q.y - p.y))))
            case .addCurveToPoint:
                guard !atual.isEmpty else { return }
                atual[atual.count - 1].saida = e.points[0]
                atual.append(No(ponto: e.points[2], entrada: e.points[1]))
            case .closeSubpath:
                fechar(true)
            @unknown default:
                break
            }
        }
        if !atual.isEmpty { fechar(false) }
        return subcaminhos.isEmpty ? nil : (caixa, subcaminhos)
    }
}

extension Documento {
    /// Aplica a operação aos selecionados; devolve um aviso quando não dá.
    func pathfinder(_ operacao: OperacaoPathfinder) -> String? {
        let objs = objetosEmOrdem.filter { selecao.contains($0.id) }   // de trás para a frente
        guard objs.count >= 2 else { return String(localized: "Selecione ao menos dois objetos para o Pathfinder.") }
        guard objs.allSatisfy({ $0.imagem == nil }) else { return String(localized: "Imagens não entram no Pathfinder.") }
        let regra = CGPathFillRule.evenOdd
        let p = objs.map { $0.caminho.cgPath }
        var pecas: [(CGPath, Objeto)]
        switch operacao {
        case .unir:
            pecas = [(p.dropFirst().reduce(p[0]) { $0.union($1, using: regra) }, objs.last!)]
        case .intersecao:
            pecas = [(p.dropFirst().reduce(p[0]) { $0.intersection($1, using: regra) }, objs.last!)]
        case .excluir:
            pecas = [(p.dropFirst().reduce(p[0]) { $0.symmetricDifference($1, using: regra) }, objs.last!)]
        case .subtrairFrente:
            pecas = [(p.dropFirst().reduce(p[0]) { $0.subtracting($1, using: regra) }, objs[0])]
        case .subtrairTras:
            pecas = [(p.dropLast().reduce(p[p.count - 1]) { $0.subtracting($1, using: regra) }, objs.last!)]
        case .dividir:
            // Cada nova forma corta as peças que já existem; cada região vira um objeto.
            var partes: [(CGPath, Objeto)] = [(p[0], objs[0])]
            for i in 1..<p.count {
                var novas: [(CGPath, Objeto)] = []
                var resto = p[i]
                for (peca, de) in partes {
                    novas.append((peca.intersection(p[i], using: regra), objs[i]))
                    novas.append((peca.subtracting(p[i], using: regra), de))
                    resto = resto.subtracting(peca, using: regra)
                }
                novas.append((resto, objs[i]))
                partes = novas
            }
            pecas = partes.flatMap { caminho, de in caminho.componentsSeparated(using: regra).map { ($0, de) } }
        }
        let novos: [Objeto] = pecas.compactMap { caminho, de in
            let caixa = caminho.boundingBoxOfPath
            guard !caminho.isEmpty, caixa.width * caixa.height > 0.0001, let livre = Objeto.caminhoLivre(caminho) else { return nil }
            var objeto = de
            objeto.id = UUID()
            objeto.forma = .caminho(livre.subcaminhos)
            objeto.quadro = livre.quadro
            objeto.rotulo = operacao.resultado
            return objeto
        }
        guard !novos.isEmpty else { return String(localized: "O resultado ficou vazio — as formas não se sobrepõem?") }
        registrar()
        let posicao = (objetos.indices.filter { selecao.contains(objetos[$0].id) }.max() ?? objetos.count - 1) + 1
        objetos.insert(contentsOf: novos, at: min(posicao, objetos.count))
        objetos.removeAll { selecao.contains($0.id) }
        selecao = Set(novos.map(\.id))
        return nil
    }
}
