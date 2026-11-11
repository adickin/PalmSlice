import XCTest
import simd
@testable import PalmSlice

/// Filament use / cost statistics and arranging (Duplicate, Fill Plate).
final class SliceStatsTests: XCTestCase {
    private let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures")

    /// Slices parts.3mf (tools 1–3) on the U1 with priced filaments and
    /// returns the stats.
    private func twoMaterialStats() throws -> SliceStats {
        let printer = try XCTUnwrap(BuiltInProfiles.all.first { $0.builtInKey == "snapmaker-u1" })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = try importModelFile(at: fixtures.appendingPathComponent("parts.3mf"), outputDir: dir)
        guard let h = slicer_create() else { throw XCTSkip("slicer_create") }
        defer { slicer_destroy(h) }
        var printerPriced = printer
        printerPriced.extraSettings["time_cost"] = "2"
        var pla = BuiltInMaterialProfiles.pla
        pla.extraSettings["filament_cost"] = "25"
        var petg = BuiltInMaterialProfiles.petg
        petg.colour = "#0000FF"
        petg.extraSettings["filament_cost"] = "40"
        try SliceSetup.configure(h, printer: printerPriced, material: pla, slice: SliceProfile(), toolMaterials: [petg])
        let object = file.objects[0]
        let model = PlacedModel(id: UUID(), url: object.url, name: object.name, geometry: nil,
                                transform: ModelTransform(), nativeURL: object.nativeURL,
                                extruder: object.extruder, parts: object.parts)
        let idx = slicer_add_model_object(h, try XCTUnwrap(object.nativeURL).path, 1)
        var t = SlicerModelTransform(); t.scale_x = 1; t.scale_y = 1; t.scale_z = 1
        XCTAssertEqual(slicer_set_object_transform(h, idx, &t), 0)
        XCTAssertNil(SliceSetup.applyTools(h, object: idx, model: model))
        XCTAssertEqual(slicer_slice(h, 0, 0), 0, String(cString: slicer_last_error(h)))
        let out = dir.appendingPathComponent("stats.gcode")
        XCTAssertEqual(slicer_export_gcode(h, out.path), 0, String(cString: slicer_last_error(h)))
        return try XCTUnwrap(SliceStats(json: String(cString: slicer_print_stats(h))))
    }

    func testStatsBreakFilamentDownByUseAndFilament() throws {
        let stats = try twoMaterialStats()
        XCTAssertGreaterThan(stats.filaments.count, 1)
        XCTAssertGreaterThan(stats.filamentChanges, 0)
        XCTAssertGreaterThan(stats.time, 0)
        XCTAssertGreaterThan(stats.towerG + stats.flushG, 0, "a multi-tool print uses the prime tower")
        for f in stats.filaments {
            // Every gram is model, support, tower or flush.
            XCTAssertEqual(f.modelG + f.supportG + f.towerG + f.flushG, f.totalG, accuracy: max(0.05, f.totalG * 0.01),
                           "filament \(f.tool)")
            XCTAssertEqual(f.cost, f.totalG * f.pricePerKg / 1000, accuracy: 0.0001)
        }
        XCTAssertEqual(stats.filaments.first { $0.tool == 1 }?.pricePerKg, 25)
        XCTAssertEqual(stats.timeCost, 2 * stats.time / 3600, accuracy: 0.001)
        XCTAssertEqual(stats.totalCost, stats.filamentCost + stats.timeCost, accuracy: 0.0001)
    }

    func testStatsDecodeFromBridgeJSON() throws {
        let json = """
        {"time":3600,"filament_changes":4,"change_time":120,"time_cost":1.5,"filaments":[
         {"index":0,"colour":"#FFFFFF","model_g":10,"support_g":2,"tower_g":1,"flush_g":0.5,"total_g":13.5,
          "total_m":4.5,"price_per_kg":20,"cost":0.27}]}
        """
        let stats = try XCTUnwrap(SliceStats(json: json))
        XCTAssertEqual(stats.filaments.first?.tool, 1)
        XCTAssertEqual(stats.supportG, 2)
        XCTAssertEqual(stats.totalCost, 1.77, accuracy: 0.0001)
        XCTAssertEqual(SliceStats.duration(stats.time), "1h 00m 00s")
    }

    // MARK: Arrange

    private func square(_ size: Float) -> [SIMD2<Float>] {
        let h = size / 2
        return [SIMD2(-h, -h), SIMD2(h, -h), SIMD2(h, h), SIMD2(-h, h)]
    }

    func testConvexHullDropsInnerPoints() {
        let hull = ModelTransform.convexHull([SIMD2(0, 0), SIMD2(1, 0), SIMD2(0.5, 0.2), SIMD2(1, 1), SIMD2(0, 1)])
        XCTAssertEqual(hull.count, 4, "the inner point is dropped")
        XCTAssertEqual(PlateArrange.area(square(10)), 100, accuracy: 0.001)
    }

    func testFillPlatePacksCopiesWithoutOverlap() {
        let bed = square(220)
        let item = square(30)
        let wanted = PlateArrange.maxCopies(of: item, bed: bed)
        let spots = PlateArrange.place(Array(repeating: item, count: wanted), around: [], bed: bed).compactMap { $0 }
        // About a 37 mm pitch on a 220 mm bed: 5 × 5 at least.
        XCTAssertGreaterThanOrEqual(spots.count, 25)
        for (i, a) in spots.enumerated() {
            XCTAssertLessThanOrEqual(abs(a.x) + 15, 110.01)
            XCTAssertLessThanOrEqual(abs(a.y) + 15, 110.01)
            for b in spots[(i + 1)...] {
                XCTAssertTrue(abs(a.x - b.x) >= 35.9 || abs(a.y - b.y) >= 35.9, "\(a) is closer than 6 mm to \(b)")
            }
        }
    }

    func testDuplicateAvoidsModelsInPlace() throws {
        let bed = square(220)
        let existing = square(40)   // at the bed centre
        let spot = try XCTUnwrap(PlateArrange.place([square(40)], around: [existing], bed: bed,
                                                    prefer: .zero).first ?? nil)
        XCTAssertTrue(abs(spot.x) >= 45.9 || abs(spot.y) >= 45.9, "copy at \(spot) is closer than 6 mm")
        XCTAssertLessThan(simd_length(spot), 50, "the copy goes next to the original")
    }

    func testNoRoomReportsNil() {
        let spots = PlateArrange.place([square(300)], around: [], bed: square(220))
        XCTAssertNil(spots.first ?? nil)
    }
}
