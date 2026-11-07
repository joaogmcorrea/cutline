// The "Google Fonts" tab of the font list (Editor/TextPanel.swift › FontList), as in the mockup the owner approved
// (option A, like Illustrator's Find More): search, category pills, each family written in itself with its number of
// styles and its license, and a round cloud button that adds it (a progress ring while it downloads, ✓ once it's in).
// The Mac talks to Google only while this tab is open, or when a font is added (GoogleFonts.swift).
import AppKit
import SwiftUI

/// The pills of the tab (the catalog's categories).
enum GoogleCategory: String, CaseIterable, Identifiable {
    case all
    case sansSerif = "sans-serif"
    case serif, display, handwriting, monospace

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .all: "All"
        case .sansSerif: "Sans serif"
        case .serif: "Serif"
        case .display: "Display"
        case .handwriting: "Handwriting"
        case .monospace: "Monospace"
        }
    }
}

struct GoogleFontsTab: View {
    let current: String
    let choose: (String) -> Void
    @Binding var search: String
    @Binding var category: GoogleCategory
    @FocusState private var searching: Bool

    private var fonts: GoogleFonts { .shared }

    private var filtered: [GoogleFamily] {
        GoogleFonts.catalog.filter { family in
            (category == .all || family.category.contains(category.rawValue))
                && (search.isEmpty || family.name.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        let families = filtered
        VStack(spacing: 0) {
            FontSearchField(prompt: "Search Google Fonts", text: $search, focus: $searching) {
                if let first = families.first { pick(first) }
            }
            FlowLayout(spacing: 5) {
                ForEach(GoogleCategory.allCases) { pill($0) }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            if fonts.unreachable {
                HStack(alignment: .top, spacing: 7) {
                    Image(.offline).resizable().frame(width: 14, height: 14).foregroundStyle(.orange)
                    Text("Can't reach Google Fonts. The fonts you've added keep working.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(8)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            Divider()
            if families.isEmpty {
                Text("No fonts found").foregroundStyle(.secondary).frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(families) { family in
                            GoogleFontRow(family: family, current: fonts.installedName(family) == current) { pick(family) }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Divider()
            Text("\(GoogleFonts.catalog.count.formatted()) free families · open licenses")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(6)
        }
        .onAppear {
            fonts.watchNetwork()
            searching = true
        }
        .onDisappear { fonts.stopWatchingNetwork() }
    }

    /// A family on this Mac (added or installed) goes to the text; one that isn't starts downloading.
    private func pick(_ family: GoogleFamily) {
        if fonts.added[family.name] != nil || fonts.isOnMac(family) {
            choose(fonts.installedName(family))
        } else {
            fonts.add(family)
        }
    }

    private func pill(_ kind: GoogleCategory) -> some View {
        let on = category == kind
        return Button { category = kind } label: {
            Text(kind.title)
                .font(.caption)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .foregroundStyle(on ? Color.white : Color.primary)
                .background(on ? Color.accentColor : Color.secondary.opacity(0.14), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A family: its name written in itself (loaded when the row shows), its styles and license, and the add button.
private struct GoogleFontRow: View {
    let family: GoogleFamily
    let current: Bool
    let pick: () -> Void
    @State private var preview: CTFont?
    @State private var over = false

    private var fonts: GoogleFonts { .shared }

    var body: some View {
        let added = fonts.added[family.name] != nil
        HStack(spacing: 8) {
            Image(.checked).resizable().frame(width: 12, height: 12).foregroundStyle(Color.accentColor).opacity(current ? 1 : 0)
            VStack(alignment: .leading, spacing: 1) {
                name.lineLimit(1)
                HStack(spacing: 4) {
                    Text("\(family.styleCount) styles")
                    Text(verbatim: "·")
                    Text(verbatim: family.license)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            GoogleAddButton(family: family)
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .clipped()
        .background(over ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: pick)
        .onHover { over = $0 }
        .help(Text(licenseName))
        .contextMenu {
            if added {
                Button("Remove from Cutline") { fonts.remove(family.name) }
            }
        }
        // Asks again when the network comes back (retry goes up).
        .task(id: fonts.retry) { await loadPreview() }
    }

    @ViewBuilder private var name: some View {
        if fonts.added[family.name] != nil || fonts.isOnMac(family) {
            Text(family.name).font(Font(Fonts.swatch(fonts.installedName(family), size: 15)))
        } else if let preview {
            Text(family.name).font(Font(preview))
        } else {
            // Until (or unless) its letters arrive: the system font, a little smaller, in gray.
            Text(family.name).font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    private var licenseName: String {
        switch family.license {
        case "OFL": "SIL Open Font License"
        case "Apache": "Apache License 2.0"
        case "UFL": "Ubuntu Font Licence"
        default: family.license
        }
    }

    private func loadPreview() async {
        guard preview == nil, fonts.added[family.name] == nil, !fonts.isOnMac(family) else { return }
        // Rows that only fly by while scrolling don't ask.
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        preview = await fonts.preview(family)
    }
}

/// The round cloud button: adds the family; a progress ring while it downloads; ✓ once it's in Cutline (or already on
/// the Mac); after a failure, a warning that tries again.
struct GoogleAddButton: View {
    let family: GoogleFamily

    private var fonts: GoogleFonts { .shared }

    var body: some View {
        Group {
            if let progress = fonts.downloading[family.name] {
                ProgressView(value: max(progress, 0.06))
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .help("Adding to Cutline…")
            } else if fonts.added[family.name] != nil {
                Image(.checked).resizable().frame(width: 14, height: 14).foregroundStyle(Color.accentColor)
                    .help("Added to Cutline")
            } else if fonts.isOnMac(family) {
                Image(.checked).resizable().frame(width: 14, height: 14).foregroundStyle(.secondary)
                    .help("Already installed on this Mac")
            } else {
                let failed = fonts.failed.contains(family.name)
                Button { fonts.add(family) } label: {
                    Image(failed ? .warning : .cloudDownload)
                        .resizable()
                        .frame(width: 14, height: 14)
                        .foregroundStyle(failed ? Color.orange : Color.accentColor)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.accentColor.opacity(0.14)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(failed ? "Couldn't add this font. Click to try again." as LocalizedStringKey : "Add to Cutline")
            }
        }
        .frame(width: 28, height: 28)
    }
}

/// The text's font is missing from this Mac and Google Fonts has it (a document made on another Mac): the Installed tab
/// offers to add it right there; the text redraws in it as soon as it's in.
struct MissingFontBanner: View {
    let name: String
    let family: GoogleFamily

    private var fonts: GoogleFonts { .shared }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(.warning).resizable().frame(width: 14, height: 14).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("“\(name)” isn't on this Mac.").font(.caption)
                if let progress = fonts.downloading[family.name] {
                    HStack(spacing: 5) {
                        ProgressView(value: max(progress, 0.06)).progressViewStyle(.circular).controlSize(.mini)
                        Text("Adding to Cutline…").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Button { fonts.add(family) } label: {
                        HStack(spacing: 4) {
                            Image(fonts.failed.contains(family.name) ? .warning : .cloudDownload)
                                .resizable().frame(width: 12, height: 12)
                            Text(fonts.failed.contains(family.name) ? "Couldn't add it. Try again" : "Add from Google Fonts")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.link)
                    .foregroundStyle(.tint)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}

/// Lays its pieces in rows, wrapping when the width runs out (the pills, whose names grow in other languages).
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
