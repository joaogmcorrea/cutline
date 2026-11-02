// Camada de transporte: Bluetooth LE (BLETransport), cabo USB (USBTransport) ou simulação.
import Foundation

public protocol CutterTransport: AnyObject, Sendable {
    /// Descrição da conexão, para log ("bluetooth-le Portrait 4-0000001 (…)").
    var location: String { get }
    /// Envia todos os bytes; `timeout` vale para cada pacote.
    func write(_ data: Data, timeout: TimeInterval) async throws
    /// Lê uma resposta terminada em ETX (ou até `maxLength` bytes).
    /// Lança `CutterError.timeout` se nada chegar no prazo.
    func read(maxLength: Int, timeout: TimeInterval) async throws -> Data
    func close() async
}

/// Mensagens para o usuário: traduzidas pelo catálogo do app (Localizable.xcstrings do Cutline, chaves
/// "manuais"); fora do app (CLI `cutline`), ficam em português.
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
        case .timeout: localized("A cortadora não respondeu a tempo.")
        case .disconnected: localized("A cortadora desconectou.")
        case .bluetoothUnavailable(let motivo), .usbUnavailable(let motivo): motivo
        case .notFound(let alvo): localized("Não encontrei \(alvo). Verifique se ela está ligada.")
        case .ambiguous(let nomes): localized("Mais de uma cortadora encontrada: \(nomes.joined(separator: ", ")).")
        case .missingService: localized("O dispositivo não tem o serviço Bluetooth da Silhouette.")
        case .writeFailed(let motivo): localized("Falha ao enviar comandos: \(motivo)")
        case .badResponse(let resposta): localized("Resposta inesperada da cortadora: \(resposta)")
        case .registrationMarksNotFound(let resposta): localized("Não encontrei as marcas de registro (\(resposta)).")
        case .mediaNotLoaded: localized("Nenhuma base carregada. Carregue a base e tente de novo.")
        case .invalidSettings(let motivo): motivo
        case .outOfBounds(let motivo): motivo
        }
    }
}

/// Sem máquina: responde como o modo simulação (dry run) do driver Python — estado "pronta",
/// firmware "None " e marcas de registro "encontradas". Não guarda nada; a transcrição fica no `Cutter`.
public final class SimulatedTransport: CutterTransport, @unchecked Sendable {
    public let location = "simulação"
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
