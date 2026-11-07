// A vector file with more paths than Cutline handles well (an Illustrator texture or image trace brings tens of
// thousands, almost all of them print-only specks): before it goes in, a choice. Flatten turns everything that only
// prints (a PDF's images too) into one 300 dpi image and keeps the cut lines as paths; Simplify leaves out the
// print-only pieces smaller than a size the user picks; Import All Paths brings every path, as before.
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct ManyPaths: Identifiable {
    /// More paths than this and the import asks first.
    static let threshold = 5_000

    let id = UUID()
    /// The file's name, for the title and the notice.
    let name: String
    let result: VectorImport
    /// A page from Open from Canva…: the notice doesn't send the person to Illustrator for the text.
    var fromCanva = false

    var cutting: [CanvasObject] { result.objects.filter(\.cutsLine) }

    /// An object's biggest side, in mm: what Simplify compares with the chosen size.
    static func size(_ object: CanvasObject) -> Double { max(object.frame.width, object.frame.height) }

    /// What Simplify keeps, in the file's order: the cut lines always, the print-only pieces from `limit` mm up.
    func kept(from limit: Double) -> [CanvasObject] {
        result.objects.filter { $0.cutsLine || Self.size($0) >= limit }
    }

    /// The data of the images these objects show (a PDF's images: only those that go in).
    func images(of objects: [CanvasObject]) -> [String: Data] {
        result.imageData.filter { key, _ in objects.contains { $0.image?.key == key } }
    }
}

/// Filled outlines ready to draw off the main thread (a CGPath or CGColor doesn't change once made).
nonisolated struct FillPieces: @unchecked Sendable {
    var paths: [CGPath] = []
    var colors: [CGColor] = []
    /// A PDF's images, by the index of their outline in `paths`: the image and where its pixels go (pixel → page mm).
    var pictures: [Int: (image: CGImage, toPage: CGAffineTransform)] = [:]
    /// How CMYK goes into the RGB image (the document's: as the canvas shows it).
    var intent = CGColorRenderingIntent.defaultIntent
    /// Each piece's biggest side, in mm (infinite for the cut lines, which Simplify never leaves out).
    var sizes: [Double] = []
    /// Around every piece, in page mm.
    var box = CGRect.null

    /// The flattened image's resolution.
    static let dotsPerInch = 300.0

    /// The fills drawn with even-odd, like the canvas and the print, in the document's CMYK profile, and the images
    /// (`images`: their data by key) clipped by their outlines.
    @MainActor init(_ objects: [CanvasObject], colors converter: ColorConverter, images: [String: Data] = [:]) {
        intent = converter.intent
        for object in objects {
            let path = object.shapePath.cgPath
            if let inShape = object.image, let payload = images[inShape.key],
               let source = CGImageSourceCreateWithData(payload as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                pictures[paths.count] = (image, inShape.transform.cg.concatenating(object.frameToPage))
                colors.append(CGColor(gray: 0, alpha: 0))
            } else if let fill = object.fill {
                colors.append(converter.printColor(fill))
            } else {
                continue
            }
            paths.append(path)
            sizes.append(object.cutsLine ? .infinity : ManyPaths.size(object))
            box = box.union(path.boundingBoxOfPath)
        }
    }

    /// The pieces from `limit` mm up, on a transparent bitmap covering `box` (mm, y down).
    func image(of box: CGRect, pixelsPerMM: Double, from limit: Double = 0) -> CGImage? {
        guard !box.isNull, box.width > 0, box.height > 0 else { return nil }
        let width = max(1, Int((box.width * pixelsPerMM).rounded(.up)))
        let height = max(1, Int((box.height * pixelsPerMM).rounded(.up)))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: Double(height))
        ctx.scaleBy(x: pixelsPerMM, y: -pixelsPerMM)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        // As the canvas shows the CMYK (Model/ColorConversion.swift).
        ctx.setRenderingIntent(intent)
        for i in paths.indices where sizes[i] >= limit {
            ctx.addPath(paths[i])
            if let picture = pictures[i] {
                // As the print draws an image (Printing.swift): clipped by the outline, pixels with y down.
                ctx.saveGState()
                ctx.clip(using: .evenOdd)
                ctx.concatenate(picture.toPage)
                ctx.translateBy(x: 0, y: Double(picture.image.height))
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(picture.image, in: CGRect(x: 0, y: 0, width: picture.image.width, height: picture.image.height))
                ctx.restoreGState()
                continue
            }
            ctx.setFillColor(colors[i])
            ctx.fillPath(using: .evenOdd)
        }
        return ctx.makeImage()
    }

    /// Everything as one image at `dotsPerInch` (less if it would pass 8000 pixels on a side): the
    /// PNG, its size in pixels and where it goes on the page (the box, rounded up to whole pixels).
    func flattened() -> (png: Data, pixels: CGSize, frame: CGRect)? {
        guard !box.isNull, box.width > 0, box.height > 0 else { return nil }
        let pixelsPerMM = min(Self.dotsPerInch / 25.4, 8000 / max(box.width, box.height))
        guard let image = image(of: box, pixelsPerMM: pixelsPerMM) else { return nil }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let pixels = CGSize(width: image.width, height: image.height)
        let frame = CGRect(origin: box.origin, size: CGSize(width: pixels.width / pixelsPerMM, height: pixels.height / pixelsPerMM))
        return (png as Data, pixels, frame)
    }
}

struct ManyPathsWindow: View {
    let doc: Document
    let origin: ManyPaths
    @Environment(\.dismiss) private var close
    @AppStorage(LengthUnit.key) private var unit = LengthUnit.mm
    /// Simplify's size, in mm.
    @State private var limit = 1.0
    /// Every fill (previews) and the print-only ones (what Flatten draws), made once.
    @State private var everything: FillPieces?
    @State private var cutLines: [CGPath] = []
    /// Biggest side of each print-only piece, mm (to count what Simplify keeps).
    @State private var printSizes: [Double] = []
    @State private var flatPreview: CGImage?
    @State private var simplePreview: CGImage?
    @State private var flattening = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("“\(origin.name)” has \(origin.result.objects.count) paths").font(.headline)
                Text("That’s a lot for Cutline. \(origin.cutting.count) of them cut, the rest only prints.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 12) {
                ImageOption(title: "Flatten what prints",
                            detail: "Everything that only prints becomes one image at 300 dpi. The cut lines stay as they are.",
                            defaultValue: true) {
                    PiecesPreview(image: flatPreview, box: everything?.box, cuts: cutLines)
                } action: { flatten() }
                simplifyCard
            }
            HStack(spacing: 8) {
                Button("Import All Paths") { importAll() }
                Spacer()
                if flattening {
                    ProgressView().controlSize(.small)
                    Text("Flattening…").foregroundStyle(.secondary)
                }
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 480)
        .disabled(flattening)
        .task {
            let all = FillPieces(origin.result.objects, colors: doc.colors, images: origin.result.imageData)
            everything = all
            cutLines = origin.cutting.map { $0.shapePath.cgPath }
            printSizes = origin.result.objects.filter { !$0.cutsLine }.map(ManyPaths.size)
            let pixelsPerMM = 420 / max(all.box.width, all.box.height, 1)
            flatPreview = await Task.detached { all.image(of: all.box, pixelsPerMM: pixelsPerMM) }.value
            #if DEBUG
            switch DebugHooks.manyPathsChoice {
            case "flatten"?: flatten()
            case "all"?: importAll()
            case "cancel"?: close()
            case let choice? where choice.hasPrefix("simplify"):
                if let size = Double(choice.dropFirst("simplify:".count)) { limit = size }
                simplify()
            default: break
            }
            #endif
        }
        .task(id: limit) {
            // Redrawn when the size settles (typing or holding the stepper changes it many times).
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let all = everything else { return }
            let (pixelsPerMM, from) = (420 / max(all.box.width, all.box.height, 1), limit)
            simplePreview = await Task.detached { all.image(of: all.box, pixelsPerMM: pixelsPerMM, from: from) }.value
        }
    }

    /// Simplify's card: like an `ImageOption`, with the size field and the count under the button.
    private var simplifyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { simplify() } label: {
                VStack(alignment: .leading, spacing: 8) {
                    PiecesPreview(image: simplePreview ?? flatPreview, box: everything?.box, cuts: cutLines)
                        .frame(height: 150)
                        .frame(maxWidth: .infinity)
                        .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    Text("Simplify")
                        .font(.body.weight(.semibold))
                    Text("Leaves out the print-only pieces smaller than this size. Cut lines always stay.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 6) {
                Text("Smaller than")
                TextField("Size", value: shownLimit, format: .number.precision(.fractionLength(0...unit.fractionDigits)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 56)
                Stepper("Size", value: shownLimit, in: unit.show(0.05)...unit.show(50), step: unit.show(0.25))
                    .labelsHidden()
                Text(verbatim: unit.symbol)
            }
            .font(.callout)
            Text("Paths left: \(keptCount) of \(origin.result.objects.count)")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(width: 210, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
    }

    /// The size in the unit from Settings (the document keeps mm).
    private var shownLimit: Binding<Double> {
        Binding { unit.show(limit) } set: { limit = min(max(unit.mm($0), 0.05), 50) }
    }

    private var keptCount: Int { origin.cutting.count + printSizes.count(where: { $0 >= limit }) }

    private func flatten() {
        guard !flattening else { return }
        flattening = true
        let printOnly = FillPieces(origin.result.objects.filter { !$0.cutsLine }, colors: doc.colors, images: origin.result.imageData)
        Task {
            let flat = await Task.detached { printOnly.flattened() }.value
            let key = UUID().uuidString
            var objects: [CanvasObject] = []
            if let flat {
                let name = (origin.name as NSString).deletingPathExtension
                objects.append(doc.imageObject(flat.frame, key: key, pixels: flat.pixels, name: name))
            }
            objects += origin.cutting
            doc.insertImported(objects, images: flat.map { [key: $0.png] } ?? [:])
            var lead = flat == nil ? [] : [String(localized: "\(1) images")]
            if !origin.cutting.isEmpty { lead.append(String(localized: "\(origin.cutting.count) paths")) }
            doc.notice = origin.result.notice(from: origin.name, lead: lead, fromCanva: origin.fromCanva)
            close()
        }
    }

    private func simplify() {
        let kept = origin.kept(from: limit)
        doc.insertImported(kept, images: origin.images(of: kept))
        doc.notice = origin.result.notice(from: origin.name, lead: [
            String(localized: "\(kept.count) paths"),
            String(localized: "\(origin.result.objects.count - kept.count) small pieces left out"),
        ], fromCanva: origin.fromCanva)
        close()
    }

    private func importAll() {
        doc.insertImported(origin.result.objects, images: origin.result.imageData)
        doc.notice = origin.result.notice(from: origin.name, fromCanva: origin.fromCanva)
        close()
    }
}

/// The file's fills (already drawn) with its cut lines in red on top.
private struct PiecesPreview: View {
    let image: CGImage?
    /// What the image covers, in page mm.
    let box: CGRect?
    let cuts: [CGPath]

    var body: some View {
        Canvas { ctx, size in
            guard let box, !box.isNull, box.width > 0, box.height > 0 else { return }
            let area = box.insetBy(dx: -2, dy: -2)
            let e = min(size.width / area.width, size.height / area.height)
            let place = CGAffineTransform(translationX: (size.width - area.width * e) / 2 - area.minX * e,
                                          y: (size.height - area.height * e) / 2 - area.minY * e).scaledBy(x: e, y: e)
            if let image { ctx.draw(Image(decorative: image, scale: 1), in: box.applying(place)) }
            var path = Path()
            for cut in cuts { path.addPath(Path(cut), transform: place) }
            ctx.stroke(path, with: .color(Color(red: 0.89, green: 0.29, blue: 0.29)), lineWidth: 1.5)
        }
        .overlay { if image == nil { ProgressView().controlSize(.small) } }
    }
}
