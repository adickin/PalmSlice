import XCTest
@testable import PalmSlice

/// Built-in templates that Reset to Default restores from.
final class ResetToDefaultTests: XCTestCase {
    func testEveryBuiltInIsItsOwnTemplate() {
        for p in BuiltInSliceProfiles.all { XCTAssertEqual(BuiltInSliceProfiles.template(named: p.builtInName)?.name, p.name) }
        for m in BuiltInMaterialProfiles.all { XCTAssertEqual(BuiltInMaterialProfiles.template(named: m.builtInName)?.name, m.name) }
        XCTAssertNil(BuiltInSliceProfiles.template(named: nil))
        XCTAssertNil(BuiltInMaterialProfiles.template(named: "My Material"))
    }

    // The link survives a rename and a save; profiles saved before it existed decode without one.
    func testLinkIsSavedAndOptional() throws {
        var p = try XCTUnwrap(BuiltInSliceProfiles.all.first)
        p.name = "Renamed"
        let decoded = try JSONDecoder().decode(SliceProfile.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(decoded.builtInName, BuiltInSliceProfiles.all.first?.name)

        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(BuiltInMaterialProfiles.all[0])) as! [String: Any]
        old["builtInName"] = nil
        let legacy = try JSONDecoder().decode(MaterialProfile.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(legacy.builtInName)
    }
}
