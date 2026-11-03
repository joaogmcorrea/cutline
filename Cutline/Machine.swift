// Connection to the cutter (USB cable or Bluetooth LE, through CutlineKit) and the job queue.
// One operation at a time: the Cutter doesn't accept commands in parallel, and the queue only sends the next job
// when the machine says it finished the previous one. With Silhouette Studio open, nothing connects or cuts:
// both can't use the cutter at the same time.
import AppKit
import Foundation
import Observation
import CutlineKit

@Observable
final class Machine {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        /// More than one cutter in range and none used before: the user chooses.
        case choose([DiscoveredCutter])
        case connected
        case sending(String)
        case sent
        case failure(String)
    }

    private(set) var state = ConnectionState.disconnected
    private(set) var info: MachineInfo?
    /// Latest driver messages (for diagnostics).
    private(set) var logLines: [String] = []
    /// Cutters seen in the last search (to switch when there is more than one).
    private(set) var discovered: [DiscoveredCutter] = []
    /// The connected cutter (or the last one used).
    private(set) var current: DiscoveredCutter?

    /// Jobs sent in this session: waiting, cutting and the finished ones (until cleared).
    private(set) var queue: [Job] = []

    /// Silhouette Studio open (it or its Bluetooth helper): while it is, Cutline doesn't connect or send.
    private(set) var studioOpen = false

    private var cutter: Cutter?
    private var busy = false
    private var processing = false
    /// Someone wanted the machine (or it was connected) while Studio was open: connects when it closes.
    private var connectAfterStudio = false
    @ObservationIgnored private var studioObservers: [NSObjectProtocol] = []

    #if DEBUG
    /// CUTLINE_SIMULATE=1: no machine, like the test's `--simular`.
    private let simulate = ProcessInfo.processInfo.environment["CUTLINE_SIMULATE"] != nil
    #else
    private let simulate = false
    #endif

    /// "Silhouette_Portrait4" → "Portrait 4".
    var modelName: String {
        guard let name = info?.model else { return "Silhouette" }
        return name.replacingOccurrences(of: "Silhouette_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"([A-Za-z])(\d)"#, with: "$1 $2", options: .regularExpression)
    }

    /// "Portrait 4 V1.05" → "Firmware 1.05".
    var firmware: String? {
        guard let text = info?.firmware, let v = text.range(of: #"V[\d.]+"#, options: .regularExpression) else { return nil }
        return "Firmware " + text[v].dropFirst()
    }

    var maxSpeed: Int { info?.maxSpeed ?? 30 }

    /// The connected model (or the last one used); with none, the Portrait 4 (the Page panel's mats follow it).
    var hardware: Hardware {
        info.flatMap { Hardware.named($0.model) } ?? Hardware.match(current) ?? .portrait4
    }

    init() {
        current = Self.last
        watchStudio()
    }

    /// Connects (if needed) and reads model, firmware and status. With `chosen`, switches to it.
    func connect(_ chosen: DiscoveredCutter? = nil) async {
        guard !studioOpen else {
            connectAfterStudio = true
            return
        }
        guard !busy else { return }
        busy = true
        defer {
            busy = false
            // The queue may have been waiting for the connection (or for the machine choice).
            Task { await processQueue() }
        }
        if let chosen, chosen != current || cutter == nil {
            await cutter?.close()
            cutter = nil
            info = nil
        }
        state = .connecting
        do {
            let cutter = try await connectedCutter(chosen)
            info = try await cutter.info()
            state = .connected
        } catch MachineError.choose(let list) {
            state = .choose(list)
        } catch {
            await failed(error)
        }
    }

    // MARK: Queue

    /// Puts the job in the queue; starts right away if the machine is free. With `registration` (Print & Cut), the
    /// machine reads the marks on the printed sheet before the first cut.
    func enqueue(_ job: Job) {
        guard !job.layers.isEmpty else { return }
        queue.append(job)
        Task { await processQueue() }
    }

    /// Removes from the queue (the one being cut stays: the machine already received the commands).
    func removeItem(_ id: Job.ID) {
        queue.removeAll { $0.id == id && !$0.inProgress }
        Task { await processQueue() }
    }

    /// Puts the stopped job back in the queue (in the same place: it is the first to go).
    func retry(_ id: Job.ID) {
        guard let i = queue.firstIndex(where: { $0.id == id }), queue[i].status.didStop else { return }
        queue[i].status = .waiting
        Task { await processQueue() }
    }

    func clearFinished() { queue.removeAll { $0.status == .done } }

    /// The job that stopped the queue (error or marks not found), if any.
    var stopped: Job? { queue.first { $0.status.didStop } }

    /// How many jobs go before this one (0 = it's next or already cutting).
    func ahead(of id: Job.ID) -> Int {
        let activeOnes = queue.filter { $0.status == .waiting || $0.inProgress }
        return activeOnes.firstIndex { $0.id == id } ?? 0
    }

    /// Waiting or cutting.
    var pending: Int { queue.filter { $0.status == .waiting || $0.inProgress }.count }

    /// Sends the waiting jobs, one at a time; stops at the first one that fails.
    private func processQueue() async {
        guard !processing else { return }
        processing = true
        defer { processing = false }
        while !busy, !studioOpen, stopped == nil, let next = queue.first(where: { $0.status == .waiting }) {
            guard await cutJob(next) else { break }
        }
        // Studio opened during a cut: once the cut is done, the machine is free for it.
        if studioOpen, !busy { await drop() }
    }

    /// Cuts a job. False = the queue has to wait for the user (choose the machine).
    private func cutJob(_ job: Job) async -> Bool {
        busy = true
        defer { busy = false }
        let id = job.id
        do {
            if cutter == nil { state = .connecting }
            let cutter = try await connectedCutter(nil)
            display(String(localized: "Checking the machine…"), id)
            await cutter.clearTranscript()
            var info = try await cutter.info()
            // Still cutting a previous job (left in the machine's memory): wait for it to finish
            // before sending another.
            if info.status == .moving, !simulate {
                display(String(localized: "Waiting for the machine to finish the previous job…"), id)
                _ = try await cutter.waitForReady(timeout: 600)
                info = try await cutter.info()
            }
            self.info = info
            guard info.status != .unloaded || simulate else {
                let text = job.withMat ? String(localized: "Load the mat into the machine and try again.")
                    : String(localized: "Load the sheet into the machine and try again.")
                status(.failure(text), id)
                state = .connected
                return true
            }
            #if DEBUG
            if job.logLines != nil, DebugHooks.marksFail { throw CutterError.registrationMarksNotFound("simulado") }
            #endif
            try await cutter.cut(job.layers, info: info, registration: job.logLines,
                                    cuttingMat: job.withMat, mat: job.base) { [weak self] progress in
                let color = progress.passCount > 1
                    ? String(localized: "color \(progress.layer) of \(progress.layerCount) — pass \(progress.pass) of \(progress.passCount)")
                    : String(localized: "color \(progress.layer) of \(progress.layerCount)")
                // Reading the marks (up to ~40 s) comes right before the first cut.
                let marks = job.logLines != nil && progress.layer == 1 && progress.pass == 1
                let text = marks ? String(localized: "Reading the registration marks and cutting \(color)…") : String(localized: "Cutting \(color)…")
                Task { @MainActor in self?.display(text, id) }
            }
            status(.done, id)
            state = .sent
        } catch MachineError.choose(let list) {
            status(.waiting, id)
            state = .choose(list)
            return false
        } catch CutterError.registrationMarksNotFound(_) {
            // The connection is still good: the notice stays on the job (and in the tips window).
            status(.marksNotFound, id)
            state = .connected
        } catch {
            status(.failure(error.localizedDescription), id)
            await failed(error)
        }
        await saveTranscript()
        return true
    }

    private func display(_ text: String, _ id: Job.ID) {
        state = .sending(text)
        status(.cutting(text), id)
    }

    private func status(_ newOne: Job.JobStatus, _ id: Job.ID) {
        if let i = queue.firstIndex(where: { $0.id == id }) { queue[i].status = newOne }
    }

    private enum MachineError: Error {
        case choose([DiscoveredCutter])
    }

    /// The current connection, or a new one: the chosen one; else the only one in range; else the last one used;
    /// else asks the user to choose.
    private func connectedCutter(_ chosen: DiscoveredCutter?) async throws -> Cutter {
        if let cutter { return cutter }
        let log: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor in self?.note(line) }
        }
        let target: DiscoveredCutter
        if let chosen {
            target = chosen
        } else {
            let list = try await discover(log: log)
            discovered = list
            if list.count == 1 {
                target = list[0]
            } else if let last = list.first(where: { $0.id == Self.last?.id }) {
                target = last
            } else {
                throw MachineError.choose(list)
            }
        }
        let newOne = simulate ? Cutter.simulated(.portrait4, log: log)
            : target.link == .usb ? try await Cutter.connectUSB(identifier: target.id, log: log)
            : try await Cutter.connectBluetooth(identifier: target.id, log: log)
        cutter = newOne
        current = target
        if !simulate { Self.last = target }
        return newOne
    }

    private func discover(log: @escaping @Sendable (String) -> Void) async throws -> [DiscoveredCutter] {
        #if DEBUG
        // CUTLINE_SIMULATE=2: two simulated machines, to see the choice.
        if simulate {
            let twoOf = ProcessInfo.processInfo.environment["CUTLINE_SIMULATE"] == "2"
            let names = twoOf ? ["Portrait 4-0000001", "Portrait 4-0000002"] : ["Portrait 4-0000001"]
            return names.enumerated().map {
                DiscoveredCutter(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\($0.offset + 1)")!, name: $0.element)
            }
        }
        #endif
        // Settings › Machine prefers Bluetooth: searched first; the cable if nothing answers.
        if PreferredConnection.current == .bluetooth {
            do {
                let found = try await Cutter.findBluetooth(log: log)
                if !found.isEmpty { return found }
            } catch {
                let usb = Cutter.findUSB(log: log)
                if usb.isEmpty { throw error }
                return usb
            }
            return Cutter.findUSB(log: log)
        }
        // Machine on the cable: uses USB (the search is immediate and doesn't depend on Bluetooth) and skips Bluetooth.
        let usb = Cutter.findUSB(log: log)
        if !usb.isEmpty { return usb }
        return try await Cutter.findBluetooth(log: log)
    }

    /// Last cutter used on this Mac (UserDefaults).
    private static var last: DiscoveredCutter? {
        get {
            UserDefaults.standard.data(forKey: "ultimaMaquina").flatMap { try? JSONDecoder().decode(DiscoveredCutter.self, from: $0) }
        }
        set {
            UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "ultimaMaquina")
        }
    }

    private func failed(_ error: Error) async {
        // Job errors (mat, settings, limits) keep the connection — the message stays on the queued job;
        // the others drop the connection, to connect again next time.
        let fromJob: Bool = switch error as? CutterError {
        case .mediaNotLoaded, .invalidSettings, .outOfBounds, .registrationMarksNotFound: true
        default: false
        }
        state = fromJob && cutter != nil ? .connected : .failure(error.localizedDescription)
        if !fromJob {
            await cutter?.close()
            cutter = nil
        }
    }

    // MARK: Silhouette Studio

    /// Studio and its Bluetooth (ss_bluetooth, srt_helper) live inside "Silhouette Studio.app"; the
    /// helpers have generic identifiers, so the app path counts too.
    nonisolated private static func isStudio(_ app: NSRunningApplication) -> Bool {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        let id = app.bundleIdentifier ?? ""
        return id.hasPrefix("com.silhouettesoftware.") || id.hasPrefix("com.aspexsoftware.")
            || app.bundleURL?.path.contains("/Silhouette Studio") == true
    }

    nonisolated private static var studioProcesses: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter(isStudio)
    }

    /// CUTLINE_TEST_IGNORE_STUDIO=1 pretends Studio is closed (to test the simulated send with it open).
    nonisolated private static var studioRunning: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CUTLINE_TEST_IGNORE_STUDIO"] != nil { return false }
        #endif
        return !studioProcesses.isEmpty
    }

    /// Follows Studio opening and closing while Cutline is open.
    private func watchStudio() {
        studioOpen = Self.studioRunning
        let center = NSWorkspace.shared.notificationCenter
        studioObservers = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notice in
                guard let app = notice.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      Self.isStudio(app) else { return }
                MainActor.assumeIsolated { self?.studioChanged() }
            }
        }
    }

    private func studioChanged() {
        let opened = Self.studioRunning
        guard opened != studioOpen else { return }
        studioOpen = opened
        if opened {
            // Idle, the machine goes to Studio; cutting, the cut finishes first (in `processQueue`).
            if cutter != nil { connectAfterStudio = true }
            if !busy { Task { await drop() } }
        } else if connectAfterStudio || pending > 0 {
            connectAfterStudio = false
            // Studio's Bluetooth takes a moment to release the machine.
            Task {
                try? await Task.sleep(for: .seconds(2))
                await connect()
            }
        }
    }

    /// Closes the connection so Studio can use the machine.
    private func drop() async {
        guard cutter != nil else { return }
        await cutter?.close()
        cutter = nil
        info = nil
        state = .disconnected
    }

    /// "Quit Silhouette Studio" button: asks it to quit, like its ⌘Q (if something is unsaved, Studio
    /// itself asks). The helpers quit along; if one is left behind, a second click closes it.
    func quitStudio() {
        let processes = Self.studioProcesses
        let mainOnes = processes.filter { !($0.bundleURL?.path.contains(".app/Contents/") ?? false) }
        for app in mainOnes.isEmpty ? processes : mainOnes { app.terminate() }
    }

    private func note(_ line: String) {
        logLines.append(line)
        if logLines.count > 300 { logLines.removeFirst(logLines.count - 300) }
    }

    /// Transcript of the commands sent, in ~/Library/Logs/Cutline (like the test's logs/*.gpgl).
    private func saveTranscript() async {
        guard let cutter else { return }
        let payload = await cutter.transcript
        guard !payload.isEmpty else { return }
        let folder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Cutline")
        let format = DateFormatter()
        format.dateFormat = "yyyyMMdd-HHmmss"
        let name = format.string(from: Date()) + (simulate ? "-simulado" : "") + ".gpgl"
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? payload.write(to: folder.appending(path: name))
    }
}

extension Job {
    var inProgress: Bool { if case .cutting = status { true } else { false } }
}
