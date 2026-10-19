# PalmSlice — App Store Connect Listing Draft

Copy/paste material for App Store Connect. Screenshots are the one item that
can't be drafted here — see the bottom of this file.

## App Information

- **Name:** PalmSlice
- **Subtitle (30 chars max):** On-device 3D print slicer
- **Primary category:** Utilities (alternative: Graphics & Design)
- **Secondary category:** Productivity
- **Bundle ID:** `com.adickin.PalmSlice`
- **Support URL:** https://github.com/adickin/ISlicer/issues
- **Marketing URL (optional):** https://github.com/adickin/ISlicer
- **Privacy Policy URL:** https://github.com/adickin/ISlicer/blob/main/PRIVACY.md
- **Copyright:** © 2026 Adam Dickin

## Promotional Text (170 chars max)

Slice STL files into printer-ready G-code right on your iPhone or iPad. No account, no cloud — slicing runs on your device. Send G-code straight to OctoPrint.

## Description

PalmSlice is a 3D printing slicer that runs entirely on your iPhone or iPad. Open an STL, position it on a virtual build plate, slice it, preview every layer, and export G-code to your printer — without a computer.

Under the hood it uses libslic3r, the same slicing engine that powers PrusaSlicer.

SLICE ANYWHERE
• Import STL files from the Files app
• Slice on-device — no cloud, no account, no internet connection needed
• Preview the sliced model layer by layer before you export
• Rename and export G-code to Files, AirDrop, or anywhere via the share sheet
• Upload directly to OctoPrint — pick a folder or create a new one

PLACE AND ADJUST MODELS
• Move, rotate, and scale with on-screen 3D gizmos or type exact values
• Lay Flat, Drop to Bed, Center, and Fit to Bed helpers
• Load several models at once, with collision and out-of-bounds highlighting
• Size warnings when a model looks like it was exported in the wrong units

PROFILES FOR YOUR PRINTER
• Built-in printer profiles imported from PrusaSlicer's vendor library, including Creality, Prusa, Elegoo, Sovol, Anycubic, Artillery, and Voron models
• Separate printer, material, and slicing profiles — create, edit, and reuse your own
• Control layer height, walls, infill, supports, brim/skirt/raft, ironing, speeds, temperatures, retraction, and fan settings

PRIVATE BY DESIGN
PalmSlice collects no data. No analytics, no accounts, no servers of ours. The only network connection is the optional OctoPrint upload to a server you set up.

PROFILE NOTE
Profiles other than the Ender 3 S1 have not been print-tested and are marked "Untested" in the app. Please verify first layers and start/end G-code on your own printer.

PalmSlice is open-source software licensed under AGPL-3.0. Source code and licenses are linked from the in-app About screen.

## Keywords (100 chars max, comma-separated, no spaces)

3d printing,slicer,gcode,stl,prusa,ender,creality,printer,fdm,3d print,layer preview,filament

## What's New (Version 1.0)

First release.

## Age Rating

Answer "None" to every content question (no objectionable content, no user-generated content, no web access, no purchases). Expected rating: **4+**.

## App Privacy ("nutrition label")

**Data Not Collected.** Matches `PRIVACY.md` and `PrivacyInfo.xcprivacy`
(no collected data types, no tracking, `UserDefaults` declared with reason `CA92.1`).

## Export Compliance

`ITSAppUsesNonExemptEncryption = false` is already set in Info.plist — answer
"No" if asked about encryption. (The OctoPrint upload uses only OS-provided
HTTPS via URLSession, which is exempt.)

## App Review Notes

PalmSlice has no login. Network access is used only for the optional OctoPrint
upload (Export → Set Up OctoPrint), which needs a user-run OctoPrint server on
the local network; everything else works offline. To test: tap the + / import
button, choose any `.stl` file from Files (or use a sample), pick a printer and
slice profile, then tap Slice, review the layer preview, and tap Export G-code.
The app is open source (AGPL-3.0): https://github.com/adickin/ISlicer

## Screenshots (still needed — manual)

Apple requires at least one set; 6.9" (iPhone 16/17 Pro Max class, 1320×2868)
is the required size, 6.5" and iPad sizes optional. Suggested shots:

1. A model loaded on the build plate with the move gizmo showing
2. Layer preview mid-slice with the layer slider
3. The printer profile picker (shows Verified / Untested sections)
4. The expanded settings panel with the Slice and Export buttons
5. Transform panel with typed mm sizing

Capture from the simulator (`xcrun simctl io booted screenshot`) with an
iPhone 16 Pro Max / 17 Pro Max destination, or from a device.
