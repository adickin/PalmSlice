"""Writes profiles/PalmSlice.ini, PalmSlice's own PrusaSlicer vendor bundle.

Usage: python3 scripts/profiles/make_palmslice_bundle.py profiles/PalmSlice.ini

The Snapmaker U1 (4 toolheads, Klipper) isn't in PrusaSlicer's vendor
profiles. Its printer, print and filament presets here are ported from
OrcaSlicer's Snapmaker profiles (AGPL-3.0, like PalmSlice): Orca keys are
mapped to PrusaSlicer keys, and the G-code templates are rewritten for
PrusaSlicer's macro language (see U1_* below). Orca JSON is fetched from
GitHub with curl and cached in a temp directory.

The U1 presets have not printed on real hardware yet; PalmSlice marks the
printer untested until they have.
"""
import json
import os
import subprocess
import sys
import tempfile
import urllib.parse

ORCA = "https://raw.githubusercontent.com/OrcaSlicer/OrcaSlicer/main/resources/profiles/"
CACHE = os.path.join(tempfile.gettempdir(), "palmslice-orca-cache")
TOOLS = 4
MODEL = "Snapmaker U1"
PRINTER = "Snapmaker U1 (0.4 nozzle)"


def fetch(kind, name):
    path = os.path.join(CACHE, kind + "__" + name + ".json")
    if not os.path.exists(path):
        os.makedirs(CACHE, exist_ok=True)
        for vendor, sub in (("Snapmaker", kind), ("OrcaFilamentLibrary", kind), ("OrcaFilamentLibrary", kind + "/base")):
            r = subprocess.run(["curl", "-sfL", ORCA + vendor + "/" + sub + "/" + urllib.parse.quote(name + ".json")],
                               capture_output=True)
            if r.returncode == 0 and r.stdout:
                open(path, "wb").write(r.stdout)
                break
        else:
            raise SystemExit("Orca profile not found: %s %s" % (kind, name))
    return json.load(open(path))


def resolve(kind, name):
    """An Orca profile with its inherits chain applied."""
    chain, n = [], name
    while n:
        d = fetch(kind, n)
        chain.append(d)
        n = d.get("inherits")
    out = {}
    for d in reversed(chain):
        out.update(d)
    return out


def first(v):
    """Orca stores per-variant lists; the first entry is the standard 0.4 nozzle."""
    return v[0] if isinstance(v, list) else v


def per_tool(v):
    return ",".join([str(v)] * TOOLS)


def escape(gcode):
    return gcode.strip("\n").replace("\\", "\\\\").replace("\n", "\\n")


# ── G-code (PrusaSlicer macro language) ──────────────────────────────────────
# Ported from Orca's "Snapmaker U1 (0.4 nozzle)" (dated 2026-01-28 / 06-05 /
# 06-07). Firmware macros are kept as they are. Orca → PrusaSlicer changes:
#   nozzle_temperature[_initial_layer]   → temperature / first_layer_temperature
#   bed_temperature_initial_layer_single → first_layer_bed_temperature[initial_extruder]
#   min_vitrification_temperature        → chosen from the used filaments' types
#   curr_bed_type == "High Temp Plate"   → dropped (no plate types in PrusaSlicer)
#   adaptive_bed_mesh_min/max            → first_layer_print_min/max, clamped to the probe area
#   position[2] = position[2] + 2        → an explicit absolute Z move back to the layer
#   print_sequence == "by object"        → dropped (tool changes lift a fixed 1.5 mm)
# Tools the print doesn't use aren't fed or flow-calibrated (is_extruder_used).

def used_type(types):
    """True if any used tool's filament type is one of `types`."""
    names = ", ".join('"%s"' % t for t in types)
    return " or ".join("(is_extruder_used[%d] and one_of(filament_type[%d], %s))" % (i, i, names) for i in range(TOOLS))


def feed(i):
    return "{if is_extruder_used[%d]}SM_PRINT_AUTO_FEED EXTRUDER=%d\nSM_PRINT_FLOW_CALIBRATE EXTRUDER=%d\n{endif}" % (i, i, i)


def preheat(i):
    return "{if is_extruder_used[%d]}SM_PRINT_EXTRUDER_PREHEAT EXTRUDER=%d TEMP=140\n{endif}" % (i, i)


U1_START = """
; Snapmaker U1 start, PalmSlice port of OrcaSlicer's profile (2026-01-28)
SET_PRINT_AUTO_BED_LEVELING ENABLE=1
SET_TIME_LAPSE_CAMERA ENABLE=1
PRINT_START
DEFECT_DETECTION_START
SET_PRINT_STATS_INFO TOTAL_LAYER={total_layer_count} CURRENT_LAYER=0
TIMELAPSE_START
M140 S{first_layer_bed_temperature[initial_extruder]}
M104 T{initial_extruder} S140
M204 S10000
;===== top cover purifier =====
{if %(soft)s}
SET_PURIFIER_MODE MODE=1 DESIRE_TEMP=42 ALARM_TEMP=48 FAN_SPEED=0.6 DELAY_OFF=0 ; strong cooling
{elsif %(mid)s}
SET_PURIFIER_MODE MODE=1 DESIRE_TEMP=45 ALARM_TEMP=51 FAN_SPEED=0.6 DELAY_OFF=0 ; weak cooling
{else}
SET_PURIFIER_MODE MODE=3 DESIRE_TEMP=45 FAN_SPEED=0.6 DELAY_OFF=600 ; keep warm
{endif}
G28 X Y
DEFECT_DETECT_NOODLE_FIRST
;===== bed foreign object detection =====
T{initial_extruder}
G90
DEFECT_DETECTION_DETECT_BED
;===== toolhead pick-up check =====
SM_PRINT_CHECK_SWITCH_EXTRUDER

;===== auto feed, flow calibration (used tools only) =====
%(preheat1)s%(feed0)s%(preheat2)s%(feed1)s%(preheat3)s%(feed2)s%(feed3)sM104 S0 T0 A0
M104 S0 T1 A0
M104 S0 T2 A0
M104 S0 T3 A0

;===== pre-extrude =====
M104 T{initial_extruder} S{temperature[initial_extruder]}
T{initial_extruder}
M109 T{initial_extruder} S{temperature[initial_extruder]}
SM_PRINT_PREEXTRUDE_FILAMENT INDEX={initial_extruder}
M104 T{initial_extruder} S{temperature[initial_extruder] - 90}

;===== rough homing =====
T{initial_extruder}
M106 S255
M106 P2 S0
MOVE_TO_DISCARD_FILAMENT_POSITION
M109 T{initial_extruder} S{temperature[initial_extruder] - 90}
ROUGHLY_CLEAN_NOZZLE_WITH_DISCARD
MOVE_TO_XY_IDLE_POSITION_EXTRUDER
M107
G28 Z I140 J140

;===== plate detection =====
M107
DETECT_BED_PLATE

;===== deep nozzle clean =====
M106 S255
G90
G0 Z5 F10000
MOVE_TO_DISCARD_FILAMENT_POSITION
M109 S{temperature[initial_extruder] - 50}
ROUGHLY_CLEAN_NOZZLE
MOVE_TO_XY_IDLE_POSITION_EXTRUDER
FINELY_CLEAN_NOZZLE_STAGE_1
M104 S{temperature[initial_extruder] - 90}
G0 Z5 F10000
MOVE_TO_DISCARD_FILAMENT_POSITION
ROUGHLY_CLEAN_NOZZLE
MOVE_TO_XY_IDLE_POSITION_EXTRUDER
FINELY_CLEAN_NOZZLE_STAGE_2

;===== fine homing =====
M106 S255
M109 S{temperature[initial_extruder] - 90}
M190 S{first_layer_bed_temperature[initial_extruder]}
M107 P2
G90
G0 Z5 F10000
WAIT_CHAMBER_TEMP TIMEOUT=180
M107
G28 Z

;===== bed mesh over the first layer =====
M107
; ADAPTIVE=0: the mesh area comes from the slicer (first layer bounds, clamped to the probe area)
BED_MESH_CALIBRATE mesh_min={max(3, first_layer_print_min[0])},{max(3, first_layer_print_min[1])} mesh_max={min(267, first_layer_print_max[0])},{min(267, first_layer_print_max[1])} ADAPTIVE=0 ADAPTIVE_MARGIN=0

;===== prime line =====
G90
G1 Z1.5
G0 X85 Y1 Z2 F18000
M109 S{first_layer_temperature[initial_extruder]}
G1 Z0.2
M83
G1 X185 E15 F360
G1 Z1.5

G90
M106 S0
""" % dict(soft=used_type(["PLA", "PLA-CF", "TPU", "FLEX", "PVA"]),
           mid=used_type(["PETG", "PET", "PCTG", "HIPS"]),
           preheat1=preheat(1), preheat2=preheat(2), preheat3=preheat(3),
           feed0=feed(0), feed1=feed(1), feed2=feed(2), feed3=feed(3))

U1_END = """
; Snapmaker U1 end, PalmSlice port of OrcaSlicer's profile (2026-06-05)
PRINT_END
TIMELAPSE_STOP

; U1 nozzle flow metadata, in logical filament order
; filament_volume_type = standard{if size(filament_type) > 1},standard{endif}{if size(filament_type) > 2},standard{endif}{if size(filament_type) > 3},standard{endif}
"""

U1_TOOLCHANGE = """
; Snapmaker U1 tool change, PalmSlice port of OrcaSlicer's profile (2026-06-07)
; Change Tool[previous_extruder] -> Tool[next_extruder] (layer [layer_num])
G91
G1 Z1.5 F600
G90
G1 F{min(travel_speed, 350) * 60}
{if not (layer_num < 0 and next_extruder == initial_tool)}M109 S{if layer_num == 0}{first_layer_temperature[next_extruder]}{else}{temperature[next_extruder]}{endif} T{next_extruder}
{endif}M400
T{next_extruder}
{if filament_type[next_extruder] == "PVA"}SET_VELOCITY_LIMIT ACCEL=3000
{endif}{if previous_extruder != next_extruder and initial_extruder != next_extruder}SM_PRINT_PREEXTRUDE_FILAMENT INDEX={next_extruder}
{endif}G90
; back down to the layer (PrusaSlicer doesn't track the lift above)
G1 Z{toolchange_z + z_offset} F600
"""

U1_BEFORE_LAYER = """
;BEFORE_LAYER_CHANGE
;[layer_z]
G92 E0
TIMELAPSE_TAKE_FRAME
DEFECT_DETECTION_DETECT
"""

U1_LAYER = """
;AFTER_LAYER_CHANGE
;[layer_z]
SET_PRINT_STATS_INFO TOTAL_LAYER={total_layer_count} CURRENT_LAYER={layer_num+1}
"""


def printer_section():
    o = resolve("machine", PRINTER)
    pair = lambda key, i=0: "%s,%s" % (o[key][i], o[key][i + 1])
    s = {
        "printer_technology": "FFF",
        "printer_model": MODEL,
        "printer_variant": "0.4",
        "printer_notes": "PRINTER_VENDOR_SNAPMAKER\\nPRINTER_MODEL_U1\\nPALMSLICE_UNTESTED",
        "default_print_profile": "0.20 Standard @Snapmaker U1 (0.4 nozzle)",
        "default_filament_profile": ";".join(['"Generic PLA @Snapmaker U1"'] * TOOLS),
        "bed_shape": ",".join(o["printable_area"]),
        "max_print_height": "270",
        "gcode_flavor": "klipper",
        "use_relative_e_distances": "1",
        "use_firmware_retraction": "0",
        "single_extruder_multi_material": "0",
        "nozzle_diameter": per_tool(first(o["nozzle_diameter"])),
        "extruder_offset": per_tool("0x0"),
        "min_layer_height": per_tool(first(o["min_layer_height"])),
        "max_layer_height": per_tool(first(o["max_layer_height"])),
        "retract_length": per_tool(first(o["retraction_length"])),
        "retract_speed": per_tool(first(o["retraction_speed"])),
        "deretract_speed": per_tool(first(o["deretraction_speed"])),
        "retract_length_toolchange": per_tool(first(o["retract_length_toolchange"])),
        "retract_restart_extra": per_tool("0"),
        "retract_restart_extra_toolchange": per_tool("0"),
        "retract_lift": per_tool(first(o["z_hop"])),
        "retract_lift_above": per_tool("0"),
        "retract_lift_below": per_tool(first(o["retract_lift_below"])),
        "retract_before_travel": per_tool(first(o["retraction_minimum_travel"])),
        "retract_layer_change": per_tool("1"),
        "retract_before_wipe": per_tool(first(o["retract_before_wipe"])),
        "wipe": per_tool("1"),
        "extruder_clearance_radius": o["extruder_clearance_radius"],
        "extruder_clearance_height": o["extruder_clearance_height_to_rod"],
        "machine_limits_usage": "time_estimate_only",
        "machine_max_feedrate_x": pair("machine_max_speed_x"),
        "machine_max_feedrate_y": pair("machine_max_speed_y"),
        "machine_max_feedrate_z": pair("machine_max_speed_z"),
        "machine_max_feedrate_e": pair("machine_max_speed_e"),
        "machine_max_acceleration_x": pair("machine_max_acceleration_x"),
        "machine_max_acceleration_y": pair("machine_max_acceleration_y"),
        "machine_max_acceleration_z": pair("machine_max_acceleration_z"),
        "machine_max_acceleration_e": pair("machine_max_acceleration_e"),
        "machine_max_acceleration_extruding": pair("machine_max_acceleration_extruding"),
        "machine_max_acceleration_retracting": pair("machine_max_acceleration_retracting"),
        "machine_max_acceleration_travel": pair("machine_max_acceleration_travel"),
        "machine_max_jerk_x": pair("machine_max_jerk_x"),
        "machine_max_jerk_y": pair("machine_max_jerk_y"),
        "machine_max_jerk_z": pair("machine_max_jerk_z"),
        "machine_max_jerk_e": pair("machine_max_jerk_e"),
        "remaining_times": "1",
        "binary_gcode": "0",
        "thumbnails": "48x48/PNG, 300x300/PNG",
        "multimaterial_purging": "45",
        "pause_print_gcode": "M600",
        "start_gcode": escape(U1_START),
        "end_gcode": escape(U1_END),
        "toolchange_gcode": escape(U1_TOOLCHANGE),
        "before_layer_gcode": escape(U1_BEFORE_LAYER),
        "layer_gcode": escape(U1_LAYER),
    }
    return s


INFILL = {"crosshatch": "grid", "zig-zag": "rectilinear", "monotonicline": "monotoniclines"}
SURFACE = {"monotonicline": "monotoniclines"}
SUPPORT_STYLE = {"normal(auto)": ("snug", "1"), "tree(auto)": ("organic", "1"),
                 "normal(manual)": ("snug", "0"), "tree(manual)": ("organic", "0"), "default": ("snug", "1")}


def print_section(orca_name):
    o = resolve("process", orca_name)
    f = lambda k: str(first(o[k]))
    style, auto = SUPPORT_STYLE.get(o.get("support_type", "default"), ("snug", "1"))
    s = {
        "compatible_printers_condition": 'printer_model=="%s" and nozzle_diameter[0]==0.4' % MODEL,
        "layer_height": f("layer_height"),
        "first_layer_height": f("initial_layer_print_height"),
        "perimeters": f("wall_loops"),
        "top_solid_layers": f("top_shell_layers"),
        "bottom_solid_layers": f("bottom_shell_layers"),
        "top_solid_min_thickness": f("top_shell_thickness"),
        "bottom_solid_min_thickness": f("bottom_shell_thickness"),
        "fill_density": f("sparse_infill_density"),
        "fill_pattern": INFILL.get(f("sparse_infill_pattern"), f("sparse_infill_pattern")),
        "top_fill_pattern": SURFACE.get(f("top_surface_pattern"), f("top_surface_pattern")),
        "bottom_fill_pattern": SURFACE.get(f("bottom_surface_pattern"), f("bottom_surface_pattern")),
        "perimeter_generator": f("wall_generator"),
        "seam_position": f("seam_position"),
        "infill_overlap": f("infill_wall_overlap"),
        "elefant_foot_compensation": f("elefant_foot_compensation"),
        "thin_walls": f("detect_thin_wall"),
        "top_one_perimeter_type": "all" if f("only_one_wall_top") == "1" else "none",
        "extrusion_width": f("line_width"),
        "first_layer_extrusion_width": f("initial_layer_line_width"),
        "perimeter_extrusion_width": f("inner_wall_line_width"),
        "external_perimeter_extrusion_width": f("outer_wall_line_width"),
        "infill_extrusion_width": f("sparse_infill_line_width"),
        "solid_infill_extrusion_width": f("internal_solid_infill_line_width"),
        "top_infill_extrusion_width": f("top_surface_line_width"),
        "support_material_extrusion_width": f("support_line_width"),
        "external_perimeter_speed": f("outer_wall_speed"),
        "perimeter_speed": f("inner_wall_speed"),
        "infill_speed": f("sparse_infill_speed"),
        "solid_infill_speed": f("internal_solid_infill_speed"),
        "top_solid_infill_speed": f("top_surface_speed"),
        "gap_fill_speed": f("gap_infill_speed"),
        "bridge_speed": f("bridge_speed"),
        "support_material_speed": f("support_speed"),
        "support_material_interface_speed": f("support_interface_speed"),
        "travel_speed": f("travel_speed"),
        "first_layer_speed": f("initial_layer_speed"),
        "first_layer_infill_speed": f("initial_layer_infill_speed"),
        "enable_dynamic_overhang_speeds": "1",
        "overhang_speed_0": f("overhang_4_4_speed"),
        "overhang_speed_1": f("overhang_3_4_speed"),
        "overhang_speed_2": f("overhang_2_4_speed"),
        "overhang_speed_3": f("overhang_1_4_speed") if f("overhang_1_4_speed") != "0" else "100%",
        "default_acceleration": f("default_acceleration"),
        "external_perimeter_acceleration": f("outer_wall_acceleration"),
        "top_solid_infill_acceleration": f("top_surface_acceleration"),
        "first_layer_acceleration": f("initial_layer_acceleration"),
        "wipe_tower": f("enable_prime_tower"),
        "wipe_tower_width": f("prime_tower_width"),
        "wipe_tower_brim_width": f("prime_tower_brim_width"),
        # The U1 pre-extrudes each tool itself (SM_PRINT_PREEXTRUDE_FILAMENT).
        "single_extruder_multi_material_priming": "0",
        "ooze_prevention": f("ooze_prevention"),
        "standby_temperature_delta": f("standby_temperature_delta"),
        "support_material": f("enable_support"),
        "support_material_style": style,
        "support_material_auto": auto,
        "support_material_threshold": f("support_threshold_angle"),
        "support_material_contact_distance": f("support_top_z_distance"),
        "support_material_bottom_contact_distance": f("support_bottom_z_distance"),
        "support_material_xy_spacing": f("support_object_xy_distance"),
        "support_material_interface_layers": f("support_interface_top_layers"),
        "support_material_bottom_interface_layers": f("support_interface_bottom_layers"),
        "support_material_buildplate_only": f("support_on_build_plate_only"),
        "support_material_spacing": f("support_base_pattern_spacing"),
        "support_material_interface_spacing": f("support_interface_spacing"),
        "ironing": "0" if f("ironing_type") == "no ironing" else "1",
        "skirts": f("skirt_loops"),
        "skirt_distance": f("skirt_distance"),
        "brim_width": "0",
        "gcode_label_objects": "firmware" if f("exclude_object") == "1" else "octoprint",
        "complete_objects": "1" if f("print_sequence") == "by object" else "0",
    }
    for k in ("inner_wall_acceleration", "sparse_infill_acceleration", "travel_acceleration", "bridge_acceleration"):
        if k in o:
            s[{"inner_wall_acceleration": "perimeter_acceleration", "sparse_infill_acceleration": "infill_acceleration",
               "travel_acceleration": "travel_acceleration", "bridge_acceleration": "bridge_acceleration"}[k]] = f(k)
    return s


FILAMENT_TYPE = {"PET": "PETG"}
COLOURS = {"PLA": "#F2F2F2", "PETG": "#3C8DD8", "TPU": "#333333"}


def filament_section(orca_name):
    o = resolve("filament", orca_name)
    f = lambda k: str(first(o[k]))
    kind = FILAMENT_TYPE.get(f("filament_type"), f("filament_type"))
    pa = "SET_PRESSURE_ADVANCE ADVANCE=%s" % f("pressure_advance") if f("enable_pressure_advance") == "1" else ""
    bed = f("hot_plate_temp")
    return {
        "compatible_printers_condition": 'printer_model=="%s"' % MODEL,
        "filament_vendor": "Generic",
        "filament_type": kind,
        "filament_colour": COLOURS.get(kind, "#808080"),
        "filament_diameter": "1.75",
        "filament_density": f("filament_density"),
        "filament_cost": f("filament_cost"),
        "temperature": f("nozzle_temperature"),
        "first_layer_temperature": f("nozzle_temperature_initial_layer"),
        "bed_temperature": bed,
        "first_layer_bed_temperature": bed,
        "filament_max_volumetric_speed": f("filament_max_volumetric_speed"),
        "extrusion_multiplier": f("filament_flow_ratio"),
        "cooling": "1",
        "fan_always_on": "1" if f("fan_min_speed") != "0" else "0",
        "min_fan_speed": f("fan_min_speed"),
        "max_fan_speed": f("fan_max_speed"),
        "bridge_fan_speed": f("overhang_fan_speed"),
        "disable_fan_first_layers": f("close_fan_the_first_x_layers"),
        "fan_below_layer_time": f("fan_cooling_layer_time"),
        "slowdown_below_layer_time": f("slow_down_layer_time"),
        "min_print_speed": f("slow_down_min_speed"),
        "filament_retract_length": f("filament_retraction_length") if f("filament_retraction_length") != "nil" else "nil",
        "start_filament_gcode": '"%s"' % pa,
    }


def section(header, settings):
    return "[%s]\n" % header + "".join("%s = %s\n" % kv for kv in settings.items()) + "\n"


def main(out):
    text = """# PalmSlice vendor bundle: printers PrusaSlicer's own vendor profiles don't have.
# Generated by scripts/profiles/make_palmslice_bundle.py; edit that, not this file.
# Snapmaker U1 presets are ported from OrcaSlicer's Snapmaker profiles (AGPL-3.0).

[vendor]
name = PalmSlice
config_version = 1.0.0
config_update_url =

[printer_model:%(model)s]
name = %(model)s
variants = 0.4
technology = FFF
family = Snapmaker
default_materials = Generic PLA @Snapmaker U1;Generic PETG @Snapmaker U1;Generic TPU @Snapmaker U1

""" % dict(model=MODEL)
    text += section("printer:" + PRINTER, printer_section())
    for orca, ours in (("0.08 Extra Fine @Snapmaker U1 (0.4 nozzle)", "0.08 Extra Fine @Snapmaker U1 (0.4 nozzle)"),
                       ("0.12 Fine @Snapmaker U1 (0.4 nozzle)", "0.12 Fine @Snapmaker U1 (0.4 nozzle)"),
                       ("0.16 Optimal @Snapmaker U1 (0.4 nozzle)", "0.16 Optimal @Snapmaker U1 (0.4 nozzle)"),
                       ("0.20 Standard @Snapmaker U1 (0.4 nozzle)", "0.20 Standard @Snapmaker U1 (0.4 nozzle)"),
                       ("0.28 Extra Draft @Snapmaker U1 (0.4 nozzle)", "0.28 Extra Draft @Snapmaker U1 (0.4 nozzle)")):
        text += section("print:" + ours, print_section(orca))
    for orca, ours in (("Generic PLA @U1 0.4 nozzle", "Generic PLA @Snapmaker U1"),
                       ("Generic PETG @U1 0.4 nozzle", "Generic PETG @Snapmaker U1"),
                       ("Generic TPU @U1 0.4 nozzle", "Generic TPU @Snapmaker U1")):
        text += section("filament:" + ours, filament_section(orca))
    open(out, "w").write(text)


main(sys.argv[1])
