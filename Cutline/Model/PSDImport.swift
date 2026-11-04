// Photoshop files (.psd and .psb) for File › Import… and dropping: each visible layer becomes its own PNG, in its place
// on the Photoshop canvas (the window that asks what to do is Editor/LayeredImageWindow.swift). The layers are read from
// the file itself: RGB, grayscale or CMYK, 8 or 16 bits, raw, RLE or ZIP channels. The layer's opacity and its mask
// apply; blend modes, layer effects, clipping masks and adjustment layers don't (the pixels go as they are, as in
// Photoshop's Export Layers to Files). Hidden layers, and the ones inside hidden groups, stay out. A file without
// layers (flattened, or in a mode not read here) goes in as a single image, through ImageIO.
import Compression
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated struct PSDLayer: @unchecked Sendable {
    let name: String
    /// Where it sits on the Photoshop canvas, in pixels (origin at the top-left corner; cropped to the canvas).
    let rect: CGRect
    let image: CGImage
    /// The layer as a PNG: what goes into the document.
    let png: Data
}

nonisolated struct PSDFile: @unchecked Sendable {
    /// Canvas size, in pixels.
    let size: CGSize
    /// Pixels per inch (72 when the file doesn't say).
    let resolution: Double
    /// From the bottom one up; empty = nothing to import layer by layer.
    let layers: [PSDLayer]
}

nonisolated enum PSDImport {
    static func isPhotoshop(_ payload: Data) -> Bool { payload.starts(with: Array("8BPS".utf8)) }

    /// nil when the data isn't a Photoshop file (or is damaged).
    static func read(_ payload: Data) -> PSDFile? {
        guard isPhotoshop(payload) else { return nil }
        var reader = Reader(bytes: [UInt8](payload))
        return try? reader.file()
    }

    static func png(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

private nonisolated struct Damaged: Error {}

private nonisolated struct Box {
    var top, left, bottom, right: Int
    var width: Int { max(right - left, 0) }
    var height: Int { max(bottom - top, 0) }
}

/// A layer's header, before its pixels.
private nonisolated struct Record {
    var box: Box
    var channels: [(id: Int, length: Int)]
    var opacity: Int
    var hidden: Bool
    var name = ""
    /// 0 = a layer; 1 and 2 = a group (open, closed), which comes after its layers; 3 = where a group begins.
    var section = 0
    var mask: (box: Box, fill: UInt8, off: Bool)?
}

/// Reading position over the file's bytes (big-endian, as Photoshop writes them).
private nonisolated struct Reader {
    let bytes: [UInt8]
    var i = 0

    mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n >= 0, i + n <= bytes.count else { throw Damaged() }
        defer { i += n }
        return bytes[i..<(i + n)]
    }

    mutating func number(_ size: Int) throws -> Int { try take(size).reduce(0) { $0 << 8 | Int($1) } }
    mutating func u8() throws -> Int { try number(1) }
    mutating func u16() throws -> Int { try number(2) }
    mutating func u32() throws -> Int { try number(4) }
    mutating func i16() throws -> Int { Int(Int16(truncatingIfNeeded: try u16())) }
    mutating func i32() throws -> Int { Int(Int32(truncatingIfNeeded: try u32())) }
    /// Lengths take 8 bytes in the large format (.psb) where Photoshop's spec says so.
    mutating func length(_ long: Bool) throws -> Int { try number(long ? 8 : 4) }
    mutating func text(_ n: Int) throws -> String { String(decoding: try take(n), as: UTF8.self) }

    mutating func file() throws -> PSDFile {
        guard try text(4) == "8BPS" else { throw Damaged() }
        let version = try u16()
        guard version == 1 || version == 2 else { throw Damaged() }
        let large = version == 2
        _ = try take(6)
        _ = try u16()   // channels of the flattened image
        let height = try u32(), width = try u32()
        let depth = try u16(), mode = try u16()
        _ = try take(try u32())   // color mode data
        let (resolution, profile) = try resources()
        let size = CGSize(width: width, height: height)
        let flattened = PSDFile(size: size, resolution: resolution, layers: [])
        // Bitmap, indexed, Lab, multichannel or 32 bits: only the flattened image (ImageIO).
        guard [8, 16].contains(depth), [1, 3, 4].contains(mode), width > 0, height > 0 else { return flattened }
        guard try length(large) > 0, try length(large) > 0 else { return flattened }
        let count = abs(try i16())
        var records: [Record] = []
        for _ in 0..<count { records.append(try record(large)) }

        // Groups: going down from the top, a group comes before its layers and ends at the section that begins it.
        var skip = [Bool](repeating: false, count: records.count)
        var groups: [Bool] = []
        for k in records.indices.reversed() {
            let inHidden = groups.last ?? false
            switch records[k].section {
            case 1, 2: groups.append(inHidden || records[k].hidden); skip[k] = true
            case 3: _ = groups.popLast(); skip[k] = true
            default: skip[k] = inHidden || records[k].hidden
            }
        }

        let space = mode == 3 ? profile.flatMap { CGColorSpace(iccData: $0 as CFData) } ?? CGColorSpace(name: CGColorSpace.sRGB)!
            : CGColorSpace(name: CGColorSpace.sRGB)!
        var layers: [PSDLayer] = []
        // The pixels come after all the headers, layer by layer, each channel with its own compression.
        for (k, record) in records.enumerated() {
            var planes: [Int: [UInt8]] = [:]
            for channel in record.channels {
                let end = i + channel.length
                let box = channel.id == -2 ? record.mask?.box : record.box
                if !skip[k], let box, channel.id >= -2, channel.id <= 3 {
                    planes[channel.id] = try plane(width: box.width, height: box.height, length: channel.length, depth: depth, large: large)
                }
                i = end
            }
            guard !skip[k], let image = compose(record, planes, mode: mode, canvas: (width, height), space: space),
                  let png = PSDImport.png(image.image) else { continue }
            let name = record.name.isEmpty ? String(localized: "Layer \(layers.count + 1)") : record.name
            layers.append(PSDLayer(name: name, rect: image.rect, image: image.image, png: png))
        }
        return PSDFile(size: size, resolution: resolution, layers: layers)
    }

    /// Resolution (ResolutionInfo, 0x03ED) and the color profile (0x040F).
    mutating func resources() throws -> (Double, Data?) {
        let size = try u32()
        let end = i + size
        var resolution = 72.0, profile: Data?
        while i + 12 <= end, try text(4) == "8BIM" {
            let id = try u16()
            let nameLength = try u8()
            _ = try take(nameLength + (nameLength + 1) % 2)
            let length = try u32()
            let start = i
            if id == 0x03ED, length >= 4 {
                let ppi = Double(try u32()) / 65536
                if ppi > 0 { resolution = ppi }
            }
            if id == 0x040F { profile = Data(try take(length)) }
            i = start + length + length % 2
        }
        i = end
        return (resolution, profile)
    }

    mutating func record(_ large: Bool) throws -> Record {
        let box = Box(top: try i32(), left: try i32(), bottom: try i32(), right: try i32())
        var channels: [(id: Int, length: Int)] = []
        let channelCount = try u16()
        for _ in 0..<channelCount { channels.append((try i16(), try length(large))) }
        _ = try take(8)   // "8BIM" and the blend mode
        let opacity = try u8()
        _ = try u8()   // clipping
        let flags = try u8()
        _ = try u8()
        let extra = try u32()
        let extraEnd = i + extra
        var record = Record(box: box, channels: channels, opacity: opacity, hidden: flags & 2 != 0)
        let maskLength = try u32()
        let maskEnd = i + maskLength
        if maskLength >= 20 {
            let maskBox = Box(top: try i32(), left: try i32(), bottom: try i32(), right: try i32())
            let fill = try u8(), maskFlags = try u8()
            record.mask = (maskBox, UInt8(fill), maskFlags & 2 != 0)
        }
        i = maskEnd
        i += try u32()   // blending ranges
        let nameLength = try u8()
        record.name = String(bytes: try take(nameLength), encoding: .macOSRoman) ?? ""
        _ = try take(3 - nameLength % 4)   // Pascal string padded to 4 bytes
        // Tagged blocks: the Unicode name and the group sections.
        let longKeys: Set = ["LMsk", "Lr16", "Lr32", "Layr", "Mt16", "Mt32", "Mtrn", "Alph", "FMsk", "lnk2", "FEid", "FXid", "PxSD"]
        while i + 12 <= extraEnd {
            let signature = try text(4)
            // Some blocks are padded: slide a byte at a time until the next signature.
            guard signature == "8BIM" || signature == "8B64" else { i -= 3; continue }
            let key = try text(4)
            let size = try length(large && longKeys.contains(key))
            let start = i
            switch key {
            case "luni":
                let units = try take(min(try u32() * 2, max(size - 4, 0)))
                let code = stride(from: units.startIndex, to: units.endIndex - 1, by: 2).map { UInt16(units[$0]) << 8 | UInt16(units[$0 + 1]) }
                record.name = String(decoding: code, as: UTF16.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            case "lsct", "lsdk":
                if size >= 4 { record.section = try u32() }
            default: break
            }
            i = start + size
        }
        i = extraEnd
        return record
    }

    /// One channel, one byte per pixel (16 bits keep the high byte).
    mutating func plane(width: Int, height: Int, length: Int, depth: Int, large: Bool) throws -> [UInt8] {
        let compression = try u16()
        guard width > 0, height > 0 else { return [] }
        let sampleSize = depth / 8, rowBytes = width * sampleSize
        var samples: [UInt8]
        switch compression {
        case 0:
            samples = Array(try take(rowBytes * height))
        case 1:
            var counts: [Int] = []
            for _ in 0..<height { counts.append(large ? try u32() : try u16()) }
            samples = [UInt8](repeating: 0, count: rowBytes * height)
            for row in 0..<height { unpackBits(try take(counts[row]), into: &samples, at: row * rowBytes, count: rowBytes) }
        case 2, 3:
            samples = try inflate(take(length - 2), size: rowBytes * height)
            if compression == 3 { undoPrediction(&samples, width: width, height: height, sampleSize: sampleSize) }
        default:
            throw Damaged()
        }
        return sampleSize == 2 ? stride(from: 0, to: samples.count, by: 2).map { samples[$0] } : samples
    }

    /// The layer in RGBA, cropped to the canvas; nil if nothing in it shows.
    func compose(_ record: Record, _ planes: [Int: [UInt8]], mode: Int, canvas: (width: Int, height: Int),
                 space: CGColorSpace) -> (image: CGImage, rect: CGRect)? {
        let b = record.box
        let left = max(b.left, 0), top = max(b.top, 0), right = min(b.right, canvas.width), bottom = min(b.bottom, canvas.height)
        guard right > left, bottom > top else { return nil }
        let w = right - left, h = bottom - top, full = b.width * b.height
        let colors = (0..<(mode == 4 ? 4 : mode == 3 ? 3 : 1)).compactMap { planes[$0] }
        guard colors.count == (mode == 4 ? 4 : mode == 3 ? 3 : 1), colors.allSatisfy({ $0.count == full }) else { return nil }
        let alpha = planes[-1].flatMap { $0.count == full ? $0 : nil }
        let mask = record.mask.flatMap { mask in
            planes[-2].flatMap { !mask.off && $0.count == mask.box.width * mask.box.height ? (mask, $0) : nil }
        }
        // CMYK: Photoshop stores the ink inverted (255 = no ink); ColorSync turns it into RGB.
        let rgb = mode == 4 ? cmykToRGB(colors, width: b.width, height: b.height) : nil
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        var shows = false
        for y in 0..<h {
            for x in 0..<w {
                let s = (y + top - b.top) * b.width + (x + left - b.left), o = (y * w + x) * 4
                var a = (alpha.map { Int($0[s]) } ?? 255) * record.opacity / 255
                if let mask {
                    let box = mask.0.box, mx = x + left - box.left, my = y + top - box.top
                    let inside = mx >= 0 && my >= 0 && mx < box.width && my < box.height
                    a = a * Int(inside ? mask.1[my * box.width + mx] : mask.0.fill) / 255
                }
                guard a > 0 else { continue }
                shows = true
                switch mode {
                case 1: (rgba[o], rgba[o + 1], rgba[o + 2]) = (colors[0][s], colors[0][s], colors[0][s])
                case 3: (rgba[o], rgba[o + 1], rgba[o + 2]) = (colors[0][s], colors[1][s], colors[2][s])
                default:
                    guard let rgb else { return nil }
                    (rgba[o], rgba[o + 1], rgba[o + 2]) = (rgb[s * 4], rgb[s * 4 + 1], rgb[s * 4 + 2])
                }
                rgba[o + 3] = UInt8(a)
            }
        }
        guard shows, let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                                  decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return (image, CGRect(x: left, y: top, width: w, height: h))
    }
}

private nonisolated func cmykToRGB(_ channels: [[UInt8]], width: Int, height: Int) -> [UInt8]? {
    var cmyk = [UInt8](repeating: 0, count: width * height * 4)
    for p in 0..<(width * height) {
        for c in 0..<4 { cmyk[p * 4 + c] = 255 - channels[c][p] }
    }
    var rgb = [UInt8](repeating: 0, count: width * height * 4)
    guard let space = CGColorSpace(name: CGColorSpace.genericCMYK), let provider = CGDataProvider(data: Data(cmyk) as CFData),
          let source = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                               shouldInterpolate: false, intent: .defaultIntent)
    else { return nil }
    let drawn = rgb.withUnsafeMutableBytes { bytes -> Bool in
        guard let ctx = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return false }
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    return drawn ? rgb : nil
}

/// PackBits (RLE), one row.
private nonisolated func unpackBits(_ input: ArraySlice<UInt8>, into output: inout [UInt8], at start: Int, count: Int) {
    var o = start, k = input.startIndex
    let end = start + count
    while k < input.endIndex, o < end {
        let n = Int(Int8(bitPattern: input[k]))
        k += 1
        if n >= 0 {
            let c = min(n + 1, input.endIndex - k, end - o)
            for j in 0..<c { output[o + j] = input[k + j] }
            o += c
            k += n + 1
        } else if n != -128, k < input.endIndex {
            let c = min(1 - n, end - o), value = input[k]
            for j in 0..<c { output[o + j] = value }
            o += c
            k += 1
        }
    }
}

/// ZIP channels: a zlib stream (the 2-byte header, then deflate).
private nonisolated func inflate(_ input: ArraySlice<UInt8>, size: Int) throws -> [UInt8] {
    let raw = Array(input.dropFirst(2))
    guard !raw.isEmpty, size > 0 else { throw Damaged() }
    var output = [UInt8](repeating: 0, count: size)
    let n = raw.withUnsafeBufferPointer { source in
        output.withUnsafeMutableBufferPointer { destination in
            compression_decode_buffer(destination.baseAddress!, size, source.baseAddress!, source.count, nil, COMPRESSION_ZLIB)
        }
    }
    guard n == size else { throw Damaged() }
    return output
}

/// ZIP with prediction: each sample is stored as the difference to the one on its left.
private nonisolated func undoPrediction(_ s: inout [UInt8], width: Int, height: Int, sampleSize: Int) {
    for row in 0..<height {
        let base = row * width * sampleSize
        if sampleSize == 1 {
            for x in 1..<max(width, 1) { s[base + x] &+= s[base + x - 1] }
        } else {
            var previous = UInt16(s[base]) << 8 | UInt16(s[base + 1])
            for x in 1..<max(width, 1) {
                let p = base + 2 * x
                previous &+= UInt16(s[p]) << 8 | UInt16(s[p + 1])
                (s[p], s[p + 1]) = (UInt8(previous >> 8), UInt8(previous & 0xFF))
            }
        }
    }
}
