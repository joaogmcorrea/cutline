// Silhouette's GPGL protocol (Graphtec).
// Port of Graphtec.py (inkscape-silhouette, GPLv2) — same commands, byte by byte.
import Foundation

public enum GPGL {
    /// End of command.
    public static let etx: UInt8 = 0x03
    public static let esc: UInt8 = 0x1B
    /// Escape commands: ESC EOT initializes, ESC ENQ asks for the status, ESC NAK asks for the tools.
    public static let eot: UInt8 = 0x04
    public static let enq: UInt8 = 0x05
    public static let nak: UInt8 = 0x15

    /// Machine unit: 1 mm = 20 SU, 1 in = 508 SU.
    /// Python's `round()` rounds ties to even (0.5 → 0; 1.5 → 2) — same here.
    public static func su(mm: Double) -> Int { Int((mm * 20.0).rounded(.toNearestOrEven)) }
    public static func su(inch: Double) -> Int { Int((inch * 508.0).rounded(.toNearestOrEven)) }

    /// Each command terminated by ETX.
    public static func delimit(_ commands: [String]) -> Data {
        var data = Data()
        for command in commands {
            data.append(contentsOf: Array(command.utf8))
            data.append(etx)
        }
        return data
    }

    // Coordinates go as (y, x): the machine's x axis runs top to bottom.
    static func move(y: Double, x: Double) -> String { "M\(su(mm: y)),\(su(mm: x))" }
    static func draw(y: Double, x: Double) -> String { "D\(su(mm: y)),\(su(mm: x))" }
    static func upperLeft(y: Double, x: Double) -> String { "\\\(su(mm: y)),\(su(mm: x))" }
    static func lowerRight(y: Double, x: Double) -> String { "Z\(su(mm: y)),\(su(mm: x))" }
    static func acceleration(_ value: Int) -> String { "TJ\(value)" }

    /// Automatic search for the registration marks (TB123; TB124 = 4 marks, Cameo 5 Alpha).
    static func automaticRegmarkTest(height: Double, width: Double, top: Double, left: Double, quad: Bool) -> String {
        "\(quad ? "TB124" : "TB123"),\(su(mm: height)),\(su(mm: width)),\(su(mm: top)),\(su(mm: left))"
    }

    static func manualRegmark(height: Double, width: Double) -> String {
        "TB23,\(su(mm: height)),\(su(mm: width))"
    }
}

/// Commands of a tool holder (1 or 2).
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
