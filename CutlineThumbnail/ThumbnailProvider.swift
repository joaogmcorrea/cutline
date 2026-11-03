// The Finder's icon for .cutline and .studio3 files (icon and gallery views, Open dialogs): the page as Cutline draws
// it, the same as the start screen's recent files. Like CutlinePreview, it runs sandboxed and compiles the app's
// drawing (PagePreview.swift and the model files it needs: see the CutlineThumbnail exceptions in the project).
import QuickLookThumbnailing

/// Quick Look creates and calls it off the main thread; the drawing (the app's) runs on the main one.
nonisolated final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        // The A4 page as large as the requested box allows.
        let box = request.maximumSize, page = CGSize(width: 210, height: 297)
        let fit = min(box.width / page.width, box.height / page.height)
        let size = CGSize(width: (page.width * fit).rounded(), height: (page.height * fit).rounded())
        let url = request.fileURL, pixels = Int(size.width * request.scale)
        // Quick Look takes the answer later, from any thread.
        nonisolated(unsafe) let handler = handler
        Task {
            guard let image = await MainActor.run(body: { PagePreview.image(of: url, width: pixels) }) else {
                return handler(nil, CocoaError(.fileReadCorruptFile))
            }
            handler(QLThumbnailReply(contextSize: size) { context in
                // The context may already be scaled to the screen: its clip box is the whole thumbnail in its own units.
                context.draw(image, in: context.boundingBoxOfClipPath)
                return true
            }, nil)
        }
    }
}
