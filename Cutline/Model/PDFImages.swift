// The images of an imported PDF (Model/PDFImport.swift): an image XObject becomes what an image object keeps in the
// document (`Document.images`), like an imported PNG or JPEG. A JPEG in RGB or gray with no mask goes in as it is;
// everything else (Flate, LZW, JPEG 2000, CMYK, indexed, 1 to 16 bits, soft masks, stencil and color-key masks) is
// drawn into an RGBA bitmap and goes in as PNG. CMYK becomes sRGB from the image's own profile or the document's, as a
// Photoshop file's CMYK layers do (Model/PSDImport.swift). Separation and DeviceN images are left out (counted).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum PDFImages {
    /// The image's data for the document and its size in pixels (what `ImageInShape.transform` places it by).
    struct Decoded {
        var data: Data
        var width: Int
        var height: Int
    }

    /// Bigger than this (pixels) is left out: tens of thousands of pixels a side would take gigabytes to decode.
    static let pixelLimit = 200_000_000

    /// `fill`: the color a stencil mask (ImageMask) paints with. `colors`: the document's conversion (the CMYK profile for
    /// DeviceCMYK, the RGB working space for DeviceRGB). `resource`: a color space named in the page's resources (an
    /// inline image's /CS /CS0).
    static func decode(_ stream: PDFStream, fill: CGColor?, colors: ColorConverter?,
                       resource: (UnsafePointer<CChar>) -> CGPDFObjectRef? = { _ in nil }) -> Decoded? {
        guard let dictionary = stream.dictionary, let width = dictionary.integer("Width"), let height = dictionary.integer("Height"),
              width > 0, height > 0, width * height <= pixelLimit else { return nil }
        if dictionary.boolean("ImageMask") == true {
            guard let alpha = stencil(stream, width: width, height: height), let fill else { return nil }
            return png(width: width, height: height, colors: colors) { ctx, rect in
                ctx.clip(to: rect, mask: alpha)
                ctx.setFillColor(fill)
                ctx.fill(rect)
            }
        }
        var format = CGPDFDataFormat.raw
        guard let payload = CGPDFStreamCopyData(stream.ref, &format) as Data? else { return nil }
        var space = dictionary.object("ColorSpace").flatMap { colorSpace($0, colors: colors) }
        var named: UnsafePointer<CChar>?
        if space == nil, let object = dictionary.object("ColorSpace"), CGPDFObjectGetValue(object, .name, &named), let named,
           let found = resource(named) {
            space = colorSpace(found, colors: colors)
        }
        let softMask = dictionary.stream("SMask").flatMap { mask(softMask: $0, width: width, height: height) }
        let stencilMask = dictionary.stream("Mask").flatMap { stencil($0, width: nil, height: nil) }
        let colorKey = dictionary.array("Mask").map { list in (0..<list.count).map { CGFloat(list.number(at: $0) ?? 0) } }
        let plain = softMask == nil && stencilMask == nil && colorKey == nil
        var image: CGImage?
        switch format {
        case .jpegEncoded, .JPEG2000:
            // JPEG in RGB or gray, nothing on top: the file as it is (smaller, and no second compression).
            if format == .jpegEncoded, plain, dictionary.array("Decode") == nil,
               let components = space?.numberOfComponents ?? jpegComponents(payload), components == 1 || components == 3 {
                guard let source = CGImageSourceCreateWithData(payload as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
                return Decoded(data: payload, width: width, height: height)
            }
            guard let source = CGImageSourceCreateWithData(payload as CFData, nil) else { return nil }
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        case .raw:
            guard let space else { return nil }
            image = samples(payload, dictionary: dictionary, width: width, height: height, space: space)
        @unknown default:
            return nil
        }
        guard var image else { return nil }
        if let colorKey, colorKey.count == 2 * (image.colorSpace?.numberOfComponents ?? 0) {
            image = image.copy(maskingColorComponents: colorKey) ?? image
        }
        // RGB or gray, 8 bits, no mask: straight to PNG (keeps the profile). The rest is drawn in sRGB.
        if plain, image.bitsPerComponent == 8, let model = image.colorSpace?.model, model == .rgb || model == .monochrome {
            return encode(image).map { Decoded(data: $0, width: width, height: height) }
        }
        return png(width: width, height: height, colors: colors) { ctx, rect in
            if let mask = softMask ?? stencilMask { ctx.clip(to: rect, mask: mask) }
            ctx.draw(image, in: rect)
        }
    }

    /// The samples of a raw image as a CGImage (bits per component and Decode as in the PDF; what CoreGraphics doesn't
    /// take directly is widened to 8 bits).
    private static func samples(_ payload: Data, dictionary: PDFDict, width: Int, height: Int, space: CGColorSpace) -> CGImage? {
        let bits = dictionary.integer("BitsPerComponent") ?? 8
        let components = space.model == .indexed ? 1 : space.numberOfComponents
        guard [1, 2, 4, 8, 16].contains(bits), components > 0 else { return nil }
        let rowBytes = (width * components * bits + 7) / 8
        guard payload.count >= rowBytes * height else { return nil }
        var decode = dictionary.array("Decode").map { list in (0..<list.count).map { CGFloat(list.number(at: $0) ?? 0) } }
        if decode?.count != 2 * components { decode = nil }
        // CoreGraphics takes 1–8 bits for gray and indexed images, 8 and 16 for color: widen the rest to 8.
        if bits < 8, space.model != .monochrome, space.model != .indexed {
            let maximum = (1 << bits) - 1
            var wide = [UInt8](repeating: 0, count: width * components * height)
            payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for y in 0..<height {
                    for k in 0..<(width * components) {
                        let bit = k * bits, byte = raw[y * rowBytes + bit / 8]
                        let value = Int(byte >> (8 - bits - bit % 8)) & maximum
                        wide[y * width * components + k] = UInt8(value * 255 / maximum)
                    }
                }
            }
            return image(Data(wide), width: width, height: height, bits: 8, components: components, space: space, decode: decode)
        }
        return image(payload, width: width, height: height, bits: bits, components: components, space: space, decode: decode)
    }

    private static func image(_ payload: Data, width: Int, height: Int, bits: Int, components: Int, space: CGColorSpace,
                              decode: [CGFloat]?) -> CGImage? {
        guard let provider = CGDataProvider(data: payload as CFData) else { return nil }
        let info: CGBitmapInfo = bits == 16 ? [.byteOrder16Big] : []
        return CGImage(width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bits * components,
                       bytesPerRow: (width * components * bits + 7) / 8, space: space, bitmapInfo: info, provider: provider,
                       decode: decode, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// A stencil mask (ImageMask, or an image's Mask stream) as a gray alpha image: 1 where it paints (sample 0, or 1 with
    /// Decode [1 0]). `width`/`height` nil = the mask's own.
    private static func stencil(_ stream: PDFStream, width: Int?, height: Int?) -> CGImage? {
        guard let dictionary = stream.dictionary, let data = stream.data else { return nil }
        let w = width ?? dictionary.integer("Width") ?? 0, h = height ?? dictionary.integer("Height") ?? 0
        let rowBytes = (w + 7) / 8
        guard w > 0, h > 0, data.count >= rowBytes * h else { return nil }
        let inverted = dictionary.array("Decode").flatMap { $0.number(at: 0) } == 1
        var alpha = [UInt8](repeating: 0, count: w * h)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for y in 0..<h {
                for x in 0..<w {
                    let bit = raw[y * rowBytes + x / 8] >> (7 - x % 8) & 1
                    alpha[y * w + x] = (bit == 0) != inverted ? 255 : 0
                }
            }
        }
        return gray(alpha, width: w, height: h)
    }

    /// A soft mask (SMask: a gray image, any size, maybe with Decode) as an alpha image.
    private static func mask(softMask stream: PDFStream, width: Int, height: Int) -> CGImage? {
        guard let dictionary = stream.dictionary, let w = dictionary.integer("Width"), let h = dictionary.integer("Height"),
              w > 0, h > 0, w * h <= pixelLimit else { return nil }
        var format = CGPDFDataFormat.raw
        guard let payload = CGPDFStreamCopyData(stream.ref, &format) as Data? else { return nil }
        let gray = CGColorSpaceCreateDeviceGray()
        let image: CGImage?
        if format == .raw {
            image = samples(payload, dictionary: dictionary, width: w, height: h, space: gray)
        } else {
            image = CGImageSourceCreateWithData(payload as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        }
        guard let image else { return nil }
        // In a plain 8-bit gray bitmap (what clip(to:mask:) takes as alpha).
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: gray,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func gray(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Draws into an sRGB RGBA bitmap of the image's size and returns it as PNG.
    private static func png(width: Int, height: Int, colors: ColorConverter?, draw: (CGContext, CGRect) -> Void) -> Decoded? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // As the canvas shows CMYK (Model/ColorConversion.swift).
        ctx.setRenderingIntent(colors?.intent ?? .defaultIntent)
        ctx.interpolationQuality = .high
        draw(ctx, CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage().flatMap(encode).map { Decoded(data: $0, width: width, height: height) }
    }

    private static func encode(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// Components of a JPEG by its frame header (SOF), when the PDF doesn't say.
    private static func jpegComponents(_ data: Data) -> Int? {
        let b = [UInt8](data.prefix(65536))
        var i = 2
        while i + 9 < b.count {
            guard b[i] == 0xFF else { return nil }
            let marker = b[i + 1], length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            if (0xC0...0xCF).contains(marker), marker != 0xC4, marker != 0xC8, marker != 0xCC { return Int(b[i + 9]) }
            i += 2 + length
        }
        return nil
    }

    /// An image's color space. DeviceCMYK uses the document's CMYK profile and DeviceRGB its RGB working space; nil =
    /// one Cutline doesn't draw (Separation, DeviceN, Pattern).
    static func colorSpace(_ object: CGPDFObjectRef, colors: ColorConverter?) -> CGColorSpace? {
        var name: UnsafePointer<CChar>?
        if CGPDFObjectGetValue(object, .name, &name), let name { return device(String(cString: name), colors: colors) }
        var raw: CGPDFArrayRef?
        guard CGPDFObjectGetValue(object, .array, &raw), let raw else { return nil }
        let list = PDFArray(raw)
        guard let family = list.name(at: 0) else { return nil }
        switch family {
        case "ICCBased":
            guard let stream = list.stream(at: 1) else { return nil }
            if let data = stream.data, let space = CGColorSpace(iccData: data as CFData) { return space }
            if let alternate = stream.dictionary?.object("Alternate") { return colorSpace(alternate, colors: colors) }
            switch stream.dictionary?.integer("N") {
            case 1: return device("DeviceGray", colors: colors)
            case 4: return device("DeviceCMYK", colors: colors)
            default: return device("DeviceRGB", colors: colors)
            }
        case "CalRGB": return device("DeviceRGB", colors: colors)
        case "CalGray": return device("DeviceGray", colors: colors)
        case "Lab":
            let white = list.dictionary(at: 1)?.array("WhitePoint")
            let point = (0..<3).map { CGFloat(white?.number(at: $0) ?? [0.9505, 1, 1.089][$0]) }
            let range = list.dictionary(at: 1)?.array("Range")
            let limits = (0..<4).map { CGFloat(range?.number(at: $0) ?? [-100, 100, -100, 100][$0]) }
            return CGColorSpace(labWhitePoint: point, blackPoint: nil, range: limits)
        case "Indexed", "I":
            guard let baseObject = list.object(at: 1), let base = colorSpace(baseObject, colors: colors),
                  let last = list.number(at: 2) else { return nil }
            var table: Data?
            if let lookup = list.object(at: 3) {
                var string: CGPDFStringRef?
                var stream: CGPDFStreamRef?
                if CGPDFObjectGetValue(lookup, .string, &string), let string, let bytes = CGPDFStringGetBytePtr(string) {
                    table = Data(bytes: bytes, count: CGPDFStringGetLength(string))
                } else if CGPDFObjectGetValue(lookup, .stream, &stream), let stream {
                    table = PDFStream(stream).data
                }
            }
            let entries = Int(last) + 1, size = entries * base.numberOfComponents
            guard var bytes = table.map({ [UInt8]($0) }), entries > 0, entries <= 256 else { return nil }
            if bytes.count < size { bytes += [UInt8](repeating: 0, count: size - bytes.count) }
            return CGColorSpace(indexedBaseSpace: base, last: entries - 1, colorTable: bytes)
        default:
            return device(family, colors: colors)
        }
    }

    private static func device(_ name: String, colors: ColorConverter?) -> CGColorSpace? {
        switch name {
        case "DeviceGray", "G", "CalGray": return CGColorSpaceCreateDeviceGray()
        case "DeviceRGB", "RGB", "CalRGB": return colors?.rgbSpace ?? CGColorSpace(name: CGColorSpace.sRGB)
        case "DeviceCMYK", "CMYK": return colors?.cmykSpace ?? CGColorSpace(name: CGColorSpace.genericCMYK)
        default: return nil
        }
    }
}

nonisolated extension PDFImages {
    /// An image XObject already in the document: its key and size in pixels (nil = it couldn't be read).
    struct Placed {
        var key: String
        var width: Int
        var height: Int
    }
}

nonisolated extension PDFImport.Reader {
    /// Do with an image: an image object at its place on the page (the unit square through the CTM), clipped by the
    /// clipping paths (the object's outline is what shows of the image). Prints, doesn't cut.
    func paintImage(_ stream: PDFStream) {
        flushText()
        guard state.fillAlpha > 0 else { return }
        let stencil = stream.dictionary?.boolean("ImageMask") == true
        // A stencil mask paints with the fill color: the same mask with another color is another image. An inline
        // image's stream lasts only while it's read.
        let cached = !stencil && !stream.inline
        let fill = stencil ? state.fill.map { (VectorImporter.colors ?? ColorSettings.shared.converter()).printColor($0) } : nil
        let placed: PDFImages.Placed
        if cached, let known = imageKeys[stream.ref] {
            placed = known
        } else {
            let content = contents.last
            let decoded = PDFImages.decode(stream, fill: fill, colors: VectorImporter.colors) { name in
                content.flatMap { CGPDFContentStreamGetResource($0, "ColorSpace", name) }
            }
            guard let decoded else {
                images += 1
                return
            }
            placed = PDFImages.Placed(key: UUID().uuidString, width: decoded.width, height: decoded.height)
            imageData[placed.key] = decoded.data
            if cached { imageKeys[stream.ref] = placed }
        }
        let unitToPage = state.ctm.concatenating(toPage)
        var outline: CGPath = CGPath(rect: CGRect(x: 0, y: 0, width: 1, height: 1), transform: [unitToPage])
        if let clip = state.clip {
            let box = outline.boundingBoxOfPath
            if !(clip.isRect && clip.box.insetBy(dx: -ImportClipping.tolerance, dy: -ImportClipping.tolerance).contains(box)) {
                guard !box.intersection(clip.box).isNull else { return }
                if let visible = ImportClipping.visible(outline, in: clip.path, line: false) {
                    guard !visible.isEmpty else { return }
                    outline = visible
                }
            }
        }
        guard let free = CanvasObject.freePath(outline), free.frame.width > ImportClipping.tolerance,
              free.frame.height > ImportClipping.tolerance else { return }
        var object = CanvasObject(shape: .shapePath(free.subpaths), frame: free.frame)
        // Pixel (origin at the top left) → the unit square (y up) → page mm → the frame (0…1).
        let pixelToUnit = CGAffineTransform(a: 1 / Double(placed.width), b: 0, c: 0, d: -1 / Double(placed.height), tx: 0, ty: 1)
        let pageToFrame = CGAffineTransform(translationX: -free.frame.minX, y: -free.frame.minY)
            .concatenating(CGAffineTransform(scaleX: 1 / free.frame.width, y: 1 / free.frame.height))
        object.image = ImageInShape(key: placed.key, transform: Transform(pixelToUnit.concatenating(unitToPage).concatenating(pageToFrame)))
        object.fill = nil
        object.cutsLine = false
        objects.append(object)
    }
}
