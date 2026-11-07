// Links panel, like Illustrator's: every image in the document, linked or embedded, with its state (OK, missing,
// changed on disk), and Relink…, Go to Link, Update and Embed. Also the window's watcher of the linked files (checks them
// every 2 s and asks to update a changed one) and File › Import…'s panel with the Link option. The model is in
// Model/ImageLinks.swift.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension Document {
    /// Go to Link: selects the objects with that image.
    func selectImage(_ key: String) {
        if textEditing != nil { finishText() }
        selection = Set(objects.filter { $0.image?.key == key && !untouchable($0) }.map(\.id))
    }

    /// The name shown for an image: the linked file's, or the object's.
    func imageName(_ key: String) -> String {
        links[key]?.fileName ?? objects.first { $0.image?.key == key }?.name ?? String(localized: "Image")
    }
}

struct LinksSection: View {
    @Bindable var doc: Document
    @State private var chosen: String?

    var body: some View {
        let keys = doc.imageKeysInUse
        VStack(alignment: .leading, spacing: 8) {
            if keys.isEmpty {
                Text("No images in the document. File › Import… with Link places an image without copying it into the document.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 2) {
                    ForEach(keys.prefix(200), id: \.self) { key in
                        LinkRow(doc: doc, key: key, chosen: chosen == key)
                            .onTapGesture { chosen = key }
                            .simultaneousGesture(TapGesture(count: 2).onEnded { doc.selectImage(key) })
                    }
                }
                .padding(.horizontal, -8)
                let key = chosen.flatMap { keys.contains($0) ? $0 : nil } ?? keys[0]
                details(key)
            }
        }
    }

    private func details(_ key: String) -> some View {
        let link = doc.links[key]
        return VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text(link?.path ?? String(localized: "Embedded in the document"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if let link {
                Text("\(link.pixelWidth) × \(link.pixelHeight) pixels")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Button("Relink…") { relink(key) }
                    .help("Link this image to another file (an embedded one becomes linked)")
                Button("Go to Link") { doc.selectImage(key) }
                    .help("Select the objects with this image")
            }
            HStack(spacing: 6) {
                Button("Update") { doc.updateLinks([key]) }
                    .disabled(doc.linkStates[key] != .modified)
                    .help("Read the changed file again")
                Button("Embed") { doc.embed([key]) }
                    .disabled(link == nil || doc.images[key] == nil)
                    .help("Keep the image inside the document (it no longer depends on the file)")
            }
        }
        .controlSize(.small)
    }

    private func relink(_ key: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose the image file for “\(doc.imageName(key))”.")
        panel.prompt = String(localized: "Relink")
        if let path = doc.links[key]?.path { panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent() }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !doc.relink(key, to: url) { doc.notice = String(localized: "“\(url.lastPathComponent)” couldn’t be opened.") }
    }
}

/// One image: thumbnail, name and state.
private struct LinkRow: View {
    let doc: Document
    let key: String
    let chosen: Bool

    var body: some View {
        let link = doc.links[key]
        HStack(spacing: 8) {
            Group {
                if let image = doc.image(key) {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Color.gray.opacity(0.3)
                }
            }
            .frame(width: 26, height: 26)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(doc.imageName(key))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            state(link)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(chosen ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }

    private func state(_ link: ImageLink?) -> some View {
        let (icon, tip, color): (ImageResource, LocalizedStringKey, Color) = switch (link, doc.linkStates[key]) {
        case (nil, _): (.linkEmbedded, "Embedded", .secondary)
        case (_, .missing?): (.linkMissing, "Missing: the file isn’t where it was (a small preview shows)", .red)
        case (_, .modified?): (.linkModified, "Changed on disk: Update reads it again", .orange)
        default: (.panelLinks, "Linked", .secondary)
        }
        return Image(icon).resizable().frame(width: 14, height: 14).foregroundStyle(color).help(tip)
    }
}

/// Watches the document's linked files: every 2 s (and right when the window opens) it checks them, and when one changed
/// on disk it asks, as Illustrator does, whether to update it.
struct LinkWatcher: ViewModifier {
    let doc: Document
    @State private var nsWindow = WeakWindow()

    func body(content: Content) -> some View {
        content
            .background(WindowReader { nsWindow.nsWindow = $0 })
            .task {
                while !Task.isCancelled {
                    if !doc.links.isEmpty {
                        doc.documentURL = (nsWindow.nsWindow?.windowController?.document as? NSDocument)?.fileURL
                        doc.checkLinks()
                        #if DEBUG
                        DebugHooks.answerLinksForTest(doc)
                        #endif
                    }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            .alert(question, isPresented: Binding(get: { !doc.linksToAsk.isEmpty }, set: { if !$0 { doc.linksToAsk = [] } })) {
                Button("Update") { doc.updateLinks(doc.linksToAsk) }
                Button("Not Now", role: .cancel) { doc.linksToAsk = [] }
            } message: {
                Text("The file changed outside Cutline. Update the document with it? (The Links panel can do it later.)")
            }
    }

    private var question: String {
        let keys = doc.linksToAsk
        return keys.count == 1 ? String(localized: "“\(doc.imageName(keys[0]))” changed on disk.")
            : String(localized: "\(keys.count) linked images changed on disk.")
    }
}

/// File › Import…: the open panel with Link, as Illustrator's Place (the choice is remembered). Linked, an image stays
/// where it is and the document keeps where it is; PDF, AI, SVG and EPS always come in as paths.
enum ImportPanel {
    static let linkKey = "vincularImagens"

    static func choose(_ kinds: [UTType], in nsWindow: NSWindow, done: @escaping (URL, Bool) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = kinds
        panel.allowsMultipleSelection = false
        // Before Linked images is released (ReleaseGate.swift): the open panel of before, and every image copied in.
        guard Feature.linkedImages.isOn else {
            panel.beginSheetModal(for: nsWindow) { response in
                if response == .OK, let url = panel.url { done(url, false) }
            }
            return
        }
        let link = NSButton(checkboxWithTitle: String(localized: "Link (the image isn’t copied into the document)"), target: nil, action: nil)
        link.state = UserDefaults.standard.bool(forKey: linkKey) ? .on : .off
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 36))
        link.frame = NSRect(x: 16, y: 8, width: 400, height: 20)
        box.addSubview(link)
        panel.accessoryView = box
        panel.isAccessoryViewDisclosed = true
        panel.beginSheetModal(for: nsWindow) { response in
            guard response == .OK, let url = panel.url else { return }
            let linked = link.state == .on
            if linked != UserDefaults.standard.bool(forKey: linkKey) { UserDefaults.standard.set(linked, forKey: linkKey) }
            done(url, linked)
        }
    }
}
