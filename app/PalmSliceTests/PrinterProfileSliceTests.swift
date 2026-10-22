import XCTest
@testable import PalmSlice

/// Slices a small model with every built-in printer profile and checks that
/// libslic3r accepts the profile's start/end G-code placeholders.
final class PrinterProfileSliceTests: XCTestCase {

    func testEveryBuiltInPrinterSlices() throws {
        let stl = "/Users/adickin/ios-sources/PrusaSlicer/resources/shapes/sphere.stl"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: stl), "sample STL not available")

        var failures: [String] = []
        for profile in BuiltInProfiles.all {
            guard let h = slicer_create() else { XCTFail("slicer_create"); return }
            defer { slicer_destroy(h) }
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(profile.builtInKey ?? "x").gcode")

            let systemPreset = try XCTUnwrap(profile.systemPreset, "\(profile.name) has no PrusaSlicer preset")
            XCTAssertTrue(PresetLibrary.exists(.printer, systemPreset), "missing preset \(systemPreset)")
            let base = try XCTUnwrap(SliceSetup.base(printer: profile, material: BuiltInMaterialProfiles.pla,
                                                     slice: BuiltInSliceProfiles.standard))
            do {
                try SliceSetup.configure(h, printer: profile, material: BuiltInMaterialProfiles.pla,
                                         slice: BuiltInSliceProfiles.standard)
            } catch {
                failures.append("\(profile.name): \(error)"); continue
            }
            if slicer_load_stl(h, stl) != 0 { failures.append("\(profile.name): load — \(String(cString: slicer_last_error(h)))"); continue }
            if slicer_slice(h, 0, 0) != 0 { failures.append("\(profile.name): slice — \(String(cString: slicer_last_error(h)))"); continue }
            if slicer_export_gcode(h, out.path) != 0 { failures.append("\(profile.name): export — \(String(cString: slicer_last_error(h)))"); continue }
            let text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
            print("PROFILE-OK \(profile.name) bytes=\(text.utf8.count) base=\(base)")
            if !text.hasPrefix(";") { failures.append("\(profile.name): G-code isn't plain text") }
            if !text.contains("; print_settings_id = \(base.print)") {
                failures.append("\(profile.name): print preset \(base.print) not recorded")
            }
            if profile.builtInKey == "prusa-mk4" {
                print("MK4-START-BLOCK\n" + text.components(separatedBy: "\n").prefix(60).joined(separator: "\n"))
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
}
