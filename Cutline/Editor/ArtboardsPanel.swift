// Artboards panel (like Illustrator's): the document's artboards in order — click one to make it active, double-click
// its name to rename it — with New, Delete and Move Up/Down. The size controls (preset, orientation, W × H) are
// shared by the Page panel and the Artboard tool's control bar (`ArtboardBar`). The editing is in
// Model/ArtboardEditing.swift.
import SwiftUI

struct ArtboardsSection: View {
    @Bindable var doc: Document
    @AppStorage(LengthUnit.key) private var unit = LengthUnit.mm
    /// The artboard whose name is being typed.
    @State private var renaming: UUID?
    @State private var newName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 2) {
                ForEach(Array(doc.artboards.enumerated()), id: \.element.id) { i, artboard in
                    row(i, artboard)
                }
            }
            HStack(spacing: 2) {
                button("New Artboard", .plus) { doc.newArtboard() }
                button("Delete Artboard (its artwork stays on the canvas)", .trash) { doc.deleteArtboard(doc.activeArtboardID) }
                    .disabled(doc.artboards.count < 2)
                Spacer(minLength: 0)
                button("Move Up", .arrowUp) { doc.moveArtboard(doc.activeArtboardID, by: -1) }
                    .disabled(doc.activeIndex == 0)
                button("Move Down", .arrowDown) { doc.moveArtboard(doc.activeArtboardID, by: 1) }
                    .disabled(doc.activeIndex == doc.artboards.count - 1)
            }
            Text("The order is the order of the pages when printing; the 1st one is the one the Finder shows. ⇧O moves and resizes them on the canvas.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ i: Int, _ artboard: Artboard) -> some View {
        let active = artboard.id == doc.activeArtboardID
        return HStack(spacing: 8) {
            Text(verbatim: "\(i + 1)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
            if renaming == artboard.id {
                TextField("Name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($nameFocused)
                    .onSubmit { finishRenaming() }
                    .onChange(of: nameFocused) { _, focused in if !focused { finishRenaming() } }
            } else {
                Text(artboard.title(i))
                    .fontWeight(active ? .semibold : .regular)
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        newName = artboard.title(i)
                        renaming = artboard.id
                        nameFocused = true
                    }
            }
            Spacer(minLength: 4)
            Text(verbatim: unit.text(artboard.size))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(artboard.isLandscape ? .pageLandscape : .pagePortrait)
                .resizable()
                .frame(width: 13, height: 13)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(active ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture { doc.activate(artboard.id) }
        .help("Click to make it the active artboard; double-click the name to rename it")
    }

    private func finishRenaming() {
        guard let id = renaming else { return }
        renaming = nil
        doc.renameArtboard(id, newName)
    }

    private func button(_ tip: LocalizedStringKey, _ icon: ImageResource, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(icon).resizable().frame(width: 15, height: 15).frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(tip)
    }
}

/// The page size presets (paper, then the cutting mats) and Custom, for an artboard.
struct PresetMenu: View {
    @Bindable var doc: Document
    let artboard: Artboard

    var body: some View {
        Menu {
            ForEach(PagePreset.allCases.filter { !$0.isMat }) { preset in
                Button(preset.name) { doc.setArtboardPreset(artboard.id, preset) }
            }
            Divider()
            ForEach(PagePreset.allCases.filter(\.isMat)) { preset in
                Button(preset.name) { doc.setArtboardPreset(artboard.id, preset) }
            }
        } label: {
            Text(artboard.preset?.name ?? String(localized: "Custom")).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Page size")
    }
}

/// Portrait and landscape, as two buttons (a square artboard has neither lit).
struct OrientationButtons: View {
    @Bindable var doc: Document
    let artboard: Artboard

    var body: some View {
        HStack(spacing: 2) {
            option("Portrait", .pagePortrait, on: !artboard.isLandscape && artboard.rect.width != artboard.rect.height) {
                doc.setArtboardLandscape(artboard.id, false)
            }
            option("Landscape", .pageLandscape, on: artboard.isLandscape) { doc.setArtboardLandscape(artboard.id, true) }
        }
    }

    private func option(_ tip: LocalizedStringKey, _ icon: ImageResource, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(icon)
                .resizable()
                .frame(width: 16, height: 16)
                .foregroundStyle(on ? Color.accentColor : .secondary)
                .frame(width: 26, height: 24)
                .background(on ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tip)
    }
}

/// W and H of an artboard, in the Settings unit (the top-left corner stays).
struct ArtboardSizeFields: View {
    @Bindable var doc: Document
    let artboard: Artboard
    @AppStorage(LengthUnit.key) private var unit = LengthUnit.mm

    var body: some View {
        HStack(spacing: 6) {
            field("W", artboard.size.width) { doc.setArtboardSize(artboard.id, CGSize(width: $0, height: artboard.size.height)) }
            field("H", artboard.size.height) { doc.setArtboardSize(artboard.id, CGSize(width: artboard.size.width, height: $0)) }
            Text(verbatim: unit.symbol).foregroundStyle(.secondary).fixedSize()
        }
    }

    private func field(_ label: LocalizedStringKey, _ value: Double, apply: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary).fixedSize()
            // The field confirms the value again on losing focus: it only applies (and registers the undo) if it changed.
            TextField(label, value: Binding(get: { unit.show(value) }, set: { updated in
                let v = Artboard.limited(unit.mm(updated))
                if abs(v - value) > 1e-6 { apply(v) }
            }), format: .number.precision(.fractionLength(0...unit.fractionDigits)))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 50)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// The control bar with the Artboard tool (⇧O): the active artboard's name, size and orientation, New and Delete, and
/// whether its artwork moves with it.
struct ArtboardBar: View {
    @Bindable var doc: Document
    @AppStorage(Preferences.moveArtworkWithArtboard) private var moveArtwork = true

    var body: some View {
        let artboard = doc.activeArtboard
        HStack(spacing: 8) {
            Text(verbatim: "\(doc.activeIndex + 1) – \(artboard.title(doc.activeIndex))")
                .fontWeight(.semibold)
                .lineLimit(1)
            PresetMenu(doc: doc, artboard: artboard)
            OrientationButtons(doc: doc, artboard: artboard)
            ArtboardSizeFields(doc: doc, artboard: artboard)
            Divider().frame(height: 16)
            Toggle("Move Artwork", isOn: $moveArtwork)
                .toggleStyle(.checkbox)
                .fixedSize()
                .help("Moving an artboard moves the artwork on it too")
            Button("New") { doc.newArtboard() }
                .controlSize(.small)
                .help("New Artboard, the size of this one, to the right of the others")
            Button("Delete") { doc.deleteArtboard(artboard.id) }
                .controlSize(.small)
                .disabled(doc.artboards.count < 2)
                .help("Deletes the active artboard (⌫); its artwork stays on the canvas")
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
