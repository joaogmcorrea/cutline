// Cut job: several layers, each with its own force/speed/blade/passes.
// Port of `nucleo.cortar()`, from the Python prototype that checked the driver (outside the repository).
import CoreGraphics
import Foundation

/// Settings of one cut. Portrait 3/4 ranges: speed 1–30 (1–10 on the older ones),
/// force 1–33, blade (AutoBlade) 1–10, passes 1–5.
public struct CutSettings: Sendable, Hashable, Codable {
    public var speed: Int
    public var force: Int
    public var blade: Int
    public var passes: Int

    public init(speed: Int, force: Int, blade: Int, passes: Int) {
        self.speed = speed
        self.force = force
        self.blade = blade
        self.passes = passes
    }

    public static let forceRange = 1...33
    public static let bladeRange = 1...10
    public static let passesRange = 1...5
}

/// Paths cut with the same settings (in the app: one line color).
public struct CutLayer: Sendable {
    public var name: String
    /// In mm, page coordinates (origin at the top-left corner).
    public var paths: [[CGPoint]]
    public var settings: CutSettings

    public init(name: String, paths: [[CGPoint]], settings: CutSettings) {
        self.name = name
        self.paths = paths
        self.settings = settings
    }
}

/// Where the cut is: layer (1…n) and pass (1…n), to show progress.
public struct CutProgress: Sendable {
    public let layer: Int
    public let layerCount: Int
    public let layerName: String
    public let pass: Int
    public let passCount: Int
}

public struct MachineInfo: Sendable {
    public let model: String
    public let firmware: String
    public let status: Cutter.Status
    /// New protocol (Portrait 3/4, Cameo 4/5): blade set by the machine.
    public let autoblade: Bool
    public let maxSpeed: Int
}

extension Cutter {
    public static let a4 = CGSize(width: 210, height: 297)

    public func info() async throws -> MachineInfo {
        let autoblade = hardware.isCameo4Line
        let status = try await status()
        let firmware = try await firmwareVersion() ?? ""
        return MachineInfo(model: hardware.name, firmware: firmware.trimmingCharacters(in: .whitespacesAndNewlines),
                           status: status, autoblade: autoblade, maxSpeed: autoblade ? 30 : 10)
    }

    public nonisolated func validate(_ settings: CutSettings, maxSpeed: Int) throws {
        guard (1...maxSpeed).contains(settings.speed) else {
            throw CutterError.invalidSettings(localized("Speed must be between 1 and \(maxSpeed) on this model."))
        }
        guard CutSettings.forceRange.contains(settings.force) else {
            throw CutterError.invalidSettings(localized("Force must be between 1 and 33."))
        }
        guard CutSettings.bladeRange.contains(settings.blade) else {
            throw CutterError.invalidSettings(localized("Blade must be between 1 and 10."))
        }
        guard CutSettings.passesRange.contains(settings.passes) else {
            throw CutterError.invalidSettings(localized("Passes must be between 1 and 5."))
        }
    }

    /// Cuts the layers in the given order (on stickers: first the inner kiss cut, last
    /// the outer die cut). With `registration`, reads the marks first and only goes back to the origin at the end,
    /// so the registration isn't lost. `cuttingMat` false = no cutting mat (the machine pulls the sheet directly, `TG0`);
    /// `mat` picks the mat (nil = the machine's default).
    @discardableResult
    public func cut(_ layers: [CutLayer], info: MachineInfo, media: CGSize = Cutter.a4,
                    registration: Registration? = nil, cuttingMat: Bool = true, mat: CuttingMat? = nil,
                    onProgress: (@Sendable (CutProgress) -> Void)? = nil) async throws -> Status {
        guard !layers.isEmpty else { throw CutterError.invalidSettings(localized("Nothing to cut.")) }
        for layer in layers { try validate(layer.settings, maxSpeed: info.maxSpeed) }

        if registration == nil {
            let points = layers.flatMap(\.paths).flatMap { $0 }
            let outside = points.contains { $0.x < 0 || $0.y < 0 || $0.x > media.width || $0.y > media.height }
            if outside {
                throw CutterError.outOfBounds(localized("The shapes go past the mat (\(Int(media.width)) × \(Int(media.height)) mm)."))
            }
        }
        if info.status == .unloaded, !isSimulated { throw CutterError.mediaNotLoaded }

        let total = layers.reduce(0) { $0 + $1.settings.passes }
        var count = 0
        for (index, layer) in layers.enumerated() {
            let s = layer.settings
            log("== \(layer.name): speed=\(s.speed) force=\(s.force) blade=\(s.blade) passes=\(s.passes)")
            if !info.autoblade { log("! Manual blade: check that it is set to \(s.blade).") }
            // Finishes the previous layer before changing the configuration.
            if index > 0, !isSimulated { try await waitForReady(timeout: 300) }

            var setup = SetupOptions()
            setup.speed = s.speed
            setup.pressure = s.force
            setup.depth = s.blade
            setup.autoblade = info.autoblade
            setup.cuttingMat = cuttingMat ? (mat ?? hardware.defaultCuttingMat) : CuttingMat.none
            setup.mediaWidth = media.width
            setup.mediaHeight = media.height
            setup.skipInit = index > 0
            try await self.setup(setup)

            for pass in 0..<s.passes {
                count += 1
                onProgress?(CutProgress(layer: index + 1, layerCount: layers.count, layerName: layer.name,
                                        pass: pass + 1, passCount: s.passes))
                var plot = PlotOptions()
                plot.mediaWidth = media.width
                plot.mediaHeight = media.height
                plot.endPosition = .start
                plot.registration = registration
                plot.skipInit = count > 1
                plot.skipReset = registration != nil ? count < total : pass < s.passes - 1
                if registration != nil, count == 1 { log("Reading the registration marks (up to ~40 s)…") }
                try await self.plot(layer.paths, plot)
            }
        }
        return isSimulated ? .ready : try await waitForReady(timeout: 300)
    }
}
