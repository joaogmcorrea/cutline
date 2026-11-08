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

/// What is in the tool holder. Everything but the blade draws, presses or heats: no blade offset, no AutoBlade.
/// The raw values go into .cutline files (in Portuguese, like the rest of that format).
public enum CutTool: String, Sendable, Hashable, Codable, CaseIterable {
    case blade = "lamina", pen = "caneta", foil, emboss = "gravacao", heatPen = "canetaTermica"
}

/// Paths cut with the same settings (in the app: one line color).
public struct CutLayer: Sendable {
    public var name: String
    /// In mm, page coordinates (origin at the top-left corner).
    public var paths: [[CGPoint]]
    public var settings: CutSettings
    /// Tool holder 1 or 2 (2 only on machines with two, `Hardware.hasTwoTools`).
    public var holder: Int
    public var tool: CutTool

    public init(name: String, paths: [[CGPoint]], settings: CutSettings, holder: Int = 1, tool: CutTool = .blade) {
        self.name = name
        self.paths = paths
        self.settings = settings
        self.holder = holder
        self.tool = tool
    }
}

/// Where the cut is: layer (1…n) and pass (1…n), to show progress.
public struct CutProgress: Sendable {
    public let layer: Int
    public let layerCount: Int
    public let layerName: String
    public let pass: Int
    public let passCount: Int
    /// Waiting for the Heat Pen to heat up: about this many seconds left (0 = any moment now).
    public var heatingSecondsLeft: Int? = nil
}

public struct MachineInfo: Sendable {
    public let model: String
    public let firmware: String
    public let status: Cutter.Status
    /// New protocol (Portrait 3/4, Cameo 4/5): blade set by the machine.
    public let autoblade: Bool
    public let maxSpeed: Int
    /// Two tool holders (Cameo 3 onward); the Heat Pen and the emboss tool, by model.
    public let twoHolders: Bool
    public let heatPen: Bool
    public let emboss: Bool
}

extension Cutter {
    public static let a4 = CGSize(width: 210, height: 297)

    public func info() async throws -> MachineInfo {
        let autoblade = hardware.isCameo4Line
        let status = try await status()
        let firmware = try await firmwareVersion() ?? ""
        return MachineInfo(model: hardware.name, firmware: firmware.trimmingCharacters(in: .whitespacesAndNewlines),
                           status: status, autoblade: autoblade, maxSpeed: autoblade ? 30 : 10,
                           twoHolders: hardware.hasTwoTools, heatPen: hardware.hasHeatPen, emboss: hardware.hasEmboss)
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
    /// `mat` picks the mat (nil = the machine's default). `trackEnhancing`: the rollers run the media forward and back
    /// before cutting (`FY0`); it goes once per job, in the first layer's setup. `studioOrder` (Print & Cut): the order
    /// Silhouette Studio sends — the marks are read right after the init and the mat, then the work area is set to the
    /// area between them, and only then the tool (`PlotOptions.studioRegistration`).
    @discardableResult
    public func cut(_ layers: [CutLayer], info: MachineInfo, media: CGSize = Cutter.a4,
                    registration: Registration? = nil, cuttingMat: Bool = true, mat: CuttingMat? = nil,
                    trackEnhancing: Bool = false, studioOrder: Bool = false,
                    onProgress: (@Sendable (CutProgress) -> Void)? = nil) async throws -> Status {
        guard !layers.isEmpty else { throw CutterError.invalidSettings(localized("Nothing to cut.")) }
        for layer in layers { try validate(layer.settings, maxSpeed: info.maxSpeed) }
        try validateTools(layers, info: info)

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
        // Heat Pen, in Silhouette Studio's order: on and hot before the job starts (before the init, the mat and the
        // marks); off at the end, or when the job stops.
        var heatPenOn = false
        do {
            if let first = layers.firstIndex(where: { $0.tool == .heatPen }) {
                heatPenOn = true
                let layer = layers[first]
                try await heatUpHeatPen { seconds in
                    onProgress?(CutProgress(layer: first + 1, layerCount: layers.count, layerName: layer.name,
                                            pass: 1, passCount: layer.settings.passes, heatingSecondsLeft: seconds))
                }
            }
            for (index, layer) in layers.enumerated() {
                let s = layer.settings
                let toolNote = layer.holder == 1 && layer.tool == .blade ? "" : " holder=\(layer.holder) tool=\(layer.tool.rawValue)"
                log("== \(layer.name): speed=\(s.speed) force=\(s.force) blade=\(s.blade) passes=\(s.passes)" + toolNote)
                if !info.autoblade, layer.tool == .blade { log("! Manual blade: check that it is set to \(s.blade).") }
                // Finishes the previous layer before changing the configuration.
                if index > 0, !isSimulated { try await waitForReady(timeout: 300) }

                var setup = SetupOptions()
                setup.speed = s.speed
                setup.pressure = s.force
                setup.depth = s.blade
                setup.autoblade = info.autoblade && layer.tool == .blade
                setup.toolholder = layer.holder
                setup.pen = layer.tool != .blade
                setup.cuttingMat = cuttingMat ? (mat ?? hardware.defaultCuttingMat) : CuttingMat.none
                setup.mediaWidth = media.width
                setup.mediaHeight = media.height
                setup.skipInit = index > 0
                setup.trackEnhancing = trackEnhancing
                // Studio order: the first layer's tool goes after the marks are read.
                let readFirst = studioOrder && registration != nil && index == 0
                setup.toolSettings = !readFirst
                try await self.setup(setup)

                if readFirst, let registration {
                    onProgress?(CutProgress(layer: 1, layerCount: layers.count, layerName: layer.name, pass: 1, passCount: s.passes))
                    log("Reading the registration marks (up to ~40 s)…")
                    var marks = PlotOptions()
                    marks.mediaWidth = media.width
                    marks.mediaHeight = media.height
                    marks.registration = registration
                    marks.studioRegistration = true
                    marks.skipReset = true
                    try await self.plot([], marks)
                    setup.skipInit = true
                    setup.toolSettings = true
                    try await self.setup(setup)
                }

                for pass in 0..<s.passes {
                    count += 1
                    if !(readFirst && pass == 0) {
                        onProgress?(CutProgress(layer: index + 1, layerCount: layers.count, layerName: layer.name,
                                                pass: pass + 1, passCount: s.passes))
                    }
                    var plot = PlotOptions()
                    plot.mediaWidth = media.width
                    plot.mediaHeight = media.height
                    plot.endPosition = .start
                    plot.registration = registration
                    plot.studioRegistration = studioOrder && registration != nil
                    // With the Studio order the marks were already read (above).
                    plot.skipInit = count > 1 || plot.studioRegistration
                    plot.skipReset = registration != nil ? count < total : pass < s.passes - 1
                    if registration != nil, count == 1, !studioOrder { log("Reading the registration marks (up to ~40 s)…") }
                    try await self.plot(layer.paths, plot)
                }
            }
        } catch {
            if heatPenOn { try? await turnOffHeatPen() }
            throw error
        }
        let status: Status = isSimulated ? .ready : try await waitForReady(timeout: 300)
        if heatPenOn { try await turnOffHeatPen() }
        return status
    }

    /// Holder 2 only where there are two holders; the Heat Pen only where the model takes it; and one tool per holder in
    /// the job (Cutline doesn't stop to swap tools, so on a one-holder machine colors with different tools go in separate
    /// jobs).
    public nonisolated func validateTools(_ layers: [CutLayer], info: MachineInfo) throws {
        for layer in layers {
            guard (1...2).contains(layer.holder), layer.holder == 1 || info.twoHolders else {
                throw CutterError.invalidSettings(localized("This machine has one tool holder: “\(layer.name)” is set to holder 2."))
            }
            if layer.tool == .heatPen, !info.heatPen {
                throw CutterError.invalidSettings(localized("This machine doesn’t take the Heat Pen (“\(layer.name)”)."))
            }
        }
        for holder in 1...2 {
            let tools = Set(layers.filter { $0.holder == holder }.map(\.tool))
            guard tools.count <= 1 else {
                throw CutterError.invalidSettings(info.twoHolders
                    ? localized("Tool holder \(holder) has colors with different tools. Use the other holder, or send them separately (turn the other colors off).")
                    : localized("Colors with different tools have to be sent separately: turn the other colors off, cut, swap the tool and send the rest."))
            }
        }
    }

    /// Heat Pen (Studio's commands): `TS0,1` turns it on; while it heats the machine's status (`ESC ENQ`) answers 6, and
    /// `TS2` says how the pen is (−1 error, 0 ready, 1 heating). Studio says it takes about 3 minutes; Cutline waits up to
    /// 6 and keeps the progress going.
    func heatUpHeatPen(_ onProgress: (Int) -> Void) async throws {
        try await send("TS0,1")
        log("Heat Pen: on, heating…")
        if isSimulated {
            log("Heat Pen: simulated, ready at once.")
            return
        }
        let start = Date()
        let typical = 180.0, limit = 360.0
        while true {
            let state = try await status()
            let response = try await query("TS2")
            let value = response.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            log("Heat Pen: status \(state), TS2 '\(response ?? "None")'")
            // Ready: the machine no longer says "heating" (6) and the pen says 0 (without an answer from the pen, the
            // machine's status decides).
            let heating = state == .other("6")
            if !heating, value == 0 || (value == nil && state == .ready) {
                log("Heat Pen: ready.")
                return
            }
            if value == -1 {
                throw CutterError.invalidSettings(localized("The Heat Pen reported an error. Check that it is plugged into the machine and in the tool holder."))
            }
            let elapsed = Date().timeIntervalSince(start)
            if elapsed > limit {
                throw CutterError.invalidSettings(localized("The Heat Pen didn’t heat up in 6 minutes."))
            }
            onProgress(max(0, Int(typical - elapsed)))
            try await Task.sleep(for: .seconds(3))
        }
    }

    /// `TS0,0`: at the end of the job, or when it stops.
    func turnOffHeatPen() async throws {
        try await send("TS0,0")
        log("Heat Pen: off.")
    }
}
