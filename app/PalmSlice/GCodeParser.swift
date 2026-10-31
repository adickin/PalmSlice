import Foundation
import simd

// MARK: - Types

enum ExtrusionType: Hashable {
    case externalPerimeter
    case perimeter
    case infill
    case solidInfill
    case topSolidInfill
    case bridgeInfill
    case support
    case supportInterface
    case wipeTower
    case travel
    case other
}

struct GCodeMove {
    var from: SIMD3<Float>
    var to:   SIMD3<Float>
    var type: ExtrusionType
    /// Tool printing the move (0-based, from the last T<n> command).
    var tool: Int = 0
}

struct GCodeLayer {
    var index: Int
    var z: Float
    var moves: [GCodeMove]
}

// MARK: - Parser

/// Parses a PrusaSlicer G-code file into an array of layers, each containing typed moves.
/// Only extrusion moves are included (travel moves are filtered out for visual clarity).
func parseGCode(url: URL) -> [GCodeLayer] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }

    var layers:       [GCodeLayer]  = []
    var currentMoves: [GCodeMove]   = []
    var currentZ:     Float         = 0
    var pos           = SIMD3<Float>(0, 0, 0)
    var currentType:  ExtrusionType = .other
    var relativeE     = true    // M83 = relative E (PrusaSlicer default)
    var relativeXYZ   = false   // G90 = absolute XYZ (PrusaSlicer default)
    var lastE:        Float     = 0
    var inLayer       = false
    var tool          = 0

    for rawLine in text.components(separatedBy: "\n") {
        // Strip inline comment to get the command portion
        let commentIdx = rawLine.firstIndex(of: ";")
        let command    = commentIdx.map { String(rawLine[rawLine.startIndex..<$0]) } ?? rawLine
        let comment    = commentIdx.map { String(rawLine[$0...]) } ?? ""
        let s          = command.trimmingCharacters(in: .whitespaces)

        // Handle comment-only lines for metadata
        if s.isEmpty {
            let trimComment = comment.trimmingCharacters(in: .whitespaces)
            if trimComment.hasPrefix(";LAYER_CHANGE") {
                if inLayer && !currentMoves.isEmpty {
                    layers.append(GCodeLayer(index: layers.count, z: currentZ, moves: currentMoves))
                    currentMoves = []
                }
                inLayer = true
            } else if trimComment.hasPrefix(";Z:") {
                let zStr = String(trimComment.dropFirst(3))
                currentZ = Float(zStr) ?? currentZ
            } else if trimComment.hasPrefix(";TYPE:") {
                let typeName = String(trimComment.dropFirst(6))
                currentType = extrusionType(from: typeName)
            }
            continue
        }

        // Also check comments on lines that have commands
        let trimComment = comment.trimmingCharacters(in: .whitespaces)
        if trimComment.hasPrefix(";LAYER_CHANGE") {
            if inLayer && !currentMoves.isEmpty {
                layers.append(GCodeLayer(index: layers.count, z: currentZ, moves: currentMoves))
                currentMoves = []
            }
            inLayer = true
        } else if trimComment.hasPrefix(";TYPE:") {
            currentType = extrusionType(from: String(trimComment.dropFirst(6)))
        }

        let parts = s.uppercased().components(separatedBy: " ").filter { !$0.isEmpty }
        guard let cmd = parts.first else { continue }

        switch cmd {
        case _ where cmd.count >= 2 && cmd.first == "T" && Int(cmd.dropFirst()) != nil:
            tool = Int(cmd.dropFirst())!   // tool change (also Klipper's T<n> macros)

        case "G90": relativeXYZ = false
        case "G91": relativeXYZ = true
        case "M82": relativeE   = false
        case "M83": relativeE   = true

        case "G0", "G1":
            var newPos = pos
            var hasE   = false
            var eVal:  Float = 0

            for part in parts.dropFirst() {
                guard let first = part.first, let val = Float(part.dropFirst()) else { continue }
                switch first {
                case "X": newPos.x = relativeXYZ ? pos.x + val : val
                case "Y": newPos.y = relativeXYZ ? pos.y + val : val
                case "Z": newPos.z = relativeXYZ ? pos.z + val : val
                case "E": hasE = true; eVal = val
                default:  break
                }
            }

            // Detect extrusion
            var isExtrusion = false
            if hasE {
                if relativeE {
                    isExtrusion = eVal > 0
                } else {
                    isExtrusion = eVal > lastE
                    lastE = eVal
                }
            }

            // Only record moves that have XY displacement (Z-only hops are not useful)
            if inLayer && (newPos.x != pos.x || newPos.y != pos.y) {
                let moveType = isExtrusion ? currentType : ExtrusionType.travel
                // Skip travel moves to keep the visualisation clean
                if moveType != .travel {
                    currentMoves.append(GCodeMove(from: pos, to: newPos, type: moveType, tool: tool))
                }
            }

            pos = newPos

        default:
            break
        }
    }

    // Flush the last layer
    if inLayer && !currentMoves.isEmpty {
        layers.append(GCodeLayer(index: layers.count, z: currentZ, moves: currentMoves))
    }

    return layers
}

// MARK: - Type mapping

private func extrusionType(from name: String) -> ExtrusionType {
    switch name.lowercased().trimmingCharacters(in: .whitespaces) {
    case "external perimeter":         return .externalPerimeter
    case "perimeter":                  return .perimeter
    case "infill":                     return .infill
    case "solid infill":               return .solidInfill
    case "top solid infill":           return .topSolidInfill
    case "bridge infill":              return .bridgeInfill
    case "support material":           return .support
    case "support material interface": return .supportInterface
    case "wipe tower":                 return .wipeTower
    default:                           return .other
    }
}

// MARK: - Summary

/// Totals from a PrusaSlicer G-code file's footer, and its tool changes.
struct GCodeSummary: Equatable {
    var printTime: String?
    /// Filament used per tool, grams (one entry on single-tool printers).
    var filamentG: [Double] = []
    /// Tool changes after the first tool is picked.
    var toolChanges = 0

    var totalFilamentG: Double { filamentG.reduce(0, +) }

    init(text: String) {
        var firstTool = true
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.first == "T", let word = line.split(separator: " ").first, Int(word.dropFirst()) != nil {
                if firstTool { firstTool = false } else { toolChanges += 1 }
            } else if line.hasPrefix("; estimated printing time (normal mode) =") {
                printTime = line.split(separator: "=").last?.trimmingCharacters(in: .whitespaces)
            } else if filamentG.isEmpty, line.hasPrefix("; filament used [g] =") {
                filamentG = line.split(separator: "=").last?.split(separator: ",")
                    .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? []
            }
        }
    }

    init?(url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        self.init(text: text)
    }

    /// "12.34 g", or with several tools "12.34 g (T1 5.10 · T2 7.24)".
    var filamentText: String? {
        guard !filamentG.isEmpty else { return nil }
        let total = String(format: "%.2f g", totalFilamentG)
        let used = filamentG.enumerated().filter { $0.element > 0 }
        guard filamentG.count > 1 else { return total }
        return total + " (" + used.map { String(format: "T%d %.2f", $0.offset + 1, $0.element) }
            .joined(separator: " · ") + ")"
    }
}
