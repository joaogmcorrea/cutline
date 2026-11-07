// Page section of the side menu (like Silhouette Studio's Page Setup): machine, cutting mat, the active artboard's size
// and orientation, and the Print & Cut marks. The mat and the marks belong to the document (each artboard gets its
// marks).
import CutlineKit
import SwiftUI

struct PageSection: View {
    @Bindable var doc: Document
    @Environment(Machine.self) private var machine
    @AppStorage(LengthUnit.key) private var unit = LengthUnit.mm

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 9) {
                GridRow {
                    label("Machine")
                    HStack(spacing: 6) {
                        Circle().fill(connected ? Color.green : .secondary).frame(width: 7, height: 7)
                        Text(machineName).lineLimit(1)
                        Spacer(minLength: 0)
                        if !connected {
                            Button("Connect") { Task { await machine.connect() } }
                                .controlSize(.small)
                        }
                    }
                }
                GridRow {
                    label("Cutting mat")
                    // The mats Studio offers for this machine.
                    Picker("Cutting mat", selection: Binding(get: { doc.base(to: machine.hardware) }, set: { doc.setMat($0) })) {
                        ForEach(machine.hardware.supportedCuttingMats, id: \.self) { base in
                            Text(base.name).tag(base)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
                let artboard = doc.activeArtboard
                GridRow {
                    label("Page")
                    HStack(spacing: 4) {
                        PresetMenu(doc: doc, artboard: artboard)
                        Spacer(minLength: 0)
                        OrientationButtons(doc: doc, artboard: artboard)
                    }
                }
                GridRow {
                    Text(verbatim: "").gridColumnAlignment(.trailing)
                    ArtboardSizeFields(doc: doc, artboard: artboard)
                        .controlSize(.small)
                }
                if doc.artboards.count > 1 {
                    GridRow {
                        Text(verbatim: "").gridColumnAlignment(.trailing)
                        Text("Artboard \(doc.activeIndex + 1) of \(doc.artboards.count): \(artboard.title(doc.activeIndex))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                GridRow {
                    label("Print & Cut")
                    Toggle("Registration marks", isOn: Binding(get: { doc.marks }, set: { if $0 != doc.marks { doc.toggleMarks() } }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                if doc.marks {
                    GridRow {
                        label("Margin")
                        HStack(spacing: 4) {
                            lengthField(Binding(get: { doc.marksConfig.margin ?? doc.marksConfig.left }, set: { newOne in
                                var config = doc.marksConfig
                                (config.left, config.top, config.right, config.bottom) = (newOne, newOne, newOne, newOne)
                                doc.setMarks(config)
                            }), span: 5...50)
                            Menu("Presets") {
                                Button("Like Cutline (15 mm, 20 mm corner marks)") { doc.setMarks(.defaultValue) }
                                Button("Like Silhouette Studio (5/8 in, 20 mm corner marks)") { doc.setMarks(.studio) }
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("The margin and corner marks must match the printed sheet")
                        }
                    }
                    GridRow {
                        label("Corner marks")
                        lengthField(Binding(get: { doc.marksConfig.length }, set: { updated in
                            var config = doc.marksConfig
                            config.length = updated
                            doc.setMarks(config)
                        }), span: 5...50)
                    }
                    GridRow {
                        label("Bleed")
                        HStack(spacing: 8) {
                            Toggle("Print bleed", isOn: Binding(get: { doc.bleed.enabled }, set: { on in
                                var bleed = doc.bleed
                                bleed.enabled = on
                                doc.setBleed(bleed)
                            }))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            // The row already says "Bleed" (and the label is long in Portuguese and Spanish).
                            .labelsHidden()
                            .help("Prints the color at the edge of the art a little past each cut line")
                            ExperimentalBadge()
                        }
                        // Without it the label wraps and the grid rows grow.
                        .fixedSize()
                    }
                    if doc.bleed.enabled {
                        GridRow {
                            label("Width")
                            lengthField(Binding(get: { doc.bleed.width }, set: { updated in
                                var bleed = doc.bleed
                                bleed.width = updated
                                doc.setBleed(bleed)
                            }), span: PrintBleed.widths)
                        }
                    }
                }
            }
            .font(.callout)
            if doc.marks, doc.bleed.enabled {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Prints the color at the edge of the art \(unit.text(doc.bleed.width)) past each closed cut line, so a cut that lands a little off doesn’t show white paper. On the canvas, the red line shows how far it goes.")
                        .fixedSize(horizontal: false, vertical: true)
                    ReportProblemLink(feature: .printBleed) { PrintBleed.reportContext(doc) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if doc.sheetFrame(doc.activeArtboard).turned {
                // As Silhouette Studio does (Model/RegistrationMarks.swift, SheetFrame).
                Text(doc.marks
                     ? "Landscape: to cut, the sheet goes on the mat turned a quarter turn clockwise, as in Silhouette Studio. The marks go where the machine looks for them on the turned sheet: the square at the artboard’s bottom-left corner."
                     : "Landscape: to cut, the sheet goes on the mat turned a quarter turn clockwise, as in Silhouette Studio (on the 12 × 12, 15 × 15 and 24 × 24 in mats it goes as it is).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if doc.marks, doc.marksConfig.margin == nil {
                Text("The mark margins came different on each side (from the Studio file); changing them here makes all four equal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(doc.withMat
                 ? "The sheet sticks to the mat, in the top-left corner of the grid."
                 : "Without a mat, the machine feeds the sheet directly: use media with a firm backing (sticker paper, card) and push it against the guide.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Length (mm) in the Settings unit, with arrows (0.5 mm per click).
    private func lengthField(_ value: Binding<Double>, span: ClosedRange<Double>) -> some View {
        let limited = Binding(get: { value.wrappedValue }, set: { value.wrappedValue = min(max($0, span.lowerBound), span.upperBound) })
        return HStack(spacing: 2) {
            TextField("", value: Binding(get: { unit.show(limited.wrappedValue) }, set: { limited.wrappedValue = unit.mm($0) }),
                      format: .number.precision(.fractionLength(0...3)))
                .labelsHidden()
                .frame(width: 54)
                .multilineTextAlignment(.trailing)
            Text(verbatim: unit.symbol).foregroundStyle(.secondary)
            Stepper("", value: limited, in: span, step: 0.5)
                .labelsHidden()
                .controlSize(.mini)
        }
        .controlSize(.small)
    }

    private func label(_ text: LocalizedStringKey) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private var connected: Bool {
        switch machine.state {
        case .connected, .sending, .sent: true
        default: false
        }
    }

    private var machineName: String {
        if machine.info != nil { return machine.modelName }
        return machine.current?.model ?? String(localized: "None connected")
    }

}

extension CuttingMat {
    /// How it shows in the Page panel and in the Send window.
    var name: String {
        switch self {
        case .none: String(localized: "No mat")
        case .cameo12x12: String(localized: "12 × 12 in mat")
        case .cameo12x24: String(localized: "12 × 24 in mat")
        case .portrait8x12: String(localized: "8 × 12 in mat")
        case .cameoPlus15x15: String(localized: "15 × 15 in mat")
        case .cameoPro24x24: String(localized: "24 × 24 in mat")
        case .portrait8_5x12: String(localized: "8.5 × 12 in mat")
        case .mini6x8: String(localized: "6 × 8 in mat")
        case .electrostatic12x12: String(localized: "Electrostatic 12 × 12 in mat")
        case .electrostatic8_5x12: String(localized: "Electrostatic 8.5 × 12 in mat")
        case .pixscanCameo, .pixscanPortrait: String(localized: "PixScan mat")
        }
    }
}
