// The Finder's icon for .cutline and .studio3 files (icon and gallery views, Open dialogs): the page as Cutline draws
// it, the same as the start screen's recent files. Like CutlinePreview, it runs sandboxed and compiles the app's
// drawing (PagePreview.swift and the model files it needs: see the CutlineThumbnail exceptions in the project).
import QuickLookThumbnailing

/// Quick Look creates and calls it off the main thread; the drawing (the app's) runs on the main one.
nonisolated final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let box = request.maximumSize, url = request.fileURL, scale = request.scale
        // Quick Look takes the answer later, from any thread.
        nonisolated(unsafe) let handler = handler
        Task {
            // The sheet (the 1st artboard) as large as the requested box allows.
            let drawn = await MainActor.run { () -> (CGImage, CGSize)? in
                guard let sheet = PagePreview.file(at: url)?.sheet, sheet.width > 0, sheet.height > 0 else { return nil }
                let fit = min(box.width / sheet.width, box.height / sheet.height)
                let size = CGSize(width: (sheet.width * fit).rounded(), height: (sheet.height * fit).rounded())
                return PagePreview.image(of: url, width: Int(size.width * scale)).map { ($0, size) }
            }
            guard let (image, size) = drawn else {
                return handler(nil, CocoaError(.fileReadCorruptFile))
            }
            nonisolated(unsafe) let picture = image
            handler(QLThumbnailReply(contextSize: size) { context in
                // The context may already be scaled to the screen: its clip box is the whole thumbnail in its own units.
                context.draw(picture, in: context.boundingBoxOfClipPath)
                return true
            }, nil)
        }
    }
}
