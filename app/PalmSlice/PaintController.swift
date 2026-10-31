import Foundation
import SceneKit
import simd

/// Painted triangles of a model for display: 9 floats per triangle in the
/// model's display-STL frame (mm), and the tool (PalmSlice number) of each.
struct PaintMesh {
    var vertices: [Float] = []
    var states: [UInt8] = []
    var isEmpty: Bool { states.isEmpty }
}

/// Reads a native object's painted triangles (every painted part) for display.
func loadPaintMesh(nativeURL: URL, parts: [ModelPart]) -> PaintMesh? {
    guard parts.contains(where: \.isPainted), let h = slicer_create() else { return nil }
    defer { slicer_destroy(h) }
    var mesh = PaintMesh()
    for (k, part) in parts.enumerated() where part.isPainted && part.kind == .part {
        guard slicer_paint_begin(h, nativeURL.path, Int32(k)) == 0 else { continue }
        let n = Int(slicer_paint_mesh_update(h))
        if n > 0, let v = slicer_paint_mesh_vertices(h), let s = slicer_paint_mesh_states(h) {
            mesh.vertices += UnsafeBufferPointer(start: v, count: n * 9)
            mesh.states += UnsafeBufferPointer(start: s, count: n)
        }
        slicer_paint_end(h, nil)
    }
    return mesh.isEmpty ? nil : mesh
}

/// Colour painting on the parts of one model: like PrusaSlicer's
/// multi-material painting gizmo. Each touched part has a bridge paint
/// session; leaving a part (or finishing) saves its painting into a new copy
/// of the model's native 3MF.
@MainActor
final class PaintController: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case brush = "Brush", smartFill = "Smart Fill", fill = "Fill"
        var id: String { rawValue }
    }

    let modelID: UUID
    @Published var tool = 1
    @Published var mode: Mode = .brush
    /// Brush radius, mm.
    @Published var radius: Float = 3
    /// Paints through the model (everything within the radius), not just facing triangles.
    @Published var sphere = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published var errorMessage: String?

    private var model: PlacedModel
    private let handle: SlicerHandle
    /// Volume being painted (index in the native 3MF), -1 = none.
    private var volume = -1
    private var undoDepth = 0, redoDepth = 0
    private var lastPoint: SIMD3<Float>?
    private var changed = false
    private var saveCount = 0
    /// Called with the updated model after each stroke (paint display) and when a part is saved.
    var onModelChange: ((PlacedModel) -> Void)?

    init?(model: PlacedModel) {
        guard model.nativeURL != nil, let h = slicer_create() else { return nil }
        self.model = model
        self.modelID = model.id
        self.handle = h
    }

    deinit { slicer_destroy(handle) }

    /// Volume index of the display mesh's printable part `element`, and that part's triangle offset.
    private func volumeIndex(forPart element: Int) -> Int? {
        var seen = 0
        for (k, part) in model.parts.enumerated() where part.kind == .part {
            if seen == element { return k }
            seen += 1
        }
        return model.parts.isEmpty && element == 0 ? 0 : nil
    }

    private func begin(volume k: Int) -> Bool {
        if volume == k { return true }
        saveCurrent()
        guard let url = model.nativeURL, slicer_paint_begin(handle, url.path, Int32(k)) == 0 else {
            errorMessage = String(cString: slicer_last_error(handle))
            return false
        }
        volume = k
        undoDepth = 0; redoDepth = 0
        updateUndoState()
        return true
    }

    /// Starts a stroke or fill at a hit on the model's mesh: `element` is the
    /// geometry element (printable part), `facet` the triangle within it,
    /// `point` and `camera` in the display-STL frame (mm).
    func touchBegan(element: Int, facet: Int, point: SIMD3<Float>, camera: SIMD3<Float>) {
        guard let k = volumeIndex(forPart: element), begin(volume: k) else { return }
        slicer_paint_stroke_begin(handle)
        undoDepth += 1; redoDepth = 0
        lastPoint = nil
        apply(facet: facet, point: point, camera: camera, first: true)
    }

    /// Continues a brush stroke (ignored for fills, which happen once per touch).
    func touchMoved(element: Int, facet: Int, point: SIMD3<Float>, camera: SIMD3<Float>) {
        guard mode == .brush, let k = volumeIndex(forPart: element), k == volume else { return }
        if let last = lastPoint, simd_distance(last, point) < radius * 0.25 { return }
        apply(facet: facet, point: point, camera: camera, first: false)
    }

    func touchEnded() {
        lastPoint = nil
        updateUndoState()
    }

    private func apply(facet: Int, point: SIMD3<Float>, camera: SIMD3<Float>, first: Bool) {
        let p = [point.x, point.y, point.z], c = [camera.x, camera.y, camera.z]
        let result: Int32
        switch mode {
        case .brush:
            if let last = lastPoint {
                let prev = [last.x, last.y, last.z]
                result = slicer_paint_brush(handle, Int32(facet), p, prev, c, radius, Int32(tool), sphere ? 1 : 0)
            } else {
                result = slicer_paint_brush(handle, Int32(facet), p, nil, c, radius, Int32(tool), sphere ? 1 : 0)
            }
            lastPoint = point
        case .smartFill, .fill:
            guard first else { return }
            result = slicer_paint_fill(handle, Int32(facet), p, Int32(tool), mode == .smartFill ? 30 : 90,
                                       mode == .smartFill ? 1 : 0)
        }
        if result != 0 { errorMessage = String(cString: slicer_last_error(handle)); return }
        changed = true
        refreshDisplay()
    }

    func undo() { step(redo: false) }
    func redo() { step(redo: true) }

    private func step(redo: Bool) {
        guard volume >= 0, slicer_paint_undo(handle, redo ? 1 : 0) == 0 else { return }
        if redo { redoDepth -= 1; undoDepth += 1 } else { undoDepth -= 1; redoDepth += 1 }
        changed = true
        refreshDisplay()
        updateUndoState()
    }

    /// Clears the painting of the part being painted.
    func clearPart() {
        guard volume >= 0 else { return }
        slicer_paint_clear(handle)
        undoDepth += 1; redoDepth = 0
        changed = true
        refreshDisplay()
        updateUndoState()
    }

    private func updateUndoState() {
        canUndo = undoDepth > 0
        canRedo = redoDepth > 0
    }

    /// Rebuilds the model's paint display: the active part from the session,
    /// the others from the saved object.
    private func refreshDisplay() {
        var mesh = PaintMesh()
        if let url = model.nativeURL, let h = slicer_create() {
            for (k, part) in model.parts.enumerated() where part.kind == .part && part.isPainted && k != volume {
                guard slicer_paint_begin(h, url.path, Int32(k)) == 0 else { continue }
                append(h, to: &mesh)
                slicer_paint_end(h, nil)
            }
            slicer_destroy(h)
        }
        if volume >= 0 { append(handle, to: &mesh) }
        model.paint = mesh.isEmpty ? nil : mesh
        model.paintVersion += 1
        onModelChange?(model)
    }

    private func append(_ h: SlicerHandle, to mesh: inout PaintMesh) {
        let n = Int(slicer_paint_mesh_update(h))
        guard n > 0, let v = slicer_paint_mesh_vertices(h), let s = slicer_paint_mesh_states(h) else { return }
        mesh.vertices += UnsafeBufferPointer(start: v, count: n * 9)
        mesh.states += UnsafeBufferPointer(start: s, count: n)
    }

    /// Saves the part being painted into a new copy of the native 3MF.
    private func saveCurrent() {
        guard volume >= 0 else { return }
        defer { volume = -1 }
        guard changed, let url = model.nativeURL else { slicer_paint_end(handle, nil); return }
        var used = [Int32](repeating: 0, count: 256)
        let n = max(0, Int(slicer_paint_used_tools(handle, &used, 256)))
        saveCount += 1
        let saved = url.deletingPathExtension().deletingPathExtension()
            .appendingPathExtension("paint\(saveCount)-\(UUID().uuidString.prefix(6)).3mf")
        guard slicer_paint_end(handle, saved.path) == 0 else {
            errorMessage = String(cString: slicer_last_error(handle))
            return
        }
        model.nativeURL = saved
        if volume < model.parts.count {
            model.parts[volume].isPainted = n > 0
            model.parts[volume].paintedTools = used.prefix(n).map(Int.init)
        }
        changed = false
        onModelChange?(model)
    }

    /// Ends painting; the returned model has the saved paint.
    func finish() -> PlacedModel {
        saveCurrent()
        return model
    }
}
