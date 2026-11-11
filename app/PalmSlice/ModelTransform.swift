import simd
import SceneKit

struct ModelTransform: Equatable {
    var positionMM: SIMD3<Float> = .zero      // mm offset in SceneKit world space
    var rotationDeg: SIMD3<Float> = .zero     // Euler angles in degrees, SceneKit ZYX order
    var scale: SIMD3<Float> = SIMD3(1, 1, 1)

    static let identity = ModelTransform()

    var isIdentity: Bool { self == .identity }

    /// The rotation in SceneKit space. Pivot eulerAngles = (rx, rz, ry);
    /// SceneKit applies X, then Y, then Z: Rz(ry) * Ry(rz) * Rx(rx)
    /// (AutoOrientTests checks this against SCNNode).
    var rotationQuaternion: simd_quatf {
        let r = rotationDeg * (.pi / 180)
        return simd_quaternion(r.y, SIMD3<Float>(0,0,1))
             * simd_quaternion(r.z, SIMD3<Float>(0,1,0))
             * simd_quaternion(r.x, SIMD3<Float>(1,0,0))
    }

    // MARK: - Drop to bed

    /// Minimum world-space Y (SceneKit units) produced by this transform, ignoring positionMM.
    /// The 8 AABB corners of the model (in pivot space: Y from 0 to height, centred in X/Z)
    /// are scaled and rotated, then the minimum Y is returned.
    func minWorldY(meshInfo: STLMeshInfo) -> Float {
        let s = scale
        let q = rotationQuaternion

        // The mesh node centers geometry in X/Z and places its bottom at pivot Y=0.
        // SCNGeometry vertices are scaled by 1/100 in buildGeometry (mm → SceneKit units).
        // STL vertex (vx, vy, vz) in mm maps to pivot space (SceneKit units) as:
        //   pivot_x = (vx - cx) / 100 * s.x
        //   pivot_y = (vz - minZ) / 100 * s.z    (STL Z = height → SceneKit Y)
        //   pivot_z = (cy - vy) / 100 * s.y      (STL Y = depth → SceneKit -Z)
        let bb = meshInfo.boundingBoxMM
        let cx: Float = (bb.min.x + bb.max.x) * 0.5
        let cy: Float = (bb.min.y + bb.max.y) * 0.5
        let minBZ: Float = bb.min.z
        let mm2u: Float = 1.0 / 100.0

        if !meshInfo.vertices.isEmpty {
            var minY: Float = .infinity
            for v in meshInfo.vertices {
                let p = SIMD3<Float>((v.x - cx) * mm2u * s.x,
                                    (v.z - minBZ) * mm2u * s.z,
                                    (cy - v.y) * mm2u * s.y)
                let wy = simd_act(q, p).y
                if wy < minY { minY = wy }
            }
            return minY == .infinity ? 0 : minY
        }

        // Fallback: 8-corner AABB (less accurate for non-box geometry when rotated).
        let hx: Float = meshInfo.sizeMMX / 200
        let hy: Float = meshInfo.sizeMMZ / 100
        let hz: Float = meshInfo.sizeMMY / 200
        let corners: [SIMD3<Float>] = [
            SIMD3<Float>(-hx * s.x, 0,        -hz * s.y),
            SIMD3<Float>( hx * s.x, 0,        -hz * s.y),
            SIMD3<Float>(-hx * s.x, hy * s.z, -hz * s.y),
            SIMD3<Float>( hx * s.x, hy * s.z, -hz * s.y),
            SIMD3<Float>(-hx * s.x, 0,         hz * s.y),
            SIMD3<Float>( hx * s.x, 0,         hz * s.y),
            SIMD3<Float>(-hx * s.x, hy * s.z,  hz * s.y),
            SIMD3<Float>( hx * s.x, hy * s.z,  hz * s.y),
        ]
        return corners.map { simd_act(q, $0).y }.min() ?? 0
    }

    /// Copy of this transform with positionMM.z adjusted so the model bottom sits exactly on the bed.
    /// positionMM.z is print Z (the vertical axis); maps to SceneKit Y via the pivot position.
    func droppedToBed(meshInfo: STLMeshInfo) -> ModelTransform {
        var t = self
        t.positionMM.z = -minWorldY(meshInfo: meshInfo) * 100
        return t
    }

    // MARK: - Footprint

    /// The model's outline seen from above: the convex hull of its rotated and
    /// scaled mesh in print coordinates (mm, X right, Y back), relative to
    /// positionMM. Empty without vertices.
    func footprintMM(meshInfo: STLMeshInfo) -> [SIMD2<Float>] {
        let s = scale
        let q = rotationQuaternion
        let bb = meshInfo.boundingBoxMM
        let cx = (bb.min.x + bb.max.x) * 0.5
        let cy = (bb.min.y + bb.max.y) * 0.5
        // Same mapping as minWorldY, in mm; SceneKit -Z is print Y.
        let points = meshInfo.vertices.map { v -> SIMD2<Float> in
            let w = simd_act(q, SIMD3<Float>((v.x - cx) * s.x, (v.z - bb.min.z) * s.z, (cy - v.y) * s.y))
            return SIMD2(w.x, -w.z)
        }
        return Self.convexHull(points)
    }

    /// Counter-clockwise convex hull (Andrew's monotone chain).
    static func convexHull(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        let p = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard p.count > 2 else { return p }
        func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [SIMD2<Float>] = [], upper: [SIMD2<Float>] = []
        for pt in p {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], pt) <= 0 { lower.removeLast() }
            lower.append(pt)
        }
        for pt in p.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], pt) <= 0 { upper.removeLast() }
            upper.append(pt)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }
}
