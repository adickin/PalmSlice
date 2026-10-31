import SwiftUI
import UIKit

/// An sRGB colour written "#RRGGBB", as PrusaSlicer stores filament_colour.
struct HexColour: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    init?(_ hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        red = Double((v >> 16) & 0xFF) / 255
        green = Double((v >> 8) & 0xFF) / 255
        blue = Double(v & 0xFF) / 255
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = red; self.green = green; self.blue = blue
    }

    init(_ colour: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        colour.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(red: min(max(Double(r), 0), 1), green: min(max(Double(g), 0), 1), blue: min(max(Double(b), 0), 1))
    }

    var hex: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
    var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: 1) }
    var color: Color { Color(uiColor) }

    /// Relative luminance, for picking a legible label colour on a swatch.
    var isLight: Bool { 0.2126 * red + 0.7152 * green + 0.0722 * blue > 0.6 }

    static let grey = HexColour(red: 0.82, green: 0.82, blue: 0.82)

    /// Distinct display colours for tools whose material colour repeats another tool's.
    static let toolStandIns = ["#E8743B", "#4F6BED", "#E0C341", "#B44FD6", "#5BBF4E", "#E04F7A", "#8C6239", "#F2F2F2"]
        .compactMap(HexColour.init)

    /// A stand-in for the tool, preferring its own slot, else the first one not yet used.
    static func standIn(forTool tool: Int, avoiding used: [HexColour]) -> HexColour {
        let own = toolStandIns[(tool - 1) % toolStandIns.count]
        if !used.contains(own) { return own }
        return toolStandIns.first { !used.contains($0) } ?? own
    }
}

extension Binding where Value == String {
    /// A ColorPicker binding over a "#RRGGBB" string.
    var hexColour: Binding<Color> {
        Binding<Color>(
            get: { (HexColour(wrappedValue) ?? .grey).color },
            set: { wrappedValue = HexColour(UIColor($0)).hex })
    }
}
