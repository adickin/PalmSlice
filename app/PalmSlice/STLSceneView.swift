import SceneKit
import SwiftUI
import simd

// MARK: - Gizmo types

enum GizmoAxis {
    case x, y, z
    var worldDir: SIMD3<Float> {
        // Scene Y = print Z (up); scene Z = print Y (bed depth). Swap so labels match print convention.
        switch self { case .x: return SIMD3(1,0,0); case .y: return SIMD3(0,0,1); case .z: return SIMD3(0,1,0) }
    }
}

enum GizmoMode: Equatable { case translate, rotate, scale }

// MARK: - STLSceneView

struct STLSceneView: UIViewRepresentable {
    var models: [PlacedModel]
    var selectedModelID: UUID?
    var bedX: Double = 220
    var bedY: Double = 220
    var bedZ: Double = 250
    var showWireframe: Bool = false
    var gizmoMode: GizmoMode = .translate
    var lockScale: Bool = true
    var didSetCamera: Bool = false
    var onTransformChange: ((UUID, ModelTransform) -> Void)? = nil
    var onSelectionChange: ((UUID?) -> Void)? = nil
    var onDragEnded: (() -> Void)? = nil
    var onCameraSet: (() -> Void)? = nil
    /// Apple Pencil double-tap / squeeze (when the user's system preference isn't "Ignore").
    var onPencilAction: (() -> Void)? = nil
    /// Tints parts by their tool's colour (multi-tool printers); nil = plain grey.
    var palette: ToolPalette? = nil
    /// A volume to show even if it isn't drawn normally (modifiers, negative volumes, …).
    var shownPart: ShownPart? = nil
    /// The wipe tower to draw on the bed (draggable); nil = none.
    var wipeTower: WipeTowerFootprint? = nil
    /// Bed centre in printer coordinates (mm); models are positioned relative to it.
    var bedCentreMM: SIMD2<Double> = .zero
    /// The wipe tower was dragged to a new front-left corner (printer mm).
    var onWipeTowerMove: ((SIMD2<Double>) -> Void)? = nil
    /// Paint mode: one finger / the Pencil paints this controller's model,
    /// two fingers orbit, pinch zooms.
    var paintController: PaintController? = nil

    struct ShownPart: Equatable {
        let model: UUID
        let part: Int
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.backgroundColor = UIColor(white: 0.10, alpha: 1)
        scnView.antialiasingMode = .multisampling4X
        scnView.allowsCameraControl = true
        scnView.rendersContinuously = true

        let ctrl = scnView.defaultCameraController
        ctrl.interactionMode = .orbitTurntable
        ctrl.minimumVerticalAngle = -89
        ctrl.maximumVerticalAngle  =  89

        let scene = SCNScene()
        scnView.scene = scene

        let bedNode = makePrintBedNode(bedX: bedX, bedY: bedY, bedZ: bedZ)
        bedNode.name = "printBed"
        scene.rootNode.addChildNode(bedNode)

        let axesNode = makeAxesNode(bedX: bedX, bedY: bedY)
        axesNode.name = "axes"
        scene.rootNode.addChildNode(axesNode)

        // Gizmo container — global, repositioned over the selected model.
        let container = SCNNode()
        container.name = "gizmoContainer"
        container.isHidden = true
        container.renderingOrder = 10
        scene.rootNode.addChildNode(container)
        context.coordinator.gizmoContainerNode = container

        let tg = makeTranslateGizmo()
        tg.name = "gizmo_translate_group"
        tg.renderingOrder = 10
        container.addChildNode(tg)
        context.coordinator.gizmoTranslateGroup = tg

        let rg = makeRotateGizmo()
        rg.name = "gizmo_rotate_group"
        rg.renderingOrder = 10
        rg.isHidden = true
        container.addChildNode(rg)
        context.coordinator.gizmoRotateGroup = rg

        let sg = makeScaleGizmo()
        sg.name = "gizmo_scale_group"
        sg.renderingOrder = 10
        sg.isHidden = true
        container.addChildNode(sg)
        context.coordinator.gizmoScaleGroup = sg

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        scnView.addGestureRecognizer(tap)
        context.coordinator.tapGesture = tap

        // Fingers (and trackpad) drag gizmo handles; Apple Pencil has its own recognizer
        // below that also lets it grab a model directly and slide it across the bed.
        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleGizmoPan(_:)))
        pan.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber,
                                 UITouch.TouchType.indirectPointer.rawValue as NSNumber]
        pan.delegate = context.coordinator
        scnView.addGestureRecognizer(pan)
        context.coordinator.panGesture = pan

        let pencilPan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleGizmoPan(_:)))
        pencilPan.allowedTouchTypes = [UITouch.TouchType.pencil.rawValue as NSNumber]
        pencilPan.delegate = context.coordinator
        scnView.addGestureRecognizer(pencilPan)
        context.coordinator.pencilPanGesture = pencilPan

        // Pencil hover (M2+ iPads) and trackpad pointer — highlights the gizmo handle under the tip.
        let hover = UIHoverGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleHover(_:)))
        scnView.addGestureRecognizer(hover)

        // Paint mode only: paint with one finger or the Pencil, orbit with two, pinch to zoom.
        let paintPan = UIPanGestureRecognizer(target: context.coordinator,
                                              action: #selector(Coordinator.handlePaintPan(_:)))
        paintPan.maximumNumberOfTouches = 1
        paintPan.isEnabled = false
        scnView.addGestureRecognizer(paintPan)
        context.coordinator.paintPanGesture = paintPan
        let orbitPan = UIPanGestureRecognizer(target: context.coordinator,
                                              action: #selector(Coordinator.handleOrbitPan(_:)))
        orbitPan.minimumNumberOfTouches = 2
        orbitPan.isEnabled = false
        orbitPan.delegate = context.coordinator
        scnView.addGestureRecognizer(orbitPan)
        context.coordinator.orbitPanGesture = orbitPan
        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handlePinch(_:)))
        pinch.isEnabled = false
        pinch.delegate = context.coordinator
        scnView.addGestureRecognizer(pinch)
        context.coordinator.pinchGesture = pinch

        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = context.coordinator
        scnView.addInteraction(pencilInteraction)

        let ambient = SCNLight(); ambient.type = .ambient; ambient.intensity = 350
        let ambNode = SCNNode(); ambNode.light = ambient
        scene.rootNode.addChildNode(ambNode)

        let key = SCNLight(); key.type = .directional; key.intensity = 800
        key.color = UIColor(red: 1.0, green: 0.97, blue: 0.9, alpha: 1)
        let keyNode = SCNNode(); keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-0.9, 0.5, 0)
        scene.rootNode.addChildNode(keyNode)

        let bedDiag = Float(sqrt(bedX * bedX + bedY * bedY)) / 100
        let camera = SCNCamera(); camera.zNear = 0.01; camera.zFar = 400; camera.fieldOfView = 45
        let camNode = SCNNode(); camNode.camera = camera
        camNode.position = SCNVector3(bedDiag * 0.75, bedDiag * 0.5, bedDiag)
        camNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(camNode)
        scnView.pointOfView = camNode
        context.coordinator.cameraNode = camNode
        context.coordinator.lastBedX = bedX
        context.coordinator.lastBedY = bedY

        return scnView
    }

    func updateUIView(_ scnView: SCNView, context: Context) {
        let coord = context.coordinator
        coord.onTransformChange = onTransformChange
        coord.onSelectionChange = onSelectionChange
        coord.onDragEnded       = onDragEnded
        coord.onCameraSet       = onCameraSet
        coord.onPencilAction    = onPencilAction
        coord.didSetCamera      = didSetCamera
        coord.lockScale         = lockScale
        coord.onWipeTowerMove   = onWipeTowerMove
        if coord.paintController !== paintController {
            coord.paintController = paintController
            let painting = paintController != nil
            scnView.allowsCameraControl = !painting
            coord.paintPanGesture?.isEnabled = painting
            coord.orbitPanGesture?.isEnabled = painting
            coord.pinchGesture?.isEnabled = painting
            coord.updateGizmoGroupVisibility()
        }
        coord.wipeTower         = wipeTower
        coord.bedCentreMM       = bedCentreMM
        if coord.lastWipeTower != wipeTower || coord.lastBedCentreMM != bedCentreMM, let scene = scnView.scene {
            coord.wipeTowerNode?.removeFromParentNode()
            coord.wipeTowerNode = wipeTower.map { makeWipeTowerNode($0, bedCentreMM: bedCentreMM) }
            if let node = coord.wipeTowerNode { scene.rootNode.addChildNode(node) }
            coord.lastWipeTower = wipeTower
            coord.lastBedCentreMM = bedCentreMM
        }

        // 1. Rebuild bed/axes on dimension change.
        if coord.lastBedX != bedX || coord.lastBedY != bedY || coord.lastBedZ != bedZ,
           let scene = scnView.scene {
            scene.rootNode.childNode(withName: "printBed", recursively: false)?.removeFromParentNode()
            scene.rootNode.childNode(withName: "axes",     recursively: false)?.removeFromParentNode()
            let b = makePrintBedNode(bedX: bedX, bedY: bedY, bedZ: bedZ); b.name = "printBed"
            scene.rootNode.addChildNode(b)
            let a = makeAxesNode(bedX: bedX, bedY: bedY); a.name = "axes"
            scene.rootNode.addChildNode(a)
            coord.lastBedX = bedX; coord.lastBedY = bedY; coord.lastBedZ = bedZ
        }

        // 2. Gizmo mode change.
        if coord.gizmoMode != gizmoMode {
            coord.gizmoMode = gizmoMode
            coord.updateGizmoGroupVisibility()
        }

        guard let scene = scnView.scene else { return }

        // 3. Remove nodes for models no longer present.
        let currentIDs = Set(models.map { $0.id })
        for id in Array(coord.modelEntries.keys) where !currentIDs.contains(id) {
            coord.modelEntries[id]?.pivot.removeFromParentNode()
            coord.modelEntries.removeValue(forKey: id)
        }

        // 4. Sync selection state and currentTransform into coordinator.
        // Read transform directly from the models array — it already holds the value
        // that onTransformChange just wrote, so the pan handler's next delta is correct.
        coord.selectedModelID = selectedModelID
        if let id = selectedModelID,
           let t = models.first(where: { $0.id == id })?.transform {
            coord.currentTransform = t
        }

        // 5. Add / update nodes for each model.
        for model in models {
            // Create entry if new.
            if coord.modelEntries[model.id] == nil {
                let pivot = SCNNode()
                pivot.name = model.id.uuidString
                scene.rootNode.addChildNode(pivot)

                let mesh = SCNNode()
                mesh.name = "mesh_" + model.id.uuidString
                mesh.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
                pivot.addChildNode(mesh)

                coord.modelEntries[model.id] = Coordinator.ModelEntry(pivot: pivot, mesh: mesh)
            }

            var entry = coord.modelEntries[model.id]!

            // 5a. Geometry update.
            if entry.lastGeometry !== model.geometry {
                entry.lastGeometry = model.geometry
                entry.mesh.geometry = model.geometry

                if let geo = model.geometry {
                    applyWireframe(geo, show: showWireframe)

                    let (minB, maxB) = geo.boundingBox
                    entry.mesh.position = SCNVector3(
                        -(minB.x + maxB.x) / 2,
                        -minB.z,
                         (minB.y + maxB.y) / 2)

                    entry.halfHeight = (maxB.z - minB.z) / 2
                    entry.meshExtent = SIMD3<Float>(
                        maxB.x - minB.x, maxB.y - minB.y, maxB.z - minB.z)

                    // Rebuild bounding box wireframe.
                    entry.bboxNode?.removeFromParentNode()
                    let bbox = makeBoundingBoxNode(min: minB, max: maxB)
                    bbox.isHidden = model.id != selectedModelID
                    entry.pivot.addChildNode(bbox)
                    entry.bboxNode = bbox

                    // Reset camera for the first model ever loaded — but only once per
                    // ContentView session (didSetCamera persists across view recreations).
                    if !coord.didSetCamera, coord.lastCameraModelID == nil, let cam = coord.cameraNode {
                        coord.lastCameraModelID = model.id
                        let modelH = maxB.z - minB.z
                        let maxExt = max(maxB.x - minB.x, maxB.y - minB.y, modelH)
                        let lookAt  = SCNVector3(0, modelH / 2, 0)
                        let bedDiag = Float(sqrt(bedX * bedX + bedY * bedY)) / 100
                        let dist    = max(maxExt * 2.0, bedDiag)
                        cam.position = SCNVector3(dist * 0.75, modelH / 2 + dist * 0.5, dist)
                        cam.look(at: lookAt)
                        scnView.pointOfView = cam
                        scnView.defaultCameraController.target = lookAt
                        coord.onCameraSet?()
                    }
                }

                coord.modelEntries[model.id] = entry
            }

            // 5b. Transform update.
            if entry.lastTransform != model.transform {
                let t = model.transform
                let r = t.rotationDeg * (Float.pi / 180)
                // positionMM.y = print Y = scene Z; positionMM.z = print Z (up) = scene Y
                entry.pivot.position    = SCNVector3(t.positionMM.x / 100,
                                                     t.positionMM.z / 100,
                                                     t.positionMM.y / 100)
                entry.pivot.eulerAngles = SCNVector3(r.x, r.z, r.y)
                entry.pivot.scale       = SCNVector3(t.scale.x, t.scale.z, t.scale.y)
                entry.lastTransform     = t
                coord.modelEntries[model.id] = entry
            }

            // 5c. Intersection / selection colour via emission.
            if let geo = entry.mesh.geometry {
                for mat in geo.materials {
                    if model.isIntersecting {
                        mat.emission.contents = UIColor(red: 0.7, green: 0, blue: 0, alpha: 1)
                    } else {
                        mat.emission.contents = UIColor.black
                    }
                }
            }

            // 5d. Bounding box visibility.
            entry.bboxNode?.isHidden = (model.id != selectedModelID)

            if let info = model.meshInfo {
                entry.centreMM = (info.boundingBoxMM.min + info.boundingBoxMM.max) * 0.5
                coord.modelEntries[model.id] = entry
            }

            // 5e. Tool tints and see-through volumes.
            let shown = shownPart?.model == model.id ? shownPart?.part : nil
            let tintKey = TintKey(geometry: model.geometry.map(ObjectIdentifier.init), palette: palette,
                                  extruder: model.extruder, parts: model.parts,
                                  overlays: model.partGeometries.count, shown: shown,
                                  paintVersion: model.paintVersion, centre: entry.centreMM)
            if entry.tintKey != tintKey {
                applyTint(model, shown: shown, to: &entry)
                entry.tintKey = tintKey
                coord.modelEntries[model.id] = entry
            }
        }

        // 6. Update gizmo position / scale to the selected model.
        if let id = selectedModelID, let entry = coord.modelEntries[id] {
            let worldCenter = entry.pivot.convertPosition(
                SCNVector3(0, entry.halfHeight, 0), to: nil)
            coord.gizmoContainerNode?.position = worldCenter
            // Mesh-local x/y/z extents map 1:1 onto transform.scale x/y/z (see ModelTransform's
            // pivot-space mapping comments), so scaling each before taking the diagonal gives the
            // model's true on-screen size — gizmo handles grow/shrink as the model is scaled.
            let ts = entry.lastTransform.scale
            let scaledDiag = simd_length(entry.meshExtent * SIMD3<Float>(ts.x, ts.y, ts.z))
            let s = max(scaledDiag * 0.55, 0.06)
            coord.gizmoContainerNode?.scale = SCNVector3(s, s, s)
        }

        // 7. Gizmo visibility.
        coord.updateGizmoGroupVisibility()

        // 8. Wireframe update.
        if coord.lastShowWireframe != showWireframe {
            for entry in coord.modelEntries.values {
                if let geo = entry.mesh.geometry { applyWireframe(geo, show: showWireframe) }
            }
            coord.lastShowWireframe = showWireframe
        }
    }

    struct TintKey: Equatable {
        var geometry: ObjectIdentifier?
        var palette: ToolPalette?
        var extruder: Int
        var parts: [ModelPart]
        var overlays: Int
        var shown: Int?
        var paintVersion: Int
        var centre: SIMD3<Float>
    }

    /// Colours each printable part with its tool, and draws modifiers that set
    /// a tool (tinted) and the shown volume see-through over the model.
    private func applyTint(_ model: PlacedModel, shown: Int?, to entry: inout Coordinator.ModelEntry) {
        guard let geo = entry.mesh.geometry else { return }
        let faceMaterials = geo.materials.dropLast()   // the last one is the wireframe's
        let printable = model.parts.filter { $0.kind == .part }
        let tools = printable.count == faceMaterials.count
            ? printable.map { $0.extruder != 0 ? $0.extruder : model.extruder }
            : Array(repeating: model.extruder, count: faceMaterials.count)
        for (material, tool) in zip(faceMaterials, tools) where material.lightingModel == .physicallyBased {
            material.diffuse.contents = palette?.colour(tool).uiColor ?? UIColor(white: 0.82, alpha: 1)
        }

        for node in entry.overlayNodes { node.removeFromParentNode() }
        entry.overlayNodes = []
        if let paint = model.paint, let geometry = makePaintGeometry(paint, centreMM: entry.centreMM, palette: palette) {
            let node = SCNNode(geometry: geometry)
            node.name = "paint"
            entry.mesh.addChildNode(node)
            entry.overlayNodes.append(node)
        }
        for (k, part) in model.parts.enumerated() where part.kind != .part {
            let showsTool = palette != nil && part.kind == .modifier && part.extruder > 0
            guard showsTool || shown == k, let source = model.partGeometries[k] else { continue }
            let overlay = source.copy() as! SCNGeometry
            let material = SCNMaterial()
            material.diffuse.contents = showsTool ? palette!.colour(part.extruder).uiColor : part.kind.overlayColour
            material.transparency = shown == k ? 0.65 : 0.45
            material.isDoubleSided = true
            material.writesToDepthBuffer = false
            material.lightingModel = .physicallyBased
            let hidden = SCNMaterial()
            hidden.transparency = 0
            overlay.materials = [material, hidden]
            let node = SCNNode(geometry: overlay)
            node.name = "volume_\(k)"
            node.renderingOrder = 10
            entry.mesh.addChildNode(node)
            entry.overlayNodes.append(node)
        }
    }

    private func applyWireframe(_ geo: SCNGeometry, show: Bool) {
        guard geo.materials.count > 1 else { return }
        geo.materials.last?.transparency = show ? 1.0 : 0.0
    }
}

// MARK: - Bounding box wireframe helper

private func makeBoundingBoxNode(min minB: SCNVector3, max maxB: SCNVector3) -> SCNNode {
    // Pivot-local extents after the mesh node's –90° X rotation:
    //   X: [–w/2 … +w/2], Y: [0 … h], Z: [–d/2 … +d/2]
    let hw = (maxB.x - minB.x) / 2
    let hh = maxB.z - minB.z
    let hd = (maxB.y - minB.y) / 2

    let verts: [SCNVector3] = [
        SCNVector3(-hw, 0,  -hd), SCNVector3( hw, 0,  -hd),
        SCNVector3( hw, 0,   hd), SCNVector3(-hw, 0,   hd),
        SCNVector3(-hw, hh, -hd), SCNVector3( hw, hh, -hd),
        SCNVector3( hw, hh,  hd), SCNVector3(-hw, hh,  hd),
    ]
    let idx: [Int32] = [
        0,1, 1,2, 2,3, 3,0,
        4,5, 5,6, 6,7, 7,4,
        0,4, 1,5, 2,6, 3,7,
    ]
    let geo = SCNGeometry(
        sources: [SCNGeometrySource(vertices: verts)],
        elements: [SCNGeometryElement(indices: idx, primitiveType: .line)])
    let mat = SCNMaterial()
    mat.diffuse.contents = UIColor(white: 1, alpha: 0.55)
    mat.lightingModel = .constant
    mat.readsFromDepthBuffer = false
    mat.writesToDepthBuffer  = false
    geo.materials = [mat]

    let node = SCNNode(geometry: geo)
    node.name = "boundingBox"
    node.renderingOrder = 50
    return node
}

// MARK: - Gizmo builders (unit scale — container node is scaled externally)

private func arrow(shaft: CGFloat, shaftR: CGFloat,
                   head: CGFloat, headR: CGFloat,
                   color: UIColor, euler: SCNVector3) -> SCNNode {
    let mat = SCNMaterial()
    mat.diffuse.contents = color
    mat.lightingModel = .constant
    mat.readsFromDepthBuffer = false
    mat.writesToDepthBuffer = false

    let sg = SCNCylinder(radius: shaftR, height: shaft); sg.materials = [mat]
    let sn = SCNNode(geometry: sg); sn.position = SCNVector3(0, Float(shaft)/2, 0)
    sn.renderingOrder = 100

    let hg = SCNCone(topRadius: 0, bottomRadius: headR, height: head); hg.materials = [mat]
    let hn = SCNNode(geometry: hg); hn.position = SCNVector3(0, Float(shaft)+Float(head)/2, 0)
    hn.renderingOrder = 100

    let hitR = headR * 1.5
    let totalLen = shaft + head
    let hitGeo = SCNCylinder(radius: hitR, height: totalLen)
    let hitMat = SCNMaterial()
    hitMat.diffuse.contents = UIColor.clear
    hitMat.lightingModel = .constant
    hitMat.readsFromDepthBuffer = false
    hitMat.writesToDepthBuffer = false
    hitGeo.materials = [hitMat]
    let hitNode = SCNNode(geometry: hitGeo)
    hitNode.position = SCNVector3(0, Float(totalLen)/2, 0)
    hitNode.renderingOrder = 100

    let n = SCNNode(); n.addChildNode(hitNode); n.addChildNode(sn); n.addChildNode(hn)
    n.eulerAngles = euler
    n.renderingOrder = 100
    return n
}

private func makeTranslateGizmo() -> SCNNode {
    let shaft: CGFloat = 1.0, shaftR: CGFloat = 0.04
    let head:  CGFloat = 0.35, headR: CGFloat = 0.12
    let root = SCNNode()

    let xa = arrow(shaft: shaft, shaftR: shaftR, head: head, headR: headR,
                   color: UIColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 1),
                   euler: SCNVector3(0, 0, -Float.pi/2))
    xa.name = "gizmo_x"

    let ya = arrow(shaft: shaft, shaftR: shaftR, head: head, headR: headR,
                   color: UIColor(red: 0.2, green: 0.9, blue: 0.2, alpha: 1),
                   euler: SCNVector3(Float.pi/2, 0, 0))  // scene Z = print Y (bed depth)
    ya.name = "gizmo_y"

    let za = arrow(shaft: shaft, shaftR: shaftR, head: head, headR: headR,
                   color: UIColor(red: 0.3, green: 0.5, blue: 1.0, alpha: 1),
                   euler: SCNVector3(0, 0, 0))            // scene Y = print Z (up)
    za.name = "gizmo_z"

    root.addChildNode(xa); root.addChildNode(ya); root.addChildNode(za)
    return root
}

private func ringNode(ringR: CGFloat, pipeVis: CGFloat, color: UIColor, euler: SCNVector3) -> SCNNode {
    let hitGeo = SCNTorus(ringRadius: ringR, pipeRadius: pipeVis * 3)
    let hitMat = SCNMaterial()
    hitMat.diffuse.contents = UIColor.clear
    hitMat.lightingModel = .constant
    hitMat.readsFromDepthBuffer = false
    hitMat.writesToDepthBuffer = false
    hitGeo.materials = [hitMat]
    let n = SCNNode(geometry: hitGeo)
    n.eulerAngles = euler
    n.renderingOrder = 100

    let visGeo = SCNTorus(ringRadius: ringR, pipeRadius: pipeVis)
    let visMat = SCNMaterial()
    visMat.diffuse.contents = color
    visMat.lightingModel = .constant
    visMat.readsFromDepthBuffer = false
    visMat.writesToDepthBuffer = false
    visGeo.materials = [visMat]
    let visNode = SCNNode(geometry: visGeo)
    visNode.renderingOrder = 100
    n.addChildNode(visNode)

    return n
}

private func makeRotateGizmo() -> SCNNode {
    let ringR: CGFloat = 1.1, pipeVis: CGFloat = 0.055
    let root = SCNNode()

    let xr = ringNode(ringR: ringR, pipeVis: pipeVis,
                      color: UIColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 1),
                      euler: SCNVector3(0, 0, Float.pi/2))
    xr.name = "gizmo_rot_x"

    let yr = ringNode(ringR: ringR, pipeVis: pipeVis,
                      color: UIColor(red: 0.2, green: 0.9, blue: 0.2, alpha: 1),
                      euler: SCNVector3(Float.pi/2, 0, 0))  // ring in scene-Z plane = print Y rotation
    yr.name = "gizmo_rot_y"

    let zr = ringNode(ringR: ringR, pipeVis: pipeVis,
                      color: UIColor(red: 0.3, green: 0.5, blue: 1.0, alpha: 1),
                      euler: SCNVector3(0, 0, 0))             // ring in scene-Y plane = print Z rotation
    zr.name = "gizmo_rot_z"

    root.addChildNode(xr); root.addChildNode(yr); root.addChildNode(zr)
    return root
}

private func scaleHandle(shaft: CGFloat, shaftR: CGFloat, cube: CGFloat,
                          color: UIColor, euler: SCNVector3) -> SCNNode {
    let mat = SCNMaterial()
    mat.diffuse.contents = color
    mat.lightingModel = .constant
    mat.readsFromDepthBuffer = false
    mat.writesToDepthBuffer = false

    let sg = SCNCylinder(radius: shaftR, height: shaft); sg.materials = [mat]
    let sn = SCNNode(geometry: sg); sn.position = SCNVector3(0, Float(shaft)/2, 0)
    sn.renderingOrder = 100

    let cg = SCNBox(width: cube, height: cube, length: cube, chamferRadius: 0.02*cube)
    cg.materials = [mat]
    let cn = SCNNode(geometry: cg); cn.position = SCNVector3(0, Float(shaft)+Float(cube)/2, 0)
    cn.renderingOrder = 100

    let hitR = cube * 0.75
    let totalLen = shaft + cube
    let hitGeo = SCNCylinder(radius: hitR, height: totalLen)
    let hitMat = SCNMaterial()
    hitMat.diffuse.contents = UIColor.clear
    hitMat.lightingModel = .constant
    hitMat.readsFromDepthBuffer = false
    hitMat.writesToDepthBuffer = false
    hitGeo.materials = [hitMat]
    let hitNode = SCNNode(geometry: hitGeo)
    hitNode.position = SCNVector3(0, Float(totalLen)/2, 0)
    hitNode.renderingOrder = 100

    let n = SCNNode(); n.addChildNode(hitNode); n.addChildNode(sn); n.addChildNode(cn)
    n.eulerAngles = euler
    n.renderingOrder = 100
    return n
}

private func makeScaleGizmo() -> SCNNode {
    let shaft: CGFloat = 1.0, shaftR: CGFloat = 0.04, cube: CGFloat = 0.18
    let root = SCNNode()

    let xa = scaleHandle(shaft: shaft, shaftR: shaftR, cube: cube,
                          color: UIColor(red: 1.0, green: 0.2, blue: 0.2, alpha: 1),
                          euler: SCNVector3(0, 0, -Float.pi/2))
    xa.name = "gizmo_scale_x"

    let ya = scaleHandle(shaft: shaft, shaftR: shaftR, cube: cube,
                          color: UIColor(red: 0.2, green: 0.9, blue: 0.2, alpha: 1),
                          euler: SCNVector3(Float.pi/2, 0, 0))  // scene Z = print Y
    ya.name = "gizmo_scale_y"

    let za = scaleHandle(shaft: shaft, shaftR: shaftR, cube: cube,
                          color: UIColor(red: 0.3, green: 0.5, blue: 1.0, alpha: 1),
                          euler: SCNVector3(0, 0, 0))             // scene Y = print Z (up)
    za.name = "gizmo_scale_z"

    root.addChildNode(xa); root.addChildNode(ya); root.addChildNode(za)
    return root
}

// MARK: - Print bed grid

func makePrintBedNode(bedX: Double, bedY: Double, bedZ: Double = 250) -> SCNNode {
    let scaleX = Float(bedX) / 100, scaleZ = Float(bedY) / 100
    let halfX = scaleX / 2,         halfZ = scaleZ / 2
    let h = Float(bedZ) / 100
    let divX = max(Int(bedX / 10), 1), divZ = max(Int(bedY / 10), 1)
    let stepX = scaleX / Float(divX), stepZ = scaleZ / Float(divZ)

    var verts: [SCNVector3] = []; var idx: [Int32] = []; var i32: Int32 = 0
    for i in 0...divZ {
        let z = -halfZ + Float(i) * stepZ
        verts += [SCNVector3(-halfX,0,z), SCNVector3(halfX,0,z)]
        idx += [i32, i32+1]; i32 += 2
    }
    for i in 0...divX {
        let x = -halfX + Float(i) * stepX
        verts += [SCNVector3(x,0,-halfZ), SCNVector3(x,0,halfZ)]
        idx += [i32, i32+1]; i32 += 2
    }
    // Four vertical corner pillars to show build volume height.
    let corners: [(Float, Float)] = [(-halfX,-halfZ),(halfX,-halfZ),(halfX,halfZ),(-halfX,halfZ)]
    for (cx, cz) in corners {
        verts += [SCNVector3(cx,0,cz), SCNVector3(cx,h,cz)]
        idx += [i32, i32+1]; i32 += 2
    }
    // Top rectangle outline.
    let topCorners: [SCNVector3] = corners.map { SCNVector3($0.0, h, $0.1) }
    for i in 0..<4 {
        let j = (i + 1) % 4
        verts += [topCorners[i], topCorners[j]]
        idx += [i32, i32+1]; i32 += 2
    }

    let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: verts)],
                          elements: [SCNGeometryElement(indices: idx, primitiveType: .line)])
    let mat = SCNMaterial(); mat.diffuse.contents = UIColor(white: 0.38, alpha: 1); mat.lightingModel = .constant
    geo.materials = [mat]
    let root = SCNNode(geometry: geo)

    let fontSize = CGFloat(max(scaleX, scaleZ)) * 0.07
    let labelMat = SCNMaterial()
    labelMat.diffuse.contents = UIColor(white: 0.7, alpha: 1)
    labelMat.lightingModel = .constant
    labelMat.isDoubleSided = true

    let pad = Float(fontSize) * 1.2

    // X-dimension label: lies flat at front edge, width runs along world X.
    // SCNText's local origin is at the baseline, so the glyph body extends
    // toward the bed (local +Y → world −Z); offset by tMax.y to clear the edge.
    do {
        let geo = SCNText(string: String(format: "%.0f mm", bedX), extrusionDepth: 0)
        geo.font = UIFont.systemFont(ofSize: fontSize, weight: .medium)
        geo.flatness = 0.1
        geo.materials = [labelMat]
        let (tMin, tMax) = geo.boundingBox
        let node = SCNNode(geometry: geo)
        node.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        node.position = SCNVector3(-(tMin.x + tMax.x) / 2, 0, halfZ + pad + tMax.y)
        root.addChildNode(node)
    }

    // Y-dimension label: lies flat at right edge, width runs along world Z.
    // After rotation, local +Y → world −X, so offset by tMax.y to clear the edge.
    do {
        let geo = SCNText(string: String(format: "%.0f mm", bedY), extrusionDepth: 0)
        geo.font = UIFont.systemFont(ofSize: fontSize, weight: .medium)
        geo.flatness = 0.1
        geo.materials = [labelMat]
        let (tMin, tMax) = geo.boundingBox
        let node = SCNNode(geometry: geo)
        node.eulerAngles = SCNVector3(-Float.pi / 2, Float.pi / 2, 0)
        node.position = SCNVector3(halfX + pad + tMax.y, 0, (tMin.x + tMax.x) / 2)
        root.addChildNode(node)
    }

    return root
}

// MARK: - Corner axis arrows

func makeAxesNode(bedX: Double, bedY: Double) -> SCNNode {
    let root = SCNNode()
    let short = Float(min(bedX, bedY)) / 100
    let s = short * 0.15
    let sl: CGFloat = CGFloat(s), sr: CGFloat = CGFloat(s)*0.05
    let hl: CGFloat = CGFloat(s)*0.36, hr: CGFloat = CGFloat(s)*0.12

    root.addChildNode(arrow(shaft: sl, shaftR: sr, head: hl, headR: hr,
                            color: UIColor(red: 0.95, green: 0.2, blue: 0.2, alpha: 1),
                            euler: SCNVector3(0, 0, -Float.pi/2)))
    root.addChildNode(arrow(shaft: sl, shaftR: sr, head: hl, headR: hr,
                            color: UIColor(red: 0.2, green: 0.85, blue: 0.3, alpha: 1),
                            euler: SCNVector3(-Float.pi/2, 0, 0)))
    root.addChildNode(arrow(shaft: sl, shaftR: sr, head: hl, headR: hr,
                            color: UIColor(red: 0.2, green: 0.5, blue: 1.0, alpha: 1),
                            euler: SCNVector3(0, 0, 0)))
    root.position = SCNVector3(-Float(bedX)/200, 0.01, Float(bedY)/200)
    return root
}

// MARK: - Coordinator

final class Coordinator: NSObject, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {

    // MARK: Per-model node tracking
    struct ModelEntry {
        let pivot: SCNNode
        let mesh:  SCNNode
        var bboxNode:      SCNNode?
        var lastGeometry:  SCNGeometry?
        var lastTransform: ModelTransform = .identity
        var halfHeight:    Float = 0
        /// Raw (unscaled) mesh bounding-box extents in mesh-local space (x/y/z map 1:1 to
        /// transform.scale x/y/z — see effectiveGizmoScale). Diagonal of this * transform.scale
        /// gives the model's current on-screen size, so the gizmo can grow/shrink with it.
        var meshExtent:    SIMD3<Float> = SIMD3(repeating: 0.06)
        var tintKey:       STLSceneView.TintKey?
        var overlayNodes:  [SCNNode] = []
        /// Centre of the model's display STL (mm), which its geometry is centred on.
        var centreMM:      SIMD3<Float> = .zero
    }
    var modelEntries: [UUID: ModelEntry] = [:]

    // MARK: Global gizmo (repositioned per selection)
    weak var gizmoContainerNode:  SCNNode?
    weak var gizmoTranslateGroup: SCNNode?
    weak var gizmoRotateGroup:    SCNNode?
    weak var gizmoScaleGroup:     SCNNode?

    // MARK: Camera
    weak var cameraNode: SCNNode?
    var lastCameraModelID: UUID? = nil

    // MARK: Persistent view state
    var selectedModelID:    UUID? = nil
    var gizmoMode:          GizmoMode = .translate
    var lockScale:          Bool = true
    var lastBedX:           Double = 0
    var lastBedY:           Double = 0
    var lastBedZ:           Double = 0
    var lastShowWireframe:  Bool = false

    // MARK: Drag state
    weak var tapGesture:    UITapGestureRecognizer?
    weak var panGesture:    UIPanGestureRecognizer?
    weak var pencilPanGesture: UIPanGestureRecognizer?
    var dragAxis:           GizmoAxis? = nil
    /// Pencil drag of a whole model across the bed: the horizontal plane (scene Y) the
    /// drag runs on, where it started on that plane, and the transform at that moment.
    var bedDragPlaneY:      Float? = nil
    var bedDragAnchor:      SIMD3<Float> = .zero
    var bedDragStart:       ModelTransform = .identity
    // Wipe tower (drawn and dragged on the bed).
    var wipeTower:          WipeTowerFootprint?
    var lastWipeTower:      WipeTowerFootprint?
    var bedCentreMM:        SIMD2<Double> = .zero
    var lastBedCentreMM:    SIMD2<Double> = .zero
    var wipeTowerNode:      SCNNode?
    var towerDragStart:     SIMD2<Double>?
    // Paint mode.
    var paintController:    PaintController?
    var paintPanGesture:    UIPanGestureRecognizer?
    var orbitPanGesture:    UIPanGestureRecognizer?
    var pinchGesture:       UIPinchGestureRecognizer?
    private var lastOrbit:  CGPoint = .zero
    private var lastPinch:  CGFloat = 1
    var onWipeTowerMove:    ((SIMD2<Double>) -> Void)?
    var isHoverHighlighting = false
    var dragMode:           GizmoMode = .translate
    var lastPanLocation:    CGPoint? = nil
    var currentTransform:   ModelTransform = .identity

    // MARK: Callbacks
    var onTransformChange: ((UUID, ModelTransform) -> Void)? = nil
    var onSelectionChange: ((UUID?) -> Void)? = nil
    var onDragEnded:       (() -> Void)? = nil
    var onCameraSet:       (() -> Void)? = nil
    var onPencilAction:    (() -> Void)? = nil
    var didSetCamera:      Bool = false

    // MARK: Gizmo visibility

    func updateGizmoGroupVisibility() {
        guard let id = selectedModelID, let entry = modelEntries[id] else {
            gizmoContainerNode?.isHidden = true
            return
        }
        let show = entry.mesh.geometry != nil && paintController == nil   // no gizmo while painting
        gizmoContainerNode?.isHidden = !show
        guard show else { return }
        gizmoTranslateGroup?.isHidden = gizmoMode != .translate
        gizmoRotateGroup?.isHidden    = gizmoMode != .rotate
        gizmoScaleGroup?.isHidden     = gizmoMode != .scale
    }

    // MARK: Tap

    // MARK: Paint

    /// The painted model's triangle under a screen point: printable part
    /// (geometry element), triangle within it, and the hit and camera in the
    /// model's display-STL frame (mm).
    private func paintHit(_ location: CGPoint, in v: SCNView)
        -> (element: Int, facet: Int, point: SIMD3<Float>, camera: SIMD3<Float>)? {
        guard let controller = paintController, let entry = modelEntries[controller.modelID],
              let pov = v.pointOfView else { return nil }
        let hits = v.hitTest(location, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue,
                                                 .rootNode: entry.mesh, .ignoreHiddenNodes: true])
        guard let hit = hits.first(where: { $0.node === entry.mesh }),
              let elements = entry.mesh.geometry?.elements.count, hit.geometryIndex < elements - 1 else { return nil }
        let point = SIMD3<Float>(hit.localCoordinates) * 100 + entry.centreMM
        let camera = entry.mesh.simdConvertPosition(pov.simdWorldPosition, from: nil) * 100 + entry.centreMM
        return (hit.geometryIndex, hit.faceIndex, point, camera)
    }

    @objc func handlePaintPan(_ gesture: UIPanGestureRecognizer) {
        guard let v = gesture.view as? SCNView, let controller = paintController else { return }
        let location = gesture.location(in: v)
        switch gesture.state {
        case .began:
            // Start where the finger first touched, not where the pan was recognized.
            let start = CGPoint(x: location.x - gesture.translation(in: v).x, y: location.y - gesture.translation(in: v).y)
            if let h = paintHit(start, in: v) ?? paintHit(location, in: v) {
                controller.touchBegan(element: h.element, facet: h.facet, point: h.point, camera: h.camera)
            }
        case .changed:
            if let h = paintHit(location, in: v) {
                controller.touchMoved(element: h.element, facet: h.facet, point: h.point, camera: h.camera)
            }
        default:
            controller.touchEnded()
        }
    }

    @objc func handleOrbitPan(_ gesture: UIPanGestureRecognizer) {
        guard let v = gesture.view as? SCNView else { return }
        let t = gesture.translation(in: v)
        if gesture.state == .began { lastOrbit = .zero }
        let d = CGPoint(x: t.x - lastOrbit.x, y: t.y - lastOrbit.y)
        lastOrbit = t
        v.defaultCameraController.rotateBy(x: Float(d.x) * 0.3, y: Float(d.y) * 0.3)
    }

    @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard let v = gesture.view as? SCNView else { return }
        if gesture.state == .began { lastPinch = 1 }
        let delta = Float(gesture.scale / lastPinch)
        lastPinch = gesture.scale
        v.defaultCameraController.dolly(by: (delta - 1) * 2, onScreenPoint: gesture.location(in: v), viewport: v.bounds.size)
    }

    @objc func handleTap(_ tap: UITapGestureRecognizer) {
        if let controller = paintController, let v = tap.view as? SCNView {
            // A tap is a single brush dab or a fill.
            if let h = paintHit(tap.location(in: v), in: v) {
                controller.touchBegan(element: h.element, facet: h.facet, point: h.point, camera: h.camera)
                controller.touchEnded()
            }
            return
        }
        guard let scnView = tap.view as? SCNView else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        // .all walks every intersection along the ray. The gizmo arrows have large invisible
        // hit cylinders that would otherwise be the *closest* hit and shadow the model behind
        // them. We just look for any model along the ray; if none, the tap deselects.
        // (Gizmo dragging uses a separate pan gesture, so a stationary tap on a gizmo handle
        //  has no meaning — letting it fall through to deselect is fine.)
        let hits = scnView.hitTest(tap.location(in: scnView),
                                   options: [.searchMode: SCNHitTestSearchMode.all.rawValue,
                                             .ignoreHiddenNodes: true])
        let modelHit = hits.first(where: { modelID(for: $0.node) != nil })?.node
        setSelected(id: modelID(for: modelHit))
    }

    private func setSelected(id: UUID?) {
        selectedModelID = id
        if let id = id { currentTransform = modelEntries[id]?.lastTransform ?? .identity }
        updateGizmoGroupVisibility()
        onSelectionChange?(id)
    }

    // Returns the model UUID that contains `node` by walking up the hierarchy.
    private func modelID(for node: SCNNode?) -> UUID? {
        var n = node
        while let cur = n {
            if let id = UUID(uuidString: cur.name ?? ""), modelEntries[id] != nil { return id }
            n = cur.parent
        }
        return nil
    }

    // MARK: Pan

    @objc func handleGizmoPan(_ gesture: UIPanGestureRecognizer) {
        guard let scnView = gesture.view as? SCNView else { return }

        switch gesture.state {
        case .began:
            let loc  = gesture.location(in: scnView)
            let hits = scnView.hitTest(loc, options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
            if let tower = wipeTower, hits.contains(where: { $0.node.name == wipeTowerNodeName }),
               let anchor = bedPlanePoint(loc, planeY: 0, in: scnView) {
                towerDragStart = SIMD2(tower.x, tower.y)
                bedDragAnchor = anchor
                scnView.allowsCameraControl = false
            } else if gizmoContainerNode?.isHidden == false,
               let info = hits.lazy.compactMap({ self.gizmoNodeInfo($0.node) }).first {
                dragAxis = info.axis
                dragMode = info.mode
                lastPanLocation = loc
                scnView.allowsCameraControl = false
                isHoverHighlighting = false
                setGizmoAxisHighlight(active: info.axis, mode: info.mode)
            } else if gesture === pencilPanGesture,
                      let hit = hits.first(where: { modelID(for: $0.node) != nil }),
                      let id = modelID(for: hit.node) {
                if id != selectedModelID { setSelected(id: id) }
                let planeY = Float(hit.worldCoordinates.y)
                guard let anchor = bedPlanePoint(loc, planeY: planeY, in: scnView) else { return }
                bedDragPlaneY = planeY
                bedDragAnchor = anchor
                bedDragStart  = currentTransform
                scnView.allowsCameraControl = false
            }

        case .changed:
            if let start = towerDragStart {
                guard let p = bedPlanePoint(gesture.location(in: scnView), planeY: 0, in: scnView) else { return }
                // Scene X = print X, scene Z = −print Y; 1 scene unit = 100 mm.
                let moved = SIMD2(start.x + Double(p.x - bedDragAnchor.x) * 100,
                                  start.y - Double(p.z - bedDragAnchor.z) * 100)
                onWipeTowerMove?(SIMD2((moved.x * 10).rounded() / 10, (moved.y * 10).rounded() / 10))
                return
            }
            if let planeY = bedDragPlaneY {
                guard let id = selectedModelID,
                      let p = bedPlanePoint(gesture.location(in: scnView), planeY: planeY, in: scnView)
                else { return }
                // Scene X = print X, scene Z = print Y; 1 scene unit = 100 mm.
                var t = bedDragStart
                t.positionMM.x += (p.x - bedDragAnchor.x) * 100
                t.positionMM.y += (p.z - bedDragAnchor.z) * 100
                currentTransform = t
                onTransformChange?(id, t)
                return
            }
            guard let axis = dragAxis,
                  let last = lastPanLocation,
                  let id = selectedModelID,
                  let entry = modelEntries[id] else { return }

            let cur   = gesture.location(in: scnView)
            let delta = CGPoint(x: cur.x - last.x, y: cur.y - last.y)
            lastPanLocation = cur

            var t = currentTransform
            switch dragMode {
            case .translate:
                let dm = axisDeltaMM(screenDelta: delta, dir: axis.worldDir,
                                     in: scnView, origin: entry.pivot.worldPosition)
                switch axis {
                case .x: t.positionMM.x += dm
                case .y: t.positionMM.y += dm
                case .z: t.positionMM.z += dm
                }

            case .rotate:
                let deg = rotateAngleDeg(screenDelta: delta, axis: axis.worldDir,
                                         in: scnView, origin: entry.pivot.worldPosition)
                switch axis {
                case .x: t.rotationDeg.x += deg
                case .y: t.rotationDeg.y += deg
                case .z: t.rotationDeg.z += deg
                }

            case .scale:
                let proj = axisScreenPx(screenDelta: delta, dir: axis.worldDir,
                                        in: scnView, origin: entry.pivot.worldPosition)
                let mult = max(0.001, 1.0 + proj / 200.0)
                if lockScale {
                    t.scale.x = max(0.001, t.scale.x * mult)
                    t.scale.y = max(0.001, t.scale.y * mult)
                    t.scale.z = max(0.001, t.scale.z * mult)
                } else {
                    switch axis {
                    case .x: t.scale.x = max(0.001, t.scale.x * mult)
                    case .y: t.scale.y = max(0.001, t.scale.y * mult)
                    case .z: t.scale.z = max(0.001, t.scale.z * mult)
                    }
                }
            }

            currentTransform = t
            onTransformChange?(id, t)

        case .ended, .cancelled:
            dragAxis = nil
            bedDragPlaneY = nil
            towerDragStart = nil
            lastPanLocation = nil
            scnView.allowsCameraControl = true
            restoreGizmoAxisHighlight()
            onDragEnded?()

        default: break
        }
    }

    // MARK: Gesture delegate

    func gestureRecognizerShouldBegin(_ gr: UIGestureRecognizer) -> Bool {
        // We're the delegate for tap and both pans — only gate the pans.
        // Anything else (notably the tap) must be allowed to recognize.
        guard gr === panGesture || gr === pencilPanGesture else { return true }
        guard let scnView = gr.view as? SCNView else { return false }
        let hits = scnView.hitTest(gr.location(in: scnView),
                                   options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
        let gizmoVisible = selectedModelID != nil && gizmoContainerNode?.isHidden == false
        if gizmoVisible, hits.contains(where: { gizmoNodeInfo($0.node) != nil }) { return true }
        // The wipe tower drags with a finger or the Pencil.
        if wipeTower != nil, hits.contains(where: { $0.node.name == wipeTowerNodeName }) { return true }
        // Pencil can also grab any model body; on empty space it falls through to the camera.
        return gr === pencilPanGesture && hits.contains { modelID(for: $0.node) != nil }
    }

    func gestureRecognizer(_ gr: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Allow tap to coexist with the camera's orbit gesture — without this, the camera pan
        // cancels the tap, making it impossible to re-select a model after deselecting.
        return gr === panGesture || other === panGesture
            || gr === pencilPanGesture || other === pencilPanGesture
            || gr === tapGesture || other === tapGesture
    }

    // MARK: Hover

    @objc func handleHover(_ hover: UIHoverGestureRecognizer) {
        guard let scnView = hover.view as? SCNView,
              dragAxis == nil, bedDragPlaneY == nil else { return }
        var hovered: (axis: GizmoAxis, mode: GizmoMode)? = nil
        if hover.state == .began || hover.state == .changed,
           gizmoContainerNode?.isHidden == false {
            let hits = scnView.hitTest(hover.location(in: scnView),
                                       options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
            hovered = hits.lazy.compactMap({ self.gizmoNodeInfo($0.node) }).first
        }
        if let info = hovered {
            setGizmoAxisHighlight(active: info.axis, mode: info.mode)
            isHoverHighlighting = true
        } else if isHoverHighlighting {
            restoreGizmoAxisHighlight()
            isHoverHighlighting = false
        }
    }

    // MARK: Pencil double-tap / squeeze

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        guard UIPencilInteraction.preferredTapAction != .ignore else { return }
        onPencilAction?()
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction,
                           didReceiveTap tap: UIPencilInteraction.Tap) {
        guard UIPencilInteraction.preferredTapAction != .ignore else { return }
        onPencilAction?()
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction,
                           didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended,
              UIPencilInteraction.preferredSqueezeAction != .ignore else { return }
        onPencilAction?()
    }

    // MARK: Helpers

    private func gizmoNodeInfo(_ node: SCNNode?) -> (axis: GizmoAxis, mode: GizmoMode)? {
        var n = node
        while let cur = n {
            switch cur.name {
            case "gizmo_x":       return (.x, .translate)
            case "gizmo_y":       return (.y, .translate)
            case "gizmo_z":       return (.z, .translate)
            case "gizmo_rot_x":   return (.x, .rotate)
            case "gizmo_rot_y":   return (.y, .rotate)
            case "gizmo_rot_z":   return (.z, .rotate)
            case "gizmo_scale_x": return (.x, .scale)
            case "gizmo_scale_y": return (.y, .scale)
            case "gizmo_scale_z": return (.z, .scale)
            default: n = cur.parent
            }
        }
        return nil
    }

    private func setGizmoAxisHighlight(active: GizmoAxis, mode: GizmoMode) {
        let names: [(String, GizmoAxis)] = {
            switch mode {
            case .translate: return [("gizmo_x",.x),("gizmo_y",.y),("gizmo_z",.z)]
            case .rotate:    return [("gizmo_rot_x",.x),("gizmo_rot_y",.y),("gizmo_rot_z",.z)]
            case .scale:     return [("gizmo_scale_x",.x),("gizmo_scale_y",.y),("gizmo_scale_z",.z)]
            }
        }()
        let group: SCNNode? = {
            switch mode {
            case .translate: return gizmoTranslateGroup
            case .rotate:    return gizmoRotateGroup
            case .scale:     return gizmoScaleGroup
            }
        }()
        for (name, axis) in names {
            if let node = group?.childNode(withName: name, recursively: false) {
                node.opacity = axis == active ? 1.0 : 0.2
            }
        }
    }

    private func restoreGizmoAxisHighlight() {
        for group in [gizmoTranslateGroup, gizmoRotateGroup, gizmoScaleGroup] {
            group?.enumerateChildNodes { node, _ in node.opacity = 1.0 }
        }
    }

    /// Where the screen ray through `point` meets the horizontal plane at scene height `planeY`.
    private func bedPlanePoint(_ point: CGPoint, planeY: Float, in v: SCNView) -> SIMD3<Float>? {
        let near = SIMD3<Float>(v.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 0)))
        let far  = SIMD3<Float>(v.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 1)))
        let dir = far - near
        // A near-horizontal view ray would fling the model toward the horizon.
        guard abs(dir.y) > 1e-4 * simd_length(dir) else { return nil }
        let t = (planeY - near.y) / dir.y
        guard t > 0 else { return nil }
        return near + dir * t
    }

    private func axisDeltaMM(screenDelta: CGPoint, dir: SIMD3<Float>,
                              in v: SCNView, origin: SCNVector3) -> Float {
        let p0 = v.projectPoint(origin)
        let p1 = v.projectPoint(SCNVector3(origin.x+dir.x, origin.y+dir.y, origin.z+dir.z))
        let sx = CGFloat(p1.x-p0.x), sy = CGFloat(p1.y-p0.y)
        let sq = sx*sx + sy*sy
        guard sq > 0.01 else { return 0 }
        return Float((screenDelta.x*sx + screenDelta.y*sy) / sq) * 100
    }

    private func axisScreenPx(screenDelta: CGPoint, dir: SIMD3<Float>,
                               in v: SCNView, origin: SCNVector3) -> Float {
        let p0 = v.projectPoint(origin)
        let p1 = v.projectPoint(SCNVector3(origin.x+dir.x, origin.y+dir.y, origin.z+dir.z))
        let sx = CGFloat(p1.x-p0.x), sy = CGFloat(p1.y-p0.y)
        let len = sqrt(sx*sx + sy*sy)
        guard len > 0.1 else { return 0 }
        return Float((screenDelta.x*sx + screenDelta.y*sy) / len)
    }

    private func rotateAngleDeg(screenDelta: CGPoint, axis: SIMD3<Float>,
                                 in v: SCNView, origin: SCNVector3) -> Float {
        let p0 = v.projectPoint(origin)
        let p1 = v.projectPoint(SCNVector3(origin.x+axis.x, origin.y+axis.y, origin.z+axis.z))
        let px = -(CGFloat(p1.y-p0.y))
        let py =   CGFloat(p1.x-p0.x)
        let plen = sqrt(px*px + py*py)
        guard plen > 0.1 else { return 0 }
        let proj = (screenDelta.x*px + screenDelta.y*py) / plen
        return Float(proj) * 0.3
    }
}

// MARK: - Wipe tower

let wipeTowerNodeName = "wipeTower"

/// The wipe tower as a translucent box on its brim, rotated about its
/// front-left corner like PrusaSlicer draws it.
func makeWipeTowerNode(_ tower: WipeTowerFootprint, bedCentreMM: SIMD2<Double>) -> SCNNode {
    let corner = SCNNode()
    corner.position = SCNVector3(Float(tower.x - bedCentreMM.x) / 100, 0, -Float(tower.y - bedCentreMM.y) / 100)
    corner.eulerAngles.y = Float(tower.rotationDeg * .pi / 180)

    let w = CGFloat(tower.width / 100), d = CGFloat(tower.depth / 100), h = CGFloat(tower.height / 100)
    let box = SCNBox(width: w, height: h, length: d, chamferRadius: 0)
    let material = SCNMaterial()
    material.diffuse.contents = UIColor(red: 0.55, green: 0.70, blue: 0.55, alpha: 1)
    material.transparency = tower.isEstimate ? 0.45 : 0.7
    material.lightingModel = .physicallyBased
    box.materials = [material]
    let body = SCNNode(geometry: box)
    body.name = wipeTowerNodeName
    body.position = SCNVector3(Float(w / 2), Float(h / 2), -Float(d / 2))
    corner.addChildNode(body)

    let b = CGFloat(tower.brim / 100)
    if b > 0 {
        let brim = SCNBox(width: w + 2 * b, height: 0.002, length: d + 2 * b, chamferRadius: 0)
        let brimMaterial = SCNMaterial()
        brimMaterial.diffuse.contents = UIColor(red: 0.55, green: 0.70, blue: 0.55, alpha: 1)
        brimMaterial.transparency = 0.35
        brim.materials = [brimMaterial]
        let brimNode = SCNNode(geometry: brim)
        brimNode.name = wipeTowerNodeName
        brimNode.position = SCNVector3(Float(w / 2), 0.001, -Float(d / 2))
        corner.addChildNode(brimNode)
    }
    return corner
}

// MARK: - Paint overlay

/// Painted triangles in their tools' colours, nudged off the surface along
/// their normals so they draw over the model's own triangles.
func makePaintGeometry(_ paint: PaintMesh, centreMM: SIMD3<Float>, palette: ToolPalette?) -> SCNGeometry? {
    guard !paint.isEmpty else { return nil }
    var positions: [SCNVector3] = [], normals: [SCNVector3] = [], colours: [SIMD4<Float>] = []
    positions.reserveCapacity(paint.states.count * 3)
    var cache: [UInt8: SIMD4<Float>] = [:]
    for (i, state) in paint.states.enumerated() {
        let v = (0..<3).map { k in SIMD3(paint.vertices[i * 9 + k * 3], paint.vertices[i * 9 + k * 3 + 1], paint.vertices[i * 9 + k * 3 + 2]) }
        var n = simd_cross(v[1] - v[0], v[2] - v[0])
        let len = simd_length(n)
        n = len > 1e-10 ? n / len : SIMD3(0, 0, 1)
        let colour = cache[state] ?? {
            let c = palette?.colour(Int(state)) ?? HexColour(red: 0.9, green: 0.4, blue: 0.1)
            let rgba = SIMD4(Float(c.red), Float(c.green), Float(c.blue), 1)
            cache[state] = rgba
            return rgba
        }()
        for p in v {
            let q = (p + n * 0.03 - centreMM) / 100
            positions.append(SCNVector3(q.x, q.y, q.z))
            normals.append(SCNVector3(n.x, n.y, n.z))
            colours.append(colour)
        }
    }
    let colourData = colours.withUnsafeBytes { Data($0) }
    let geometry = SCNGeometry(
        sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals),
                  SCNGeometrySource(data: colourData, semantic: .color, vectorCount: colours.count,
                                    usesFloatComponents: true, componentsPerVector: 4,
                                    bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                    dataStride: MemoryLayout<SIMD4<Float>>.stride)],
        elements: [SCNGeometryElement(indices: Array(0..<Int32(positions.count)), primitiveType: .triangles)])
    let material = SCNMaterial()
    material.diffuse.contents = UIColor.white
    material.lightingModel = .physicallyBased
    material.roughness.contents = Float(0.65)
    material.isDoubleSided = true
    geometry.materials = [material]
    return geometry
}
