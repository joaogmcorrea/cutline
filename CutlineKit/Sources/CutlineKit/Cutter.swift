// Cortadora Silhouette: estado, configuração (setup) e envio dos caminhos (plot).
// Porte da classe SilhouetteCameo de Graphtec.py (inkscape-silhouette, GPLv2). A ordem e o conteúdo
// dos comandos são os mesmos do driver Python — os testes comparam as transcrições byte a byte.
import CoreGraphics
import Foundation

public actor Cutter {
    public enum Status: Sendable, Equatable, CustomStringConvertible {
        case ready, moving, unloaded
        /// A máquina não respondeu ao pedido de estado.
        case noResponse
        case other(String)

        public var description: String {
            switch self {
            case .ready: "ready"
            case .moving: "moving"
            case .unloaded: "unloaded"
            case .noResponse: "sem resposta"
            case .other(let raw): raw
            }
        }
    }

    /// Onde a mídia para no fim: abaixo do desenho ou de volta à origem.
    public enum EndPosition: Sendable { case below, start }

    /// Marcas de registro (Print & Cut), em mm. `origin` = canto externo do quadrado;
    /// `width`/`length` = distância até o canto externo das cantoneiras.
    public struct Registration: Sendable, Equatable {
        public var originX: Double
        public var originY: Double
        public var width: Double
        public var length: Double
        /// Busca automática pelo sensor (TB123); falso = posicionamento manual (TB23).
        public var search: Bool
        /// 4 marcas (só Cameo 5 Alpha / Pro MK II).
        public var quad: Bool
        /// Comprimento das cantoneiras e espessura das marcas impressas (TB51/TB53).
        public var markLength: Double
        public var markThickness: Double

        public init(originX: Double = 15, originY: Double = 20, width: Double = 180, length: Double = 230,
                    search: Bool = true, quad: Bool = false, markLength: Double = 20, markThickness: Double = 0.5) {
            self.originX = originX
            self.originY = originY
            self.width = width
            self.length = length
            self.search = search
            self.quad = quad
            self.markLength = markLength
            self.markThickness = markThickness
        }
    }

    public struct SetupOptions: Sendable {
        /// Código de mídia do protocolo antigo (300 = "Custom": usa só os valores abaixo).
        public var media: Int? = 300
        public var speed: Int?
        public var pressure: Int?
        public var toolholder = 1
        public var pen = false
        public var cuttingMat: CuttingMat?
        public var sharpenCorners = false
        public var sharpenCornersStart = 0.1
        public var sharpenCornersEnd = 0.1
        public var autoblade = false
        public var depth: Int?
        public var swClipping = true
        public var clipFuzz = 0.05
        public var trackEnhancing: Bool? = false
        public var bladeDiameter = 0.9
        public var landscape: Bool? = false
        public var leftAligned: Bool?
        public var mediaWidth = 210.0
        public var mediaHeight = 297.0
        /// A partir da 2ª configuração do mesmo trabalho: só reenvia velocidade/força/lâmina.
        public var skipInit = false

        public init() {}
    }

    public struct PlotOptions: Sendable {
        public var mediaWidth = 210.0
        public var mediaHeight = 297.0
        public var marginTop: Double?
        public var marginLeft: Double?
        public var offset = CGPoint.zero
        public var endPaperOffset = 0.0
        public var endPosition = EndPosition.below
        public var registration: Registration?
        public var skipInit = false
        /// Não voltar à origem no fim (passadas extras e Print & Cut).
        public var skipReset = false

        public init() {}
    }

    /// Caixa dos pontos enviados (mm, antes do recorte à área da mídia).
    public struct BoundingBox: Sendable, Equatable {
        public var minX: Double?
        public var minY: Double?
        public var maxX: Double?
        public var maxY: Double?
        public var count = 0

        mutating func extend(_ x: Double, _ y: Double) {
            if minX.map({ x < $0 }) ?? true { minX = x }
            if maxX.map({ x > $0 }) ?? true { maxX = x }
            if maxY.map({ y > $0 }) ?? true { maxY = y }
            if minY.map({ y < $0 }) ?? true { minY = y }
        }
    }

    struct Clip {
        let minX, minY, maxX, maxY: Double
    }

    static let toolEmpty = 0
    static let toolAutoblade = 2

    public private(set) var hardware: Hardware
    public let transport: any CutterTransport
    public let isSimulated: Bool
    private var leftAligned: Bool
    private var swClipping = true
    private var clipFuzz = 0.05
    private var recording: Data?
    let log: @Sendable (String) -> Void

    /// Tudo o que foi enviado (comandos e consultas), como o `cmdfile` do driver Python.
    public var transcript: Data { recording ?? Data() }

    /// Recomeça a transcrição (um arquivo por trabalho).
    public func clearTranscript() {
        if recording != nil { recording = Data() }
    }

    public init(transport: any CutterTransport, hardware: Hardware, recordTranscript: Bool = true,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        let simulated = transport is SimulatedTransport
        self.transport = transport
        self.hardware = hardware
        self.isSimulated = simulated
        self.leftAligned = simulated || hardware.widthMM != nil
        self.recording = recordTranscript ? Data() : nil
        self.log = log
    }

    /// Sem máquina: grava os comandos que seriam enviados.
    public static func simulated(_ hardware: Hardware, log: @escaping @Sendable (String) -> Void = { _ in }) -> Cutter {
        Cutter(transport: SimulatedTransport(), hardware: hardware, log: log)
    }

    /// Procura as cortadoras ao alcance, sem conectar (para o usuário escolher quando houver mais de uma).
    public static func findBluetooth(timeout: TimeInterval = 15,
                                     log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> [DiscoveredCutter] {
        try await BLETransport.discover(timeout: timeout, log: log)
    }

    /// Procura a cortadora pelo nome anunciado (ou uma já encontrada, por `identifier`), conecta
    /// e identifica o modelo pelo firmware (FG).
    public static func connectBluetooth(name: String? = nil, identifier: UUID? = nil, timeout: TimeInterval = 20,
                                        attempts: Int = 2, recordTranscript: Bool = true,
                                        log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Cutter {
        var attempt = 1
        while true {
            do {
                let transport = try await BLETransport.connect(name: name, identifier: identifier,
                                                               timeout: timeout, log: log)
                let cutter = Cutter(transport: transport, hardware: .unknown("Unknown Bluetooth LE Graphtec device"),
                                    recordTranscript: recordTranscript, log: log)
                await cutter.identify()
                return cutter
            } catch {
                // A conexão às vezes cai no handshake; uma nova tentativa resolve.
                guard attempt < attempts, (error as? CutterError).map(Self.isRetryable) ?? true else { throw error }
                log("Bluetooth falhou (\(error.localizedDescription)); tentando de novo…")
                attempt += 1
                try await Task.sleep(for: .seconds(2))
            }
        }
    }

    private static func isRetryable(_ error: CutterError) -> Bool {
        switch error {
        case .bluetoothUnavailable, .ambiguous: false
        default: true
        }
    }

    /// Cortadoras ligadas no cabo USB agora (a busca é imediata e não precisa de permissão).
    public static func findUSB(log: @escaping @Sendable (String) -> Void = { _ in }) -> [DiscoveredCutter] {
        USBTransport.discover(log: log)
    }

    /// Conecta pelo cabo USB (a escolhida numa busca, por `identifier`, ou a única ligada). O modelo vem do
    /// product id do USB, como no driver Python.
    public static func connectUSB(identifier: UUID? = nil, recordTranscript: Bool = true,
                                  log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> Cutter {
        let transport = try await USBTransport.connect(identifier: identifier, log: log)
        let cutter = Cutter(transport: transport, hardware: transport.hardware, recordTranscript: recordTranscript, log: log)
        await cutter.identify(known: transport.hardware)
        return cutter
    }

    /// Lê o firmware (FG) e, sem `known`, deduz o modelo por ele.
    private func identify(known: Hardware? = nil) async {
        var model: String?
        do { model = try await firmwareVersion() } catch { log("Falha ao ler o firmware: \(error.localizedDescription)") }
        if let found = known ?? Hardware.match(firmware: model) {
            hardware = found
            leftAligned = found.widthMM != nil
            log("\(found.name) (firmware '\(model ?? "")') conectada em \(transport.location)")
        } else {
            let detail = model.map { " (\($0.trimmingCharacters(in: .whitespaces)))" } ?? ""
            hardware = .unknown("Unknown Bluetooth LE Graphtec device" + detail)
            log("Dispositivo não reconhecido (firmware '\(model ?? "None")') em \(transport.location)")
        }
    }

    public func close() async {
        await transport.close()
    }

    // MARK: Entrada e saída

    func write(_ data: Data, isQuery: Bool = false, timeout: TimeInterval = 10) async throws {
        recording?.append(data)
        if !isSimulated, let stale = try? await transport.read(maxLength: 64, timeout: 0.01), !stale.isEmpty {
            log("resposta antes de enviar \(Self.printable(data)): \(Self.printable(stale))")
        }
        do {
            try await transport.write(data, timeout: timeout)
        } catch let error as CutterError {
            throw error
        } catch {
            throw CutterError.writeFailed("\(data.count) bytes: \(error.localizedDescription)")
        }
    }

    func send(_ commands: [String], isQuery: Bool = false, timeout: TimeInterval = 10) async throws {
        try await write(GPGL.delimit(commands), isQuery: isQuery, timeout: timeout)
    }

    func send(_ command: String, isQuery: Bool = false, timeout: TimeInterval = 10) async throws {
        try await send([command], isQuery: isQuery, timeout: timeout)
    }

    func sendEscape(_ code: UInt8, isQuery: Bool = false) async throws {
        try await write(Data([GPGL.esc, code]), isQuery: isQuery)
    }

    func read(maxLength: Int = 64, timeout: TimeInterval = 5) async throws -> Data {
        try await transport.read(maxLength: maxLength, timeout: timeout)
    }

    /// Envia uma consulta e devolve a resposta sem o ETX (nil se não vier nada).
    func query(_ command: String, txTimeout: TimeInterval = 10, rxTimeout: TimeInterval = 1) async throws -> String? {
        try await send(command, isQuery: true, timeout: txTimeout)
        guard let response = try? await read(timeout: rxTimeout), response.count > 1 else { return nil }
        return String(decoding: response.dropLast(), as: UTF8.self)
    }

    /// Comandos longos vão em blocos de até 1 KB (como o Silhouette Studio), cortados no último ETX,
    /// esperando a máquina ficar pronta depois de cada bloco.
    func safeWrite(_ data: Data) async throws {
        let bytes = [UInt8](data)
        var start = 0
        while start < bytes.count {
            let end = min(start + 1024, bytes.count)
            guard let lastETX = bytes[start..<end].lastIndex(of: GPGL.etx) else {
                throw CutterError.writeFailed("comando maior que 1 KB")
            }
            try await write(Data(bytes[start...lastETX]))
            try await waitForReady(timeout: 120, pollInterval: 0.05)
            start = lastETX + 1
        }
    }

    func safeSend(_ commands: [String]) async throws {
        let data = GPGL.delimit(commands)
        guard !data.isEmpty else { return }
        try await safeWrite(data)
    }

    public static func printable(_ data: Data) -> String {
        data.map { byte in
            switch byte {
            case GPGL.etx: "␃"
            case GPGL.esc: "␛"
            case 0x20..<0x7F: String(UnicodeScalar(byte))
            default: String(format: "\\x%02x", byte)
            }
        }.joined()
    }

    // MARK: Consultas

    public func status() async throws -> Status {
        try await sendEscape(GPGL.enq, isQuery: true)
        let response: Data
        do {
            response = try await read(timeout: 5)
        } catch CutterError.timeout {
            log("sem resposta ao pedido de estado")
            return .noResponse
        }
        guard response.last == GPGL.etx else { throw CutterError.badResponse(Self.printable(response)) }
        let body = String(decoding: response.dropLast(), as: UTF8.self)
        switch body {
        case "0": return .ready
        case "1": return .moving
        case "2": return .unloaded
        default: return .other(body)
        }
    }

    public func firmwareVersion() async throws -> String? {
        try await query("FG", rxTimeout: 10)
    }

    /// Ferramentas instaladas (só Cameo 4 em diante), ex.: "2,0".
    public func toolSetup() async throws -> String? {
        guard hardware.isCameo4Line else { return nil }
        try await sendEscape(GPGL.nak, isQuery: true)
        guard let response = try? await read(timeout: 1), response.count > 1 else { return nil }
        return String(decoding: response.dropLast(), as: UTF8.self)
    }

    @discardableResult
    public func waitForReady(timeout: TimeInterval = 30, pollInterval: TimeInterval = 2) async throws -> Status {
        var state = try await status()
        if isSimulated { return state }
        let polls = Int(timeout / pollInterval)
        var poll = 1
        while poll < polls, state != .ready {
            if state == .unloaded, poll == 1 { log("carregue a base…") }
            try await Task.sleep(for: .seconds(pollInterval))
            state = try await status()
            poll += 1
        }
        return state
    }

    // MARK: Configuração

    func initialize() async throws {
        try await sendEscape(GPGL.eot)
        let version = try await firmwareVersion()
        log("Versão do firmware: '\(version ?? "None")'")
        if hardware.isCameo3On {
            // Calibração do sensor de marcas e dos rolos (o Studio também pergunta).
            if let response = try await query("TB71") { log("TB71: '\(response)'") }
            if let response = try await query("FA") { log("FA: '\(response)'") }
        }
        if hardware.isCameo3, let response = try await query("TC") { log("TC: '\(response)'") }
    }

    func setBoundary(top: Int, left: Int, bottom: Int, right: Int) async throws {
        try await send(["\\\(top),\(left)", "Z\(bottom),\(right)"])
    }

    /// Base de corte (só Cameo 3 em diante).
    func setCuttingMat(_ mat: CuttingMat?, mediaWidth: Double, mediaHeight: Double) async throws {
        guard hardware.isCameo3On else { return }
        let mat = (mat ?? CuttingMat.none).resolved(for: hardware)
        try await send("TG" + mat.code)
        // FN0 = reset; TB50,0 = modo retrato
        try await send(["FN0", "TB50,0"])
        if let size = mat.sizeInches {
            try await setBoundary(top: 0, left: 0, bottom: GPGL.su(inch: size.length), right: GPGL.su(inch: size.width))
        } else {
            try await setBoundary(top: 0, left: 0, bottom: GPGL.su(mm: hardware.lengthMM ?? mediaHeight),
                                  right: GPGL.su(mm: hardware.widthMM ?? mediaWidth))
        }
    }

    public func setup(_ options: SetupOptions) async throws {
        let o = options
        if let leftAligned = o.leftAligned { self.leftAligned = leftAligned }

        if !o.skipInit {
            try await initialize()
            try await setCuttingMat(o.cuttingMat, mediaWidth: o.mediaWidth, mediaHeight: o.mediaHeight)
        }
        if let media = o.media, !hardware.isCameo3On, !o.skipInit {
            try await send("FW\(media < 100 || media > 300 ? 300 : media)")
        }

        let tool = Tool(holder: o.toolholder)
        let currentTool: Int? = try await toolSetup().flatMap { setup in
            let parts = setup.split(separator: ",", omittingEmptySubsequences: false)
            guard o.toolholder - 1 < parts.count else { return nil }
            return Int(parts[o.toolholder - 1].trimmingCharacters(in: .whitespaces))
        }
        if hardware.hasTwoTools { try await send(tool.select) }
        log("porta-ferramenta: \(o.toolholder)")

        // Cantos vivos: início e fim vão em décimos de milímetro, não em SU.
        let sharpen = o.pen
            ? tool.sharpenCorners(start: 0, end: 0)
            : tool.sharpenCorners(start: Int((o.sharpenCornersStart + 0.05) * 10.0),
                                  end: Int((o.sharpenCornersEnd + 0.05) * 10.0))

        if hardware.isCameo4Line {
            // A Cameo 4 recebe força, aceleração e offset duas vezes (reproduzindo o Studio).
            if let pressure = o.pressure {
                let value = min(pressure, hardware.maxPressure ?? 33)
                try await send(tool.pressure(value))
                log("força: \(value)")
                try await send(GPGL.acceleration(0))
            }
            if let speed = o.speed {
                let value = max(1, min(30, speed))
                try await send(tool.speed(value))
                log("velocidade: \(value)")
            }
            try await send(tool.cutterOffset(xmm: 0, ymm: 0.05))
            try await send(tool.lift(o.sharpenCorners))
            try await send(sharpen)
            if let pressure = o.pressure {
                let value = max(1, min(33, pressure))
                try await send(tool.pressure(value))
                try await send(GPGL.acceleration(3))
            }
            try await send(tool.cutterOffset(xmm: o.pen ? 0 : o.bladeDiameter, ymm: 0.05))
        } else {
            if let speed = o.speed {
                let value = max(1, min(10, speed))
                try await send(hardware.isCameo3 ? tool.speed(value) : "!\(value)")
                log("velocidade: \(value)")
            }
            if let pressure = o.pressure {
                let value = max(1, min(33, pressure))
                try await send(hardware.isCameo3 ? tool.pressure(value) : "FX\(value)")
                log("força: \(value)")
            }
            if hardware.isCameo3, o.pen { try await send(tool.cutterOffset(xmm: 0, ymm: 0.05)) }
            log(leftAligned ? "Mídia alinhada à esquerda." : "Mídia alinhada à direita.")
            if hardware.isCameo3 {
                try await send(tool.lift(o.sharpenCorners))
                try await send(sharpen)
                if !o.pen {
                    try await send([tool.cutterOffset(xmm: 0, ymm: 0.05),
                                    tool.cutterOffset(xmm: o.bladeDiameter, ymm: 0.05)])
                }
            } else {
                // Diâmetro do círculo que reorienta a lâmina nos cantos (0 para caneta).
                try await send(o.pen ? "FC0" : "FC\(GPGL.su(mm: o.bladeDiameter))")
            }
        }

        if hardware.isCameo3On, o.autoblade, let depth = o.depth {
            if let current = currentTool, current != Self.toolAutoblade, current != Self.toolEmpty {
                log("Esperava uma AutoBlade, encontrei a ferramenta \(current). Lâmina não ajustada.")
            } else if o.toolholder != 1 {
                log("A AutoBlade só ajusta no porta-ferramenta 1, não no \(o.toolholder).")
            } else {
                let value = max(0, min(10, depth))
                try await send(tool.depth(value))
                log("lâmina: \(value)")
            }
        }

        swClipping = o.swClipping
        clipFuzz = o.clipFuzz

        // Reforço de tração: rolos 3× para a frente e para trás (precisa de força ≥ 19).
        if let trackEnhancing = o.trackEnhancing, !o.skipInit {
            if trackEnhancing {
                try await send("FY0")
            } else if !hardware.isCameo3On {
                try await send("FY1")
            }
        }

        if !o.skipInit, !hardware.isCameo3On {
            if let landscape = o.landscape { try await send(["FN0", landscape ? "TB50,1" : "TB50,0"]) }
            // Não levantar a ferramenta entre caminhos.
            try await send("FE0,0")
        }
    }

    // MARK: Corte

    /// Envia os caminhos (mm). Cada caminho é cortado de uma vez; entre caminhos a ferramenta sobe.
    @discardableResult
    public func plot(_ paths: [[CGPoint]], _ options: PlotOptions = PlotOptions()) async throws -> BoundingBox {
        let o = options
        let top = o.marginTop ?? hardware.marginTopMM ?? 0
        let left = o.marginLeft ?? hardware.marginLeftMM ?? 0
        var mediaWidth = o.mediaWidth
        if leftAligned, let width = hardware.widthMM { mediaWidth = width }
        log("área: (\(left), \(top)) – (\(mediaWidth), \(o.mediaHeight)) mm")

        var width = max(mediaWidth, left)
        var height = max(o.mediaHeight, top)
        var offsetX = Double(o.offset.x)
        var offsetY = Double(o.offset.y)

        if let reg = o.registration {
            // Depois do registro, (0, 0) é o canto da marca: compensa a posição dela na página
            // e limita a área ao espaço entre as marcas.
            offsetX -= reg.originX
            offsetY -= reg.originY
            height = reg.length
            width = reg.width

            if !o.skipInit {
                try await send("TB50,0")
                try await send("TB99")
                try await send("TB52,2")    // tipo de marca: 2 = Cameo/Portrait
                try await send("TB51,\(GPGL.su(mm: reg.markLength))")      // comprimento das marcas (20 mm = 400)
                try await send("TB53,\(GPGL.su(mm: reg.markThickness))")   // espessura das marcas (0,5 mm = 10)
                try await send("TB55,1")
                if reg.search {
                    // busca automática, com 10 mm de folga
                    try await send(GPGL.automaticRegmarkTest(height: reg.length, width: reg.width,
                                                             top: max(reg.originY - 10, 0),
                                                             left: max(reg.originX - 10, 0),
                                                             quad: hardware.quadRegmarks && reg.quad))
                } else {
                    try await send(GPGL.manualRegmark(height: reg.length, width: reg.width))
                }
                let response = try? await read(timeout: 40)
                guard response == Data("    0".utf8) + [GPGL.etx] else {
                    throw CutterError.registrationMarksNotFound(response.map(Self.printable) ?? localized("sem resposta"))
                }
            }
        }

        if !hardware.isCameo3On, !o.skipInit {
            try await send([GPGL.upperLeft(y: 0, x: 0), GPGL.lowerRight(y: height, x: width), "L0", "FE0,0", "FF0,0,0"])
        }

        let clip = Clip(minX: left, minY: top, maxX: width, maxY: height)
        let (commands, bbox) = plotCommands(paths, clip: clip, offsetX: offsetX, offsetY: offsetY)
        try await safeSend(commands)

        let home: [String] = switch o.endPosition {
        case .start:
            hardware.isCameo3On
                ? ["L0", GPGL.upperLeft(y: 0, x: 0), GPGL.move(y: 0, x: 0), "J0", "FN0", "TB50,0"]
                : ["H"]
        case .below:
            [GPGL.move(y: (bbox.maxY ?? 0) + o.endPaperOffset, x: 0), "SO0"]
        }
        if !o.skipReset { try await send(home) }
        return bbox
    }

    func plotCommands(_ paths: [[CGPoint]], clip: Clip, offsetX: Double, offsetY: Double) -> ([String], BoundingBox) {
        let xOffset = offsetX + clip.minX
        let yOffset = offsetY + clip.minY
        var bbox = BoundingBox()
        var commands: [String] = []
        var lastInside = true
        for path in paths where path.count >= 2 {
            let x0 = Double(path[0].x) + xOffset
            let y0 = Double(path[0].y) + yOffset
            bbox.extend(x0, y0)
            bbox.count += 1
            let first = clipPoint(x0, y0, clip)
            lastInside = first.inside
            commands.append(GPGL.move(y: first.y, x: first.x))

            for point in path.dropFirst() {
                let x = Double(point.x) + xOffset
                let y = Double(point.y) + yOffset
                bbox.extend(x, y)
                bbox.count += 1
                let p = clipPoint(x, y, clip)
                // Fora da área só move, sem cortar.
                commands.append(!swClipping || (p.inside && lastInside) ? GPGL.draw(y: p.y, x: p.x) : GPGL.move(y: p.y, x: p.x))
                lastInside = p.inside
            }
        }
        return (commands, bbox)
    }

    func clipPoint(_ x: Double, _ y: Double, _ clip: Clip) -> (x: Double, y: Double, inside: Bool) {
        var x = x, y = y, inside = true
        if clip.minX - x > clipFuzz { x = clip.minX; inside = false }
        if x - clip.maxX > clipFuzz { x = clip.maxX; inside = false }
        if clip.minY - y > clipFuzz { y = clip.minY; inside = false }
        if y - clip.maxY > clipFuzz { y = clip.maxY; inside = false }
        return (x, y, inside)
    }
}
