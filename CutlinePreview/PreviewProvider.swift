// Quick Look in the Finder (space bar) for .cutline and .studio3 files: everything in the file as Cutline draws it,
// the sheet and the objects off it, as a PDF, so it stays sharp when zoomed. The extension runs in its own sandboxed
// process and compiles the app's drawing (PagePreview.swift, Printing.swift and the model files it needs: see the
// CutlinePreview exceptions in the project).
import QuickLookUI
import UniformTypeIdentifiers

/// Quick Look creates and calls it off the main thread; the drawing (the app's) runs on the main one.
nonisolated final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        guard let preview = await MainActor.run(body: { PagePreview.pdf(of: url) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let pdf = preview.data
        return QLPreviewReply(dataOfContentType: .pdf, contentSize: preview.size) { _ in pdf }
    }
}
