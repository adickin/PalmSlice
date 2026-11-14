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

/// Layers and footer totals from one read of a G-code file.
struct ParsedGCode {
    var layers: [GCodeLayer] = []
    var summary = GCodeSummary()
    /// True when any extrusion is printed by a tool other than T0.
    var usesSeveralTools = false
}

/// Parses an OrcaSlicer (or PrusaSlicer) G-code file into an array of layers, each containing typed moves.
/// Only extrusion moves are included (travel moves are filtered out for visual clarity).
func parseGCode(url: URL) -> [GCodeLayer] {
    parseGCodeFile(url: url)?.layers ?? []
}

/// Reads the file once and returns its layers and summary; nil when it can't be read.
func parseGCodeFile(url: URL) -> ParsedGCode? {
    guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
    return parseGCode(data: data)
}

/// Byte-level parser: a big plate's G-code is tens of MB, so lines are never copied into Strings.
/// Understands both OrcaSlicer tag sets: the generic `;LAYER_CHANGE` / `;Z:` / `;TYPE:` and the
/// Bambu Lab `; CHANGE_LAYER` / `; Z_HEIGHT:` / `; FEATURE:` written when `is_BBL_printer()`.
func parseGCode(data: Data) -> ParsedGCode {
    var result = ParsedGCode()
    var currentMoves: [GCodeMove]   = []
    var currentZ:     Float         = 0
    var pos           = SIMD3<Float>(0, 0, 0)
    var currentType:  ExtrusionType = .other
    var relativeE     = true    // M83 = relative E (PrusaSlicer default)
    var relativeXYZ   = false   // G90 = absolute XYZ (PrusaSlicer default)
    var lastE:        Float     = 0
    var inLayer       = false
    var tool          = 0
    var firstTool     = true

    func flushLayer() {
        if inLayer && !currentMoves.isEmpty {
            result.layers.append(GCodeLayer(index: result.layers.count, z: currentZ, moves: currentMoves))
            currentMoves = []
        }
    }

    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let bytes = raw.bindMemory(to: UInt8.self)
        let n = bytes.count
        var lineStart = 0
        var words: [GCodeBytes] = []
        while lineStart < n {
            var lineEnd = lineStart
            while lineEnd < n && bytes[lineEnd] != 0x0A { lineEnd += 1 }
            let next = lineEnd + 1
            var end = lineEnd
            if end > lineStart && bytes[end - 1] == 0x0D { end -= 1 }   // CRLF

            var semi = lineStart
            while semi < end && bytes[semi] != 0x3B { semi += 1 }        // ';'

            // Comment tags
            if semi < end {
                var c = semi + 1
                while c < end && (bytes[c] == 0x20 || bytes[c] == 0x09) { c += 1 }
                let comment = GCodeBytes(base: bytes, start: c, end: end)
                if comment.hasPrefix("LAYER_CHANGE") || comment.hasPrefix("CHANGE_LAYER") {
                    flushLayer()
                    inLayer = true
                } else if comment.hasPrefix("Z:") {
                    currentZ = comment.float(from: 2) ?? currentZ
                } else if comment.hasPrefix("Z_HEIGHT:") {
                    currentZ = comment.float(from: 9) ?? currentZ
                } else if comment.hasPrefix("TYPE:") {
                    currentType = extrusionType(from: comment.string(from: 5))
                } else if comment.hasPrefix("FEATURE:") {
                    currentType = extrusionType(from: comment.string(from: 8))
                } else if semi == lineStart {
                    parseSummaryComment(comment, into: &result.summary)
                }
            }

            // Command words, split on spaces and tabs
            words.removeAll(keepingCapacity: true)
            var w = lineStart
            while w < semi {
                while w < semi && (bytes[w] == 0x20 || bytes[w] == 0x09) { w += 1 }
                let ws = w
                while w < semi && bytes[w] != 0x20 && bytes[w] != 0x09 { w += 1 }
                if w > ws { words.append(GCodeBytes(base: bytes, start: ws, end: w)) }
            }
            lineStart = next
            guard let cmd = words.first else { continue }

            switch cmd.upperLetter(0) {
            case 0x54:   // T<n>: tool change (also Klipper's T<n> macros)
                if cmd.count >= 2, let t = cmd.int(from: 1) {
                    tool = t
                    if firstTool { firstTool = false } else { result.summary.toolChanges += 1 }
                }
            case 0x47:   // G
                guard let g = cmd.int(from: 1) else { break }
                switch g {
                case 90: relativeXYZ = false
                case 91: relativeXYZ = true
                case 92:
                    for word in words.dropFirst() where word.upperLetter(0) == 0x45 {
                        lastE = word.float(from: 1) ?? lastE
                    }
                case 0, 1, 2, 3:
                    var newPos = pos
                    var hasE = false
                    var eVal: Float = 0
                    var centre = SIMD2<Float>(pos.x, pos.y)
                    var hasCentre = false
                    for word in words.dropFirst() {
                        guard let val = word.float(from: 1) else { continue }
                        switch word.upperLetter(0) {
                        case 0x58: newPos.x = relativeXYZ ? pos.x + val : val
                        case 0x59: newPos.y = relativeXYZ ? pos.y + val : val
                        case 0x5A: newPos.z = relativeXYZ ? pos.z + val : val
                        case 0x45: hasE = true; eVal = val
                        case 0x49: centre.x = pos.x + val; hasCentre = true
                        case 0x4A: centre.y = pos.y + val; hasCentre = true
                        default:   break
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

                    // Only record extrusions; travel is skipped to keep the visualisation clean.
                    if inLayer && isExtrusion {
                        let path = g >= 2 && hasCentre
                            ? arcPoints(from: pos, to: newPos, centre: centre, clockwise: g == 2)
                            : [newPos]
                        var from = pos
                        for to in path {
                            // Z-only hops are not useful
                            if to.x != from.x || to.y != from.y {
                                currentMoves.append(GCodeMove(from: from, to: to, type: currentType, tool: tool))
                                if tool != 0 { result.usesSeveralTools = true }
                            }
                            from = to
                        }
                    }
                    pos = newPos
                default: break
                }
            case 0x4D:   // M
                switch cmd.int(from: 1) {
                case 82: relativeE = false
                case 83: relativeE = true
                default: break
                }
            default: break
            }
        }
    }

    // Flush the last layer
    flushLayer()
    return result
}

/// Points along a G2 (clockwise) or G3 arc, ending at `to`; Z moves linearly.
/// The same start and end point is a full circle.
func arcPoints(from: SIMD3<Float>, to: SIMD3<Float>, centre: SIMD2<Float>, clockwise: Bool) -> [SIMD3<Float>] {
    let r0 = SIMD2(from.x, from.y) - centre
    let r1 = SIMD2(to.x, to.y) - centre
    let radius = simd_length(r0)
    guard radius > 1e-4 else { return [to] }
    let a0 = atan2(r0.y, r0.x)
    var sweep = atan2(r1.y, r1.x) - a0
    if clockwise {
        if sweep >= -1e-6 { sweep -= 2 * .pi }
    } else {
        if sweep <= 1e-6 { sweep += 2 * .pi }
    }
    // Segments of at most ~0.5 mm and 10°, enough for the preview.
    let segments = max(1, min(720, Int((abs(sweep) * max(radius / 0.5, 18 / .pi)).rounded(.up))))
    var points: [SIMD3<Float>] = []
    points.reserveCapacity(segments)
    for i in 1..<segments {
        let t = Float(i) / Float(segments)
        let a = a0 + sweep * t
        points.append(SIMD3(centre.x + radius * cos(a), centre.y + radius * sin(a), from.z + (to.z - from.z) * t))
    }
    points.append(to)
    return points
}

/// Footer lines: generic `; estimated printing time (normal mode) = …`, Bambu
/// `; model printing time: …; total estimated time: …`, and `; filament used [g] = …`.
private func parseSummaryComment(_ comment: GCodeBytes, into summary: inout GCodeSummary) {
    if summary.printTime == nil, comment.hasPrefix("estimated printing time (normal mode) =") {
        summary.printTime = comment.string(from: 39).trimmingCharacters(in: .whitespaces)
    } else if summary.printTime == nil, comment.hasPrefix("model printing time:") {
        let text = comment.string(from: 0)
        if let r = text.range(of: "total estimated time:") {
            summary.printTime = text[r.upperBound...].trimmingCharacters(in: .whitespaces)
        }
    } else if summary.filamentG.isEmpty, comment.hasPrefix("filament used [g] =") {
        summary.filamentG = comment.string(from: 19).split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }
}

/// A slice of a line's bytes, without copying.
private struct GCodeBytes {
    let base: UnsafeBufferPointer<UInt8>
    let start: Int
    let end: Int

    var count: Int { end - start }

    func hasPrefix(_ prefix: StaticString) -> Bool {
        let len = prefix.utf8CodeUnitCount
        guard count >= len else { return false }
        let p = prefix.utf8Start
        for i in 0..<len where base[start + i] != p[i] { return false }
        return true
    }

    /// The byte at `offset`, upper-cased if it's a letter; 0 past the end.
    func upperLetter(_ offset: Int) -> UInt8 {
        guard start + offset < end else { return 0 }
        let b = base[start + offset]
        return (b >= 0x61 && b <= 0x7A) ? b - 0x20 : b
    }

    func string(from offset: Int) -> String {
        guard start + offset < end else { return "" }
        return String(decoding: UnsafeBufferPointer(rebasing: base[(start + offset)..<end]), as: UTF8.self)
    }

    func int(from offset: Int) -> Int? {
        var i = start + offset
        guard i < end else { return nil }
        var v = 0
        while i < end {
            let d = Int(base[i]) - 0x30
            guard d >= 0 && d <= 9 else { return nil }
            v = v &* 10 &+ d
            i += 1
        }
        return v
    }

    /// A decimal number starting at `offset` (sign, digits, point, exponent); leading spaces skipped.
    func float(from offset: Int) -> Float? {
        var i = start + offset
        while i < end && base[i] == 0x20 { i += 1 }
        guard i < end else { return nil }
        var negative = false
        if base[i] == 0x2D { negative = true; i += 1 } else if base[i] == 0x2B { i += 1 }
        var mantissa: Double = 0
        var scale: Double = 1
        var digits = 0
        var fraction = false
        while i < end {
            let b = base[i]
            if b >= 0x30 && b <= 0x39 {
                if fraction { scale /= 10; mantissa += Double(b - 0x30) * scale }
                else { mantissa = mantissa * 10 + Double(b - 0x30) }
                digits += 1
            } else if b == 0x2E && !fraction {
                fraction = true
            } else if b == 0x45 || b == 0x65, digits > 0 {
                var e = i + 1
                var expNeg = false
                if e < end && (base[e] == 0x2D || base[e] == 0x2B) { expNeg = base[e] == 0x2D; e += 1 }
                var exp = 0
                var expDigits = 0
                while e < end, base[e] >= 0x30, base[e] <= 0x39 { exp = exp * 10 + Int(base[e] - 0x30); e += 1; expDigits += 1 }
                guard expDigits > 0 else { return nil }
                mantissa *= pow(10, Double(expNeg ? -exp : exp))
                i = e
                break
            } else {
                break
            }
            i += 1
        }
        guard digits > 0 else { return nil }
        return Float(negative ? -mantissa : mantissa)
    }
}

// MARK: - Type mapping

/// OrcaSlicer's ;TYPE: names (ExtrusionEntity.cpp role_to_string); the
/// PrusaSlicer names are kept for G-code sliced by PalmSlice's PrusaSlicer backend.
private func extrusionType(from name: String) -> ExtrusionType {
    switch name.lowercased().trimmingCharacters(in: .whitespaces) {
    case "outer wall", "overhang wall",
         "external perimeter", "overhang perimeter":     return .externalPerimeter
    case "inner wall", "perimeter":                       return .perimeter
    case "sparse infill", "infill":                       return .infill
    case "internal solid infill", "bottom surface", "gap infill",
         "solid infill", "gap fill":                      return .solidInfill
    case "top surface", "ironing", "top solid infill":    return .topSolidInfill
    case "bridge", "internal bridge", "bridge infill":    return .bridgeInfill
    case "support", "support transition",
         "support material":                              return .support
    case "support interface",
         "support material interface":                    return .supportInterface
    case "prime tower", "wipe tower":                     return .wipeTower
    default:                                              return .other
    }
}

// MARK: - Summary

/// Totals from an OrcaSlicer G-code file's footer (generic or Bambu Lab flavour), and its tool changes.
struct GCodeSummary: Equatable {
    var printTime: String?
    /// Filament used per tool, grams (one entry on single-tool printers).
    var filamentG: [Double] = []
    /// Tool changes after the first tool is picked.
    var toolChanges = 0

    var totalFilamentG: Double { filamentG.reduce(0, +) }

    init() {}

    init(text: String) {
        self = parseGCode(data: Data(text.utf8)).summary
    }

    init?(url: URL) {
        guard let parsed = parseGCodeFile(url: url) else { return nil }
        self = parsed.summary
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
