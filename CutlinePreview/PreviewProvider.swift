// Quick Look in the Finder (space bar) for .cutline and .studio3 files: the page as Cutline draws it, as a PDF, so it
// stays sharp when zoomed. The extension runs in its own sandboxed process and compiles the app's drawing
// (PagePreview.swift, Printing.swift and the model files it needs: see the CutlinePreview exceptions in the project).
import QuickLookUI
import UniformTypeIdentifiers

/// Quick Look creates and calls it off the main thread; the drawing (the app's) runs on the main one.
nonisolated final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let preview = await MainActor.run {
            PagePreview.pdf(of: url).map { ($0, CGSize(width: Document.page.width * Printing.pointsPerMM,
                                                      height: Document.page.height * Printing.pointsPerMM)) }
        }
        guard let (pdf, page) = preview else { throw CocoaError(.fileReadCorruptFile) }
        return QLPreviewReply(dataOfContentType: .pdf, contentSize: page) { _ in pdf }
    }
}
