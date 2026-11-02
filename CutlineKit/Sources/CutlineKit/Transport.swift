// Transport layer: Bluetooth LE (BLETransport), USB cable (USBTransport) or simulation.
import Foundation

public protocol CutterTransport: AnyObject, Sendable {
    /// Connection description, for the log ("bluetooth-le Portrait 4-0000001 (…)").
    var location: String { get }
    /// Sends all the bytes; `timeout` applies to each packet.
    func write(_ data: Data, timeout: TimeInterval) async throws
    /// Reads a response ending in ETX (or up to `maxLength` bytes).
    /// Throws `CutterError.timeout` if nothing arrives in time.
    func read(maxLength: Int, timeout: TimeInterval) async throws -> Data
    func close() async
}

/// Messages for the user: translated by the app's catalog (Cutline's Localizable.xcstrings, "manual"
/// keys); outside the app (the `cutline` CLI), they stay in English.
func localized(_ value: String.LocalizationValue) -> String { String(localized: value, bundle: .main) }

public enum CutterError: Error, Equatable, LocalizedError {
    case timeout
    case disconnected
    case bluetoothUnavailable(String)
    case usbUnavailable(String)
    case notFound(String)
    case ambiguous([String])
    case missingService
    case writeFailed(String)
    case badResponse(String)
    case registrationMarksNotFound(String)
    case mediaNotLoaded
    case invalidSettings(String)
    case outOfBounds(String)

    public var errorDescription: String? {
        switch self {
        case .timeout: localized("The cutter didn’t respond in time.")
        case .disconnected: localized("The cutter disconnected.")
        case .bluetoothUnavailable(let reason), .usbUnavailable(let reason): reason
        case .notFound(let target): localized("Couldn’t find \(target). Check that it’s turned on.")
        case .ambiguous(let names): localized("More than one cutter found: \(names.joined(separator: ", ")).")
        case .missingService: localized("The device doesn’t have the Silhouette Bluetooth service.")
        case .writeFailed(let reason): localized("Couldn’t send commands: \(reason)")
        case .badResponse(let reply): localized("Unexpected response from the cutter: \(reply)")
        case .registrationMarksNotFound(let reply): localized("Couldn’t find the registration marks (\(reply)).")
        case .mediaNotLoaded: localized("No mat loaded. Load the mat and try again.")
        case .invalidSettings(let reason): reason
        case .outOfBounds(let reason): reason
        }
    }
}

/// No machine: answers like the Python driver's simulation (dry run) mode — status "ready",
/// firmware "None " and registration marks "found". Stores nothing; the transcript stays in the `Cutter`.
public final class SimulatedTransport: CutterTransport, @unchecked Sendable {
    public let location = "simulation"
    private let lock = NSLock()
    private var pending: Data?

    public init() {}

    public func write(_ data: Data, timeout: TimeInterval) async throws {
        let response: Data? = switch data {
        case Data([GPGL.esc, GPGL.enq]): Data("0".utf8) + [GPGL.etx]
        case GPGL.delimit(["FG"]): Data("None ".utf8) + [GPGL.etx]
        case _ where data.starts(with: Array("TB123".utf8)) || data.starts(with: Array("TB124".utf8))
            || data.starts(with: Array("TB23,".utf8)):
            Data("    0".utf8) + [GPGL.etx]
        default: nil
        }
        if let response { lock.withLock { pending = response } }
    }

    public func read(maxLength: Int, timeout: TimeInterval) async throws -> Data {
        let data = lock.withLock { () -> Data? in
            defer { pending = nil }
            return pending
        }
        guard let data else { throw CutterError.timeout }
        return data
    }

    public func close() async {}
}
