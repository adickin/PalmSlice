// slicer_bridge.h
// Thin C wrapper around libslic3r's C++ API.
// Swift sees this via the ObjC bridging header — it cannot call C++ directly.

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle to a slicer context (holds Model + Print + Config)
typedef void* SlicerHandle;

// Lifecycle
SlicerHandle slicer_create(void);
void         slicer_destroy(SlicerHandle handle);

// Load an STL file from an absolute path on the filesystem.
// Returns 0 on success, negative on error.
int slicer_load_stl(SlicerHandle handle, const char* path);

// Slice with given layer height (mm) and infill percentage (0–100).
// Blocks until slicing is complete.
// Returns 0 on success, negative on error.
int slicer_slice(SlicerHandle handle, float layer_height, int infill_percent);

// Slice with a progress callback.
// progress_cb receives a value in [0.0, 1.0] and a user-supplied ctx pointer.
// Returns 0 on success, negative on error.
int slicer_slice_with_progress(SlicerHandle handle,
                               float layer_height,
                               int   infill_percent,
                               void (*progress_cb)(float progress, void* ctx),
                               void* ctx);

// Export G-code to the given absolute output path.
// Slice must have been called successfully first.
// Returns 0 on success, negative on error.
int slicer_export_gcode(SlicerHandle handle, const char* output_path);

// Cancel an in-progress slice. Safe to call from any thread while
// slicer_slice / slicer_slice_with_progress is running.
// The canceled flag is cleared automatically at the start of the next slice.
void slicer_cancel(SlicerHandle handle);

// Returns a human-readable error string for the last failed call.
// Valid until the next call on the same handle.
const char* slicer_last_error(SlicerHandle handle);

// ── Slice profile ─────────────────────────────────────────────────────────────

// The slice profile's wall / shell / infill values, as checked by
// slicer_check_slice_config. (Settings themselves are applied as PrusaSlicer
// key/value text with slicer_apply_settings.)
typedef struct {
    // Layers
    float layer_height;          // mm — layer_height
    float first_layer_height;    // mm — first_layer_height

    // Walls
    int   wall_count;            // perimeters
    float horizontal_expansion;  // mm — xy_size_compensation (negative = shrink)
    int   wall_generator;        // 0=classic, 1=arachne — perimeter_generator
    int   external_perimeters_first; // bool — external_perimeters_first

    // Top / Bottom
    int   top_layers;            // top_solid_layers
    int   bottom_layers;         // bottom_solid_layers
    float top_thickness;         // mm — top_solid_min_thickness (0 = use layer count)
    float bottom_thickness;      // mm — bottom_solid_min_thickness (0 = use layer count)

    // Infill
    int   infill_density;        // 0–100 % — fill_density
    int   infill_pattern;        // InfillPattern::bridgeInt — fill_pattern
    // How far infill lines overlap into the perimeters, as a % of extrusion
    // width. Stock PrusaSlicer is 25%; lower it to reduce material being forced
    // out through the walls on dense/solid parts (at the cost of wall bonding).
    float infill_overlap;        // % — infill_overlap

    // Advanced
    int   slicing_mode;          // 0=regular, 1=even/odd — slicing_mode
    float gap_closing_radius;    // mm — slice_closing_radius
    float extrusion_width;       // mm — extrusion_width (0 = keep the base value)
    float first_layer_extrusion_width; // mm — first_layer_extrusion_width (0 = keep the base value)

    // Speed (mm/s)
    float print_speed;           // perimeter_speed
    float infill_speed;          // infill_speed
    float travel_speed;          // travel_speed
    float first_layer_speed;     // first_layer_speed
    float solid_infill_speed;    // solid_infill_speed — top/bottom/internal solid shells
    float top_solid_infill_speed; // top_solid_infill_speed — visible top surface only

    // Ironing — a slow, low-flow finishing pass over solid top surfaces that
    // smooths ridges left by solid infill. Most useful on parts with thick
    // top/bottom shells (many solid layers) where those ridges are most visible.
    int   ironing;                // bool — ironing
    int   ironing_type;           // 0=all top surfaces, 1=topmost only, 2=all solid surfaces — ironing_type
    float ironing_flowrate;       // % — ironing_flowrate
    float ironing_speed;          // mm/s — ironing_speed
    float ironing_spacing;        // mm — ironing_spacing

    // Support
    int   generate_support;          // bool — support_material
    int   support_style;             // 0=normal(snug), 1=tree(organic) — support_material_style
    int   support_buildplate_only;   // bool — support_material_buildplate_only
    int   support_overhang_angle;    // degrees — support_material_threshold
    float support_xy_spacing;        // mm — support_material_xy_spacing
    int   support_use_towers;        // bool — support_material_with_sheath
    // Support-to-part interface. These govern how solid the part's supported
    // (bottom-on-support) surface prints. Smaller contact distance + more/denser
    // interface layers => more solid bottom, at the cost of harder removal.
    float support_contact_distance;  // mm — support_material_contact_distance (Z gap between support top and part)
    int   support_interface_layers;  // support_material_interface_layers (dense layers under the part; also mirrored to bottom)
    float support_interface_spacing; // mm — support_material_interface_spacing (0 = fully solid interface)

    // Build plate adhesion
    // adhesion_type: 0=none, 1=skirt, 2=brim, 3=raft
    int   adhesion_type;
    int   brim_type;             // 1=outer_only, 2=inner_only, 3=outer_and_inner — brim_type
    float brim_width;            // mm — brim_width
    int   skirt_loops;           // skirts
    float skirt_distance;        // mm — skirt_distance
    int   raft_layers;           // raft_layers
} SlicerSliceConfig;

// Result of slicer_check_slice_config: flags wall/top/bottom settings that
// are too aggressive for the loaded model's geometry — e.g. more wall loops
// than fit across the model's thinnest horizontal span, or more top/bottom
// solid layers than fit in its shortest vertical span. Settings like that
// don't fail to slice, but produce overlapping/self-intersecting perimeters
// or fully-solid parts instead of a clean print.
//
// This is a bounding-box heuristic (nozzle diameter × geometry extents), not
// full per-region mesh analysis — it catches settings that are too
// aggressive for the model as a whole, not thin features buried inside an
// otherwise large part.
typedef struct {
    int needs_warning;             // 1 if any suggested value differs from cfg's input
    int suggested_wall_count;
    int suggested_top_layers;
    int suggested_bottom_layers;
} SlicerSliceConfigCheck;

// Sanity-check wall_count/top_layers/bottom_layers in cfg against the loaded
// model's geometry and the applied printer's nozzle diameter. Does not
// modify the slicer context or cfg — read-only, safe to call repeatedly
// (e.g. live as the user edits a slice profile).
//
// Must be called after slicer_load_stl/slicer_add_stl (model geometry known)
// and settings with the nozzle_diameter applied.
// Returns 0 on success, negative on error (out is left zeroed on error).
int slicer_check_slice_config(SlicerHandle handle,
                              const SlicerSliceConfig* cfg,
                              SlicerSliceConfigCheck* out);

// ── Model transform ───────────────────────────────────────────────────────────

// User transform from the 3D viewer (SceneKit coordinate space).
// Call after slicer_load_stl and before slicer_slice / slicer_slice_with_progress.
//
// Coordinate mapping (SceneKit → STL/Slic3r):
//   SceneKit X  →  STL X     (same axis)
//   SceneKit Y  →  STL Z     (up in both, but SceneKit Y = STL Z)
//   SceneKit Z  → -STL Y     (depth axis, sign-flipped)
//
// pos_x_mm / pos_z_mm: XY offset from bed centre in mm (SceneKit X / SceneKit Z).
// rot_*_deg: ZYX Euler angles as used by SceneKit, in degrees.
// scale_*: per-axis scale factors (SceneKit X/Y/Z).
typedef struct {
    float pos_x_mm;   // SceneKit X offset from bed centre  → Slic3r X delta
    float pos_z_mm;   // SceneKit Z offset from bed centre  → negated Slic3r Y delta
    float rot_x_deg;  // SceneKit Euler X (degrees)
    float rot_y_deg;  // SceneKit Euler Y (degrees)
    float rot_z_deg;  // SceneKit Euler Z (degrees)
    float scale_x;    // SceneKit scale X → Slic3r scale X
    float scale_y;    // SceneKit scale Y → Slic3r scale Z
    float scale_z;    // SceneKit scale Z → Slic3r scale Y
} SlicerModelTransform;

// Apply the viewer model transform to the loaded model.
// Drops the model to the bed (Z=0) automatically after rotation/scale.
// Returns 0 on success, negative on error.
int slicer_set_model_transform(SlicerHandle handle,
                               const SlicerModelTransform* t);

// ── Multi-model API ───────────────────────────────────────────────────────────

// Append a new STL object to the slicer model (does not reset existing objects).
// Returns the object index (≥ 0) on success, or a negative error code.
// Must be called after the printer settings (bed_shape) are applied so the bed is known.
int slicer_add_stl(SlicerHandle handle, const char* path);

// Apply a viewer transform to the Nth object added via slicer_add_stl.
// object_index is the value returned by slicer_add_stl.
// Drops the object to the bed (Z=0) automatically.
// Returns 0 on success, negative on error.
int slicer_set_object_transform(SlicerHandle handle, int object_index,
                                const SlicerModelTransform* t);

// ── Model file import ─────────────────────────────────────────────────────────

// Loads a 3MF, OBJ, AMF or STL file and writes each object instance as a binary
// STL to "<out_dir>/<i>.stl" (i = 0..count-1), with the instance's rotation,
// scale and mirroring baked in. Embedded print settings are ignored.
// Returns the number of objects written (> 0), or a negative error code.
// Does not touch the handle's model; only the import results below.
int slicer_import_model_file(SlicerHandle handle, const char* path, const char* out_dir);

// Name of the Nth object from the last slicer_import_model_file call ("" if out of range).
// The pointer is valid until the next import call or slicer_destroy.
const char* slicer_imported_object_name(SlicerHandle handle, int index);

// Position of the Nth imported object's bounding-box centre relative to the
// centre of all imported objects, in print coordinates (X, Y = bed depth), mm.
// Returns 0 on success, negative on error.
int slicer_imported_object_offset(SlicerHandle handle, int index,
                                  float* offset_x_mm, float* offset_y_mm);

// ── PrusaSlicer system presets ────────────────────────────────────────────────
//
// PrusaSlicer's vendor profile bundles (printer / print / filament presets,
// shipped in the app by scripts/12_vendor_profiles.sh) loaded once per
// process with libslic3r's PresetBundle. They are the base layer every slice
// starts from, so any setting a PalmSlice profile doesn't set takes the value
// PrusaSlicer itself would use for that printer — not libslic3r's bare
// built-in defaults.

// Preset types, matching PrusaSlicer's three FFF preset collections.
enum {
    SLICER_PRESET_PRINT    = 0,   // print settings   (PalmSlice: slice profile)
    SLICER_PRESET_FILAMENT = 1,   // filament settings (PalmSlice: material profile)
    SLICER_PRESET_PRINTER  = 2,   // printer settings  (PalmSlice: printer profile)
};

// Load every vendor bundle from "<profiles_dir>/vendor/*.ini". Safe to call
// again (reloads). Returns the number of system printer presets loaded (> 0),
// or a negative error code; see slicer_presets_last_error.
int slicer_presets_load(const char* profiles_dir);

// Error (or non-fatal load warnings) from the last slicer_presets_load call.
const char* slicer_presets_last_error(void);

// Number of system presets of a type (0 before slicer_presets_load).
int slicer_preset_count(int type);

// Name of the Nth system preset of a type ("" if out of range). The pointer
// stays valid until the next slicer_presets_load call.
const char* slicer_preset_name(int type, int index);

// A system preset's full, flattened settings as PrusaSlicer .ini lines
// ("key = value\n", values serialized as PrusaSlicer writes them). NULL if
// no such preset. The pointer is valid until the next call on this thread.
const char* slicer_preset_config(int type, const char* name);

// 1 if the print or filament preset `name` is compatible with the system
// printer preset `printer_name` (its compatible_printers / condition), 0 if
// not, negative if either preset is unknown. Printer presets: always 1.
int slicer_preset_is_compatible(int type, const char* name, const char* printer_name);

// ── Generic settings ──────────────────────────────────────────────────────────

// Apply a system preset's settings to the context, as PrusaSlicer does when
// that preset is selected (print/filament: also records it in
// print_settings_id / filament_settings_id for the G-code header).
// Returns 0 on success, negative if the preset is unknown.
int slicer_apply_preset(SlicerHandle handle, int type, const char* name);

// Apply settings given as PrusaSlicer .ini text ("key = value" lines; blank
// lines and lines starting with '#' or ';' are ignored). Every line is
// validated by libslic3r; on any bad key or value nothing is applied and the
// error names the offending line. Returns 0 on success, negative on error.
int slicer_apply_settings(SlicerHandle handle, const char* ini_text);

// Current value of a setting in the context, serialized as PrusaSlicer writes
// it; NULL if the key is unknown. Valid until the next call on this thread.
const char* slicer_get_setting(SlicerHandle handle, const char* key);

#ifdef __cplusplus
}
#endif
