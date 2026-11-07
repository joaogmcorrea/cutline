// Putting an image inside a shape and taking it out (the model is in Model/ImageFitting.swift), as Silhouette Studio's Fill
// Pattern and Illustrator's clipping mask:
// - dropping an image file from the Finder on a shape (MainWindow), or dragging an image already on the sheet onto one with
//   ⌘ held (Editor/CanvasView.swift): it fills the shape, which shows a highlight while the image is over it;
// - Edit › Paste Inside (⌥⌘V, InDesign's Paste Into): the image on the pasteboard inside the selected shapes;
// - Object › Clipping Mask › Make (⌘7) and Release (⌥⌘7), as in Illustrator: the image keeps its place on the page.
// The fitting (Fill, Fit, Stretch, Tile), the content's scale and the opacity are in the control bar (`ImageFitBar`); a
// double click on the shape edits the content (move, scale by a corner, turn just outside one; Esc leaves).
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

extension ImageFitMode {
    var name: String {
        switch self {
        case .fill: String(localized: "Fill")
        case .fit: String(localized: "Fit")
        case .stretch: String(localized: "Stretch")
        case .tile: String(localized: "Tile")
        }
    }

    var detail: String {
        switch self {
        case .fill: String(localized: "Covers the shape, keeping the proportions (some of the image is cut off)")
        case .fit: String(localized: "The whole image inside the shape, keeping the proportions")
        case .stretch: String(localized: "Stretched to the shape’s size")
        case .tile: String(localized: "Repeated as a pattern; the scale sets the size of the tiles")
        }
    }
}

/// An image to put in a shape: where its data comes from and its size.
struct ImageForShape {
    var key: String
    var pixels: CGSize
    /// New data for the document (nothing when the key is already in it).
    var images: [String: Data] = [:]
    var links: [String: ImageLink] = [:]
}

extension Document {
    // MARK: Which shapes take an image

    /// A shape that can take an image inside: a closed outline (any shape, a path with a closed part), not a text, visible
    /// and unlocked, and not an image on its own (one already inside a shape is replaced).
    func takesImage(_ o: CanvasObject) -> Bool {
        guard !untouchable(o), o.textPath == nil, o.frame.width > 0, o.frame.height > 0 else { return false }
        if o.image != nil, o.imageFit == nil { return false }
        switch o.shape {
        case .text: return false
        case .shapePath(let subs): return subs.contains { $0.closed && $0.nodes.count >= 2 }
        default: return true
        }
    }

    /// The shape an image dropped at `p` (page mm) goes into: the frontmost object there, when it takes images (an image or a
    /// text on top keeps the drop for itself). `excluding`: what is being dragged.
    func imageTarget(at p: CGPoint, excluding: Set<CanvasObject.ID> = []) -> CanvasObject.ID? {
        for o in objectsInOrder.reversed() where !excluding.contains(o.id) && !untouchable(o) {
            guard o.shapePath.cgPath.contains(p, using: .evenOdd) else { continue }
            return takesImage(o) ? o.id : nil
        }
        return nil
    }

    /// An image on its own being dragged (the only one selected), which ⌘ would put into a shape.
    var draggedImage: CanvasObject? {
        let chosen = selectedObjects
        guard chosen.count == 1, chosen[0].image != nil, chosen[0].imageFit == nil else { return nil }
        return chosen[0]
    }

    /// The size the placement of an image counts (a linked image's full size).
    func pixels(of key: String) -> CGSize? {
        if let link = links[key], link.pixelWidth > 0, link.pixelHeight > 0 { return CGSize(width: link.pixelWidth, height: link.pixelHeight) }
        return image(key).map { CGSize(width: $0.width, height: $0.height) }
    }

    // MARK: Putting an image in

    /// Puts the image in the shapes `targets` (those that take it), filling them as Studio does (`mode`, centered); a shape that
    /// already has one inside keeps its fitting and opacity with the new image. `removing`: objects that go away in the same
    /// step (the image dragged onto the shape). One undo step (`register` false: the gesture already registered it).
    @discardableResult
    func putImage(_ picture: ImageForShape, into targets: [CanvasObject.ID], removing consumed: Set<CanvasObject.ID> = [],
                  mode: ImageFitMode = .fill, register: Bool = true) -> Bool {
        let ids = Set(targets.filter { id in objects.contains { $0.id == id && takesImage($0) } })
        guard !ids.isEmpty, picture.pixels.width > 0, picture.pixels.height > 0 else { return false }
        if register { registrar() }
        images.merge(picture.images) { _, newOne in newOne }
        links.merge(picture.links) { _, newOne in newOne }
        for key in picture.links.keys { linkStates[key] = .ok }
        for i in objects.indices where ids.contains(objects[i].id) {
            var fitting = objects[i].imageFit ?? ImageFitting(mode: mode, pixels: picture.pixels)
            fitting.pixelWidth = Double(picture.pixels.width)
            fitting.pixelHeight = Double(picture.pixels.height)
            fitting.resetContent()
            objects[i].image = ImageInShape(key: picture.key, transform: Transform(.identity))
            objects[i].imageFit = fitting   // places the image
        }
        objects.removeAll { consumed.contains($0.id) }
        selection = ids
        imageContentEditing = nil
        imageDropTarget = nil
        return true
    }

    /// An image file dropped on the shape `target` (from the Finder): read as Import… reads it (upright, a Photoshop file
    /// flattened), into the document. False when the file isn't an image.
    func putImageFile(_ url: URL, into target: CanvasObject.ID) -> Bool {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let payload = try? Data(contentsOf: url), VectorImporter.format(payload) == nil,
              let read = LinkedFile.picture(payload) else { return false }
        let key = UUID().uuidString
        return putImage(ImageForShape(key: key, pixels: CGSize(width: read.image.width, height: read.image.height), images: [key: read.payload]),
                        into: [target])
    }

    // MARK: Paste Inside

    /// The image on the pasteboard: one copied in Cutline (an image, or a shape with one inside), or one copied in another app
    /// (Preview, a browser: PNG, TIFF, JPEG, HEIC).
    var pastedImage: ImageForShape? {
        let area = pasteboardArea
        if let payload = area.data(forType: .cutlineObjects), let clipping = try? PropertyListDecoder().decode(Clipping.self, from: payload) {
            let withImage = clipping.objects.first { $0.image != nil && $0.imageFit == nil } ?? clipping.objects.first { $0.image != nil }
            guard let key = withImage?.image?.key else { return nil }
            let link = clipping.links?[key]
            let data = clipping.images[key]
            let pixels: CGSize? = if let link, link.pixelWidth > 0 { CGSize(width: link.pixelWidth, height: link.pixelHeight) }
                else { (data ?? link?.preview).flatMap(ImageFillDrawing.decode).map { CGSize(width: $0.width, height: $0.height) } }
            guard let pixels, data != nil || link != nil else { return nil }
            return ImageForShape(key: key, pixels: pixels, images: data.map { [key: $0] } ?? [:], links: link.map { [key: $0] } ?? [:])
        }
        let types: [NSPasteboard.PasteboardType] = [.png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier),
                                                    NSPasteboard.PasteboardType(UTType.heic.identifier)]
        guard let type = area.availableType(from: types), let data = area.data(forType: type),
              let read = LinkedFile.picture(data, compact: true) else { return nil }
        return ImageForShape(key: UUID().uuidString, pixels: CGSize(width: read.image.width, height: read.image.height),
                             images: [:], links: [:]).withData(read.payload)
    }

    var canPasteInside: Bool {
        guard selectedObjects.contains(where: takesImage) else { return false }
        let area = pasteboardArea
        return area.availableType(from: [.cutlineObjects, .png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier),
                                         NSPasteboard.PasteboardType(UTType.heic.identifier)]) != nil
    }

    /// Edit › Paste Inside (⌥⌘V): the pasteboard's image inside the selected shapes, filling them. Returns a notice when it
    /// can't.
    func pasteInside() -> String? {
        let shapes = selectedObjects.filter(takesImage).map(\.id)
        guard !shapes.isEmpty else { return String(localized: "Select a closed shape to paste the image inside it.") }
        guard let picture = pastedImage else { return String(localized: "There’s no image to paste: copy an image first.") }
        putImage(picture, into: shapes)
        return nil
    }

    // MARK: Clipping mask

    /// An image on its own and a shape that takes it, the two selected.
    private var clippingPair: (image: CanvasObject, shape: CanvasObject)? {
        let chosen = selectedObjects
        guard chosen.count == 2 else { return nil }
        let pictures = chosen.filter { $0.image != nil && $0.imageFit == nil }
        let shapes = chosen.filter { $0.image == nil && takesImage($0) }
        guard pictures.count == 1, shapes.count == 1 else { return nil }
        return (pictures[0], shapes[0])
    }

    var canMakeClippingMask: Bool { clippingPair != nil }
    var canReleaseClippingMask: Bool { selectedObjects.contains(where: \.hasImageInside) }

    /// Object › Clipping Mask › Make (⌘7), as in Illustrator: with an image and a shape selected, the shape becomes the mask
    /// and the image goes inside it where it is on the page (the content's place, scale and turn, with Fill for when the
    /// shape is resized). The result takes the place of the one on top, in the stack and in the layers. Returns a notice when
    /// the selection isn't an image and a shape.
    func makeClippingMask() -> String? {
        guard let (picture, shape) = clippingPair, let key = picture.image?.key, let pixels = pixels(of: key),
              let placed = picture.imageToPage else {
            return String(localized: "Select one image and one closed shape: the shape becomes the mask and the image goes inside it.")
        }
        registrar()
        let order = objectsInOrder.map(\.id)
        let imageOnTop = (order.firstIndex(of: picture.id) ?? 0) > (order.firstIndex(of: shape.id) ?? 0)
        var result = shape
        var fitting = ImageFitting(mode: .fill, pixels: pixels)
        fitting.adopt(placed.concatenating(shape.rotationTransform.inverted()), in: shape.frame.standardized)
        result.image = ImageInShape(key: key, transform: Transform(.identity))
        result.imageFit = fitting
        if imageOnTop {
            // In the image's place (and layer): it was on top. (The shape leaves its own place first: the result has its id.)
            result.layer = picture.layer
            objects.removeAll { $0.id == shape.id }
            if let i = objects.firstIndex(where: { $0.id == picture.id }) { objects[i] = result }
        } else {
            if let i = objects.firstIndex(where: { $0.id == shape.id }) { objects[i] = result }
            objects.removeAll { $0.id == picture.id }
        }
        selection = [result.id]
        imageContentEditing = nil
        return nil
    }

    /// Object › Clipping Mask › Release (⌥⌘7): the image comes out of each selected shape as an image on its own, where it
    /// shows (one tile of a tiled one, opaque), just below the shape; the shape keeps its outline, stroke and fill.
    func releaseClippingMask() {
        guard canReleaseClippingMask else { return }
        registrar()
        var chosen = selection
        for id in selection {
            guard let i = objects.firstIndex(where: { $0.id == id }), objects[i].hasImageInside, let key = objects[i].image?.key,
                  let fitting = objects[i].imageFit, let placed = objects[i].imageToPage else { continue }
            var released = releasedImage(key, pixels: fitting.pixels, placement: placed)
            released.layer = objects[i].layer
            released.groups = objects[i].groups
            objects[i].image = nil
            objects[i].imageFit = nil
            objects.insert(released, at: i)
            chosen.insert(released.id)
        }
        selection = chosen
        imageContentEditing = nil
    }

    /// An image on its own (a rectangle that doesn't cut, as Import… makes it) where `placement` (pixel → page mm) puts the
    /// image: turned with it; a slanted placement goes in its box, upright.
    private func releasedImage(_ key: String, pixels: CGSize, placement p: CGAffineTransform) -> CanvasObject {
        let name = links[key].map { ($0.fileName as NSString).deletingPathExtension } ?? String(localized: "Image")
        let w = Double(pixels.width), h = Double(pixels.height)
        let angle = CanvasObject.normalizedAngle(atan2(-p.b, p.a) * 180 / .pi)
        let (s, c) = CanvasObject.sinCos(angle)
        let lengthX = hypot(p.a, p.b), lengthY = p.c * s + p.d * c
        let center = CGPoint(x: w / 2, y: h / 2).applying(p)
        let square = abs(p.a * p.c + p.b * p.d) <= 1e-6 * max(lengthX * abs(lengthY), 1e-12)
        if square, lengthY > 0 {
            let frame = CGRect(x: center.x - lengthX * w / 2, y: center.y - lengthY * h / 2, width: lengthX * w, height: lengthY * h)
            var o = imageObject(frame, key: key, pixels: pixels, name: name)
            o.rotation = angle
            if links[key] == nil { o.label = nil }   // "Image", in the app's language
            return o
        }
        let corners = [CGPoint.zero, CGPoint(x: w, y: 0), CGPoint(x: w, y: h), CGPoint(x: 0, y: h)].map { $0.applying(p) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: max(xs.max()! - xs.min()!, 0.01), height: max(ys.max()! - ys.min()!, 0.01))
        var o = imageObject(box, key: key, pixels: pixels, name: name)
        if links[key] == nil { o.label = nil }
        let placed = Transform(p.concatenating(o.unrotatedFrameToPage.inverted()))
        o.image?.transform = placed
        return o
    }

    // MARK: Fitting, scale and opacity (control bar)

    /// The image inside a shape the control bar shows (the first selected one).
    var selectedImageFit: ImageFitting? { selectedObjects.lazy.compactMap(\.imageFit).first }

    /// A new fitting for the selected shapes with an image inside: the content back to how the mode puts it (choosing the
    /// same one again undoes the content's moves).
    func setImageFit(_ mode: ImageFitMode) {
        guard canReleaseClippingMask else { return }
        modifySelection { o in
            guard var fitting = o.imageFit else { return }
            fitting.mode = mode
            fitting.resetContent()
            o.imageFit = fitting
        }
    }

    /// The content's scale, in %: the tiles' size for Tile. A field's steps merge into one undo step.
    func setImageScale(_ percent: Double) {
        guard canReleaseClippingMask else { return }
        registerAdjustment("imageScale")
        for i in objects.indices where selection.contains(objects[i].id) {
            guard var fitting = objects[i].imageFit else { continue }
            fitting.setScale(percent / 100)
            objects[i].imageFit = fitting
        }
    }

    /// The image's opacity, in %.
    func setImageOpacity(_ percent: Double) {
        guard canReleaseClippingMask else { return }
        registerAdjustment("imageOpacity")
        for i in objects.indices where selection.contains(objects[i].id) {
            guard var fitting = objects[i].imageFit else { continue }
            fitting.opacity = min(max(percent / 100, 0), 1)
            objects[i].imageFit = fitting
        }
    }

    // MARK: Editing the content

    /// Starts editing the content of the image inside `id` (double click; the control bar's Edit Contents).
    func editContent(_ id: CanvasObject.ID) {
        guard let o = objects.first(where: { $0.id == id }), o.hasImageInside, !untouchable(o) else { return }
        finishText()
        selection = [id]
        imageContentEditing = id
    }

    /// The object whose content is being edited.
    var contentObject: CanvasObject? {
        guard let id = imageContentEditing else { return nil }
        return objects.first { $0.id == id && $0.hasImageInside }
    }

    /// The content's box on the page (one tile's for Tile): its corners, top-left first, clockwise.
    func contentCorners(_ o: CanvasObject) -> [CGPoint]? {
        guard let placed = o.imageToPage, let fitting = o.imageFit else { return nil }
        let w = fitting.pixels.width, h = fitting.pixels.height
        return [CGPoint.zero, CGPoint(x: w, y: 0), CGPoint(x: w, y: h), CGPoint(x: 0, y: h)].map { $0.applying(placed) }
    }

    /// Puts the content of `id` at `placement` (pixel → page mm, with the object's rotation): the fitting takes the scale,
    /// turn and place.
    func placeContent(_ id: CanvasObject.ID, at placement: CGAffineTransform) {
        guard let i = objects.firstIndex(where: { $0.id == id }), var fitting = objects[i].imageFit else { return }
        let o = objects[i]
        fitting.adopt(placement.concatenating(o.rotationTransform.inverted()), in: o.frame.standardized)
        objects[i].imageFit = fitting
    }

    /// The content of the one being edited moved, scaled (around its center) or turned by a map of the page, in one step
    /// (the test hooks; the canvas does it while dragging).
    func transformContent(_ m: CGAffineTransform) {
        guard let o = contentObject, let placed = o.imageToPage else { return }
        registrar()
        placeContent(o.id, at: placed.concatenating(m))
    }
}

private extension ImageForShape {
    func withData(_ data: Data) -> ImageForShape {
        var copy = self
        copy.images = [key: data]
        return copy
    }
}

/// The control bar's part for a shape with an image inside: the fitting, the content's scale (the tiles' size for Tile), the
/// opacity, and editing the content.
struct ImageFitBar: View {
    @Bindable var doc: Document
    let fitting: ImageFitting
    let id: CanvasObject.ID

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Picker("Image", selection: Binding(get: { fitting.mode }, set: { doc.setImageFit($0) })) {
                    ForEach(ImageFitMode.allCases) { mode in
                        Text(mode.name).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Divider()
                Button("Reset Content") { doc.setImageFit(fitting.mode) }
            } label: {
                Text(fitting.mode.name)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("\(fitting.mode.detail). Double-click the shape to move, scale and turn the image in it.")
            percentField(fitting.scale * 100, minimum: ImageFitting.scaleRange.lowerBound * 100, maximum: ImageFitting.scaleRange.upperBound * 100) {
                doc.setImageScale($0)
            }
            .help(fitting.mode == .tile ? "Size of the tiles" as LocalizedStringKey : "Size of the image in the shape")
            HStack(spacing: 3) {
                Image(.contrast).resizable().frame(width: 15, height: 15).foregroundStyle(.secondary)
                percentField(fitting.opacity * 100, minimum: 0, maximum: 100) { doc.setImageOpacity($0) }
            }
            .help("Opacity of the image (it prints lighter; the cut doesn’t change)")
            // Editing the content (double click, Object › Clipping Mask › Edit Contents): the way out, besides Esc.
            if doc.imageContentEditing == id {
                Button("Done") { doc.imageContentEditing = nil }
                    .controlSize(.small)
                    .help("Stop editing the image inside the shape (Esc)")
            }
        }
    }

    /// A % field that applies on confirm, like the bar's other fields.
    private func percentField(_ value: Double, minimum: Double, maximum: Double, apply: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 2) {
            TextField("", value: Binding(get: { value }, set: { updated in
                let v = min(max(updated, minimum), maximum)
                if abs(v - value) > 1e-6 { apply(v) }
            }), format: .number.precision(.fractionLength(0...1)))
                .labelsHidden()
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 34)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            Text(verbatim: "%").foregroundStyle(.secondary).fixedSize()
        }
    }
}
