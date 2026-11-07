// Linked images, as in Illustrator (File › Import… with Link): the image file stays where it is and the document keeps
// the link (Model/Document.swift, `ImageLink`). Here: making a link, finding the file again (bookmark, absolute path,
// path relative to the document), noticing when it changes, and Update, Relink and Embed (the Links panel,
// Editor/LinksPanel.swift). Update and Relink give the image a new key, so undo brings the previous one back as it was.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reading an image file the way Import does.
nonisolated enum LinkedFile {
    /// The data and the image of a file, as Import stores them (`picture`).
    static func read(_ url: URL) -> (payload: Data, image: CGImage)? {
        guard let payload = try? Data(contentsOf: url) else { return nil }
        return picture(payload)
    }

    /// An image's data and image as the document keeps them (File › Import…, dropped on the window, linked, from an iPhone
    /// or iPad: Editor/DeviceImport.swift). A flattened Photoshop file as a PNG. A photo whose file says to turn it (EXIF
    /// orientation: the iPhone and most cameras write the pixels sideways and the turn apart) turned upright and saved again,
    /// as JPEG for a photo (JPEG, HEIC) and PNG for the rest (it keeps the transparency); the document draws the pixels as
    /// they are, so it never reads the turn. Anything else as it came. `compact`: a format other than JPEG, HEIC or PNG
    /// (TIFF…) is saved again too, as PNG.
    static func picture(_ payload: Data, compact: Bool = false) -> (payload: Data, image: CGImage)? {
        guard let source = CGImageSourceCreateWithData(payload as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        if PSDImport.isPhotoshop(payload) {
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return (PSDImport.png(image) ?? payload, image)
        }
        let type = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let side = max((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0,
                       (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0)
        let photo = [UTType.jpeg, .heif, .heic].contains { type?.conforms(to: $0) == true }
        let small = photo || type?.conforms(to: .png) == true
        if orientation == 1 || side == 0, small || !compact, let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return (payload, image)
        }
        let image: CGImage?
        if side > 0 {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: side,
                                            kCGImageSourceShouldCacheImmediately: true]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let image else { return nil }
        let format = photo ? UTType.jpeg : .png
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, format.identifier as CFString, 1, nil) else { return nil }
        let quality: [CFString: Any] = photo ? [kCGImageDestinationLossyCompressionQuality: 0.92] : [:]
        CGImageDestinationAddImage(destination, image, quality as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, image)
    }

    /// The file's modification date and size (what tells a changed file).
    static func stamp(_ url: URL) -> (modified: Date?, size: Int?)? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        return (values.contentModificationDate, values.fileSize)
    }

    /// A small PNG of the image (at most `ImageLink.previewSide` on the long side).
    static func preview(_ image: CGImage) -> Data? {
        let side = Double(ImageLink.previewSide)
        let scale = min(1, side / Double(max(image.width, image.height, 1)))
        let width = max(1, Int((Double(image.width) * scale).rounded())), height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = ctx.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, small, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

nonisolated extension ImageLink {
    /// A link to the file as it is now.
    static func make(_ url: URL, image: CGImage, documentURL: URL?) -> ImageLink {
        let stamp = LinkedFile.stamp(url)
        let link = ImageLink(path: url.standardizedFileURL.path, relativePath: nil,
                             bookmark: try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
                             preview: LinkedFile.preview(image), pixelWidth: image.width, pixelHeight: image.height,
                             modified: stamp?.modified, fileSize: stamp?.size)
        return link.relative(to: documentURL)
    }

    /// Where the file is now: the bookmark (it follows a moved or renamed file), the absolute path, or the path relative to
    /// the document (the document and its images moved together, or came from another Mac). nil = missing.
    func resolve(documentURL: URL?) -> URL? {
        var candidates: [URL] = []
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil,
                                  bookmarkDataIsStale: &stale) { candidates.append(url) }
        }
        candidates.append(URL(fileURLWithPath: path))
        if let relativePath, let documentURL {
            candidates.append(documentURL.deletingLastPathComponent().appending(path: relativePath).standardizedFileURL)
        }
        return candidates.first { LinkedFile.stamp($0) != nil }
    }

    /// The file is as it was last read.
    func matches(_ stamp: (modified: Date?, size: Int?)) -> Bool {
        stamp.size == fileSize && (stamp.modified == nil || modified == nil || abs(stamp.modified!.timeIntervalSince(modified!)) < 0.001)
    }
}

extension Document {
    /// The image keys the objects use, in the objects' order.
    var imageKeysInUse: [String] {
        var seen = Set<String>()
        return objects.compactMap(\.image?.key).filter { seen.insert($0).inserted }
    }

    /// Looks at each linked file (the window does it every 2 s and when the document opens): found as it was read → its
    /// image is loaded (once) and it is OK; missing → its preview shows; changed on disk → it keeps showing what it had and
    /// asks once (Update / Not Now) for each change.
    func checkLinks() {
        var newlyMissing: [String] = []
        defer {
            // The window's notice, once per image that goes missing (as Illustrator's missing-links warning).
            if !newlyMissing.isEmpty {
                notice = newlyMissing.count == 1
                    ? String(localized: "The linked image “\(imageName(newlyMissing[0]))” is missing: a small preview shows in its place. Relink it in the Links panel.")
                    : String(localized: "\(newlyMissing.count) linked images are missing: a small preview shows in their place. Relink them in the Links panel.")
            }
        }
        for key in imageKeysInUse {
            guard let link = links[key] else { continue }
            guard let url = link.resolve(documentURL: documentURL), let stamp = LinkedFile.stamp(url) else {
                if linkStates[key] != .missing {
                    linkStates[key] = .missing
                    newlyMissing.append(key)
                }
                continue
            }
            if link.matches(stamp) {
                if images[key] == nil, let read = LinkedFile.read(url) {
                    images[key] = read.payload
                    forgetDecodedImage(key)
                }
                if linkStates[key] != .ok { linkStates[key] = .ok }
                // Found somewhere else (moved, or another Mac): the link follows it.
                if url.standardizedFileURL.path != link.path { links[key]?.path = url.standardizedFileURL.path }
            } else if linkStates[key] != .modified {
                linkStates[key] = .modified
                if !linksToAsk.contains(key) { linksToAsk.append(key) }
            }
        }
    }

    /// Update: reads the changed files again (one undo step). Each gets a new key, so undo shows what was there before.
    func updateLinks(_ keys: [String]) {
        var changes: [(String, URL)] = []
        for key in keys {
            guard let link = links[key], let url = link.resolve(documentURL: documentURL) else { continue }
            changes.append((key, url))
        }
        guard !changes.isEmpty else { return }
        registrar()
        for (key, url) in changes { replaceImage(key, with: url) }
        linksToAsk.removeAll { keys.contains($0) }
    }

    /// Relink…: the image now comes from another file (an embedded one becomes linked), in the same place: an image of
    /// another size is fitted proportionally into the same box, as Illustrator does. One undo step. false if the file isn't an image.
    @discardableResult func relink(_ key: String, to url: URL) -> Bool {
        guard LinkedFile.read(url) != nil else { return false }
        registrar()
        replaceImage(key, with: url)
        return true
    }

    /// Embed: the image goes into the document (it no longer depends on the file). Only with the image read.
    func embed(_ keys: [String]) {
        let ready = keys.filter { links[$0] != nil && images[$0] != nil }
        guard !ready.isEmpty else { return }
        registrar()
        for key in ready {
            links[key] = nil
            linkStates[key] = nil
        }
        linksToAsk.removeAll { ready.contains($0) }
    }

    /// The objects with image `key` take the file at `url` under a new key, fitted into the same pixels box.
    private func replaceImage(_ key: String, with url: URL) {
        guard let read = LinkedFile.read(url) else { return }
        let newKey = UUID().uuidString
        let old: CGSize = links[key].map { CGSize(width: $0.pixelWidth, height: $0.pixelHeight) }
            ?? image(key).map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: read.image.width, height: read.image.height)
        // Fitted proportionally into the old image's box, centered (an image of the same size lands exactly on it).
        let w = Double(max(read.image.width, 1)), h = Double(max(read.image.height, 1))
        let scale = min(old.width / w, old.height / h)
        let fit = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: (old.width - w * scale) / 2, ty: (old.height - h * scale) / 2)
        images[newKey] = read.payload
        links[newKey] = ImageLink.make(url, image: read.image, documentURL: documentURL)
        linkStates[newKey] = .ok
        for i in objects.indices {
            guard var placed = objects[i].image, placed.key == key else { continue }
            placed.key = newKey
            placed.transform = Transform(fit.concatenating(placed.transform.cg))
            objects[i].image = placed
            // An image inside a shape: the new one takes the shape the same way (Fill covers it with the new proportions).
            if var fitting = objects[i].imageFit {
                fitting.pixelWidth = w
                fitting.pixelHeight = h
                objects[i].imageFit = fitting
            }
        }
        linkStates[key] = nil
    }
}
