import Foundation

/// The wipe tower's footprint on the bed, in printer coordinates (mm).
struct WipeTowerFootprint: Equatable {
    /// Front-left corner.
    var x: Double
    var y: Double
    var width: Double
    var depth: Double
    /// Rotation about the front-left corner.
    var rotationDeg: Double
    var brim: Double
    var height: Double
    /// Depth estimated before slicing (the slice gives the real one).
    var isEstimate: Bool

    /// Where the tower goes until it's dragged: back right of the bed centre.
    static func defaultPosition(bedX: Double, bedY: Double, originAtCenter: Bool) -> SIMD2<Double> {
        let origin = originAtCenter ? SIMD2(-bedX / 2, -bedY / 2) : .zero
        return origin + SIMD2((bedX * 0.68).rounded(), (bedY * 0.68).rounded())
    }

    /// The wipe tower settings over a print preset's (`base`), and the plate:
    /// nil when there's no tower (off, a single tool, or one tool used).
    /// `slicedDepth` is the last slice's real depth.
    static func make(settings: [String: String], base: [String: String], toolCount: Int,
                     toolsUsed: Int, modelHeight: Double, slicedDepth: Double?,
                     position: SIMD2<Double>) -> WipeTowerFootprint? {
        func value(_ key: String) -> String? { settings[key] ?? base[key] }
        func number(_ key: String, _ fallback: Double) -> Double { value(key).flatMap(PrusaValue.parseFloat) ?? fallback }
        guard toolCount > 1, toolsUsed > 1, value("wipe_tower").flatMap(PrusaValue.parseBool) ?? true else { return nil }
        let width = number("wipe_tower_width", 60)
        // Before slicing, PrusaSlicer's early estimate: 900 mm² per tool change.
        let depth = slicedDepth ?? max(5, 900 / max(width, 1) * Double(toolsUsed - 1))
        return WipeTowerFootprint(
            x: position.x, y: position.y, width: width, depth: depth, rotationDeg: 0,
            brim: number("wipe_tower_brim_width", 2), height: max(modelHeight, 1),
            isEstimate: slicedDepth == nil)
    }
}
