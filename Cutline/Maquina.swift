// Conexão com a cortadora (cabo USB ou Bluetooth LE, via CutlineKit) e fila de trabalhos.
// Uma operação por vez: o Cutter não aceita comandos em paralelo, e a fila só manda o próximo trabalho
// quando a máquina avisa que terminou o anterior. Com o Silhouette Studio aberto, nada conecta nem corta:
// os dois não conseguem usar a cortadora ao mesmo tempo.
import AppKit
import Foundation
import Observation
import CutlineKit

/// Um envio na fila: a máquina corta um por vez, na ordem de chegada.
struct Trabalho: Identifiable {
    enum Situacao: Equatable {
        case aguardando
        case cortando(String)
        case feito
        /// A fila para aqui até o usuário tentar de novo ou tirar o trabalho da fila.
        case erro(String)
        /// Print & Cut: a máquina não achou as marcas (nada foi cortado).
        case marcasNaoEncontradas

        var parou: Bool {
            switch self {
            case .erro, .marcasNaoEncontradas: true
            default: false
            }
        }
    }

    let id = UUID()
    /// Nome do documento.
    let nome: String
    /// Documento de onde veio (o aviso das marcas abre na janela dele).
    let origem: ObjectIdentifier
    let camadas: [CutLayer]
    let registro: Cutter.Registration?
    let comBase: Bool
    /// A base escolhida (nil = a padrão da máquina).
    var base: CuttingMat? = nil
    var situacao = Situacao.aguardando
}

@Observable
final class Maquina {
    enum Estado: Equatable {
        case desconectada
        case conectando
        /// Mais de uma cortadora ao alcance e nenhuma usada antes: o usuário escolhe.
        case escolher([DiscoveredCutter])
        case conectada
        case enviando(String)
        case enviado
        case erro(String)
    }

    private(set) var estado = Estado.desconectada
    private(set) var info: MachineInfo?
    /// Últimas mensagens do driver (para diagnóstico).
    private(set) var registro: [String] = []
    /// Cortadoras vistas na última busca (para trocar quando houver mais de uma).
    private(set) var encontradas: [DiscoveredCutter] = []
    /// A cortadora conectada (ou a última usada).
    private(set) var atual: DiscoveredCutter?

    /// Trabalhos enviados nesta sessão: aguardando, cortando e os já terminados (até limpar).
    private(set) var fila: [Trabalho] = []

    /// Silhouette Studio aberto (ele ou o Bluetooth dele): enquanto estiver, o Cutline não conecta nem envia.
    private(set) var studioAberto = false

    private var cortadora: Cutter?
    private var ocupada = false
    private var processando = false
    /// Alguém quis a máquina (ou ela estava conectada) enquanto o Studio estava aberto: conecta quando ele fechar.
    private var conectarDepoisDoStudio = false
    @ObservationIgnored private var observadoresStudio: [NSObjectProtocol] = []

    #if DEBUG
    /// CUTLINE_SIMULAR=1: sem máquina, como o `--simular` do teste.
    private let simular = ProcessInfo.processInfo.environment["CUTLINE_SIMULAR"] != nil
    #else
    private let simular = false
    #endif

    /// "Silhouette_Portrait4" → "Portrait 4".
    var nomeModelo: String {
        guard let nome = info?.model else { return "Silhouette" }
        return nome.replacingOccurrences(of: "Silhouette_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"([A-Za-z])(\d)"#, with: "$1 $2", options: .regularExpression)
    }

    /// "Portrait 4 V1.05" → "Firmware 1.05".
    var firmware: String? {
        guard let texto = info?.firmware, let v = texto.range(of: #"V[\d.]+"#, options: .regularExpression) else { return nil }
        return "Firmware " + texto[v].dropFirst()
    }

    var velocidadeMaxima: Int { info?.maxSpeed ?? 30 }

    /// O modelo conectado (ou o último usado); sem nenhum, a Portrait 4 (as bases do painel Página seguem ele).
    var hardware: Hardware {
        info.flatMap { Hardware.named($0.model) } ?? Hardware.match(atual) ?? .portrait4
    }

    init() {
        atual = Self.ultima
        vigiarStudio()
    }

    /// Conecta (se preciso) e lê modelo, firmware e estado. Com `escolhida`, troca para ela.
    func conectar(_ escolhida: DiscoveredCutter? = nil) async {
        guard !studioAberto else {
            conectarDepoisDoStudio = true
            return
        }
        guard !ocupada else { return }
        ocupada = true
        defer {
            ocupada = false
            // A fila pode ter esperado pela conexão (ou pela escolha da máquina).
            Task { await processar() }
        }
        if let escolhida, escolhida != atual || cortadora == nil {
            await cortadora?.close()
            cortadora = nil
            info = nil
        }
        estado = .conectando
        do {
            let cortadora = try await cortadoraConectada(escolhida)
            info = try await cortadora.info()
            estado = .conectada
        } catch MaquinaError.escolher(let lista) {
            estado = .escolher(lista)
        } catch {
            await falhou(error)
        }
    }

    // MARK: Fila

    /// Põe o trabalho na fila; começa na hora se a máquina estiver livre. Com `registro` (Print & Cut), a
    /// máquina lê as marcas da folha impressa antes do primeiro corte.
    func enfileirar(_ trabalho: Trabalho) {
        guard !trabalho.camadas.isEmpty else { return }
        fila.append(trabalho)
        Task { await processar() }
    }

    /// Tira da fila (o que está cortando não sai: a máquina já recebeu os comandos).
    func remover(_ id: Trabalho.ID) {
        fila.removeAll { $0.id == id && !$0.emAndamento }
        Task { await processar() }
    }

    /// Volta o trabalho parado para a fila (no mesmo lugar: é o primeiro a sair).
    func tentarDeNovo(_ id: Trabalho.ID) {
        guard let i = fila.firstIndex(where: { $0.id == id }), fila[i].situacao.parou else { return }
        fila[i].situacao = .aguardando
        Task { await processar() }
    }

    func limparConcluidos() { fila.removeAll { $0.situacao == .feito } }

    /// O trabalho que parou a fila (erro ou marcas não encontradas), se houver.
    var parada: Trabalho? { fila.first { $0.situacao.parou } }

    /// Quantos trabalhos saem antes deste (0 = é o próximo ou já está cortando).
    func naFrente(de id: Trabalho.ID) -> Int {
        let ativos = fila.filter { $0.situacao == .aguardando || $0.emAndamento }
        return ativos.firstIndex { $0.id == id } ?? 0
    }

    /// Aguardando ou cortando.
    var pendentes: Int { fila.filter { $0.situacao == .aguardando || $0.emAndamento }.count }

    /// Manda os trabalhos que estão aguardando, um por vez; para no primeiro que der erro.
    private func processar() async {
        guard !processando else { return }
        processando = true
        defer { processando = false }
        while !ocupada, !studioAberto, parada == nil, let proximo = fila.first(where: { $0.situacao == .aguardando }) {
            guard await cortar(proximo) else { break }
        }
        // O Studio abriu durante um corte: terminado o corte, a máquina fica livre para ele.
        if studioAberto, !ocupada { await soltar() }
    }

    /// Corta um trabalho. Falso = a fila precisa esperar o usuário (escolher a máquina).
    private func cortar(_ trabalho: Trabalho) async -> Bool {
        ocupada = true
        defer { ocupada = false }
        let id = trabalho.id
        do {
            if cortadora == nil { estado = .conectando }
            let cortadora = try await cortadoraConectada(nil)
            mostrar(String(localized: "Verificando a máquina…"), id)
            await cortadora.clearTranscript()
            var info = try await cortadora.info()
            // Ainda cortando um trabalho anterior (que ficou na memória da máquina): espera ela terminar
            // antes de mandar outro.
            if info.status == .moving, !simular {
                mostrar(String(localized: "Esperando a máquina terminar o trabalho anterior…"), id)
                _ = try await cortadora.waitForReady(timeout: 600)
                info = try await cortadora.info()
            }
            self.info = info
            guard info.status != .unloaded || simular else {
                let texto = trabalho.comBase ? String(localized: "Carregue a base na máquina e tente de novo.")
                    : String(localized: "Carregue a folha na máquina e tente de novo.")
                situacao(.erro(texto), id)
                estado = .conectada
                return true
            }
            #if DEBUG
            if trabalho.registro != nil, Depuracao.marcasFalham { throw CutterError.registrationMarksNotFound("simulado") }
            #endif
            try await cortadora.cut(trabalho.camadas, info: info, registration: trabalho.registro,
                                    cuttingMat: trabalho.comBase, mat: trabalho.base) { [weak self] progresso in
                let cor = progresso.passCount > 1
                    ? String(localized: "cor \(progresso.layer) de \(progresso.layerCount) — passada \(progresso.pass) de \(progresso.passCount)")
                    : String(localized: "cor \(progresso.layer) de \(progresso.layerCount)")
                // A leitura das marcas (até ~40 s) vem logo antes do primeiro corte.
                let marcas = trabalho.registro != nil && progresso.layer == 1 && progresso.pass == 1
                let texto = marcas ? String(localized: "Lendo as marcas de registro e cortando \(cor)…") : String(localized: "Cortando \(cor)…")
                Task { @MainActor in self?.mostrar(texto, id) }
            }
            situacao(.feito, id)
            estado = .enviado
        } catch MaquinaError.escolher(let lista) {
            situacao(.aguardando, id)
            estado = .escolher(lista)
            return false
        } catch CutterError.registrationMarksNotFound(_) {
            // A conexão continua boa: o aviso fica no trabalho (e na janela das dicas).
            situacao(.marcasNaoEncontradas, id)
            estado = .conectada
        } catch {
            situacao(.erro(error.localizedDescription), id)
            await falhou(error)
        }
        await gravarTranscricao()
        return true
    }

    private func mostrar(_ texto: String, _ id: Trabalho.ID) {
        estado = .enviando(texto)
        situacao(.cortando(texto), id)
    }

    private func situacao(_ nova: Trabalho.Situacao, _ id: Trabalho.ID) {
        if let i = fila.firstIndex(where: { $0.id == id }) { fila[i].situacao = nova }
    }

    private enum MaquinaError: Error {
        case escolher([DiscoveredCutter])
    }

    /// A conexão atual, ou uma nova: a escolhida; senão a única ao alcance; senão a última usada;
    /// senão pede para o usuário escolher.
    private func cortadoraConectada(_ escolhida: DiscoveredCutter?) async throws -> Cutter {
        if let cortadora { return cortadora }
        let log: @Sendable (String) -> Void = { [weak self] linha in
            Task { @MainActor in self?.anotar(linha) }
        }
        let alvo: DiscoveredCutter
        if let escolhida {
            alvo = escolhida
        } else {
            let lista = try await buscar(log: log)
            encontradas = lista
            if lista.count == 1 {
                alvo = lista[0]
            } else if let ultima = lista.first(where: { $0.id == Self.ultima?.id }) {
                alvo = ultima
            } else {
                throw MaquinaError.escolher(lista)
            }
        }
        let nova = simular ? Cutter.simulated(.portrait4, log: log)
            : alvo.link == .usb ? try await Cutter.connectUSB(identifier: alvo.id, log: log)
            : try await Cutter.connectBluetooth(identifier: alvo.id, log: log)
        cortadora = nova
        atual = alvo
        if !simular { Self.ultima = alvo }
        return nova
    }

    private func buscar(log: @escaping @Sendable (String) -> Void) async throws -> [DiscoveredCutter] {
        #if DEBUG
        // CUTLINE_SIMULAR=2: duas máquinas simuladas, para ver a escolha.
        if simular {
            let duas = ProcessInfo.processInfo.environment["CUTLINE_SIMULAR"] == "2"
            let nomes = duas ? ["Portrait 4-0000001", "Portrait 4-0000002"] : ["Portrait 4-0000001"]
            return nomes.enumerated().map {
                DiscoveredCutter(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\($0.offset + 1)")!, name: $0.element)
            }
        }
        #endif
        // Máquina no cabo: usa o USB (a busca é imediata e não depende do Bluetooth) e nem procura no Bluetooth.
        let usb = Cutter.findUSB(log: log)
        if !usb.isEmpty { return usb }
        return try await Cutter.findBluetooth(log: log)
    }

    /// Última cortadora usada neste Mac (UserDefaults).
    private static var ultima: DiscoveredCutter? {
        get {
            UserDefaults.standard.data(forKey: "ultimaMaquina").flatMap { try? JSONDecoder().decode(DiscoveredCutter.self, from: $0) }
        }
        set {
            UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "ultimaMaquina")
        }
    }

    private func falhou(_ erro: Error) async {
        // Erros do trabalho (base, ajustes, limites) mantêm a conexão — a mensagem fica no trabalho da fila;
        // os demais derrubam a conexão, para conectar de novo na próxima vez.
        let doTrabalho: Bool = switch erro as? CutterError {
        case .mediaNotLoaded, .invalidSettings, .outOfBounds, .registrationMarksNotFound: true
        default: false
        }
        estado = doTrabalho && cortadora != nil ? .conectada : .erro(erro.localizedDescription)
        if !doTrabalho {
            await cortadora?.close()
            cortadora = nil
        }
    }

    // MARK: Silhouette Studio

    /// O Studio e o Bluetooth dele (ss_bluetooth, srt_helper) moram dentro de "Silhouette Studio.app"; os
    /// ajudantes têm identificadores genéricos, então também vale o caminho do app.
    nonisolated private static func ehDoStudio(_ app: NSRunningApplication) -> Bool {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        let id = app.bundleIdentifier ?? ""
        return id.hasPrefix("com.silhouettesoftware.") || id.hasPrefix("com.aspexsoftware.")
            || app.bundleURL?.path.contains("/Silhouette Studio") == true
    }

    nonisolated private static var processosDoStudio: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter(ehDoStudio)
    }

    /// CUTLINE_TESTE_IGNORAR_STUDIO=1 finge que o Studio está fechado (testar o envio simulado com ele aberto).
    nonisolated private static var studioRodando: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CUTLINE_TESTE_IGNORAR_STUDIO"] != nil { return false }
        #endif
        return !processosDoStudio.isEmpty
    }

    /// Acompanha o Studio abrir e fechar enquanto o Cutline está aberto.
    private func vigiarStudio() {
        studioAberto = Self.studioRodando
        let centro = NSWorkspace.shared.notificationCenter
        observadoresStudio = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map { nome in
            centro.addObserver(forName: nome, object: nil, queue: .main) { [weak self] aviso in
                guard let app = aviso.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      Self.ehDoStudio(app) else { return }
                MainActor.assumeIsolated { self?.studioMudou() }
            }
        }
    }

    private func studioMudou() {
        let aberto = Self.studioRodando
        guard aberto != studioAberto else { return }
        studioAberto = aberto
        if aberto {
            // Livre, a máquina fica para o Studio; cortando, termina o corte antes (em `processar`).
            if cortadora != nil { conectarDepoisDoStudio = true }
            if !ocupada { Task { await soltar() } }
        } else if conectarDepoisDoStudio || pendentes > 0 {
            conectarDepoisDoStudio = false
            // O Bluetooth do Studio leva um instante para largar a máquina.
            Task {
                try? await Task.sleep(for: .seconds(2))
                await conectar()
            }
        }
    }

    /// Fecha a conexão para o Studio poder usar a máquina.
    private func soltar() async {
        guard cortadora != nil else { return }
        await cortadora?.close()
        cortadora = nil
        info = nil
        estado = .desconectada
    }

    /// Botão "Fechar o Silhouette Studio": pede para ele sair, como o ⌘Q dele (se houver algo sem salvar, o
    /// próprio Studio pergunta). Os ajudantes saem junto; se algum ficar para trás, um segundo clique o fecha.
    func fecharStudio() {
        let processos = Self.processosDoStudio
        let principais = processos.filter { !($0.bundleURL?.path.contains(".app/Contents/") ?? false) }
        for app in principais.isEmpty ? processos : principais { app.terminate() }
    }

    private func anotar(_ linha: String) {
        registro.append(linha)
        if registro.count > 300 { registro.removeFirst(registro.count - 300) }
    }

    /// Transcrição dos comandos enviados em ~/Library/Logs/Cutline (como os logs/*.gpgl do teste).
    private func gravarTranscricao() async {
        guard let cortadora else { return }
        let dados = await cortadora.transcript
        guard !dados.isEmpty else { return }
        let pasta = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Cutline")
        let formato = DateFormatter()
        formato.dateFormat = "yyyyMMdd-HHmmss"
        let nome = formato.string(from: Date()) + (simular ? "-simulado" : "") + ".gpgl"
        try? FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
        try? dados.write(to: pasta.appending(path: nome))
    }
}

extension Trabalho {
    var emAndamento: Bool { if case .cortando = situacao { true } else { false } }
}
