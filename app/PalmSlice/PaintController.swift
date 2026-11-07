import Foundation
import SceneKit
import simd

/// What's painted: tool colours, or where supports / seams must or mustn't go
/// (PrusaSlicer's MMU, support and seam painting).
enum PaintLayer: Int32, CaseIterable, Identifiable {
    case colour = 0, supports, seam   // SLICER_PAINT_*
    var id: Int32 { rawValue }
    var title: String {
        switch self {
        case .colour:   "Colour"
        case .supports: "Supports"
        case .seam:     "Seam"
        }
    }

    /// Display colour of an enforce / block state on the support or seam layers.
    static func annotationColour(_ state: UInt8) -> HexColour {
        state == UInt8(SLICER_PAINT_BLOCK) ? HexColour(red: 0.91, green: 0.27, blue: 0.24)
                                           : HexColour(red: 0.24, green: 0.52, blue: 1.0)
    }
}

/// Painted triangles of a model for display: 9 floats per triangle in the
/// model's display-STL frame (mm), and the state of each: a tool (PalmSlice
/// number) for colour, SLICER_PAINT_ENFORCE / _BLOCK for supports and seams.
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

/// Painting on the parts of one model: colours, like PrusaSlicer's
/// multi-material painting gizmo, or support / seam enforcers and blockers.
/// Each touched part has a bridge paint session; leaving a part, switching
/// layer or finishing saves its painting into a new copy of the model's native 3MF.
@MainActor
final class PaintController: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case brush = "Brush", smartFill = "Smart Fill", fill = "Fill"
        var id: String { rawValue }
    }

    let modelID: UUID
    /// What strokes paint. Switching saves the part being painted.
    @Published var layer: PaintLayer = .colour {
        didSet { if layer != oldValue { switchLayer(from: oldValue) } }
    }
    /// The tool to paint (colour), or SLICER_PAINT_ENFORCE / _BLOCK; 0 erases.
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
    /// Volume being painted (index in the native 3MF), -1 = none, and the layer its session paints.
    private var volume = -1
    private var sessionLayer: PaintLayer = .colour
    private var undoDepth = 0, redoDepth = 0
    private var lastPoint: SIMD3<Float>?
    /// A stroke has begun and its touch hasn't ended.
    private var strokeOpen = false
    private var changed = false
    private var saveCount = 0
    /// The tool last used on each layer.
    private var toolByLayer: [PaintLayer: Int] = [:]
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
        guard let url = model.nativeURL, slicer_paint_begin_layer(handle, url.path, Int32(k), layer.rawValue) == 0 else {
            errorMessage = String(cString: slicer_last_error(handle))
            return false
        }
        volume = k
        sessionLayer = layer
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
        strokeOpen = true
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
        strokeOpen = false
        updateUndoState()
    }

    /// Takes back the open stroke: its touch became a two-finger gesture.
    func cancelStroke() {
        guard strokeOpen else { return }
        strokeOpen = false
        lastPoint = nil
        if slicer_paint_cancel_stroke(handle) == 0 { undoDepth -= 1 }
        refreshDisplay()
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

    /// Rebuilds the model's display of the layer being painted: the active
    /// part from the session, the others from the saved object.
    private func refreshDisplay() {
        var mesh = PaintMesh()
        if let url = model.nativeURL, let h = slicer_create() {
            for (k, part) in model.parts.enumerated() where part.kind == .part && part.isPainted(layer) && k != volume {
                guard slicer_paint_begin_layer(h, url.path, Int32(k), layer.rawValue) == 0 else { continue }
                append(h, to: &mesh)
                slicer_paint_end(h, nil)
            }
            slicer_destroy(h)
        }
        if volume >= 0 { append(handle, to: &mesh) }
        if layer == .colour {
            model.paint = mesh.isEmpty ? nil : mesh
            model.annotation = nil
        } else {
            model.annotation = mesh   // empty still hides the colour paint
        }
        model.paintVersion += 1
        onModelChange?(model)
    }

    private func switchLayer(from old: PaintLayer) {
        saveCurrent()
        toolByLayer[old] = tool
        tool = toolByLayer[layer] ?? (layer == .colour ? 1 : Int(SLICER_PAINT_ENFORCE))
        undoDepth = 0; redoDepth = 0
        updateUndoState()
        refreshDisplay()
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
            switch sessionLayer {
            case .colour:
                model.parts[volume].isPainted = n > 0
                model.parts[volume].paintedTools = used.prefix(n).map(Int.init)
            case .supports: model.parts[volume].supportsPainted = n > 0
            case .seam:     model.parts[volume].seamPainted = n > 0
            }
        }
        changed = false
        onModelChange?(model)
    }

    /// Ends painting; the returned model has the saved paint.
    func finish() -> PlacedModel {
        saveCurrent()
        model.annotation = nil
        return model
    }
}
