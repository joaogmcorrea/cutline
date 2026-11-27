// What's new in each version, on the start screen (option A of the start screen proposals, 23/11/2026, as Final Cut
// shows after an update): a spotlight on top with a few highlights, which its × folds into a thin line until the
// next version, and the What's New sheet. The text is written with each release, from the same notes as the update
// window, and goes inside the app: nothing comes from the network. A release with something to show adds its entry to
// `WhatsNew.all`; a version without one shows nothing.
import AppKit
import SwiftUI

struct WhatsNew {
    /// One highlight of the spotlight.
    struct Slide: Identifiable {
        let id: Int
        let kicker: LocalizedStringResource
        let title: LocalizedStringResource
        let body: LocalizedStringResource
        let art: Art
        let action: Action
    }

    /// What a highlight shows on its right: the same drawings as the tips (Editor/FeatureTips.swift).
    enum Art { case nest, typeOnPath }

    /// The highlight's button.
    enum Action {
        /// A new document with a few shapes, nesting (`StartScreen.Setup.tryNest`).
        case tryNest
        /// A new document with a circle and the Type on a Path tool (`StartScreen.Setup.typeOnPath`).
        case tryTypeOnPath

        var title: LocalizedStringResource {
            switch self {
            case .tryNest: "Try Nest"
            case .tryTypeOnPath: "Try It"
            }
        }
    }

    /// One line of the What's New sheet.
    struct Item: Identifiable {
        let id: Int
        let icon: ImageResource
        let title: LocalizedStringResource
        let text: LocalizedStringResource
        /// Left out while this feature isn't released (ReleaseGate.swift).
        var needs: Feature? = nil
    }

    /// "1.8": the versions it shows in (1.8.0, 1.8.1…).
    let version: String
    /// The thin line left after the × (and the sidebar's button title stays "What's New").
    let summary: LocalizedStringResource
    let slides: [Slide]
    let items: [Item]
    let notes: URL

    /// Newest first.
    static let all: [WhatsNew] = [
        WhatsNew(
            version: "1.8",
            summary: "Cutline 1.8 brings Nesting and a new look for Settings.",
            slides: [
                Slide(id: 0, kicker: "New in 1.8", title: "Nest your pieces and waste less material",
                      body: "Cutline fits the pieces on the sheet for you. Let them turn, or fill the artboard with copies of each one.",
                      art: .nest, action: .tryNest),
                Slide(id: 1, kicker: "Since 1.7", title: "Text that follows a path",
                      body: "Hold the T in the tools and pick Type on a Path. Click a line or a shape and type. It cuts along the letters.",
                      art: .typeOnPath, action: .tryTypeOnPath),
            ],
            items: [
                Item(id: 0, icon: .panelNest, title: "Nesting",
                     text: "Cutline fits your pieces on the sheet to use less material. Open the Nest tab on the right, or Object › Nest… (⌥⌘N).",
                     needs: .nesting),
                Item(id: 1, icon: .settingsTabGeneral, title: "Settings UI redesign",
                     text: "Settings has a new look that feels more at home on the Mac. Each topic has its own tab, and the options line up the same way on all of them."),
            ],
            notes: URL(string: "https://github.com/joaogmcorrea/cutline/releases/tag/v1.8.0")!
        ),
    ]

    /// The entry of the version running (major.minor), with what isn't released yet left out (ReleaseGate.swift).
    static var current: WhatsNew? {
        var version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        #if DEBUG
        if let test = DebugHooks.whatsNewVersion { version = test }
        #endif
        let minor = version.split(separator: ".").prefix(2).joined(separator: ".")
        guard let entry = all.first(where: { $0.version == minor }) else { return nil }
        let nesting = Feature.nesting.isOn
        return WhatsNew(version: entry.version, summary: entry.summary,
                        slides: entry.slides.filter { nesting || $0.art != .nest },
                        items: entry.items.filter { $0.needs?.isOn ?? true },
                        notes: entry.notes)
    }

    /// The version whose spotlight the × folded (until the next one).
    static let foldedKey = "spotlightFolded"
}

// MARK: The spotlight

/// The highlights of the version on top of the start screen, or the thin line they fold into.
struct StartSpotlight: View {
    let entry: WhatsNew
    let showSheet: () -> Void
    @AppStorage(WhatsNew.foldedKey) private var folded = ""
    @State private var index = 0

    var body: some View {
        Group {
            if isFolded { thinLine } else if let slide = entry.slides[safe: index] { banner(slide) }
        }
        #if DEBUG
        .onAppear {
            if let test = DebugHooks.spotlightSlide { index = min(test, entry.slides.count - 1) }
        }
        #endif
    }

    private var isFolded: Bool {
        #if DEBUG
        if DebugHooks.spotlightFolded { return true }
        #endif
        return folded == entry.version || entry.slides.isEmpty
    }

    private func banner(_ slide: WhatsNew.Slide) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(slide.kicker)
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .foregroundStyle(Color.accentColor)
                Text(slide.title).font(.system(size: 22, weight: .semibold))
                Text(slide.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 10)
                HStack(spacing: 10) {
                    Button { perform(slide.action) } label: { Text(slide.action.title).padding(.horizontal, 4) }
                        .buttonStyle(.glassProminent)
                    Button { showSheet() } label: { Text("What’s New in \(entry.version)…") }
                        .buttonStyle(.glass)
                    Spacer(minLength: 0)
                    if entry.slides.count > 1 { dots }
                }
            }
            .padding(.vertical, 20)
            .padding(.leading, 24)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            SpotlightArt(art: slide.art)
                .frame(width: 330, height: 170)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.trailing, 22)
        }
        .frame(height: 214)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topTrailing) {
            Button { folded = entry.version } label: {
                Image(.close).resizable().frame(width: 12, height: 12).padding(6).contentShape(Circle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Hide until the next version")
            .padding(6)
        }
    }

    private var dots: some View {
        HStack(spacing: 7) {
            ForEach(Array(entry.slides.enumerated()), id: \.element.id) { i, slide in
                Button { index = i } label: {
                    Circle()
                        .fill(i == index ? Color.accentColor : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                        .contentShape(Rectangle().inset(by: -4))
                }
                .buttonStyle(.plain)
                .help(Text(slide.title))
                .accessibilityLabel(Text(slide.title))
            }
        }
        .padding(.trailing, 4)
    }

    private var thinLine: some View {
        HStack(spacing: 10) {
            Image(.whatsNew).resizable().frame(width: 16, height: 16).foregroundStyle(Color.accentColor)
            Text(entry.summary).frame(maxWidth: .infinity, alignment: .leading)
            Button("What’s New") { showSheet() }.controlSize(.small)
            if !entry.slides.isEmpty {
                Button("Show Again") { folded = "" }.controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    private func perform(_ action: WhatsNew.Action) {
        switch action {
        case .tryNest: StartScreen.newDocument(.tryNest)
        case .tryTypeOnPath: StartScreen.newDocument(.typeOnPath)
        }
    }
}

/// The drawing on a highlight's right: the tip animations, larger.
private struct SpotlightArt: View {
    let art: WhatsNew.Art

    var body: some View {
        switch art {
        case .nest: tip(.nest)
        case .typeOnPath: tip(.typeOnPath)
        }
    }

    /// The tip animations are drawn for 250 × 130 (Editor/FeatureTips.swift).
    private func tip(_ preview: TipPreview) -> some View {
        TipAnimation(preview: preview)
            .frame(width: 250, height: 130)
            .scaleEffect(1.32)
            .frame(width: 330, height: 172)
    }
}

// MARK: The sheet

/// What's New in the version, as Final Cut shows it after an update.
struct WhatsNewSheet: View {
    let entry: WhatsNew
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("What’s New in Cutline \(entry.version)")
                .font(.title.weight(.semibold))
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 16) {
                ForEach(entry.items) { item in
                    HStack(alignment: .top, spacing: 14) {
                        Image(item.icon).resizable().frame(width: 24, height: 24)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 44, height: 44)
                            .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 11))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.headline)
                            Text(item.text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Link("Full Notes on GitHub", destination: entry.notes).font(.callout)
                Spacer()
                Button { dismiss() } label: { Text("Continue").padding(.horizontal, 8) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 520)
    }
}

// MARK: Trying a highlight

extension Document {
    /// A few shapes scattered on the active artboard, for Try Nest (they nest as soon as the window opens).
    func addNestSample() {
        let origin = activeArtboard.rect.origin
        func at(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(x: origin.x + x, y: origin.y + y, width: w, height: h) }
        let blue = CMYK(c: 100, m: 50, y: 0, k: 0), green = CMYK(c: 70, m: 0, y: 100, k: 0), red = CMYK(c: 0, m: 95, y: 85, k: 0)
        objects = [
            CanvasObject(shape: .star(points: 5, innerRadius: 0.45), frame: at(20, 22, 70, 67), strokeColor: green),
            CanvasObject(shape: .ellipse, frame: at(122, 30, 62, 40), strokeColor: blue),
            CanvasObject(shape: .rectangle(radius: 6), frame: at(30, 125, 55, 55), strokeColor: red),
            CanvasObject(shape: .star(points: 5, innerRadius: 0.45), frame: at(128, 112, 52, 50), strokeColor: green),
            CanvasObject(shape: .ellipse, frame: at(95, 205, 45, 45), strokeColor: blue),
            CanvasObject(shape: .rectangle(radius: 3), frame: at(18, 232, 66, 38), strokeColor: red),
            CanvasObject(shape: .star(points: 6, innerRadius: 0.55), frame: at(152, 222, 40, 40), strokeColor: blue),
        ]
        selection = []
    }

    /// A circle in the middle of the active artboard and the Type on a Path tool, for Try It.
    func addTypeOnPathSample() {
        let rect = activeArtboard.rect
        let side = min(rect.width, rect.height) * 0.6
        objects = [CanvasObject(shape: .ellipse, frame: CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side))]
        selection = []
        tool = .typeOnPath
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
