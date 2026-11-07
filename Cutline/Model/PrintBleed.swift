// Print bleed (Print & Cut, experimental): each closed cut line that goes to the machine gets a band `width` mm wide
// around it, filled with the color of the nearest printed pixel on the side that stays (inside the line, even-odd, as
// the print fills it), and drawn under all the art. If the cut lands a little off, the sticker's edge shows that color
// instead of white paper. Unlike Silhouette Studio, the color comes only from fully inked pixels (not from "anything that
// isn't pure white"), so the soft edge of an image doesn't spread white; and the nearest color is found by real distance,
// so curves don't get stripes. Plan: _docs/PLANO-SANGRIA.md.
// The bands are made in two steps: the art and the masks are drawn on the main thread (the drawing uses the document),
// then the nearest color is searched anywhere (the canvas preview does it off the main thread).
import CoreGraphics
import Foundation
import SwiftUI

/// The bleed setting of a document (stored in the .cutline under "sangria", only when it isn't the default).
nonisolated struct PrintBleed: Hashable, Codable, Sendable {
    var enabled = false
    /// How far past the cut line, in mm.
    var width = 1.0

    static let widths = 0.5...3.0
    /// Print resolution of the bands, and the canvas preview's (lighter).
    static let printPixelsPerMM = 300 / 25.4
    static let previewPixelsPerMM = 6.0

    /// The keys stored on disk are in Portuguese, like the rest of the .cutline format.
    enum CodingKeys: String, CodingKey {
        case enabled = "ligada", width = "largura"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        width = min(max(try c.decodeIfPresent(Double.self, forKey: .width) ?? 1, Self.widths.lowerBound), Self.widths.upperBound)
    }

    /// One band ready to draw: the colors (CMYK, which has no alpha) and where they go (gray mask, white = print), over
    /// `rect` in page mm; and its outer edge, the red guide the canvas shows (like Illustrator's bleed guide; never printed).
    nonisolated struct Piece: @unchecked Sendable {
        let rect: CGRect
        let image: CGImage
        let mask: CGImage
        let guide: CGPath
    }

    /// Draws the bands in a context in page mm with y down (before the art: they go under it).
    nonisolated static func draw(_ pieces: [Piece], in cg: CGContext) {
        for piece in pieces {
            cg.saveGState()
            // Images are drawn with y up: flip around the band's rectangle.
            cg.translateBy(x: piece.rect.minX, y: piece.rect.maxY)
            cg.scaleBy(x: 1, y: -1)
            let box = CGRect(origin: .zero, size: piece.rect.size)
            cg.clip(to: box, mask: piece.mask)
            cg.draw(piece.image, in: box)
            cg.restoreGState()
        }
    }

    /// The print's colors are CMYK with the document's profile (as the fills print); the canvas's are the colors the
    /// canvas draws with (`ColorConverter.screen`), so the band matches the art on screen too.
    enum Colors: Sendable {
        case print, screen
    }

    /// The bands of one artboard now, at once (the print).
    @MainActor static func pieces(for doc: Document, on artboard: Artboard, pixelsPerMM: Double, colors: Colors = .print) -> [Piece] {
        source(for: doc, on: artboard, pixelsPerMM: pixelsPerMM, colors: colors)?.pieces() ?? []
    }

    // MARK: Step 1 (main thread): the art and the masks

    /// What the bands are made from: the art drawn without the marks, in CMYK and as coverage, over the region the bands
    /// need, and each band's masks. nil when there is nothing to do (bleed or marks off, no closed line that cuts).
    @MainActor static func source(for doc: Document, on artboard: Artboard, pixelsPerMM ppm: Double, colors: Colors = .print) -> Source? {
        guard doc.marks, doc.bleed.enabled else { return nil }
        let reach = min(max(doc.bleed.width, widths.lowerBound), widths.upperBound)
        let marks = doc.marksConfig, sheet = artboard.rect, frame = doc.sheetFrame(artboard)
        // Only between the artboard's marks (the machine doesn't cut outside) and away from them (they confuse the sensor).
        let allowed = CGPath(rect: marks.area(on: frame), transform: nil).subtracting(marks.forbiddenZone(on: frame).cgPath, using: .evenOdd)
        var contours: [(closed: CGPath, band: CGPath)] = []
        for line in doc.cutLines(on: artboard) where doc.config(line.color).sends {
            for object in line.objects {
                // An open line has no side that stays: no bleed.
                let closed = closedSubpaths(object.shapePath.cgPath)
                guard !closed.isEmpty else { continue }
                let band = closed.copy(strokingWithWidth: 2 * reach, lineCap: .round, lineJoin: .round, miterLimit: 10)
                    .normalized(using: .winding)
                    .intersection(allowed, using: .evenOdd)
                guard !band.isEmpty, !band.boundingBoxOfPath.isNull else { continue }
                contours.append((closed, band))
            }
        }
        guard !contours.isEmpty else { return nil }
        let wanted = contours.reduce(CGRect.null) { $0.union($1.band.boundingBoxOfPath.insetBy(dx: -reach, dy: -reach)) }
            .intersection(sheet)
        guard !wanted.isNull else { return nil }
        let x0 = Int((wanted.minX * ppm).rounded(.down)), y0 = Int((wanted.minY * ppm).rounded(.down))
        let x1 = Int((wanted.maxX * ppm).rounded(.up)), y1 = Int((wanted.maxY * ppm).rounded(.up))
        let width = x1 - x0, height = y1 - y0
        guard width > 0, height > 0 else { return nil }
        let region = CGRect(x: Double(x0) / ppm, y: Double(y0) / ppm, width: Double(width) / ppm, height: Double(height) / ppm)

        // The art without the marks: as it prints (CMYK) or as the canvas shows it (RGBA), and how much ink each pixel has.
        // A transparent image inside a shape inks its pixels all the same (lighter): the coverage leaves its opacity out.
        let art = { (cg: CGContext) in
            cg.scaleBy(x: 1 / Printing.pointsPerMM, y: 1 / Printing.pointsPerMM)
            Printing.render(doc, in: cg, marks: false, screenColors: colors == .screen)
        }
        let opaqueArt = { (cg: CGContext) in
            cg.scaleBy(x: 1 / Printing.pointsPerMM, y: 1 / Printing.pointsPerMM)
            Printing.render(doc, in: cg, marks: false, screenColors: colors == .screen, opaqueImages: true)
        }
        let transparentImages = doc.objects.contains { ($0.imageFit?.opacity ?? 1) < 1 && doc.visible($0) }
        let color: [UInt8], coverage: [UInt8]
        let cmykSpace = doc.colors.cmykSpace
        switch colors {
        case .print:
            color = pixels(width, height, .cmyk(cmykSpace), rect: region, ppm: ppm, draw: art)
            coverage = pixels(width, height, .coverage, rect: region, ppm: ppm, draw: transparentImages ? opaqueArt : art)
        case .screen where transparentImages:
            // On white paper, as it prints (the transparent image lighter, not darker); the coverage apart.
            color = pixels(width, height, .rgba, rect: region, ppm: ppm) { cg in
                cg.setFillColor(CGColor(gray: 1, alpha: 1))
                cg.fill(region)
                art(cg)
            }
            coverage = pixels(width, height, .coverage, rect: region, ppm: ppm, draw: opaqueArt)
        case .screen:
            color = pixels(width, height, .rgba, rect: region, ppm: ppm, draw: art)
            coverage = stride(from: 3, to: color.count, by: 4).map { color[$0] }
        }

        var bands: [Source.Band] = []
        for (closed, band) in contours {
            let around = band.boundingBoxOfPath.insetBy(dx: -reach, dy: -reach)
            let bx0 = max(x0, Int((around.minX * ppm).rounded(.down))), by0 = max(y0, Int((around.minY * ppm).rounded(.down)))
            let bx1 = min(x1, Int((around.maxX * ppm).rounded(.up))), by1 = min(y1, Int((around.maxY * ppm).rounded(.up)))
            let w = bx1 - bx0, h = by1 - by0
            guard w > 0, h > 0 else { continue }
            let rect = CGRect(x: Double(bx0) / ppm, y: Double(by0) / ppm, width: Double(w) / ppm, height: Double(h) / ppm)
            let inside = pixels(w, h, .gray, rect: rect, ppm: ppm) { cg in
                cg.addPath(closed)
                cg.fillPath(using: .evenOdd)
            }
            let mask = pixels(w, h, .gray, rect: rect, ppm: ppm) { cg in
                cg.addPath(band)
                cg.fillPath(using: .winding)
            }
            // The outer edge: the line's inside grown by the band (into a hole too, which is waste).
            let guide = closed.normalized(using: .evenOdd).union(band, using: .winding)
            bands.append(Source.Band(rect: rect, x0: bx0 - x0, y0: by0 - y0, width: w, height: h, inside: inside, band: mask,
                                     guide: guide))
        }
        return Source(colors: colors, cmykSpace: cmykSpace, ppm: ppm, reach: reach, width: width, height: height, color: color,
                      coverage: coverage, bands: bands)
    }

    private enum Bitmap {
        /// 4 bytes per pixel, zero = white paper, in the document's CMYK profile.
        case cmyk(CGColorSpace)
        /// How much ink each pixel has (the alpha of a transparent RGBA bitmap), 1 byte per pixel.
        case coverage
        /// The art as the canvas shows it, on transparent: 4 bytes per pixel (premultiplied RGBA).
        case rgba
        /// Paths filled in white on black, 1 byte per pixel.
        case gray
    }

    /// Draws into a bitmap over `rect` (page mm, y down) and returns its bytes (row 0 = the top).
    @MainActor private static func pixels(_ w: Int, _ h: Int, _ kind: Bitmap, rect: CGRect, ppm: Double,
                                          draw: (CGContext) -> Void) -> [UInt8] {
        let gray = if case .gray = kind { true } else { false }
        var data = [UInt8](repeating: 0, count: w * h * (gray ? 1 : 4))
        data.withUnsafeMutableBytes { raw in
            let context: CGContext? = switch kind {
            case .cmyk(let space):
                CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                          space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue)
            case .coverage, .rgba:
                CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                          space: ColorConverter.screenSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            case .gray:
                CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            }
            guard let context else { return }
            context.translateBy(x: 0, y: CGFloat(h))
            context.scaleBy(x: ppm, y: -ppm)
            context.translateBy(x: -rect.minX, y: -rect.minY)
            if gray { context.setFillColor(gray: 1, alpha: 1) }
            draw(context)
        }
        if case .coverage = kind { return stride(from: 3, to: data.count, by: 4).map { data[$0] } }
        return data
    }

    /// The closed subpaths only.
    nonisolated static func closedSubpaths(_ path: CGPath) -> CGPath {
        let closed = CGMutablePath()
        var current = CGMutablePath()
        var open = false
        path.applyWithBlock { element in
            let p = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint:
                current = CGMutablePath()
                current.move(to: p[0])
                open = true
            case .addLineToPoint: if open { current.addLine(to: p[0]) }
            case .addQuadCurveToPoint: if open { current.addQuadCurve(to: p[1], control: p[0]) }
            case .addCurveToPoint: if open { current.addCurve(to: p[2], control1: p[0], control2: p[1]) }
            case .closeSubpath:
                if open {
                    current.closeSubpath()
                    closed.addPath(current)
                    open = false
                }
            @unknown default: break
            }
        }
        return closed
    }

    // MARK: Step 2 (any thread): the nearest color

    nonisolated struct Source: @unchecked Sendable {
        struct Band {
            /// Page mm, on the pixel grid.
            let rect: CGRect
            /// Where it starts in the region's pixels.
            let x0, y0: Int
            let width, height: Int
            /// Inside the cut line (even-odd), and the band itself (antialiased), one byte per pixel.
            let inside: [UInt8]
            let band: [UInt8]
            /// Outer edge of the band, page mm.
            let guide: CGPath
        }

        let colors: Colors
        let cmykSpace: CGColorSpace
        let ppm: Double
        let reach: Double
        let width, height: Int
        let color: [UInt8]
        let coverage: [UInt8]
        let bands: [Band]

        func pieces() -> [Piece] { bands.compactMap(piece) }

        /// A source pixel is fully inside the line and fully inked: an antialiased edge pixel is already mixed with
        /// the paper's white, and copying it gives the band light stripes (Studio's halo, on a small scale).
        static let solid: UInt8 = 250

        /// Every band pixel takes the color of the nearest source pixel (inside the line, fully inked).
        /// Nearest by real distance (two passes that carry each pixel's nearest source, 8 neighbors). Pixels with no
        /// source within reach (a line around nothing printed, or around white margin) stay unprinted.
        private func piece(_ band: Band) -> Piece? {
            let w = band.width, h = band.height, n = w * h
            let none = Int32.max
            var nx = [Int32](repeating: 0, count: n), ny = [Int32](repeating: 0, count: n)
            var distance = [Int32](repeating: none, count: n)
            var found = false
            for j in 0..<h {
                for i in 0..<w {
                    let k = j * w + i, g = (band.y0 + j) * width + band.x0 + i
                    if band.inside[k] >= Self.solid, coverage[g] >= Self.solid {
                        nx[k] = Int32(i)
                        ny[k] = Int32(j)
                        distance[k] = 0
                        found = true
                    }
                }
            }
            guard found else { return nil }
            nx.withUnsafeMutableBufferPointer { nx in
                ny.withUnsafeMutableBufferPointer { ny in
                    distance.withUnsafeMutableBufferPointer { d in
                        /// Pixel k (at i, j) takes neighbor q's source if it is nearer.
                        func relax(_ k: Int, _ i: Int, _ j: Int, _ q: Int) {
                            guard d[q] != none else { return }
                            let dx = Int32(i) - nx[q], dy = Int32(j) - ny[q]
                            let candidate = dx * dx + dy * dy
                            if candidate < d[k] {
                                d[k] = candidate
                                nx[k] = nx[q]
                                ny[k] = ny[q]
                            }
                        }
                        for j in 0..<h {
                            for i in 0..<w {
                                let k = j * w + i
                                if i > 0 { relax(k, i, j, k - 1) }
                                if j > 0 {
                                    relax(k, i, j, k - w)
                                    if i > 0 { relax(k, i, j, k - w - 1) }
                                    if i < w - 1 { relax(k, i, j, k - w + 1) }
                                }
                            }
                            for i in stride(from: w - 2, through: 0, by: -1) { relax(j * w + i, i, j, j * w + i + 1) }
                        }
                        for j in stride(from: h - 1, through: 0, by: -1) {
                            for i in stride(from: w - 1, through: 0, by: -1) {
                                let k = j * w + i
                                if i < w - 1 { relax(k, i, j, k + 1) }
                                if j < h - 1 {
                                    relax(k, i, j, k + w)
                                    if i < w - 1 { relax(k, i, j, k + w + 1) }
                                    if i > 0 { relax(k, i, j, k + w - 1) }
                                }
                            }
                            for i in stride(from: 1, to: w, by: 1) { relax(j * w + i, i, j, j * w + i - 1) }
                        }
                    }
                }
            }
            // A band pixel is at most `reach` from the line, and its source at most `reach` inside: 2 × reach.
            let limitPixels = 2 * reach * ppm + 2
            let limit = Int32(limitPixels * limitPixels)
            var cmyk = [UInt8](repeating: 0, count: n * 4)
            var mask = [UInt8](repeating: 0, count: n)
            var any = false
            for k in 0..<n where band.band[k] > 0 && distance[k] <= limit {
                let g = (band.y0 + Int(ny[k])) * width + band.x0 + Int(nx[k])
                for c in 0..<4 { cmyk[k * 4 + c] = color[g * 4 + c] }
                mask[k] = band.band[k]
                any = true
            }
            // Print: CMYK. Screen: RGB (the sources are fully inked, so premultiplied or not is the same).
            let space = colors == .print ? cmykSpace : ColorConverter.screenSpace
            let info = colors == .print ? CGImageAlphaInfo.none : CGImageAlphaInfo.noneSkipLast
            guard any,
                  let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGBitmapInfo(rawValue: info.rawValue),
                                      provider: CGDataProvider(data: Data(cmyk) as CFData)!, decode: nil,
                                      shouldInterpolate: true, intent: .defaultIntent),
                  let maskImage = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                          provider: CGDataProvider(data: Data(mask) as CFData)!, decode: nil,
                                          shouldInterpolate: true, intent: .defaultIntent)
            else { return nil }
            return Piece(rect: band.rect, image: image, mask: maskImage, guide: band.guide)
        }
    }
}

extension Document {
    /// Turns the bleed on or off, or changes its width (stays in the file; consecutive adjustments are one undo step).
    func setBleed(_ newOne: PrintBleed) {
        guard newOne != bleed else { return }
        registerAdjustment("sangria")
        bleed = newOne
    }
}

/// The canvas preview of the bleed: recomputed a moment after the document changes, off the main thread for the
/// heavy part; meanwhile the previous bands stay on screen.
@Observable
final class BleedPreview {
    private(set) var pieces: [PrintBleed.Piece] = []
    @ObservationIgnored private var key: Int?
    @ObservationIgnored private var work: Task<Void, Never>?

    func pieces(for doc: Document) -> [PrintBleed.Piece] {
        var hasher = Hasher()
        hasher.combine(doc.objects)
        hasher.combine(doc.cuts)
        for layer in doc.layers { hasher.combine(layer.id); hasher.combine(layer.visible) }
        hasher.combine(doc.marks)
        hasher.combine(doc.marksConfig)
        hasher.combine(doc.artboards.map(\.rect))
        hasher.combine(doc.bleed)
        hasher.combine(doc.images.count)
        // The colors: the document's CMYK profile and the app's RGB working space.
        hasher.combine(ObjectIdentifier(doc.colors))
        let updated = hasher.finalize()
        guard updated != key else { return pieces }
        key = updated
        work?.cancel()
        work = Task { [weak self, weak doc] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let doc else { return }
            // Each artboard with its own marks.
            let sources = doc.artboards.compactMap { PrintBleed.source(for: doc, on: $0, pixelsPerMM: PrintBleed.previewPixelsPerMM, colors: .screen) }
            guard !sources.isEmpty else {
                self?.pieces = []
                return
            }
            let made = await Task.detached(priority: .userInitiated) { sources.flatMap { $0.pieces() } }.value
            guard !Task.isCancelled else { return }
            self?.pieces = made
        }
        return pieces
    }
}

extension PrintBleed {
    /// What goes into a report from the "Report a Problem…" link: the setting, the marks, what gets a band and how long
    /// the bands take. The person sees it before sending.
    @MainActor static func reportContext(_ doc: Document) -> String {
        let marks = doc.marksConfig
        let cutting = doc.cutLines(on: doc.sendArtboard).filter { doc.config($0.color).sends }.flatMap(\.objects)
        let closed = cutting.filter { !closedSubpaths($0.shapePath.cgPath).isEmpty }.count
        let start = Date()
        let pieces = pieces(for: doc, on: doc.sendArtboard, pixelsPerMM: previewPixelsPerMM)
        let milliseconds = Int(Date().timeIntervalSince(start) * 1000)
        let visible = doc.objects.filter { doc.visible($0) }
        let fills = visible.filter { $0.fill != nil }.count
        let images = visible.filter { $0.image != nil }.count
        let strokes = visible.filter { $0.strokeWidth > 0 }.count
        let number = { (v: Double) in v.formatted(.number.precision(.fractionLength(0...3))) }
        return [
            "### " + String(localized: "Experimental: print bleed"),
            "- Bleed: \(doc.bleed.enabled ? "on" : "off"), \(number(doc.bleed.width)) mm · Print & Cut marks: \(doc.marks ? "on" : "off")",
            "- Marks: left \(number(marks.left)), top \(number(marks.top)), right \(number(marks.right)), bottom \(number(marks.bottom)) mm · corner marks \(number(marks.length)) mm",
            "- Artboard: \(number(doc.sendArtboard.size.width)) × \(number(doc.sendArtboard.size.height)) mm (\(doc.artboards.count) in the document)",
            "- Lines that cut: \(cutting.count) object(s), \(closed) closed · bands drawn: \(pieces.count)",
            "- Art: \(fills) filled, \(images) image(s), \(strokes) printed stroke(s), \(visible.count) visible object(s)",
            "- Bands computed in \(milliseconds) ms at \(Int(previewPixelsPerMM)) px/mm (the print uses 300 dpi)",
        ].joined(separator: "\n")
    }
}
