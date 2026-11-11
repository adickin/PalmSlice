import Foundation
import simd

/// Finds room on the plate for new models (Duplicate, Fill Plate).
/// Coordinates are mm relative to the bed centre, print X right / Y back.
/// Footprints are convex outlines (ModelTransform.footprintMM).
///
/// The bed is sampled on a grid; each footprint is grown by half the spacing,
/// so placed models end up at least `spacingMM` apart.
enum PlateArrange {
    /// Gap between models, like OrcaSlicer's default arrange spacing.
    static let spacingMM: Float = 6
    /// Grid cell size.
    static let cellMM: Float = 1

    /// The printer's bed outline, relative to its centre.
    static func bed(_ printer: PrinterProfile) -> [SIMD2<Float>] {
        let cx = printer.originAtCenter ? 0 : printer.bedX / 2
        let cy = printer.originAtCenter ? 0 : printer.bedY / 2
        return printer.bedOutline().map { SIMD2(Float($0.0 - cx), Float($0.1 - cy)) }
    }

    /// The wipe tower's footprint (brim included), relative to the bed centre.
    static func footprint(_ tower: WipeTowerFootprint, bedCentre: SIMD2<Double>) -> [SIMD2<Float>] {
        let a = tower.rotationDeg * .pi / 180
        let corners = [(-tower.brim, -tower.brim), (tower.width + tower.brim, -tower.brim),
                       (tower.width + tower.brim, tower.depth + tower.brim), (-tower.brim, tower.depth + tower.brim)]
        return corners.map { x, y in
            SIMD2(Float(tower.x + x * cos(a) - y * sin(a) - bedCentre.x),
                  Float(tower.y + x * sin(a) + y * cos(a) - bedCentre.y))
        }
    }

    /// Where each of `items` (footprints around their own origin) goes so it
    /// stays on the bed and clear of `fixed` (footprints in place) and of the
    /// items placed before it; nil for those that don't fit. Each goes as near
    /// `prefer` as it can, or, without it, packs in rows from the front left.
    static func place(_ items: [[SIMD2<Float>]], around fixed: [[SIMD2<Float>]],
                      bed: [SIMD2<Float>], prefer: SIMD2<Float>? = nil) -> [SIMD2<Float>?] {
        guard bed.count >= 3 else { return items.map { _ in nil } }
        var grid = Grid(bed: bed)
        let slack = cellMM * 0.75                  // cells are sampled at their centres
        let pad = spacingMM / 2 + slack
        for f in fixed { grid.occupy(grown(f, by: pad)) }

        var cells = Array(0..<(grid.w * grid.h))
        if let prefer {
            let d = cells.map { simd_distance_squared(grid.centre($0), prefer) }
            cells.sort { d[$0] < d[$1] }
        }
        var results: [SIMD2<Float>?] = []
        var body: [Span] = [], padded: [Span] = []
        var start = 0   // packing identical items in rows: the cells before the last one stay full
        for (k, item) in items.enumerated() {
            if k == 0 || item != items[k - 1] {
                body = grid.spans(grown(item, by: slack))
                padded = grid.spans(grown(item, by: pad))
                start = 0
            }
            var spot: SIMD2<Float>? = nil
            var i = body.isEmpty ? cells.count : prefer == nil ? start : 0
            while i < cells.count {
                if grid.fits(body: body, pad: padded, at: cells[i]) {
                    grid.occupy(padded, at: cells[i])
                    spot = grid.centre(cells[i])
                    start = i + 1
                    break
                }
                i += 1
            }
            results.append(spot)
            if spot == nil { start = cells.count }
        }
        return results
    }

    /// How many copies of a footprint could fit on the bed at most (by area).
    static func maxCopies(of footprint: [SIMD2<Float>], bed: [SIMD2<Float>]) -> Int {
        // The outline grown by half the spacing.
        let area = Self.area(footprint) + perimeter(footprint) * spacingMM / 2 + .pi * spacingMM * spacingMM / 4
        guard area > 1 else { return 0 }
        return min(200, Int(Self.area(bed) / area))
    }

    static func area(_ polygon: [SIMD2<Float>]) -> Float {
        guard polygon.count > 2 else { return 0 }
        var sum: Float = 0
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    static func perimeter(_ polygon: [SIMD2<Float>]) -> Float {
        guard polygon.count > 1 else { return 0 }
        return polygon.indices.reduce(0) { $0 + simd_distance(polygon[$1], polygon[($1 + 1) % polygon.count]) }
    }

    /// A convex outline grown by `d` (its corners rounded).
    static func grown(_ polygon: [SIMD2<Float>], by d: Float) -> [SIMD2<Float>] {
        let ring = (0..<12).map { i -> SIMD2<Float> in
            let a = Float(i) / 12 * 2 * .pi
            return SIMD2(cos(a), sin(a)) * d
        }
        return ModelTransform.convexHull(polygon.flatMap { p in ring.map { p + $0 } })
    }

    /// Whether `p` is inside a convex polygon (either winding).
    static func contains(_ polygon: [SIMD2<Float>], _ p: SIMD2<Float>) -> Bool {
        guard polygon.count >= 3 else { return false }
        var sign: Float = 0
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            let c = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
            if c == 0 { continue }
            if sign == 0 { sign = c } else if (c > 0) != (sign > 0) { return false }
        }
        return true
    }

    /// One row of a footprint's cells, relative to the cell it's centred on.
    private struct Span { var dj: Int; var di0: Int; var di1: Int }

    /// The bed sampled in cells: which are on the bed and which are taken,
    /// with per-row prefix sums so a footprint's row checks in one step.
    private struct Grid {
        let origin: SIMD2<Float>
        let w: Int, h: Int
        /// Per row, (w + 1) running counts of cells off the bed / taken.
        var offBed: [Int32]
        var taken: [Int32]

        init(bed: [SIMD2<Float>]) {
            let lo = bed.reduce(SIMD2<Float>(repeating: .infinity)) { simd_min($0, $1) }
            let hi = bed.reduce(SIMD2<Float>(repeating: -.infinity)) { simd_max($0, $1) }
            origin = lo
            w = max(1, Int(((hi.x - lo.x) / cellMM).rounded(.down)))
            h = max(1, Int(((hi.y - lo.y) / cellMM).rounded(.down)))
            offBed = Array(repeating: 0, count: (w + 1) * h)
            taken = Array(repeating: 0, count: (w + 1) * h)
            for j in 0..<h {
                for i in 0..<w {
                    let off: Int32 = PlateArrange.contains(bed, centre(j * w + i)) ? 0 : 1
                    offBed[j * (w + 1) + i + 1] = offBed[j * (w + 1) + i] + off
                }
            }
        }

        func centre(_ cell: Int) -> SIMD2<Float> {
            origin + SIMD2(Float(cell % w) + 0.5, Float(cell / w) + 0.5) * cellMM
        }

        /// The rows of cells a convex footprint centred on a cell covers.
        func spans(_ polygon: [SIMD2<Float>]) -> [Span] {
            let lo = polygon.reduce(SIMD2<Float>(repeating: .infinity)) { simd_min($0, $1) }
            let hi = polygon.reduce(SIMD2<Float>(repeating: -.infinity)) { simd_max($0, $1) }
            var out: [Span] = []
            for dj in Int((lo.y / cellMM).rounded(.down))...Int((hi.y / cellMM).rounded(.up)) {
                let row = (Int((lo.x / cellMM).rounded(.down))...Int((hi.x / cellMM).rounded(.up)))
                    .filter { PlateArrange.contains(polygon, SIMD2(Float($0), Float(dj)) * cellMM) }
                if let first = row.first, let last = row.last { out.append(Span(dj: dj, di0: first, di1: last)) }
            }
            return out
        }

        /// Count in row j, columns i0...i1, of a prefix-summed table; nil if off the grid.
        private func count(_ table: [Int32], _ j: Int, _ i0: Int, _ i1: Int) -> Int32? {
            guard j >= 0, j < h, i0 >= 0, i1 < w else { return nil }
            return table[j * (w + 1) + i1 + 1] - table[j * (w + 1) + i0]
        }

        /// The body on the bed, its padded outline clear of other models.
        func fits(body: [Span], pad: [Span], at cell: Int) -> Bool {
            let i = cell % w, j = cell / w
            for s in body {
                guard count(offBed, j + s.dj, i + s.di0, i + s.di1) == 0 else { return false }
            }
            for s in pad {
                let jj = j + s.dj
                guard jj >= 0, jj < h else { continue }
                if let n = count(taken, jj, max(0, i + s.di0), min(w - 1, i + s.di1)), n > 0 { return false }
            }
            return true
        }

        mutating func occupy(_ spans: [Span], at cell: Int) {
            let i = cell % w, j = cell / w
            for s in spans {
                let jj = j + s.dj
                guard jj >= 0, jj < h else { continue }
                mark(row: jj, max(0, i + s.di0), min(w - 1, i + s.di1))
            }
        }

        /// Marks the cells a footprint in place covers.
        mutating func occupy(_ polygon: [SIMD2<Float>]) {
            for j in 0..<h {
                let row = (0..<w).filter { PlateArrange.contains(polygon, centre(j * w + $0)) }
                if let first = row.first, let last = row.last { mark(row: j, first, last) }
            }
        }

        private mutating func mark(row j: Int, _ i0: Int, _ i1: Int) {
            guard i0 <= i1 else { return }
            let base = j * (w + 1)
            var cells = (0..<w).map { taken[base + $0 + 1] - taken[base + $0] }
            for i in i0...i1 { cells[i] = 1 }
            for i in 0..<w { taken[base + i + 1] = taken[base + i] + cells[i] }
        }
    }
}
