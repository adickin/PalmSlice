import XCTest
@testable import PalmSlice

/// PrusaSlicer settings stored on objects in 3MF files, using 3DLabPrint's
/// Piper J-3 Cub project files (skipped when they aren't on this machine).
final class FileSettingsTests: XCTestCase {
    private let cub = URL(fileURLWithPath: "/Users/adickin/ios-sources/test-data/PS_3MF")

    private func cubFile(_ path: String) throws -> URL {
        let url = cub.appendingPathComponent(path)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "Cub 3MF files not available")
        return url
    }

    private func convert(_ url: URL) throws -> ConvertedModelObject {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let objects = try convertModelFile(at: url, outputDir: dir)
        XCTAssertEqual(objects.count, 1)
        return try XCTUnwrap(objects.first)
    }

    func testReadsRangesLayerHeightsAndProjectSettings() throws {
        let aileron = try convert(try cubFile("wing/CUB aileron L1.3mf"))
        let fs = try XCTUnwrap(aileron.fileSettings)
        XCTAssertEqual(fs.ranges.count, 2)
        XCTAssertEqual(fs.ranges[0].minZ, 0)
        XCTAssertEqual(fs.ranges[0].maxZ, 2)
        XCTAssertEqual(fs.ranges[0].settings["bottom_solid_layers"], "4")
        XCTAssertEqual(fs.ranges[1].settings["top_solid_layers"], "3")
        XCTAssertEqual(aileron.projectSettings?["slicing_mode"], "even_odd")
        XCTAssertEqual(aileron.projectSettings?["print_settings_id"], "0.3 mm 3DLabPrint")

        let fuselage = try convert(try cubFile("fuselage/CUB fuselage 1.3mf"))
        let heights = try XCTUnwrap(fuselage.fileSettings?.layerHeightRange)
        XCTAssertEqual(heights.lowerBound, 0.07, accuracy: 0.001)

        let mount = try convert(try cubFile("accessories/CUB motor mount 16x19.3mf"))
        XCTAssertEqual(mount.fileSettings?.objectSettings["fill_density"], "100%")
        XCTAssertEqual(mount.fileSettings?.objectSettings["perimeters"], "5")
    }

    // Height ranges add the aileron's solid end caps; without them it's an
    // open single-wall shell, so it uses less filament.
    func testHeightRangesChangeTheSlice() throws {
        let aileron = try convert(try cubFile("wing/CUB aileron L1.3mf"))
        let with = try slice(aileron, useFileSettings: true)
        let without = try slice(aileron, useFileSettings: false)
        XCTAssertGreaterThan(try filament(with), try filament(without) * 1.02)
    }

    // The variable layer height profile reaches the G-code: fuselage 1 goes
    // down to 0.07 mm layers where the profile says so.
    func testVariableLayerHeightsReachTheGCode() throws {
        let fuselage = try convert(try cubFile("fuselage/CUB fuselage 1.3mf"))
        let heights = try slice(fuselage, useFileSettings: true)
            .split(separator: "\n").filter { $0.hasPrefix(";HEIGHT:") }
            .compactMap { Double($0.dropFirst(8)) }
        XCTAssertLessThan(try XCTUnwrap(heights.min()), 0.1)
        let flat = try slice(fuselage, useFileSettings: false)
            .split(separator: "\n").filter { $0.hasPrefix(";HEIGHT:") }
            .compactMap { Double($0.dropFirst(8)) }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(flat.filter { $0 > 0.05 }.min()), 0.2)
    }

    private func slice(_ object: ConvertedModelObject, useFileSettings: Bool) throws -> String {
        guard let h = slicer_create() else { throw XCTSkip("slicer_create") }
        defer { slicer_destroy(h) }
        let printer = try XCTUnwrap(BuiltInProfiles.all.first { $0.verified })
        try SliceSetup.configure(h, printer: printer, material: BuiltInMaterialProfiles.esunPLALW,
                                 slice: BuiltInSliceProfiles.rcPlane)
        let idx = slicer_add_stl(h, object.url.path)
        XCTAssertGreaterThanOrEqual(idx, 0, String(cString: slicer_last_error(h)))
        var t = SlicerModelTransform()
        t.scale_x = 1; t.scale_y = 1; t.scale_z = 1
        XCTAssertEqual(slicer_set_object_transform(h, idx, &t), 0, String(cString: slicer_last_error(h)))
        if useFileSettings, let fs = object.fileSettings {
            XCTAssertEqual(slicer_set_object_file_settings(h, idx, fs.text()), 0, String(cString: slicer_last_error(h)))
        }
        XCTAssertEqual(slicer_slice(h, 0, 0), 0, String(cString: slicer_last_error(h)))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).gcode")
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertEqual(slicer_export_gcode(h, out.path), 0, String(cString: slicer_last_error(h)))
        return try String(contentsOf: out, encoding: .utf8)
    }

    private func filament(_ gcode: String) throws -> Double {
        let line = try XCTUnwrap(gcode.split(separator: "\n").first { $0.hasPrefix("; filament used [mm] =") })
        return try XCTUnwrap(Double(line.split(separator: "=").last!.trimmingCharacters(in: .whitespaces)))
    }
}

/// End to end: a Cub part imported the PalmSlice way (mesh + profiles created
/// from the file + per-part file settings) slices like the 3MF project itself.
final class ProjectParityTests: XCTestCase {
    func testCubPartsMatchPrusaSlicerProject() throws {
        let root = URL(fileURLWithPath: "/Users/adickin/ios-sources/test-data/PS_3MF")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: root.path), "Cub 3MF files not available")
        for part in ["wing/CUB aileron L1.3mf", "fuselage/CUB fuselage 1.3mf",
                     "accessories/CUB motor mount 16x19.3mf", "floats/CUB float L2.3mf"] {
            let file = root.appendingPathComponent(part)
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }

            // Reference: the project as PrusaSlicer would slice it.
            let refURL = tmp.appendingPathComponent("ref.gcode")
            var err = [CChar](repeating: 0, count: 512)
            XCTAssertEqual(slicer_reference_slice_3mf(file.path, refURL.path, &err, 512), 0, String(cString: err))

            // PalmSlice: import, profiles from the file, part settings.
            let object = try XCTUnwrap(try convertModelFile(at: file, outputDir: tmp).first)
            let project = try XCTUnwrap(object.projectSettings)
            var printer = PrinterProfile(); printer.importPrusaSettings(project)
            var material = MaterialProfile(); material.importPrusaSettings(project)
            var slice = SliceProfile(); slice.importPrusaSettings(project)
            guard let h = slicer_create() else { return XCTFail("slicer_create") }
            defer { slicer_destroy(h) }
            try SliceSetup.configure(h, printer: printer, material: material, slice: slice)
            let idx = slicer_add_stl(h, object.url.path)
            var t = SlicerModelTransform(); t.scale_x = 1; t.scale_y = 1; t.scale_z = 1
            XCTAssertEqual(slicer_set_object_transform(h, idx, &t), 0)
            if let fs = object.fileSettings {
                XCTAssertEqual(slicer_set_object_file_settings(h, idx, fs.text()), 0, String(cString: slicer_last_error(h)))
            }
            XCTAssertEqual(slicer_slice(h, 0, 0), 0, String(cString: slicer_last_error(h)))
            let oursURL = tmp.appendingPathComponent("ours.gcode")
            XCTAssertEqual(slicer_export_gcode(h, oursURL.path), 0, String(cString: slicer_last_error(h)))

            let ref = try String(contentsOf: refURL, encoding: .utf8)
            let ours = try String(contentsOf: oursURL, encoding: .utf8)
            func heights(_ g: String) -> [String] { g.split(separator: "\n").filter { $0.hasPrefix(";HEIGHT:") }.map(String.init) }
            func filament(_ g: String) -> Double {
                Double(g.split(separator: "\n").first { $0.hasPrefix("; filament used [mm] =") }?
                    .split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? "") ?? -1
            }
            XCTAssertEqual(heights(ours), heights(ref), "\(part): layer heights differ")
            XCTAssertEqual(filament(ours), filament(ref), accuracy: filament(ref) * 0.002,
                           "\(part): filament \(filament(ours)) vs project \(filament(ref)) mm")
            print("PARITY \(part): \(heights(ours).count) layers, filament \(filament(ours)) vs \(filament(ref)) mm")
        }
    }
}
