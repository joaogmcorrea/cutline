// Copy, cut and paste objects (⌘C, ⌘X, ⌘V; also through the Edit menu and right-click), including from
// one Cutline window to another: they go to the macOS pasteboard in a type of their own, with the images
// they use. Paste puts them in the active layer, at the same spot on the sheet (or 5 mm down and to the right, as many times as
// needed, if an identical one is already there) and selects them. ⌘ + arrow duplicates the selection right next to it, to that
// side, as in Silhouette Studio.
import AppKit

nonisolated struct Clipping: Codable {

    /// The keys stored on disk keep the names of the 1.0 format (Portuguese), so older files still open.

    enum CodingKeys: String, CodingKey {

        case objects = "objetos", images = "imagens"

    }

    var objects: [CanvasObject]
    var images: [String: Data]
}

extension NSPasteboard.PasteboardType {
    static let cutlineObjects = Self("io.github.joaogmcorrea.cutline.objetos")
}

nonisolated enum Direction: Sendable {
    case left, right, up, bottom
}

extension Document {
    /// The general macOS one (in hidden tests, one of Cutline's own, so the owner's isn't touched).
    private var area: NSPasteboard {
        #if DEBUG
        if let test = DebugHooks.testArea { return test }
        #endif
        return .general
    }

    func copySelection() {
        let copied = objectsInOrder.filter { selection.contains($0.id) }
        let keys = Set(copied.compactMap(\.image?.key))
        guard !copied.isEmpty,
              let payload = try? PropertyListEncoder().encode(Clipping(objects: copied, images: images.filter { keys.contains($0.key) }))
        else { return }
        area.clearContents()
        area.setData(payload, forType: .cutlineObjects)
    }

    func cutSelection() {
        copySelection()
        deleteSelection()
    }

    var canPaste: Bool { area.availableType(from: [.cutlineObjects]) != nil }

    func paste() {
        guard let payload = area.data(forType: .cutlineObjects),
              let clipping = try? PropertyListDecoder().decode(Clipping.self, from: payload), !clipping.objects.isEmpty else { return }
        let equal = { (a: CGRect, b: CGRect) in
            abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01 && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
        }
        var offset = 0.0
        while offset < 250, clipping.objects.contains(where: { pasted in
            objects.contains { equal($0.frame, pasted.frame.offsetBy(dx: offset, dy: offset)) }
        }) { offset += 5 }
        insertImported(CanvasObject.copies(clipping.objects, offset: CGSize(width: offset, height: offset)),
                          images: clipping.images)
    }

    /// A copy of the selection right next to it, on the chosen side.
    func duplicateBeside(_ direction: Direction) {
        guard let box = selectionBox else { return }
        switch direction {
        case .left: duplicateSelection(offset: CGSize(width: -box.width, height: 0))
        case .right: duplicateSelection(offset: CGSize(width: box.width, height: 0))
        case .up: duplicateSelection(offset: CGSize(width: 0, height: -box.height))
        case .bottom: duplicateSelection(offset: CGSize(width: 0, height: box.height))
        }
    }
}
