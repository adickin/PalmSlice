import Foundation

// Printer templates seeded into a new install's ProfileStore, and merged
// into existing installs when new templates are added (see
// ProfileStore.mergeInMissingBuiltIns). All were imported from
// PrusaSlicer's bundled vendor profile library. `crealityEnder3S1` is the
// only one print-tested with this app, so it's seeded as verified; the
// rest start in the "untested" list.
enum BuiltInProfiles {
    // MARK: - Imported from PrusaSlicer's vendor profile library

    static let prusaMK3S: PrinterProfile = {
        var p = PrinterProfile()
        p.name = "Prusa i3 MK3S+"
        p.verified = false
        p.builtInKey = "prusa-mk3s"

        p.bedX = 250
        p.bedY = 210
        p.bedZ = 210
        p.buildPlateShape = .rectangular
        p.originAtCenter = false
        p.heatedBed = true

        p.gcodeFlavor = .marlin
        p.startGCode = """
M862.3 P "MK3S" ; printer model check
M862.1 P[nozzle_diameter] ; nozzle diameter check
M115 U3.14.1 ; tell printer latest fw version
G90 ; use absolute coordinates
M83 ; extruder relative mode
M104 S[first_layer_temperature] ; set extruder temp
M140 S[first_layer_bed_temperature] ; set bed temp
M190 S[first_layer_bed_temperature] ; wait for bed temp
M109 S[first_layer_temperature] ; wait for extruder temp
G28 W ; home all without mesh bed level
G80 X{first_layer_print_min[0]} Y{first_layer_print_min[1]} W{(first_layer_print_max[0]) - (first_layer_print_min[0])} H{(first_layer_print_max[1]) - (first_layer_print_min[1])} ; mesh bed levelling
{if filament_settings_id[initial_tool]=~/.*Prusament PA11.*/}
G1 Z0.3 F720
G1 Y-3 F1000 ; go outside print area
G92 E0
G1 X60 E9 F1000 ; intro line
G1 X100 E9 F1000 ; intro line
{else}
G1 Z0.2 F720
G1 Y-3 F1000 ; go outside print area
G92 E0
G1 X60 E9 F1000 ; intro line
G1 X100 E12.5 F1000 ; intro line
{endif}
G92 E0
M221 S{if layer_height<0.075}100{else}95{endif}
"""
        p.endGCode = """
{if layer_z < max_print_height}G1 Z{z_offset+min(max_layer_z+1, max_print_height)} F720 ; Move print head up{endif}
G1 X0 Y200 F3600 ; park
{if layer_z < max_print_height}G1 Z{z_offset+min(max_layer_z+49, max_print_height)} F720 ; Move print head further up{endif}
G4 ; wait
M221 S100 ; reset flow
M900 K0 ; reset LA
{if print_settings_id=~/.*(DETAIL @MK3|QUALITY @MK3|@0.25 nozzle MK3).*/}M907 E538 ; reset extruder motor current{endif}
M104 S0 ; turn off temperature
M140 S0 ; turn off heatbed
M107 ; turn off fan
M84 ; disable motors
"""

        p.printheadXMin = -45
        p.printheadYMin = -45
        p.printheadXMax = 45
        p.printheadYMax = 45
        p.gantryHeight = 20
        p.numberOfExtruders = 1
        p.applyExtruderOffsetsToGCode = true

        var ext = ExtruderProfile()
        ext.nozzleDiameter = 0.4
        ext.compatibleMaterialDiameters = [1.75]
        p.extruders = [ext]

        return p
    }()

    static let prusaMINI: PrinterProfile = {
        var p = PrinterProfile()
        p.name = "Prusa MINI+"
        p.verified = false
        p.builtInKey = "prusa-mini"

        p.bedX = 180
        p.bedY = 180
        p.bedZ = 180
        p.buildPlateShape = .rectangular
        p.originAtCenter = false
        p.heatedBed = true

        p.gcodeFlavor = .marlin2
        p.startGCode = """
M862.3 P "MINI" ; printer model check
G90 ; use absolute coordinates
M83 ; extruder relative mode
M104 S170 ; set extruder temp for bed leveling
M140 S[first_layer_bed_temperature] ; set bed temp
M109 R170 ; wait for bed leveling temp
M190 S[first_layer_bed_temperature] ; wait for bed temp
M204 T1250 ; set travel acceleration
G28 ; home all without mesh bed level
G29 ; mesh bed leveling
M204 T[machine_max_acceleration_travel] ; restore travel acceleration
M104 S[first_layer_temperature] ; set extruder temp
G92 E0
G1 Y-2 X179 F2400
G1 Z3 F720
M109 S[first_layer_temperature] ; wait for extruder temp

; intro line
G1 X170 F1000
G1 Z0.2 F720
G1 X110 E8 F900
G1 X40 E10 F700
G92 E0

M221 S95 ; set flow
"""
        p.endGCode = """
G1 E-1 F2100 ; retract
{if layer_z < max_print_height}G1 Z{z_offset+min(max_layer_z+2, max_print_height)} F720 ; Move print head up{endif}
G1 X178 Y178 F4200 ; park print head
{if layer_z < max_print_height}G1 Z{z_offset+min(max_layer_z+30, max_print_height)} F720 ; Move print head further up{endif}
G4 ; wait
M104 S0 ; turn off temperature
M140 S0 ; turn off heatbed
M107 ; turn off fan
M221 S100 ; reset flow
M900 K0 ; reset LA
M84 ; disable motors
"""

        p.printheadXMin = -35
        p.printheadYMin = -35
        p.printheadXMax = 35
        p.printheadYMax = 35
        p.gantryHeight = 20
        p.numberOfExtruders = 1
        p.applyExtruderOffsetsToGCode = true

        var ext = ExtruderProfile()
        ext.nozzleDiameter = 0.4
        ext.compatibleMaterialDiameters = [1.75]
        p.extruders = [ext]

        return p
    }()

    static let crealityEnder3V2: PrinterProfile = {
        var p = PrinterProfile()
        p.name = "Creality Ender-3 V2"
        p.verified = false
        p.builtInKey = "creality-ender3v2"

        p.bedX = 210
        p.bedY = 220
        p.bedZ = 250
        p.buildPlateShape = .rectangular
        p.originAtCenter = false
        p.heatedBed = true

        p.gcodeFlavor = .marlin
        p.startGCode = Self.crealityStartGCode
        p.endGCode = Self.crealityEndGCode

        p.printheadXMin = -55
        p.printheadYMin = -55
        p.printheadXMax = 55
        p.printheadYMax = 55
        p.gantryHeight = 25
        p.numberOfExtruders = 1
        p.applyExtruderOffsetsToGCode = true

        var ext = ExtruderProfile()
        ext.nozzleDiameter = 0.4
        ext.compatibleMaterialDiameters = [1.75]
        p.extruders = [ext]

        return p
    }()

    static let crealityCR10: PrinterProfile = {
        var p = PrinterProfile()
        p.name = "Creality CR-10"
        p.verified = false
        p.builtInKey = "creality-cr10"

        p.bedX = 300
        p.bedY = 300
        p.bedZ = 400
        p.buildPlateShape = .rectangular
        p.originAtCenter = false
        p.heatedBed = true

        p.gcodeFlavor = .marlin
        p.startGCode = Self.crealityStartGCode
        p.endGCode = Self.crealityEndGCode

        p.printheadXMin = -55
        p.printheadYMin = -55
        p.printheadXMax = 55
        p.printheadYMax = 55
        p.gantryHeight = 25
        p.numberOfExtruders = 1
        p.applyExtruderOffsetsToGCode = true

        var ext = ExtruderProfile()
        ext.nozzleDiameter = 0.4
        ext.compatibleMaterialDiameters = [1.75]
        p.extruders = [ext]

        return p
    }()

    // Shared by Ender-3 V2 and CR-10 — neither overrides the vendor's common start/end gcode.
    private static let crealityStartGCode = """
G90 ; use absolute coordinates
M83 ; extruder relative mode
M104 S{is_nil(idle_temperature[0]) ? 150 : idle_temperature[0]} ; set temporary nozzle temp to prevent oozing during homing
M140 S{first_layer_bed_temperature[0]} ; set final bed temp
G4 S30 ; allow partial nozzle warmup
G28 ; home all axis
G1 Z50 F240
G1 X2.0 Y10 F3000
M104 S{first_layer_temperature[0]} ; set final nozzle temp
M190 S{first_layer_bed_temperature[0]} ; wait for bed temp to stabilize
M109 S{first_layer_temperature[0]} ; wait for nozzle temp to stabilize
G1 Z0.28 F240
G92 E0
G1 X2.0 Y140 E10 F1500 ; prime the nozzle
G1 X2.3 Y140 F5000
G92 E0
G1 X2.3 Y10 E10 F1200 ; prime the nozzle
G92 E0
"""
    private static let crealityEndGCode = """
{if max_layer_z < max_print_height}G1 Z{z_offset+min(max_layer_z+2, max_print_height)} F600 ; Move print head up{endif}
G1 X5 Y{print_bed_max[1]*0.85} F{travel_speed*60} ; present print
{if max_layer_z < max_print_height-10}G1 Z{z_offset+min(max_layer_z+70, max_print_height-10)} F600 ; Move print head further up{endif}
{if max_layer_z < max_print_height*0.6}G1 Z{max_print_height*0.6} F600 ; Move print head further up{endif}
M140 S0 ; turn off heatbed
M104 S0 ; turn off temperature
M107 ; turn off fan
M84 X Y E ; disable motors
"""

    static let anycubicI3Mega: PrinterProfile = {
        var p = PrinterProfile()
        p.name = "Anycubic i3 Mega"
        p.verified = false
        p.builtInKey = "anycubic-i3mega"

        p.bedX = 210
        p.bedY = 210
        p.bedZ = 205
        p.buildPlateShape = .rectangular
        p.originAtCenter = false
        p.heatedBed = true

        p.gcodeFlavor = .marlin
        p.startGCode = """
G90 ; use absolute coordinates
M83 ; extruder relative mode
M204 S[machine_max_acceleration_extruding] T[machine_max_acceleration_retracting]
M104 S[first_layer_temperature] ; set extruder temp
M140 S[first_layer_bed_temperature] ; set bed temp
G28 ; home all
G1 Y1.0 Z0.3 F1000 ; move print head up
M190 S[first_layer_bed_temperature] ; wait for bed temp
M109 S[first_layer_temperature] ; wait for extruder temp
G92 E0.0
; initial load
G1 X205.0 E19 F1000
G1 Y1.6
G1 X5.0 E19 F1000
G92 E0.0
; intro line
G1 Y2.0 Z0.2 F1000
G1 X65.0 E9.0 F1000
G1 X105.0 E12.5 F1000
G92 E0.0
"""
        p.endGCode = """
G1 E-1.0 F2100 ; retract
G92 E0.0
G1{if max_layer_z < max_print_height} Z{z_offset+min(max_layer_z+30, max_print_height)}{endif} E-34.0 F720 ; move print head up & retract filament
G4 ; wait
M104 S0 ; turn off temperature
M140 S0 ; turn off heatbed
M107 ; turn off fan
G1 X0 Y105 F3000 ; park print head
M84 ; disable motors
"""

        p.printheadXMin = -60
        p.printheadYMin = -60
        p.printheadXMax = 60
        p.printheadYMax = 60
        p.gantryHeight = 35
        p.numberOfExtruders = 1
        p.applyExtruderOffsetsToGCode = true

        var ext = ExtruderProfile()
        ext.nozzleDiameter = 0.4
        ext.compatibleMaterialDiameters = [1.75]
        p.extruders = [ext]

        return p
    }()

    static let artillerySidewinderX1: PrinterProfile = {
        var p = PrinterProfile()
        p.name = "Artillery Sidewinder X1"
        p.verified = false
        p.builtInKey = "artillery-sidewinder-x1"

        p.bedX = 300
        p.bedY = 300
        p.bedZ = 400
        p.buildPlateShape = .rectangular
        p.originAtCenter = false
        p.heatedBed = true

        p.gcodeFlavor = .marlin
        p.startGCode = """
; Initial setups
G90 ; use absolute coordinates
M83 ; extruder relative mode
M220 S100 ; reset speed factor to 100%
M221 S100 ; reset extrusion rate to 100%

; Set the heating
M190 S[first_layer_bed_temperature] ; wait for bed to heat up
M104 S[first_layer_temperature] ; start nozzle heating but don't wait

; Home
G1 Z3 F3000 ; move z up little to prevent scratching of surface
G28 ; home all axes
G1 X3 Y3 F5000 ; move to corner of the bed to avoid ooze over centre

; Wait for final heating
M109 S[first_layer_temperature] ; wait for the nozzle to heat up
M190 S[first_layer_bed_temperature] ; wait for the bed to heat up

; Return to prime position, Prime line routine
G92 E0 ; Reset Extruder
G1 Z3 F3000 ; move z up little to prevent scratching of surface
G1 X10 Y.5 Z0.25 F5000.0 ; Move to start position
G1 X100 Y.5 Z0.25 F1500.0 E15 ; Draw the first line
G1 X100 Y.2 Z0.25 F5000.0 ; Move to side a little
G1 X10 Y.2 Z0.25 F1500.0 E30 ; Draw the second line
G92 E0 ; Reset Extruder
M221 S{if layer_height<0.075}100{else}95{endif}
"""
        p.endGCode = """
G4 ; wait
G92 E0 ; prepare to retract
G1 E-0.5 F3000; retract to avoid stringing

; Anti-stringing end wiggle
G91 ; use relative coordinates
G1 X1 Y1 F1200

; Raise nozzle and present bed
{if layer_z < max_print_height}G1 Z{z_offset+min(layer_z+120, max_print_height)}{endif} ; Move print head up
G90 ; use absolute coordinates

; Reset print setting overrides
M200 D0 ; disable volumetric e
M220 S100 ; reset speed factor to 100%
M221 S100 ; reset extrusion rate to 100%

; Shut down printer
M106 S0 ; turn-off fan
M104 S0 ; turn-off hotend
M140 S0 ; turn-off bed
M150 P0 ; turn off led
M85 S0 ; deactivate idle timeout
M84 ; disable motors
"""

        p.printheadXMin = -45
        p.printheadYMin = -45
        p.printheadXMax = 45
        p.printheadYMax = 45
        p.gantryHeight = 25
        p.numberOfExtruders = 1
        p.applyExtruderOffsetsToGCode = true

        var ext = ExtruderProfile()
        ext.nozzleDiameter = 0.4
        ext.compatibleMaterialDiameters = [1.75]
        p.extruders = [ext]

        return p
    }()

    static let crealityEnder3: PrinterProfile = {
        var p = PrinterProfile()
        p.name = "Creality Ender-3"
        p.verified = false
        p.builtInKey = "creality-ender3"

        p.bedX = 228
        p.bedY = 228
        p.bedZ = 250
        p.buildPlateShape = .rectangular
        p.originAtCenter = false
        p.heatedBed = true

        p.gcodeFlavor = .marlin
        p.startGCode = """
G90 ; use absolute coordinates
M83 ; extruder relative mode
M104 S{is_nil(idle_temperature[0]) ? 150 : idle_temperature[0]} ; set temporary nozzle temp to prevent oozing during homing
M140 S{first_layer_bed_temperature[0]} ; set final bed temp
G4 S30 ; allow partial nozzle warmup
G28 ; home all axis
G1 Z50 F240
G1 X2.0 Y10 F3000
M104 S{first_layer_temperature[0]} ; set final nozzle temp
M190 S{first_layer_bed_temperature[0]} ; wait for bed temp to stabilize
M109 S{first_layer_temperature[0]} ; wait for nozzle temp to stabilize
G1 Z0.28 F240
G92 E0
G1 X2.0 Y140 E10 F1500 ; prime the nozzle
G1 X2.3 Y140 F5000
G92 E0
G1 X2.3 Y10 E10 F1200 ; prime the nozzle
G92 E0
"""
        p.endGCode = """
{if max_layer_z < max_print_height}G1 Z{z_offset+min(max_layer_z+2, max_print_height)} F600 ; Move print head up{endif}
G1 X5 Y{print_bed_max[1]*0.85} F{travel_speed*60} ; present print
{if max_layer_z < max_print_height-10}G1 Z{z_offset+min(max_layer_z+70, max_print_height-10)} F600 ; Move print head further up{endif}
{if max_layer_z < max_print_height*0.6}G1 Z{max_print_height*0.6} F600 ; Move print head further up{endif}
M140 S0 ; turn off heatbed
M104 S0 ; turn off temperature
M107 ; turn off fan
M84 X Y E ; disable motors
"""

        p.printheadXMin = -55
        p.printheadYMin = -55
        p.printheadXMax = 55
        p.printheadYMax = 55
        p.gantryHeight = 25
        p.numberOfExtruders = 1
        p.applyExtruderOffsetsToGCode = true

        var ext = ExtruderProfile()
        ext.nozzleDiameter = 0.4
        ext.compatibleMaterialDiameters = [1.75]
        p.extruders = [ext]

        return p
    }()

    // Print-tested on a real Ender-3 S1 (2026-10-21). Replaced the app's
    // original hand-written Ender 3 S1 profile (builtInKey "ender3s1"),
    // which ProfileStore removes from existing installs.
    static let crealityEnder3S1: PrinterProfile = {
        var p = PrinterProfile()
        p.name = "Creality Ender-3 S1"
        p.verified = true
        p.builtInKey = "creality-ender3s1-vendor"

        p.bedX = 215
        p.bedY = 220
        p.bedZ = 270
        p.buildPlateShape = .rectangular
        p.originAtCenter = false
        p.heatedBed = true

        p.gcodeFlavor = .marlin
        p.startGCode = """
G90 ; use absolute coordinates
M83 ; extruder relative mode
M104 S{is_nil(idle_temperature[0]) ? 150 : idle_temperature[0]} ; set temporary nozzle temp to prevent oozing during homing
M140 S{first_layer_bed_temperature[0]} ; set final bed temp
G4 S30 ; allow partial nozzle warmup
G28 ; home all axis and restore leveling
G1 Z50 F240
G1 X2.0 Y10 F3000
M104 S{first_layer_temperature[0]} ; set final nozzle temp
M190 S{first_layer_bed_temperature[0]} ; wait for bed temp to stabilize
M109 S{first_layer_temperature[0]} ; wait for nozzle temp to stabilize
G1 Z0.28 F240
G92 E0
G1 X2.0 Y140 E10 F1500 ; prime the nozzle
G1 X2.3 Y140 F5000
G92 E0
G1 X2.3 Y10 E10 F1200 ; prime the nozzle
G92 E0
"""
        p.endGCode = """
{if max_layer_z < max_print_height}G1 Z{z_offset+min(max_layer_z+2, max_print_height)} F600 ; Move print head up{endif}
G1 X5 Y{print_bed_max[1]*0.85} F{travel_speed*60} ; present print
{if max_layer_z < max_print_height-10}G1 Z{z_offset+min(max_layer_z+70, max_print_height-10)} F600 ; Move print head further up{endif}
{if max_layer_z < max_print_height*0.6}G1 Z{max_print_height*0.6} F600 ; Move print head further up{endif}
M140 S0 ; turn off heatbed
M104 S0 ; turn off temperature
M107 ; turn off fan
M84 X Y E ; disable motors
"""

        p.printheadXMin = -55
        p.printheadYMin = -55
        p.printheadXMax = 55
        p.printheadYMax = 55
        p.gantryHeight = 25
        p.numberOfExtruders = 1
        p.applyExtruderOffsetsToGCode = true

        var ext = ExtruderProfile()
        ext.nozzleDiameter = 0.4
        ext.compatibleMaterialDiameters = [1.75]
        p.extruders = [ext]

        return p
    }()

    static let crealityEnder5: PrinterProfile = {
        var p = PrinterProfile()
        p.name = "Creality Ender-5"
        p.verified = false
        p.builtInKey = "creality-ender5"

        p.bedX = 215
        p.bedY = 220
        p.bedZ = 300
        p.buildPlateShape = .rectangular
        p.originAtCenter = false
        p.heatedBed = true

        p.gcodeFlavor = .marlin
        p.startGCode = """
G90 ; use absolute coordinates
M83 ; extruder relative mode
M104 S{is_nil(idle_temperature[0]) ? 150 : idle_temperature[0]} ; set temporary nozzle temp to prevent oozing during homing
M140 S{first_layer_bed_temperature[0]} ; set final bed temp
G4 S30 ; allow partial nozzle warmup
G28 ; home all axis
G1 Z50 F240
G1 X2.0 Y10 F3000
M104 S{first_layer_temperature[0]} ; set final nozzle temp
M190 S{first_layer_bed_temperature[0]} ; wait for bed temp to stabilize
M109 S{first_layer_temperature[0]} ; wait for nozzle temp to stabilize
G1 Z0.28 F240
G92 E0
G1 X2.0 Y140 E10 F1500 ; prime the nozzle
G1 X2.3 Y140 F5000
G92 E0
G1 X2.3 Y10 E10 F1200 ; prime the nozzle
G92 E0
"""
        p.endGCode = """
{if max_layer_z < max_print_height}G1 Z{z_offset+min(max_layer_z+2, max_print_height)} F600{endif} ; Move print bed down
G1 X50 Y50 F{travel_speed*60} ; move print head out of the way
{if max_layer_z < max_print_height-10}G1 Z{z_offset+max_print_height-10} F600{endif} ; Move print bed close to the bottom
M140 S0 ; turn off heatbed
M104 S0 ; turn off temperature
M107 ; turn off fan
M84 X Y E ; disable motors
"""

        p.printheadXMin = -55
        p.printheadYMin = -55
        p.printheadXMax = 55
        p.printheadYMax = 55
        p.gantryHeight = 25
        p.numberOfExtruders = 1
        p.applyExtruderOffsetsToGCode = true

        var ext = ExtruderProfile()
        ext.nozzleDiameter = 0.4
        ext.compatibleMaterialDiameters = [1.75]
        p.extruders = [ext]

        return p
    }()

    static let prusaMk4: PrinterProfile = {
        var p = PrinterProfile()
        p.name = "Prusa MK4"
        p.verified = false
        p.builtInKey = "prusa-mk4"

        p.bedX = 250
        p.bedY = 210
        p.bedZ = 220
        p.buildPlateShape = .rectangular
        p.originAtCenter = false
        p.heatedBed = true

        p.gcodeFlavor = .marlin2
        p.startGCode = """
M17 ; enable steppers
M862.3 P "MK4" ; printer model check
M862.1 P[nozzle_diameter] A{(filament_abrasive[0] ? 1 : 0)} F{(nozzle_high_flow[0] ? 1 : 0)} ; nozzle check
M115 U6.2.6+8948
M555 X{(min(print_bed_max[0], first_layer_print_min[0] + 32) - 32)} Y{(max(0, first_layer_print_min[1]) - 4)} W{((min(print_bed_max[0], max(first_layer_print_min[0] + 32, first_layer_print_max[0])))) - ((min(print_bed_max[0], first_layer_print_min[0] + 32) - 32))} H{((first_layer_print_max[1])) - ((max(0, first_layer_print_min[1]) - 4))}

G90 ; use absolute coordinates
M83 ; extruder relative mode

M140 S[first_layer_bed_temperature] ; set bed temp
M104 T0 S{((filament_notes[0]=~/.*MBL160.*/) ? 160 : (filament_notes[0]=~/.*HT_MBL10.*/) ? (first_layer_temperature[0] - 10) : (filament_type[0] == "PC" or filament_type[0] == "PA") ? (first_layer_temperature[0] - 25) : (filament_type[0] == "FLEX") ? 210 : (filament_type[0]=~/.*PET.*/) ? 175 : 170)} ; set extruder temp for bed leveling
M109 T0 R{((filament_notes[0]=~/.*MBL160.*/) ? 160 : (filament_notes[0]=~/.*HT_MBL10.*/) ? (first_layer_temperature[0] - 10) : (filament_type[0] == "PC" or filament_type[0] == "PA") ? (first_layer_temperature[0] - 25) : (filament_type[0] == "FLEX") ? 210 : (filament_type[0]=~/.*PET.*/) ? 175 : 170)} ; wait for temp

M84 E ; turn off E motor

G28 ; home all without mesh bed level

G1 X42 Y-4 Z5 F4800

M302 S155 ; lower cold extrusion limit to 155C

{if filament_type[initial_tool]=="FLEX"}
G1 E-4 F2400 ; retraction
{else}
G1 E-2 F2400 ; retraction
{endif}

M84 E ; turn off E motor

G29 P9 X10 Y-4 W32 H4

{if first_layer_bed_temperature[initial_tool]<=60}M106 S100{endif}

G0 Z40 F10000

M190 S[first_layer_bed_temperature] ; wait for bed temp

M107

;
; MBL
;
M84 E ; turn off E motor
G29 P1 ; invalidate mbl & probe print area
G29 P1 X0 Y0 W50 H20 C ; probe near purge place
G29 P3.2 ; interpolate mbl probes
G29 P3.13 ; extrapolate mbl outside probe area
G29 A ; activate mbl

; prepare for purge
M104 S{first_layer_temperature[0]}
G0 X0 Y-4 Z15 F4800 ; move away and ready for the purge
M109 S{first_layer_temperature[0]}

G92 E0
M569 S0 E ; set spreadcycle mode for extruder

;
; Extrude purge line
;
G92 E0 ; reset extruder position
G1 E{(filament_type[0] == "FLEX" ? 4 : 2)} F2400 ; deretraction after the initial one before nozzle cleaning
G0 E7 X15 Z0.2 F500 ; purge
G0 X25 E4 F500 ; purge
G0 X35 E4 F650 ; purge
G0 X45 E4 F800 ; purge
G0 X48 Z0.05 F8000 ; wipe, move close to the bed
G0 X51 Z0.2 F8000 ; wipe, move quickly away from the bed

G92 E0
M221 S100 ; set flow to 100%
"""
        p.endGCode = """
{if layer_z < max_print_height}G1 Z{z_offset+min(max_layer_z+1, max_print_height)} F720 ; Move print head up{endif}
M104 S0 ; turn off temperature
M140 S0 ; turn off heatbed
M107 ; turn off fan
G1 X241 Y170 F3600 ; park
{if layer_z < max_print_height}G1 Z{z_offset+min(max_layer_z+23, max_print_height)} F300 ; Move print head up{endif}
G4 ; wait
M900 K0 ; reset LA
M142 S36 ; reset heatbreak target temp
M84 X Y E ; disable motors
; max_layer_z = [max_layer_z]
"""

        p.printheadXMin = -45
        p.printheadYMin = -45
        p.printheadXMax = 45
        p.printheadYMax = 45
        p.gantryHeight = 13
        p.numberOfExtruders = 1
        p.applyExtruderOffsetsToGCode = true

        var ext = ExtruderProfile()
        ext.nozzleDiameter = 0.4
        ext.compatibleMaterialDiameters = [1.75]
        p.extruders = [ext]

        return p
    }()

    static let elegooNeptune3Pro: PrinterProfile = {
        var p = PrinterProfile()
        p.name = "Elegoo Neptune-3 Pro"
        p.verified = false
        p.builtInKey = "elegoo-neptune3pro"

        p.bedX = 225
        p.bedY = 225
        p.bedZ = 280
        p.buildPlateShape = .rectangular
        p.originAtCenter = false
        p.heatedBed = true

        p.gcodeFlavor = .marlin
        p.startGCode = """
M413 S0 ; disable Power Loss Recovery
G90 ; use absolute coordinates
M83 ; extruder relative mode
M104 S120 ; set temporary nozzle temp to prevent oozing during homing and auto bed leveling
M140 S[first_layer_bed_temperature] ; set final bed temp
G4 S10 ; allow partial nozzle warmup
G28 ; home all axis
;G29 ; run abl mesh
M420 S1 ; load mesh
G1 Z50 F240
G1 X2 Y10 F3000
M104 S[first_layer_temperature] ; set final nozzle temp
M190 S[first_layer_bed_temperature] ; wait for bed temp to stabilize
M109 S[first_layer_temperature] ; wait for nozzle temp to stabilize
G1 Z0.28 F240
G92 E0
G1 Y140 E10 F1500 ; prime the nozzle
G1 X2.3 F5000
G92 E0
G1 Y10 E10 F1200 ; prime the nozzle
G92 E0
"""
        p.endGCode = """
{if max_layer_z < max_print_height}G1 Z{z_offset+min(max_layer_z+2, max_print_height)} F600 ; Move print head up{endif}
G1 X5 Y{print_bed_max[1]*0.8} F{travel_speed*60} ; present print
{if max_layer_z < max_print_height-10}G1 Z{z_offset+min(max_layer_z+70, max_print_height-10)} F600 ; Move print head further up{endif}
{if max_layer_z < max_print_height*0.6}G1 Z{max_print_height*0.6} F600 ; Move print head further up{endif}
M140 S0 ; turn off heatbed
M104 S0 ; turn off temperature
M107 ; turn off fan
M84 X Y E ; disable motors
"""

        p.printheadXMin = -45
        p.printheadYMin = -45
        p.printheadXMax = 45
        p.printheadYMax = 45
        p.gantryHeight = 25
        p.numberOfExtruders = 1
        p.applyExtruderOffsetsToGCode = true

        var ext = ExtruderProfile()
        ext.nozzleDiameter = 0.4
        ext.compatibleMaterialDiameters = [1.75]
        p.extruders = [ext]

        return p
    }()

    static let sovolSv06: PrinterProfile = {
        var p = PrinterProfile()
        p.name = "Sovol SV06"
        p.verified = false
        p.builtInKey = "sovol-sv06"

        p.bedX = 220
        p.bedY = 220
        p.bedZ = 250
        p.buildPlateShape = .rectangular
        p.originAtCenter = false
        p.heatedBed = true

        p.gcodeFlavor = .marlin
        p.startGCode = """
M104 S[first_layer_temperature] ; set extruder temp
M140 S[first_layer_bed_temperature] ; set bed temp
M190 S[first_layer_bed_temperature] ; wait for bed temp
M109 S[first_layer_temperature] ; wait for extruder temp
G28;
G1 Z4.0 F3000 ;Move Z Axis up
G92 E0 ;Reset Extruder
G1 X5.1 Y20 Z0.28 F5000.0 ;Move to start position
G1 X5.1 Y30.0 Z0.28 F1500.0 E1 ;Draw a short bit in case the extruder turns in the wrong direction
G1 X5.1 Y200.0 Z0.28 F1500.0 E15 ;Draw the first line
G1 X5.4 Y200.0 Z0.28 F5000.0 ;Move to side a little
G1 X5.4 Y20 Z0.28 F1500.0 E30 ;Draw the second line
G92 E0 ;Reset Extruder
G1 Z2.0 F3000 ;Move Z Axis up
"""
        p.endGCode = """
G91 ;Relative positioning
G1 X5 Y5 F3000 ;Wipe out
G1 Z10 ;Raise Z more
G90 ;Absolute positioning
G1 X10 Y220 ;Present print
M106 S0 ;Turn-off fan
M104 S0 ;Turn-off hotend
M140 S0 ;Turn-off bed
M84 X Y E ;Disable all steppers but Z
"""

        p.printheadXMin = -45
        p.printheadYMin = -45
        p.printheadXMax = 45
        p.printheadYMax = 45
        p.gantryHeight = 20
        p.numberOfExtruders = 1
        p.applyExtruderOffsetsToGCode = true

        var ext = ExtruderProfile()
        ext.nozzleDiameter = 0.4
        ext.compatibleMaterialDiameters = [1.75]
        p.extruders = [ext]

        return p
    }()

    static let voronV2350: PrinterProfile = {
        var p = PrinterProfile()
        p.name = "Voron 2.4 (350)"
        p.verified = false
        p.builtInKey = "voron-v2-350"

        p.bedX = 350
        p.bedY = 350
        p.bedZ = 330
        p.buildPlateShape = .rectangular
        p.originAtCenter = false
        p.heatedBed = true

        p.gcodeFlavor = .klipper
        p.startGCode = """
print_start EXTRUDER=[first_layer_temperature[initial_tool]] BED=[first_layer_bed_temperature]
"""
        p.endGCode = """
print_end    ;end script from macro
"""

        p.printheadXMin = -70
        p.printheadYMin = -70
        p.printheadXMax = 70
        p.printheadYMax = 70
        p.gantryHeight = 20
        p.numberOfExtruders = 1
        p.applyExtruderOffsetsToGCode = true

        var ext = ExtruderProfile()
        ext.nozzleDiameter = 0.4
        ext.compatibleMaterialDiameters = [1.75]
        p.extruders = [ext]

        return p
    }()

    static let verified: [PrinterProfile] = [crealityEnder3S1]

    static let untested: [PrinterProfile] = [
        prusaMK3S,
        prusaMINI,
        crealityEnder3V2,
        crealityCR10,
        anycubicI3Mega,
        artillerySidewinderX1,
        crealityEnder3,
        crealityEnder5,
        prusaMk4,
        elegooNeptune3Pro,
        sovolSv06,
        voronV2350,
    ]

    // PrusaSlicer system printer preset each built-in corresponds to (the 0.4 mm
    // nozzle variant), by builtInKey. Applied as the base layer of every slice;
    // ProfileStore also fills it into saved copies of these built-ins.
    static let systemPresetNames: [String: String] = [
        "prusa-mk3s":               "Original Prusa i3 MK3S & MK3S+",
        "prusa-mini":               "Original Prusa MINI & MINI+",
        "creality-ender3v2":        "Creality Ender-3 V2 (0.4 mm nozzle)",
        "creality-cr10":            "Creality CR-10 (0.4 mm nozzle)",
        "anycubic-i3mega":          "Anycubic i3 Mega",
        "artillery-sidewinder-x1":  "Artillery Sidewinder X1",
        "creality-ender3":          "Creality Ender-3 (0.4 mm nozzle)",
        "creality-ender3s1-vendor": "Creality Ender-3 S1 (0.4 mm nozzle)",
        "creality-ender5":          "Creality Ender-5 (0.4 mm nozzle)",
        "prusa-mk4":                "Original Prusa MK4 0.4 nozzle",
        "elegoo-neptune3pro":       "Elegoo Neptune-3 Pro",
        "sovol-sv06":               "SV06",
        "voron-v2-350":             "Voron_v2_350 0.4 nozzle",
    ]

    static let all: [PrinterProfile] = (verified + untested).map { profile in
        var p = profile
        p.systemPreset = p.builtInKey.flatMap { systemPresetNames[$0] }
        return p
    }
}
