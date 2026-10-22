import XCTest
@testable import PalmSlice

final class ProfileCodableTests: XCTestCase {

    // MARK: - Round-trip encode/decode

    func testPrinterProfileRoundTrip() throws {
        let original = BuiltInProfiles.crealityEnder3S1
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
            XCTAssertEqual(decoded.adhesionType, original.adhesionType)
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

    func testEnder3S1HasAtLeastOneExtruder() {
        XCTAssertFalse(BuiltInProfiles.crealityEnder3S1.extruders.isEmpty)
        XCTAssertEqual(BuiltInProfiles.crealityEnder3S1.numberOfExtruders, BuiltInProfiles.crealityEnder3S1.extruders.count)
    }

    // MARK: - Bridge-int mappings must stay unique per enum
    // (each of these enums is passed to the C++ bridge as a raw Int32; a
    // collision would silently apply the wrong slicer setting)

    func testGCodeFlavorBridgeIntsAreUnique() {
        let values = GCodeFlavor.allCases.map(\.bridgeInt)
        XCTAssertEqual(values.count, Set(values).count)
    }

    func testAdhesionTypeBridgeIntsAreUnique() {
        let values = AdhesionType.allCases.map(\.bridgeInt)
        XCTAssertEqual(values.count, Set(values).count)
    }

    func testBrimTypeBridgeIntsAreUnique() {
        let values = BrimType.allCases.map(\.bridgeInt)
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
}
