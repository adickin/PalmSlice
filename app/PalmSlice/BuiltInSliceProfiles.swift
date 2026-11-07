import Foundation

/// PalmSlice's own qualities: only what they deliberately change, applied over
/// the printer's OrcaSlicer quality nearest their layer height. Everyday
/// qualities (Draft, Standard, Fine…) come from OrcaSlicer for each printer.
enum BuiltInSliceProfiles {
    private static func changes(_ name: String, _ settings: [String: String]) -> SliceProfile {
        var p = SliceProfile()
        p.name = name
        p.builtInName = name
        p.extraSettings = settings
        p.isResolved = false
        return p
    }

    // Pairs with the "eSUN PLA-LW (Lightweight)" material. Foaming PLA is used for
    // light, thin-walled parts, so: 2 walls, thin shells, sparse infill. eSUN says
    // not to slow the first layer (its flow already matches the foamed layers),
    // so first-layer speed equals print speed; fast travel limits oozing, since
    // retraction is barely effective with foaming filament.
    static let lightweight = changes("Lightweight LW-PLA (0.2 mm)", [
        "layer_height": "0.2",
        "wall_loops": "2",
        "top_shell_layers": "3",
        "bottom_shell_layers": "3",
        "sparse_infill_density": "10%",
        "sparse_infill_pattern": "gyroid",
        "outer_wall_speed": "45",
        "inner_wall_speed": "45",
        "sparse_infill_speed": "45",
        "initial_layer_speed": "45",
        "internal_solid_infill_speed": "30",
        "top_surface_speed": "25",
        "travel_speed": "150",
    ])

    // 3DLabPrint RC plane parts, with the settings from 3dlabprint.com/faq/prusaslicer
    // (LW-PLA values). Their models build skins, ribs and spars into the geometry,
    // so the slicer prints one wall and nothing else: no top/bottom shells, no
    // infill. Even/Odd slicing, Classic walls and a 0 gap-closing radius are
    // required for that geometry to slice correctly. First layer is 50% of wall
    // speed, as specified there. Not for ordinary models: they would print as
    // hollow single-wall shells.
    static let rcPlane = changes("3DLabPrint RC Plane (LW-PLA 0.3 mm)", [
        "layer_height": "0.3",
        "initial_layer_print_height": "0.3",
        "wall_loops": "1",
        "wall_generator": "classic",
        "wall_sequence": "outer wall/inner wall",
        "top_shell_layers": "0",
        "bottom_shell_layers": "0",
        "top_shell_thickness": "0",
        "bottom_shell_thickness": "0",
        "sparse_infill_density": "0%",
        "slicing_mode": "even_odd",
        "slice_closing_radius": "0",
        "line_width": "0.42",
        "initial_layer_line_width": "0.44",
        "outer_wall_speed": "40",
        "inner_wall_speed": "40",
        "sparse_infill_speed": "40",
        "initial_layer_speed": "20",
        "travel_speed": "150",
        "skirt_loops": "1",
    ])

    static let all: [SliceProfile] = [lightweight, rcPlane]

    static func template(named name: String?) -> SliceProfile? { all.first { $0.builtInName == name } }
}
