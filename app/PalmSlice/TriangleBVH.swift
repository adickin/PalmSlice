import simd

// Median-split BVH over a triangle mesh, used for precise mesh-vs-mesh
// intersection. Triangles are stored in raw mm space (same coordinates as
// STLMeshInfo.vertices). Query callers pass world-transform matrices so the
// BVH itself is independent of object placement and can be built once at
// import time.

struct TriangleBVH {
    struct Node {
        var aabbMin: SIMD3<Float>
        var aabbMax: SIMD3<Float>
        // Leaf when triCount > 0; firstTri then indexes into `triangles`
        // (each triangle = 3 consecutive SIMD3<Float> entries, so the byte
        // offset is firstTri * 3).
        // Internal otherwise; leftChild and rightChild index into `nodes`.
        var leftChild: Int32
        var rightChild: Int32
        var firstTri: Int32
        var triCount: Int32
    }

    let nodes: [Node]
    /// Flat triangle vertex array, 3 entries per triangle, reordered so
    /// triangles in the same leaf are contiguous.
    let triangles: [SIMD3<Float>]

    var rootAABBMin: SIMD3<Float> { nodes[0].aabbMin }
    var rootAABBMax: SIMD3<Float> { nodes[0].aabbMax }

    private static let leafThreshold = 8

    /// Build a BVH from a flat 3-per-triangle vertex array (mesh-local mm).
    /// Returns nil for an empty mesh.
    static func build(triangleVertices: [SIMD3<Float>]) -> TriangleBVH? {
        let triCount = triangleVertices.count / 3
        guard triCount > 0 else { return nil }

        var triMin = [SIMD3<Float>](); triMin.reserveCapacity(triCount)
        var triMax = [SIMD3<Float>](); triMax.reserveCapacity(triCount)
        var triCentroid = [SIMD3<Float>](); triCentroid.reserveCapacity(triCount)
        for t in 0..<triCount {
            let a = triangleVertices[t * 3]
            let b = triangleVertices[t * 3 + 1]
            let c = triangleVertices[t * 3 + 2]
            triMin.append(simd_min(simd_min(a, b), c))
            triMax.append(simd_max(simd_max(a, b), c))
            triCentroid.append((a + b + c) / 3)
        }

        var triRefs = Array(0..<triCount)
        var nodes = [Node]()
        nodes.reserveCapacity(triCount * 2)

        // Recursive median split. Returns the node index for [start..<end).
        func buildNode(start: Int, end: Int) -> Int32 {
            let nodeIdx = nodes.count
            var mn = SIMD3<Float>(repeating:  .infinity)
            var mx = SIMD3<Float>(repeating: -.infinity)
            for i in start..<end {
                let r = triRefs[i]
                mn = simd_min(mn, triMin[r])
                mx = simd_max(mx, triMax[r])
            }
            nodes.append(Node(aabbMin: mn, aabbMax: mx,
                              leftChild: -1, rightChild: -1,
                              firstTri: 0, triCount: 0))

            let count = end - start
            if count <= leafThreshold {
                nodes[nodeIdx].firstTri = Int32(start)
                nodes[nodeIdx].triCount = Int32(count)
                return Int32(nodeIdx)
            }

            // Split along longest centroid-extent axis at the median.
            let extent = mx - mn
            let axis: Int
            if extent.x >= extent.y && extent.x >= extent.z { axis = 0 }
            else if extent.y >= extent.z                    { axis = 1 }
            else                                            { axis = 2 }
            triRefs[start..<end].sort {
                triCentroid[$0][axis] < triCentroid[$1][axis]
            }
            let mid = (start + end) / 2

            let left  = buildNode(start: start, end: mid)
            let right = buildNode(start: mid,   end: end)
            nodes[nodeIdx].leftChild  = left
            nodes[nodeIdx].rightChild = right
            return Int32(nodeIdx)
        }

        _ = buildNode(start: 0, end: triCount)

        // Reorder triangles so leaf triangles are contiguous.
        var orderedTris = [SIMD3<Float>]()
        orderedTris.reserveCapacity(triCount * 3)
        for ref in triRefs {
            orderedTris.append(triangleVertices[ref * 3])
            orderedTris.append(triangleVertices[ref * 3 + 1])
            orderedTris.append(triangleVertices[ref * 3 + 2])
        }

        return TriangleBVH(nodes: nodes, triangles: orderedTris)
    }

    /// Returns true if any triangle of self intersects any triangle of other,
    /// when each mesh is placed by its given world-transform matrix.
    func intersects(
        _ other: TriangleBVH,
        selfTransform: simd_float4x4,
        otherTransform: simd_float4x4
    ) -> Bool {
        // Work in self's local frame. Transform other's geometry by M.
        let M = selfTransform.inverse * otherTransform

        // Pre-transform other's node AABBs into self's local space (Arvo).
        var otherAABBMin = [SIMD3<Float>](); otherAABBMin.reserveCapacity(other.nodes.count)
        var otherAABBMax = [SIMD3<Float>](); otherAABBMax.reserveCapacity(other.nodes.count)
        for n in other.nodes {
            let (mn, mx) = transformAABB(n.aabbMin, n.aabbMax, M)
            otherAABBMin.append(mn)
            otherAABBMax.append(mx)
        }

        return recurse(
            aIdx: 0,
            bIdx: 0,
            other: other,
            otherTransform: M,
            otherAABBMin: otherAABBMin,
            otherAABBMax: otherAABBMax
        )
    }

    private func recurse(
        aIdx: Int32,
        bIdx: Int32,
        other: TriangleBVH,
        otherTransform: simd_float4x4,
        otherAABBMin: [SIMD3<Float>],
        otherAABBMax: [SIMD3<Float>]
    ) -> Bool {
        let aNode = nodes[Int(aIdx)]
        let bNode = other.nodes[Int(bIdx)]
        let bMin  = otherAABBMin[Int(bIdx)]
        let bMax  = otherAABBMax[Int(bIdx)]
        if !aabbsOverlap(aNode.aabbMin, aNode.aabbMax, bMin, bMax) { return false }

        let aLeaf = aNode.triCount > 0
        let bLeaf = bNode.triCount > 0

        if aLeaf && bLeaf {
            // Pre-transform B's leaf triangles once, into stack scratch space
            // (no heap allocation per leaf pair).
            let bCount = Int(bNode.triCount)
            let bBaseIdx = Int(bNode.firstTri) * 3
            return withUnsafeTemporaryAllocation(of: SIMD3<Float>.self, capacity: bCount * 3) { bTris in
                for k in 0..<(bCount * 3) {
                    bTris.initializeElement(at: k, to: transformPoint(other.triangles[bBaseIdx + k], otherTransform))
                }
                let aCount = Int(aNode.triCount)
                let aBaseIdx = Int(aNode.firstTri) * 3
                for i in 0..<aCount {
                    let off = aBaseIdx + i * 3
                    let v0 = triangles[off]
                    let v1 = triangles[off + 1]
                    let v2 = triangles[off + 2]
                    for j in 0..<bCount {
                        if triTriIntersect(v0, v1, v2, bTris[j * 3], bTris[j * 3 + 1], bTris[j * 3 + 2]) { return true }
                    }
                }
                return false
            }
        }

        // Descend the side that has children. If both have children, descend
        // into the larger AABB to converge faster.
        let descendA: Bool
        if aLeaf {
            descendA = false
        } else if bLeaf {
            descendA = true
        } else {
            let aSize = aNode.aabbMax - aNode.aabbMin
            let bSize = bMax - bMin
            descendA = (aSize.x * aSize.y * aSize.z) >= (bSize.x * bSize.y * bSize.z)
        }
        if descendA {
            return recurse(aIdx: aNode.leftChild,  bIdx: bIdx, other: other,
                           otherTransform: otherTransform,
                           otherAABBMin: otherAABBMin, otherAABBMax: otherAABBMax)
                || recurse(aIdx: aNode.rightChild, bIdx: bIdx, other: other,
                           otherTransform: otherTransform,
                           otherAABBMin: otherAABBMin, otherAABBMax: otherAABBMax)
        } else {
            return recurse(aIdx: aIdx, bIdx: bNode.leftChild,  other: other,
                           otherTransform: otherTransform,
                           otherAABBMin: otherAABBMin, otherAABBMax: otherAABBMax)
                || recurse(aIdx: aIdx, bIdx: bNode.rightChild, other: other,
                           otherTransform: otherTransform,
                           otherAABBMin: otherAABBMin, otherAABBMax: otherAABBMax)
        }
    }
}

// MARK: - AABB helpers

@inline(__always)
func aabbsOverlap(_ aMin: SIMD3<Float>, _ aMax: SIMD3<Float>,
                  _ bMin: SIMD3<Float>, _ bMax: SIMD3<Float>) -> Bool {
    return aMin.x <= bMax.x && aMax.x >= bMin.x
        && aMin.y <= bMax.y && aMax.y >= bMin.y
        && aMin.z <= bMax.z && aMax.z >= bMin.z
}

/// Transform an AABB by an affine 4x4 matrix using Arvo's method (O(9)).
@inline(__always)
func transformAABB(_ mn: SIMD3<Float>, _ mx: SIMD3<Float>, _ M: simd_float4x4)
    -> (min: SIMD3<Float>, max: SIMD3<Float>)
{
    // Translation column.
    var newMin = SIMD3<Float>(M.columns.3.x, M.columns.3.y, M.columns.3.z)
    var newMax = newMin
    // For each output axis i, accumulate per-input-axis contributions.
    for i in 0..<3 {
        for j in 0..<3 {
            let m = M[j][i]    // M[col][row] in simd column-major
            let a = m * mn[j]
            let b = m * mx[j]
            if a < b { newMin[i] += a; newMax[i] += b }
            else     { newMin[i] += b; newMax[i] += a }
        }
    }
    return (newMin, newMax)
}

@inline(__always)
func transformPoint(_ p: SIMD3<Float>, _ M: simd_float4x4) -> SIMD3<Float> {
    let v = M * SIMD4<Float>(p.x, p.y, p.z, 1)
    return SIMD3<Float>(v.x, v.y, v.z)
}

// MARK: - Triangle-triangle intersection (Möller 1997)

/// Returns true if triangles V0V1V2 and U0U1U2 intersect (in the same coord
/// frame). Coplanar pairs are not handled rigorously — neighbouring tri-pairs
/// generally cover the contact, which is sufficient for collision flagging.
func triTriIntersect(
    _ V0: SIMD3<Float>, _ V1: SIMD3<Float>, _ V2: SIMD3<Float>,
    _ U0: SIMD3<Float>, _ U1: SIMD3<Float>, _ U2: SIMD3<Float>
) -> Bool {
    let eps: Float = 1e-7

    // Plane of U.
    let nU = simd_cross(U1 - U0, U2 - U0)
    let dU = -simd_dot(nU, U0)

    var dv0 = simd_dot(nU, V0) + dU
    var dv1 = simd_dot(nU, V1) + dU
    var dv2 = simd_dot(nU, V2) + dU
    if abs(dv0) < eps { dv0 = 0 }
    if abs(dv1) < eps { dv1 = 0 }
    if abs(dv2) < eps { dv2 = 0 }
    let dv0v1 = dv0 * dv1
    let dv0v2 = dv0 * dv2
    if dv0v1 > 0 && dv0v2 > 0 { return false }   // V on one side of U's plane

    // Plane of V.
    let nV = simd_cross(V1 - V0, V2 - V0)
    let dV = -simd_dot(nV, V0)

    var du0 = simd_dot(nV, U0) + dV
    var du1 = simd_dot(nV, U1) + dV
    var du2 = simd_dot(nV, U2) + dV
    if abs(du0) < eps { du0 = 0 }
    if abs(du1) < eps { du1 = 0 }
    if abs(du2) < eps { du2 = 0 }
    let du0u1 = du0 * du1
    let du0u2 = du0 * du2
    if du0u1 > 0 && du0u2 > 0 { return false }   // U on one side of V's plane

    // Project onto the largest component of the intersection direction.
    let D = simd_cross(nV, nU)
    let aD = abs(D)
    let axis: Int
    if aD.x >= aD.y && aD.x >= aD.z { axis = 0 }
    else if aD.y >= aD.z            { axis = 1 }
    else                            { axis = 2 }

    let pv = (V0[axis], V1[axis], V2[axis])
    let pu = (U0[axis], U1[axis], U2[axis])

    guard let (vMin, vMax) = computeInterval(p: pv, d: (dv0, dv1, dv2),
                                              d0d1: dv0v1, d0d2: dv0v2)
    else { return false }
    guard let (uMin, uMax) = computeInterval(p: pu, d: (du0, du1, du2),
                                              d0d1: du0u1, d0d2: du0u2)
    else { return false }

    return vMax >= uMin && uMax >= vMin
}

@inline(__always)
private func computeInterval(
    p: (Float, Float, Float),
    d: (Float, Float, Float),
    d0d1: Float, d0d2: Float
) -> (Float, Float)? {
    // Identify the lone vertex on its own side of the other plane, then
    // linearly interpolate along the two edges that cross.
    let p0 = p.0, p1 = p.1, p2 = p.2
    let d0 = d.0, d1 = d.1, d2 = d.2
    var t0: Float
    var t1: Float
    if d0d1 > 0 {
        // d2 lone
        t0 = p0 + (p2 - p0) * d0 / (d0 - d2)
        t1 = p1 + (p2 - p1) * d1 / (d1 - d2)
    } else if d0d2 > 0 {
        // d1 lone
        t0 = p0 + (p1 - p0) * d0 / (d0 - d1)
        t1 = p2 + (p1 - p2) * d2 / (d2 - d1)
    } else if d1 * d2 > 0 || d0 != 0 {
        // d0 lone
        t0 = p1 + (p0 - p1) * d1 / (d1 - d0)
        t1 = p2 + (p0 - p2) * d2 / (d2 - d0)
    } else if d1 != 0 {
        t0 = p0 + (p2 - p0) * d0 / (d0 - d2)
        t1 = p1 + (p2 - p1) * d1 / (d1 - d2)
    } else if d2 != 0 {
        t0 = p0 + (p1 - p0) * d0 / (d0 - d1)
        t1 = p2 + (p1 - p2) * d2 / (d2 - d1)
    } else {
        // Coplanar — skip rigorous handling; let neighbours catch it.
        return nil
    }
    return (min(t0, t1), max(t0, t1))
}
