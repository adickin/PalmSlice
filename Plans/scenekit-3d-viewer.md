# Plan: SceneKit 3D Viewer

**Goal:** Load and display the STL mesh in a real-time 3D viewer with orbit/pan/zoom gestures, embedded in the existing ContentView above the action buttons.

---

## Architecture Overview

All visualization is pure Swift/SceneKit — no C bridge changes needed. The STL is parsed independently of the slicer pipeline (the C bridge only needs the path for slicing; we parse the same file ourselves for display).

Three new Swift files + a few ContentView edits:

```
app/PalmSlice/
  STLParser.swift        ← STL → SCNGeometry (binary + ASCII)
  STLSceneView.swift     ← UIViewRepresentable wrapping SCNView + gestures
  ContentView.swift      ← add geometry state, wire viewer into layout
```

SceneKit is a system framework — just add `SceneKit.framework` to `project.yml` dependencies and `import SceneKit`.

---

## Step 1 — `STLParser.swift`

Single public function:

```swift
func parseSTL(url: URL) throws -> SCNGeometry
```

### Binary STL layout
```
[80 bytes] header (skip)
[4 bytes]  uint32 triangle count N
[N × 50 bytes]:
    [12] normal  (3 × float32)   ← regenerate from cross-product; file normals are often wrong
    [12] vertex0 (3 × float32)
    [12] vertex1
    [12] vertex2
    [2]  attribute byte count    (skip)
```

### ASCII STL
Detect if first non-whitespace chars are `solid` (not preceded by binary garbage). Parse `vertex x y z` lines with `Scanner`.

### Geometry construction
- Build flat `[Float]` arrays for vertex positions and per-vertex normals.
- Per-face normal: `normalize((v1-v0) × (v2-v0))` — same normal for all three verts of a face (flat shading looks good for 3D print meshes).
- `SCNGeometrySource(vertices:)` for positions, `SCNGeometrySource(normals:)` for normals.
- `SCNGeometryElement(indices:primitiveType:.triangles)` — or index-free with `.triangles` count.
- **Normalize**: translate centroid to origin, uniform-scale so the longest AABB axis maps to 1.0. This makes camera placement predictable regardless of original model units.
- Single gray material: `diffuse = UIColor(white: 0.82, alpha: 1)`, `metalness = 0.05`, `roughness = 0.65`, `isDoubleSided = true`.

---

## Step 2 — `STLSceneView.swift`

`UIViewRepresentable` wrapping `SCNView`. The Coordinator owns gesture recognizers and camera state.

### Scene setup (called once in `makeUIView`)
```
scene
└── pivotNode          ← gesture rotation target; at origin (model is normalized to center)
    └── cameraNode     ← starts at (0, 0, cameraDistance)
scene (direct children)
└── meshNode           ← SCNNode(geometry: geometry)
└── ambientLightNode
└── keyLightNode
```

**Why pivot node?** Rotating `pivotNode` on X/Y gives natural tumble/orbit without gimbal lock from directly manipulating the camera.

### Camera
- `SCNCamera` with `zNear = 0.01`, `zFar = 100`, `fieldOfView = 45°`
- Initial camera distance: `1.8` (model is normalized to ~1.0 unit)
- Initial pivot rotation: `x = -0.6 rad` (tilt down ~34°), `y = 0.8 rad` (rotate ~46°) — diagonal isometric-ish view

### Lighting
- **Ambient**: `SCNLight(type: .ambient)`, intensity 400, white
- **Key**: `SCNLight(type: .directional)`, intensity 800, warm white `(1.0, 0.97, 0.9)`, node euler angles `(-0.9, 0.5, 0)` — upper right

### Gestures (Coordinator owns these)
| Gesture | Action |
|---------|--------|
| 1-finger pan | Orbit: increment `pivotNode.eulerAngles.y` by `ΔX × 0.01`, `.x` by `ΔY × 0.01`, clamp `.x` to `[-π/2, π/2]` |
| 2-finger pan | Pan: translate `pivotNode.position` in camera-space XY by `Δ × 0.002` |
| Pinch | Zoom: multiply `cameraDistance` by `1/scale`, clamp to `[0.3, 8.0]`, update `cameraNode.position.z` |

Register orbit pan with `minimumNumberOfTouches = 1` / `maximumNumberOfTouches = 1` and 2-touch pan separately. Use `gesture.require(toFail:)` so 2-touch pan only fires when 1-touch orbit fails.

### `updateUIView`
When `geometry` binding changes: replace the `meshNode`'s geometry, reset pivot rotation and position to defaults, reset camera distance.

### Public interface
```swift
struct STLSceneView: UIViewRepresentable {
    let geometry: SCNGeometry
}
```

---

## Step 3 — Update `ContentView.swift`

### New state
```swift
@State private var loadedSTLGeometry: SCNGeometry? = nil
@State private var isParsingSTL = false
```

### Layout change
Expand `modelSection` — add a 3D viewer panel above the existing file-name row:

```
GroupBox("Model") {
    VStack(spacing: 8) {
        // 3D viewer or placeholder
        if let geo = loadedSTLGeometry {
            STLSceneView(geometry: geo)
                .frame(height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemGray6))
                .frame(height: 280)
                .overlay {
                    if isParsingSTL {
                        ProgressView("Loading…")
                    } else {
                        Image(systemName: "cube")
                            .font(.system(size: 64))
                            .foregroundStyle(.secondary)
                    }
                }
        }
        // existing HStack: filename + params + Load STL button
        HStack { ... }
    }
}
```

### Parse on import
In `importSTL(from:)`, after the file copy succeeds:

```swift
loadedSTLGeometry = nil
isParsingSTL = true
Task.detached(priority: .userInitiated) {
    let geo = try? STLParser.parseSTL(url: dest)
    await MainActor.run {
        loadedSTLGeometry = geo
        isParsingSTL = false
    }
}
```

### Bundled cube on first launch
In a `.task {}` modifier on `ContentView`, parse `cube.stl` from the bundle so the viewer is populated before the user picks a file.

---

## Step 4 — `project.yml` update

Add to the `dependencies` list:

```yaml
- sdk: SceneKit.framework
```

Run `xcodegen` after editing.

---

## File summary

| File | Action | Key details |
|------|--------|-------------|
| `STLParser.swift` | Create | Binary + ASCII STL → `SCNGeometry`; normalize to unit box; flat normals |
| `STLSceneView.swift` | Create | `UIViewRepresentable`, `SCNView`, orbit/pan/zoom gestures via Coordinator |
| `ContentView.swift` | Edit | Add geometry state; expand `modelSection`; parse on import; parse bundled cube on launch |
| `project.yml` | Edit | Add `SceneKit.framework` SDK dep |

---

## Out of scope for this feature

- Layer slice / toolpath visualization (post-slice)
- Wireframe toggle
- Color by face normals or overhang angle
- Model placement / move / rotate UI
- Multiple objects
