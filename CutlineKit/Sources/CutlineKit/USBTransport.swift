// GPGL byte stream over the USB cable (IOUSBHost).
// The path is the same as Silhouette Studio's (studied with REA, without copying code): the machine's configuration 1,
// first interface, first bulk out endpoint and first bulk in endpoint; each send goes whole in a single request,
// and there is always an 8 KB read pending, keeping the responses until the driver asks for them.
import CryptoKit
import Foundation
import IOKit
import IOUSBHost

public final class USBTransport: CutterTransport, @unchecked Sendable {
    static let vendors = [Hardware.vendorGraphtec, Hardware.vendorCameo5Alpha]
    static let readSize = 8192
    /// The Python driver's fixed endpoints, if the interface doesn't describe its own.
    static let fallbackOut = 0x01
    static let fallbackIn = 0x82
    /// After configuring the machine, macOS takes a moment to publish the interface.
    static let interfaceWait: TimeInterval = 2

    // IOKit codes that are C macros (they don't reach Swift).
    static let messageTerminated: UInt32 = 0xE000_0010
    static let returnAborted = IOReturn(bitPattern: 0xE000_02EB)
    static let returnTimeout = IOReturn(bitPattern: 0xE000_02D6)
    static let returnExclusiveAccess = IOReturn(bitPattern: 0xE000_02C5)
    static let returnPipeStalled = IOReturn(bitPattern: 0xE000_404F)

    /// A cutter on the cable, with the (retained) IOKit service to open.
    private struct Found {
        let cutter: DiscoveredCutter
        let hardware: Hardware
        let service: io_service_t
    }

    private struct Reader {
        let continuation: CheckedContinuation<Data, Error>
        let maxLength: Int
        let timeout: DispatchWorkItem
    }

    // All the state below is only touched on the `queue` queue, where IOUSBHost delivers the callbacks.
    private let queue = DispatchQueue(label: "cutline.usb")
    private let log: @Sendable (String) -> Void
    private var interface: IOUSBHostInterface?
    private var output: IOUSBHostPipe?
    private var input: IOUSBHostPipe?
    private var incoming = Data()
    private var reader: Reader?
    private var connected = false

    /// The model by the USB product id.
    public let hardware: Hardware
    public private(set) var location = "usb (not connected)"

    private init(hardware: Hardware, log: @escaping @Sendable (String) -> Void) {
        self.hardware = hardware
        self.log = log
    }

    deinit {
        interface?.destroy()
    }

    /// The cutters on the cable now (only the models in the `Hardware` table). Opens none.
    public static func discover(log: @escaping @Sendable (String) -> Void = { _ in }) -> [DiscoveredCutter] {
        let found = scan(log: log)
        defer { found.forEach { IOObjectRelease($0.service) } }
        return found.map(\.cutter)
    }

    /// Opens the chosen cutter (`identifier`, from an earlier search) or the only one plugged in.
    public static func connect(identifier: UUID? = nil,
                               log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> USBTransport {
        let found = scan(log: log)
        defer { found.forEach { IOObjectRelease($0.service) } }
        let candidates = identifier.map { id in found.filter { $0.cutter.id == id } } ?? found
        guard candidates.count == 1, let chosen = candidates.first else {
            if candidates.isEmpty {
                throw CutterError.notFound(identifier == nil ? localized("a Silhouette cutter on the USB cable")
                                                             : localized("the chosen cutter on the USB cable"))
            }
            throw CutterError.ambiguous(candidates.map(\.cutter.name))
        }
        let transport = USBTransport(hardware: chosen.hardware, log: log)
        try await transport.open(chosen)
        return transport
    }

    // MARK: CutterTransport

    public func write(_ data: Data, timeout: TimeInterval) async throws {
        guard !data.isEmpty else { return }
        nonisolated(unsafe) let pipe = try queue.sync { () throws -> IOUSBHostPipe in
            guard connected, let output else { throw CutterError.disconnected }
            return output
        }
        nonisolated(unsafe) let buffer = NSMutableData(data: data)
        let expected = data.count
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try pipe.enqueueIORequest(with: buffer, completionTimeout: timeout) { status, sent in
                    _ = buffer
                    switch status {
                    case kIOReturnSuccess where sent == expected:
                        continuation.resume()
                    case kIOReturnSuccess:
                        continuation.resume(throwing: CutterError.writeFailed(localized("\(sent) of \(expected) bytes sent")))
                    case Self.returnTimeout:
                        continuation.resume(throwing: CutterError.timeout)
                    default:
                        continuation.resume(throwing: Self.failure(status))
                    }
                }
            } catch {
                continuation.resume(throwing: Self.failure(error))
            }
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
        // destroy() cancels the pending read and waits for the callbacks, which run on the queue: call it off the queue.
        nonisolated(unsafe) let open = queue.sync { () -> IOUSBHostInterface? in
            connected = false
            failReader(.disconnected)
            defer { interface = nil; output = nil; input = nil }
            return interface
        }
        open?.destroy()
    }

    // MARK: Busca

    /// All USB devices, filtered here: IOKit matching doesn't accept the vendor alone.
    private static func scan(log: @Sendable (String) -> Void) -> [Found] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOUSBHostDeviceClassName), &iterator)
                == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [Found] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            guard let vendor = (property(service, "idVendor") as? NSNumber)?.uint16Value, vendors.contains(vendor),
                  let product = (property(service, "idProduct") as? NSNumber)?.uint16Value,
                  let hardware = Hardware.withUSB(vendor: vendor, product: product) else {
                IOObjectRelease(service)
                continue
            }
            let serial = (property(service, "USB Serial Number") as? String)?
                .trimmingCharacters(in: .whitespaces).nilIfEmpty
            let location = (property(service, "locationID") as? NSNumber)?.uint32Value ?? 0
            // Same format as the name advertised over Bluetooth: model + "-" + serial number.
            let name = [hardware.modelName, serial].compactMap(\.self).joined(separator: "-")
            let key = "usb:\(vendor):\(product):" + (serial ?? String(location))
            let cutter = DiscoveredCutter(id: stableID(key), name: name, link: .usb)
            log("found on USB: \(name)")
            found.append(Found(cutter: cutter, hardware: hardware, service: service))
        }
        return found.sorted { $0.cutter.name.localizedStandardCompare($1.cutter.name) == .orderedAscending }
    }

    private static func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// Fixed UUID for the same machine (serial number; without it, the port), to remember the last one used.
    private static func stableID(_ key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // MARK: Abertura

    private func open(_ found: Found) async throws {
        var service = Self.firstInterface(of: found.service)
        if service == nil {
            // Nobody configured the machine yet: picks the first configuration, like Studio.
            try Self.configure(found.service)
            let deadline = Date().addingTimeInterval(Self.interfaceWait)
            while service == nil, Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
                service = Self.firstInterface(of: found.service)
            }
        }
        guard let service else { throw CutterError.notFound(localized("the cutter’s USB interface")) }
        defer { IOObjectRelease(service) }
        // Opening the interface gives exclusive access to it (fails if another app has the machine).
        let opened: IOUSBHostInterface
        let pipes: (out: IOUSBHostPipe, in: IOUSBHostPipe)
        let (out, inp): (Int, Int)
        do {
            opened = try IOUSBHostInterface(__ioService: service, options: [], queue: queue) { [weak self] _, message, _ in
                guard message == Self.messageTerminated else { return }
                self?.unplugged()
            }
        } catch {
            throw Self.failure(error)
        }
        do {
            (out, inp) = Self.bulkEndpoints(opened)
            pipes = (try opened.copyPipe(withAddress: out), try opened.copyPipe(withAddress: inp))
        } catch {
            opened.destroy()
            throw Self.failure(error)
        }
        nonisolated(unsafe) let state = (opened, pipes)
        queue.sync {
            interface = state.0
            (output, input) = state.1
            connected = true
            location = "usb \(found.cutter.name) (endpoints 0x\(String(out, radix: 16)), 0x\(String(inp, radix: 16)))"
            startReading()
        }
    }

    /// The machine's lowest-numbered interface (Studio uses the first), if macOS already published it.
    private static func firstInterface(of device: io_service_t) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(device, kIOServicePlane, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: (number: Int, service: io_service_t)?
        while case let child = IOIteratorNext(iterator), child != 0 {
            let number = (property(child, "bInterfaceNumber") as? NSNumber)?.intValue
            if IOObjectConformsTo(child, kIOUSBHostInterfaceClassName) != 0, let number, number < best?.number ?? .max {
                if let previous = best { IOObjectRelease(previous.service) }
                best = (number, child)
            } else {
                IOObjectRelease(child)
            }
        }
        return best?.service
    }

    private static func configure(_ service: io_service_t) throws {
        do {
            let device = try IOUSBHostDevice(__ioService: service, options: [], queue: nil, interestHandler: nil)
            defer { device.destroy() }
            let value = (try? device.configurationDescriptor(with: 0))?.pointee.bConfigurationValue ?? 1
            try device.__configure(withValue: Int(value), matchInterfaces: true)
        } catch {
            throw failure(error)
        }
    }

    /// The interface's first bulk out endpoint and first bulk in endpoint (like Studio's `getpipe`).
    private static func bulkEndpoints(_ interface: IOUSBHostInterface) -> (out: Int, in: Int) {
        var out: Int?
        var inp: Int?
        let configuration = interface.configurationDescriptor
        let descriptor = interface.interfaceDescriptor
        var current: UnsafePointer<IOUSBDescriptorHeader>?
        while let endpoint = IOUSBGetNextEndpointDescriptor(configuration, descriptor, current) {
            current = UnsafeRawPointer(endpoint).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
            guard IOUSBGetEndpointType(endpoint) == UInt8(kIOUSBEndpointTypeBulk.rawValue) else { continue }
            let address = Int(IOUSBGetEndpointAddress(endpoint))
            if address & 0x80 != 0 { inp = inp ?? address } else { out = out ?? address }
        }
        return (out ?? fallbackOut, inp ?? fallbackIn)
    }

    // MARK: Continuous reading

    /// Leaves a read request pending; each response goes to `incoming` and a new request goes out.
    private func startReading() {
        guard connected, let input else { return }
        nonisolated(unsafe) let buffer = NSMutableData(length: Self.readSize)!
        do {
            try input.enqueueIORequest(with: buffer, completionTimeout: 0) { [weak self] status, count in
                self?.received(status, buffer, count)
            }
        } catch {
            log("USB read failed: \(error.localizedDescription)")
            connected = false
            failReader(.disconnected)
        }
    }

    private func received(_ status: IOReturn, _ buffer: NSMutableData, _ count: Int) {
        switch status {
        case kIOReturnSuccess:
            incoming.append(Data(bytes: buffer.bytes, count: count))
            deliver()
            startReading()
        case Self.returnAborted:
            break
        case Self.returnPipeStalled:
            log("USB: read stalled; clearing")
            try? input?.clearStall()
            startReading()
        default:
            guard connected else { return }
            log("USB: read failed (0x\(String(UInt32(bitPattern: status), radix: 16)))")
            connected = false
            failReader(.disconnected)
        }
    }

    private func unplugged() {
        guard connected else { return }
        log("USB cable unplugged")
        connected = false
        failReader(.disconnected)
    }

    private func failReader(_ error: CutterError) {
        guard let pending = reader else { return }
        reader = nil
        pending.timeout.cancel()
        pending.continuation.resume(throwing: error)
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

    // MARK: Erros

    private static func failure(_ error: Error) -> CutterError {
        if let error = error as? CutterError { return error }
        return failure(IOReturn(truncatingIfNeeded: (error as NSError).code))
    }

    private static func failure(_ status: IOReturn) -> CutterError {
        switch status {
        case returnExclusiveAccess:
            .usbUnavailable(localized("Another app is using the cutter over USB (Silhouette Studio?)."))
        case returnTimeout:
            .timeout
        default:
            .usbUnavailable(localized("USB error (code 0x\(String(UInt32(bitPattern: status), radix: 16)))."))
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
