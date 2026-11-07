import simd
import Foundation

/// Compute per-model collision flags using actual mesh triangles (BVH-based)
/// for model-model and projected mesh vertices for the bed footprint.
/// Safe to call from a background thread — reads only the snapshot passed in.
/// Returns the set of model IDs that either overlap another model or extend
/// outside the bed.
func preciseIntersectionResults(
    models: [PlacedModel],
    bedX: Double,
    bedY: Double
) -> Set<UUID> {
    var intersecting = Set<UUID>()
    let bedHX = Float(bedX) / 200
    let bedHZ = Float(bedY) / 200

    struct Entry {
        let id: UUID
        let info: STLMeshInfo
        let bvh: TriangleBVH
        let worldM: simd_float4x4
        let worldMin: SIMD3<Float>
        let worldMax: SIMD3<Float>
    }

    var entries = [Entry]()
    entries.reserveCapacity(models.count)
    for m in models {
        guard let info = m.meshInfo, let bvh = m.bvh else { continue }
        let M = worldTransformMatrix(m.transform, info: info)
        let (mn, mx) = transformAABB(bvh.rootAABBMin, bvh.rootAABBMax, M)
        entries.append(Entry(id: m.id, info: info, bvh: bvh,
                             worldM: M, worldMin: mn, worldMax: mx))
    }

    // Bed footprint — vertex-based test in world XZ.
    for e in entries {
        // Fast path: if world AABB is fully inside the bed, nothing to check.
        if e.worldMin.x >= -bedHX && e.worldMax.x <=  bedHX
        && e.worldMin.z >= -bedHZ && e.worldMax.z <=  bedHZ {
            continue
        }
        var outside = false
        for v in e.info.vertices {
            let w = transformPoint(v, e.worldM)
            if w.x < -bedHX || w.x > bedHX || w.z < -bedHZ || w.z > bedHZ {
                outside = true
                break
            }
        }
        if outside { intersecting.insert(e.id) }
    }

    // Pairwise model-model — AABB pre-filter, then BVH-vs-BVH.
    for i in 0..<entries.count {
        let a = entries[i]
        for j in (i + 1)..<entries.count {
            let b = entries[j]
            if !aabbsOverlap(a.worldMin, a.worldMax, b.worldMin, b.worldMax) {
                continue
            }
            if a.bvh.intersects(b.bvh,
                                selfTransform: a.worldM,
                                otherTransform: b.worldM) {
                intersecting.insert(a.id)
                intersecting.insert(b.id)
            }
        }
    }

    return intersecting
}

// MARK: - World transform

/// 4×4 matrix mapping a raw STL vertex (mm, mesh-local) to its world
/// position in SceneKit units, matching how STLSceneView places the pivot.
///
/// Composed of:
///   1. Centre/anchor — subtract origin (cx, cy, minZ) to centre X/Z and
///      anchor Y at the bed.
///   2. Remap+scale — STL-X → scene-X·sx/100, STL-Z → scene-Y·sz/100,
///      STL-Y → −scene-Z·sy/100.
///   3. Rotate (SceneKit ZYX Euler, matching pivot.eulerAngles) and
///      translate by pivotPos.
func worldTransformMatrix(_ t: ModelTransform, info: STLMeshInfo) -> simd_float4x4 {
    let bb = info.boundingBoxMM
    let origin = SIMD3<Float>((bb.min.x + bb.max.x) * 0.5,
                              (bb.min.y + bb.max.y) * 0.5,
                              bb.min.z)

    let sx = t.scale.x / 100
    let sy = t.scale.y / 100
    let sz = t.scale.z / 100

    // 3×3 remap+scale, given as the images of the STL basis vectors.
    let mRemap = simd_float3x3(
        SIMD3<Float>(sx, 0, 0),     // STL X → ( sx,  0,   0)
        SIMD3<Float>(0, 0, -sy),    // STL Y → (  0,  0, -sy)
        SIMD3<Float>(0, sz, 0)      // STL Z → (  0, sz,   0)
    )

    let r = t.rotationDeg * (.pi / 180)
    // SceneKit's pivot rotation: X, then Y (rz), then Z (ry) — see ModelTransform.minWorldY.
    let q = simd_quaternion(r.y, SIMD3<Float>(0, 0, 1))
          * simd_quaternion(r.z, SIMD3<Float>(0, 1, 0))
          * simd_quaternion(r.x, SIMD3<Float>(1, 0, 0))
    let combined = simd_float3x3(q) * mRemap

    let pivotPos = SIMD3<Float>(t.positionMM.x / 100,
                                t.positionMM.z / 100,
                                t.positionMM.y / 100)
    let translation = pivotPos - combined * origin

    return simd_float4x4(
        SIMD4<Float>(combined.columns.0.x, combined.columns.0.y, combined.columns.0.z, 0),
        SIMD4<Float>(combined.columns.1.x, combined.columns.1.y, combined.columns.1.z, 0),
        SIMD4<Float>(combined.columns.2.x, combined.columns.2.y, combined.columns.2.z, 0),
        SIMD4<Float>(translation.x, translation.y, translation.z, 1)
    )
}
