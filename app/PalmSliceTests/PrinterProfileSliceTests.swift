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
            let base = try XCTUnwrap(PresetLibrary.base(printerPreset: systemPreset, filamentType: "PLA"))
            if !PresetLibrary.apply(base, to: h) {
                failures.append("\(profile.name): base — \(String(cString: slicer_last_error(h)))"); continue
            }

            let ok: Bool = profile.startGCode.withCString { s in profile.endGCode.withCString { e in
                var cfg = SlicerPrinterConfig()
                cfg.bed_x = Float(profile.bedX); cfg.bed_y = Float(profile.bedY); cfg.bed_z = Float(profile.bedZ)
                cfg.heated_bed = 1
                cfg.gcode_flavor = profile.gcodeFlavor.bridgeInt
                cfg.start_gcode = s; cfg.end_gcode = e
                cfg.printhead_x_min = Float(profile.printheadXMin); cfg.printhead_y_min = Float(profile.printheadYMin)
                cfg.printhead_x_max = Float(profile.printheadXMax); cfg.printhead_y_max = Float(profile.printheadYMax)
                cfg.gantry_height = Float(profile.gantryHeight)
                cfg.extruder_count = 1
                cfg.apply_extruder_offsets = 1
                cfg.nozzle_diameter = Float(profile.extruders[0].nozzleDiameter)
                cfg.filament_diameter = 1.75
                return slicer_apply_printer_config(h, &cfg) == 0
            }}
            if !ok { failures.append("\(profile.name): apply — \(String(cString: slicer_last_error(h)))"); continue }
            if slicer_load_stl(h, stl) != 0 { failures.append("\(profile.name): load — \(String(cString: slicer_last_error(h)))"); continue }
            if slicer_slice(h, 0.2, 15) != 0 { failures.append("\(profile.name): slice — \(String(cString: slicer_last_error(h)))"); continue }
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
