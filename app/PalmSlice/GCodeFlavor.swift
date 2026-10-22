import Foundation

enum GCodeFlavor: String, CaseIterable, Codable, Identifiable {
    case marlin           = "Marlin"
    case marlin2          = "Marlin 2"
    case klipper          = "Klipper"
    case repRap           = "RepRap (Sprinter)"
    case repRapFirmware   = "RepRap (Firmware)"
    case teacup           = "Teacup"
    case makerWare        = "MakerWare"
    case sailfish         = "Sailfish"
    case mach3            = "Mach3"
    case machineKit       = "MachineKit"
    case smoothie         = "Smoothie"
    case noGCode          = "No G-Code"

    var id: String { rawValue }
}
