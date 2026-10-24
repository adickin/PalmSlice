# Plan: Multi-Model Support

Support loading multiple STL files simultaneously, each with independent transforms, sliced together in one job. Intersecting models are highlighted red.

---

## Current State

- `ContentView` holds a single `loadedSTLURL: URL?` + `loadedSTLGeometry: SCNGeometry?`
- `ModelTransform` is a single `@State` on `ContentView`
- `STLSceneView` manages one `SCNNode` for the model
- `slicer_load_stl` loads one STL into the slicer handle
- `slicer_set_model_transform` applies one transform

---

## Target State

- A `[PlacedModel]` array replaces the single-model fields
- Each model has its own node in the SceneKit scene, its own transform gizmo when selected
- A selected-model index drives which gizmo is active
- AABB intersection is checked after every transform change; intersecting models render red
- The C bridge loads N models into one handle and maps N transforms

---

## Step 1 — `PlacedModel` Data Model

**File:** `app/PalmSlice/PlacedModel.swift` (new file)

```swift
struct PlacedModel: Identifiable {
    let id: UUID
    var url: URL              // temp-dir copy of the STL
    var geometry: SCNGeometry // parsed SceneKit geometry
    var transform: ModelTransform
    var meshInfo: MeshInfo    // bounding box etc. from parseSTLMeshInfo
    var isIntersecting: Bool  // updated by intersection check
}
```

**Why a struct:** transforms mutate frequently; value semantics avoid accidental aliasing. `isIntersecting` is derived state but kept here so the scene view can read it without recomputing.

---

## Step 2 — State Migration in `ContentView`

Replace:
```swift
@State private var loadedSTLURL: URL?
@State private var loadedSTLGeometry: SCNGeometry?
@State private var modelTransform = ModelTransform()
```

With:
```swift
@State private var models: [PlacedModel] = []
@State private var selectedModelID: UUID? = nil
```

Update every reference site:
- `importSTL()` → appends a new `PlacedModel` (keep the temp-copy + parseSTL logic, wrap result)
- `runSlice()` → iterates all models (see Step 5)
- `resetTransform()` → acts on `models[selectedIndex].transform`
- The "drop to bed" call → applied per model

---

## Step 3 — Multi-Node Scene in `STLSceneView`

**File:** `STLSceneView.swift`

Replace the single `modelNode: SCNNode?` with `modelNodes: [UUID: SCNNode]`.

`updateUIView` diff:
1. Remove nodes for IDs no longer in the models array
2. Add nodes for new IDs (same geometry-attach logic as today)
3. For each node, set material color:
   - `isIntersecting == true` → red (`UIColor.systemRed`)
   - selected → existing highlight tint
   - normal → existing default tint
4. Apply `model.transform` to each node (same SCNMatrix math as today)

Gizmo gestures:
- On tap of a node → set `selectedModelID` binding to that model's ID
- Gizmo pan/pinch gestures read/write `models[selectedIndex].transform` (today they write the single `modelTransform`)
- Hit-test (`sceneView.hitTest`) identifies which node was tapped via `SCNNode.name = model.id.uuidString`

---

## Step 4 — Intersection Detection

**File:** `app/PalmSlice/IntersectionChecker.swift` (new file)

```swift
func checkIntersections(models: inout [PlacedModel]) {
    // Mark all clear first
    for i in models.indices { models[i].isIntersecting = false }

    for i in models.indices {
        for j in (i+1)..<models.count {
            if aabbIntersects(models[i], models[j]) {
                models[i].isIntersecting = true
                models[j].isIntersecting = true
            }
        }
    }
}
```

**AABB computation:** transform the model's local bounding box corners through its `ModelTransform` (position + rotation + scale) to get a world-space AABB. Use `MeshInfo.boundingBoxMin/Max` already parsed by `parseSTLMeshInfo`. For now AABB is sufficient (fast, no geometry sampling needed). Can upgrade to OBB or SCNNode physicsBody if needed later.

**When to call:** after every transform change (same place `updateModelTransform` is called today) and after every `importSTL`.

Because this is O(N²) and N is small (< 20 models), no optimization needed.

---

## Step 5 — C Bridge: Multi-Model Slicing

**File:** `slicer_bridge.h` / `slicer_bridge.cpp`

Add:
```c
// Load the Nth object. Returns object index or negative on error.
int slicer_add_stl(SlicerHandle, const char* path);

// Set transform for the Nth object loaded via slicer_add_stl.
int slicer_set_object_transform(SlicerHandle, int object_index,
                                const SlicerModelTransform*);
```

Keep `slicer_load_stl` and `slicer_set_model_transform` for backwards compatibility (they map to index 0 internally).

C++ side: `libslic3r`'s `Model` already supports multiple `ModelObject` entries. `slicer_add_stl` calls `model.add_object()` then `object->add_volume(mesh)`. `slicer_set_object_transform` calls `instance->set_transformation(...)` on that object's first instance.

**Slice flow change** (`runSlice()` in `ContentView`):
```swift
let handle = slicer_create()
// apply printer/material/slice configs (unchanged)
for (i, model) in models.enumerated() {
    let idx = slicer_add_stl(handle, model.url.path)
    var t = model.transform.asSlicerTransform()
    slicer_set_object_transform(handle, idx, &t)
}
// then slicer_slice_with_progress (unchanged)
```

---

## Step 6 — Model List UI

A compact horizontal strip above the 3D view (or a side panel on larger screens) shows thumbnails/names of loaded models. Tapping selects; a trash icon removes.

**Components needed:**
- `ModelListView`: `ScrollView(.horizontal)` of `ModelThumbnailCell` views
- Each cell shows the filename (trimmed), a small SceneKit snapshot, and a delete button
- "Add Model" button (+ icon) triggers `importSTL()` (already an `async` func)
- Selected cell gets a border highlight

Binding: `models` + `selectedModelID` flow down from `ContentView`.

---

## Step 7 — Slice-All Guard

Before slicing, validate:
- `models` is non-empty (replace the current "no model loaded" guard)
- No model `isIntersecting` (warn the user with an alert: "Models are overlapping. Slicing may fail. Continue?")

---

## Sequencing

| Step | Touches | Risk |
|------|---------|------|
| 1 — PlacedModel struct | new file only | none |
| 2 — State migration | ContentView (large) | medium — many reference sites |
| 3 — Multi-node scene | STLSceneView | medium — node lifecycle |
| 4 — Intersection | new file + hook | low |
| 5 — C bridge | bridge + C++ | high — libslic3r multi-object API |
| 6 — Model list UI | new view + ContentView | low |
| 7 — Slice guard | ContentView | low |

Do steps in order. Steps 1–4 and 6–7 are pure Swift and can be compiled/tested without touching the C bridge. Step 5 requires a bridge rebuild (`scripts/11_xcframework.sh`).
