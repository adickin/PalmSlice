import simd

// Recomputes isIntersecting on every model in-place using world-space OBB pairs (SAT).
// Also marks models that extend outside the bed XY footprint.
func checkIntersections(models: inout [PlacedModel], bedX: Double = 220, bedY: Double = 220) {
    for i in models.indices { models[i].isIntersecting = false }

    let obbs: [OBB?] = models.map(computeOBB(model:))

    // Bed half-extents in SceneKit units (bed Y depth maps to SceneKit Z).
    let bedHX = Float(bedX) / 200
    let bedHZ = Float(bedY) / 200

    for i in models.indices {
        guard let a = obbs[i] else { continue }

        // Out-of-bed check: project OBB corners into XZ and compare to bed footprint.
        let (minX, maxX, minZ, maxZ) = obbXZExtents(a)
        if minX < -bedHX || maxX > bedHX || minZ < -bedHZ || maxZ > bedHZ {
            models[i].isIntersecting = true
        }

        // Model-model overlap check using OBB-OBB SAT.
        for j in (i + 1)..<models.count {
            guard let b = obbs[j] else { continue }
            if obbsOverlap(a, b) {
                models[i].isIntersecting = true
                models[j].isIntersecting = true
            }
        }
    }
}

// MARK: - OBB

private struct OBB {
    let center: SIMD3<Float>
    let he: SIMD3<Float>                                           // half-extents along each local axis
    let axes: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)          // local X, Y, Z unit vectors in world space
}

private func computeOBB(model: PlacedModel) -> OBB? {
    guard let info = model.meshInfo else { return nil }
    let t = model.transform
    let s = t.scale

    // OBB half-extents in the pivot's local frame (before rotation), after scale.
    // Pivot scale remapping: SceneKit X←s.x, SceneKit Y←s.z, SceneKit Z←s.y
    let heX: Float = (info.sizeMMX / 200) * s.x
    let heY: Float = (info.sizeMMZ / 200) * s.z   // half of full height (sizeMMZ/100 / 2)
    let heZ: Float = (info.sizeMMY / 200) * s.y

    let r = t.rotationDeg * (.pi / 180)
    // SceneKit's pivot rotation: X, then Y (rz), then Z (ry) — see ModelTransform.minWorldY.
    let q = simd_quaternion(r.y, SIMD3<Float>(0, 0, 1))
          * simd_quaternion(r.z, SIMD3<Float>(0, 1, 0))
          * simd_quaternion(r.x, SIMD3<Float>(1, 0, 0))

    let axX = simd_act(q, SIMD3<Float>(1, 0, 0))
    let axY = simd_act(q, SIMD3<Float>(0, 1, 0))
    let axZ = simd_act(q, SIMD3<Float>(0, 0, 1))

    // Center of the unscaled box in pivot local space is (0, heY_unscaled, 0).
    // After scale it becomes (0, heY, 0) — same axis, just scaled value.
    let pivotPos = SIMD3<Float>(t.positionMM.x / 100, t.positionMM.z / 100, t.positionMM.y / 100)
    let center   = simd_act(q, SIMD3<Float>(0, heY, 0)) + pivotPos

    return OBB(center: center, he: SIMD3(heX, heY, heZ), axes: (axX, axY, axZ))
}

// MARK: - OBB-OBB SAT

private func obbsOverlap(_ a: OBB, _ b: OBB) -> Bool {
    let T = b.center - a.center
    let aAxes = [a.axes.0, a.axes.1, a.axes.2]
    let bAxes = [b.axes.0, b.axes.1, b.axes.2]

    // Returns true when the given axis L separates the two OBBs.
    // Works with unnormalized axes — scaling both sides by |L| preserves the inequality.
    func separates(_ L: SIMD3<Float>) -> Bool {
        let t = abs(simd_dot(T, L))
        let rA = a.he.x * abs(simd_dot(aAxes[0], L))
               + a.he.y * abs(simd_dot(aAxes[1], L))
               + a.he.z * abs(simd_dot(aAxes[2], L))
        let rB = b.he.x * abs(simd_dot(bAxes[0], L))
               + b.he.y * abs(simd_dot(bAxes[1], L))
               + b.he.z * abs(simd_dot(bAxes[2], L))
        return t > rA + rB
    }

    // Test 6 face-normal axes (A's and B's local axes).
    for ax in aAxes { if separates(ax) { return false } }
    for bx in bAxes { if separates(bx) { return false } }

    // Test 9 edge cross-product axes.
    for ax in aAxes {
        for bx in bAxes {
            let L = simd_cross(ax, bx)
            // Skip near-degenerate axes (parallel source edges); already covered above.
            if simd_length_squared(L) < 1e-6 { continue }
            if separates(L) { return false }
        }
    }

    return true
}

// MARK: - Bed footprint helper

private func obbXZExtents(_ obb: OBB) -> (minX: Float, maxX: Float, minZ: Float, maxZ: Float) {
    var minX: Float =  .infinity, maxX: Float = -.infinity
    var minZ: Float =  .infinity, maxZ: Float = -.infinity
    let signs: [Float] = [-1, 1]
    for sx in signs {
        for sy in signs {
            for sz in signs {
                let corner = obb.center
                           + obb.axes.0 * (obb.he.x * sx)
                           + obb.axes.1 * (obb.he.y * sy)
                           + obb.axes.2 * (obb.he.z * sz)
                minX = min(minX, corner.x); maxX = max(maxX, corner.x)
                minZ = min(minZ, corner.z); maxZ = max(maxZ, corner.z)
            }
        }
    }
    return (minX, maxX, minZ, maxZ)
}
