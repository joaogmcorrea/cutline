// Protocolo GPGL (Graphtec) das Silhouette.
// Porte de Graphtec.py (inkscape-silhouette, GPLv2) — mesmos comandos, byte a byte.
import Foundation

public enum GPGL {
    /// Fim de comando.
    public static let etx: UInt8 = 0x03
    public static let esc: UInt8 = 0x1B
    /// Comandos de escape: ESC EOT inicializa, ESC ENQ pede o estado, ESC NAK pede as ferramentas.
    public static let eot: UInt8 = 0x04
    public static let enq: UInt8 = 0x05
    public static let nak: UInt8 = 0x15

    /// Unidade da máquina: 1 mm = 20 SU, 1 pol = 508 SU.
    /// O `round()` do Python arredonda empates para o par (0,5 → 0; 1,5 → 2) — igual aqui.
    public static func su(mm: Double) -> Int { Int((mm * 20.0).rounded(.toNearestOrEven)) }
    public static func su(inch: Double) -> Int { Int((inch * 508.0).rounded(.toNearestOrEven)) }

    /// Cada comando terminado por ETX.
    public static func delimit(_ commands: [String]) -> Data {
        var data = Data()
        for command in commands {
            data.append(contentsOf: Array(command.utf8))
            data.append(etx)
        }
        return data
    }

    // Coordenadas vão como (y, x): o eixo x da máquina corre de cima para baixo.
    static func move(y: Double, x: Double) -> String { "M\(su(mm: y)),\(su(mm: x))" }
    static func draw(y: Double, x: Double) -> String { "D\(su(mm: y)),\(su(mm: x))" }
    static func upperLeft(y: Double, x: Double) -> String { "\\\(su(mm: y)),\(su(mm: x))" }
    static func lowerRight(y: Double, x: Double) -> String { "Z\(su(mm: y)),\(su(mm: x))" }
    static func acceleration(_ value: Int) -> String { "TJ\(value)" }

    /// Busca automática das marcas de registro (TB123; TB124 = 4 marcas, Cameo 5 Alpha).
    static func automaticRegmarkTest(height: Double, width: Double, top: Double, left: Double, quad: Bool) -> String {
        "\(quad ? "TB124" : "TB123"),\(su(mm: height)),\(su(mm: width)),\(su(mm: top)),\(su(mm: left))"
    }

    static func manualRegmark(height: Double, width: Double) -> String {
        "TB23,\(su(mm: height)),\(su(mm: width))"
    }
}

/// Comandos de um porta-ferramenta (1 ou 2).
struct Tool {
    let holder: Int

    var select: String { "J\(holder)" }
    func pressure(_ value: Int) -> String { "FX\(value),\(holder)" }
    func speed(_ value: Int) -> String { "!\(value),\(holder)" }
    func depth(_ value: Int) -> String { "TF\(value),\(holder)" }
    func cutterOffset(xmm: Double, ymm: Double) -> String {
        "FC\(GPGL.su(mm: xmm)),\(GPGL.su(mm: ymm)),\(holder)"
    }
    func lift(_ on: Bool) -> String { on ? "FE1,\(holder)" : "FE0,\(holder)" }
    func sharpenCorners(start: Int, end: Int) -> [String] {
        ["FF\(start),0,\(holder)", "FF\(start),\(end),\(holder)"]
    }
}
