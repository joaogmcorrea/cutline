// Job queue: the list (in the Send window and in the toolbar's machine menu) and the machine pill.
import CutlineKit
import SwiftUI

/// This session's jobs, in the order they go to the machine.
struct QueueList: View {
    @Environment(Machine.self) private var machine

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Job queue").font(.headline)
                Spacer()
                if machine.queue.contains(where: { $0.status == .done }) {
                    Button("Clear Finished") { machine.clearFinished() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
            if machine.queue.isEmpty {
                Text("Nothing in the queue. Each Send goes here; the machine cuts one job at a time.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 2) {
                ForEach(machine.queue) { job in QueueRow(job: job) }
            }
            if let stopped = machine.stopped, machine.pending > 0 {
                Label("The queue stopped at “\(stopped.name)”: try again or remove it from the queue to continue.", image: .pause)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct QueueRow: View {
    @Environment(Machine.self) private var machine
    let job: Job

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.name).lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(job.status.didStop ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            if job.status.didStop {
                Button("Try Again", image: .refresh) { machine.retry(job.id) }
                    .help("Try Again")
            }
            if !job.inProgress {
                Button("Remove from Queue", image: .close) { machine.removeItem(job.id) }
                    .help(job.status == .done ? "Remove from List" : "Remove from Queue")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(job.inProgress ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var icon: some View {
        switch job.status {
        case .waiting: Image(.clock).foregroundStyle(.secondary)
        case .cutting: ProgressView().controlSize(.small)
        case .done: Image(.checkCircle).foregroundStyle(.green)
        case .failure: Image(.warning).foregroundStyle(.orange)
        case .marksNotFound: Image(.registrationMarks).foregroundStyle(.orange)
        }
    }

    private var detail: String {
        let colors = String(localized: "\(job.layers.count) colors")
        let extras = [job.logLines != nil ? "Print & Cut" : nil, job.withMat ? nil : String(localized: "no mat")].compactMap(\.self)
        let summary = ([colors] + extras).joined(separator: " · ")
        switch job.status {
        case .waiting:
            let front = machine.ahead(of: job.id)
            return summary + " · " + (front == 0 ? String(localized: "next") : String(localized: "\(front) ahead"))
        case .cutting(let text): return text
        case .done: return summary + " · " + String(localized: "cut")
        case .failure(let text): return text
        case .marksNotFound: return String(localized: "The machine couldn’t find the marks — nothing was cut.")
        }
    }
}

/// Machine pill in the toolbar (● Portrait 4), as in the prototype: the status and, when clicked, the machine and the queue.
struct MachinePill: View {
    @Environment(Machine.self) private var machine
    @State private var isOpen = false

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(text).lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
        .help(machine.studioOpen ? "Close Silhouette Studio: the two can't use the machine at the same time" as LocalizedStringKey
              : "Machine and job queue")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 16) {
                StudioNotice()
                MachineCard()
                QueueList()
            }
            .padding(16)
            .frame(width: 440)
        }
    }

    private var name: String { machine.info == nil ? machine.current?.model ?? String(localized: "Machine") : machine.modelName }

    private var text: String {
        if machine.studioOpen { return String(localized: "Close Silhouette Studio") }
        if machine.stopped != nil { return String(localized: "\(name) · queue stopped") }
        let pending = machine.pending
        if pending > 1 { return String(localized: "\(name) · \(pending) in queue") }
        if pending == 1 { return String(localized: "\(name) · cutting") }
        return name
    }

    private var color: Color {
        if machine.studioOpen || machine.stopped != nil { return .orange }
        switch machine.state {
        case .connected, .sent: return machine.info?.status == .unloaded ? .orange : .green
        case .sending, .connecting: return .accentColor
        case .choose: return .orange
        case .disconnected, .failure: return .secondary
        }
    }
}

/// Silhouette Studio open: Cutline and Studio can't use the cutter at the same time (Send window and
/// the toolbar's machine menu).
struct StudioNotice: View {
    @Environment(Machine.self) private var machine

    var body: some View {
        if machine.studioOpen {
            HStack(alignment: .top, spacing: 10) {
                Image(.warning)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Close Silhouette Studio").font(.headline)
                    Text("Cutline and Silhouette Studio can't use the cutter at the same time. While Studio is open, Cutline won't connect or send; once it closes, the connection comes back on its own.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Quit Silhouette Studio") { machine.quitStudio() }
                        .help("Asks Studio to quit; if anything is unsaved, Studio asks first")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
