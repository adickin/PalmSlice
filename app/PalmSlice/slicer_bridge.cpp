// slicer_bridge.cpp
// C wrapper implementation over libslic3r.
//
// Targets: OrcaSlicer 2.4.2 libslic3r API (pinned via ORCA_TAG in scripts/common.sh).
// If the build fails due to missing symbols, check the OrcaSlicer version:
//   cd ~/ios-sources/OrcaSlicer && git log --oneline -5
// and adjust the include paths or method names accordingly.

#include "slicer_bridge.h"

#include <string>
#include <stdexcept>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <strings.h>
#include <functional>
#include <algorithm>
#include <numeric>
#include <cmath>
#include <limits>
#include <vector>
#include <array>

// ── libslic3r core ────────────────────────────────────────────────────────────
#include <libslic3r/libslic3r.h>
#include <libslic3r/Model.hpp>
#include <libslic3r/Print.hpp>
#include <libslic3r/PrintConfig.hpp>
#include <libslic3r/Format/STL.hpp>
#include <libslic3r/Format/bbs_3mf.hpp>
#include <libslic3r/Format/3mf.hpp>
#include <libslic3r/Semver.hpp>
#include <libslic3r/TriangleMesh.hpp>
#include <libslic3r/Preset.hpp>
#include <libslic3r/PresetBundle.hpp>
#include <libslic3r/Utils.hpp>
#include <libslic3r/TriangleSelector.hpp>
#include <libslic3r/GCode/ThumbnailData.hpp>
#include <libslic3r/GCode/GCodeProcessor.hpp>
#include <libslic3r/FlushVolCalc.hpp>
#include <libslic3r/Flow.hpp>
#include <libslic3r/Feature/FullSpectrum/VirtualExtruder.hpp>
#include <libslic3r/Feature/FullSpectrum/prusa_fdm_mixer.hpp>
#include <map>
#include <memory>
#include <mutex>
#include <sstream>
#include <filesystem>
#include <boost/algorithm/string/predicate.hpp>

// ── Paint session ─────────────────────────────────────────────────────────────
// Colour painting on one printable volume of an imported object (its native
// 3MF). States are PalmSlice tool numbers (0 = the part's own tool).
struct PaintSession {
    Slic3r::Model model;                                   // the one object
    Slic3r::ModelVolume* volume = nullptr;
    Slic3r::Transform3d trafo = Slic3r::Transform3d::Identity();  // volume mesh → display frame
    int layer = SLICER_PAINT_COLOUR;
    std::unique_ptr<Slic3r::TriangleSelector> selector;
    std::vector<Slic3r::TriangleSelector::TriangleSplittingData> undo, redo;
    std::vector<float> vertices;                           // display mesh, 9 floats per triangle
    std::vector<unsigned char> states;                     // state per triangle
};

// ── Context ───────────────────────────────────────────────────────────────────
struct SlicerContext {
    Slic3r::Model              model;
    Slic3r::Print              print;
    Slic3r::DynamicPrintConfig config;
    std::string                last_error;

    // Printer dimensions — derived from bed_shape whenever settings are
    // applied (sync_bed_from_config), used to centre models on the bed.
    double bed_x = 220.0;
    double bed_y = 220.0;
    bool   origin_at_center = false;

    // Set to true once slicer_apply_settings has been called so that
    // slicer_slice_with_progress doesn't clobber the slice settings with its
    // legacy layer_height / infill_percent parameters.
    bool   slice_config_applied = false;

    // Results of the last slicer_import_model_file call.
    struct ImportedVolume {
        std::string name;
        int type = SLICER_VOLUME_PART;
        int extruder = 0;      // PalmSlice tool number, 0 = the object's
        int facets = 0;        // triangles in the object's STL (parts only)
        bool painted = false;
        int painted_layers = 0;         // bit (1 << SLICER_PAINT_*) per painted layer
        std::vector<int> paint_tools;   // PalmSlice tool numbers painted on it
    };
    struct ImportedObject {
        std::string name;
        float offset_x_mm = 0.f;
        float offset_y_mm = 0.f;
        // Settings stored on the object in the file (see slicer_imported_object_settings).
        std::string settings;
        int extruder = 0;      // PalmSlice tool number, 0 = default
        std::vector<ImportedVolume> volumes;
    };
    std::vector<ImportedObject> imported;
    // Project-wide settings stored in the last imported file (3MF / AMF).
    std::string imported_project;
    // Colliding paths found by the last export (slicer_path_conflict).
    std::string path_conflict;
    // Statistics of the last export (slicer_print_stats).
    std::string print_stats;

    // Wipe (prime) tower placement from slicer_set_wipe_tower_position; until
    // then the printer preset's. OrcaSlicer keeps it in the config (per plate).
    bool  wipe_tower_placed = false;
    float wipe_tower_x = 0.f, wipe_tower_y = 0.f, wipe_tower_rotation = 0.f;

    std::unique_ptr<PaintSession> paint;

    // The session's mixes (ColorMix: PrusaSlicer Full Spectrum virtual
    // extruders), with PalmSlice tool numbers as ids.
    Slic3r::FullSpectrum::VirtualExtruders mixes;
    std::string mixes_json;

    // Thumbnails: when enabled, the printer's `thumbnails` setting is kept and
    // these images (rendered by the app, one per requested size) are embedded.
    bool thumbnails_enabled = false;
    std::vector<Slic3r::ThumbnailData> thumbnails;

    // Per object in model.objects: the object's volume index in its native
    // 3MF → index in the object now (-1 = removed). Empty = unchanged.
    std::vector<std::vector<int>> volume_maps;

    SlicerContext() {
        // Start from libslic3r's defaults so we have a valid config baseline;
        // presets and profiles are applied on top before every slice.
        config.apply(Slic3r::FullPrintConfig::defaults());

        // A generic 220×220×250 mm, 0.4 mm nozzle, 1.75 mm filament printer.
        config.set_key_value("printable_area",
            new Slic3r::ConfigOptionPoints({{0, 0}, {220, 0}, {220, 220}, {0, 220}}));
        config.set_key_value("printable_height", new Slic3r::ConfigOptionFloat(250));
        config.set_key_value("nozzle_diameter", new Slic3r::ConfigOptionFloats({0.4}));
        config.set_key_value("filament_diameter", new Slic3r::ConfigOptionFloats({1.75}));
        config.set_key_value("layer_height", new Slic3r::ConfigOptionFloat(0.2));
        config.set_key_value("enable_support", new Slic3r::ConfigOptionBool(false));
    }
};

// ── Helpers ──────────────────────────────────────────────────────────────────
static SlicerContext* CTX(SlicerHandle h) {
    return static_cast<SlicerContext*>(h);
}

static int set_err(SlicerContext* ctx, const std::exception& e) {
    ctx->last_error = e.what();
    return -1;
}

static int set_err(SlicerContext* ctx, const char* msg) {
    ctx->last_error = msg;
    return -1;
}

// Bed size / origin used to centre models (slicer_load_stl, slicer_add_stl),
// derived from the config's printable_area bounding box. Called whenever
// settings that may include printable_area are applied.
static void sync_bed_from_config(SlicerContext* ctx) {
    auto* shape = ctx->config.opt<Slic3r::ConfigOptionPoints>("printable_area");
    if (!shape || shape->values.size() < 3) return;
    double min_x = shape->values[0].x(), max_x = min_x;
    double min_y = shape->values[0].y(), max_y = min_y;
    for (const auto& p : shape->values) {
        min_x = std::min(min_x, p.x()); max_x = std::max(max_x, p.x());
        min_y = std::min(min_y, p.y()); max_y = std::max(max_y, p.y());
    }
    ctx->bed_x = max_x - min_x;
    ctx->bed_y = max_y - min_y;
    ctx->origin_at_center = min_x < 0 && min_y < 0;
}

// "#RRGGBB" → r, g, b (grey if unparseable).
static void parse_hex_colour(const std::string& hex, unsigned char rgb[3]) {
    unsigned int r = 128, g = 128, b = 128;
    if (hex.size() >= 7 && hex[0] == '#') std::sscanf(hex.c_str() + 1, "%02x%02x%02x", &r, &g, &b);
    rgb[0] = static_cast<unsigned char>(r); rgb[1] = static_cast<unsigned char>(g); rgb[2] = static_cast<unsigned char>(b);
}

// Sizes the per-filament and per-extruder settings, the filament → extruder
// map and the purge volumes to the printer's extruders and the session's
// filaments (PalmSlice tools), the way OrcaSlicer's GUI keeps them consistent
// (PresetBundle::full_fff_config; Plater's purge volumes from filament colours).
static void normalize_tools(Slic3r::DynamicPrintConfig& cfg) {
    auto* nozzles = cfg.option<Slic3r::ConfigOptionFloats>("nozzle_diameter");
    auto* diameters = cfg.option<Slic3r::ConfigOptionFloats>("filament_diameter");
    const size_t extruders = nozzles ? std::max<size_t>(1, nozzles->values.size()) : 1;
    // A tool changer has a filament per nozzle; a multi-material single nozzle
    // has as many filaments as are configured.
    const size_t filaments = std::max(extruders, diameters ? diameters->values.size() : size_t(1));

    if (extruders > 1) cfg.set_num_extruders(unsigned(extruders));
    // Per-filament vectors grow by repeating tool 1's value: the filament
    // preset's keys (print_config_def.filament_option_keys() is never filled)
    // plus the colour, which OrcaSlicer keeps in the project instead.
    auto grow = [&](const std::string& key) {
        if (auto* opt = dynamic_cast<Slic3r::ConfigOptionVectorBase*>(cfg.option(key, false)))
            if (!opt->empty() && opt->size() < filaments) opt->resize(filaments);
    };
    for (const std::string& key : Slic3r::Preset::filament_options()) grow(key);
    grow("filament_colour");

    // 0 = automatic width everywhere except OrcaSlicer's colour-painting
    // segmentation, which reads the outer wall width as is (vendor presets
    // always set it; bare configs and PrusaSlicer projects may not).
    if (auto* outer = cfg.option<Slic3r::ConfigOptionFloatOrPercent>("outer_wall_line_width");
        outer && outer->value == 0) {
        const auto* line = cfg.option<Slic3r::ConfigOptionFloatOrPercent>("line_width");
        const double nozzle = nozzles && !nozzles->values.empty() ? nozzles->values.front() : 0.4;
        const double width = line && line->value > 0 ? line->get_abs_value(nozzle)
                                                     : Slic3r::Flow::auto_extrusion_width(Slic3r::frExternalPerimeter, float(nozzle));
        cfg.set_key_value("outer_wall_line_width", new Slic3r::ConfigOptionFloatOrPercent(width, false));
    }

    // Filament settings with extruder variants (nozzle temperatures, …) are
    // looked up through filament_self_index: one variant per filament here.
    // (PresetBundle::full_fff_config builds it the same way.)
    if (auto* variants = cfg.option<Slic3r::ConfigOptionStrings>("filament_extruder_variant");
        variants && variants->values.size() == filaments) {
        auto& self = cfg.option<Slic3r::ConfigOptionInts>("filament_self_index", true)->values;
        self.resize(filaments);
        std::iota(self.begin(), self.end(), 1);
    }

    auto* map = cfg.option<Slic3r::ConfigOptionInts>("filament_map", true);
    map->values.resize(filaments, 1);
    for (int& e : map->values) e = std::clamp(e, 1, int(extruders));

    if (filaments < 2) return;
    auto* multiplier = cfg.option<Slic3r::ConfigOptionFloats>("flush_multiplier", true);
    if (multiplier->values.empty()) multiplier->values.push_back(1.);
    multiplier->values.resize(extruders, multiplier->values.front());
    auto* matrix = cfg.option<Slic3r::ConfigOptionFloats>("flush_volumes_matrix", true);
    if (matrix->values.size() == filaments * filaments * extruders) return;

    const auto* colours = cfg.option<Slic3r::ConfigOptionStrings>("filament_colour");
    const auto* datasets = cfg.option<Slic3r::ConfigOptionIntsNullable>("nozzle_flush_dataset");
    const auto* volumes = cfg.option<Slic3r::ConfigOptionFloatsNullable>("nozzle_volume");
    std::vector<std::array<unsigned char, 3>> rgb(filaments);
    for (size_t i = 0; i < filaments; ++i)
        parse_hex_colour(colours && i < colours->values.size() ? colours->values[i] : "", rgb[i].data());
    matrix->values.assign(filaments * filaments * extruders, 0.);
    for (size_t h = 0; h < extruders; ++h) {
        const int dataset = datasets && h < datasets->values.size() && !datasets->is_nil(h) ? datasets->values[h] : 0;
        const int min_volume = volumes && h < volumes->values.size() && !volumes->is_nil(h) ? int(volumes->values[h]) : 0;
        Slic3r::FlushVolCalculator calculator(min_volume, Slic3r::g_max_flush_volume, dataset);
        for (size_t from = 0; from < filaments; ++from)
            for (size_t to = 0; to < filaments; ++to)
                if (from != to)
                    matrix->values[h * filaments * filaments + from * filaments + to] = calculator.calc_flush_vol(
                        255, rgb[from][0], rgb[from][1], rgb[from][2], 255, rgb[to][0], rgb[to][1], rgb[to][2]);
    }
}

static void clamp_model_tools(Slic3r::Model& model, int filaments);
static Slic3r::FullSpectrum::VirtualExtruders slicer_mixes(const SlicerContext* ctx);

// OrcaSlicer drops a variable layer height profile whose first layer isn't
// exactly the first layer height (PrintObject::update_layer_height_profile),
// so an imported PrusaSlicer profile would be ignored whenever the printer's
// first layer differs. Start each profile on the first layer height in use.
static void fit_layer_height_profiles(Slic3r::Model& model, const Slic3r::DynamicPrintConfig& cfg) {
    for (Slic3r::ModelObject* obj : model.objects) {
        std::vector<coordf_t> heights = obj->layer_height_profile.get();
        if (heights.size() < 4) continue;
        const Slic3r::ConfigOption* own = obj->config.option("initial_layer_print_height");
        const double first = own ? own->getFloat() : cfg.opt_float("initial_layer_print_height");
        if (first > 0 && std::abs(heights[1] - first) > EPSILON) {
            heights[1] = first;
            obj->layer_height_profile.set(std::move(heights));
        }
    }
}

// ── Public C API ─────────────────────────────────────────────────────────────
extern "C" {

SlicerHandle slicer_create(void) {
    try {
        // OrcaSlicer's 3MF writer stages files in temporary_dir(); the app's
        // sandbox only allows its own tmp directory.
        if (Slic3r::temporary_dir().empty())
            if (const char* tmp = std::getenv("TMPDIR"))
                Slic3r::set_temporary_dir(tmp);
        return new SlicerContext();
    } catch (const std::exception& e) {
        return nullptr;
    }
}

void slicer_destroy(SlicerHandle handle) {
    delete CTX(handle);
}

int slicer_load_stl(SlicerHandle handle, const char* path) {
    auto ctx = CTX(handle);
    try {
        ctx->model = Slic3r::Model();
        ctx->volume_maps.clear();
        // load_stl fills the model in place; returns true on success
        bool ok = Slic3r::load_stl(path, &ctx->model, /*object_name=*/nullptr);
        if (!ok) return set_err(ctx, "load_stl returned false");

        // Add default instances so the model has geometry to slice
        ctx->model.add_default_instances();

        // Centre on the print bed using stored printer dimensions.
        double cx = ctx->origin_at_center ? 0.0 : ctx->bed_x / 2.0;
        double cy = ctx->origin_at_center ? 0.0 : ctx->bed_y / 2.0;
        Slic3r::Vec2d bed_centre(cx, cy);
        for (auto* obj : ctx->model.objects) {
            // center_around_origin() centers the mesh in X, Y, *and* Z.
            // After this call the mesh runs from -h/2 to +h/2 in Z with
            // all instance Z-offsets at 0, so we must shift each instance
            // up by h/2 to place the model bottom on the build plate (Z=0).
            obj->center_around_origin();
            Slic3r::BoundingBoxf3 bb = obj->raw_bounding_box();
            double shift_z = -bb.min.z();  // distance from mesh bottom to Z=0
            for (auto* inst : obj->instances) {
                Slic3r::Vec3d off = inst->get_offset();
                inst->set_offset(Slic3r::Vec3d(off.x(), off.y(), off.z() + shift_z));
            }
        }
        ctx->model.center_instances_around_point(bed_centre);

        return 0;
    } catch (const std::exception& e) {
        return set_err(ctx, e);
    }
}

int slicer_slice(SlicerHandle handle, float layer_height, int infill_percent) {
    return slicer_slice_with_progress(handle, layer_height, infill_percent,
                                      /*progress_cb=*/nullptr,
                                      /*user_ctx=*/nullptr);
}

int slicer_slice_with_progress(SlicerHandle handle,
                               float layer_height,
                               int   infill_percent,
                               void (*progress_cb)(float, void*),
                               void* user_ctx)
{
    auto ctx = CTX(handle);
    try {
        // layer_height and infill_percent are kept in the signature for compatibility
        // but the values are now owned by slicer_apply_settings. If no slice
        // config has been applied (legacy call path), fall back to the parameters.
        if (!ctx->slice_config_applied) {
            // A zero layer height would never finish slicing.
            if (layer_height > 0.0f)
                ctx->config.set_key_value("layer_height",
                    new Slic3r::ConfigOptionFloat(static_cast<double>(layer_height)));
            if (infill_percent >= 0)
                ctx->config.set_key_value("sparse_infill_density",
                    new Slic3r::ConfigOptionPercent(infill_percent));
        }

        ctx->print.clear();
        ctx->print.restart();  // clear any previous cancel flag

        if (progress_cb) {
            ctx->print.set_status_callback([=](const Slic3r::PrintBase::SlicingStatus& s) {
                progress_cb(static_cast<float>(s.percent), user_ctx);
            });
        } else {
            ctx->print.set_status_silent();
        }

        Slic3r::DynamicPrintConfig cfg_copy = ctx->config;
        // Vendor presets can enable desktop-only output features: post-processing
        // scripts (can't run on iOS) and embedded thumbnails (need the desktop
        // 3D renderer, or the app's images via slicer_set_thumbnail).
        cfg_copy.set_key_value("post_process", new Slic3r::ConfigOptionStrings());
        // The output path is always given; a project's filename template may
        // use PrusaSlicer placeholders OrcaSlicer can't evaluate.
        cfg_copy.set_key_value("filename_format", new Slic3r::ConfigOptionString("{input_filename_base}.gcode"));
        if (!ctx->thumbnails_enabled)
            cfg_copy.set_key_value("thumbnails", new Slic3r::ConfigOptionString(""));
        if (ctx->wipe_tower_placed) {
            cfg_copy.set_key_value("wipe_tower_x", new Slic3r::ConfigOptionFloats({ctx->wipe_tower_x}));
            cfg_copy.set_key_value("wipe_tower_y", new Slic3r::ConfigOptionFloats({ctx->wipe_tower_y}));
            cfg_copy.set_key_value("wipe_tower_rotation_angle", new Slic3r::ConfigOptionFloat(ctx->wipe_tower_rotation));
        }
        // Bambu Lab printers get BambuStudio-style G-code (OrcaSlicer's GUI
        // sets this from the vendor; same test as the G-code processor's).
        ctx->print.is_BBL_printer() = cfg_copy.has("printer_model") &&
            boost::starts_with(cfg_copy.opt_string("printer_model"), "Bambu Lab");
        normalize_tools(cfg_copy);
        ctx->model.virtual_extruders = slicer_mixes(ctx);
        clamp_model_tools(ctx->model, cfg_copy.option<Slic3r::ConfigOptionFloats>("filament_diameter")->values.size());
        fit_layer_height_profiles(ctx->model, cfg_copy);
        // One plate, at the bed origin.
        ctx->print.set_plate_origin(Slic3r::Vec3d::Zero());
        ctx->print.apply(ctx->model, std::move(cfg_copy));

        ctx->print.process();

        ctx->print.set_status_default();
        return 0;
    } catch (const Slic3r::CanceledException&) {
        ctx->print.set_status_default();
        ctx->last_error = "canceled";
        return -2;  // distinct from general errors (-1)
    } catch (const std::exception& e) {
        ctx->print.set_status_default();
        return set_err(ctx, e);
    }
}

int slicer_set_wipe_tower_position(SlicerHandle handle, float x, float y, float rotation_deg) {
    auto ctx = CTX(handle);
    ctx->wipe_tower_placed = true;
    ctx->wipe_tower_x = x;
    ctx->wipe_tower_y = y;
    ctx->wipe_tower_rotation = rotation_deg;
    return 0;
}

int slicer_wipe_tower_size(SlicerHandle handle, float* depth, float* brim_width, float* height) {
    auto ctx = CTX(handle);
    if (!ctx->print.is_step_done(Slic3r::psWipeTower) || !ctx->print.has_wipe_tower())
        return set_err(ctx, "no wipe tower");
    const Slic3r::WipeTowerData& data = ctx->print.wipe_tower_data();
    if (depth) *depth = data.depth;
    if (brim_width) *brim_width = data.brim_width;
    if (height) *height = data.height;
    return 0;
}

void slicer_cancel(SlicerHandle handle) {
    CTX(handle)->print.cancel();
}

// Filament use by purpose and cost, as slicer_print_stats describes: the
// numbers OrcaSlicer's preview legend shows.
static std::string print_stats_json(const Slic3r::PrintConfig& cfg,
                                    const Slic3r::PrintEstimatedStatistics& ps, unsigned changes) {
    using Mode = Slic3r::PrintEstimatedStatistics::ETimeMode;
    const double time = ps.modes[size_t(Mode::Normal)].time;
    auto volume = [](const std::map<size_t, double>& m, size_t id) {
        auto it = m.find(id);
        return it == m.end() ? 0.0 : it->second;
    };
    char buf[512];
    std::snprintf(buf, sizeof buf,
                  "{\"time\":%.1f,\"filament_changes\":%u,\"change_time\":%.1f,\"time_cost\":%.4f,\"filaments\":[",
                  time, changes,
                  double(ps.total_filament_load_time + ps.total_filament_unload_time + ps.total_tool_change_time),
                  cfg.time_cost.value * time / 3600.0);
    std::string out = buf;
    bool first = true;
    for ([[maybe_unused]] const auto& [id, total_volume] : ps.total_volumes_per_extruder) {
        const double density  = cfg.filament_density.get_at(id);
        const double diameter = cfg.filament_diameter.get_at(id);
        const double price    = cfg.filament_cost.get_at(id);
        auto grams = [&](double mm3) { return mm3 * density * 0.001; };
        // The total is the sum of the uses, as OrcaSlicer's legend shows it
        // (total_volumes_per_extruder books purges to the other filament).
        const double used = volume(ps.model_volumes_per_extruder, id) + volume(ps.support_volumes_per_extruder, id)
                          + volume(ps.wipe_tower_volumes_per_extruder, id) + volume(ps.flush_per_filament, id);
        const double total_g = grams(used);
        std::string colour = id < cfg.filament_colour.values.size() ? cfg.filament_colour.values[id] : "";
        colour.erase(std::remove_if(colour.begin(), colour.end(), [](char c) { return c == '"' || c == '\\'; }),
                     colour.end());
        std::snprintf(buf, sizeof buf,
                      "%s{\"index\":%zu,\"colour\":\"%s\",\"model_g\":%.4f,\"support_g\":%.4f,\"tower_g\":%.4f,"
                      "\"flush_g\":%.4f,\"total_g\":%.4f,\"total_m\":%.4f,\"price_per_kg\":%.4f,\"cost\":%.4f}",
                      first ? "" : ",", id, colour.c_str(),
                      grams(volume(ps.model_volumes_per_extruder, id)),
                      grams(volume(ps.support_volumes_per_extruder, id)),
                      grams(volume(ps.wipe_tower_volumes_per_extruder, id)),
                      grams(volume(ps.flush_per_filament, id)),
                      total_g,
                      diameter > 0 ? used / (M_PI * 0.25 * diameter * diameter) * 0.001 : 0.0,
                      price, total_g * price * 0.001);
        out += buf;
        first = false;
    }
    return out + "]}";
}

int slicer_export_gcode(SlicerHandle handle, const char* output_path) {
    auto ctx = CTX(handle);
    try {
        // Thumbnails: hand libslic3r the app's image for each requested size.
        Slic3r::ThumbnailsGeneratorCallback thumbnail_cb = nullptr;
        if (ctx->thumbnails_enabled && !ctx->thumbnails.empty())
            thumbnail_cb = [ctx](const Slic3r::ThumbnailsParams& params) {
                Slic3r::ThumbnailsList out;
                for (const Slic3r::Vec2d& size : params.sizes)
                    for (const Slic3r::ThumbnailData& t : ctx->thumbnails)
                        if (t.width == unsigned(size.x()) && t.height == unsigned(size.y())) out.push_back(t);
                return out;
            };
        // Print::export_gcode fills the result (path conflicts, the G-code
        // processor's statistics) without checking it for null.
        Slic3r::GCodeProcessorResult result;
        ctx->path_conflict.clear();
        ctx->print.export_gcode(std::string(output_path), &result, thumbnail_cb);
        if (const auto& c = result.conflict_result)
            ctx->path_conflict = c->_objName1 + "\n" + c->_objName2 + "\n" + std::to_string(c->_height);
        // Tool changes, as the G-code footer's "total filament change" counts them.
        ctx->print_stats = print_stats_json(ctx->print.config(), result.print_statistics,
                                            unsigned(ctx->print.print_statistics().total_toolchanges));
        return 0;
    } catch (const std::exception& e) {
        return set_err(ctx, e);
    }
}

const char* slicer_path_conflict(SlicerHandle handle) {
    return CTX(handle)->path_conflict.c_str();
}

const char* slicer_print_stats(SlicerHandle handle) {
    return CTX(handle)->print_stats.c_str();
}

void slicer_release_print(SlicerHandle handle) {
    auto ctx = CTX(handle);
    ctx->print.clear();
    ctx->model.clear_objects();
    ctx->volume_maps.clear();
}

// Writes `model` (with `config` as the project settings, if given) as an
// OrcaSlicer 3MF.
static bool store_orca_3mf(const char* path, Slic3r::Model& model, Slic3r::DynamicPrintConfig* config,
                           Slic3r::ThumbnailData* thumbnail = nullptr) {
    Slic3r::StoreParams params;
    params.path = path;
    params.model = &model;
    params.config = config;
    params.strategy = Slic3r::SaveStrategy(int(Slic3r::SaveStrategy::Zip64) | int(Slic3r::SaveStrategy::Silence));
    if (thumbnail) params.thumbnail_data.push_back(thumbnail);
    return Slic3r::store_bbs_3mf(params);
}

// Reads an OrcaSlicer / BambuStudio / PrusaSlicer 3MF (geometry, per-object
// settings, painting). `config` receives the file's project settings.
// PrusaSlicer settings are renamed to OrcaSlicer's as they're read
// (PrusaSettingsImport in the iOS patch).
static bool load_orca_3mf(const char* path, Slic3r::Model& model, Slic3r::DynamicPrintConfig& config) {
    Slic3r::ConfigSubstitutionContext subst(Slic3r::ForwardCompatibilitySubstitutionRule::EnableSilent);
    // PrusaSlicer 3MFs keep parts / modifiers in Slic3r_PE_model.config,
    // which only OrcaSlicer's PrusaSlicer reader understands.
    if (Slic3r::PrusaFileParser().check_3mf_from_prusa(path))
        return Slic3r::load_3mf(path, config, subst, &model, /*check_version=*/false);
    Slic3r::PlateDataPtrs plates;
    std::vector<Slic3r::Preset*> project_presets;
    bool is_bbl = false, is_orca = false;
    Slic3r::Semver version;
    const auto strategy = Slic3r::LoadStrategy::LoadModel | Slic3r::LoadStrategy::LoadConfig;
    const bool ok = Slic3r::load_bbs_3mf(path, &config, &subst, &model, &plates, &project_presets,
                                         &is_bbl, &is_orca, &version, nullptr, strategy);
    Slic3r::release_PlateData_list(plates);
    for (Slic3r::Preset* p : project_presets) delete p;
    return ok;
}

int slicer_export_project_3mf(SlicerHandle handle, const char* path) {
    auto ctx = CTX(handle);
    try {
        // Objects, parts, painting and tools are already in libslic3r's
        // numbering, so desktop OrcaSlicer opens the same setup.
        Slic3r::Model model = ctx->model;
        Slic3r::ThumbnailData* thumbnail = nullptr;
        for (auto& t : ctx->thumbnails)
            if (!thumbnail || t.width > thumbnail->width) thumbnail = &t;
        if (!store_orca_3mf(path, model, &ctx->config, thumbnail))
            return set_err(ctx, "Could not write the project");
        return 0;
    } catch (const std::exception& e) {
        return set_err(ctx, e);
    }
}

int slicer_enable_thumbnails(SlicerHandle handle, int enabled) {
    auto ctx = CTX(handle);
    ctx->thumbnails_enabled = enabled != 0;
    if (!ctx->thumbnails_enabled) ctx->thumbnails.clear();
    return 0;
}

// "48x48/PNG, 300x300/PNG" → {48, 48}, {300, 300} (the `thumbnails` format;
// libslic3r's own parser isn't usable from the bridge, see slicer_thumbnail_sizes).
static std::vector<std::pair<int, int>> parse_thumbnail_sizes(const std::string& value) {
    std::vector<std::pair<int, int>> sizes;
    std::istringstream in(value);
    std::string item;
    while (std::getline(in, item, ',')) {
        int w = 0, h = 0;
        if (std::sscanf(item.c_str(), " %dx%d", &w, &h) == 2 && w > 0 && w < 1000 && h > 0 && h < 1000)
            sizes.emplace_back(w, h);
    }
    return sizes;
}

int slicer_thumbnail_sizes(SlicerHandle handle, int* out_sizes, int max_sizes) {
    auto ctx = CTX(handle);
    const std::string value = ctx->config.has("thumbnails") ? ctx->config.opt_string("thumbnails") : "";
    const auto sizes = parse_thumbnail_sizes(value);
    for (int i = 0; out_sizes && i < std::min(int(sizes.size()), max_sizes); ++i) {
        out_sizes[2 * i] = sizes[i].first;
        out_sizes[2 * i + 1] = sizes[i].second;
    }
    return int(sizes.size());
}

int slicer_set_thumbnail(SlicerHandle handle, int width, int height, const unsigned char* rgba) {
    auto ctx = CTX(handle);
    if (width <= 0 || height <= 0 || !rgba) return set_err(ctx, "bad thumbnail");
    Slic3r::ThumbnailData data;
    data.set(unsigned(width), unsigned(height));
    // libslic3r's PNG writer expects rows bottom-up (OpenGL order); the app's are top-down.
    const size_t row = size_t(width) * 4;
    for (int y = 0; y < height; ++y)
        std::memcpy(data.pixels.data() + size_t(height - 1 - y) * row, rgba + size_t(y) * row, row);
    ctx->thumbnails.erase(std::remove_if(ctx->thumbnails.begin(), ctx->thumbnails.end(),
        [&](const Slic3r::ThumbnailData& t) { return t.width == data.width && t.height == data.height; }),
        ctx->thumbnails.end());
    ctx->thumbnails.push_back(std::move(data));
    return 0;
}

const char* slicer_last_error(SlicerHandle handle) {
    return CTX(handle)->last_error.c_str();
}

int slicer_check_slice_config(SlicerHandle handle, const SlicerSliceConfig* cfg,
                              SlicerSliceConfigCheck* out) {
    auto ctx = CTX(handle);
    if (!cfg || !out) return set_err(ctx, "null config/output pointer");
    *out = SlicerSliceConfigCheck{};
    try {
        if (ctx->model.objects.empty()) return set_err(ctx, "no model loaded");

        double nozzle_d = 0.4;
        if (auto* opt = ctx->config.opt<Slic3r::ConfigOptionFloats>("nozzle_diameter")) {
            if (!opt->values.empty() && opt->values[0] > 0.0) nozzle_d = opt->values[0];
        }

        double layer_h = static_cast<double>(cfg->layer_height);
        if (layer_h <= 0.0) layer_h = 0.2;

        // Smallest object's footprint/height across the plate — conservative:
        // any one object thinner than the others still needs to print cleanly.
        // instance_bounding_box(0, /*dont_translate=*/true) reflects the
        // instance's actual scale/rotation, unlike raw_bounding_box().
        double min_xy = std::numeric_limits<double>::max();
        double min_z  = std::numeric_limits<double>::max();
        for (auto* obj : ctx->model.objects) {
            if (obj->instances.empty()) continue;
            Slic3r::BoundingBoxf3 bb = obj->instance_bounding_box(0, true);
            Slic3r::Vec3d size = bb.size();
            min_xy = std::min({min_xy, size.x(), size.y()});
            min_z  = std::min(min_z, size.z());
        }
        if (min_xy == std::numeric_limits<double>::max()) return set_err(ctx, "no placed instances");

        // Each wall loop is ~1 nozzle width; loops nest in from both sides of
        // the thinnest span, so more than roughly half that span overlaps.
        int max_walls = std::max(1, static_cast<int>(std::floor(min_xy / (2.0 * nozzle_d))));

        // Reserve at least half the model's layers for interior/infill so
        // top+bottom solid regions can't consume the whole part between them.
        int total_layers = static_cast<int>(std::floor(min_z / layer_h));
        int max_each = std::max(1, total_layers / 4);

        out->suggested_wall_count    = std::min(cfg->wall_count, max_walls);
        out->suggested_top_layers    = std::min(cfg->top_layers, max_each);
        out->suggested_bottom_layers = std::min(cfg->bottom_layers, max_each);

        out->needs_warning =
            (out->suggested_wall_count    != cfg->wall_count) ||
            (out->suggested_top_layers    != cfg->top_layers) ||
            (out->suggested_bottom_layers != cfg->bottom_layers);

        return 0;
    } catch (const std::exception& e) {
        return set_err(ctx, e);
    }
}

int slicer_set_model_transform(SlicerHandle handle,
                               const SlicerModelTransform* t)
{
    auto ctx = CTX(handle);
    if (!t) return set_err(ctx, "null model transform");
    try {
        double bed_cx = ctx->origin_at_center ? 0.0 : ctx->bed_x / 2.0;
        double bed_cy = ctx->origin_at_center ? 0.0 : ctx->bed_y / 2.0;

        // Scale mapping: SceneKit(X,Y,Z) → STL(X, -Z_sign, Y_stl)
        //   SceneKit X → STL X: scale_x unchanged
        //   SceneKit Y → STL Z: scale_y becomes STL Z scale
        //   SceneKit Z → STL Y: scale_z becomes STL Y scale
        double sx = static_cast<double>(t->scale_x);  // STL X scale
        double sy = static_cast<double>(t->scale_z);  // STL Y scale  (SceneKit Z → STL Y)
        double sz = static_cast<double>(t->scale_y);  // STL Z scale  (SceneKit Y → STL Z)

        // Convert SceneKit ZYX Euler angles (degrees) to Slic3r ZYX Euler angles (radians)
        // in STL/Slic3r space via: R_stl = Rx(+90°) * R_sc * Rx(-90°)
        // where Rx(+90°) converts from STL space to SceneKit space.
        double rx_d = static_cast<double>(t->rot_x_deg) * M_PI / 180.0;
        double ry_d = static_cast<double>(t->rot_y_deg) * M_PI / 180.0;
        double rz_d = static_cast<double>(t->rot_z_deg) * M_PI / 180.0;

        double cxr = cos(rx_d), sxr = sin(rx_d);
        double cyr = cos(ry_d), syr = sin(ry_d);
        double czr = cos(rz_d), szr = sin(rz_d);

        // R_stl elements (row 0, 1, 2 of Rx(+90°) * Rz(rz)*Ry(ry)*Rx(rx) * Rx(-90°)):
        // Row 2 is needed for min-Z computation and Euler extraction.
        double stl00 = czr * cyr;
        double stl10 = syr;
        double stl20 = szr * cyr;
        double stl21 = czr * sxr - szr * syr * cxr;
        double stl22 = szr * syr * sxr + czr * cxr;
        // For gimbal lock branch:
        double stl01 = -(czr * syr * cxr + szr * sxr);
        double stl11 = cyr * cxr;

        // Extract ZYX Euler angles for Slic3r from the R_stl matrix.
        // R_stl = Rz(ez)*Ry(ey)*Rx(ex) → R[2][0] = -sin(ey)
        double sin_ey = -stl20;
        double rx_stl, ry_stl, rz_stl;
        if (std::abs(sin_ey) < 0.9999) {
            ry_stl = std::asin(sin_ey);
            rx_stl = std::atan2(stl21, stl22);
            rz_stl = std::atan2(stl10, stl00);
        } else {
            // Gimbal lock (ry ≈ ±90°): set rz=0 and recover rx from remaining DOF.
            ry_stl = (sin_ey > 0) ? M_PI / 2.0 : -M_PI / 2.0;
            rx_stl = std::atan2(-stl01, stl11);
            rz_stl = 0.0;
        }

        // Compute min world Z of the scaled+rotated mesh (for drop-to-bed).
        // Transform all 8 AABB corners of the raw (centered) mesh, apply scale
        // then rotation, keep track of the minimum Z component.
        double min_z = std::numeric_limits<double>::max();
        for (auto* obj : ctx->model.objects) {
            Slic3r::BoundingBoxf3 raw_bb = obj->raw_bounding_box();
            double xs[2] = { raw_bb.min.x() * sx, raw_bb.max.x() * sx };
            double ys[2] = { raw_bb.min.y() * sy, raw_bb.max.y() * sy };
            double zs[2] = { raw_bb.min.z() * sz, raw_bb.max.z() * sz };
            for (int i = 0; i < 2; ++i)
            for (int j = 0; j < 2; ++j)
            for (int k = 0; k < 2; ++k) {
                double wz = stl20 * xs[i] + stl21 * ys[j] + stl22 * zs[k];
                if (wz < min_z) min_z = wz;
            }
        }
        double drop_z = (min_z < std::numeric_limits<double>::max()) ? -min_z : 0.0;

        // Apply transform to every instance of every object.
        // pos_x_mm: SceneKit X → STL X (same direction)
        // pos_z_mm: SceneKit Z → -STL Y (sign-flipped depth axis)
        double inst_x = bed_cx + static_cast<double>(t->pos_x_mm);
        double inst_y = bed_cy - static_cast<double>(t->pos_z_mm);
        double inst_z = drop_z;   // model bottom placed at Z=0

        for (auto* obj : ctx->model.objects) {
            for (auto* inst : obj->instances) {
                inst->set_scaling_factor(Slic3r::Vec3d(sx, sy, sz));
                inst->set_rotation(Slic3r::Vec3d(rx_stl, ry_stl, rz_stl));
                inst->set_offset(Slic3r::Vec3d(inst_x, inst_y, inst_z));
            }
            // The box corners above reach below a rotated mesh that isn't a
            // box; put the mesh itself on the bed.
            obj->ensure_on_bed();
        }
        return 0;
    } catch (const std::exception& e) {
        return set_err(ctx, e);
    }
}

// ── Multi-model helpers ───────────────────────────────────────────────────────

// Shared transform math extracted into a free function so both
// slicer_set_model_transform and slicer_set_object_transform can use it.
static int apply_transform_to_object(SlicerContext* ctx,
                                     Slic3r::ModelObject* obj,
                                     const SlicerModelTransform* t)
{
    double bed_cx = ctx->origin_at_center ? 0.0 : ctx->bed_x / 2.0;
    double bed_cy = ctx->origin_at_center ? 0.0 : ctx->bed_y / 2.0;

    double sx = static_cast<double>(t->scale_x);
    double sy = static_cast<double>(t->scale_z);
    double sz = static_cast<double>(t->scale_y);

    double rx_d = static_cast<double>(t->rot_x_deg) * M_PI / 180.0;
    double ry_d = static_cast<double>(t->rot_y_deg) * M_PI / 180.0;
    double rz_d = static_cast<double>(t->rot_z_deg) * M_PI / 180.0;

    double cxr = cos(rx_d), sxr = sin(rx_d);
    double cyr = cos(ry_d), syr = sin(ry_d);
    double czr = cos(rz_d), szr = sin(rz_d);

    double stl00 = czr * cyr;
    double stl10 = syr;
    double stl20 = szr * cyr;
    double stl21 = czr * sxr - szr * syr * cxr;
    double stl22 = szr * syr * sxr + czr * cxr;
    double stl01 = -(czr * syr * cxr + szr * sxr);
    double stl11 = cyr * cxr;

    double sin_ey = -stl20;
    double rx_stl, ry_stl, rz_stl;
    if (std::abs(sin_ey) < 0.9999) {
        ry_stl = std::asin(sin_ey);
        rx_stl = std::atan2(stl21, stl22);
        rz_stl = std::atan2(stl10, stl00);
    } else {
        ry_stl = (sin_ey > 0) ? M_PI / 2.0 : -M_PI / 2.0;
        rx_stl = std::atan2(-stl01, stl11);
        rz_stl = 0.0;
    }

    double min_z = std::numeric_limits<double>::max();
    Slic3r::BoundingBoxf3 raw_bb = obj->raw_bounding_box();
    double xs[2] = { raw_bb.min.x() * sx, raw_bb.max.x() * sx };
    double ys[2] = { raw_bb.min.y() * sy, raw_bb.max.y() * sy };
    double zs[2] = { raw_bb.min.z() * sz, raw_bb.max.z() * sz };
    for (int i = 0; i < 2; ++i)
    for (int j = 0; j < 2; ++j)
    for (int k = 0; k < 2; ++k) {
        double wz = stl20 * xs[i] + stl21 * ys[j] + stl22 * zs[k];
        if (wz < min_z) min_z = wz;
    }
    double drop_z = (min_z < std::numeric_limits<double>::max()) ? -min_z : 0.0;

    double inst_x = bed_cx + static_cast<double>(t->pos_x_mm);
    double inst_y = bed_cy - static_cast<double>(t->pos_z_mm);
    double inst_z = drop_z;

    for (auto* inst : obj->instances) {
        inst->set_scaling_factor(Slic3r::Vec3d(sx, sy, sz));
        inst->set_rotation(Slic3r::Vec3d(rx_stl, ry_stl, rz_stl));
        inst->set_offset(Slic3r::Vec3d(inst_x, inst_y, inst_z));
    }
    // The box corners above reach below a rotated mesh that isn't a box;
    // put the mesh itself on the bed.
    obj->ensure_on_bed();
    return 0;
}

int slicer_add_stl(SlicerHandle handle, const char* path) {
    auto ctx = CTX(handle);
    try {
        // Load into a temporary model so we don't disturb existing objects.
        Slic3r::Model temp;
        bool ok = Slic3r::load_stl(path, &temp, /*object_name=*/nullptr);
        if (!ok) return set_err(ctx, "load_stl returned false");
        if (temp.objects.empty()) return set_err(ctx, "STL contains no objects");

        temp.add_default_instances();

        double cx = ctx->origin_at_center ? 0.0 : ctx->bed_x / 2.0;
        double cy = ctx->origin_at_center ? 0.0 : ctx->bed_y / 2.0;

        int start_idx = static_cast<int>(ctx->model.objects.size());

        for (auto* src : temp.objects) {
            auto* obj = ctx->model.add_object(*src);
            obj->center_around_origin();
            Slic3r::BoundingBoxf3 bb = obj->raw_bounding_box();
            double shift_z = -bb.min.z();
            for (auto* inst : obj->instances) {
                Slic3r::Vec3d off = inst->get_offset();
                inst->set_offset(Slic3r::Vec3d(cx, cy, off.z() + shift_z));
            }
        }

        return start_idx;
    } catch (const std::exception& e) {
        return set_err(ctx, e);
    }
}

int slicer_set_object_transform(SlicerHandle handle, int object_index,
                                const SlicerModelTransform* t)
{
    auto ctx = CTX(handle);
    if (!t) return set_err(ctx, "null model transform");
    int n = static_cast<int>(ctx->model.objects.size());
    if (object_index < 0 || object_index >= n)
        return set_err(ctx, "object_index out of range");
    try {
        return apply_transform_to_object(ctx, ctx->model.objects[object_index], t);
    } catch (const std::exception& e) {
        return set_err(ctx, e);
    }
}

int slicer_add_object_instance(SlicerHandle handle, int object_index, float pos_x_mm, float pos_z_mm) {
    auto ctx = CTX(handle);
    if (object_index < 0 || object_index >= static_cast<int>(ctx->model.objects.size()))
        return set_err(ctx, "object index out of range");
    try {
        Slic3r::ModelObject* obj = ctx->model.objects[object_index];
        if (obj->instances.empty()) return set_err(ctx, "object has no instance");
        const double bed_cx = ctx->origin_at_center ? 0.0 : ctx->bed_x / 2.0;
        const double bed_cy = ctx->origin_at_center ? 0.0 : ctx->bed_y / 2.0;
        // Same rotation, scale and height as the first copy; its own XY.
        const Slic3r::ModelInstance* first = obj->instances.front();
        Slic3r::ModelInstance* inst = obj->add_instance(*first);
        const Slic3r::Vec3d from = first->get_offset();
        inst->set_offset(Slic3r::Vec3d(bed_cx + pos_x_mm, bed_cy - pos_z_mm, from.z()));
        return 0;
    } catch (const std::exception& e) {
        return set_err(ctx, e);
    }
}

} // extern "C"

// Object settings text (slicer_imported_object_settings format).
static std::string format_number(double v) {
    char buf[32];
    std::snprintf(buf, sizeof buf, "%.10g", v);
    return buf;
}

static void append_config(std::string& out, const Slic3r::DynamicPrintConfig& cfg) {
    for (const std::string& key : cfg.keys())
        out += key + " = " + cfg.opt_serialize(key) + "\n";
}

static std::string object_file_settings(const Slic3r::ModelObject& obj) {
    std::string out;
    append_config(out, obj.config.get());
    for (const auto& [range, config] : obj.layer_config_ranges) {
        out += "[range " + format_number(range.first) + " " + format_number(range.second) + "]\n";
        append_config(out, config.get());
    }
    const std::vector<coordf_t>& heights = obj.layer_height_profile.get();
    if (!heights.empty()) {
        out += "[layer_heights]\n";
        for (size_t i = 0; i < heights.size(); ++i)
            out += (i ? ";" : "") + format_number(heights[i]);
        out += "\n";
    }
    return out;
}

// ── Tools and mixes ──────────────────────────────────────────────────────────
// PalmSlice tool numbers are OrcaSlicer filament numbers (1-based); mix n
// (SLICER_MIX_BASE + n) is the virtual extruder numbered right after the
// physical filaments, as PrusaSlicer's Full Spectrum numbers them.
namespace FS = Slic3r::FullSpectrum;
using ToolRemap = std::map<int, int>;

// Painted states OrcaSlicer can store: none + 16 filaments. Tools paint as
// themselves; mix n paints as state 17 - n (16, 15, …), so painting holds up
// to 8 tools and 8 mixes whatever the printer.
static constexpr int k_paint_states = int(Slic3r::EnforcerBlockerType::ExtruderMax) + 1;
static constexpr int k_paint_mixes = 8;

// PalmSlice tool → painted state (-1: can't be painted).
static int paint_state(int tool) {
    if (tool <= SLICER_MIX_BASE) return tool < k_paint_states - k_paint_mixes ? tool : -1;
    const int n = tool - SLICER_MIX_BASE;
    return n <= k_paint_mixes ? k_paint_states - n : -1;
}

// Painted state → PalmSlice tool.
static int paint_tool(int state) {
    return state >= k_paint_states - k_paint_mixes ? SLICER_MIX_BASE + (k_paint_states - state) : state;
}

// Filaments the printer is set up for (one per tool): one per nozzle on a
// tool changer, or as many as are configured for a single nozzle.
static int physical_count(const SlicerContext* ctx) {
    auto* nd = ctx->config.option<Slic3r::ConfigOptionFloats>("nozzle_diameter");
    auto* fd = ctx->config.option<Slic3r::ConfigOptionFloats>("filament_diameter");
    return std::max({1, nd ? int(nd->values.size()) : 1, fd ? int(fd->values.size()) : 1});
}

static bool has_mix(const SlicerContext* ctx, int tool) {
    return std::any_of(ctx->mixes.begin(), ctx->mixes.end(), [tool](const FS::VirtualExtruder& m) { return int(m.id) == tool; });
}

// PalmSlice tool number → libslic3r's: a mix follows the physical filaments
// (0, the object's filament, if it isn't in the session or beyond what
// OrcaSlicer can number).
static int to_slicer_tool(const SlicerContext* ctx, int tool) {
    if (tool <= SLICER_MIX_BASE) return tool;
    const int id = physical_count(ctx) + (tool - SLICER_MIX_BASE);
    return has_mix(ctx, tool) && id < k_paint_states ? id : 0;
}

// PalmSlice → libslic3r numbers for every mix number.
static ToolRemap mixes_to_slicer(const SlicerContext* ctx) {
    ToolRemap remap;
    for (int id = SLICER_MIX_BASE + 1; id < 2 * SLICER_MIX_BASE; ++id) remap[id] = to_slicer_tool(ctx, id);
    return remap;
}

// The session's mixes in libslic3r numbering, for Print::apply.
static FS::VirtualExtruders slicer_mixes(const SlicerContext* ctx) {
    FS::VirtualExtruders out;
    for (FS::VirtualExtruder m : ctx->mixes)
        if (const int id = to_slicer_tool(ctx, int(m.id)); id > 0) {
            m.id = static_cast<unsigned>(id);
            out.push_back(m);
        }
    return out;
}

static void update_mixes_json(SlicerContext* ctx) {
    ctx->mixes_json = FS::serialize_virtual_extruders_to_json({}, ctx->mixes);
}

// Settings holding a filament number (the *_filament_id ones: 0 = inherit).
static const char* const k_tool_keys[] = {
    "extruder", "outer_wall_filament_id", "inner_wall_filament_id", "sparse_infill_filament_id",
    "internal_solid_filament_id", "top_surface_filament_id", "bottom_surface_filament_id" };

static void remap_config_tools(Slic3r::ModelConfig& cfg, const ToolRemap& remap) {
    for (const char* key : k_tool_keys)
        if (const Slic3r::ConfigOption* opt = cfg.option(key)) {
            auto it = remap.find(opt->getInt());
            if (it != remap.end()) cfg.set(key, it->second);
        }
}

// Repaints a volume's colour painting with states[old state].
static void remap_paint(Slic3r::ModelVolume& vol, const Slic3r::EnforcerBlockerStateMap& states) {
    if (!vol.is_mm_painted()) return;
    const auto& used = vol.mmu_segmentation_facets.get_data().used_states;
    bool changes = false;
    for (size_t st = 1; st < used.size() && st < states.size(); ++st)
        changes |= used[st] && states[st] != Slic3r::EnforcerBlockerType(st);
    if (!changes) return;
    Slic3r::TriangleSelector selector(vol.mesh());
    selector.deserialize(vol.mmu_segmentation_facets.get_data(), false);
    selector.remap_triangle_state(states);
    vol.mmu_segmentation_facets.set(selector);
}

// Painted mixes (states 17 - n) → their libslic3r numbers.
static void paint_mixes_to_slicer(const SlicerContext* ctx, Slic3r::ModelVolume& vol) {
    Slic3r::EnforcerBlockerStateMap states;
    for (size_t st = 0; st < states.size(); ++st) {
        const int tool = paint_tool(int(st));
        states[st] = Slic3r::EnforcerBlockerType(tool > SLICER_MIX_BASE ? to_slicer_tool(ctx, tool) : int(st));
    }
    remap_paint(vol, states);
}

// Renumbers every tool an object stores (settings, height ranges, parts,
// painting) from a file's numbering to PalmSlice's.
static void remap_object_tools(Slic3r::ModelObject& obj, const ToolRemap& remap) {
    if (remap.empty()) return;
    Slic3r::EnforcerBlockerStateMap states;
    for (size_t st = 0; st < states.size(); ++st) {
        auto it = remap.find(int(st));
        const int to = it == remap.end() ? int(st) : paint_state(it->second);
        states[st] = to < 0 ? Slic3r::EnforcerBlockerType::NONE : Slic3r::EnforcerBlockerType(to);
    }
    remap_config_tools(obj.config, remap);
    for (auto& [range, config] : obj.layer_config_ranges) remap_config_tools(config, remap);
    for (Slic3r::ModelVolume* vol : obj.volumes) {
        remap_config_tools(vol->config, remap);
        remap_paint(*vol, states);
    }
}

// The same mix, ignoring its number and display colour.
static bool same_mix(const FS::VirtualExtruder& a, const FS::VirtualExtruder& b) {
    return a.components == b.components && a.gradient == b.gradient;
}

// Adds a file's mixes (libslic3r numbering) to the session's, reusing an
// identical mix's number. Returns file number → PalmSlice number.
static ToolRemap merge_file_mixes(SlicerContext* ctx, const FS::VirtualExtruders& file_mixes) {
    ToolRemap remap;
    for (const FS::VirtualExtruder& mix : file_mixes) {
        auto it = std::find_if(ctx->mixes.begin(), ctx->mixes.end(),
                               [&](const FS::VirtualExtruder& m) { return same_mix(m, mix); });
        unsigned id;
        if (it != ctx->mixes.end()) {
            id = it->id;
        } else {
            id = SLICER_MIX_BASE;
            for (const auto& m : ctx->mixes) id = std::max(id, m.id);
            ++id;
            if (paint_state(int(id)) < 0) continue;  // too many mixes
            FS::VirtualExtruder added = mix;
            added.id = id;
            ctx->mixes.push_back(added);
        }
        remap[int(mix.id)] = int(id);
    }
    update_mixes_json(ctx);
    return remap;
}

// Tools above the printer's filament count that aren't one of the print's
// mixes (e.g. an unknown tool in an imported file) fall back to the object's
// filament: OrcaSlicer would index past its per-filament settings. Covers
// settings, height ranges, parts and painted areas.
static void clamp_model_tools(Slic3r::Model& model, int filaments) {
    auto valid = [&](int t) {
        return t <= filaments || std::any_of(model.virtual_extruders.begin(), model.virtual_extruders.end(),
                                              [t](const FS::VirtualExtruder& m) { return int(m.id) == t; });
    };
    ToolRemap remap;
    for (int t = filaments + 1; t < 2 * SLICER_MIX_BASE; ++t)
        if (!valid(t)) remap[t] = 0;
    Slic3r::EnforcerBlockerStateMap states;
    for (size_t i = 0; i < states.size(); ++i)
        states[i] = valid(int(i)) ? Slic3r::EnforcerBlockerType(i) : Slic3r::EnforcerBlockerType::NONE;
    for (Slic3r::ModelObject* obj : model.objects) {
        remap_config_tools(obj->config, remap);
        for (auto& [range, config] : obj->layer_config_ranges) remap_config_tools(config, remap);
        for (Slic3r::ModelVolume* vol : obj->volumes) {
            remap_config_tools(vol->config, remap);
            remap_paint(*vol, states);
        }
    }
}

// libslic3r reads layer_height from every height range (PrusaSlicer always
// stores one); give ranges without it the object's or the print's.
static void ensure_range_layer_heights(const SlicerContext* ctx, Slic3r::ModelObject& obj) {
    const Slic3r::ConfigOption* own = obj.config.option("layer_height");
    const Slic3r::ConfigOption* print = ctx->config.option("layer_height");
    const double height = own ? own->getFloat() : print ? print->getFloat() : 0.2;
    for (auto& [range, config] : obj.layer_config_ranges)
        if (!config.has("layer_height")) config.set("layer_height", height);
}

static int config_tool(const Slic3r::ModelConfig& cfg) {
    const Slic3r::ConfigOption* opt = cfg.option("extruder");
    return opt ? opt->getInt() : 0;
}

extern "C" {

int slicer_set_virtual_extruders(SlicerHandle handle, const char* json) {
    auto ctx = CTX(handle);
    try {
        FS::VirtualExtruders mixes;
        if (json && *json) {
            FS::FullSpectrumConfig parsed = FS::deserialize_virtual_extruders_from_json(json);
            for (const auto& m : FS::normalize_virtual_extruders(parsed.virtual_extruders))
                if (m.id > SLICER_MIX_BASE) mixes.push_back(m);
        }
        ctx->mixes = std::move(mixes);
        update_mixes_json(ctx);
        return 0;
    } catch (const std::exception& e) {
        return set_err(ctx, e);
    }
}

const char* slicer_get_virtual_extruders(SlicerHandle handle) {
    auto ctx = CTX(handle);
    if (ctx->mixes_json.empty()) update_mixes_json(ctx);
    return ctx->mixes_json.c_str();
}

int slicer_mix_color(const char* parts, char* out_hex, int len) {
    if (!parts || !out_hex || len < 8) return -1;
    try {
        std::vector<prusa_fdm_mixer::Part> mix;
        std::istringstream in(parts);
        std::string item;
        while (std::getline(in, item, ';')) {
            size_t colon = item.find(':');
            if (colon == std::string::npos) return -1;
            const double ratio = std::stod(item.substr(colon + 1));
            if (ratio > 0) mix.push_back({item.substr(0, colon), ratio});
        }
        if (mix.empty()) return -1;
        double total = 0;
        for (const auto& part : mix) total += part.ratio;
        for (auto& part : mix) part.ratio /= total;
        const std::string hex = mix.size() == 1 ? mix.front().hex : prusa_fdm_mixer::mix(mix);
        std::snprintf(out_hex, size_t(len), "%s", hex.c_str());
        return 0;
    } catch (const std::exception&) {
        return -1;
    }
}

int slicer_color_delta_e(const char* hex_a, const char* hex_b, double* out) {
    if (!hex_a || !hex_b || !out) return -1;
    try {
        using namespace prusa_fdm_mixer;
        *out = delta_e_2000(rgb_to_lab(hex_to_rgb(hex_a)), rgb_to_lab(hex_to_rgb(hex_b)));
        return 0;
    } catch (const std::exception&) {
        return -1;
    }
}

int slicer_import_model_file(SlicerHandle handle, const char* path, const char* out_dir) {
    auto ctx = CTX(handle);
    try {
        ctx->imported.clear();
        ctx->imported_project.clear();
        // Model::read_from_file dispatches on the extension: 3MF (OrcaSlicer,
        // BambuStudio, PrusaSlicer), STL, OBJ, AMF, DRC, and via ModelIO PLY / USD.
        Slic3r::Model model;
        Slic3r::DynamicPrintConfig file_config;  // the file's project settings
        if (std::string(path).size() > 4 &&
            strcasecmp(path + std::strlen(path) - 4, ".3mf") == 0) {
            if (!load_orca_3mf(path, model, file_config))
                return set_err(ctx, "Could not read .3mf file");
        } else {
            model = Slic3r::Model::read_from_file(path, &file_config);
        }
        model.add_default_instances();

        // The file's mixes join the session's; its tools get PalmSlice numbers.
        const ToolRemap mix_remap = merge_file_mixes(ctx, model.virtual_extruders);

        // One single-instance object per object instance, with the instance's
        // rotation / scale / mirroring folded into the volumes. Translation is
        // kept separately as an offset from the file's overall centre so
        // arranged plates keep their layout.
        struct Native {
            Slic3r::Model model;           // holds the one object
            Slic3r::TriangleMesh parts;    // printable parts, merged in volume order
            Slic3r::Vec3d centre;
            SlicerContext::ImportedObject info;
        };
        std::vector<std::unique_ptr<Native>> natives;
        Slic3r::BoundingBoxf3 all_bb;
        for (const auto* obj : model.objects) {
            if (obj->raw_mesh().empty()) continue;
            int n_inst = static_cast<int>(obj->instances.size());
            for (int i = 0; i < n_inst; ++i) {
                const auto* inst = obj->instances[i];
                auto n = std::make_unique<Native>();
                Slic3r::ModelObject* o = n->model.add_object(*obj);
                for (int k = n_inst - 1; k >= 0; --k)
                    if (k != i) o->delete_instance(k);
                const Slic3r::Transform3d inst_matrix = inst->get_matrix_no_offset();
                for (Slic3r::ModelVolume* vol : o->volumes)
                    vol->set_transformation(Slic3r::Geometry::Transformation(inst_matrix * vol->get_matrix()));
                o->instances.front()->set_transformation(Slic3r::Geometry::Transformation());
                remap_object_tools(*o, mix_remap);

                auto& info = n->info;
                info.extruder = config_tool(o->config);
                o->config.erase("extruder");   // the object's tool is reported separately
                for (const Slic3r::ModelVolume* vol : o->volumes) {
                    SlicerContext::ImportedVolume v;
                    v.name     = vol->name;
                    v.type     = static_cast<int>(vol->type());
                    v.extruder = config_tool(vol->config);
                    v.painted  = vol->is_mm_painted();
                    v.painted_layers = (v.painted ? 1 << SLICER_PAINT_COLOUR : 0)
                        | (vol->is_fdm_support_painted() ? 1 << SLICER_PAINT_SUPPORTS : 0)
                        | (vol->is_seam_painted() ? 1 << SLICER_PAINT_SEAM : 0);
                    if (v.painted) {
                        const auto& used = vol->mmu_segmentation_facets.get_data().used_states;
                        for (size_t s = 1; s < used.size(); ++s)
                            if (used[s]) v.paint_tools.push_back(paint_tool(static_cast<int>(s)));
                    }
                    if (vol->is_model_part()) {
                        Slic3r::TriangleMesh mesh = vol->mesh();
                        mesh.transform(vol->get_matrix(), /*fix_left_handed=*/true);
                        v.facets = static_cast<int>(mesh.facets_count());
                        n->parts.merge(mesh);
                    }
                    info.volumes.push_back(std::move(v));
                }
                Slic3r::BoundingBoxf3 bb = n->parts.bounding_box();
                n->centre = bb.center() + inst->get_offset();
                all_bb.merge(Slic3r::BoundingBoxf3(bb.min + inst->get_offset(),
                                                   bb.max + inst->get_offset()));
                info.name = obj->name.empty() ? "Object " + std::to_string(natives.size() + 1)
                                              : obj->name;
                if (n_inst > 1) info.name += " (" + std::to_string(i + 1) + ")";
                info.settings = object_file_settings(*o);
                natives.push_back(std::move(n));
            }
        }
        if (natives.empty()) return set_err(ctx, "File contains no printable objects");

        Slic3r::Vec3d centre = all_bb.center();
        for (size_t i = 0; i < natives.size(); ++i) {
            Native& n = *natives[i];
            const std::string base = std::string(out_dir) + "/" + std::to_string(i);
            if (!n.parts.write_binary((base + ".stl").c_str()))
                return set_err(ctx, "Could not write the imported mesh");
            if (!store_orca_3mf((base + ".3mf").c_str(), n.model, nullptr))
                return set_err(ctx, "Could not write the imported object");
            const Slic3r::ModelObject* o = n.model.objects.front();
            for (size_t k = 0; k < o->volumes.size(); ++k) {
                const Slic3r::ModelVolume* vol = o->volumes[k];
                if (vol->is_model_part()) continue;
                Slic3r::TriangleMesh mesh = vol->mesh();
                mesh.transform(vol->get_matrix(), /*fix_left_handed=*/true);
                mesh.write_binary((base + ".v" + std::to_string(k) + ".stl").c_str());
            }
            n.info.offset_x_mm = static_cast<float>(n.centre.x() - centre.x());
            n.info.offset_y_mm = static_cast<float>(n.centre.y() - centre.y());
            ctx->imported.push_back(std::move(n.info));
        }
        std::string project;
        append_config(project, file_config);
        ctx->imported_project = std::move(project);
        return static_cast<int>(natives.size());
    } catch (const std::exception& e) {
        return set_err(ctx, e);
    }
}

static const SlicerContext::ImportedVolume* imported_volume(SlicerContext* ctx, int index, int volume) {
    if (index < 0 || index >= static_cast<int>(ctx->imported.size())) return nullptr;
    const auto& vols = ctx->imported[index].volumes;
    if (volume < 0 || volume >= static_cast<int>(vols.size())) return nullptr;
    return &vols[volume];
}

int slicer_imported_object_extruder(SlicerHandle handle, int index) {
    auto ctx = CTX(handle);
    if (index < 0 || index >= static_cast<int>(ctx->imported.size())) return 0;
    return ctx->imported[index].extruder;
}

int slicer_imported_volume_count(SlicerHandle handle, int index) {
    auto ctx = CTX(handle);
    if (index < 0 || index >= static_cast<int>(ctx->imported.size())) return 0;
    return static_cast<int>(ctx->imported[index].volumes.size());
}

const char* slicer_imported_volume_name(SlicerHandle handle, int index, int volume) {
    auto v = imported_volume(CTX(handle), index, volume);
    return v ? v->name.c_str() : "";
}

int slicer_imported_volume_type(SlicerHandle handle, int index, int volume) {
    auto v = imported_volume(CTX(handle), index, volume);
    return v ? v->type : -1;
}

int slicer_imported_volume_extruder(SlicerHandle handle, int index, int volume) {
    auto v = imported_volume(CTX(handle), index, volume);
    return v ? v->extruder : 0;
}

int slicer_imported_volume_facets(SlicerHandle handle, int index, int volume) {
    auto v = imported_volume(CTX(handle), index, volume);
    return v ? v->facets : 0;
}

int slicer_imported_volume_painted(SlicerHandle handle, int index, int volume) {
    auto v = imported_volume(CTX(handle), index, volume);
    return v && v->painted ? 1 : 0;
}

int slicer_imported_volume_painted_layers(SlicerHandle handle, int index, int volume) {
    auto v = imported_volume(CTX(handle), index, volume);
    return v ? v->painted_layers : 0;
}

int slicer_imported_volume_paint_tools(SlicerHandle handle, int index, int volume, int* out, int max) {
    auto v = imported_volume(CTX(handle), index, volume);
    if (!v) return 0;
    const int n = static_cast<int>(v->paint_tools.size());
    for (int i = 0; out && i < std::min(n, max); ++i) out[i] = v->paint_tools[i];
    return n;
}

int slicer_add_model_object(SlicerHandle handle, const char* path, int keep_volume_settings) {
    auto ctx = CTX(handle);
    try {
        Slic3r::Model temp;
        Slic3r::DynamicPrintConfig unused;
        if (!load_orca_3mf(path, temp, unused))
            return set_err(ctx, "Could not read the imported object");
        if (temp.objects.size() != 1) return set_err(ctx, "Imported object file must hold one object");
        temp.add_default_instances();
        Slic3r::ModelObject* src = temp.objects.front();

        // Object settings come back through slicer_set_object_file_settings.
        src->config.reset();
        src->layer_config_ranges.clear();
        src->layer_height_profile.clear();

        std::vector<int> volume_map;
        for (int k = 0; k < static_cast<int>(src->volumes.size()); ++k) volume_map.push_back(k);
        if (!keep_volume_settings) {
            // Keep each volume's tool; a modifier with nothing left does nothing.
            for (int k = static_cast<int>(src->volumes.size()) - 1; k >= 0; --k) {
                Slic3r::ModelVolume* vol = src->volumes[k];
                const int tool = config_tool(vol->config);
                vol->config.reset();
                if (tool > 0) vol->config.set("extruder", tool);
                if (vol->is_modifier() && tool == 0) {
                    src->delete_volume(k);
                    volume_map[k] = -1;
                    for (int j = k + 1; j < static_cast<int>(volume_map.size()); ++j)
                        if (volume_map[j] >= 0) --volume_map[j];
                }
            }
        }
        for (Slic3r::ModelVolume* vol : src->volumes) {
            remap_config_tools(vol->config, mixes_to_slicer(ctx));
            paint_mixes_to_slicer(ctx, *vol);
        }
        remap_config_tools(src->config, mixes_to_slicer(ctx));

        double cx = ctx->origin_at_center ? 0.0 : ctx->bed_x / 2.0;
        double cy = ctx->origin_at_center ? 0.0 : ctx->bed_y / 2.0;
        int idx = static_cast<int>(ctx->model.objects.size());
        auto* obj = ctx->model.add_object(*src);
        obj->center_around_origin();
        Slic3r::BoundingBoxf3 bb = obj->raw_bounding_box();
        for (auto* inst : obj->instances)
            inst->set_offset(Slic3r::Vec3d(cx, cy, inst->get_offset().z() - bb.min.z()));
        ctx->volume_maps.resize(idx);
        ctx->volume_maps.push_back(std::move(volume_map));
        return idx;
    } catch (const std::exception& e) {
        return set_err(ctx, e);
    }
}

static void set_config_tool(SlicerContext* ctx, Slic3r::ModelConfig& cfg, int tool) {
    if (tool > 0) cfg.set("extruder", to_slicer_tool(ctx, tool));
    else cfg.erase("extruder");
}

int slicer_set_object_extruder(SlicerHandle handle, int object_index, int tool) {
    auto ctx = CTX(handle);
    if (object_index < 0 || object_index >= static_cast<int>(ctx->model.objects.size()))
        return set_err(ctx, "object index out of range");
    if (tool < 0 || tool >= 2 * SLICER_MIX_BASE)
        return set_err(ctx, "tool out of range");
    set_config_tool(ctx, ctx->model.objects[object_index]->config, tool);
    return 0;
}

int slicer_set_volume_extruder(SlicerHandle handle, int object_index, int volume, int tool) {
    auto ctx = CTX(handle);
    if (object_index < 0 || object_index >= static_cast<int>(ctx->model.objects.size()))
        return set_err(ctx, "object index out of range");
    if (tool < 0 || tool >= 2 * SLICER_MIX_BASE)
        return set_err(ctx, "tool out of range");
    Slic3r::ModelObject* obj = ctx->model.objects[object_index];
    int k = volume;
    if (object_index < static_cast<int>(ctx->volume_maps.size()) && !ctx->volume_maps[object_index].empty()) {
        const auto& map = ctx->volume_maps[object_index];
        if (volume < 0 || volume >= static_cast<int>(map.size())) return set_err(ctx, "volume index out of range");
        k = map[volume];
        if (k < 0) return 0;   // removed (a modifier without a tool)
    }
    if (k < 0 || k >= static_cast<int>(obj->volumes.size())) return set_err(ctx, "volume index out of range");
    set_config_tool(ctx, obj->volumes[k]->config, tool);
    return 0;
}

const char* slicer_imported_object_name(SlicerHandle handle, int index) {
    auto ctx = CTX(handle);
    if (index < 0 || index >= static_cast<int>(ctx->imported.size())) return "";
    return ctx->imported[index].name.c_str();
}

int slicer_imported_object_offset(SlicerHandle handle, int index,
                                  float* offset_x_mm, float* offset_y_mm) {
    auto ctx = CTX(handle);
    if (index < 0 || index >= static_cast<int>(ctx->imported.size()))
        return set_err(ctx, "imported object index out of range");
    if (offset_x_mm) *offset_x_mm = ctx->imported[index].offset_x_mm;
    if (offset_y_mm) *offset_y_mm = ctx->imported[index].offset_y_mm;
    return 0;
}

const char* slicer_imported_object_settings(SlicerHandle handle, int index) {
    auto ctx = CTX(handle);
    if (index < 0 || index >= static_cast<int>(ctx->imported.size())) return "";
    return ctx->imported[index].settings.c_str();
}

const char* slicer_imported_project_settings(SlicerHandle handle) {
    return CTX(handle)->imported_project.c_str();
}

int slicer_set_object_file_settings(SlicerHandle handle, int object_index, const char* text) {
    auto ctx = CTX(handle);
    if (!text) return set_err(ctx, "null settings");
    if (object_index < 0 || object_index >= static_cast<int>(ctx->model.objects.size()))
        return set_err(ctx, "object index out of range");
    Slic3r::ModelObject* obj = ctx->model.objects[object_index];
    // Parse fully before touching the object, so a bad line changes nothing.
    Slic3r::DynamicPrintConfig object_config;
    std::vector<std::pair<Slic3r::t_layer_height_range, Slic3r::DynamicPrintConfig>> ranges;
    std::vector<coordf_t> heights;
    enum { kObject, kRange, kHeights } section = kObject;
    std::istringstream in(text);
    std::string line;
    int line_no = 0;
    try {
        while (std::getline(in, line)) {
            ++line_no;
            if (line.empty()) continue;
            if (line.rfind("[range ", 0) == 0) {
                double lo = 0, hi = 0;
                if (std::sscanf(line.c_str(), "[range %lf %lf]", &lo, &hi) != 2 || hi <= lo)
                    throw std::runtime_error("bad height range");
                ranges.push_back({{lo, hi}, Slic3r::DynamicPrintConfig()});
                section = kRange;
                continue;
            }
            if (line == "[layer_heights]") { section = kHeights; continue; }
            if (section == kHeights) {
                std::istringstream values(line);
                std::string v;
                while (std::getline(values, v, ';')) heights.push_back(std::stod(v));
                continue;
            }
            size_t eq = line.find(" = ");
            if (eq == std::string::npos) throw std::runtime_error("expected \"key = value\"");
            std::string key = line.substr(0, eq), value = line.substr(eq + 3);
            Slic3r::ConfigSubstitutionContext subst(Slic3r::ForwardCompatibilitySubstitutionRule::EnableSilent);
            (section == kObject ? object_config : ranges.back().second).set_deserialize(key, value, subst);
        }
    } catch (const std::exception& e) {
        ctx->last_error = "object settings line " + std::to_string(line_no) + ": " + e.what();
        return -1;
    }
    // Tools in the text are PalmSlice numbers.
    const ToolRemap tools = mixes_to_slicer(ctx);
    for (const std::string& key : object_config.keys())
        obj->config.set_key_value(key, object_config.option(key)->clone());
    remap_config_tools(obj->config, tools);
    if (!ranges.empty()) {
        // On top of any ranges set before (e.g. the file's, then the user's):
        // split old and new at every boundary; new settings win where they overlap.
        std::vector<double> cuts;
        for (const auto& [range, config] : obj->layer_config_ranges) { cuts.push_back(range.first); cuts.push_back(range.second); }
        for (const auto& [range, config] : ranges) { cuts.push_back(range.first); cuts.push_back(range.second); }
        std::sort(cuts.begin(), cuts.end());
        cuts.erase(std::unique(cuts.begin(), cuts.end(), [](double a, double b) { return std::abs(a - b) < EPSILON; }), cuts.end());
        Slic3r::t_layer_config_ranges pieces;
        for (size_t i = 0; i + 1 < cuts.size(); ++i) {
            const double lo = cuts[i], hi = cuts[i + 1], mid = (lo + hi) / 2;
            Slic3r::ModelConfig mc;
            bool covered = false;
            for (const auto& [range, rc] : obj->layer_config_ranges)
                if (range.first <= mid && mid < range.second) { mc.assign_config(rc.get()); covered = true; }
            for (const auto& [range, config] : ranges)
                if (range.first <= mid && mid < range.second) {
                    Slic3r::ModelConfig added;
                    added.assign_config(config);
                    remap_config_tools(added, tools);
                    mc.assign_config(added.get());
                    covered = true;
                }
            if (covered) pieces[{lo, hi}] = std::move(mc);
        }
        obj->layer_config_ranges = std::move(pieces);
    }
    ensure_range_layer_heights(ctx, *obj);
    if (!heights.empty()) obj->layer_height_profile.set(std::move(heights));
    return 0;
}

const char* slicer_object_setting_keys(void) {
    static const std::string keys = [] {
        std::string out;
        for (const std::string& k : Slic3r::PrintObjectConfig().keys()) out += k + "\n";
        for (const std::string& k : Slic3r::PrintRegionConfig().keys()) out += k + "\n";
        return out;
    }();
    return keys.c_str();
}

int slicer_set_object_tool_ranges(SlicerHandle handle, int object_index, const char* spec) {
    auto ctx = CTX(handle);
    if (!spec) return set_err(ctx, "null tool ranges");
    if (object_index < 0 || object_index >= static_cast<int>(ctx->model.objects.size()))
        return set_err(ctx, "object index out of range");
    struct Band { double lo, hi; int tool; };
    std::vector<Band> bands;
    std::istringstream in(spec);
    std::string line;
    while (std::getline(in, line)) {
        if (line.empty()) continue;
        Band b;
        if (std::sscanf(line.c_str(), "%lf %lf %d", &b.lo, &b.hi, &b.tool) != 3 || !(b.hi > b.lo) || b.tool < 0)
            return set_err(ctx, ("bad tool range: " + line).c_str());
        bands.push_back(b);
    }
    Slic3r::ModelObject* obj = ctx->model.objects[object_index];
    // Ranges past the object's top break libslic3r's layer height profile,
    // so clamp to the object as placed (after slicer_set_object_transform).
    const double top = obj->instances.empty() ? 0 : obj->instance_bounding_box(0).size().z();
    for (Band& b : bands) b.hi = std::min(b.hi, top);
    bands.erase(std::remove_if(bands.begin(), bands.end(), [](const Band& b) { return !(b.hi > b.lo + EPSILON); }),
                bands.end());
    if (bands.empty()) return 0;
    // Split the existing height ranges and the bands at every boundary; each
    // piece keeps its range's settings, with the band's tool on top.
    std::vector<double> cuts;
    for (const auto& [range, config] : obj->layer_config_ranges) { cuts.push_back(range.first); cuts.push_back(range.second); }
    for (const Band& b : bands) { cuts.push_back(b.lo); cuts.push_back(b.hi); }
    std::sort(cuts.begin(), cuts.end());
    cuts.erase(std::unique(cuts.begin(), cuts.end(), [](double a, double b) { return std::abs(a - b) < EPSILON; }), cuts.end());
    Slic3r::t_layer_config_ranges pieces;
    for (size_t i = 0; i + 1 < cuts.size(); ++i) {
        const double lo = cuts[i], hi = cuts[i + 1], mid = (lo + hi) / 2;
        Slic3r::ModelConfig config;
        bool covered = false;
        for (const auto& [range, rc] : obj->layer_config_ranges)
            if (range.first <= mid && mid < range.second) { config.assign_config(rc.get()); covered = true; }
        for (const Band& b : bands)
            if (b.lo <= mid && mid < b.hi) {
                if (b.tool > 0) config.set("extruder", to_slicer_tool(ctx, b.tool));
                else config.erase("extruder");
                covered = true;
            }
        if (covered) pieces[{lo, hi}] = std::move(config);
    }
    obj->layer_config_ranges = std::move(pieces);
    ensure_range_layer_heights(ctx, *obj);
    return 0;
}

// ── Painting ──────────────────────────────────────────────────────────────────

static PaintSession* paint_session(SlicerContext* ctx) {
    if (!ctx->paint || !ctx->paint->selector) { set_err(ctx, "no paint session"); return nullptr; }
    return ctx->paint.get();
}

// A point in the object's display frame (the <i>.stl) → the volume's mesh frame.
static Slic3r::Vec3f to_volume(const PaintSession& s, float x, float y, float z) {
    return (s.trafo.inverse() * Slic3r::Vec3d(x, y, z)).cast<float>();
}

static void push_undo(PaintSession& s) {
    s.undo.push_back(s.selector->serialize());
    if (s.undo.size() > 64) s.undo.erase(s.undo.begin());
    s.redo.clear();
}

// The volume's painting for the session's layer.
static Slic3r::FacetsAnnotation& paint_facets(PaintSession& s) {
    switch (s.layer) {
    case SLICER_PAINT_SUPPORTS: return s.volume->supported_facets;
    case SLICER_PAINT_SEAM:     return s.volume->seam_facets;
    default:                    return s.volume->mmu_segmentation_facets;
    }
}

// States a stroke can paint: tools for colour, enforce / block otherwise.
static int paint_state_count(const PaintSession& s) {
    return s.layer == SLICER_PAINT_COLOUR ? k_paint_states : SLICER_PAINT_BLOCK + 1;
}

int slicer_paint_begin(SlicerHandle handle, const char* path, int volume) {
    return slicer_paint_begin_layer(handle, path, volume, SLICER_PAINT_COLOUR);
}

int slicer_paint_begin_layer(SlicerHandle handle, const char* path, int volume, int layer) {
    auto ctx = CTX(handle);
    if (layer < SLICER_PAINT_COLOUR || layer > SLICER_PAINT_SEAM) return set_err(ctx, "unknown paint layer");
    try {
        auto s = std::make_unique<PaintSession>();
        Slic3r::DynamicPrintConfig unused;
        if (!load_orca_3mf(path, s->model, unused) || s->model.objects.size() != 1)
            return set_err(ctx, "Could not read the object to paint");
        Slic3r::ModelObject* obj = s->model.objects.front();
        if (volume < 0 || volume >= int(obj->volumes.size()) || !obj->volumes[volume]->is_model_part())
            return set_err(ctx, "Only printable parts can be painted");
        s->volume = obj->volumes[volume];
        // Loading the 3MF can move the object's offset from its volumes onto
        // the instance, so the display frame is instance × volume.
        s->trafo = obj->instances.empty() ? s->volume->get_matrix()
                                          : obj->instances.front()->get_matrix() * s->volume->get_matrix();
        s->layer = layer;
        s->selector = std::make_unique<Slic3r::TriangleSelector>(s->volume->mesh());
        s->selector->deserialize(paint_facets(*s).get_data());
        ctx->paint = std::move(s);
        return 0;
    } catch (const std::exception& e) {
        return set_err(ctx, e);
    }
}

int slicer_paint_stroke_begin(SlicerHandle handle) {
    auto ctx = CTX(handle);
    auto s = paint_session(ctx);
    if (!s) return -1;
    push_undo(*s);
    return 0;
}

int slicer_paint_brush(SlicerHandle handle, int facet, const float* point, const float* previous,
                       const float* camera, float radius, int state, int sphere) {
    auto ctx = CTX(handle);
    auto s = paint_session(ctx);
    if (!s || !point || !camera) return -1;
    if (facet < 0 || facet >= int(s->volume->mesh().facets_count())) return set_err(ctx, "facet out of range");
    if (s->layer == SLICER_PAINT_COLOUR) state = paint_state(state);  // a tool or mix
    if (state < 0 || state >= paint_state_count(*s)) return set_err(ctx, "state out of range");
    try {
        using TS = Slic3r::TriangleSelector;
        const Slic3r::Transform3d trafo = s->trafo;
        const Slic3r::Vec3f center = to_volume(*s, point[0], point[1], point[2]);
        const Slic3r::Vec3f cam = to_volume(*s, camera[0], camera[1], camera[2]);
        const auto type = sphere ? TS::CursorType::SPHERE : TS::CursorType::CIRCLE;
        Slic3r::Transform3d no_translate = trafo;
        no_translate.translation() = Slic3r::Vec3d::Zero();
        auto cursor = previous
            ? TS::DoublePointCursor::cursor_factory(to_volume(*s, previous[0], previous[1], previous[2]), center, cam, radius, type, trafo, TS::ClippingPlane())
            : TS::SinglePointCursor::cursor_factory(center, cam, radius, type, trafo, TS::ClippingPlane());
        s->selector->select_patch(facet, std::move(cursor), Slic3r::EnforcerBlockerType(state), no_translate, true);
        return 0;
    } catch (const std::exception& e) {
        return set_err(ctx, e);
    }
}

int slicer_paint_fill(SlicerHandle handle, int facet, const float* point, int state, float angle_deg, int smart) {
    auto ctx = CTX(handle);
    auto s = paint_session(ctx);
    if (!s || !point) return -1;
    if (facet < 0 || facet >= int(s->volume->mesh().facets_count())) return set_err(ctx, "facet out of range");
    if (s->layer == SLICER_PAINT_COLOUR) state = paint_state(state);  // a tool or mix
    if (state < 0 || state >= paint_state_count(*s)) return set_err(ctx, "state out of range");
    try {
        using TS = Slic3r::TriangleSelector;
        const Slic3r::Vec3f hit = to_volume(*s, point[0], point[1], point[2]);
        Slic3r::Transform3d no_translate = s->trafo;
        no_translate.translation() = Slic3r::Vec3d::Zero();
        if (smart)
            s->selector->seed_fill_select_triangles(hit, facet, no_translate, TS::ClippingPlane(), angle_deg);
        else
            s->selector->bucket_fill_select_triangles(hit, facet, TS::ClippingPlane(), angle_deg, /*propagate=*/true);
        s->selector->seed_fill_apply_on_triangles(Slic3r::EnforcerBlockerType(state));
        return 0;
    } catch (const std::exception& e) {
        return set_err(ctx, e);
    }
}

int slicer_paint_clear(SlicerHandle handle) {
    auto ctx = CTX(handle);
    auto s = paint_session(ctx);
    if (!s) return -1;
    push_undo(*s);
    s->selector->reset();
    return 0;
}

int slicer_paint_undo(SlicerHandle handle, int redo) {
    auto ctx = CTX(handle);
    auto s = paint_session(ctx);
    if (!s) return -1;
    auto& from = redo ? s->redo : s->undo;
    auto& to = redo ? s->undo : s->redo;
    if (from.empty()) return 1;
    to.push_back(s->selector->serialize());
    s->selector->deserialize(from.back());
    from.pop_back();
    return 0;
}

int slicer_paint_cancel_stroke(SlicerHandle handle) {
    auto ctx = CTX(handle);
    auto s = paint_session(ctx);
    if (!s) return -1;
    if (s->undo.empty()) return 1;
    s->selector->deserialize(s->undo.back());
    s->undo.pop_back();
    return 0;
}

int slicer_paint_mesh_update(SlicerHandle handle) {
    auto ctx = CTX(handle);
    auto s = paint_session(ctx);
    if (!s) return -1;
    try {
        const Slic3r::Transform3d trafo = s->trafo;
        s->vertices.clear();
        s->states.clear();
        // Unpainted triangles (state 0) are the part's own tool, drawn by its mesh.
        for (int state = 1; state < paint_state_count(*s); ++state) {
            const indexed_triangle_set its = s->selector->get_facets_strict(Slic3r::EnforcerBlockerType(state));
            for (const auto& tri : its.indices) {
                for (int k = 0; k < 3; ++k) {
                    const Slic3r::Vec3d v = trafo * its.vertices[tri[k]].cast<double>();
                    s->vertices.insert(s->vertices.end(), {float(v.x()), float(v.y()), float(v.z())});
                }
                s->states.push_back(static_cast<unsigned char>(s->layer == SLICER_PAINT_COLOUR ? paint_tool(state) : state));
            }
        }
        return int(s->states.size());
    } catch (const std::exception& e) {
        return set_err(ctx, e);
    }
}

const float* slicer_paint_mesh_vertices(SlicerHandle handle) {
    auto ctx = CTX(handle);
    return ctx->paint ? ctx->paint->vertices.data() : nullptr;
}

const unsigned char* slicer_paint_mesh_states(SlicerHandle handle) {
    auto ctx = CTX(handle);
    return ctx->paint ? ctx->paint->states.data() : nullptr;
}

int slicer_paint_used_tools(SlicerHandle handle, int* out, int max) {
    auto ctx = CTX(handle);
    auto s = paint_session(ctx);
    if (!s) return -1;
    const auto data = s->selector->serialize();
    int n = 0;
    for (size_t state = 1; state < data.used_states.size(); ++state)
        if (data.used_states[state]) {
            if (out && n < max) out[n] = s->layer == SLICER_PAINT_COLOUR ? paint_tool(int(state)) : int(state);
            ++n;
        }
    return n;
}

int slicer_paint_end(SlicerHandle handle, const char* save_path) {
    auto ctx = CTX(handle);
    auto s = paint_session(ctx);
    if (!s) return -1;
    try {
        int result = 0;
        if (save_path) {
            s->selector->garbage_collect();
            paint_facets(*s).set(*s->selector);
            if (!store_orca_3mf(save_path, s->model, nullptr))
                result = set_err(ctx, "Could not save the painting");
        }
        ctx->paint.reset();
        return result;
    } catch (const std::exception& e) {
        ctx->paint.reset();
        return set_err(ctx, e);
    }
}

// ── OrcaSlicer system presets ────────────────────────────────────────────────
} // extern "C"

namespace {

// Process-wide: loaded once, then only read. g_presets_mutex guards both the
// swap in slicer_presets_load and every read.
//
// One PresetBundle per vendor, the first being OrcaFilamentLibrary (the
// generic filaments other vendors' filaments inherit from). OrcaSlicer merges
// them into one bundle (PresetBundle::load_system_presets_from_json, which is
// private); kept separate, compatibility is still checked across vendors the
// way OrcaSlicer does.
struct PresetRef {
    std::string           name;
    Slic3r::PresetBundle* bundle;
};
std::mutex                                         g_presets_mutex;
std::vector<std::unique_ptr<Slic3r::PresetBundle>> g_bundles;
std::string                                        g_presets_error;
// System presets per type, sorted by name (index = API index).
std::vector<PresetRef>                             g_preset_refs[3];

thread_local std::string t_string_result;

Slic3r::PresetCollection* collection(Slic3r::PresetBundle& b, int type) {
    switch (type) {
        case SLICER_PRESET_PRINT:    return &b.prints;
        case SLICER_PRESET_FILAMENT: return &b.filaments;
        case SLICER_PRESET_PRINTER:  return &b.printers;
        default:                     return nullptr;
    }
}

// Finds a system preset by name; also returns the bundle (vendor) it's in.
const Slic3r::Preset* find_system_preset(int type, const char* name,
                                         Slic3r::PresetBundle** bundle_out = nullptr) {
    if (type < 0 || type > 2 || !name) return nullptr;
    const auto& refs = g_preset_refs[type];
    auto it = std::lower_bound(refs.begin(), refs.end(), std::string(name),
        [](const PresetRef& r, const std::string& n) { return r.name < n; });
    if (it == refs.end() || it->name != name) return nullptr;
    const Slic3r::Preset* p = collection(*it->bundle, type)->find_preset(name, false, false);
    if (p && bundle_out) *bundle_out = it->bundle;
    return p;
}

// Settings OrcaSlicer stores in a preset but which aren't print settings:
// preset bookkeeping (inheritance / compatibility).
bool is_preset_bookkeeping_key(const std::string& key) {
    return key == "inherits" || key == "compatible_printers" ||
           key == "compatible_printers_condition" || key == "compatible_prints" ||
           key == "compatible_prints_condition" || key == "renamed_from" ||
           key == "inherits_group" || key == "different_settings_to_system" ||
           key == "print_compatible_printers";
}

std::string serialize_config(const Slic3r::DynamicPrintConfig& cfg) {
    std::ostringstream out;
    for (const std::string& key : cfg.keys()) {
        if (is_preset_bookkeeping_key(key)) continue;
        out << key << " = " << cfg.opt_serialize(key) << "\n";
    }
    return out.str();
}

} // namespace

extern "C" {

int slicer_presets_load(const char* resources_dir) {
    std::lock_guard<std::mutex> lock(g_presets_mutex);
    g_presets_error.clear();
    g_bundles.clear();
    for (auto& refs : g_preset_refs) refs.clear();
    if (!resources_dir) { g_presets_error = "null resources dir"; return -1; }
    try {
        // libslic3r also reads resources_dir()/info and /flush while slicing.
        // Nothing is written to data_dir: system presets are never saved.
        Slic3r::set_resources_dir(resources_dir);
        Slic3r::set_data_dir(resources_dir);
        const std::filesystem::path vendor_dir = std::filesystem::path(resources_dir) / "profiles";
        std::vector<std::string> vendors;
        for (const auto& entry : std::filesystem::directory_iterator(vendor_dir))
            if (entry.path().extension() == ".json")
                vendors.push_back(entry.path().stem().string());
        std::sort(vendors.begin(), vendors.end());
        // The filament library first: other vendors' filaments inherit from it.
        const std::string library = Slic3r::PresetBundle::ORCA_FILAMENT_LIBRARY;
        auto lib_it = std::find(vendors.begin(), vendors.end(), library);
        if (lib_it != vendors.end()) std::rotate(vendors.begin(), lib_it, lib_it + 1);

        const Slic3r::PresetBundle* base = nullptr;
        for (const std::string& vendor : vendors) {
            auto bundle = std::make_unique<Slic3r::PresetBundle>();
            try {
                bundle->load_vendor_configs_from_json(vendor_dir.string(), vendor, Slic3r::PresetBundle::LoadSystem,
                    Slic3r::ForwardCompatibilitySubstitutionRule::EnableSilent, vendor == library ? nullptr : base);
            } catch (const std::exception& e) {
                // One bad vendor file shouldn't take the others down.
                g_presets_error += vendor + ": " + e.what() + "\n";
                continue;
            }
            for (int type = 0; type < 3; ++type) {
                auto* coll = collection(*bundle, type);
                for (size_t i = 0; i < coll->size(); ++i) {
                    const Slic3r::Preset& p = coll->preset(i, false);
                    if (p.is_system && !p.is_default)
                        g_preset_refs[type].push_back({p.name, bundle.get()});
                }
            }
            if (vendor == library) base = bundle.get();
            g_bundles.push_back(std::move(bundle));
        }
        for (auto& refs : g_preset_refs) {
            std::stable_sort(refs.begin(), refs.end(),
                [](const PresetRef& a, const PresetRef& b) { return a.name < b.name; });
            // A name used by two vendors: keep the first (the library, then alphabetical).
            refs.erase(std::unique(refs.begin(), refs.end(),
                [](const PresetRef& a, const PresetRef& b) { return a.name == b.name; }), refs.end());
        }
        int printers = static_cast<int>(g_preset_refs[SLICER_PRESET_PRINTER].size());
        if (printers == 0) {
            g_presets_error += std::string("no printer presets found in ") + vendor_dir.string();
            return -1;
        }
        return printers;
    } catch (const std::exception& e) {
        g_bundles.clear();
        for (auto& refs : g_preset_refs) refs.clear();
        g_presets_error = e.what();
        return -1;
    }
}

const char* slicer_presets_last_error(void) {
    std::lock_guard<std::mutex> lock(g_presets_mutex);
    t_string_result = g_presets_error;
    return t_string_result.c_str();
}

int slicer_preset_count(int type) {
    std::lock_guard<std::mutex> lock(g_presets_mutex);
    if (type < 0 || type > 2) return 0;
    return static_cast<int>(g_preset_refs[type].size());
}

const char* slicer_preset_name(int type, int index) {
    std::lock_guard<std::mutex> lock(g_presets_mutex);
    if (type < 0 || type > 2 || index < 0 ||
        index >= static_cast<int>(g_preset_refs[type].size()))
        return "";
    return g_preset_refs[type][index].name.c_str();
}

const char* slicer_preset_config(int type, const char* name) {
    std::lock_guard<std::mutex> lock(g_presets_mutex);
    const Slic3r::Preset* p = find_system_preset(type, name);
    if (!p) return nullptr;
    t_string_result = serialize_config(p->config);
    return t_string_result.c_str();
}

int slicer_preset_is_compatible(int type, const char* name, const char* printer_name) {
    std::lock_guard<std::mutex> lock(g_presets_mutex);
    Slic3r::PresetBundle* bundle = nullptr;
    Slic3r::PresetBundle* printer_bundle = nullptr;
    const Slic3r::Preset* p       = find_system_preset(type, name, &bundle);
    const Slic3r::Preset* printer = find_system_preset(SLICER_PRESET_PRINTER, printer_name, &printer_bundle);
    if (!p || !printer) return -1;
    if (type == SLICER_PRESET_PRINTER) return 1;
    // Across vendors too, like OrcaSlicer (e.g. the library's generic filaments).
    return Slic3r::is_compatible_with_printer(
               collection(*bundle, type)->get_preset_with_vendor_profile(*p),
               printer_bundle->printers.get_preset_with_vendor_profile(*printer)) ? 1 : 0;
}

int slicer_apply_preset(SlicerHandle handle, int type, const char* name) {
    auto ctx = CTX(handle);
    std::lock_guard<std::mutex> lock(g_presets_mutex);
    const Slic3r::Preset* p = find_system_preset(type, name);
    if (!p) return set_err(ctx, (std::string("unknown OrcaSlicer preset: ") + (name ? name : "(null)")).c_str());
    try {
        for (const std::string& key : p->config.keys()) {
            if (is_preset_bookkeeping_key(key)) continue;
            ctx->config.set_key_value(key, p->config.option(key)->clone());
        }
        // Recorded in the G-code footer like OrcaSlicer does.
        switch (type) {
            case SLICER_PRESET_PRINT:
                ctx->config.set_key_value("print_settings_id", new Slic3r::ConfigOptionString(p->name));
                ctx->slice_config_applied = true;
                break;
            case SLICER_PRESET_FILAMENT:
                ctx->config.set_key_value("filament_settings_id", new Slic3r::ConfigOptionStrings({p->name}));
                break;
            case SLICER_PRESET_PRINTER:
                ctx->config.set_key_value("printer_settings_id", new Slic3r::ConfigOptionString(p->name));
                // Bed temperatures are per plate type; start on the printer's
                // default plate like OrcaSlicer does: smooth PEI unless the
                // printer names one ("Textured PEI Plate", or a BedType number).
                ctx->config.set_key_value("curr_bed_type", new Slic3r::ConfigOptionEnum<Slic3r::BedType>(Slic3r::btPEI));
                if (p->config.has("default_bed_type")) {
                    const std::string bed = p->config.opt_string("default_bed_type");
                    Slic3r::ConfigSubstitutionContext subst(Slic3r::ForwardCompatibilitySubstitutionRule::EnableSilent);
                    if (!bed.empty() && std::isdigit(static_cast<unsigned char>(bed[0])))
                        ctx->config.set_key_value("curr_bed_type", new Slic3r::ConfigOptionEnum<Slic3r::BedType>(Slic3r::BedType(std::atoi(bed.c_str()))));
                    else if (!bed.empty())
                        ctx->config.set_deserialize("curr_bed_type", bed, subst);
                }
                sync_bed_from_config(ctx);
                break;
        }
        return 0;
    } catch (const std::exception& e) {
        return set_err(ctx, e);
    }
}

int slicer_apply_settings(SlicerHandle handle, const char* ini_text) {
    auto ctx = CTX(handle);
    if (!ini_text) return set_err(ctx, "null settings");
    // Validate into a scratch copy so a bad line leaves the context untouched.
    Slic3r::DynamicPrintConfig staged = ctx->config;
    std::istringstream in(ini_text);
    std::string line;
    int line_no = 0;
    while (std::getline(in, line)) {
        ++line_no;
        if (!line.empty() && line.back() == '\r') line.pop_back();
        size_t start = line.find_first_not_of(" \t");
        if (start == std::string::npos || line[start] == '#' || line[start] == ';') continue;
        size_t eq = line.find('=');
        if (eq == std::string::npos) {
            ctx->last_error = "line " + std::to_string(line_no) + ": expected \"key = value\": " + line;
            return -1;
        }
        std::string key = line.substr(start, eq - start);
        while (!key.empty() && (key.back() == ' ' || key.back() == '\t')) key.pop_back();
        std::string value = line.substr(eq + 1);
        if (!value.empty() && value.front() == ' ') value.erase(0, 1);
        if (is_preset_bookkeeping_key(key)) continue;
        try {
            Slic3r::ConfigSubstitutionContext subst(Slic3r::ForwardCompatibilitySubstitutionRule::Disable);
            staged.set_deserialize(key, value, subst);
        } catch (const std::exception& e) {
            ctx->last_error = "setting \"" + key + "\": " + e.what();
            return -1;
        }
    }
    ctx->config = std::move(staged);
    sync_bed_from_config(ctx);
    // Layer height / infill now come from settings, not slicer_slice's legacy parameters.
    ctx->slice_config_applied = true;
    return 0;
}

const char* slicer_normalize_settings(const char* ini_text) {
    Slic3r::DynamicPrintConfig parsed;
    std::istringstream in(ini_text ? ini_text : "");
    std::string line;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        size_t start = line.find_first_not_of(" \t");
        if (start == std::string::npos || line[start] == '#' || line[start] == ';') continue;
        size_t eq = line.find('=');
        if (eq == std::string::npos) continue;
        std::string key = line.substr(start, eq - start);
        while (!key.empty() && (key.back() == ' ' || key.back() == '\t')) key.pop_back();
        std::string value = line.substr(eq + 1);
        if (!value.empty() && value.front() == ' ') value.erase(0, 1);
        if (is_preset_bookkeeping_key(key)) continue;
        try {
            // Renames PrusaSlicer keys (PrintConfigDef::handle_legacy) and
            // silently drops unknown ones.
            Slic3r::ConfigSubstitutionContext subst(Slic3r::ForwardCompatibilitySubstitutionRule::EnableSilent);
            parsed.set_deserialize(key, value, subst);
        } catch (const std::exception&) {
            // A value libslic3r can't parse: dropped.
        }
    }
    t_string_result = serialize_config(parsed);
    return t_string_result.c_str();
}

// Sets element `tool` (0-based) of a per-extruder option from the first
// element of `value`, growing the vector to the tool count by repeating its
// first element. Scalar options aren't per tool and are left alone.
static void set_tool_option(Slic3r::DynamicPrintConfig& config, size_t tool_count,
                            const std::string& key, const Slic3r::ConfigOption& value, size_t tool) {
    auto* src = dynamic_cast<const Slic3r::ConfigOptionVectorBase*>(&value);
    if (!src || src->empty()) return;
    auto* dst = dynamic_cast<Slic3r::ConfigOptionVectorBase*>(config.option(key, true));
    if (!dst) return;
    const size_t n = std::max(tool_count, tool + 1);
    if (dst->size() < n) dst->resize(n, src);
    dst->set_at(src, tool, 0);
}

int slicer_apply_tool_settings(SlicerHandle handle, int tool, const char* ini_text) {
    auto ctx = CTX(handle);
    if (!ini_text) return set_err(ctx, "null settings");
    if (tool < 1 || tool >= SLICER_MIX_BASE) return set_err(ctx, "tool out of range");
    Slic3r::DynamicPrintConfig parsed;
    std::istringstream in(ini_text);
    std::string line;
    int line_no = 0;
    while (std::getline(in, line)) {
        ++line_no;
        if (!line.empty() && line.back() == '\r') line.pop_back();
        size_t start = line.find_first_not_of(" \t");
        if (start == std::string::npos || line[start] == '#' || line[start] == ';') continue;
        size_t eq = line.find('=');
        if (eq == std::string::npos) {
            ctx->last_error = "line " + std::to_string(line_no) + ": expected \"key = value\": " + line;
            return -1;
        }
        std::string key = line.substr(start, eq - start);
        while (!key.empty() && (key.back() == ' ' || key.back() == '\t')) key.pop_back();
        std::string value = line.substr(eq + 1);
        if (!value.empty() && value.front() == ' ') value.erase(0, 1);
        if (is_preset_bookkeeping_key(key)) continue;
        try {
            Slic3r::ConfigSubstitutionContext subst(Slic3r::ForwardCompatibilitySubstitutionRule::Disable);
            parsed.set_deserialize(key, value, subst);
        } catch (const std::exception& e) {
            ctx->last_error = "setting \"" + key + "\": " + e.what();
            return -1;
        }
    }
    try {
        Slic3r::DynamicPrintConfig staged = ctx->config;
        for (const std::string& key : parsed.keys())
            set_tool_option(staged, physical_count(ctx), key, *parsed.option(key), size_t(tool - 1));
        ctx->config = std::move(staged);
        return 0;
    } catch (const std::exception& e) {
        return set_err(ctx, e);
    }
}

int slicer_apply_tool_preset(SlicerHandle handle, int tool, const char* name) {
    auto ctx = CTX(handle);
    if (tool < 1 || tool >= SLICER_MIX_BASE) return set_err(ctx, "tool out of range");
    std::lock_guard<std::mutex> lock(g_presets_mutex);
    const Slic3r::Preset* p = find_system_preset(SLICER_PRESET_FILAMENT, name);
    if (!p) return set_err(ctx, (std::string("unknown OrcaSlicer preset: ") + (name ? name : "(null)")).c_str());
    try {
        Slic3r::DynamicPrintConfig staged = ctx->config;
        const size_t n = physical_count(ctx), t = size_t(tool - 1);
        for (const std::string& key : p->config.keys())
            if (!is_preset_bookkeeping_key(key))
                set_tool_option(staged, n, key, *p->config.option(key), t);
        Slic3r::ConfigOptionStrings id({p->name});
        set_tool_option(staged, n, "filament_settings_id", id, t);
        ctx->config = std::move(staged);
        return 0;
    } catch (const std::exception& e) {
        return set_err(ctx, e);
    }
}

const char* slicer_get_setting(SlicerHandle handle, const char* key) {
    auto ctx = CTX(handle);
    if (!key) return nullptr;
    const Slic3r::ConfigOption* opt = ctx->config.option(key);
    if (!opt) {
        // Not set yet: fall back to libslic3r's default for a known key.
        const Slic3r::ConfigOptionDef* def = Slic3r::print_config_def.get(key);
        if (!def || !def->default_value) return nullptr;
        t_string_result = def->default_value->serialize();
        return t_string_result.c_str();
    }
    t_string_result = opt->serialize();
    return t_string_result.c_str();
}

const char* slicer_setting_info(const char* key) {
    if (!key) return nullptr;
    const Slic3r::ConfigOptionDef* def = Slic3r::print_config_def.get(key);
    if (!def) return nullptr;
    const char* kind = "string";
    switch (def->type) {
        case Slic3r::coFloat:  case Slic3r::coFloats:  kind = "float"; break;
        case Slic3r::coInt:    case Slic3r::coInts:    kind = "int"; break;
        case Slic3r::coPercent: case Slic3r::coPercents: kind = "percent"; break;
        case Slic3r::coFloatOrPercent: case Slic3r::coFloatsOrPercents: kind = "float_or_percent"; break;
        case Slic3r::coBool:   case Slic3r::coBools:   kind = "bool"; break;
        case Slic3r::coEnum:   case Slic3r::coEnums:   kind = "enum"; break;
        case Slic3r::coPoint:  kind = "point"; break;
        case Slic3r::coPoints: kind = "points"; break;
        default: break;
    }
    auto join = [](const std::vector<std::string>& items) {
        std::string out;
        for (size_t i = 0; i < items.size(); ++i) { if (i) out += ";"; out += items[i]; }
        return out;
    };
    std::ostringstream out;
    out << "kind = " << kind << "\n"
        << "vector = " << (def->is_scalar() || def->type == Slic3r::coPoints ? 0 : 1) << "\n"
        << "nullable = " << (def->nullable ? 1 : 0) << "\n"
        << "multiline = " << (def->multiline ? 1 : 0) << "\n"
        << "mode = " << static_cast<int>(def->mode) << "\n"
        << "label = " << Slic3r::escape_string_cstyle(def->label) << "\n"
        << "full_label = " << Slic3r::escape_string_cstyle(def->full_label) << "\n"
        << "category = " << Slic3r::escape_string_cstyle(def->category) << "\n"
        << "sidetext = " << Slic3r::escape_string_cstyle(def->sidetext) << "\n"
        << "tooltip = " << Slic3r::escape_string_cstyle(def->tooltip) << "\n";
    if (!def->enum_values.empty())
        out << "enum_values = " << Slic3r::escape_string_cstyle(join(def->enum_values)) << "\n"
            << "enum_labels = " << Slic3r::escape_string_cstyle(join(def->enum_labels.empty() ? def->enum_values : def->enum_labels)) << "\n";
    t_string_result = out.str();
    return t_string_result.c_str();
}

// Test reference: slice a 3MF project the way OrcaSlicer's command line does
// (the model with all its stored settings, the file's project settings over
// libslic3r defaults), without going through PalmSlice's import / profile path.
int slicer_reference_slice_3mf(const char* path, const char* out_gcode, char* error, int error_len) {
    try {
        Slic3r::Model model;
        Slic3r::DynamicPrintConfig config;
        config.apply(Slic3r::FullPrintConfig::defaults());
        if (!load_orca_3mf(path, model, config))
            throw std::runtime_error("load_bbs_3mf failed");
        model.add_default_instances();
        config.set_key_value("thumbnails", new Slic3r::ConfigOptionString(""));
        config.set_key_value("filename_format", new Slic3r::ConfigOptionString("{input_filename_base}.gcode"));
        Slic3r::Print print;
        print.set_status_silent();
        print.is_BBL_printer() = config.has("printer_model") &&
            boost::starts_with(config.opt_string("printer_model"), "Bambu Lab");
        normalize_tools(config);
        clamp_model_tools(model, config.option<Slic3r::ConfigOptionFloats>("filament_diameter")->values.size());
        fit_layer_height_profiles(model, config);
        print.set_plate_origin(Slic3r::Vec3d::Zero());
        print.apply(model, config);
        print.process();
        Slic3r::GCodeProcessorResult result;
        print.export_gcode(out_gcode, &result, nullptr);
        return 0;
    } catch (const std::exception& e) {
        if (error && error_len > 0) std::snprintf(error, error_len, "%s", e.what());
        return -1;
    }
}

} // extern "C"

