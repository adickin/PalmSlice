import Foundation

/// PrusaSlicer settings a 3MF/AMF file stores on one object
/// (slicer_imported_object_settings): overrides for the whole object,
/// overrides for height ranges, and a variable layer height profile.
/// Applied on top of the PalmSlice profiles when the object is sliced.
struct ModelFileSettings: Equatable {
    struct HeightRange: Equatable {
        var minZ: Double
        var maxZ: Double
        var settings: [String: String]
    }

    var objectSettings: [String: String] = [:]
    var ranges: [HeightRange] = []
    /// Variable layer height profile: (z, layer height) pairs.
    var layerHeights: [(z: Double, height: Double)] = []

    static func == (a: Self, b: Self) -> Bool {
        a.objectSettings == b.objectSettings && a.ranges == b.ranges
            && a.layerHeights.map(\.z) == b.layerHeights.map(\.z)
            && a.layerHeights.map(\.height) == b.layerHeights.map(\.height)
    }

    var isEmpty: Bool { objectSettings.isEmpty && ranges.isEmpty && layerHeights.isEmpty }
    /// Whether any setting depends on height (ranges or layer heights).
    var dependsOnHeight: Bool { !ranges.isEmpty || !layerHeights.isEmpty }

    init?(text: String) {
        var section: Int? = nil   // nil = object, -1 = layer heights, n = range n
        for line in text.split(separator: "\n").map(String.init) {
            if line.hasPrefix("[range ") {
                let parts = line.dropFirst(7).dropLast().split(separator: " ")
                guard parts.count == 2, let lo = Double(parts[0]), let hi = Double(parts[1]) else { continue }
                ranges.append(HeightRange(minZ: lo, maxZ: hi, settings: [:]))
                section = ranges.count - 1
            } else if line == "[layer_heights]" {
                section = -1
            } else if section == -1 {
                let v = line.split(separator: ";").compactMap { Double($0) }
                layerHeights = stride(from: 0, to: v.count - 1, by: 2).map { (v[$0], v[$0 + 1]) }
            } else if let r = line.range(of: " = ") {
                let key = String(line[..<r.lowerBound]), value = String(line[r.upperBound...])
                if let i = section { ranges[i].settings[key] = value } else { objectSettings[key] = value }
            }
        }
        // "extruder = 0" (= the object's default extruder) carries no information.
        objectSettings = objectSettings.filter { !($0.key == "extruder" && $0.value == "0") }
        for i in ranges.indices {
            ranges[i].settings = ranges[i].settings.filter { !($0.key == "extruder" && $0.value == "0") }
        }
        ranges.removeAll { $0.settings.isEmpty }
        if isEmpty { return nil }
    }

    /// The settings as slicer_set_object_file_settings text. Heights are
    /// multiplied by `heightScale` (the part's Z scale); `includeHeights: false`
    /// leaves out ranges and layer heights (for a part tilted off its
    /// imported orientation, where those heights no longer line up).
    func text(heightScale: Double = 1, includeHeights: Bool = true) -> String {
        var out = SettingsText.serialize(objectSettings)
        guard includeHeights else { return out }
        for r in ranges {
            out += "[range \(PrusaValue.float(r.minZ * heightScale)) \(PrusaValue.float(r.maxZ * heightScale))]\n"
            out += SettingsText.serialize(r.settings)
        }
        if !layerHeights.isEmpty {
            out += "[layer_heights]\n"
            out += layerHeights.flatMap { [PrusaValue.float($0.z * heightScale), PrusaValue.float($0.height)] }
                .joined(separator: ";") + "\n"
        }
        return out
    }

    /// Thinnest and thickest layer in the variable layer height profile.
    var layerHeightRange: ClosedRange<Double>? {
        let h = layerHeights.map(\.height).filter { $0 > 0 }
        guard let lo = h.min(), let hi = h.max() else { return nil }
        return lo...hi
    }
}

extension ModelTransform {
    /// True if the part is only spun about the vertical axis, so heights from
    /// the file (ranges, variable layer heights) still line up.
    var keepsFileHeights: Bool {
        func level(_ deg: Float) -> Bool {
            let r = deg.truncatingRemainder(dividingBy: 360)
            return abs(r) < 0.01 || abs(abs(r) - 360) < 0.01
        }
        return level(rotationDeg.x) && level(rotationDeg.y)
    }
}
