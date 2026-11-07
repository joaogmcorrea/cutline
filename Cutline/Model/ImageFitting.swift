// An image inside a shape, as Silhouette Studio's Fill Pattern and Illustrator's clipping mask: the shape's outline clips
// the image, the image prints, and the shape's stroke stays the cut line (the image sends nothing to the machine). The image
// is the object's `image` (`ImageInShape`: its key and where its pixels sit in the frame), which every version of Cutline
// draws clipped by the outline; `ImageFitting` says how it sits in the shape: Fill (covers it), Fit (whole, inside it),
// Stretch or Tile (repeated as a pattern), the content moved, scaled and turned inside the shape (double click, Esc to
// leave), and the image's opacity. The placement is worked out from these (`pixelToFrame`) whenever the frame's size changes,
// so Fill keeps covering a resized shape. Putting images in and taking them out: Editor/ImageInsideShape.swift.
// In the file the fitting goes in `imagemNaForma`, beside `imagem`, which the versions before it draw as it is: an image
// that repeats or is transparent goes there already drawn and clipped (`flattenedForFile`), with the original's key here.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// How the image sits in the shape. The raw values are stored on disk (Portuguese, like the rest of the format).
nonisolated enum ImageFitMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Covers the shape, keeping its proportions (some of it is cut off): the default, as Studio's pattern.
    case fill = "preencher"
    /// The whole image inside the shape, keeping its proportions.
    case fit = "caber"
    /// Stretched to the shape's box.
    case stretch = "esticar"
    /// Repeated as a pattern, as Studio's fixed pattern; the scale sets the tiles' size.
    case tile = "repetir"

    var id: Self { self }
}

/// How the image of an object sits inside its outline (see the top of the file). Stored as `imagemNaForma`.
nonisolated struct ImageFitting: Hashable, Codable, Sendable {
    /// The keys stored on disk follow the names of the 1.0 format (Portuguese), like the others.
    enum CodingKeys: String, CodingKey {
        case mode = "modo", scaleX = "escalaX", scaleY = "escalaY", angle = "angulo", offset = "deslocamento",
             opacity = "opacidade", pixelWidth = "largura", pixelHeight = "altura", fileKey = "chave"
    }

    var mode = ImageFitMode.fill
    /// The content's size over the size the mode gives it, along the image's own sides (1 = as the mode puts it; Tile: the
    /// tiles' size). Negative = mirrored (only from an image placed that way).
    var scaleX = 1.0
    var scaleY = 1.0
    /// Degrees, counterclockwise: the content turned inside the shape (the shape's own rotation turns it too).
    var angle = 0.0
    /// Where the image's center is from the frame's center, in fractions of the frame's width and height (so it follows a
    /// resize).
    var offset = CGPoint.zero
    /// 0…1 (Studio's pattern transparency is 1 − this).
    var opacity = 1.0
    /// The image's size in pixels (a linked image's full size): the placement is worked out from it.
    var pixelWidth: Double
    var pixelHeight: Double
    /// Only in the file: the original image's key, while `imagem` holds the image already drawn (tiled or transparent).
    var fileKey: String?

    /// The content's scale in the control bar and while editing it (5 % to 2000 %).
    static let scaleRange = 0.05...20.0
    /// Tile at 100 %: this many tiles where Fit would put one image (the tiles follow the shape's size, as everything else in it).
    static let tilesPerFit = 4.0

    init(mode: ImageFitMode = .fill, pixels: CGSize) {
        self.mode = mode
        pixelWidth = Double(pixels.width)
        pixelHeight = Double(pixels.height)
    }

    /// Tolerant reading: what is missing gets the default; a mode a later version wrote and this one doesn't know, Fill.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decodeIfPresent(ImageFitMode.self, forKey: .mode)).flatMap { $0 } ?? .fill
        scaleX = try c.decodeIfPresent(Double.self, forKey: .scaleX) ?? 1
        scaleY = try c.decodeIfPresent(Double.self, forKey: .scaleY) ?? scaleX
        angle = CanvasObject.normalizedAngle(try c.decodeIfPresent(Double.self, forKey: .angle) ?? 0)
        offset = try c.decodeIfPresent(CGPoint.self, forKey: .offset) ?? .zero
        opacity = min(max(try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1, 0), 1)
        pixelWidth = try c.decode(Double.self, forKey: .pixelWidth)
        pixelHeight = try c.decode(Double.self, forKey: .pixelHeight)
        fileKey = try c.decodeIfPresent(String.self, forKey: .fileKey)
        guard pixelWidth > 0, pixelHeight > 0, [scaleX, scaleY, offset.x, offset.y].allSatisfy(\.isFinite), scaleX != 0, scaleY != 0 else {
            throw DecodingError.dataCorruptedError(forKey: .pixelWidth, in: c, debugDescription: "invalid image fitting")
        }
    }

    /// The pixels' size (never zero).
    var pixels: CGSize { CGSize(width: max(pixelWidth, 1), height: max(pixelHeight, 1)) }

    /// The size, in mm per pixel, the mode gives the image in a frame of that size (before the content's own scale).
    func baseScale(in size: CGSize) -> (x: Double, y: Double) {
        let w = pixels.width, h = pixels.height
        let width = max(size.width, 1e-9), height = max(size.height, 1e-9)
        switch mode {
        case .fill:
            let s = max(width / w, height / h)
            return (s, s)
        case .fit:
            let s = min(width / w, height / h)
            return (s, s)
        case .stretch:
            return (width / w, height / h)
        case .tile:
            let s = min(width / w, height / h) / Self.tilesPerFit
            return (s, s)
        }
    }

    /// Image pixel (origin at the top-left corner) → page mm, in the unrotated frame `r`: the mode's size, the content's
    /// scale and turn around the image's center, which sits at the frame's center moved by `offset`.
    func pixelToLocal(in r: CGRect) -> CGAffineTransform {
        let base = baseScale(in: r.size)
        let center = CGPoint(x: r.midX + offset.x * r.width, y: r.midY + offset.y * r.height)
        return CGAffineTransform(translationX: -pixels.width / 2, y: -pixels.height / 2)
            .concatenating(CGAffineTransform(scaleX: base.x * scaleX, y: base.y * scaleY))
            .concatenating(CanvasObject.rotation(angle, around: .zero))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
    }

    /// Image pixel → frame unit (0…1): what `ImageInShape.transform` keeps.
    func pixelToFrame(in r: CGRect) -> CGAffineTransform {
        let width = max(r.width, 1e-9), height = max(r.height, 1e-9)
        return pixelToLocal(in: r).concatenating(CGAffineTransform(a: 1 / width, b: 0, c: 0, d: 1 / height,
                                                                   tx: -r.minX / width, ty: -r.minY / height))
    }

    /// Takes the content's scale, turn and place from an image already placed (`placement`: pixel → page mm in the unrotated
    /// frame `r`), keeping the mode: the image stays exactly where it was (Make Clipping Mask, Reset Bounding Box). A slant,
    /// which the content can't have, is left out (the nearest placement without it).
    mutating func adopt(_ placement: CGAffineTransform, in r: CGRect) {
        let base = baseScale(in: r.size)
        let axisX = CGPoint(x: placement.a, y: placement.b), axisY = CGPoint(x: placement.c, y: placement.d)
        angle = CanvasObject.normalizedAngle(atan2(-axisX.y, axisX.x) * 180 / .pi)
        let (s, c) = CanvasObject.sinCos(angle)
        scaleX = hypot(axisX.x, axisX.y) / base.x
        // Along the turned y axis: negative when the image was mirrored.
        scaleY = (axisY.x * s + axisY.y * c) / base.y
        if abs(scaleY) < 1e-9 { scaleY = scaleX }
        let center = CGPoint(x: pixels.width / 2, y: pixels.height / 2).applying(placement)
        offset = CGPoint(x: (center.x - r.midX) / max(r.width, 1e-9), y: (center.y - r.midY) / max(r.height, 1e-9))
    }

    /// The content back to how the mode puts it (centered, upright, 100 %).
    mutating func resetContent() {
        scaleX = 1
        scaleY = 1
        angle = 0
        offset = .zero
    }

    /// The content's scale as one number (the control bar's), keeping the ratio between the two sides.
    var scale: Double { abs(scaleX) }

    mutating func setScale(_ value: Double) {
        let v = min(max(value, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
        let ratio = scaleX != 0 ? scaleY / scaleX : 1
        scaleX = scaleX < 0 ? -v : v
        scaleY = abs(scaleX) * ratio * (scaleX < 0 ? -1 : 1)
    }

    /// Drawn as it is, the image doesn't show right in the versions before it: it repeats or is transparent.
    var needsFlatImage: Bool { mode == .tile || opacity < 1 }
}

extension CanvasObject {
    /// Works the image's placement out again from its fitting (the frame's size or the fitting changed).
    nonisolated mutating func refitImage() {
        guard let fitting = imageFit, image != nil else { return }
        let placed = Transform(fitting.pixelToFrame(in: frame.standardized))
        image?.transform = placed
    }

    /// Puts the image at this placement (pixel → frame unit): as it is, or, in a shape, as the content's scale, turn and
    /// place (Reset Bounding Box, a slanting stretch: the image keeps its place on the page).
    nonisolated mutating func placeImage(_ pixelToFrame: CGAffineTransform) {
        guard image != nil else { return }
        guard var fitting = imageFit else {
            image?.transform = Transform(pixelToFrame)
            return
        }
        fitting.adopt(pixelToFrame.concatenating(unrotatedFrameToPage), in: frame.standardized)
        imageFit = fitting
    }

    /// The image's pixel → page mm, with the object's rotation.
    var imageToPage: CGAffineTransform? {
        image.map { $0.transform.cg.concatenating(frameToPage) }
    }

    /// An image inside a shape (put there by dropping, Paste Inside or Make Clipping Mask): it has a fitting. An image on its
    /// own (imported, opened from a .studio3) has the image without one.
    var hasImageInside: Bool { image != nil && imageFit != nil }
}

/// Drawing an object's image, the same on the canvas, in the print, the Finder's previews and the file's flattened image.
nonisolated enum ImageFillDrawing {
    /// Draws the image in a context in page mm with y down that is already clipped to the outline: placed by `pixelToPage`,
    /// repeated for Tile, with the fitting's opacity. `pixels`: the size the placement counts (a missing linked image's
    /// preview is smaller, and covers the same box).
    static func draw(_ image: CGImage, pixels: CGSize, pixelToPage: CGAffineTransform, fitting: ImageFitting?, in cg: CGContext) {
        cg.saveGState()
        defer { cg.restoreGState() }
        if let fitting, fitting.opacity < 1 { cg.setAlpha(max(fitting.opacity, 0)) }
        cg.concatenate(pixelToPage)
        // Pixels with y down: flip the image back (CoreGraphics draws with y up).
        cg.translateBy(x: 0, y: pixels.height)
        cg.scaleBy(x: 1, y: -1)
        let cell = CGRect(origin: .zero, size: pixels)
        if fitting?.mode == .tile {
            // The tiles fill what the clip leaves (the outline), along the image's own sides.
            cg.draw(image, in: cell, byTiling: true)
        } else {
            cg.draw(image, in: cell)
        }
    }

    /// An image read from its data (PNG, JPEG…), off the main thread.
    static func decode(_ payload: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(payload as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

// MARK: The file

extension CanvasObject {
    /// The key the file gives the image of this object already drawn (the same on each save, so the file doesn't change
    /// when nothing did).
    nonisolated var flatImageKey: String { id.uuidString + "-flat" }
}

nonisolated enum ImageFlattening {
    /// Print resolution of a flattened image (at most), and the side it never goes past.
    static let maxPixelsPerMM = 300 / 25.4
    static let minPixelsPerMM = 4.0
    static let maxSide = 4096.0

    /// The objects as the file keeps them: an image that repeats or is transparent goes in `imagem` already drawn and clipped
    /// by the outline (over the unrotated frame), so the versions before image fitting show it as it is; the original's key
    /// goes in the fitting (`chave`). Returns the objects and the flattened images' data (PNG), by key.
    static func forFile(_ objects: [CanvasObject], images: [String: Data], links: [String: ImageLink]) -> ([CanvasObject], [String: Data]) {
        guard objects.contains(where: { $0.imageFit?.needsFlatImage == true && $0.image != nil }) else { return (objects, [:]) }
        var result = objects, added: [String: Data] = [:]
        for i in result.indices {
            guard var fitting = result[i].imageFit, fitting.needsFlatImage, let image = result[i].image,
                  let payload = images[image.key] ?? links[image.key]?.preview,
                  let flat = flatten(result[i], payload: payload, pixels: fitting.pixels) else { continue }
            let key = result[i].flatImageKey
            added[key] = flat.png
            fitting.fileKey = image.key
            // The fitting first (setting it works the placement out again), then the drawn image's.
            result[i].imageFit = fitting
            result[i].image = ImageInShape(key: key, transform: flat.transform)
        }
        return (result, added)
    }

    /// The image of an object drawn as it shows inside its outline (tiled, transparent, clipped), over its unrotated frame:
    /// PNG data and where those pixels sit in the frame (pixel → frame unit). nil when the image can't be read.
    static func flatten(_ object: CanvasObject, payload: Data, pixels: CGSize) -> (png: Data, transform: Transform)? {
        guard let source = ImageFillDrawing.decode(payload), let placed = object.image, let outline = object.localOutlineWithoutText else { return nil }
        let r = object.frame.standardized
        guard r.width > 0, r.height > 0 else { return nil }
        // As sharp as the image is where it sits (never more than 300 dpi), within the largest side.
        let placement = placed.transform.cg.concatenating(object.unrotatedFrameToPage)
        let mmPerPixel = max(hypot(placement.a, placement.b), 1e-9)
        var ppm = min(max(Double(source.width) / pixels.width / mmPerPixel, minPixelsPerMM), maxPixelsPerMM)
        ppm = min(ppm, maxSide / max(r.width, r.height))
        let width = max(Int((r.width * ppm).rounded(.up)), 1), height = max(Int((r.height * ppm).rounded(.up)), 1)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        cg.interpolationQuality = .high
        // Page mm (y down) of the frame → the bitmap's pixels.
        cg.translateBy(x: 0, y: Double(height))
        cg.scaleBy(x: Double(width) / r.width, y: -Double(height) / r.height)
        cg.translateBy(x: -r.minX, y: -r.minY)
        cg.addPath(outline)
        cg.clip(using: .evenOdd)
        ImageFillDrawing.draw(source, pixels: pixels, pixelToPage: placement, fitting: object.imageFit, in: cg)
        guard let drawn = cg.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, drawn, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, Transform(CGAffineTransform(scaleX: 1 / Double(width), y: 1 / Double(height))))
    }
}
