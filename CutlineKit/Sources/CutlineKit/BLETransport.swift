// Fluxo de bytes GPGL pelo serviço GATT da Silhouette (Bluetooth LE).
// Porte de BLETransport.py (inkscape-silhouette, GPLv2): mesmos UUIDs, handshake e pacotes de 20 bytes.
import CoreBluetooth
import Foundation

/// Cortadora vista na busca, antes de conectar.
public struct DiscoveredCutter: Sendable, Hashable, Identifiable, Codable {
    public enum Link: String, Sendable, Codable { case bluetooth, usb }

    /// Identificador do periférico neste Mac (estável entre as buscas).
    public let id: UUID
    /// Nome anunciado: modelo + "-" + número de série ("Portrait 4-0000001"); no USB, montado igual.
    public let name: String
    public let link: Link

    public init(id: UUID, name: String, link: Link = .bluetooth) {
        self.id = id
        self.name = name
        self.link = link
    }

    // A última máquina gravada antes do USB não tem `link`: era Bluetooth.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        link = try container.decodeIfPresent(Link.self, forKey: .link) ?? .bluetooth
    }

    /// "Portrait 4".
    public var model: String {
        String(name.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)[0])
            .trimmingCharacters(in: .whitespaces)
    }

    /// Número de série da máquina (o mesmo do USB), se o nome tiver.
    public var serial: String? {
        let parts = name.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let serial = parts[1].trimmingCharacters(in: .whitespaces)
        return serial.isEmpty ? nil : serial
    }
}

public final class BLETransport: NSObject, CutterTransport, @unchecked Sendable {
    nonisolated(unsafe) static let serviceUUID = CBUUID(string: "E2088282-4FDE-42F9-BB22-6EC3C7ED8F91")
    nonisolated(unsafe) static let writeUUID = CBUUID(string: "6D92661D-F429-4D67-929B-28E7A9780912")
    /// Respostas às consultas chegam aqui.
    nonisolated(unsafe) static let readUUID = CBUUID(string: "8DCF199A-30E7-4BD4-BEB6-BEB57DCA866C")
    /// Eventos de movimento ("1␃", "0␃") — ignorados, para não se misturarem às respostas.
    nonisolated(unsafe) static let controlUUID = CBUUID(string: "61490654-B5B4-458C-A867-9E15BC1471E0")

    static let initBytes = Data([GPGL.esc, GPGL.eot])
    static let chunkSize = 20
    static let handshakeSettle: TimeInterval = 1
    static let backpressureRetries = 3
    static let backpressureDelay: TimeInterval = 0.1
    /// Depois da primeira cortadora encontrada, continua ouvindo um pouco para notar uma segunda.
    static let discoveryGrace: TimeInterval = 2

    private enum Phase { case idle, poweringOn, scanning, connecting, discovering, subscribing, writing, closing }

    /// As três características do serviço (enum para poder ser capturado entre filas).
    private enum Channel {
        case write, read, control
        var uuid: CBUUID {
            switch self {
            case .write: BLETransport.writeUUID
            case .read: BLETransport.readUUID
            case .control: BLETransport.controlUUID
            }
        }
    }

    private struct Found {
        let peripheral: CBPeripheral
        let name: String
        let advertisesService: Bool
    }

    private struct Reader {
        let continuation: CheckedContinuation<Data, Error>
        let maxLength: Int
        let timeout: DispatchWorkItem
    }

    // Todo o estado abaixo só é tocado na fila `queue`, onde o CoreBluetooth entrega os callbacks.
    private let queue = DispatchQueue(label: "cutline.bluetooth")
    private let log: @Sendable (String) -> Void
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var incoming = Data()
    private var connected = false

    // Uma operação por vez (o driver é sequencial).
    private var phase = Phase.idle
    private var waiter: CheckedContinuation<Void, Error>?
    private var waiterTimeout: DispatchWorkItem?
    private var reader: Reader?

    private var scanFilter: (@Sendable (String) -> Bool)?
    /// Só aceita este periférico (uma cortadora escolhida numa busca anterior).
    private var wantedIdentifier: UUID?
    /// Ao fim da busca, escolhe a única cortadora (conectar) ou só guarda a lista (`discover`).
    private var pickOne = true
    private var found: [UUID: Found] = [:]
    private var graceTimer: DispatchWorkItem?
    private var notifyPending: Set<CBUUID> = []

    public private(set) var location = "bluetooth-le (não conectado)"

    private init(log: @escaping @Sendable (String) -> Void) {
        self.log = log
    }

    /// Procura (pelo nome anunciado), conecta, assina as notificações e faz o handshake.
    /// Sem `name`, aceita qualquer modelo da tabela de `Hardware`; com `identifier`, só aquela cortadora.
    public static func connect(name: String? = nil, identifier: UUID? = nil, timeout: TimeInterval = 20,
                               log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> BLETransport {
        let transport = BLETransport(log: log)
        do {
            try await transport.powerOn()
            try await transport.scan(name: name, identifier: identifier, pickOne: true, timeout: timeout)
            try await transport.connectPeripheral(timeout: timeout)
            try await transport.discover(timeout: timeout)
            try await transport.subscribe(timeout: timeout)
            for channel in [Channel.control, .read, .write] {
                try await transport.writeValue(initBytes, to: channel, timeout: timeout)
            }
            try await Task.sleep(for: .seconds(handshakeSettle))
            transport.queue.sync { transport.incoming.removeAll() }
            return transport
        } catch {
            await transport.close()
            throw error
        }
    }

    /// Procura as cortadoras ao alcance sem conectar. Termina um pouco depois da primeira encontrada.
    public static func discover(timeout: TimeInterval = 15,
                                log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> [DiscoveredCutter] {
        let transport = BLETransport(log: log)
        do {
            try await transport.powerOn()
            try await transport.scan(name: nil, identifier: nil, pickOne: false, timeout: timeout)
        } catch {
            await transport.close()
            throw error
        }
        await transport.close()
        return transport.queue.sync {
            transport.candidates()
                .map { DiscoveredCutter(id: $0.peripheral.identifier, name: $0.name) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    // MARK: CutterTransport

    public func write(_ data: Data, timeout: TimeInterval) async throws {
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + Self.chunkSize, bytes.count)
            try await writeValue(Data(bytes[offset..<end]), to: .write, timeout: timeout)
            offset = end
        }
    }

    public func read(maxLength: Int, timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            queue.async { [self] in
                if let data = takeReply(maxLength) {
                    continuation.resume(returning: data)
                    return
                }
                guard connected else {
                    continuation.resume(throwing: CutterError.disconnected)
                    return
                }
                let item = DispatchWorkItem { [self] in
                    guard let pending = reader else { return }
                    reader = nil
                    if incoming.isEmpty {
                        pending.continuation.resume(throwing: CutterError.timeout)
                    } else {
                        pending.continuation.resume(returning: pop(min(pending.maxLength, incoming.count)))
                    }
                }
                reader = Reader(continuation: continuation, maxLength: maxLength, timeout: item)
                queue.asyncAfter(deadline: .now() + timeout, execute: item)
            }
        }
    }

    public func close() async {
        let isConnected = queue.sync { connected }
        guard isConnected else {
            queue.sync { if central?.state == .poweredOn { central?.stopScan() } }
            return
        }
        try? await step(.closing, timeout: 5) { [self] in
            if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        }
    }

    // MARK: Etapas da conexão

    private func powerOn() async throws {
        try await step(.poweringOn, timeout: 10) { [self] in
            central = CBCentralManager(delegate: self, queue: queue)
        }
    }

    private func scan(name: String?, identifier: UUID?, pickOne: Bool, timeout: TimeInterval) async throws {
        let wanted = name?.lowercased()
        let target = name ?? (identifier == nil ? "uma cortadora Silhouette" : "a cortadora escolhida")
        try await step(.scanning, timeout: timeout, onTimeout: { [self] in
            central?.stopScan()
            return .notFound(target)
        }) { [self] in
            scanFilter = { advertised in
                guard let wanted else { return Hardware.match(bluetoothName: advertised) != nil }
                return advertised.lowercased().contains(wanted)
            }
            wantedIdentifier = identifier
            self.pickOne = pickOne
            found = [:]
            // A Portrait não anuncia o UUID do serviço; o filtro é pelo nome.
            central?.scanForPeripherals(withServices: nil, options: nil)
        }
    }

    private func connectPeripheral(timeout: TimeInterval) async throws {
        try await step(.connecting, timeout: timeout, onTimeout: { [self] in
            if let peripheral { central?.cancelPeripheralConnection(peripheral) }
            return .timeout
        }) { [self] in
            guard let peripheral else { throw CutterError.notFound(localized("uma cortadora Silhouette")) }
            central?.connect(peripheral)
        }
    }

    private func discover(timeout: TimeInterval) async throws {
        try await step(.discovering, timeout: timeout) { [self] in
            guard let peripheral else { throw CutterError.disconnected }
            peripheral.delegate = self
            peripheral.discoverServices([Self.serviceUUID])
        }
    }

    private func subscribe(timeout: TimeInterval) async throws {
        try await step(.subscribing, timeout: timeout) { [self] in
            guard let peripheral else { throw CutterError.disconnected }
            notifyPending = [Self.controlUUID, Self.readUUID]
            for uuid in notifyPending {
                guard let characteristic = characteristics[uuid] else { throw CutterError.missingService }
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    /// Escrita com confirmação; se a máquina responder "ocupada" (ATT 0x0E), espera e tenta de novo.
    private func writeValue(_ data: Data, to channel: Channel, timeout: TimeInterval) async throws {
        var attempt = 0
        while true {
            do {
                try await step(.writing, timeout: timeout) { [self] in
                    guard connected, let peripheral, let characteristic = characteristics[channel.uuid] else {
                        throw CutterError.disconnected
                    }
                    peripheral.writeValue(data, for: characteristic, type: .withResponse)
                }
                return
            } catch where Self.isBackpressure(error) && attempt < Self.backpressureRetries {
                try await Task.sleep(for: .seconds(Self.backpressureDelay * pow(2, Double(attempt))))
                attempt += 1
            }
        }
    }

    private static func isBackpressure(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == CBATTErrorDomain && error.code == CBATTError.Code.unlikelyError.rawValue
    }

    // MARK: Espera pelos callbacks

    /// Inicia uma operação na fila do Bluetooth e espera o callback que a conclui (ou o tempo esgotar).
    private func step(_ phase: Phase, timeout: TimeInterval, onTimeout: (@Sendable () -> CutterError)? = nil,
                      start: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                if let previous = waiter {
                    waiter = nil
                    previous.resume(throwing: CutterError.writeFailed(localized("operação Bluetooth interrompida")))
                }
                self.phase = phase
                waiter = continuation
                let item = DispatchWorkItem { [self] in
                    guard waiter != nil, self.phase == phase else { return }
                    finish(.failure(onTimeout?() ?? .timeout))
                }
                waiterTimeout = item
                queue.asyncAfter(deadline: .now() + timeout, execute: item)
                do { try start() } catch { finish(.failure(error)) }
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        waiterTimeout?.cancel()
        waiterTimeout = nil
        graceTimer?.cancel()
        graceTimer = nil
        phase = .idle
        guard let waiter else { return }
        self.waiter = nil
        waiter.resume(with: result)
    }

    private func failAll(_ error: CutterError) {
        finish(.failure(error))
        if let pending = reader {
            reader = nil
            pending.timeout.cancel()
            pending.continuation.resume(throwing: error)
        }
    }

    /// Uma resposta terminada em ETX, ou `maxLength` bytes se já houver tantos.
    private func takeReply(_ maxLength: Int) -> Data? {
        guard !incoming.isEmpty else { return nil }
        if let etx = incoming.firstIndex(of: GPGL.etx) {
            return pop(min(maxLength, incoming.distance(from: incoming.startIndex, to: etx) + 1))
        }
        return incoming.count >= maxLength ? pop(maxLength) : nil
    }

    private func pop(_ count: Int) -> Data {
        let head = Data(incoming.prefix(count))
        incoming = Data(incoming.dropFirst(count))
        return head
    }

    private func deliver() {
        guard let pending = reader, let data = takeReply(pending.maxLength) else { return }
        reader = nil
        pending.timeout.cancel()
        pending.continuation.resume(returning: data)
    }

    /// As encontradas; se alguma anuncia o serviço da Silhouette, só essas.
    private func candidates() -> [Found] {
        let all = Array(found.values)
        let advertising = all.filter(\.advertisesService)
        return advertising.isEmpty ? all : advertising
    }

    private func finishScan() {
        graceTimer = nil
        central?.stopScan()
        guard pickOne else { return finish(.success(())) }
        let candidates = self.candidates()
        guard candidates.count == 1, let chosen = candidates.first else {
            finish(.failure(candidates.isEmpty
                ? CutterError.notFound(localized("uma cortadora Silhouette"))
                : CutterError.ambiguous(candidates.map { "\($0.name) (\($0.peripheral.identifier))" })))
            return
        }
        peripheral = chosen.peripheral
        location = "bluetooth-le \(chosen.name) (\(chosen.peripheral.identifier))"
        finish(.success(()))
    }
}

extension BLETransport: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if phase == .poweringOn { finish(.success(())) }
        case .unauthorized:
            failAll(.bluetoothUnavailable(
                localized("Sem permissão de Bluetooth. Libere em Ajustes do Sistema › Privacidade e Segurança › Bluetooth.")))
        case .poweredOff:
            connected = false
            failAll(.bluetoothUnavailable(localized("O Bluetooth do Mac está desligado.")))
        case .unsupported:
            failAll(.bluetoothUnavailable(localized("Este Mac não tem Bluetooth LE.")))
        default:
            break
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard phase == .scanning, found[peripheral.identifier] == nil else { return }
        if let wantedIdentifier, peripheral.identifier != wantedIdentifier { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        guard let scanFilter, scanFilter(name) else { return }
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        found[peripheral.identifier] = Found(peripheral: peripheral, name: name,
                                             advertisesService: services.contains(Self.serviceUUID))
        log("encontrada: \(name)")
        if wantedIdentifier != nil { return finishScan() }
        if graceTimer == nil {
            let item = DispatchWorkItem { [self] in finishScan() }
            graceTimer = item
            queue.asyncAfter(deadline: .now() + Self.discoveryGrace, execute: item)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connected = true
        if phase == .connecting { finish(.success(())) }
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard phase == .connecting else { return }
        finish(.failure(CutterError.bluetoothUnavailable(
            localized("Falha ao conectar: \(error?.localizedDescription ?? localized("motivo desconhecido"))"))))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        connected = false
        if phase == .closing {
            finish(.success(()))
            return
        }
        log("desconectada" + (error.map { ": \($0.localizedDescription)" } ?? ""))
        failAll(.disconnected)
    }
}

extension BLETransport: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard phase == .discovering else { return }
        if let error { return finish(.failure(error)) }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            return finish(.failure(CutterError.missingService))
        }
        peripheral.discoverCharacteristics([Self.writeUUID, Self.readUUID, Self.controlUUID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        guard phase == .discovering else { return }
        if let error { return finish(.failure(error)) }
        for characteristic in service.characteristics ?? [] {
            characteristics[characteristic.uuid] = characteristic
        }
        let complete = [Self.writeUUID, Self.readUUID, Self.controlUUID].allSatisfy { characteristics[$0] != nil }
        finish(complete ? .success(()) : .failure(CutterError.missingService))
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard phase == .subscribing else { return }
        if let error { return finish(.failure(error)) }
        notifyPending.remove(characteristic.uuid)
        if notifyPending.isEmpty { finish(.success(())) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard phase == .writing else { return }
        finish(error.map { .failure($0) } ?? .success(()))
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard characteristic.uuid == Self.readUUID, let value = characteristic.value else { return }
        incoming.append(value)
        deliver()
    }
}
