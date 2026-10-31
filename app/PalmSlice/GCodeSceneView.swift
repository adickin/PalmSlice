import SceneKit
import SwiftUI
import simd

// MARK: - View

/// What the preview's line colours show.
enum PreviewColouring: String, CaseIterable, Identifiable {
    case feature = "Feature", tool = "Tool"
    var id: String { rawValue }
}

struct GCodeSceneView: UIViewRepresentable {
    let layers: [GCodeLayer]
    var currentLayerIndex: Int
    var bedX: Double = 220
    var bedY: Double = 220
    var colouring: PreviewColouring = .feature
    /// Colour per tool (0-based) for `.tool` colouring.
    var toolColours: [HexColour] = []

    func makeCoordinator() -> GCodeCoordinator { GCodeCoordinator() }

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

        // Bed + axes (reuse helpers from STLSceneView)
        let bedNode = makePrintBedNode(bedX: bedX, bedY: bedY)
        bedNode.name = "printBed"
        scene.rootNode.addChildNode(bedNode)

        let axesNode = makeAxesNode(bedX: bedX, bedY: bedY)
        axesNode.name = "axes"
        scene.rootNode.addChildNode(axesNode)

        // Container node for all per-layer geometry
        let layerContainer = SCNNode()
        layerContainer.name = "layerContainer"
        scene.rootNode.addChildNode(layerContainer)
        context.coordinator.layerContainer = layerContainer

        // Ambient light so lines are visible from all angles
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 1000
        ambientLight.color = UIColor.white
        let ambientNode = SCNNode()
        ambientNode.light = ambientLight
        scene.rootNode.addChildNode(ambientNode)

        // Camera positioned to see the whole bed
        let bedDiag = Float(sqrt(bedX * bedX + bedY * bedY)) / 100
        let camera = SCNCamera()
        camera.zNear = 0.01
        camera.zFar  = 100
        camera.fieldOfView = 45
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(bedDiag * 0.55, bedDiag * 0.65, bedDiag * 0.9)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)
        scnView.pointOfView = cameraNode
        context.coordinator.cameraNode = cameraNode
        context.coordinator.lastBedX = bedX
        context.coordinator.lastBedY = bedY

        return scnView
    }

    func updateUIView(_ scnView: SCNView, context: Context) {
        let coord = context.coordinator

        // 1. Rebuild bed/axes if printer dimensions changed
        if (coord.lastBedX != bedX || coord.lastBedY != bedY), let scene = scnView.scene {
            scene.rootNode.childNode(withName: "printBed", recursively: false)?.removeFromParentNode()
            scene.rootNode.childNode(withName: "axes", recursively: false)?.removeFromParentNode()
            let bedNode = makePrintBedNode(bedX: bedX, bedY: bedY)
            bedNode.name = "printBed"
            scene.rootNode.addChildNode(bedNode)
            let axesNode = makeAxesNode(bedX: bedX, bedY: bedY)
            axesNode.name = "axes"
            scene.rootNode.addChildNode(axesNode)
            coord.lastBedX = bedX
            coord.lastBedY = bedY
        }

        // 2. Rebuild layer nodes if layers or colours changed
        let colourKey = colouring == .tool ? toolColours.map(\.hex).joined() : colouring.rawValue
        if layers.count != coord.lastLayerCount || colourKey != coord.lastColourKey {
            coord.lastLayerCount = layers.count
            coord.lastColourKey = colourKey

            // Cancel any in-flight build
            coord.buildTask?.cancel()

            // Remove old nodes
            coord.layerNodes.forEach { $0.removeFromParentNode() }
            coord.layerNodes = []

            let capturedLayers = layers
            let capturedBedX   = bedX
            let capturedBedY   = bedY
            let capturedIndex  = currentLayerIndex
            let colours: LineColours = colouring == .tool
                ? .tool(toolColours.map { SIMD4(Float($0.red), Float($0.green), Float($0.blue), 1) })
                : .feature

            coord.buildTask = Task.detached(priority: .userInitiated) {
                // Build SCNGeometry objects off the main thread (creating geometry is thread-safe)
                var geometries: [SCNGeometry?] = []
                geometries.reserveCapacity(capturedLayers.count)
                for layer in capturedLayers {
                    guard !Task.isCancelled else { break }
                    geometries.append(buildLayerGeometry(layer: layer, bedX: capturedBedX, bedY: capturedBedY,
                                                         colours: colours))
                }

                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard let container = coord.layerContainer else { return }
                    var nodes: [SCNNode] = []
                    for (i, geo) in geometries.enumerated() {
                        let node = SCNNode(geometry: geo)
                        node.isHidden = i > capturedIndex
                        container.addChildNode(node)
                        nodes.append(node)
                    }
                    coord.layerNodes = nodes
                    // Apply the current slider position (may have changed while building)
                    coord.applyLayerVisibility(upTo: coord.lastCurrentLayer)
                }
            }
        }

        // 3. Update layer visibility when slider moves
        if currentLayerIndex != coord.lastCurrentLayer {
            coord.lastCurrentLayer = currentLayerIndex
            coord.applyLayerVisibility(upTo: currentLayerIndex)
        }
    }
}

// MARK: - Coordinator

final class GCodeCoordinator: NSObject {
    var buildTask:        Task<Void, Never>?
    var lastLayerCount:   Int = -1
    var lastColourKey:    String = ""
    var layerNodes:       [SCNNode] = []
    var lastCurrentLayer: Int = -1
    weak var layerContainer: SCNNode?
    weak var cameraNode: SCNNode?
    var lastBedX: Double = 0
    var lastBedY: Double = 0

    func applyLayerVisibility(upTo index: Int) {
        for (i, node) in layerNodes.enumerated() {
            node.isHidden = i > index
        }
    }
}

// MARK: - Per-layer geometry builder

enum LineColours {
    case feature
    /// RGBA per tool (0-based); the wipe tower stays its feature colour.
    case tool([SIMD4<Float>])

    func colour(for move: GCodeMove) -> SIMD4<Float> {
        switch self {
        case .feature: return lineColor(for: move.type)
        case .tool(let colours):
            guard move.type != .wipeTower, !colours.isEmpty else { return lineColor(for: move.type) }
            return colours[min(move.tool, colours.count - 1)]
        }
    }
}

/// Builds an SCNGeometry of line segments for a single layer, coloured by extrusion type or tool.
/// Safe to call off the main thread — creates new geometry objects without touching a scene.
func buildLayerGeometry(layer: GCodeLayer, bedX: Double, bedY: Double,
                        colours: LineColours = .feature) -> SCNGeometry? {
    guard !layer.moves.isEmpty else { return nil }

    var vertices: [SCNVector3]    = []
    var colors:   [SIMD4<Float>]  = []
    vertices.reserveCapacity(layer.moves.count * 2)
    colors.reserveCapacity(layer.moves.count * 2)

    for move in layer.moves {
        let from = gcodeToScene(pos: move.from, bedX: bedX, bedY: bedY)
        let to   = gcodeToScene(pos: move.to,   bedX: bedX, bedY: bedY)
        vertices.append(from)
        vertices.append(to)
        let c = colours.colour(for: move)
        colors.append(c)
        colors.append(c)
    }

    guard !vertices.isEmpty else { return nil }

    // Line indices: each consecutive pair is one segment
    let indices = (0..<Int32(vertices.count)).map { $0 }
    let element = SCNGeometryElement(indices: indices, primitiveType: .line)

    let vertexSource = SCNGeometrySource(vertices: vertices)

    let colorData = colors.withUnsafeBytes { Data($0) }
    let colorSource = SCNGeometrySource(
        data: colorData,
        semantic: .color,
        vectorCount: colors.count,
        usesFloatComponents: true,
        componentsPerVector: 4,
        bytesPerComponent: MemoryLayout<Float>.size,
        dataOffset: 0,
        dataStride: MemoryLayout<SIMD4<Float>>.stride
    )

    let geo = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])

    let mat = SCNMaterial()
    mat.lightingModel      = .constant
    mat.diffuse.contents   = UIColor.white  // vertex colours drive output
    mat.isDoubleSided      = true
    geo.materials = [mat]

    return geo
}

// MARK: - Helpers

/// Maps GCode mm coordinates to SceneKit world space.
/// GCode: X=right, Y=forward, Z=up (mm, origin at bed front-left corner)
/// SceneKit: 1 unit = 100 mm; bed centred at (0, 0, 0) at ground level
private func gcodeToScene(pos: SIMD3<Float>, bedX: Double, bedY: Double) -> SCNVector3 {
    let sx = (pos.x - Float(bedX) / 2) / 100
    let sy =  pos.z / 100                               // Z height → SceneKit Y
    let sz = -(pos.y - Float(bedY) / 2) / 100           // Y forward → SceneKit -Z
    return SCNVector3(sx, sy, sz)
}

func lineColor(for type: ExtrusionType) -> SIMD4<Float> {
    switch type {
    case .externalPerimeter:  return SIMD4(1.00, 0.55, 0.00, 1.0)  // orange
    case .perimeter:          return SIMD4(1.00, 0.85, 0.00, 1.0)  // yellow
    case .solidInfill:        return SIMD4(1.00, 0.27, 0.27, 1.0)  // red
    case .topSolidInfill:     return SIMD4(0.90, 0.20, 0.20, 1.0)  // darker red
    case .infill:             return SIMD4(0.00, 0.75, 1.00, 1.0)  // cyan
    case .bridgeInfill:       return SIMD4(0.50, 0.90, 1.00, 1.0)  // light blue
    case .support:            return SIMD4(0.80, 0.60, 1.00, 1.0)  // light purple
    case .supportInterface:   return SIMD4(0.90, 0.70, 1.00, 1.0)  // lighter purple
    case .wipeTower:          return SIMD4(0.55, 0.70, 0.55, 1.0)  // grey-green
    case .travel:             return SIMD4(0.50, 0.50, 0.50, 0.25) // grey, low alpha
    case .other:              return SIMD4(1.00, 1.00, 1.00, 1.0)  // white
    }
}
