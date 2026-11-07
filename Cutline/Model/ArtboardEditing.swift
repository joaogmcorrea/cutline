// Editing the artboards (Model/Artboards.swift), as in Illustrator's Artboards panel and Artboard tool: new, delete,
// rename, reorder, move (with the artwork on it, Illustrator's default) and resize, by preset, orientation or W × H.
// Each change is one undo step; every change that could move the 1st artboard ends with `anchorFirstArtboard`.
import CoreGraphics
import Foundation

extension Document {
    /// Space between a new artboard and the ones already there (mm).
    static let artboardGap = 20.0

    /// Makes an artboard the active one (the rulers, the snap and Fit in Window follow it). Not an undo step.
    func activate(_ id: UUID) {
        guard activeArtboardID != id, artboards.contains(where: { $0.id == id }) else { return }
        activeArtboardID = id
    }

    /// New artboard (Artboards panel): the active one's size, to the right of all of them, active.
    func newArtboard() {
        let box = artboardsBox, size = activeArtboard.size
        addArtboard(CGRect(x: box.maxX + Self.artboardGap, y: artboards[0].rect.minY, width: size.width, height: size.height))
    }

    /// New artboard at a place (the Artboard tool's drag), active.
    func addArtboard(_ rect: CGRect) {
        let r = rect.standardized
        let artboard = Artboard(rect: CGRect(x: r.minX, y: r.minY, width: Artboard.limited(r.width), height: Artboard.limited(r.height)))
        registrar()
        artboards.append(artboard)
        activeArtboardID = artboard.id
    }

    /// Deletes an artboard (never the last one); the artwork on it stays on the canvas, as in Illustrator.
    func deleteArtboard(_ id: UUID) {
        guard artboards.count > 1, let i = artboards.firstIndex(where: { $0.id == id }) else { return }
        registrar()
        artboards.remove(at: i)
        if activeArtboardID == id { activeArtboardID = artboards[min(i, artboards.count - 1)].id }
        if sendArtboardID == id { sendArtboardID = nil }
        anchorFirstArtboard()
    }

    /// Renames an artboard; an empty name goes back to "Artboard N".
    func renameArtboard(_ id: UUID, _ name: String) {
        guard let i = artboards.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated: String? = trimmed.isEmpty || trimmed == Artboard.defaultName(i) ? nil : trimmed
        guard updated != artboards[i].name else { return }
        registrar()
        artboards[i].name = updated
    }

    /// Moves an artboard up or down the list (the order of the pages in the print; the 1st is the one the previews show).
    func moveArtboard(_ id: UUID, by offset: Int) {
        guard let i = artboards.firstIndex(where: { $0.id == id }), artboards.indices.contains(i + offset), offset != 0 else { return }
        registrar()
        artboards.swapAt(i, i + offset)
        anchorFirstArtboard()
    }

    /// The artboard's place and size (canvas mm). `artwork`: the objects on it (their box's center inside it) go along
    /// when it moves, as Illustrator's "Move/Copy Artwork with Artboard". `registered`: the undo step was already taken
    /// (a drag); `anchor` false leaves the 1st artboard where it is until the drag ends.
    func setArtboardRect(_ id: UUID, _ rect: CGRect, artwork: [CanvasObject.ID: CGRect] = [:], registered: Bool = false,
                         anchor: Bool = true) {
        guard let i = artboards.firstIndex(where: { $0.id == id }) else { return }
        let r = rect.standardized
        let updated = CGRect(x: r.minX, y: r.minY, width: Artboard.limited(r.width), height: Artboard.limited(r.height))
        guard updated != artboards[i].rect || !artwork.isEmpty else { return }
        if !registered { registrar() }
        artboards[i].rect = updated
        // `artwork` has each object's frame relative to the artboard's corner (`artworkOn`): it goes to the new corner.
        for j in objects.indices {
            if let relative = artwork[objects[j].id] { objects[j].frame = relative.offsetBy(dx: updated.minX, dy: updated.minY) }
        }
        if anchor { anchorFirstArtboard() }
    }

    /// The objects on an artboard (their box's center inside it), with their frames relative to its top-left corner: what
    /// moves with it.
    func artworkOn(_ id: UUID) -> [CanvasObject.ID: CGRect] {
        guard let artboard = artboards.first(where: { $0.id == id }) else { return [:] }
        let o = artboard.rect.origin
        var found: [CanvasObject.ID: CGRect] = [:]
        for object in objects where !object.emptyText {
            let box = object.shapePath.boundingRect
            guard artboard.rect.contains(CGPoint(x: box.midX, y: box.midY)) else { continue }
            found[object.id] = object.frame.offsetBy(dx: -o.x, dy: -o.y)
        }
        return found
    }

    /// New size, keeping the top-left corner (the Page panel, the control bar).
    func setArtboardSize(_ id: UUID, _ size: CGSize) {
        guard let a = artboards.first(where: { $0.id == id }) else { return }
        setArtboardRect(id, CGRect(origin: a.rect.origin, size: size))
    }

    /// A preset's size, in the artboard's orientation (a square one keeps the preset's).
    func setArtboardPreset(_ id: UUID, _ preset: PagePreset) {
        guard let a = artboards.first(where: { $0.id == id }) else { return }
        let s = preset.size
        let size = a.isLandscape ? CGSize(width: max(s.width, s.height), height: min(s.width, s.height)) : s
        setArtboardSize(id, size)
    }

    /// Portrait or landscape: swaps the width and the height when the orientation changes.
    func setArtboardLandscape(_ id: UUID, _ landscape: Bool) {
        guard let a = artboards.first(where: { $0.id == id }), a.isLandscape != landscape, a.rect.width != a.rect.height else { return }
        setArtboardSize(id, a.rotated().size)
    }
}
