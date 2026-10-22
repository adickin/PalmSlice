// slicer_bridge.cpp
// C wrapper implementation over libslic3r.
//
// Targets: PrusaSlicer 2.9.6 libslic3r API (pinned via PRUSA_TAG in scripts/common.sh).
// If the build fails due to missing symbols, check the PrusaSlicer version:
//   cd ~/ios-sources/PrusaSlicer && git log --oneline -5
// and adjust the include paths or method names accordingly.

#include "slicer_bridge.h"

#include <string>
#include <stdexcept>
#include <cstring>
#include <functional>
#include <algorithm>
#include <cmath>
#include <limits>
#include <vector>

// ── libslic3r core ────────────────────────────────────────────────────────────
#include <libslic3r/libslic3r.h>
#include <libslic3r/Model.hpp>
#include <libslic3r/Print.hpp>
#include <libslic3r/PrintConfig.hpp>
#include <libslic3r/Format/STL.hpp>
#include <libslic3r/Format/3mf.hpp>
#include <libslic3r/Format/AMF.hpp>
#include <libslic3r/Format/OBJ.hpp>
#include <libslic3r/Semver.hpp>
#include <libslic3r/TriangleMesh.hpp>
// GCode export lives inside Print::export_gcode in recent PrusaSlicer builds.
// If your version has a separate GCode.hpp, add: #include <libslic3r/GCode.hpp>

// ── Context ───────────────────────────────────────────────────────────────────
struct SlicerContext {
    Slic3r::Model              model;
    Slic3r::Print              print;
    Slic3r::DynamicPrintConfig config;
    std::string                last_error;

    // Printer dimensions — updated by slicer_apply_printer_config,
    // used by slicer_load_stl to centre the model on the correct bed.
    double bed_x = 220.0;
    double bed_y = 220.0;
    bool   origin_at_center = false;

    // Set to true once slicer_apply_slice_config has been called so that
    // slicer_slice_with_progress doesn't clobber the slice settings with its
    // legacy layer_height / infill_percent parameters.
    bool   slice_config_applied = false;

    // Results of the last slicer_import_model_file call.
    struct ImportedObject {
        std::string name;
        float offset_x_mm = 0.f;
        float offset_y_mm = 0.f;
    };
    std::vector<ImportedObject> imported;

    SlicerContext() {
        // Start from factory defaults so we have a valid config baseline.
        // FullPrintConfig::defaults() returns the canonical defaults object.
        config.apply(Slic3r::FullPrintConfig::defaults());

        // Override a minimal set for a usable FFF print.
        // These match a generic 0.4mm nozzle, 1.75mm PLA printer.
        config.set_key_value("layer_height",
            new Slic3r::ConfigOptionFloat(0.2));
        config.set_key_value("first_layer_height",
            new Slic3r::ConfigOptionFloatOrPercent(0.25, false));
        config.set_key_value("perimeters",
            new Slic3r::ConfigOptionInt(3));
        config.set_key_value("fill_density",
            new Slic3r::ConfigOptionPercent(20));
        config.set_key_value("fill_pattern",
            new Slic3r::ConfigOptionEnum<Slic3r::InfillPattern>(Slic3r::ipGyroid));

        // Nozzle / filament — must be arrays (one entry per extruder)
        config.set_key_value("nozzle_diameter",
            new Slic3r::ConfigOptionFloats({0.4}));
        config.set_key_value("filament_diameter",
            new Slic3r::ConfigOptionFloats({1.75}));
        config.set_key_value("temperature",
            new Slic3r::ConfigOptionInts({210}));
        config.set_key_value("first_layer_temperature",
            new Slic3r::ConfigOptionInts({215}));
        config.set_key_value("bed_temperature",
            new Slic3r::ConfigOptionInts({60}));
        config.set_key_value("first_layer_bed_temperature",
            new Slic3r::ConfigOptionInts({65}));

        // Retraction
        config.set_key_value("retract_length",
            new Slic3r::ConfigOptionFloats({5.0}));
        config.set_key_value("retract_speed",
            new Slic3r::ConfigOptionFloats({45.0}));
        config.set_key_value("retract_restart_extra",
            new Slic3r::ConfigOptionFloats({0.0}));

        // Fan
        config.set_key_value("fan_always_on",
            new Slic3r::ConfigOptionBools({true}));
        config.set_key_value("min_fan_speed",
            new Slic3r::ConfigOptionInts({35}));
        config.set_key_value("max_fan_speed",
            new Slic3r::ConfigOptionInts({100}));

        // Bed size (220×220×250 mm — generic Ender-class)
        config.set_key_value("bed_size",
            new Slic3r::ConfigOptionPoint(Slic3r::Vec2d(220, 220)));
        config.set_key_value("print_center",
            new Slic3r::ConfigOptionPoint(Slic3r::Vec2d(110, 110)));
        config.set_key_value("max_print_height",
            new Slic3r::ConfigOptionFloat(250));

        // Speeds
        config.set_key_value("perimeter_speed",
            new Slic3r::ConfigOptionFloat(45));
        config.set_key_value("infill_speed",
            new Slic3r::ConfigOptionFloat(80));
        config.set_key_value("first_layer_speed",
            new Slic3r::ConfigOptionFloatOrPercent(25, false));
        config.set_key_value("travel_speed",
            new Slic3r::ConfigOptionFloat(130));

        // Extrusion multiplier
        config.set_key_value("extrusion_multiplier",
            new Slic3r::ConfigOptionFloats({1.0}));

        // Gcode flavour (RepRap / Marlin)
        config.set_key_value("gcode_flavor",
            new Slic3r::ConfigOptionEnum<Slic3r::GCodeFlavor>(Slic3r::gcfMarlinLegacy));

        // No support structures for v1
        config.set_key_value("support_material",
            new Slic3r::ConfigOptionBool(false));
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

// ── GCodeFlavor mapping ───────────────────────────────────────────────────────
// Must stay in sync with GCodeFlavor.bridgeInt in GCodeFlavor.swift.
static const Slic3r::GCodeFlavor kFlavorMap[] = {
    Slic3r::gcfMarlinLegacy,    // 0  = .marlin
    Slic3r::gcfMarlinFirmware,  // 1  = .marlin2
    Slic3r::gcfKlipper,         // 2  = .klipper
    Slic3r::gcfRepRapSprinter,  // 3  = .repRap
    Slic3r::gcfRepRapFirmware,  // 4  = .repRapFirmware
    Slic3r::gcfTeacup,          // 5  = .teacup
    Slic3r::gcfMakerWare,       // 6  = .makerWare
    Slic3r::gcfSailfish,        // 7  = .sailfish
    Slic3r::gcfMach3,           // 8  = .mach3
    Slic3r::gcfMachinekit,      // 9  = .machineKit
    Slic3r::gcfSmoothie,        // 10 = .smoothie
    Slic3r::gcfNoExtrusion,     // 11 = .noGCode
};
static constexpr int kFlavorMapSize = static_cast<int>(sizeof(kFlavorMap) / sizeof(kFlavorMap[0]));

// ── Public C API ─────────────────────────────────────────────────────────────
extern "C" {

SlicerHandle slicer_create(void) {
    try {
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
        // but the values are now owned by slicer_apply_slice_config. If no slice
        // config has been applied (legacy call path), fall back to the parameters.
        if (!ctx->slice_config_applied) {
            ctx->config.set_key_value("layer_height",
                new Slic3r::ConfigOptionFloat(static_cast<double>(layer_height)));
            ctx->config.set_key_value("fill_density",
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

void slicer_cancel(SlicerHandle handle) {
    CTX(handle)->print.cancel();
}

int slicer_export_gcode(SlicerHandle handle, const char* output_path) {
    auto ctx = CTX(handle);
    try {
        // export_gcode signature (PrusaSlicer 2.7+):
        //   void Print::export_gcode(const std::string& path_template,
        //                            GCodeProcessorResult* result,
        //                            ThumbnailsGeneratorCallback thumbnail_cb)
        ctx->print.export_gcode(std::string(output_path),
                                /*result=*/nullptr,
                                /*thumbnail_cb=*/nullptr);
        return 0;
    } catch (const std::exception& e) {
        return set_err(ctx, e);
    }
}

const char* slicer_last_error(SlicerHandle handle) {
    return CTX(handle)->last_error.c_str();
}

int slicer_apply_printer_config(SlicerHandle handle, const SlicerPrinterConfig* cfg) {
    auto ctx = CTX(handle);
    if (!cfg) return set_err(ctx, "null printer config");
    try {
        // Store bed dimensions for use in slicer_load_stl.
        ctx->bed_x = static_cast<double>(cfg->bed_x);
        ctx->bed_y = static_cast<double>(cfg->bed_y);
        ctx->origin_at_center = (cfg->origin_at_center != 0);

        // bed_shape: rectangular polygon in mm.
        // When origin is at front-left, polygon starts at (0,0).
        // When origin is at centre, polygon starts at (-x/2, -y/2).
        double ox = ctx->origin_at_center ? -ctx->bed_x / 2.0 : 0.0;
        double oy = ctx->origin_at_center ? -ctx->bed_y / 2.0 : 0.0;
        Slic3r::ConfigOptionPoints bed_shape;
        bed_shape.values = {
            Slic3r::Vec2d(ox,              oy),
            Slic3r::Vec2d(ox + ctx->bed_x, oy),
            Slic3r::Vec2d(ox + ctx->bed_x, oy + ctx->bed_y),
            Slic3r::Vec2d(ox,              oy + ctx->bed_y),
        };
        ctx->config.set_key_value("bed_shape",
            new Slic3r::ConfigOptionPoints(bed_shape));

        // Max print height
        ctx->config.set_key_value("max_print_height",
            new Slic3r::ConfigOptionFloat(static_cast<double>(cfg->bed_z)));

        // G-Code flavor
        int fi = cfg->gcode_flavor;
        Slic3r::GCodeFlavor flavor = (fi >= 0 && fi < kFlavorMapSize)
            ? kFlavorMap[fi]
            : Slic3r::gcfMarlinLegacy;
        ctx->config.set_key_value("gcode_flavor",
            new Slic3r::ConfigOptionEnum<Slic3r::GCodeFlavor>(flavor));

        // Start / end gcode
        if (cfg->start_gcode) {
            ctx->config.set_key_value("start_gcode",
                new Slic3r::ConfigOptionString(std::string(cfg->start_gcode)));
        }
        if (cfg->end_gcode) {
            ctx->config.set_key_value("end_gcode",
                new Slic3r::ConfigOptionString(std::string(cfg->end_gcode)));
        }

        // Nozzle / filament diameters (per-extruder arrays)
        ctx->config.set_key_value("nozzle_diameter",
            new Slic3r::ConfigOptionFloats({static_cast<double>(cfg->nozzle_diameter)}));
        ctx->config.set_key_value("filament_diameter",
            new Slic3r::ConfigOptionFloats({static_cast<double>(cfg->filament_diameter)}));

        // Printhead clearance: use the largest half-extent as the radius.
        float radius = std::max({std::abs(cfg->printhead_x_min),
                                  std::abs(cfg->printhead_x_max),
                                  std::abs(cfg->printhead_y_min),
                                  std::abs(cfg->printhead_y_max)});
        ctx->config.set_key_value("extruder_clearance_radius",
            new Slic3r::ConfigOptionFloat(static_cast<double>(radius)));
        if (cfg->gantry_height > 0.0f) {
            ctx->config.set_key_value("extruder_clearance_height",
                new Slic3r::ConfigOptionFloat(static_cast<double>(cfg->gantry_height)));
        }

        return 0;
    } catch (const std::exception& e) {
        return set_err(ctx, e);
    }
}

int slicer_apply_slice_config(SlicerHandle handle, const SlicerSliceConfig* cfg) {
    auto ctx = CTX(handle);
    if (!cfg) return set_err(ctx, "null slice config");
    try {
        // Layers
        ctx->config.set_key_value("layer_height",
            new Slic3r::ConfigOptionFloat(static_cast<double>(cfg->layer_height)));
        ctx->config.set_key_value("first_layer_height",
            new Slic3r::ConfigOptionFloatOrPercent(
                static_cast<double>(cfg->first_layer_height), false));

        // Walls
        ctx->config.set_key_value("perimeters",
            new Slic3r::ConfigOptionInt(cfg->wall_count));
        ctx->config.set_key_value("xy_size_compensation",
            new Slic3r::ConfigOptionFloat(static_cast<double>(cfg->horizontal_expansion)));
        ctx->config.set_key_value("perimeter_generator",
            new Slic3r::ConfigOptionEnum<Slic3r::PerimeterGeneratorType>(
                cfg->wall_generator == 0 ? Slic3r::PerimeterGeneratorType::Classic
                                         : Slic3r::PerimeterGeneratorType::Arachne));
        ctx->config.set_key_value("external_perimeters_first",
            new Slic3r::ConfigOptionBool(cfg->external_perimeters_first != 0));

        // Top / Bottom
        ctx->config.set_key_value("top_solid_layers",
            new Slic3r::ConfigOptionInt(cfg->top_layers));
        ctx->config.set_key_value("bottom_solid_layers",
            new Slic3r::ConfigOptionInt(cfg->bottom_layers));
        if (cfg->top_thickness > 0.0f) {
            ctx->config.set_key_value("top_solid_min_thickness",
                new Slic3r::ConfigOptionFloat(static_cast<double>(cfg->top_thickness)));
        }
        if (cfg->bottom_thickness > 0.0f) {
            ctx->config.set_key_value("bottom_solid_min_thickness",
                new Slic3r::ConfigOptionFloat(static_cast<double>(cfg->bottom_thickness)));
        }

        // Infill
        ctx->config.set_key_value("fill_density",
            new Slic3r::ConfigOptionPercent(cfg->infill_density));
        ctx->config.set_key_value("fill_pattern",
            new Slic3r::ConfigOptionEnum<Slic3r::InfillPattern>(
                static_cast<Slic3r::InfillPattern>(cfg->infill_pattern)));
        // infill_overlap is a % of extrusion width (percent=true). Lower than
        // the stock 25% reduces squish-out on dense/solid parts.
        ctx->config.set_key_value("infill_overlap",
            new Slic3r::ConfigOptionFloatOrPercent(
                static_cast<double>(cfg->infill_overlap), true));

        // Advanced. Even/Odd slicing cancels overlapping shells (models such
        // as 3DLabPrint planes form internal ribs this way).
        ctx->config.set_key_value("slicing_mode",
            new Slic3r::ConfigOptionEnum<Slic3r::SlicingMode>(
                cfg->slicing_mode == 1 ? Slic3r::SlicingMode::EvenOdd
                                       : Slic3r::SlicingMode::Regular));
        ctx->config.set_key_value("slice_closing_radius",
            new Slic3r::ConfigOptionFloat(static_cast<double>(cfg->gap_closing_radius)));
        // 0 = auto width, which is also PrusaSlicer's own default.
        ctx->config.set_key_value("extrusion_width",
            new Slic3r::ConfigOptionFloatOrPercent(
                static_cast<double>(cfg->extrusion_width), false));
        // PrusaSlicer's default is 200% (of first layer height), so restore
        // that rather than "auto" when unset.
        if (cfg->first_layer_extrusion_width > 0.0f) {
            ctx->config.set_key_value("first_layer_extrusion_width",
                new Slic3r::ConfigOptionFloatOrPercent(
                    static_cast<double>(cfg->first_layer_extrusion_width), false));
        } else {
            ctx->config.set_key_value("first_layer_extrusion_width",
                new Slic3r::ConfigOptionFloatOrPercent(200, true));
        }

        // Speed — types verified against PrintConfig.hpp:
        // perimeter_speed: ConfigOptionFloat
        // infill_speed:    ConfigOptionFloat
        // travel_speed:    ConfigOptionFloat
        // first_layer_speed: ConfigOptionFloatOrPercent
        ctx->config.set_key_value("perimeter_speed",
            new Slic3r::ConfigOptionFloat(static_cast<double>(cfg->print_speed)));
        ctx->config.set_key_value("infill_speed",
            new Slic3r::ConfigOptionFloat(static_cast<double>(cfg->infill_speed)));
        ctx->config.set_key_value("travel_speed",
            new Slic3r::ConfigOptionFloat(static_cast<double>(cfg->travel_speed)));
        ctx->config.set_key_value("first_layer_speed",
            new Slic3r::ConfigOptionFloatOrPercent(
                static_cast<double>(cfg->first_layer_speed), false));
        ctx->config.set_key_value("solid_infill_speed",
            new Slic3r::ConfigOptionFloatOrPercent(
                static_cast<double>(cfg->solid_infill_speed), false));
        ctx->config.set_key_value("top_solid_infill_speed",
            new Slic3r::ConfigOptionFloatOrPercent(
                static_cast<double>(cfg->top_solid_infill_speed), false));

        // Ironing
        bool ironing_on = (cfg->ironing != 0);
        ctx->config.set_key_value("ironing",
            new Slic3r::ConfigOptionBool(ironing_on));
        if (ironing_on) {
            Slic3r::IroningType itype = (cfg->ironing_type == 1) ? Slic3r::IroningType::TopmostOnly
                                       : (cfg->ironing_type == 2) ? Slic3r::IroningType::AllSolid
                                                                   : Slic3r::IroningType::TopSurfaces;
            ctx->config.set_key_value("ironing_type",
                new Slic3r::ConfigOptionEnum<Slic3r::IroningType>(itype));
            ctx->config.set_key_value("ironing_flowrate",
                new Slic3r::ConfigOptionPercent(static_cast<double>(cfg->ironing_flowrate)));
            ctx->config.set_key_value("ironing_speed",
                new Slic3r::ConfigOptionFloat(static_cast<double>(cfg->ironing_speed)));
            ctx->config.set_key_value("ironing_spacing",
                new Slic3r::ConfigOptionFloat(static_cast<double>(cfg->ironing_spacing)));
        }

        // Support
        bool gen_support = (cfg->generate_support != 0);
        ctx->config.set_key_value("support_material",
            new Slic3r::ConfigOptionBool(gen_support));
        if (gen_support) {
            // smsGrid=0, smsSnug=1, smsTree=2, smsOrganic=3
            Slic3r::SupportMaterialStyle sms = (cfg->support_style == 0)
                ? Slic3r::smsSnug : Slic3r::smsOrganic;
            ctx->config.set_key_value("support_material_style",
                new Slic3r::ConfigOptionEnum<Slic3r::SupportMaterialStyle>(sms));
            ctx->config.set_key_value("support_material_buildplate_only",
                new Slic3r::ConfigOptionBool(cfg->support_buildplate_only != 0));
            ctx->config.set_key_value("support_material_threshold",
                new Slic3r::ConfigOptionInt(cfg->support_overhang_angle));
            // xy_spacing is stored as absolute mm (percent=false)
            ctx->config.set_key_value("support_material_xy_spacing",
                new Slic3r::ConfigOptionFloatOrPercent(
                    static_cast<double>(cfg->support_xy_spacing), false));
            ctx->config.set_key_value("support_material_with_sheath",
                new Slic3r::ConfigOptionBool(cfg->support_use_towers != 0));
            // Support-to-part interface — controls how solid the supported
            // bottom surface prints. The stock 0.2mm contact distance leaves a
            // full layer-height gap (rough/airy bottom); a tighter gap plus a
            // few solid interface layers gives a much more solid seat.
            ctx->config.set_key_value("support_material_contact_distance",
                new Slic3r::ConfigOptionFloat(static_cast<double>(cfg->support_contact_distance)));
            ctx->config.set_key_value("support_material_interface_layers",
                new Slic3r::ConfigOptionInt(cfg->support_interface_layers));
            // Mirror the same interface density onto the bottom of supports so
            // the part sits on a dense seat rather than sparse support pattern.
            ctx->config.set_key_value("support_material_bottom_interface_layers",
                new Slic3r::ConfigOptionInt(cfg->support_interface_layers));
            ctx->config.set_key_value("support_material_interface_spacing",
                new Slic3r::ConfigOptionFloat(static_cast<double>(cfg->support_interface_spacing)));
        }

        // Build plate adhesion
        // adhesion_type: 0=none, 1=skirt, 2=brim, 3=raft
        switch (cfg->adhesion_type) {
            case 0: // none
                ctx->config.set_key_value("brim_type",
                    new Slic3r::ConfigOptionEnum<Slic3r::BrimType>(Slic3r::btNoBrim));
                ctx->config.set_key_value("skirts",
                    new Slic3r::ConfigOptionInt(0));
                ctx->config.set_key_value("raft_layers",
                    new Slic3r::ConfigOptionInt(0));
                break;
            case 1: // skirt
                ctx->config.set_key_value("brim_type",
                    new Slic3r::ConfigOptionEnum<Slic3r::BrimType>(Slic3r::btNoBrim));
                ctx->config.set_key_value("skirts",
                    new Slic3r::ConfigOptionInt(cfg->skirt_loops));
                ctx->config.set_key_value("skirt_distance",
                    new Slic3r::ConfigOptionFloat(static_cast<double>(cfg->skirt_distance)));
                ctx->config.set_key_value("raft_layers",
                    new Slic3r::ConfigOptionInt(0));
                break;
            case 2: { // brim
                // brim_type: 1=outer_only, 2=inner_only, 3=outer_and_inner
                int bt = cfg->brim_type;
                Slic3r::BrimType brim = (bt == 2) ? Slic3r::btInnerOnly
                                      : (bt == 3) ? Slic3r::btOuterAndInner
                                                  : Slic3r::btOuterOnly;
                ctx->config.set_key_value("brim_type",
                    new Slic3r::ConfigOptionEnum<Slic3r::BrimType>(brim));
                ctx->config.set_key_value("brim_width",
                    new Slic3r::ConfigOptionFloat(static_cast<double>(cfg->brim_width)));
                ctx->config.set_key_value("skirts",
                    new Slic3r::ConfigOptionInt(0));
                ctx->config.set_key_value("raft_layers",
                    new Slic3r::ConfigOptionInt(0));
                break;
            }
            case 3: // raft
                ctx->config.set_key_value("brim_type",
                    new Slic3r::ConfigOptionEnum<Slic3r::BrimType>(Slic3r::btNoBrim));
                ctx->config.set_key_value("skirts",
                    new Slic3r::ConfigOptionInt(0));
                ctx->config.set_key_value("raft_layers",
                    new Slic3r::ConfigOptionInt(cfg->raft_layers));
                break;
            default:
                break;
        }

        ctx->slice_config_applied = true;
        return 0;
    } catch (const std::exception& e) {
        return set_err(ctx, e);
    }
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

int slicer_apply_material_config(SlicerHandle handle,
                                 const SlicerMaterialConfig* cfg) {
    auto ctx = CTX(handle);
    if (!cfg) return set_err(ctx, "null material config");
    try {
        // Filament diameter — overrides the value set by slicer_apply_printer_config
        ctx->config.set_key_value("filament_diameter",
            new Slic3r::ConfigOptionFloats({static_cast<double>(cfg->filament_diameter)}));

        // Temperatures
        ctx->config.set_key_value("first_layer_temperature",
            new Slic3r::ConfigOptionInts({cfg->first_layer_temperature}));
        ctx->config.set_key_value("temperature",
            new Slic3r::ConfigOptionInts({cfg->temperature}));
        ctx->config.set_key_value("first_layer_bed_temperature",
            new Slic3r::ConfigOptionInts({cfg->first_layer_bed_temperature}));
        ctx->config.set_key_value("bed_temperature",
            new Slic3r::ConfigOptionInts({cfg->bed_temperature}));

        // Flow
        ctx->config.set_key_value("extrusion_multiplier",
            new Slic3r::ConfigOptionFloats({static_cast<double>(cfg->extrusion_multiplier)}));

        // Retraction — retract_length == 0 disables retraction natively
        ctx->config.set_key_value("retract_length",
            new Slic3r::ConfigOptionFloats({static_cast<double>(cfg->retract_length)}));
        ctx->config.set_key_value("retract_speed",
            new Slic3r::ConfigOptionFloats({static_cast<double>(cfg->retract_speed)}));
        ctx->config.set_key_value("retract_restart_extra",
            new Slic3r::ConfigOptionFloats({static_cast<double>(cfg->retract_restart_extra)}));
        ctx->config.set_key_value("retract_lift",
            new Slic3r::ConfigOptionFloats({static_cast<double>(cfg->retract_lift)}));
        ctx->config.set_key_value("retract_before_travel",
            new Slic3r::ConfigOptionFloats({static_cast<double>(cfg->retract_before_travel)}));

        // Fan / cooling
        ctx->config.set_key_value("cooling",
            new Slic3r::ConfigOptionBools({cfg->cooling != 0}));
        ctx->config.set_key_value("min_fan_speed",
            new Slic3r::ConfigOptionInts({cfg->min_fan_speed}));
        ctx->config.set_key_value("max_fan_speed",
            new Slic3r::ConfigOptionInts({cfg->max_fan_speed}));
        ctx->config.set_key_value("bridge_fan_speed",
            new Slic3r::ConfigOptionInts({cfg->bridge_fan_speed}));
        ctx->config.set_key_value("disable_fan_first_layers",
            new Slic3r::ConfigOptionInts({cfg->disable_fan_first_layers}));
        ctx->config.set_key_value("fan_below_layer_time",
            new Slic3r::ConfigOptionInts({cfg->fan_below_layer_time}));
        ctx->config.set_key_value("slowdown_below_layer_time",
            new Slic3r::ConfigOptionInts({cfg->slowdown_below_layer_time}));
        ctx->config.set_key_value("min_print_speed",
            new Slic3r::ConfigOptionFloats({static_cast<double>(cfg->min_print_speed)}));

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

int slicer_import_model_file(SlicerHandle handle, const char* path, const char* out_dir) {
    auto ctx = CTX(handle);
    try {
        ctx->imported.clear();
        // Dispatch on extension ourselves rather than via FileReader::load_model,
        // which also links the STEP loader (needs OpenCASCADE, not built for iOS).
        std::string p(path);
        std::string ext = p.substr(p.find_last_of('.') + 1);
        std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);

        Slic3r::Model model;
        Slic3r::DynamicPrintConfig file_config;  // embedded print settings, ignored
        Slic3r::ConfigSubstitutionContext substitutions(
            Slic3r::ForwardCompatibilitySubstitutionRule::EnableSilent);
        bool ok = false;
        if (ext == "3mf") {
            boost::optional<Slic3r::Semver> generator_version;
            ok = Slic3r::load_3mf(path, file_config, substitutions, &model,
                                  /*check_version=*/false, generator_version);
        } else if (ext == "amf") {
            ok = Slic3r::load_amf(path, &file_config, &substitutions, &model,
                                  /*check_version=*/false);
        } else if (ext == "obj") {
            ok = Slic3r::load_obj(path, &model);
        } else if (ext == "stl") {
            ok = Slic3r::load_stl(path, &model);
        } else {
            return set_err(ctx, "Unsupported file type (expected .3mf, .obj, .amf or .stl)");
        }
        if (!ok) return set_err(ctx, ("Could not read ." + ext + " file").c_str());
        model.add_default_instances();

        // One output mesh per object instance, with the instance's rotation /
        // scale / mirroring baked in. Translation is kept separately as an offset
        // from the file's overall centre so arranged plates keep their layout.
        struct Baked { Slic3r::TriangleMesh mesh; std::string name; Slic3r::Vec3d centre; };
        std::vector<Baked> baked;
        Slic3r::BoundingBoxf3 all_bb;
        for (const auto* obj : model.objects) {
            Slic3r::TriangleMesh raw = obj->raw_mesh();
            if (raw.empty()) continue;
            int n_inst = static_cast<int>(obj->instances.size());
            for (int i = 0; i < n_inst; ++i) {
                const auto* inst = obj->instances[i];
                Baked b;
                b.mesh = raw;
                b.mesh.transform(inst->get_matrix_no_offset(), /*fix_left_handed=*/true);
                Slic3r::BoundingBoxf3 bb = b.mesh.bounding_box();
                b.centre = bb.center() + inst->get_offset();
                all_bb.merge(Slic3r::BoundingBoxf3(bb.min + inst->get_offset(),
                                                   bb.max + inst->get_offset()));
                b.name = obj->name.empty() ? "Object " + std::to_string(baked.size() + 1)
                                           : obj->name;
                if (n_inst > 1) b.name += " (" + std::to_string(i + 1) + ")";
                baked.push_back(std::move(b));
            }
        }
        if (baked.empty()) return set_err(ctx, "File contains no printable objects");

        Slic3r::Vec3d centre = all_bb.center();
        for (size_t i = 0; i < baked.size(); ++i) {
            std::string out = std::string(out_dir) + "/" + std::to_string(i) + ".stl";
            baked[i].mesh.write_binary(out.c_str());
            SlicerContext::ImportedObject io;
            io.name        = baked[i].name;
            io.offset_x_mm = static_cast<float>(baked[i].centre.x() - centre.x());
            io.offset_y_mm = static_cast<float>(baked[i].centre.y() - centre.y());
            ctx->imported.push_back(std::move(io));
        }
        return static_cast<int>(baked.size());
    } catch (const std::exception& e) {
        return set_err(ctx, e);
    }
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

} // extern "C"
