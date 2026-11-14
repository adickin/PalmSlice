import XCTest
@testable import PalmSlice

/// Editing an OrcaSlicer filament from a tool's sheet loads the copy in that tool only.
@MainActor
final class MaterialEditToolTests: XCTestCase {
    private var store: MaterialProfileStore!
    private var savedDefaults: [String: Any?] = [:]
    private var added: [UUID] = []
    private let keys = ["lastMaterialID", "toolMaterialIDs"]

    override func setUp() async throws {
        for k in keys { savedDefaults[k] = UserDefaults.standard.object(forKey: k) }
        UserDefaults.standard.removeObject(forKey: "toolMaterialIDs")   // no tool has its own yet
        store = MaterialProfileStore()
        let u1 = try XCTUnwrap(BuiltInProfiles.all.first { $0.builtInKey == "snapmaker-u1" })
        store.load(printerPreset: u1.systemPreset)
    }

    override func tearDown() async throws {
        for id in added { store.delete(id: id) }
        for (k, v) in savedDefaults { UserDefaults.standard.set(v ?? nil, forKey: k) }
    }

    /// Both tools on the printer's default filament, as after a fresh install.
    private func sameFilamentInBothTools() throws -> MaterialProfile {
        let system = try XCTUnwrap(store.systemProfiles.first)
        store.select(id: system.id)
        store.setMaterial(system.id, forTool: 2)
        return system
    }

    func testEditFromT2LeavesT1Alone() throws {
        let system = try sameFilamentInBothTools()
        var draft = system; draft.colour = "#FF0000"
        let id = store.keepEdit(ofSystem: draft, forTool: 2); added.append(id)

        XCTAssertEqual(store.selectedProfileId, system.id, "T1 should keep the OrcaSlicer filament")
        XCTAssertEqual(store.material(forTool: 1)?.colour, system.colour)
        XCTAssertEqual(store.material(forTool: 2)?.id, id)
        XCTAssertEqual(store.material(forTool: 2)?.colour, "#FF0000")
        XCTAssertFalse(try XCTUnwrap(store.material(forTool: 2)).isSystem)
    }

    func testEditFromT1LeavesT2Alone() throws {
        let system = try sameFilamentInBothTools()
        var draft = system; draft.colour = "#00FF00"
        let id = store.keepEdit(ofSystem: draft, forTool: 1); added.append(id)

        XCTAssertEqual(store.selectedProfileId, id)
        XCTAssertEqual(store.material(forTool: 2)?.id, system.id)
    }

    // Picking T3's filament used to pin T2 to T1's filament of the moment.
    func testSettingT3LeavesT2FollowingT1() throws {
        let systems = store.systemProfiles
        guard systems.count >= 3 else { throw XCTSkip("needs three filaments") }
        store.select(id: systems[0].id)
        store.setMaterial(systems[1].id, forTool: 3)
        XCTAssertFalse(store.hasOwnMaterial(tool: 2))

        store.select(id: systems[2].id)
        XCTAssertEqual(store.material(forTool: 2)?.id, systems[2].id, "T2 should follow T1")
        XCTAssertEqual(store.material(forTool: 3)?.id, systems[1].id)
    }

    func testToolsUsingAMaterial() throws {
        let system = try sameFilamentInBothTools()
        XCTAssertEqual(store.tools(using: system.id, count: 4), [1, 2, 3, 4])   // T3, T4 follow T1
        let other = try XCTUnwrap(store.systemProfiles.first { $0.id != system.id })
        store.setMaterial(other.id, forTool: 3)
        XCTAssertEqual(store.tools(using: system.id, count: 4), [1, 2, 4])
        XCTAssertEqual(store.tools(using: other.id, count: 4), [3])
    }
}
