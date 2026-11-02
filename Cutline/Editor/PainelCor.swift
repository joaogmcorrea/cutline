// Seção Cor do painel lateral (como no protótipo e no Illustrator): quadrados de preenchimento e traço
// (X alterna, ⇧X troca, D padrão, / nenhum), canais CMYK/HSL/RGB com degradê, hex, cores rápidas,
// amostras do Studio, espectro e recentes. Tudo é guardado em CMYK.
import SwiftUI

enum ModoCor: String, CaseIterable, Identifiable {
    case cmyk = "CMYK", hsl = "HSL", rgb = "RGB"
    var id: Self { self }
}

struct SecaoCor: View {
    @Bindable var doc: Documento
    let modo: ModoCor

    var body: some View {
        let alvo = doc.alvoCor
        let (atual, misturadas) = doc.cor(alvo)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 6) {
                    QuadradosCor(doc: doc)
                    HStack(spacing: 2) {
                        Button { doc.coresPadrao() } label: { Image(.coresPadrao).resizable().frame(width: 13, height: 13) }
                            .help("Padrão: sem preenchimento, traço vermelho de 0 pt (D)")
                        Button { doc.trocarCores() } label: { Image(.inverterCores).resizable().frame(width: 13, height: 13) }
                            .help("Trocar preenchimento e traço (⇧X)")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
                .frame(width: 46)
                CanaisCor(doc: doc, modo: modo, base: atual ?? CMYK(c: 0, m: 0, y: 0, k: 0))
                    .disabled(atual == nil)
                    .opacity(atual == nil ? 0.4 : 1)
            }

            HStack(spacing: 6) {
                Text("#").foregroundStyle(.secondary)
                CampoHex(valor: atual?.hex ?? "") { cor in doc.definirCor(alvo, cor) }
                Group {
                    if misturadas {
                        Text("cores misturadas")
                    } else if let atual {
                        Text(verbatim: "C\(Int(atual.c)) M\(Int(atual.m)) Y\(Int(atual.y)) K\(Int(atual.k))")
                    } else {
                        Text("nenhum")
                    }
                }
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 4) {
                BotaoCor(cor: nil, escolhida: atual == nil && !misturadas, dica: String(localized: "Nenhum (/)")) { doc.definirCor(alvo, nil) }
                BotaoCor(cor: CMYK(c: 0, m: 0, y: 0, k: 100), escolhida: atual == CMYK(c: 0, m: 0, y: 0, k: 100), dica: String(localized: "Preto 100 %")) {
                    doc.definirCor(alvo, CMYK(c: 0, m: 0, y: 0, k: 100))
                }
                BotaoCor(cor: CMYK(c: 0, m: 0, y: 0, k: 0), escolhida: atual == CMYK(c: 0, m: 0, y: 0, k: 0), dica: String(localized: "Branco")) {
                    doc.definirCor(alvo, CMYK(c: 0, m: 0, y: 0, k: 0))
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 12), spacing: 3) {
                ForEach(CMYK.amostras, id: \.self) { amostra in
                    Amostra(cor: amostra, escolhida: amostra == atual) { doc.definirCor(alvo, amostra) }
                }
            }

            Espectro { cor, final in doc.definirCor(alvo, cor, final: final) }
                .frame(height: 30)

            if !doc.recentes.isEmpty {
                HStack(spacing: 3) {
                    ForEach(doc.recentes, id: \.self) { cor in
                        BotaoCor(cor: cor, escolhida: cor == atual, dica: cor.descricao) { doc.definirCor(alvo, cor) }
                    }
                }
            }

            Text(alvo == .traco
                 ? "Cores sempre em CMYK. A cor do traço define a configuração de corte; sem traço, o objeto não corta."
                 : "Cores sempre em CMYK (RGB, HSL e hex convertem na hora). O preenchimento é impresso.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Os dois quadrados do Illustrator: preenchimento atrás, traço (só a borda grossa) na frente; clicar
/// traz um para a frente. Branco com risco vermelho = nenhum; "?" = cores misturadas.
private struct QuadradosCor: View {
    @Bindable var doc: Documento

    var body: some View {
        let preenchimento = doc.cor(.preenchimento), traco = doc.cor(.traco)
        ZStack(alignment: .topLeading) {
            quadrado(preenchimento.cor, misturadas: preenchimento.misturadas, ehTraco: false)
                .zIndex(doc.alvoCor == .preenchimento ? 2 : 1)
            quadrado(traco.cor, misturadas: traco.misturadas, ehTraco: true)
                .offset(x: 14, y: 14)
                .zIndex(doc.alvoCor == .traco ? 2 : 1)
        }
        .frame(width: 44, height: 44, alignment: .topLeading)
    }

    private func quadrado(_ cor: CMYK?, misturadas: Bool, ehTraco: Bool) -> some View {
        let forma = RoundedRectangle(cornerRadius: 6)
        let ativo = doc.alvoCor == (ehTraco ? .traco : .preenchimento)
        return ZStack {
            if let cor, !misturadas {
                if ehTraco {
                    forma.fill(Color.white.opacity(0.001))
                    forma.strokeBorder(cor.cor, lineWidth: 6)
                } else {
                    forma.fill(cor.cor)
                }
            } else {
                forma.fill(.white)
                if misturadas {
                    Text("?").font(.system(size: 13, weight: .bold)).foregroundStyle(.gray)
                } else {
                    Nenhum().clipShape(forma)
                }
            }
        }
        .frame(width: 28, height: 28)
        .overlay(forma.strokeBorder(.black.opacity(0.22), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 1.5, y: 1)
        .overlay(forma.inset(by: -3).stroke(Color.accentColor, lineWidth: ativo ? 2 : 0))
        .contentShape(forma)
        .onTapGesture { doc.alvoCor = ehTraco ? .traco : .preenchimento }
        .help(ehTraco ? "Traço — cor de corte (X alterna)" : "Preenchimento (X alterna)")
    }
}

/// Risco vermelho em diagonal: "nenhum".
private struct Nenhum: View {
    var body: some View {
        Canvas { ctx, tamanho in
            var risco = Path()
            risco.move(to: CGPoint(x: 0, y: tamanho.height))
            risco.addLine(to: CGPoint(x: tamanho.width, y: 0))
            ctx.stroke(risco, with: .color(Color(red: 1, green: 0.23, blue: 0.19)), lineWidth: max(2, tamanho.width / 10))
        }
    }
}

/// Canais do modo escolhido: rótulo, trilha com o degradê do próprio canal, valor digitável e unidade.
private struct CanaisCor: View {
    @Bindable var doc: Documento
    let modo: ModoCor
    let base: CMYK

    private struct Canal {
        let rotulo: String
        let valor: Int
        let maximo: Int
        let unidade: String
        let cores: [Color]
        let aplicar: (Int) -> CMYK
    }

    private var canais: [Canal] {
        switch modo {
        case .cmyk:
            let campos: [(String, WritableKeyPath<CMYK, Double>)] = [("C", \.c), ("M", \.m), ("Y", \.y), ("K", \.k)]
            return campos.map { rotulo, campo in
                var de = base, ate = base
                de[keyPath: campo] = 0
                ate[keyPath: campo] = 100
                return Canal(rotulo: rotulo, valor: Int(base[keyPath: campo].rounded()), maximo: 100, unidade: "%",
                             cores: [de.corSRGB, ate.corSRGB]) { v in
                    var nova = base
                    nova[keyPath: campo] = Double(v)
                    return nova
                }
            }
        case .rgb:
            let rgb = base.rgb255
            return ["R", "G", "B"].enumerated().map { i, rotulo in
                var de = rgb, ate = rgb
                de[i] = 0
                ate[i] = 255
                return Canal(rotulo: rotulo, valor: rgb[i], maximo: 255, unidade: "",
                             cores: [CMYK(rgb255: de).corSRGB, CMYK(rgb255: ate).corSRGB]) { v in
                    var novo = rgb
                    novo[i] = v
                    return CMYK(rgb255: novo)
                }
            }
        case .hsl:
            let hsl = base.hsl
            let matizes = stride(from: 0, through: 360, by: 60).map { CMYK(hsl: [$0, 100, 50]).corSRGB }
            let canal = { (i: Int, rotulo: String, maximo: Int, unidade: String, cores: [Color]) in
                Canal(rotulo: rotulo, valor: hsl[i], maximo: maximo, unidade: unidade, cores: cores) { v in
                    var novo = hsl
                    novo[i] = v
                    return CMYK(hsl: novo)
                }
            }
            return [
                canal(0, "H", 360, "°", matizes),
                canal(1, "S", 100, "%", [CMYK(hsl: [hsl[0], 0, hsl[2]]).corSRGB, CMYK(hsl: [hsl[0], 100, hsl[2]]).corSRGB]),
                canal(2, "L", 100, "%", [.black, CMYK(hsl: [hsl[0], hsl[1], 50]).corSRGB, .white]),
            ]
        }
    }

    var body: some View {
        VStack(spacing: 7) {
            ForEach(canais, id: \.rotulo) { canal in
                HStack(spacing: 6) {
                    Text(canal.rotulo)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 12, alignment: .leading)
                    TrilhaCor(valor: canal.valor, maximo: canal.maximo, cores: canal.cores) { v, final in
                        doc.definirCor(doc.alvoCor, canal.aplicar(v), final: final)
                    }
                    TextField(canal.rotulo, value: Binding(get: { canal.valor }, set: { novo in
                        let v = min(max(novo, 0), canal.maximo)
                        if v != canal.valor { doc.definirCor(doc.alvoCor, canal.aplicar(v)) }
                    }), format: .number)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 44)
                    Text(canal.unidade)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 10, alignment: .leading)
                }
            }
        }
    }
}

/// Trilha fina com degradê e pino branco: arrastar ou clicar escolhe o valor.
private struct TrilhaCor: View {
    let valor: Int
    let maximo: Int
    let cores: [Color]
    /// (valor, terminou de arrastar)
    let mudar: (Int, Bool) -> Void

    var body: some View {
        GeometryReader { geo in
            let largura = max(geo.size.width, 1)
            let x = Double(valor) / Double(maximo) * largura
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: cores, startPoint: .leading, endPoint: .trailing))
                    .overlay(Capsule().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
                    .frame(height: 6)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
                    .frame(width: 14, height: 14)
                    .offset(x: min(max(x - 7, -7), largura - 7))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { mudar(valorEm($0.location.x, largura), false) }
                .onEnded { mudar(valorEm($0.location.x, largura), true) })
        }
        .frame(height: 16)
    }

    private func valorEm(_ x: Double, _ largura: Double) -> Int {
        Int((min(max(x / largura, 0), 1) * Double(maximo)).rounded())
    }
}

/// Campo hex: aplica ao confirmar; texto inválido volta ao valor atual.
private struct CampoHex: View {
    let valor: String
    let aplicar: (CMYK) -> Void
    @State private var texto = ""

    var body: some View {
        TextField("hex", text: $texto)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()
            .frame(width: 76)
            .onAppear { texto = valor }
            .onChange(of: valor) { _, novo in texto = novo }
            .onSubmit {
                if let cor = CMYK(hex: texto), cor.hex != valor { aplicar(cor) } else { texto = valor }
            }
    }
}

/// Quadradinho de cor (rápidas e recentes); sem cor = nenhum.
private struct BotaoCor: View {
    let cor: CMYK?
    let escolhida: Bool
    let dica: String
    let escolher: () -> Void

    var body: some View {
        let forma = RoundedRectangle(cornerRadius: 4)
        Button(action: escolher) {
            ZStack {
                if let cor { forma.fill(cor.cor) } else { forma.fill(.white); Nenhum().clipShape(forma) }
            }
            .frame(width: 18, height: 18)
            .overlay(forma.strokeBorder(escolhida ? Color.accentColor : .black.opacity(0.25), lineWidth: escolhida ? 2 : 0.5))
        }
        .buttonStyle(.plain)
        .help(dica)
    }
}

struct Amostra: View {
    let cor: CMYK
    let escolhida: Bool
    let escolher: () -> Void
    @State private var sobre = false

    var body: some View {
        Button(action: escolher) {
            RoundedRectangle(cornerRadius: 4)
                .fill(cor.cor)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(escolhida ? Color.accentColor : Color.black.opacity(0.18), lineWidth: escolhida ? 2 : 0.5))
                .aspectRatio(1, contentMode: .fit)
                .scaleEffect(sobre ? 1.18 : 1)
                .animation(.snappy(duration: 0.12), value: sobre)
        }
        .buttonStyle(.plain)
        .onHover { sobre = $0 }
        .help(cor.descricao)
    }
}

/// Espectro: matiz na horizontal; de cima para baixo, do branco à cor pura e ao preto.
private struct Espectro: View {
    /// (cor, terminou de arrastar)
    let escolher: (CMYK, Bool) -> Void

    var body: some View {
        GeometryReader { geo in
            let tamanho = geo.size
            Canvas { ctx, t in
                let retangulo = Path(CGRect(origin: .zero, size: t))
                let matizes = stride(from: 0, through: 360, by: 30).map { CMYK(hsl: [$0, 100, 50]).corSRGB }
                ctx.fill(retangulo, with: .linearGradient(Gradient(colors: matizes), startPoint: .zero, endPoint: CGPoint(x: t.width, y: 0)))
                ctx.fill(retangulo, with: .linearGradient(Gradient(stops: [
                    .init(color: .white, location: 0), .init(color: .white.opacity(0), location: 0.5),
                    .init(color: .black.opacity(0), location: 0.5), .init(color: .black, location: 1),
                ]), startPoint: .zero, endPoint: CGPoint(x: 0, y: t.height)))
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { escolher(cor(em: $0.location, tamanho), false) }
                .onEnded { escolher(cor(em: $0.location, tamanho), true) })
            .pointerStyle(.rectSelection)
        }
    }

    private func cor(em p: CGPoint, _ t: CGSize) -> CMYK {
        let x = min(max(p.x / max(t.width, 1), 0), 1), y = min(max(p.y / max(t.height, 1), 0), 1)
        return CMYK(hsl: [Int((x * 360).rounded()) % 360, 100, Int(((1 - y) * 100).rounded())])
    }
}
