import XCTest
@testable import PalmSlice

/// Defaults come from OrcaSlicer: each printer's own qualities and filaments,
/// with the user's qualities and materials stored as changes only.
@MainActor
final class OrcaDefaultsTests: XCTestCase {
    private let ender = "Creality Ender-3 S1 0.4 nozzle"
    private let u1 = "Snapmaker U1 (0.4 nozzle)"

    // The stores remember their selection in the app's defaults; don't leave
    // the tests' choice behind in the host app.
    private var savedSelection: Any?
    override func setUp() { savedSelection = UserDefaults.standard.object(forKey: "lastSliceProfileID") }
    override func tearDown() { UserDefaults.standard.set(savedSelection, forKey: "lastSliceProfileID") }

    func testEachPrinterHasItsOwnQualities() {
        let enderQualities = PresetLibrary.qualities(forPrinter: ender)
        let u1Qualities = PresetLibrary.qualities(forPrinter: u1)
        XCTAssertTrue(enderQualities.contains("0.20mm Standard @Creality Ender3S1"))
        XCTAssertEqual(PresetLibrary.defaultQuality(forPrinter: ender), "0.20mm Standard @Creality Ender3S1")
        XCTAssertGreaterThan(u1Qualities.count, 5)
        XCTAssertTrue(Set(enderQualities).isDisjoint(with: u1Qualities))
        // The U1's own default name doesn't exist in OrcaSlicer's data: its
        // 0.20 Standard is used.
        XCTAssertEqual(PresetLibrary.defaultQuality(forPrinter: u1), "0.20 Standard @Snapmaker U1 (0.4 nozzle)")
        XCTAssertEqual(PresetLibrary.quality(forPrinter: u1, layerHeight: 0.28), "0.28 Extra Draft @Snapmaker U1 (0.4 nozzle)")
    }

    func testSwitchingPrinterSelectsItsDefaultQuality() {
        let store = SliceProfileStore()
        store.load(printerPreset: ender)
        store.select(id: PresetLibrary.stableID(.print, "0.20mm Standard @Creality Ender3S1"))
        XCTAssertEqual(store.selectedProfile?.basePreset, "0.20mm Standard @Creality Ender3S1")
        store.setPrinter(u1)
        XCTAssertEqual(store.selectedProfile?.basePreset, "0.20 Standard @Snapmaker U1 (0.4 nozzle)")
        XCTAssertTrue(store.systemProfiles.allSatisfy { $0.basePreset?.contains("Snapmaker U1") == true })
        // A user quality stays selected across printers.
        let rc = try! XCTUnwrap(store.customProfiles.first { $0.builtInName == BuiltInSliceProfiles.rcPlane.name })
        store.select(id: rc.id)
        store.setPrinter(ender)
        XCTAssertEqual(store.selectedProfileId, rc.id)
        XCTAssertEqual(store.selectedProfile?.wallCount, 1)
    }

    func testUserQualityKeepsOnlyItsChanges() {
        let store = SliceProfileStore()
        store.load(printerPreset: ender)
        var mine = SliceProfile.from(printPreset: "0.20mm Standard @Creality Ender3S1", name: "Five walls")
        mine.wallCount = 5
        let stored = store.changesOnly(mine)
        XCTAssertEqual(stored.extraSettings, ["wall_loops": "5", "layer_height": "0.2"])
        XCTAssertFalse(stored.isResolved)
    }

    /// An OrcaSlicer quality and filament slice exactly as the presets say.
    func testOrcaQualitySlicesItsPresets() throws {
        let printer = try XCTUnwrap(BuiltInProfiles.all.first { $0.systemPreset == ender })
        let quality = SliceProfile.system(try XCTUnwrap(PresetLibrary.defaultQuality(forPrinter: ender)))
        let filament = MaterialProfile.system(try XCTUnwrap(PresetLibrary.featuredFilaments(forPrinter: ender).first))
        guard let h = slicer_create() else { return XCTFail("slicer_create") }
        defer { slicer_destroy(h) }
        try SliceSetup.configure(h, printer: printer, material: filament, slice: quality)
        var drifted: [String] = []
        for (type, name) in [(PresetType.print, quality.basePreset!), (.filament, filament.basePreset!)] {
            for (key, value) in try XCTUnwrap(PresetLibrary.settings(type, name))
            where !["print_settings_id", "filament_settings_id"].contains(key) {
                let actual = slicer_get_setting(h, key).map { String(cString: $0) }
                if OrcaMigration.normalize([key: actual ?? ""]) != OrcaMigration.normalize([key: value]) {
                    drifted.append("\(key): preset=\(value) actual=\(actual ?? "nil")")
                }
            }
        }
        XCTAssertTrue(drifted.isEmpty, drifted.joined(separator: "\n"))
    }

    /// The RC Plane quality is its changes over whichever printer it's used on.
    func testUserQualityWorksOnEveryPrinter() throws {
        for preset in [ender, u1] {
            let printer = try XCTUnwrap(BuiltInProfiles.all.first { $0.systemPreset == preset })
            guard let h = slicer_create() else { return XCTFail("slicer_create") }
            defer { slicer_destroy(h) }
            try SliceSetup.configure(h, printer: printer, material: nil, slice: BuiltInSliceProfiles.rcPlane)
            XCTAssertEqual(slicer_get_setting(h, "wall_loops").map { String(cString: $0) }, "1")
            XCTAssertEqual(slicer_get_setting(h, "slicing_mode").map { String(cString: $0) }, "even_odd")
            let base = try XCTUnwrap(PresetLibrary.quality(forPrinter: preset, layerHeight: 0.3))
            let presetAccel = PresetLibrary.settings(.print, base)?["outer_wall_acceleration"]
            XCTAssertEqual(slicer_get_setting(h, "outer_wall_acceleration").map { String(cString: $0) }, presetAccel, preset)
        }
    }
}
