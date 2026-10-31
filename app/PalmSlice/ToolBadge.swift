import SwiftUI

/// A tool's number on its colour ("T1", or "M1" for a mix).
struct ToolBadge: View {
    let tool: Int
    let colour: HexColour
    var compact = false

    var label: String { ToolMix.isMix(tool) ? "M\(tool - ToolMix.base)" : "T\(max(tool, 1))" }

    var body: some View {
        Text(label)
            .font(compact ? .caption2.weight(.bold) : .caption.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(colour.isLight ? Color.black : Color.white)
            .padding(.horizontal, compact ? 4 : 6)
            .padding(.vertical, compact ? 1 : 2)
            .background(colour.color, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.secondary.opacity(0.4), lineWidth: 0.5))
    }
}
