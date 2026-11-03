// Floating glass piece over the canvas: tools (left). The control bar is in ControlBar.swift.
import SwiftUI

/// Vertical tool capsule, like Illustrator's (one-letter shortcuts), with the colors at the foot.
struct ToolsPanel: View {
    @Bindable var doc: Document
    /// The Pen's group (as in Illustrator): the slot shows the last one used; holding it (or a right click) shows all three.
    @State private var penSlot = Tool.pen
    @State private var penGroupOpen = false

    private static let penGroup: [Tool] = [.pen, .addNode, .deleteNode]
    private let groups: [[Tool]] = [[.selection, .direct], [.pen, .text], [.rectangle, .ellipse, .star], [.eyedropper], [.hand, .zoom]]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(groups.indices, id: \.self) { g in
                if g > 0 { Divider().frame(width: 22).padding(.vertical, 2) }
                ForEach(groups[g]) { tool in
                    if tool == .pen { penButton } else { button(tool) }
                }
            }
            Divider().frame(width: 22).padding(.vertical, 2)
            ToolColors(doc: doc)
        }
        .padding(6)
        .glassEffect(.regular, in: .capsule)
        .onChange(of: doc.tool) { _, newOne in if Self.penGroup.contains(newOne) { penSlot = newOne } }
    }

    private func button(_ tool: Tool, group: Bool = false) -> some View {
        let active = doc.tool == tool
        return Button {
            doc.tool = tool
        } label: {
            Image(tool.icon)
                .resizable()
                .frame(width: 20, height: 20)
                .frame(width: 36, height: 36)
                .foregroundStyle(active ? Color.white : Color.primary)
                .background(Circle().fill(active ? Color.accentColor : .clear))
                .overlay(alignment: .bottomTrailing) {
                    // The little corner of a group, as in Illustrator.
                    if group {
                        Path { p in
                            p.move(to: CGPoint(x: 5, y: 0))
                            p.addLine(to: CGPoint(x: 5, y: 5))
                            p.addLine(to: CGPoint(x: 0, y: 5))
                            p.closeSubpath()
                        }
                        .fill(active ? Color.white : Color.secondary)
                        .frame(width: 5, height: 5)
                        .offset(x: -6, y: -6)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("\(tool.name) (\(tool.keyEvent.uppercased()))")
    }

    private var penButton: some View {
        button(penSlot, group: true)
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.35).onEnded { _ in penGroupOpen = true })
            .contextMenu {
                ForEach(Self.penGroup) { tool in
                    Button("\(tool.name) (\(tool.keyEvent.uppercased()))") { doc.tool = tool }
                }
            }
            .popover(isPresented: $penGroupOpen, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Self.penGroup) { tool in
                        Button {
                            doc.tool = tool
                            penGroupOpen = false
                        } label: {
                            HStack(spacing: 8) {
                                Image(tool.icon).resizable().frame(width: 16, height: 16)
                                Text(tool.name)
                                Spacer(minLength: 16)
                                Text(verbatim: tool.keyEvent.uppercased()).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(doc.tool == tool ? Color.accentColor.opacity(0.2) : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
                .frame(minWidth: 220)
            }
    }
}

/// Illustrator's color control at the foot of the tools: default colors and swap on top, fill and stroke, and below
/// "color" (the last one used) and "none" — for whichever square is in front.
private struct ToolColors: View {
    @Bindable var doc: Document

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 0) {
                Button { doc.defaultColors() } label: { Image(.defaultColors).resizable().frame(width: 12, height: 12) }
                    .help("Default: no fill, red 0 pt stroke (D)")
                Spacer(minLength: 0)
                Button { doc.swapColors() } label: { Image(.swapColors).resizable().frame(width: 12, height: 12) }
                    .help("Swap fill and stroke (⇧X)")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .frame(width: 34)
            ColorSquares(doc: doc, side: 22)
            HStack(spacing: 4) {
                let target = doc.colorTarget
                let last = doc.recent.first ?? (target == .strokeColor ? .red : CMYK(c: 0, m: 0, y: 0, k: 100))
                Button { doc.setColor(target, last) } label: {
                    RoundedRectangle(cornerRadius: 3).fill(last.color)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.black.opacity(0.22), lineWidth: 0.5))
                        .frame(width: 15, height: 15)
                }
                .help("Color: the last one used")
                Button { doc.setColor(target, nil) } label: {
                    NoneOption()
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.black.opacity(0.22), lineWidth: 0.5))
                        .frame(width: 15, height: 15)
                }
                .help("None (/)")
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 4)
    }
}

extension Tool {
    /// Prototype icons (Assets.xcassets).
    var icon: String {
        switch self {
        case .selection: "toolSelection"
        case .direct: "toolDirectSelection"
        case .pen: "toolPen"
        case .addNode: "toolAddNode"
        case .deleteNode: "toolDeleteNode"
        case .text: "toolText"
        case .rectangle: "toolRectangle"
        case .ellipse: "toolEllipse"
        case .star: "toolStar"
        case .eyedropper: "toolEyedropper"
        case .hand: "toolHand"
        case .zoom: "toolZoom"
        }
    }
}
