import SwiftUI

/// The slice's filament use (by purpose and per filament), cost, and
/// filament changes.
struct SliceStatsView: View {
    let stats: SliceStats
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Print") {
                    row("Estimated Time", SliceStats.duration(stats.time))
                    row("Filament", "\(SliceStats.grams(stats.totalG)) · \(SliceStats.metres(stats.totalM))")
                    if stats.filaments.count > 1 || stats.filamentChanges > 0 {
                        row("Filament Changes", "\(stats.filamentChanges)")
                        if stats.changeTime > 0 { row("Time Changing Filament", SliceStats.duration(stats.changeTime)) }
                    }
                }

                Section("Filament by Use") {
                    usage(stats.modelG, stats.supportG, stats.towerG, stats.flushG, stats.totalG)
                }

                Section {
                    row("Filament", SliceStats.money(stats.filamentCost))
                    row("Printer Time", SliceStats.money(stats.timeCost))
                    row("Total", SliceStats.money(stats.totalCost)).fontWeight(.semibold)
                } header: {
                    Text("Cost")
                } footer: {
                    Text(stats.hasCost
                         ? "Filament priced per kg in each material; printer time priced per hour in the printer."
                         : "Set a price per kg in your materials and a cost per hour in your printer to see what a print costs.")
                }

                if stats.filaments.count > 1 {
                    ForEach(stats.filaments) { f in
                        Section {
                            usage(f.modelG, f.supportG, f.towerG, f.flushG, f.totalG)
                            row("Length", SliceStats.metres(f.totalM))
                            row("Cost", f.pricePerKg > 0
                                ? "\(SliceStats.money(f.cost)) at \(SliceStats.money(f.pricePerKg))/kg" : "—")
                        } header: {
                            HStack(spacing: 8) {
                                ToolBadge(tool: f.tool, colour: colour(f))
                                Text(stats.materialNames[f.tool] ?? "Filament \(f.tool)")
                            }
                            .textCase(nil)
                        }
                    }
                }
            }
            .navigationTitle("Slice Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func colour(_ f: SliceStats.Filament) -> HexColour {
        stats.toolColours[f.tool] ?? HexColour(f.colour) ?? .grey
    }

    /// Grams by purpose.
    @ViewBuilder
    private func usage(_ model: Double, _ support: Double, _ tower: Double, _ flush: Double, _ total: Double) -> some View {
        row("Model", SliceStats.grams(model))
        row("Supports", SliceStats.grams(support))
        row("Prime Tower", SliceStats.grams(tower))
        row("Flushed", SliceStats.grams(flush))
        row("Total", SliceStats.grams(total)).fontWeight(.semibold)
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).monospacedDigit() }
    }
}
