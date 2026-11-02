// Entradas de cor do painel (RGB, HSL, hex) — só entrada: o documento guarda sempre CMYK.
// Mesma conversão ingênua do protótipo (sem perfil ICC).
import SwiftUI

extension CMYK {
    /// sRGB de 0 a 255.
    nonisolated var rgb255: [Int] {
        let f = { (v: Double) in 1 - v / 100 }
        return [f(c), f(m), f(y)].map { Int(($0 * f(k) * 255).rounded()) }
    }

    nonisolated init(rgb255 v: [Int]) {
        self.init(vermelho: Double(v[0]) / 255, verde: Double(v[1]) / 255, azul: Double(v[2]) / 255)
    }

    /// "RRGGBB".
    nonisolated var hex: String { rgb255.map { String(format: "%02X", $0) }.joined() }

    /// "RRGGBB", "#RRGGBB" ou "RGB".
    nonisolated init?(hex texto: String) {
        var h = texto.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(rgb255: [Int(v >> 16) & 0xFF, Int(v >> 8) & 0xFF, Int(v) & 0xFF])
    }

    /// Matiz 0–360°, saturação e luminosidade 0–100.
    nonisolated var hsl: [Int] {
        let rgb = rgb255.map { Double($0) / 255 }
        let (r, g, b) = (rgb[0], rgb[1], rgb[2])
        let mx = max(r, g, b), mn = min(r, g, b), l = (mx + mn) / 2
        var h = 0.0, s = 0.0
        if mx != mn {
            let d = mx - mn
            s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
            h = mx == r ? (g - b) / d + (g < b ? 6 : 0) : mx == g ? (b - r) / d + 2 : (r - g) / d + 4
            h *= 60
        }
        return [Int(h.rounded()), Int((s * 100).rounded()), Int((l * 100).rounded())]
    }

    nonisolated init(hsl v: [Int]) {
        let h = Double(v[0]), s = Double(v[1]) / 100, l = Double(v[2]) / 100
        let a = s * min(l, 1 - l)
        let f = { (n: Double) -> Double in
            let k = (n + h / 30).truncatingRemainder(dividingBy: 12)
            return l - a * max(-1, min(k - 3, 9 - k, 1))
        }
        self.init(vermelho: f(0), verde: f(8), azul: f(4))
    }

    /// Para os degradês dos sliders.
    nonisolated var corSRGB: Color { Color(.sRGB, red: Double(rgb255[0]) / 255, green: Double(rgb255[1]) / 255, blue: Double(rgb255[2]) / 255) }
}
