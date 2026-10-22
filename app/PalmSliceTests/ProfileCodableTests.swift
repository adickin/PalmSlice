import XCTest
@testable import PalmSlice

final class ProfileCodableTests: XCTestCase {

    // MARK: - Round-trip encode/decode

    func testPrinterProfileRoundTrip() throws {
        let original = try XCTUnwrap(BuiltInProfiles.all.first)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PrinterProfile.self, from: data)

        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.bedX, original.bedX)
        XCTAssertEqual(decoded.bedY, original.bedY)
        XCTAssertEqual(decoded.bedZ, original.bedZ)
        XCTAssertEqual(decoded.gcodeFlavor, original.gcodeFlavor)
        XCTAssertEqual(decoded.startGCode, original.startGCode)
        XCTAssertEqual(decoded.endGCode, original.endGCode)
        XCTAssertEqual(decoded.extruders.count, original.extruders.count)
    }

    func testSliceProfileRoundTrip() throws {
        for original in BuiltInSliceProfiles.all {
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(SliceProfile.self, from: data)

            XCTAssertEqual(decoded.name, original.name)
            XCTAssertEqual(decoded.layerHeight, original.layerHeight)
            XCTAssertEqual(decoded.infillDensity, original.infillDensity)
            XCTAssertEqual(decoded.infillPattern, original.infillPattern)
            XCTAssertEqual(decoded.skirtLoops, original.skirtLoops)
            XCTAssertEqual(decoded.brimType, original.brimType)
            XCTAssertEqual(decoded.raftLayers, original.raftLayers)
        }
    }

    func testMaterialProfileRoundTrip() throws {
        for original in BuiltInMaterialProfiles.all {
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(MaterialProfile.self, from: data)

            XCTAssertEqual(decoded.name, original.name)
            XCTAssertEqual(decoded.firstLayerTemp, original.firstLayerTemp)
            XCTAssertEqual(decoded.otherLayersTemp, original.otherLayersTemp)
            XCTAssertEqual(decoded.retractionEnabled, original.retractionEnabled)
        }
    }

    // MARK: - Built-in profile sanity

    func testBuiltInProfilesHaveUniqueNames() {
        let printerNames = BuiltInProfiles.all.map(\.name)
        XCTAssertEqual(printerNames.count, Set(printerNames).count, "duplicate built-in printer profile name")

        let sliceNames = BuiltInSliceProfiles.all.map(\.name)
        XCTAssertEqual(sliceNames.count, Set(sliceNames).count, "duplicate built-in slice profile name")

        let materialNames = BuiltInMaterialProfiles.all.map(\.name)
        XCTAssertEqual(materialNames.count, Set(materialNames).count, "duplicate built-in material profile name")
    }

    func testEnder3S1HasAtLeastOneExtruder() throws {
        let ender = try XCTUnwrap(BuiltInProfiles.all.first { $0.verified })
        XCTAssertFalse(ender.extruders.isEmpty)
        XCTAssertEqual(ender.numberOfExtruders, ender.extruders.count)
        XCTAssertEqual(BuiltInProfiles.all.count, BuiltInProfiles.entries.count, "a built-in printer preset failed to load")
    }

    // MARK: - Bridge-int mappings must stay unique per enum
    // (each of these enums is passed to the C++ bridge as a raw Int32; a
    // collision would silently apply the wrong slicer setting)

    func testGCodeFlavorBridgeIntsAreUnique() {
        let values = GCodeFlavor.allCases.map(\.prusaName)
        XCTAssertEqual(values.count, Set(values).count)
    }

    func testBrimTypePrusaNamesAreUnique() {
        let values = BrimType.allCases.map(\.prusaName)
        XCTAssertEqual(values.count, Set(values).count)
    }

    func testSupportStyleBridgeIntsAreUnique() {
        let values = SupportStyle.allCases.map(\.bridgeInt)
        XCTAssertEqual(values.count, Set(values).count)
    }

    // MARK: - Picker subtitles never crash / are non-empty

    func testSliceProfilePickerSubtitleIsNonEmpty() {
        for profile in BuiltInSliceProfiles.all {
            XCTAssertFalse(profile.pickerSubtitle.isEmpty)
        }
    }

    func testMaterialProfilePickerSubtitleIsNonEmpty() {
        for profile in BuiltInMaterialProfiles.all {
            XCTAssertFalse(profile.pickerSubtitle.isEmpty)
        }
    }

    // Profiles saved with the old single adhesion choice keep only that one on.
    func testLegacyAdhesionChoiceMigrates() throws {
        func decode(_ choice: String) throws -> SliceProfile {
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SliceProfile())) as! [String: Any]
            json["adhesionType"] = choice
            json["skirtLoops"] = 2; json["raftLayers"] = 3; json["brimType"] = "Outer Only"
            return try JSONDecoder().decode(SliceProfile.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let none = try decode("None")
        XCTAssertEqual([none.skirtLoops, none.raftLayers], [0, 0]); XCTAssertEqual(none.brimType, .none)
        let skirt = try decode("Skirt")
        XCTAssertEqual([skirt.skirtLoops, skirt.raftLayers], [2, 0]); XCTAssertEqual(skirt.brimType, .none)
        let brim = try decode("Brim")
        XCTAssertEqual([brim.skirtLoops, brim.raftLayers], [0, 0]); XCTAssertEqual(brim.brimType, .outerOnly)
        let raft = try decode("Raft")
        XCTAssertEqual([raft.skirtLoops, raft.raftLayers], [0, 3]); XCTAssertEqual(raft.brimType, .none)
    }
}
