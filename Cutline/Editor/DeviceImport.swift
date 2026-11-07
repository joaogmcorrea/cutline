// Import from iPhone or iPad (Continuity Camera), in the File menu after Import… and Merge… and in the canvas's right-click
// menu, as in Apple's apps. AppKit does the menus: it names the item and fills it with the nearby devices (Take Photo, Scan
// Documents, Add Sketch); with none, it's AppKit that turns it off or leaves it out. Cutline only says it takes images
// and PDF. A photo or a sketch then goes in as an imported PNG, with the question (just the image, the outer contour or
// with the inner ones); a scanned document comes as a PDF and goes through the PDF import. Both land centered on what the
// window shows, like Paste, at a size that fits the active artboard.
//
// Who takes the data: AppKit enables the item only when `validRequestor(forSendType:returnType:)`, asked from the key
// window's first responder, finds someone. In a SwiftUI window an AppKit responder can't answer it: the window passes the
// question to the app (never to its next responder, where `EditResponder` sits), and SwiftUI's hosting view and app
// delegate answer only from the focused value that `importsItemProviders` publishes. That modifier publishes it for the
// whole window (as a scene value, like the menus' `focusedSceneValue`), so the item works whatever has the keyboard; then
// SwiftUI's requestor gets the photo or scan from AppKit (`readSelection(fromItems:)`) as item providers.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum DeviceImport {
    /// What the window takes: images (photos and sketches) and PDF (scanned documents).
    static let contentTypes: [UTType] = [.image, .pdf]

    /// What arrived: a photo or sketch, or a scanned document.
    enum Kind { case image, pdf }

    // MARK: Menu

    /// SwiftUI's commands have no way to give an item this identifier (`ImportFromDevicesCommands` puts it after Save
    /// Selection…, away from Import…), so the item is AppKit's, put in by hand. AppKit fills it only if it's in the menu
    /// bar while the app finishes launching (`NSApplication._customizeImportFromDeviceMenuItem`, once), and then puts
    /// the document's Share item right after it, as in Apple's apps (`_customizeFileMenuIfNeeded`).
    private static let menuItem: NSMenuItem = {
        // AppKit names it ("Import from iPhone or iPad", in the Mac's language) and gives it the submenu.
        let item = NSMenuItem(title: String(localized: "Import from iPhone or iPad"), action: nil, keyEquivalent: "")
        item.identifier = NSMenuItem.importFromDeviceIdentifier
        return item
    }()
    private static var observer: NSObjectProtocol?

    /// `applicationWillFinishLaunching`: in the File menu, for AppKit to take it as the Continuity Camera item. And each
    /// time the menu bar opens it's checked to be there (should SwiftUI redo the File menu without it).
    static func installMenuItem() {
        placeMenuItem()
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil,
                                                          queue: .main) { note in
            // The menu bar's tracking (not a right-click menu's or a pop-up button's).
            let menu = (note.object as? NSMenu).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                if menu != nil, menu == NSApp.mainMenu.map(ObjectIdentifier.init) { placeMenuItem() }
            }
        }
    }

    /// Right after Import… and Merge… (Import…'s group, up to the separator) in the File menu (the one with Open…).
    static func placeMenuItem() {
        guard let file = NSApp.mainMenu?.items.lazy.compactMap(\.submenu)
                .first(where: { $0.items.contains { $0.action == #selector(NSDocumentController.openDocument(_:)) } })
        else { return }
        let isImport = { (item: NSMenuItem) in
            item.keyEquivalent == "i"
                && item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == [.command, .shift]
        }
        let others = file.items.filter { $0 !== menuItem }
        guard let importIndex = others.firstIndex(where: isImport) else { return }
        var place = importIndex + 1
        while place < others.count, !others[place].isSeparatorItem, others[place].submenu == nil { place += 1 }
        if place < file.items.count, file.items[place] === menuItem { return }
        menuItem.menu?.removeItem(menuItem)
        file.insertItem(menuItem, at: place)
    }

    // MARK: Receiving

    /// The PDF first (Scan Documents gives one when the app takes PDF); then an image, a compact format first (JPEG,
    /// HEIC, PNG) over the others (TIFF). The provider and the type to load.
    static func choose(_ providers: [NSItemProvider]) -> (provider: NSItemProvider, type: UTType, kind: Kind)? {
        let offers = providers.flatMap { provider in
            provider.registeredTypeIdentifiers.compactMap(UTType.init).map { (provider: provider, type: $0) }
        }
        if let pdf = offers.first(where: { $0.type.conforms(to: .pdf) }) { return (pdf.provider, pdf.type, .pdf) }
        let images = offers.filter { $0.type.conforms(to: .image) }
        let compact = images.filter { offer in [UTType.jpeg, .heic, .heif, .png].contains { offer.type.conforms(to: $0) } }
        guard let image = compact.first ?? images.first else { return nil }
        return (image.provider, image.type, .image)
    }

    /// The chosen representation's data.
    static func load(_ provider: NSItemProvider, _ type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in continuation.resume(returning: data) }
        }
    }

    // MARK: Bringing in

    /// The picture upright, ready for the document, as File › Import… keeps an image (Model/ImageLinks.swift): the photo
    /// the iPhone wrote sideways turned upright and saved again; and a TIFF saved as PNG.
    nonisolated static func picture(_ data: Data) -> (payload: Data, image: CGImage)? {
        LinkedFile.picture(data, compact: true)
    }

    /// The objects of a scanned page centered on `center` (or on the artboard) and, when bigger, shrunk to fit the
    /// artboard with the margin of an imported image.
    static func fitted(_ objects: [CanvasObject], in sheet: CGRect, center: CGPoint?) -> [CanvasObject] {
        guard let first = objects.first else { return objects }
        let box = objects.dropFirst().reduce(first.frame.standardized) { $0.union($1.frame.standardized) }
        let margin = ImageToTrace.margin
        let room = CGSize(width: max(sheet.width - 2 * margin, 10), height: max(sheet.height - 2 * margin, 10))
        let scale = min(1, room.width / max(box.width, 0.1), room.height / max(box.height, 0.1))
        let middle = center ?? CGPoint(x: sheet.midX, y: sheet.midY)
        let size = CGSize(width: box.width * scale, height: box.height * scale)
        let target = CGRect(x: middle.x - size.width / 2, y: middle.y - size.height / 2, width: size.width, height: size.height)
        return objects.map { object in
            var moved = object
            moved.frame = Document.stretch(object.frame.standardized, of: box, to: target)
            return moved
        }
    }
}

/// The window's side (MainWindow): says the window takes images and PDF, and brings in what arrives, with the image
/// question or straight onto the canvas for a scanned page.
struct DeviceImportReceiver: ViewModifier {
    let doc: Document
    @Binding var tracing: ImageToTrace?
    @Binding var manyPaths: ManyPaths?

    func body(content: Content) -> some View {
        content
            .importsItemProviders(DeviceImport.contentTypes) { providers in receive(providers) }
            #if DEBUG
            .onAppear { DebugHooks.deviceImportHandler[ObjectIdentifier(doc)] = { receive($0) } }
            #endif
    }

    /// AppKit's answer: true when something here can be read (the rest happens a moment later, once the data loads).
    private func receive(_ providers: [NSItemProvider]) -> Bool {
        guard let choice = DeviceImport.choose(providers) else { return false }
        // The image question or the many-paths one is still open: what arrives would have nowhere to go.
        if tracing != nil || manyPaths != nil {
            doc.notice = String(localized: "Close the open window, then import from the iPhone or iPad again.")
            return false
        }
        doc.finishText()
        Task {
            guard let data = await DeviceImport.load(choice.provider, choice.type) else {
                doc.notice = String(localized: "What arrived from the iPhone or iPad couldn’t be read.")
                return
            }
            switch choice.kind {
            case .pdf: bringScan(data)
            case .image: await bringPicture(data)
            }
        }
        return true
    }

    /// As an imported image: the question first (just the image, the outer contour or with the inner ones).
    private func bringPicture(_ data: Data) async {
        guard let picture = await Task.detached(operation: { DeviceImport.picture(data) }).value else {
            doc.notice = String(localized: "The image couldn’t be opened.")
            return
        }
        var image = ImageToTrace(name: String(localized: "Image"), payload: picture.payload, image: picture.image)
        image.ask = true
        image.center = doc.visibleCenter
        image.sheet = doc.activeArtboard.rect
        tracing = image
        #if DEBUG
        DebugHooks.deviceImportOpened(image)
        #endif
    }

    /// The 1st page, through the PDF import (a scan's pages are images; its recognized text is invisible and stays out).
    private func bringScan(_ data: Data) {
        let name = String(localized: "Scanned document")
        let result: VectorImport
        do { result = try VectorImporter.read(data, colors: doc.colors, sheet: doc.activeArtboard.rect) } catch {
            doc.notice = error.localizedDescription
            return
        }
        if result.objects.count > ManyPaths.threshold {
            manyPaths = ManyPaths(name: name, result: result)
            return
        }
        let objects = DeviceImport.fitted(result.objects, in: doc.activeArtboard.rect, center: doc.visibleCenter)
        doc.insertImported(objects, images: result.imageData)
        var notice = result.notice(from: name)
        let pages = CGDataProvider(data: data as CFData).flatMap { CGPDFDocument($0) }?.numberOfPages ?? 1
        if pages > 1 { notice += " " + String(localized: "Only the first of the \(pages) pages came in: scan one page at a time.") }
        doc.notice = notice
        #if DEBUG
        DebugHooks.deviceImportInserted(doc, objects)
        #endif
    }
}
