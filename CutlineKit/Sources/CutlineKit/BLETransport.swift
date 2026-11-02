// GPGL byte stream through Silhouette's GATT service (Bluetooth LE).
// Port of BLETransport.py (inkscape-silhouette, GPLv2): same UUIDs, handshake and 20-byte packets.
import CoreBluetooth
import Foundation

/// Cutter seen in the search, before connecting.
public struct DiscoveredCutter: Sendable, Hashable, Identifiable, Codable {
    public enum Link: String, Sendable, Codable { case bluetooth, usb }

    /// The peripheral's identifier on this Mac (stable across searches).
    public let id: UUID
    /// Advertised name: model + "-" + serial number ("Portrait 4-0000001"); over USB, built the same way.
    public let name: String
    public let link: Link

    public init(id: UUID, name: String, link: Link = .bluetooth) {
        self.id = id
        self.name = name
        self.link = link
    }

    // The last machine saved before USB support has no `link`: it was Bluetooth.
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

    /// The machine's serial number (the same as over USB), if the name has one.
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
    /// Query responses arrive here.
    nonisolated(unsafe) static let readUUID = CBUUID(string: "8DCF199A-30E7-4BD4-BEB6-BEB57DCA866C")
    /// Movement events ("1␃", "0␃") — ignored, so they don't mix with the responses.
    nonisolated(unsafe) static let controlUUID = CBUUID(string: "61490654-B5B4-458C-A867-9E15BC1471E0")

    static let initBytes = Data([GPGL.esc, GPGL.eot])
    static let chunkSize = 20
    static let handshakeSettle: TimeInterval = 1
    static let backpressureRetries = 3
    static let backpressureDelay: TimeInterval = 0.1
    /// After the first cutter found, keeps listening a little to notice a second one.
    static let discoveryGrace: TimeInterval = 2

    private enum Phase { case idle, poweringOn, scanning, connecting, discovering, subscribing, writing, closing }

    /// The service's three characteristics (an enum so it can be captured across queues).
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

    // All the state below is only touched on the `queue` queue, where CoreBluetooth delivers the callbacks.
    private let queue = DispatchQueue(label: "cutline.bluetooth")
    private let log: @Sendable (String) -> Void
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var incoming = Data()
    private var connected = false

    // One operation at a time (the driver is sequential).
    private var phase = Phase.idle
    private var waiter: CheckedContinuation<Void, Error>?
    private var waiterTimeout: DispatchWorkItem?
    private var reader: Reader?

    private var scanFilter: (@Sendable (String) -> Bool)?
    /// Only accepts this peripheral (a cutter chosen in an earlier search).
    private var wantedIdentifier: UUID?
    /// At the end of the search, picks the only cutter (connect) or just keeps the list (`discover`).
    private var pickOne = true
    private var found: [UUID: Found] = [:]
    private var graceTimer: DispatchWorkItem?
    private var notifyPending: Set<CBUUID> = []

    public private(set) var location = "bluetooth-le (not connected)"

    private init(log: @escaping @Sendable (String) -> Void) {
        self.log = log
    }

    /// Searches (by the advertised name), connects, subscribes to the notifications and does the handshake.
    /// Without `name`, accepts any model in the `Hardware` table; with `identifier`, only that cutter.
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

    /// Looks for cutters in range without connecting. Ends a little after the first one found.
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

    // MARK: Connection steps

    private func powerOn() async throws {
        try await step(.poweringOn, timeout: 10) { [self] in
            central = CBCentralManager(delegate: self, queue: queue)
        }
    }

    private func scan(name: String?, identifier: UUID?, pickOne: Bool, timeout: TimeInterval) async throws {
        let wanted = name?.lowercased()
        let target = name ?? (identifier == nil ? localized("a Silhouette cutter") : localized("the chosen cutter"))
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
            // The Portrait doesn't advertise the service UUID; the filter is by name.
            central?.scanForPeripherals(withServices: nil, options: nil)
        }
    }

    private func connectPeripheral(timeout: TimeInterval) async throws {
        try await step(.connecting, timeout: timeout, onTimeout: { [self] in
            if let peripheral { central?.cancelPeripheralConnection(peripheral) }
            return .timeout
        }) { [self] in
            guard let peripheral else { throw CutterError.notFound(localized("a Silhouette cutter")) }
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

    /// Write with confirmation; if the machine answers "busy" (ATT 0x0E), waits and tries again.
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

    /// Starts an operation on the Bluetooth queue and waits for the callback that completes it (or the timeout).
    private func step(_ phase: Phase, timeout: TimeInterval, onTimeout: (@Sendable () -> CutterError)? = nil,
                      start: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                if let previous = waiter {
                    waiter = nil
                    previous.resume(throwing: CutterError.writeFailed(localized("Bluetooth operation interrupted")))
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

    /// A response ending in ETX, or `maxLength` bytes if there are already that many.
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

    /// The ones found; if any advertises Silhouette's service, only those.
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
                ? CutterError.notFound(localized("a Silhouette cutter"))
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
                localized("No Bluetooth permission. Allow it in System Settings › Privacy & Security › Bluetooth.")))
        case .poweredOff:
            connected = false
            failAll(.bluetoothUnavailable(localized("The Mac’s Bluetooth is off.")))
        case .unsupported:
            failAll(.bluetoothUnavailable(localized("This Mac doesn’t have Bluetooth LE.")))
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
        log("found: \(name)")
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
            localized("Couldn’t connect: \(error?.localizedDescription ?? localized("unknown reason"))"))))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        connected = false
        if phase == .closing {
            finish(.success(()))
            return
        }
        log("disconnected" + (error.map { ": \($0.localizedDescription)" } ?? ""))
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
