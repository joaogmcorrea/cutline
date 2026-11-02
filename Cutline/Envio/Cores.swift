// Cores sRGB com mistura simples ou perceptual (OKLab), usadas no degradê dos ajustes.
import SwiftUI

/// Cor sRGB com mistura simples (como `color-mix in srgb`) ou perceptual (OKLab, que não escurece no meio).
struct RGB {
    var r: Double, g: Double, b: Double

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(_ hex: UInt32) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255)
    }

    var cor: Color { Color(.sRGB, red: r, green: g, blue: b) }

    static func misturaSRGB(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        let t = min(max(t, 0), 1)
        return RGB(r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t)
    }

    static func misturaOKLab(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        let t = min(max(t, 0), 1)
        let (l1, a1, b1) = a.oklab, (l2, a2, b2) = b.oklab
        return RGB(oklab: (l1 + (l2 - l1) * t, a1 + (a2 - a1) * t, b1 + (b2 - b1) * t))
    }

    private static func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    private static func gama(_ c: Double) -> Double {
        let c = min(max(c, 0), 1)
        return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    private var oklab: (Double, Double, Double) {
        let r = Self.linear(r), g = Self.linear(g), b = Self.linear(b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    private init(oklab: (Double, Double, Double)) {
        let (L, A, B) = oklab
        let l = pow(L + 0.3963377774 * A + 0.2158037573 * B, 3)
        let m = pow(L - 0.1055613458 * A - 0.0638541728 * B, 3)
        let s = pow(L - 0.0894841775 * A - 1.2914855480 * B, 3)
        self.init(r: Self.gama(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                  g: Self.gama(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                  b: Self.gama(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))
    }
}
