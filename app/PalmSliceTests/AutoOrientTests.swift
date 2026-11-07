import XCTest
import simd
import SceneKit
@testable import PalmSlice

final class AutoOrientTests: XCTestCase {
    /// Triangles of axis-aligned boxes, outward normals.
    private func mesh(_ boxes: [(SIMD3<Float>, SIMD3<Float>)], rotated q: simd_quatf = simd_quatf(angle: 0, axis: [0, 0, 1])) -> STLMeshInfo {
        var verts: [SIMD3<Float>] = [], faces: [STLMeshInfo.Face] = []
        for (lo, hi) in boxes {
            let c = (0..<8).map { i in SIMD3<Float>(i & 1 == 0 ? lo.x : hi.x, i & 2 == 0 ? lo.y : hi.y, i & 4 == 0 ? lo.z : hi.z) }
            let quads = [[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5]]
            for f in quads {
                for tri in [[f[0], f[1], f[2]], [f[0], f[2], f[3]]] {
                    let v = tri.map { q.act(c[$0]) }
                    let n = simd_cross(v[1] - v[0], v[2] - v[0])
                    verts += v
                    faces.append(.init(normal: simd_normalize(n), area: simd_length(n) / 2))
                }
            }
        }
        let lo = verts.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1) }
        let hi = verts.reduce(SIMD3<Float>(repeating: -.infinity)) { simd_max($0, $1) }
        return STLMeshInfo(faces: faces, vertices: verts, boundingBoxMM: (lo, hi))
    }

    /// What the 3D view does with rotationDeg (pivot eulerAngles = (x, z, y)), applied to an STL direction.
    private func applied(_ deg: SIMD3<Float>, to d: SIMD3<Float>) -> SIMD3<Float> {
        let r = deg * (.pi / 180)
        let node = SCNNode()
        node.simdEulerAngles = SIMD3(r.x, r.z, r.y)
        let s = node.simdOrientation.act(SIMD3(d.x, d.z, -d.y))   // STL → SceneKit pivot frame
        return SIMD3(s.x, -s.z, s.y)                              // back to STL axes (z up)
    }

    func testRotationPutsTheDirectionDown() {
        for d: SIMD3<Float> in [[1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], simd_normalize([1, 2, -0.5]), simd_normalize([-0.3, 0.4, 0.8])] {
            let out = applied(AutoOrient.rotationDeg(placing: d), to: d)
            XCTAssertEqual(simd_distance(out, [0, 0, -1]), 0, accuracy: 1e-3, "\(d) → \(out)")
        }
    }

    // A wide cap on a thin post, standing on the post: flip it onto the cap.
    func testTurnsAMushroomOntoItsCap() {
        let info = mesh([([-2, -2, 0], [2, 2, 20]), ([-15, -15, 20], [15, 15, 24])])
        let down = AutoOrient.bestDown(info)
        XCTAssertGreaterThan(down.z, 0.99, "\(down)")
    }

    // A cube tipped 30° settles on a face.
    func testTippedCubeLandsOnAFace() {
        let q = simd_quatf(angle: .pi / 6, axis: [1, 0, 0])
        let info = mesh([([-10, -10, -10], [10, 10, 10])], rotated: q)
        let down = AutoOrient.bestDown(info)
        let faceNormals = [SIMD3<Float>(1, 0, 0), [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]].map { q.act($0) }
        XCTAssertTrue(faceNormals.contains { simd_dot($0, down) > 0.999 }, "\(down)")
    }

    // End to end with the slicer: a cube tipped about two axes, auto-oriented
    // with the same transform mapping as ContentView, slices 20 mm tall (flat on a face).
    func testSlicerAgreesWithTheRotation() throws {
        let q = simd_quatf(angle: 0.5, axis: [1, 0, 0]) * simd_quatf(angle: 0.35, axis: [0, 1, 0])
        let info = mesh([([-10, -10, -10], [10, 10, 10])], rotated: q)
        let deg = AutoOrient.rotation(for: info)
        XCTAssertGreaterThan(abs(deg.x) + abs(deg.y) + abs(deg.z), 1, "should rotate")

        // Binary STL of the tipped cube.
        var data = Data(count: 80)
        var count = UInt32(info.faces.count)
        data.append(Data(bytes: &count, count: 4))
        for (i, f) in info.faces.enumerated() {
            for v in [f.normal, info.vertices[i * 3], info.vertices[i * 3 + 1], info.vertices[i * 3 + 2]] {
                var xyz = [v.x, v.y, v.z]
                data.append(Data(bytes: &xyz, count: 12))
            }
            data.append(Data(count: 2))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).stl")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let h = slicer_create() else { throw XCTSkip("slicer_create") }
        defer { slicer_destroy(h) }
        let printer = try XCTUnwrap(BuiltInProfiles.all.first { $0.verified })
        try SliceSetup.configure(h, printer: printer, material: BuiltInMaterialProfiles.pla, slice: BuiltInSliceProfiles.draft)
        let idx = slicer_add_stl(h, url.path)
        XCTAssertGreaterThanOrEqual(idx, 0)
        var t = SlicerModelTransform()
        t.scale_x = 1; t.scale_y = 1; t.scale_z = 1
        t.rot_x_deg = deg.x; t.rot_y_deg = deg.z; t.rot_z_deg = deg.y   // as ContentView.runSlice
        XCTAssertEqual(slicer_set_object_transform(h, idx, &t), 0)
        XCTAssertEqual(slicer_slice(h, 0, 0), 0, String(cString: slicer_last_error(h)))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).gcode")
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertEqual(slicer_export_gcode(h, out.path), 0, String(cString: slicer_last_error(h)))
        let tops = try String(contentsOf: out, encoding: .utf8).split(separator: "\n")
            .filter { $0.hasPrefix(";Z:") }.compactMap { Double($0.dropFirst(3)) }
        XCTAssertEqual(try XCTUnwrap(tops.max()), 20, accuracy: 0.35)
    }

    // Drop to bed uses the rotation SceneKit draws (it used to apply the angles in the wrong order).
    func testDropToBedMatchesSceneKit() {
        let info = mesh([([-10, -4, 0], [10, 4, 30])])
        var t = ModelTransform()
        t.rotationDeg = [25, 40, -30]
        let r = t.rotationDeg * (.pi / 180)
        let node = SCNNode()
        node.simdEulerAngles = SIMD3(r.x, r.z, r.y)
        let bb = info.boundingBoxMM
        let c = (bb.min + bb.max) / 2
        let expected = info.vertices.map { v in
            node.simdOrientation.act(SIMD3((v.x - c.x) / 100, (v.z - bb.min.z) / 100, (c.y - v.y) / 100)).y
        }.min()!
        XCTAssertEqual(t.minWorldY(meshInfo: info), expected, accuracy: 1e-5)
    }
}
