import Foundation

/// A ColorMix mix (PrusaSlicer "Full Spectrum" virtual extruder): layers
/// alternate between 2–3 physical tools (blend), or shift from one tool to
/// the next over a height range (gradient). Assigned like a tool, by its
/// PalmSlice tool number `id` (`ToolMix.base` + n).
struct ToolMix: Identifiable, Equatable {
    enum Kind: String { case blend = "fullspectrum", gradient }

    struct Component: Equatable {
        /// Physical tool, 1-based.
        var tool: Int
        /// Blend: share of the layers (ratios are normalized by the slicer).
        /// Gradient: stop position, 0 (bottom) … 1 (top).
        var amount: Double
    }

    static let base = Int(SLICER_MIX_BASE)

    /// Mixes need PrusaSlicer's Full Spectrum virtual extruders, which the
    /// OrcaSlicer backend doesn't have: the bridge ignores them and files'
    /// mixes import as their object's tool. The UI to create them is hidden.
    static let isSupported = false

    var id: Int
    var kind: Kind = .blend
    var components: [Component]
    /// Gradient height range in mm above the bed; nil = the painted / assigned region's extent.
    var minZ: Double? = nil
    var maxZ: Double? = nil
    /// Blend: split each layer into one thinner sub-layer per tool (as
    /// Snapmaker Orca's local-Z mixing does) instead of alternating whole layers.
    var subLayers = false

    /// 1-based mix number shown to the user ("Mix 1").
    var number: Int { id - Self.base }
    var name: String { "Mix \(number)" }
    var tools: [Int] { components.map(\.tool) }

    static func isMix(_ tool: Int) -> Bool { tool > base }

    static func nextID(in mixes: [ToolMix]) -> Int {
        (mixes.map(\.id).max() ?? base) + 1
    }
}

extension ToolMix {
    /// Mixes as the bridge's JSON (Prusa_Slicer_full_spectrum.json format).
    static func json(_ mixes: [ToolMix]) -> String {
        let entries: [[String: Any]] = mixes.map { mix in
            var e: [String: Any] = ["id": mix.id, "kind": mix.kind.rawValue]
            let key = mix.kind == .gradient ? "position" : "ratio"
            e["components"] = mix.components.map { ["extruder": $0.tool, key: $0.amount] }
            if mix.kind == .blend && mix.subLayers { e["sublayers"] = true }
            if let z = mix.minZ { e["minz"] = z }
            if let z = mix.maxZ { e["maxz"] = z }
            return e
        }
        let root: [String: Any] = ["version": 1, "physical_extruders": [], "virtual_extruders": entries]
        let data = (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func parse(_ json: String) -> [ToolMix] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["virtual_extruders"] as? [[String: Any]] else { return [] }
        return entries.compactMap { e in
            guard let id = e["id"] as? Int, let comps = e["components"] as? [[String: Any]] else { return nil }
            let kind = Kind(rawValue: e["kind"] as? String ?? "") ?? .blend
            let key = kind == .gradient ? "position" : "ratio"
            let components = comps.compactMap { c -> Component? in
                guard let tool = c["extruder"] as? Int, let amount = (c[key] as? NSNumber)?.doubleValue else { return nil }
                return Component(tool: tool, amount: amount)
            }
            return ToolMix(id: id, kind: kind, components: components,
                           minZ: (e["minz"] as? NSNumber)?.doubleValue, maxZ: (e["maxz"] as? NSNumber)?.doubleValue,
                           subLayers: (e["sublayers"] as? Bool) ?? false)
        }
    }
}

extension ToolMix {
    /// Each physical tool's share of the mix's apparent colour: blend ratios,
    /// or for a gradient the span each stop covers (as libslic3r weighs them).
    var colourWeights: [(tool: Int, weight: Double)] {
        if kind == .blend && subLayers {
            // Sub-layer heights: 0.04 + share × 0.12 mm per 0.2 mm (as the slicer sizes them).
            let total = components.reduce(0) { $0 + max(0, $1.amount) }
            return components.map { ($0.tool, 0.04 + (total > 0 ? max(0, $0.amount) / total : 0) * 0.12) }
        }
        guard kind == .gradient else { return components.map { ($0.tool, $0.amount) } }
        let stops = components.sorted { $0.amount < $1.amount }
        return stops.indices.map { i in
            let lo = i == 0 ? 0 : (stops[i - 1].amount + stops[i].amount) / 2
            let hi = i == stops.count - 1 ? 1 : (stops[i].amount + stops[i + 1].amount) / 2
            return (stops[i].tool, max(0, hi - lo))
        }
    }

    /// Predicted colour from the physical tools' colours (index = tool - 1).
    func predictedColour(toolColours: [HexColour]) -> HexColour {
        let parts = colourWeights.compactMap { w -> String? in
            guard w.tool >= 1, w.tool <= toolColours.count, w.weight > 0 else { return nil }
            return "\(toolColours[w.tool - 1].hex):\(w.weight)"
        }.joined(separator: ";")
        var out = [CChar](repeating: 0, count: 16)
        guard !parts.isEmpty, slicer_mix_color(parts, &out, 16) == 0 else { return .grey }
        return HexColour(String(cString: out)) ?? .grey
    }
}

/// Tool colours for display: physical tools from their materials, mixes predicted.
struct ToolPalette: Equatable {
    var physical: [HexColour]
    var mixes: [ToolMix]

    func colour(_ tool: Int) -> HexColour {
        if ToolMix.isMix(tool) {
            return mixes.first { $0.id == tool }?.predictedColour(toolColours: physical) ?? .grey
        }
        let t = max(tool, 1)
        return t <= physical.count ? physical[t - 1] : physical.first ?? .grey
    }

    /// Physical tools a set of tool numbers prints with (mixes expanded).
    func physicalTools(_ tools: Set<Int>) -> Set<Int> {
        Set(tools.flatMap { t in ToolMix.isMix(t) ? (mixes.first { $0.id == t }?.tools ?? []) : [t] })
    }
}
