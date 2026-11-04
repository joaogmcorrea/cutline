// A Photoshop file with layers (Model/PSDImport.swift) on its way in: the same question as for an image (only the
// images, the outer outline or the inner ones too), answered once for all the layers. Each layer goes in as its own
// image, in its place on the Photoshop canvas; the outlines use the Trace defaults from Settings, each one grouped
// with its image.
import SwiftUI

nonisolated struct LayeredImage: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let file: PSDFile
    /// Where it was dropped, in page mm (otherwise the canvas goes in centered on the page).
    var center: CGPoint?

    /// mm per Photoshop pixel: the file's real size, smaller if the canvas doesn't fit the page.
    var scale: Double {
        min(25.4 / max(file.resolution, 1), Document.page.width / file.size.width, Document.page.height / file.size.height)
    }

    /// The Photoshop canvas on the page (an A4 file at 300 ppi covers the page exactly).
    var canvasFrame: CGRect {
        let c = center ?? CGPoint(x: Document.page.width / 2, y: Document.page.height / 2)
        let size = CGSize(width: file.size.width * scale, height: file.size.height * scale)
        return CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height)
    }

    func frame(of layer: PSDLayer) -> CGRect {
        CGRect(x: canvasFrame.minX + layer.rect.minX * scale, y: canvasFrame.minY + layer.rect.minY * scale,
               width: layer.rect.width * scale, height: layer.rect.height * scale)
    }

    /// Each layer's outline loops, in page mm.
    func outlines(_ defaults: TraceParameters, inners: Bool) -> [[[CGPoint]]] {
        file.layers.map { layer in
            let frame = frame(of: layer)
            var parameters = defaults
            parameters.width = frame.width
            parameters.inners = inners
            guard let pixels = Tracer.pixels(layer.image) else { return [] }
            return Tracer.traceImage(pixels, parameters).loops.map { $0.map { CGPoint(x: $0.x + frame.minX, y: $0.y + frame.minY) } }
        }
    }
}

struct LayeredImageWindow: View {
    let doc: Document
    let origin: LayeredImage
    @Environment(\.dismiss) private var close
    /// Previews of the choices: outer only and with the inner ones (traced off the main thread).
    @State private var outer: [[[CGPoint]]]?
    @State private var inners: [[[CGPoint]]]?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What to do with “\(origin.name)”?").font(.headline)
                Text(verbatim: String(localized: "\(origin.file.layers.count) layers") + " · "
                     + String(localized: "Each layer goes in as its own image, in its place. The outlines use the Trace defaults from Settings."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 12) {
                ImageOption(title: "Images only", detail: "Placed for printing, with no cut line.") {
                    LayersPreview(origin: origin, loops: nil)
                } action: { insert(nil) }
                ImageOption(title: "Outer outline", detail: "Cuts around the artwork, with a margin. Anything inside it is ignored.",
                            defaultValue: true) {
                    LayersPreview(origin: origin, loops: outer)
                } action: { insert(false) }
                ImageOption(title: "Inner outlines too", detail: "Also cuts the openings in the artwork, like the inside of an O. The margin narrows them; small ones disappear.") {
                    LayersPreview(origin: origin, loops: inners)
                } action: { insert(true) }
            }
            HStack {
                Spacer()
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 700)
        .task {
            let (origin, defaults) = (origin, Preferences.traceDefaults)
            (outer, inners) = await Task.detached {
                (origin.outlines(defaults, inners: false), origin.outlines(defaults, inners: true))
            }.value
            #if DEBUG
            switch DebugHooks.imageChoice {
            case "image": insert(nil)
            case "outer": insert(false)
            case "inners", "inners-insert": insert(true)
            default: break
            }
            #endif
        }
    }

    /// nil = only the images; otherwise each layer with its outline (`withInners`: the inner ones too), grouped.
    private func insert(_ withInners: Bool?) {
        let defaults = Preferences.traceDefaults
        let loops = withInners.map { (($0 ? inners : outer) ?? origin.outlines(defaults, inners: $0)) }
        var objects: [CanvasObject] = [], images: [String: Data] = [:]
        for (k, layer) in origin.file.layers.enumerated() {
            let key = UUID().uuidString
            images[key] = layer.png
            var image = doc.imageObject(origin.frame(of: layer), key: key, pixels: layer.rect.size, name: layer.name)
            guard let layerLoops = loops?[k], !layerLoops.isEmpty else {
                objects.append(image)
                continue
            }
            var outline = doc.outlineObject(layerLoops, origin: .zero, smoothing: defaults.smoothing, name: layer.name)
            let group = UUID()
            image.groups = [group]
            outline.groups = [group]
            objects += [image, outline]
        }
        doc.insertImported(objects, images: images)
        doc.notice = String(localized: "Imported from “\(origin.name)”: \(String(localized: "\(origin.file.layers.count) images")).")
        doc.tool = .selection
        close()
    }
}

/// The Photoshop canvas with every layer in its place and the outlines on top.
private struct LayersPreview: View {
    let origin: LayeredImage
    let loops: [[[CGPoint]]]?

    var body: some View {
        Canvas { ctx, size in
            let box = origin.canvasFrame.insetBy(dx: -4, dy: -4)
            let e = min(size.width / box.width, size.height / box.height)
            let shift = CGPoint(x: (size.width - box.width * e) / 2 - box.minX * e, y: (size.height - box.height * e) / 2 - box.minY * e)
            let place = { (p: CGPoint) in CGPoint(x: shift.x + p.x * e, y: shift.y + p.y * e) }
            for layer in origin.file.layers {
                let frame = origin.frame(of: layer)
                ctx.draw(Image(decorative: layer.image, scale: 1),
                         in: CGRect(origin: place(frame.origin), size: CGSize(width: frame.width * e, height: frame.height * e)))
            }
            var path = Path()
            for loop in (loops ?? []).joined() where loop.count > 2 {
                path.addLines(loop.map(place))
                path.closeSubpath()
            }
            ctx.stroke(path, with: .color(Color(red: 0.89, green: 0.29, blue: 0.29)), lineWidth: 1.5)
        }
    }
}
