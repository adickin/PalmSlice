import Foundation

/// A slice's filament use and cost, from slicer_print_stats: what OrcaSlicer's
/// preview legend shows, per filament and by purpose.
struct SliceStats: Decodable, Equatable {
    struct Filament: Decodable, Equatable, Identifiable {
        /// 0-based slicer filament; PalmSlice tool `index + 1`.
        var index: Int
        var colour: String
        var modelG: Double
        var supportG: Double
        /// Prime (wipe) tower walls and infill.
        var towerG: Double
        /// Purged when changing filament (into the tower or as a purge line).
        var flushG: Double
        var totalG: Double
        var totalM: Double
        var pricePerKg: Double
        var cost: Double

        var id: Int { index }
        var tool: Int { index + 1 }
    }

    /// Estimated print time, seconds.
    var time: Double
    var filamentChanges: Int
    /// Time spent loading, unloading and changing tools, seconds.
    var changeTime: Double
    /// The printer's cost per hour × print time.
    var timeCost: Double
    var filaments: [Filament]
    /// The material each tool printed with, by PalmSlice tool number (set by the app).
    var materialNames: [Int: String] = [:]
    /// Each tool's colour as the app shows it (stand-ins for look-alike filaments).
    var toolColours: [Int: HexColour] = [:]

    private enum CodingKeys: String, CodingKey {
        case time, filamentChanges, changeTime, timeCost, filaments
    }

    var modelG: Double   { filaments.reduce(0) { $0 + $1.modelG } }
    var supportG: Double { filaments.reduce(0) { $0 + $1.supportG } }
    var towerG: Double   { filaments.reduce(0) { $0 + $1.towerG } }
    var flushG: Double   { filaments.reduce(0) { $0 + $1.flushG } }
    var totalG: Double   { filaments.reduce(0) { $0 + $1.totalG } }
    var totalM: Double   { filaments.reduce(0) { $0 + $1.totalM } }
    var filamentCost: Double { filaments.reduce(0) { $0 + $1.cost } }
    var totalCost: Double { filamentCost + timeCost }
    /// Whether any price is set (OrcaSlicer's default is 0).
    var hasCost: Bool { totalCost > 0 }

    init(time: Double, filamentChanges: Int, changeTime: Double, timeCost: Double, filaments: [Filament]) {
        self.time = time
        self.filamentChanges = filamentChanges
        self.changeTime = changeTime
        self.timeCost = timeCost
        self.filaments = filaments
    }

    init?(json: String) {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let data = json.data(using: .utf8),
              let stats = try? decoder.decode(SliceStats.self, from: data) else { return nil }
        self = stats
    }

    // MARK: Formatting

    static func grams(_ g: Double) -> String { String(format: "%.2f g", g) }
    static func metres(_ m: Double) -> String { String(format: "%.2f m", m) }

    static func money(_ value: Double) -> String {
        value.formatted(.currency(code: Locale.current.currency?.identifier ?? "USD"))
    }

    /// "1h 05m 12s"-style duration.
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        let (d, h, m, sec) = (s / 86400, s % 86400 / 3600, s % 3600 / 60, s % 60)
        if d > 0 { return String(format: "%dd %dh %02dm", d, h, m) }
        if h > 0 { return String(format: "%dh %02dm %02ds", h, m, sec) }
        if m > 0 { return String(format: "%dm %02ds", m, sec) }
        return "\(sec)s"
    }

    /// One line for the status area: "12.34 g · $0.25".
    var summaryText: String {
        var parts = [Self.grams(totalG)]
        if hasCost { parts.append(Self.money(totalCost)) }
        if filamentChanges > 0 { parts.append("\(filamentChanges) filament change\(filamentChanges == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}
