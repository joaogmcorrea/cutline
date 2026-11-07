// Type on a Path Options, like Illustrator's (Type › Type on a Path › Type on a Path Options…; here, the button in the
// control bar when a text on a path is selected): Effect, Align to Path, Spacing and Flip, plus where the text starts and
// ends. Preview shows the change on the canvas; OK keeps it (one undo step), Cancel puts it back. The layout is in
// Model/Geometry.swift (`TextOnPath.layout`), the model in Model/Document.swift (`TextOnPath`).
import SwiftUI

extension PathTextEffect {
    var name: String {
        switch self {
        case .rainbow: String(localized: "Rainbow")
        case .skew: String(localized: "Skew")
        case .stairStep: String(localized: "Stair Step")
        }
    }
}

extension PathTextAlignment {
    var name: String {
        switch self {
        case .baseline: String(localized: "Baseline")
        case .ascender: String(localized: "Ascender")
        case .descender: String(localized: "Descender")
        case .center: String(localized: "Center")
        }
    }
}

/// The sheet, on the document's window.
struct PathTextOptionsSheet: ViewModifier {
    @Bindable var doc: Document

    func body(content: Content) -> some View {
        content.sheet(isPresented: $doc.pathTextOptionsOpen) { PathTextOptionsView(doc: doc) }
    }
}

struct PathTextOptionsView: View {
    let doc: Document
    @State private var options: TextOnPath
    @State private var preview = true
    /// The selection's texts on a path as they were (Cancel puts them back).
    private let before: [CanvasObject.ID: TextOnPath]
    @Environment(\.dismiss) private var dismiss

    init(doc: Document) {
        self.doc = doc
        let first = doc.selectedObjects.first { $0.textPath != nil }?.textPath ?? TextOnPath(subpaths: [])
        _options = State(initialValue: first)
        before = Dictionary(uniqueKeysWithValues: doc.selectedObjects.compactMap { o in o.textPath.map { (o.id, $0) } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Type on a Path Options").font(.headline)
            Form {
                Picker("Effect", selection: $options.effect) {
                    ForEach(PathTextEffect.allCases) { Text($0.name).tag($0) }
                }
                Picker("Align to Path", selection: $options.alignment) {
                    ForEach(PathTextAlignment.allCases) { Text($0.name).tag($0) }
                }
                LabeledContent("Spacing") {
                    HStack(spacing: 4) {
                        TextField("Spacing", value: $options.spacing, format: .number.precision(.fractionLength(0...1)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                        Text(verbatim: "pt").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Start and end") {
                    HStack(spacing: 4) {
                        percent($options.start)
                        Text(verbatim: "–").foregroundStyle(.secondary)
                        percent($options.end)
                        Text(verbatim: "%").foregroundStyle(.secondary)
                    }
                }
                Toggle("Flip", isOn: $options.flipped)
            }
            .formStyle(.columns)
            HStack {
                Toggle("Preview", isOn: $preview)
                Spacer()
                Button("Cancel") {
                    restore()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("OK") { ok() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onChange(of: options) { _, _ in if preview { show(options) } }
        .onChange(of: preview) { _, on in if on { show(options) } else { restore() } }
        #if DEBUG
        .task { await DebugHooks.drivePathTextOptions($options, ok: ok) }
        #endif
    }

    private func percent(_ value: Binding<Double>) -> some View {
        TextField("", value: Binding(get: { (value.wrappedValue * 100).rounded() }, set: { value.wrappedValue = min(max($0, 0), 100) / 100 }),
                  format: .number)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 48)
    }

    /// The options on the selection's texts on a path, without undo (the preview).
    private func show(_ o: TextOnPath) {
        for i in doc.objects.indices where before[doc.objects[i].id] != nil { doc.objects[i].textPath = applied(o, to: before[doc.objects[i].id]!) }
    }

    private func restore() {
        for i in doc.objects.indices { if let old = before[doc.objects[i].id] { doc.objects[i].textPath = old } }
    }

    /// The dialog's options on one text (its own path stays).
    private func applied(_ o: TextOnPath, to text: TextOnPath) -> TextOnPath {
        var t = text
        t.effect = o.effect
        t.alignment = o.alignment
        t.spacing = o.spacing
        t.flipped = o.flipped
        t.start = min(o.start, o.end)
        t.end = max(o.start, o.end)
        return t
    }

    private func ok() {
        restore()
        let o = options
        doc.changePathText { $0 = applied(o, to: $0) }
        dismiss()
    }
}
