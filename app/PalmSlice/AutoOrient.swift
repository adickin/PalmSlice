import SceneKit
import simd

/// Auto-orient: picks the rotation that needs the least support. Candidate
/// "down" directions (the axes, the model's largest flat faces, and an even
/// spread over the sphere) are scored by overhanging area, with flat contact
/// on the bed and a low height as tie-breakers.
enum AutoOrient {
    /// Faces steeper than this from straight down (degrees) need no support.
    static let overhangAngle: Float = 45

    /// The best rotation for the mesh, as a ModelTransform.rotationDeg.
    static func rotation(for info: STLMeshInfo) -> SIMD3<Float> {
        rotationDeg(placing: bestDown(info))
    }

    /// The STL-frame direction (unit) that should point down.
    static func bestDown(_ info: STLMeshInfo) -> SIMD3<Float> {
        var best = SIMD3<Float>(0, 0, -1)
        var bestScore = score(info, down: best)
        for d in candidates(info) {
            let s = score(info, down: d)
            if s < bestScore - 1e-3 { best = d; bestScore = s }
        }
        return best
    }

    /// Lower is better: overhanging area, less a share of the flat area on the
    /// bed, plus a little for height.
    static func score(_ info: STLMeshInfo, down d: SIMD3<Float>) -> Float {
        // With d pointing down, a point's height is -p·d and a normal's z is -n·d.
        var zMin = Float.infinity, zMax = -Float.infinity
        for v in info.vertices {
            let z = -simd_dot(v, d)
            zMin = min(zMin, z); zMax = max(zMax, z)
        }
        let limit = -cos(overhangAngle * .pi / 180)
        var overhang: Float = 0, contact: Float = 0, total: Float = 0
        for (i, face) in info.faces.enumerated() {
            total += face.area
            let nz = -simd_dot(face.normal, d)
            guard nz < limit else { continue }
            let base = i * 3
            let faceTop = info.vertices.count >= base + 3
                ? max(-simd_dot(info.vertices[base], d), -simd_dot(info.vertices[base + 1], d), -simd_dot(info.vertices[base + 2], d))
                : zMin
            if nz < -0.99 && faceTop - zMin < 0.1 {
                contact += face.area   // flat on the bed
            } else {
                overhang += face.area
            }
        }
        let height = zMax - zMin
        return overhang - 0.3 * contact + 0.05 * height * total.squareRoot()
    }

    static func candidates(_ info: STLMeshInfo) -> [SIMD3<Float>] {
        var dirs: [SIMD3<Float>] = [[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]]
        // The normals of the largest flat areas (normals grouped to ~3°).
        var areaByNormal: [SIMD3<Int32>: (n: SIMD3<Float>, area: Float)] = [:]
        for face in info.faces where face.area > 0 {
            let key = SIMD3<Int32>((face.normal * 20).rounded(.toNearestOrAwayFromZero))
            let e = areaByNormal[key]
            areaByNormal[key] = (e?.n ?? face.normal, (e?.area ?? 0) + face.area)
        }
        dirs += areaByNormal.values.sorted { $0.area > $1.area }.prefix(40).map(\.n)
        // An even spread (Fibonacci sphere).
        let count = 200
        let golden = Float.pi * (3 - 5.0.squareRoot().float)
        for i in 0..<count {
            let z = 1 - 2 * (Float(i) + 0.5) / Float(count)
            let r = (1 - z * z).squareRoot()
            dirs.append(SIMD3(r * cos(golden * Float(i)), r * sin(golden * Float(i)), z))
        }
        return dirs.map(simd_normalize)
    }

    /// ModelTransform.rotationDeg that turns the STL-frame direction `d` straight down.
    static func rotationDeg(placing d: SIMD3<Float>) -> SIMD3<Float> {
        let down = SIMD3<Float>(0, 0, -1)
        let dot = max(-1, min(1, simd_dot(simd_normalize(d), down)))
        let q: simd_quatf
        if dot > 0.9999 { return .zero }
        if dot < -0.9999 { q = simd_quatf(angle: .pi, axis: [1, 0, 0]) }
        else { q = simd_quatf(angle: acos(dot), axis: simd_normalize(simd_cross(d, down))) }
        // The model's pivot frame is SceneKit's: STL (x, y, z) is (x, z, -y) there.
        let axis = q.axis
        let pivot = simd_quatf(angle: q.angle, axis: SIMD3(axis.x, axis.z, -axis.y))
        let node = SCNNode()
        node.simdOrientation = pivot
        let e = node.simdEulerAngles * (180 / .pi)
        // The pivot's eulerAngles are (rotationDeg.x, rotationDeg.z, rotationDeg.y).
        return SIMD3(e.x, e.z, e.y)
    }
}

private extension Double {
    var float: Float { Float(self) }
}
