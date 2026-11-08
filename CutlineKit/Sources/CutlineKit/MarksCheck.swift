// Register Marks (Print & Cut): reads the marks as before a cut and, without cutting, takes the tool (up) to the corner
// of each mark, stopping at each one, so the person sees where the machine thinks they are. Every byte sent and
// received goes into a timeline timed from the start, to compare with a video of the machine.
import Foundation

/// One moment of a marks check.
public struct MarksCheckEvent: Sendable {
    /// From the start of the check.
    public let seconds: Double
    public let date: Date
    public let text: String
}

/// While a marks check runs, the `Cutter` adds every write and read here (Cutter.swift).
struct MarksTimeline: Sendable {
    let start = ContinuousClock.now
    private(set) var events: [MarksCheckEvent] = []

    mutating func add(_ text: String) {
        let d = start.duration(to: .now).components
        events.append(MarksCheckEvent(seconds: Double(d.seconds) + Double(d.attoseconds) * 1e-18, date: Date(), text: text))
    }
}

/// Where the tool stops after the marks are read: the corners of the area between the marks, in this order.
public enum MarksCheckStop: Int, Sendable, CaseIterable {
    /// The square's outer corner (the registration's origin).
    case square
    /// The outer corner of the top-right corner mark.
    case topRight
    /// The area's fourth corner, which has no mark.
    case bottomRight
    /// The outer corner of the bottom-left corner mark.
    case bottomLeft
    /// Back over the square, to close the rectangle.
    case squareAgain

    /// The stop in the registration's mm (from the square's outer corner; x across, y along the feed).
    func point(_ r: Cutter.Registration) -> CGPoint {
        switch self {
        case .square, .squareAgain: .zero
        case .topRight: CGPoint(x: r.width, y: 0)
        case .bottomRight: CGPoint(x: r.width, y: r.length)
        case .bottomLeft: CGPoint(x: 0, y: r.length)
        }
    }

    var name: String {
        switch self {
        case .square: "the square's corner"
        case .topRight: "the top-right corner mark's corner"
        case .bottomRight: "the area's bottom-right corner (no mark there)"
        case .bottomLeft: "the bottom-left corner mark's corner"
        case .squareAgain: "the square's corner again"
        }
    }
}

public enum MarksCheckStep: Sendable {
    case reading
    case pointing(MarksCheckStop)
    case returning
}

extension Cutter {
    /// Reads the Print & Cut marks with the same commands as a cut (the setup with the lightest force, `TB123` and its
    /// reply) and, without cutting, moves the tool up to each `MarksCheckStop`, waiting for the machine to stop and
    /// `pause` seconds more at each, then goes back to the origin as a cut does. Returns the timeline (also when the
    /// marks aren't found: then the error comes with it).
    public func checkMarks(_ registration: Registration, media: CGSize, cuttingMat: Bool, mat: CuttingMat?,
                           studioOrder: Bool = false, pause: Double = 3, onStep: (@Sendable (MarksCheckStep) -> Void)? = nil)
        async -> (events: [MarksCheckEvent], error: Error?) {
        timeline = MarksTimeline()
        defer { timeline = nil }
        let r = registration
        note("Register Marks on \(hardware.name)\(isSimulated ? " (simulated)" : ""), sheet \(mm(media.width)) × \(mm(media.height)) mm")
        note("Square's outer corner expected at x \(mm(r.originX)), y \(mm(r.originY)) mm of the sheet; top-right corner mark's at x "
             + "\(mm(r.originX + r.width)), y \(mm(r.originY)); bottom-left corner mark's at x \(mm(r.originX)), y \(mm(r.originY + r.length))")
        note("The search starts at x \(mm(max(r.originX - 10, 0))), y \(mm(max(r.originY - 10, 0))) mm (x across the machine, "
             + "y along the feed, from the sheet's corner that goes in first)")
        do {
            var setup = SetupOptions()
            setup.speed = 3
            setup.pressure = 1
            setup.autoblade = false
            setup.cuttingMat = cuttingMat ? (mat ?? hardware.defaultCuttingMat) : CuttingMat.none
            setup.mediaWidth = media.width
            setup.mediaHeight = media.height
            note("Setup (force 1, speed 3; nothing is cut)")
            try await self.setup(setup)

            onStep?(.reading)
            note("Reading the marks (up to ~40 s)")
            var plot = PlotOptions()
            plot.mediaWidth = media.width
            plot.mediaHeight = media.height
            plot.registration = r
            plot.studioRegistration = studioOrder
            plot.skipReset = true
            if studioOrder { note("Studio order: TB99 and the area between the marks after reading them, TB0 at the end") }
            try await self.plot([], plot)
            note("Marks found")

            // The same offset as the cut's coordinates (Cutter.plot): the media margins on top of the registration's mm.
            let top = hardware.marginTopMM ?? 0, left = hardware.marginLeftMM ?? 0
            for stop in MarksCheckStop.allCases {
                onStep?(.pointing(stop))
                let p = stop.point(r)
                note("Tool up to \(stop.name): x \(mm(p.x)), y \(mm(p.y)) mm from the square's corner "
                     + "(x \(mm(p.x + r.originX)), y \(mm(p.y + r.originY)) mm of the sheet)")
                try await send(GPGL.move(y: p.y + top, x: p.x + left))
                if !isSimulated {
                    let state = try await waitForReady(timeout: 60, pollInterval: 0.2)
                    note("Stopped over \(stop.name) (\(state))")
                    try await Task.sleep(for: .seconds(pause))
                }
            }

            onStep?(.returning)
            note("Back to the origin")
            let home = hardware.isCameo3On ? ["L0", GPGL.upperLeft(y: 0, x: 0), GPGL.move(y: 0, x: 0), "J0", "FN0", "TB50,0"] : ["H"]
            try await send((studioOrder ? ["TB0"] : []) + home)
            if !isSimulated { _ = try await waitForReady(timeout: 120, pollInterval: 0.5) }
            note("Done")
            return (timeline?.events ?? [], nil)
        } catch {
            note("Stopped: \(error.localizedDescription)")
            return (timeline?.events ?? [], error)
        }
    }

    private func note(_ text: String) {
        timeline?.add("# " + text)
        log(text)
    }

    private nonisolated func mm(_ value: Double) -> String { String(format: "%.2f", value) }
}
