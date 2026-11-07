// Color management through ColorSync. The document stores CMYK; every conversion in the app goes through `ColorConverter`:
// - the CMYK numbers are ink in a CMYK ICC profile: the document's own (Edit › Assign Profile…, `Document.colorProfile`,
//   saved in the .cutline) or else the app's (Cutline › Settings… › Color);
// - RGB means the app's RGB working space: the Color panel's RGB, HSL and hex, the eyedropper on images and the RGB colors
//   of imported files (PDF, SVG, EPS, .studio3 fills, pasted from Illustrator);
// - the screen shows the CMYK as the profile prints it (`color`, `screen`; cached, since the canvas draws a lot), and the
//   print, the bleed and the Finder's previews send the CMYK with the profile (`printColor`, `cmykSpace`).
// Without a profile (the app's default, the owner's choice): the simple conversion Cutline always had (`simpleRGB`,
// `simpleCMYK`) on screen and for RGB, and the print in Generic CMYK, as before; the window shows that the print may look
// different (Editor/ColorProfileViews.swift). The .studio3 line colors, which pick the cut settings, always go through
// the simple conversion, so they keep the CMYK (and the remembered settings) they always had.
// The conversion is CoreGraphics's (`CGColor.converted`, which is ColorSync), with the perceptual intent and without
// ColorSync's black point compensation: on the colors tested it gives Illustrator's numbers (Adobe's engine, Relative
// Colorimetric + black point compensation), e.g. U.S. Web Coated (SWOP) v2: #000000 → C75 M68 Y67 K90, K100 → #231F20,
// C100 → #00ADEE; ColorSync's compensation turns the paper white pink (05/11/2026).
import ColorSync
import CoreGraphics
import Foundation
import Observation
import SwiftUI

/// An ICC profile: its name (the description inside the file) and where the file is. Without a file, one built into
/// macOS (Generic CMYK, sRGB), which always exists, also in the sandbox of the Finder's previews; `none` (no name, no
/// file) = no profile, the simple conversion.
nonisolated struct ColorProfile: Hashable, Codable, Sendable, Identifiable {
    /// The keys stored on disk follow the rest of the .cutline format (Portuguese).
    enum CodingKeys: String, CodingKey {
        case name = "nome", path = "arquivo"
    }

    var name: String
    var path: String?

    var id: String { path ?? name }

    static let genericCMYK = ColorProfile(name: "Generic CMYK Profile")
    static let sRGB = ColorProfile(name: "sRGB IEC61966-2.1")
    /// No CMYK profile: the simple conversion (Illustrator's "Don't Color Manage").
    static let none = ColorProfile(name: "")

    var isNone: Bool { self == .none }

    init(name: String, path: String? = nil) {
        self.name = name
        self.path = path
    }
}

nonisolated enum ColorModel: Sendable {
    case cmyk, rgb

    var builtIn: ColorProfile { self == .cmyk ? .genericCMYK : .sRGB }

    fileprivate var builtInSpace: CGColorSpace {
        CGColorSpace(name: self == .cmyk ? CGColorSpace.genericCMYK : CGColorSpace.sRGB)!
    }

    fileprivate var signature: String { self == .cmyk ? "CMYK" : "RGB " }
}

/// The profiles on this Mac: the ColorSync folders (system, computer, user) and Adobe's, which come with its apps
/// (FOGRA, SWOP, GRACoL, Japan Color…; never bundled with Cutline), plus the files chosen with Load Profile….
nonisolated enum ColorProfiles {
    static var folders: [String] {
        ["/System/Library/ColorSync/Profiles", "/Library/ColorSync/Profiles",
         NSHomeDirectory() + "/Library/ColorSync/Profiles", "/Library/Application Support/Adobe/Color/Profiles"]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var found: [String: (ColorProfile, ColorModel)]?

    /// The profiles of one model, by name, the built-in first. One per name: the first folder in `folders` wins.
    static func available(_ model: ColorModel, loaded: [String] = []) -> [ColorProfile] {
        var seen: Set<String> = [model.builtIn.name]
        var list: [ColorProfile] = []
        for (profile, kind) in all(loaded: loaded) where kind == model && !seen.contains(profile.name) {
            seen.insert(profile.name)
            list.append(profile)
        }
        return [model.builtIn] + list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Every usable file in the folders (in their order) and then the loaded ones.
    private static func all(loaded: [String]) -> [(ColorProfile, ColorModel)] {
        lock.lock()
        defer { lock.unlock() }
        if found == nil {
            var map: [String: (ColorProfile, ColorModel)] = [:]
            for folder in folders {
                guard let walk = FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)
                else { continue }
                for case let url as URL in walk {
                    // A display's own calibration isn't a working space.
                    if url.lastPathComponent == "Displays" { walk.skipDescendants(); continue }
                    guard ["icc", "icm"].contains(url.pathExtension.lowercased()), let read = read(url) else { continue }
                    map[url.path] = read
                }
            }
            found = map
        }
        let order = folders
        let installed = found!.values.sorted { a, b in
            let ia = order.firstIndex { a.0.path!.hasPrefix($0) } ?? order.count
            let ib = order.firstIndex { b.0.path!.hasPrefix($0) } ?? order.count
            return ia != ib ? ia < ib : a.0.path! < b.0.path!
        }
        return installed + loaded.compactMap { read(URL(fileURLWithPath: $0)) }
    }

    /// Reads the list again (after Load Profile…, or a profile installed with the app open).
    static func refresh() {
        lock.lock()
        found = nil
        lock.unlock()
        ColorConverter.forget()
    }

    /// Name and model of a profile file; nil if it isn't a CMYK or RGB profile that colors can be converted with
    /// (abstract, device link, named colors, gray, Lab…).
    static func read(_ url: URL) -> (ColorProfile, ColorModel)? {
        guard let handle = try? FileHandle(forReadingFrom: url), let header = try? handle.read(upToCount: 128),
              header.count == 128 else { return nil }
        try? handle.close()
        let text = { (start: Int) in String(decoding: header[start..<(start + 4)], as: UTF8.self) }
        guard ["mntr", "prtr", "scnr", "spac"].contains(text(12)) else { return nil }
        let model: ColorModel
        switch text(16) {
        case ColorModel.cmyk.signature: model = .cmyk
        case ColorModel.rgb.signature: model = .rgb
        default: return nil
        }
        guard let profile = ColorSyncProfileCreateWithURL(url as CFURL, nil)?.takeRetainedValue() else { return nil }
        let name = ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() as String?
        return (ColorProfile(name: name ?? url.deletingPathExtension().lastPathComponent, path: url.path), model)
    }

    /// The color space of a profile: its file if it's there (and of the right model), else one with the same name in the
    /// folders (the document came from another Mac), else nil (missing).
    static func space(of profile: ColorProfile, _ model: ColorModel, loaded: [String] = []) -> CGColorSpace? {
        if profile.path == nil, profile.name == model.builtIn.name { return model.builtInSpace }
        let file = profile.path.flatMap { path in read(URL(fileURLWithPath: path)).flatMap { $0.1 == model ? path : nil } }
        let path = file ?? all(loaded: loaded).first { $0.1 == model && $0.0.name == profile.name }?.0.path
        guard let path, let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let space = CGColorSpace(iccData: data as CFData), space.model == (model == .cmyk ? .cmyk : .rgb) else { return nil }
        return space
    }
}

/// The conversions of one pair of profiles (the document's CMYK and the app's RGB working space).
nonisolated final class ColorConverter: @unchecked Sendable {
    /// The profiles asked for.
    let cmykProfile: ColorProfile
    let rgbProfile: ColorProfile
    /// Their color spaces (the built-in one when the profile wasn't found).
    let cmykSpace: CGColorSpace
    let rgbSpace: CGColorSpace
    /// Asked for and not on this Mac: Generic CMYK (or sRGB) is used in its place.
    let cmykMissing: Bool
    let rgbMissing: Bool
    /// No CMYK profile: the simple conversion on screen and for RGB; the print in Generic CMYK (`cmykSpace`).
    let unmanaged: Bool
    /// The rendering intent of drawing CMYK into RGB (the print converted for an RGB printer, the previews): perceptual,
    /// as the screen; without a profile, CoreGraphics's default, as the print always was.
    var intent: CGColorRenderingIntent { unmanaged ? .defaultIntent : Self.managedIntent }

    private let lock = NSLock()
    private var shown: [CMYK: (cg: CGColor, color: Color)] = [:]
    private var inRGB: [CMYK: [Double]] = [:]

    /// The screen: Display P3, wider than sRGB, so the CMYK colors sRGB doesn't reach (cyan, green) still show on Mac screens.
    static let screenSpace = CGColorSpace(name: CGColorSpace.displayP3)!
    private static let managedIntent = CGColorRenderingIntent.perceptual

    private init(cmyk: ColorProfile, rgb: ColorProfile, loaded: [String]) {
        cmykProfile = cmyk
        rgbProfile = rgb
        unmanaged = cmyk.isNone
        let c = unmanaged ? nil : ColorProfiles.space(of: cmyk, .cmyk, loaded: loaded)
        let r = unmanaged ? nil : ColorProfiles.space(of: rgb, .rgb, loaded: loaded)
        cmykSpace = c ?? ColorModel.cmyk.builtInSpace
        rgbSpace = r ?? ColorModel.rgb.builtInSpace
        cmykMissing = c == nil && !unmanaged
        rgbMissing = r == nil && !unmanaged
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var made: [[ColorProfile]: ColorConverter] = [:]

    /// The converter of these profiles (made once: reading a profile takes a moment).
    static func make(cmyk: ColorProfile, rgb: ColorProfile, loaded: [String] = []) -> ColorConverter {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let ready = made[[cmyk, rgb]] { return ready }
        let new = ColorConverter(cmyk: cmyk, rgb: rgb, loaded: loaded)
        made[[cmyk, rgb]] = new
        return new
    }

    /// Profiles may have changed (installed, loaded): the next `make` reads them again.
    static func forget() {
        cacheLock.lock()
        made = [:]
        cacheLock.unlock()
    }

    // MARK: CMYK → RGB

    /// The color in the RGB working space, 0–1 (what the RGB, HSL and hex inputs show). Paper (no ink) is white.
    func rgb(_ c: CMYK) -> [Double] {
        lock.lock()
        if let ready = inRGB[c] { lock.unlock(); return ready }
        lock.unlock()
        let value = unmanaged ? Self.simpleRGB(c) : c == CMYK(c: 0, m: 0, y: 0, k: 0) ? [1, 1, 1] : convert(c, to: rgbSpace)
        lock.lock()
        inRGB[c] = value
        lock.unlock()
        return value
    }

    /// 0–255.
    func rgb255(_ c: CMYK) -> [Int] { rgb(c).map { Int(($0 * 255).rounded()) } }

    /// "RRGGBB".
    func hex(_ c: CMYK) -> String { rgb255(c).map { String(format: "%02X", $0) }.joined() }

    /// Hue 0–360°, saturation and lightness 0–100 (of the RGB working space).
    func hsl(_ c: CMYK) -> [Int] {
        let v = rgb(c)
        let (r, g, b) = (v[0], v[1], v[2])
        let mx = max(r, g, b), mn = min(r, g, b), l = (mx + mn) / 2
        var h = 0.0, s = 0.0
        if mx != mn {
            let d = mx - mn
            s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
            h = mx == r ? (g - b) / d + (g < b ? 6 : 0) : mx == g ? (b - r) / d + 2 : (r - g) / d + 4
            h *= 60
        }
        return [Int(h.rounded()) % 360, Int((s * 100).rounded()), Int((l * 100).rounded())]
    }

    /// How the screen shows the color: as the profile prints it.
    func screen(_ c: CMYK) -> CGColor { shownColor(c).cg }

    /// The same, for SwiftUI.
    func color(_ c: CMYK) -> Color { shownColor(c).color }

    private func shownColor(_ c: CMYK) -> (cg: CGColor, color: Color) {
        lock.lock()
        if let ready = shown[c] { lock.unlock(); return ready }
        lock.unlock()
        let space = unmanaged ? ColorModel.rgb.builtInSpace : Self.screenSpace
        let v = unmanaged ? Self.simpleRGB(c) : c == CMYK(c: 0, m: 0, y: 0, k: 0) ? [1, 1, 1] : convert(c, to: space)
        let cg = CGColor(colorSpace: space, components: v.map { CGFloat($0) } + [1])!
        let value = (cg, Color(cgColor: cg))
        lock.lock()
        shown[c] = value
        lock.unlock()
        return value
    }

    private func convert(_ c: CMYK, to space: CGColorSpace) -> [Double] {
        let source = CGColor(colorSpace: cmykSpace, components: [c.c / 100, c.m / 100, c.y / 100, c.k / 100, 1].map { CGFloat($0) })!
        let out = source.converted(to: space, intent: Self.managedIntent, options: nil)?.components ?? [0, 0, 0, 1]
        return out.prefix(3).map { min(max(Double($0), 0), 1) }
    }

    // MARK: → CMYK

    /// The CMYK with the profile, for printing (PDF, printer, bleed): macOS converts it for the printer.
    func printColor(_ c: CMYK) -> CGColor {
        CGColor(colorSpace: cmykSpace, components: [c.c / 100, c.m / 100, c.y / 100, c.k / 100, 1].map { CGFloat($0) })!
    }

    /// From the RGB working space (0–1), rounded to 1 % so equal colors group together.
    func cmyk(red r: Double, green g: Double, blue b: Double) -> CMYK {
        if unmanaged { return Self.simpleCMYK(red: r, green: g, blue: b) }
        let limit = { (v: Double) in CGFloat(min(max(v, 0), 1)) }
        return cmyk(CGColor(colorSpace: rgbSpace, components: [limit(r), limit(g), limit(b), 1])!) ?? CMYK(c: 0, m: 0, y: 0, k: 100)
    }

    func cmyk(rgb255 v: [Int]) -> CMYK { cmyk(red: Double(v[0]) / 255, green: Double(v[1]) / 255, blue: Double(v[2]) / 255) }

    /// "RRGGBB", "#RRGGBB" or "RGB".
    func cmyk(hex text: String) -> CMYK? {
        var h = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return cmyk(rgb255: [Int(v >> 16) & 0xFF, Int(v >> 8) & 0xFF, Int(v) & 0xFF])
    }

    /// Hue 0–360°, saturation and lightness 0–100, in the RGB working space.
    func cmyk(hsl v: [Int]) -> CMYK {
        let h = Double(v[0]), s = Double(v[1]) / 100, l = Double(v[2]) / 100
        let a = s * min(l, 1 - l)
        let f = { (n: Double) -> Double in
            let k = (n + h / 30).truncatingRemainder(dividingBy: 12)
            return l - a * max(-1, min(k - 3, 9 - k, 1))
        }
        return cmyk(red: f(0), green: f(8), blue: f(4))
    }

    /// Any color: CMYK keeps its numbers (as Illustrator does with CMYK in a CMYK document), gray goes to black ink
    /// only, RGB (in its own space) goes through the profile. nil for other models (Lab, patterns…).
    func cmyk(_ color: CGColor) -> CMYK? {
        guard let space = color.colorSpace, let v = color.components?.map(Double.init) else { return nil }
        let percent = { (x: Double) in (min(max(x, 0), 1) * 100).rounded() }
        switch space.model {
        case .cmyk where v.count >= 4:
            return CMYK(c: percent(v[0]), m: percent(v[1]), y: percent(v[2]), k: percent(v[3]))
        case .monochrome where v.count >= 1:
            return CMYK(c: 0, m: 0, y: 0, k: percent(1 - v[0]))
        case .rgb:
            if v.prefix(3).allSatisfy({ $0 >= 1 }) { return CMYK(c: 0, m: 0, y: 0, k: 0) }
            if unmanaged {
                guard let rgb = color.converted(to: rgbSpace, intent: .defaultIntent, options: nil)?.components, rgb.count >= 3
                else { return nil }
                return Self.simpleCMYK(red: Double(rgb[0]), green: Double(rgb[1]), blue: Double(rgb[2]))
            }
            guard let out = color.converted(to: cmykSpace, intent: Self.managedIntent, options: nil)?.components, out.count >= 4
            else { return nil }
            return CMYK(c: percent(out[0]), m: percent(out[1]), y: percent(out[2]), k: percent(out[3]))
        default:
            return nil
        }
    }

    /// Any color (the eyedropper's, sampled from the screen) in the RGB working space, 0–1.
    func workingRGB(_ color: CGColor) -> [Double]? {
        guard let out = color.converted(to: rgbSpace, intent: .defaultIntent, options: nil)?.components, out.count >= 3 else { return nil }
        return out.prefix(3).map { min(max(Double($0), 0), 1) }
    }

    // MARK: HSB (the Color Picker's H, S and B, in the RGB working space)

    /// RGB 0–1 → hue 0–360°, saturation and brightness 0–1.
    static func hsb(fromRGB v: [Double]) -> [Double] {
        let (r, g, b) = (v[0], v[1], v[2])
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            h = mx == r ? (g - b) / d + (g < b ? 6 : 0) : mx == g ? (b - r) / d + 2 : (r - g) / d + 4
            h *= 60
        }
        return [h, mx > 0 ? d / mx : 0, mx]
    }

    /// Hue 0–360°, saturation and brightness 0–1 → RGB 0–1.
    static func rgb(fromHSB v: [Double]) -> [Double] {
        let h = (v[0].truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let s = min(max(v[1], 0), 1), b = min(max(v[2], 0), 1)
        let f = { (n: Double) -> Double in
            let k = (n + h).truncatingRemainder(dividingBy: 6)
            return b - b * s * max(0, min(k, 4 - k, 1))
        }
        return [f(5), f(3), f(1)]
    }

    // MARK: The simple conversion (no profile; the .studio3 line colors)

    /// CMYK → RGB 0–1 without a profile: each ink takes away its light (Cutline 1.4 and before).
    static func simpleRGB(_ c: CMYK) -> [Double] {
        let f = { (v: Double) in 1 - min(max(v, 0), 100) / 100 }
        return [f(c.c) * f(c.k), f(c.m) * f(c.k), f(c.y) * f(c.k)]
    }

    /// RGB 0–1 → CMYK without a profile (the most black possible), rounded to 1 %.
    static func simpleCMYK(red r: Double, green g: Double, blue b: Double) -> CMYK {
        let limit = { (v: Double) in min(max(v, 0), 1) }
        let (r, g, b) = (limit(r), limit(g), limit(b))
        let k = 1 - max(r, g, b)
        guard k < 1 else { return CMYK(c: 0, m: 0, y: 0, k: 100) }
        let channel = { (v: Double) in ((1 - v - k) / (1 - k) * 100).rounded() }
        return CMYK(c: channel(r), m: channel(g), y: channel(b), k: (k * 100).rounded())
    }
}

/// The app's color settings (Cutline › Settings… › Color), like Illustrator's Color Settings: the CMYK profile of the
/// documents without their own and the RGB working space, kept in UserDefaults as the profile's JSON. The Finder's
/// previews run in a sandbox with their own (empty) settings: there the built-in ones apply.
@Observable
nonisolated final class ColorSettings: @unchecked Sendable {
    static let shared = ColorSettings()

    static let cmykKey = "cmykProfile"
    static let rgbKey = "rgbProfile"
    static let loadedKey = "loadedProfiles"

    /// What Cutline uses before anything is chosen: no CMYK profile (the simple conversion; the owner's choice, so
    /// documents keep the colors they always had on screen) and sRGB.
    static let defaultCMYK = ColorProfile.none
    static let defaultRGB = ColorProfile.sRGB

    private(set) var cmyk: ColorProfile
    private(set) var rgb: ColorProfile
    /// Files chosen with Load Profile… that aren't in the profile folders.
    private(set) var loaded: [String]

    private init() {
        let defaults = UserDefaults.standard
        let profile = { (key: String) in
            defaults.string(forKey: key).flatMap { try? JSONDecoder().decode(ColorProfile.self, from: Data($0.utf8)) }
        }
        cmyk = profile(Self.cmykKey) ?? Self.defaultCMYK
        rgb = profile(Self.rgbKey) ?? Self.defaultRGB
        loaded = defaults.stringArray(forKey: Self.loadedKey) ?? []
    }

    func setCMYK(_ profile: ColorProfile) {
        cmyk = profile
        save(profile, Self.cmykKey)
    }

    func setRGB(_ profile: ColorProfile) {
        rgb = profile
        save(profile, Self.rgbKey)
    }

    private func save(_ profile: ColorProfile, _ key: String) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: key)
    }

    /// Load Profile…: a .icc/.icm file outside the folders joins the lists (where it is: Cutline doesn't copy it). Returns
    /// it with its model, or nil if it isn't a CMYK or RGB profile.
    func load(_ url: URL) -> (ColorProfile, ColorModel)? {
        guard let read = ColorProfiles.read(url) else { return nil }
        if !loaded.contains(url.path) {
            loaded.append(url.path)
            UserDefaults.standard.set(loaded, forKey: Self.loadedKey)
        }
        ColorProfiles.refresh()
        return read
    }

    /// The conversion with this CMYK profile (a document's own; nil = the app's) and the app's RGB working space.
    func converter(_ ownCMYK: ColorProfile? = nil) -> ColorConverter {
        ColorConverter.make(cmyk: ownCMYK ?? cmyk, rgb: rgb, loaded: loaded)
    }
}

nonisolated extension Document {
    /// This document's conversion: its own CMYK profile (Edit › Assign Profile…) or the app's, and the app's RGB.
    var colors: ColorConverter { ColorSettings.shared.converter(colorProfile) }
}
