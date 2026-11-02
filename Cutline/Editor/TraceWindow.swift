// Trace window (as in the prototype): preview of the image with the contour and the settings — margin, number of
// nodes, smoothing (how much the nodes round off) and background tolerance —, with only the outer contour or also
// the inner ones (the artwork's holes). Insert places the image (prints, doesn't cut) and the contour in magenta
// (kiss cut) in the active layer, grouped (one click takes both; ⇧⌘G separates). An image imported
// or dragged onto the window first asks what to do: just the image, outer contour or inner ones.
import ImageIO
import SwiftUI

struct ImageToTrace: Identifiable {
    let id = UUID()
    let name: String
    let payload: Data
    let image: CGImage
    /// Imported or dragged: asks first what to do (the Trace tool goes straight to the settings).
    var ask = false
    /// Where it was dropped, in page mm: the image goes in centered there (otherwise, 20 mm from the corner).
    var center: CGPoint?

    var aspectRatio: Double { Double(image.height) / Double(max(image.width, 1)) }

    /// 60 mm wide, less if the height doesn't fit the page (the size is adjusted later, on the canvas).
    var initialWidth: Double { min(TraceParameters().width, (Document.page.height - 40) / aspectRatio) }

    /// Where the image sits on the page at that width.
    func frame(width: Double) -> CGRect {
        let size = CGSize(width: width, height: width * aspectRatio)
        let join = center.map { CGPoint(x: $0.x - size.width / 2, y: $0.y - size.height / 2) } ?? CGPoint(x: 20, y: 20)
        return CGRect(origin: join, size: size)
    }
}

struct TraceWindow: View {
    let doc: Document
    let origin: ImageToTrace
    @Environment(\.dismiss) private var close
    /// First the choice (imported or dragged image), then the settings.
    @State private var choosing: Bool
    @State private var parameters = TraceParameters()
    @State private var result: TraceResult?
    @State private var pixels: Tracer.Pixels?
    /// Previews for the choice, with the current settings: outer only and with the inner ones.
    @State private var outerPreview: [[CGPoint]]?
    @State private var innerPreview: [[CGPoint]]?

    init(doc: Document, origin: ImageToTrace) {
        self.doc = doc
        self.origin = origin
        _choosing = State(initialValue: origin.ask)
    }

    var body: some View {
        Group {
            if choosing { choice } else { settings }
        }
        .padding(22)
        .task {
            parameters.width = origin.initialWidth
            #if DEBUG
            if let settings = DebugHooks.traceSettings { (parameters.nodes, parameters.smoothing) = settings }
            #endif
            pixels = Tracer.pixels(origin.image)
            guard choosing else { return recompute() }
            await computePreviews()
            #if DEBUG
            switch DebugHooks.imageChoice {
            case "image": insertImageOnly()
            case "outer": choose(inners: false)
            case "inners": choose(inners: true)
            case "inners-insert":
                choose(inners: true)
                try? await Task.sleep(for: .milliseconds(400))
                insert()
            default: break
            }
            #endif
        }
        .task(id: parameters) {
            try? await Task.sleep(for: .milliseconds(60))
            recompute()
        }
    }

    // MARK: Choice

    private var choice: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What to do with “\(origin.name)”?").font(.headline)
            HStack(alignment: .top, spacing: 12) {
                ImageOption(title: "Image only", detail: "Placed for printing, with no cut line.") {
                    preview([])
                } action: { insertImageOnly() }
                ImageOption(title: "Outer outline", detail: "Cuts around the artwork, with a margin. Anything inside it is ignored.",
                            defaultValue: true) {
                    preview(outerPreview)
                } action: { choose(inners: false) }
                ImageOption(title: "Inner outlines too", detail: "Also cuts the openings in the artwork, like the inside of an O. The margin narrows them; small ones disappear.") {
                    preview(innerPreview)
                } action: { choose(inners: true) }
            }
            HStack {
                Spacer()
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func choose(inners: Bool) {
        parameters.inners = inners
        choosing = false
    }

    /// The two choice previews, off the main thread (the window opens without waiting).
    private func computePreviews() async {
        guard let pixels else { return }
        var outer = parameters, inners = parameters
        outer.inners = false
        inners.inners = true
        let (outerParams, innerParams) = (outer, inners)
        (outerPreview, innerPreview) = await Task.detached {
            (Tracer.traceImage(pixels, outerParams).loops, Tracer.traceImage(pixels, innerParams).loops)
        }.value
    }

    // MARK: Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Trace “\(origin.name)”").font(.headline)
            HStack(alignment: .top, spacing: 18) {
                preview(result?.loops)
                    .frame(width: 420, height: 360)
                    .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Outline", selection: $parameters.inners) {
                        Text("Outer only").tag(false)
                        Text("Outer and inner").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(parameters.inners
                         ? "Also cuts the openings in the artwork, like the inside of an O. The margin narrows them; small ones disappear." as LocalizedStringKey
                         : "Traces only the outer shape — anything inside the artwork is ignored.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    control("Margin", unit: "mm", value: $parameters.margin, span: 0...10, step: 0.5)
                    control("Node count", unit: "%", value: $parameters.nodes, span: 0...100, step: 1)
                    control("Smoothing", unit: "%", value: $parameters.smoothing, span: 0...100, step: 1)
                    control("Background tolerance", unit: "", value: $parameters.tolerance, span: 5...150, step: 1)
                        .disabled(result?.transparent == true)
                    if let result {
                        Text(verbatim: [String(localized: "\(result.loops.count) outlines"), String(localized: "\(result.pointsList) nodes"),
                                        result.transparent ? String(localized: "transparent background") : String(localized: "solid background detected")]
                            .joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 240)
            }
            HStack {
                if origin.ask {
                    Button("Back") {
                        choosing = true
                        Task { await computePreviews() }
                    }
                }
                Spacer()
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Insert") { insert() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(result?.loops.isEmpty ?? true)
            }
        }
    }

    private func recompute() {
        guard let pixels else { return }
        result = Tracer.traceImage(pixels, parameters)
    }

    private func preview(_ loops: [[CGPoint]]?) -> TracePreview {
        TracePreview(image: origin.image, width: parameters.width, margin: parameters.margin,
                          smoothing: parameters.smoothing, loops: loops ?? [])
    }

    private func control(_ title: LocalizedStringKey, unit: String, value: Binding<Double>, span: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                TextField(title, value: value, format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
            }
            // With many steps (the percentages), without the ticks, which turn into a dashed line: it only rounds.
            if (span.upperBound - span.lowerBound) / step > 25 {
                Slider(value: Binding { value.wrappedValue } set: { value.wrappedValue = ($0 / step).rounded() * step }, in: span)
                    .labelsHidden()
            } else {
                Slider(value: value, in: span, step: step)
                    .labelsHidden()
            }
        }
    }

    // MARK: Insert

    /// The image in the frame (prints, doesn't cut); `key` is where its data lives in the document.
    private func imageObject(_ frame: CGRect, key: String) -> CanvasObject {
        var image = doc.newObject(.rectangle(radius: 0), frame: frame)
        image.image = ImageInShape(key: key, transform: Transform(
            CGAffineTransform(scaleX: 1 / Double(origin.image.width), y: 1 / Double(origin.image.height))))
        image.fill = nil
        image.cutsLine = false
        image.label = origin.name
        return image
    }

    private func insert() {
        guard let result, !result.loops.isEmpty else { return }
        let frame = origin.frame(width: parameters.width), key = UUID().uuidString
        var contour = doc.newObject(.shapePath([]), frame: .zero)
        contour.setNodes(result.loops.map { loop in
            Subpath(nodes: Tracer.smoothPoints(loop.map { CGPoint(x: $0.x + frame.minX, y: $0.y + frame.minY) }, parameters.smoothing),
                       closed: true)
        })
        contour.fill = nil
        contour.strokeColor = CMYK(c: 0, m: 100, y: 0, k: 0)
        contour.cutsLine = true
        contour.strokeWidth = 0
        contour.label = String(localized: "\(origin.name) outline")
        // Grouped: the image and the contour move and resize together.
        var image = imageObject(frame, key: key)
        let group = UUID()
        image.groups = [group]
        contour.groups = [group]
        doc.insertImported([image, contour], images: [key: origin.payload])
        doc.tool = .selection
        close()
    }

    /// Just the image, with no cut line.
    private func insertImageOnly() {
        let key = UUID().uuidString
        doc.insertImported([imageObject(origin.frame(width: parameters.width), key: key)], images: [key: origin.payload])
        doc.tool = .selection
        close()
    }
}

/// The image with the contour (in mm, from the image's corner) on top, with the curves as they will go in.
private struct TracePreview: View {
    let image: CGImage
    let width: Double
    let margin: Double
    let smoothing: Double
    let loops: [[CGPoint]]

    var body: some View {
        Canvas { ctx, size in
            let aspectRatio = Double(image.height) / Double(max(image.width, 1))
            let slack = margin + 2
            let total = CGSize(width: width + 2 * slack, height: width * aspectRatio + 2 * slack)
            let e = min(size.width / total.width, size.height / total.height)
            let originX = (size.width - total.width * e) / 2 + slack * e, originY = (size.height - total.height * e) / 2 + slack * e
            ctx.draw(Image(decorative: image, scale: 1),
                     in: CGRect(x: originX, y: originY, width: width * e, height: width * aspectRatio * e))
            let contour = CanvasObject.shapePath(loops.map { loop in
                Subpath(nodes: Tracer.smoothPoints(loop.map { CGPoint(x: originX + $0.x * e, y: originY + $0.y * e) }, smoothing))
            }, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            ctx.stroke(contour, with: .color(Color(red: 0.89, green: 0.29, blue: 0.29)), lineWidth: 1.5)
        }
    }
}

/// One of the choices for the imported image: the preview of the result, the name and what it does.
private struct ImageOption<Preview: View>: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    /// Chosen with Return (highlighted).
    var defaultValue = false
    @ViewBuilder let preview: Preview
    let action: () -> Void
    @State private var over = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                preview
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                    .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                Text(title)
                    .font(.body.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(width: 210, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(.quaternary.opacity(over ? 0.9 : 0.4), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(defaultValue ? Color.accentColor : .clear, lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(defaultValue ? .defaultAction : nil)
        .onHover { over = $0 }
    }
}

extension ImageToTrace {
    /// PNG, JPEG, HEIC, TIFF… (whatever ImageIO opens).
    init?(url: URL) {
        guard let payload = try? Data(contentsOf: url), let font = CGImageSourceCreateWithData(payload as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(font, 0, nil) else { return nil }
        self.init(name: url.deletingPathExtension().lastPathComponent, payload: payload, image: image)
    }
}
