// Floating glass piece over the canvas: tools (left). The control bar is in ControlBar.swift.
import SwiftUI

/// Vertical tool capsule, like Illustrator's (one-letter shortcuts).
struct ToolsPanel: View {
    @Bindable var doc: Document

    private let groups: [[Tool]] = [[.selection, .direct], [.pen, .text], [.rectangle, .ellipse, .star], [.traceImage, .hand]]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(groups.indices, id: \.self) { g in
                if g > 0 { Divider().frame(width: 22).padding(.vertical, 2) }
                ForEach(groups[g]) { tool in button(tool) }
            }
        }
        .padding(6)
        .glassEffect(.regular, in: .capsule)
    }

    private func button(_ tool: Tool) -> some View {
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
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("\(tool.name) (\(tool.keyEvent.uppercased()))")
    }
}

extension Tool {
    /// Prototype icons (Assets.xcassets).
    var icon: String {
        switch self {
        case .selection: "toolSelection"
        case .direct: "toolDirectSelection"
        case .pen: "toolPen"
        case .text: "toolText"
        case .rectangle: "toolRectangle"
        case .ellipse: "toolEllipse"
        case .star: "toolStar"
        case .traceImage: "toolTrace"
        case .hand: "toolHand"
        }
    }
}
