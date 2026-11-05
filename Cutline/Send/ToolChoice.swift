// Send window: tool holder (1 or 2) and tool (blade, pen, foil, emboss, Heat Pen) for each line color. Experimental:
// only the blade in holder 1 has been tried on a machine. The driver turns holder and tool into commands
// (CutlineKit/CutJob.swift); everything but the blade goes without the blade offset or the AutoBlade.
import CutlineKit
import SwiftUI

extension CutTool {
    var name: String {
        switch self {
        case .blade: String(localized: "Blade")
        case .pen: String(localized: "Pen")
        case .foil: String(localized: "Foil")
        case .emboss: String(localized: "Emboss")
        case .heatPen: String(localized: "Heat Pen")
        }
    }

    /// The tools this model takes (Studio's table): emboss only on the Cameo 5 line, the Heat Pen on the Portrait 4 and
    /// the Cameo 5. Without a model (no machine used yet), all of them: the send checks.
    static func available(on hardware: Hardware?) -> [CutTool] {
        allCases.filter { tool in
            guard let hardware else { return true }
            switch tool {
            case .emboss: return hardware.hasEmboss
            case .heatPen: return hardware.hasHeatPen
            default: return true
            }
        }
    }
}

enum ToolDetection {
    /// The machine's answer to "which tools are in the holders" ("2,8"), one name per holder; nil if it doesn't parse.
    /// Codes from Studio's table (Cameo 4/5, Portrait 3/4).
    static func names(_ answer: String?, on hardware: Hardware) -> [String]? {
        guard let answer else { return nil }
        let codes = answer.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !codes.isEmpty, codes.allSatisfy({ $0 != nil }) else { return nil }
        return codes.map { name(code: $0!, on: hardware) }
    }

    static func name(code: Int, on hardware: Hardware) -> String {
        // On the machines that take the Heat Pen, code 8 is it (Studio calls it its foil tool).
        if code == 8, hardware.hasHeatPen { return CutTool.heatPen.name }
        return switch code {
        case 0: String(localized: "empty")
        case 1: String(localized: "Ratchet Blade")
        case 2: String(localized: "AutoBlade")
        case 3: String(localized: "Deep-Cut Blade")
        case 4: String(localized: "Kraft Blade")
        case 5: String(localized: "Rotary Blade")
        case 6: String(localized: "Punch Tool")
        case 7: String(localized: "Pen")
        case 8: String(localized: "Foil")
        case 11: String(localized: "Emboss Tool")
        case 15: String(localized: "Fine-Cut Blade")
        case 17: String(localized: "Sonic Blade")
        case 18: String(localized: "Glue Tape Tool")
        default: String(localized: "tool \(code)")
        }
    }

    /// "holder 1 · AutoBlade, holder 2 · Foil" (one holder: just the name).
    static func summary(_ answer: String?, on hardware: Hardware) -> String? {
        guard let names = names(answer, on: hardware) else { return nil }
        if names.count == 1 { return names[0] }
        return names.enumerated().map { String(localized: "holder \($0.offset + 1) · \($0.element)") }.joined(separator: ", ")
    }
}

/// The "Tool" row of the chosen color: holder, tool, what the machine says it has, and the experimental notice.
struct ToolChoice: View {
    let doc: Document
    let color: CMYK
    @Environment(Machine.self) private var machine

    var body: some View {
        let config = doc.config(color)
        let model = knownModel
        let tools = CutTool.available(on: model)
        VStack(alignment: .leading, spacing: 5) {
            LabeledContent("Tool") {
                HStack(spacing: 8) {
                    if (model ?? machine.hardware).hasTwoTools || config.holder == 2 {
                        Picker("Tool holder", selection: binding(config, \.holder)) {
                            Text("Holder 1").tag(1)
                            Text("Holder 2").tag(2)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    Picker("Tool", selection: binding(config, \.tool)) {
                        Text(CutTool.blade.name).tag(CutTool.blade)
                        Section("Experimental") {
                            ForEach(tools.filter { $0 != .blade } + (tools.contains(config.tool) ? [] : [config.tool]), id: \.self) {
                                Text($0.name).tag($0)
                            }
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if config.experimentalTool {
                        ExperimentalBadge()
                    } else {
                        Text(machine.info?.autoblade == false ? "Manual blade" : "AutoBlade (automatic)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                if let detected = ToolDetection.summary(machine.tools, on: machine.hardware) {
                    Text("In the machine now: \(detected)")
                }
                if config.experimentalTool {
                    HStack(spacing: 4) {
                        Text("Holder 2 and the pen, foil, emboss and Heat Pen haven’t been tried on a machine yet.")
                        ReportProblemLink(feature: .tools) { Self.reportContext(doc: doc, machine: machine) }
                    }
                    if config.tool == .heatPen {
                        Text("The Heat Pen heats up before the job starts (about 3 minutes) and turns off at the end. Don’t touch it while its light is red.")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The connected model, or the last one used; nil if no machine was ever used here (all tools show).
    private var knownModel: Hardware? {
        machine.info != nil || machine.current != nil ? machine.hardware : nil
    }

    private func binding<Value>(_ config: CutConfig, _ key: WritableKeyPath<CutConfig, Value>) -> Binding<Value> {
        Binding(get: { config[keyPath: key] }, set: { value in
            var updated = config
            updated[keyPath: key] = value
            doc.setConfig(updated, to: color)
        })
    }

    /// What goes into a report from the "Report a Problem…" link: the machine, what it says is in the holders, and the
    /// holder, tool and settings of each color in the cutting order. The person sees it before sending.
    static func reportContext(doc: Document, machine: Machine) -> String {
        var lines = ["### " + String(localized: "Experimental: tool holder 2 and tools")]
        let model = machine.info != nil || machine.current != nil ? machine.hardware : nil
        if let model {
            let features = [model.hasTwoTools ? "two tool holders" : "one tool holder",
                            model.hasHeatPen ? "Heat Pen" : nil, model.hasEmboss ? "emboss" : nil].compactMap(\.self)
            lines.append("- Machine: \(machine.info != nil ? machine.modelName : model.name) · \(features.joined(separator: " · "))")
        } else {
            lines.append("- Machine: none used yet")
        }
        lines.append("- Detected in the holders: " + (machine.tools.map { answer in
            "\(ToolDetection.summary(answer, on: machine.hardware) ?? "?") (\(answer))"
        } ?? (model?.detectsTools == true ? "no answer" : "this model doesn’t say")))
        for (index, line) in doc.cutLines.enumerated() {
            let c = doc.config(line.color), s = c.settings
            let blade = c.tool == .blade ? ", blade \(s.blade)" : ""
            lines.append("- \(index + 1). \(line.color.summaryText) · \(c.material) · holder \(c.holder) · \(c.tool.rawValue)"
                         + " · force \(s.force), speed \(s.speed)\(blade), \(s.passes) pass(es)"
                         + " · \(line.objects.count) object(s)" + (c.sends ? "" : " · off"))
        }
        return lines.joined(separator: "\n")
    }
}
