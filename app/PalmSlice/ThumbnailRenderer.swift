import SceneKit
import UIKit

/// Renders the plate's models offscreen for G-code thumbnails (the printer's
/// screen shows them): tinted like the 3D view, from the front right, on a
/// transparent background.
@MainActor
enum ThumbnailRenderer {
    /// RGBA pixels, top-down rows (width × height × 4), or nil if nothing renders.
    static func render(models: [PlacedModel], palette: ToolPalette?, width: Int, height: Int) -> [UInt8]? {
        let scene = SCNScene()
        var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)?
        for model in models {
            guard let source = model.geometry else { continue }
            let geometry = source.copy() as! SCNGeometry
            geometry.materials = tintedMaterials(for: model, source: source, palette: palette)
            let node = placedNode(geometry: geometry, transform: model.transform)
            scene.rootNode.addChildNode(node)
            let (lo, hi) = node.boundingBoxInWorld()
            bounds = bounds.map { (simd_min($0.min, lo), simd_max($0.max, hi)) } ?? (lo, hi)
        }
        guard let bounds else { return nil }

        let centre = (bounds.min + bounds.max) / 2
        let radius = max(simd_length(bounds.max - bounds.min) / 2, 0.01)
        let camera = SCNCamera()
        camera.fieldOfView = 30
        camera.zNear = 0.001
        camera.zFar = 100
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        let direction = simd_normalize(SIMD3<Float>(0.8, 0.75, 1))
        let distance = radius / sin(Float(camera.fieldOfView) * .pi / 360) * 1.05
        cameraNode.simdPosition = centre + direction * distance
        cameraNode.simdLook(at: centre)
        scene.rootNode.addChildNode(cameraNode)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = 450
        scene.rootNode.addChildNode(ambient)
        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light!.type = .directional
        sun.light!.intensity = 900
        sun.simdPosition = centre + SIMD3(1, 2, 1.5)
        sun.simdLook(at: centre)
        scene.rootNode.addChildNode(sun)
        scene.background.contents = UIColor.clear

        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        renderer.autoenablesDefaultLighting = false
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: width, height: height),
                                      antialiasingMode: .multisampling4X)
        return rgba(image, width: width, height: height)
    }

    /// The model's node with its transform, matching STLSceneView's pivot / mesh nodes.
    private static func placedNode(geometry: SCNGeometry, transform t: ModelTransform) -> SCNNode {
        let pivot = SCNNode()
        let r = t.rotationDeg * (Float.pi / 180)
        pivot.position = SCNVector3(t.positionMM.x / 100, t.positionMM.z / 100, t.positionMM.y / 100)
        pivot.eulerAngles = SCNVector3(r.x, r.z, r.y)
        pivot.scale = SCNVector3(t.scale.x, t.scale.z, t.scale.y)
        let mesh = SCNNode(geometry: geometry)
        mesh.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        let (lo, hi) = geometry.boundingBox
        mesh.position = SCNVector3(-(lo.x + hi.x) / 2, -lo.z, (lo.y + hi.y) / 2)
        pivot.addChildNode(mesh)
        return pivot
    }

    private static func tintedMaterials(for model: PlacedModel, source: SCNGeometry, palette: ToolPalette?) -> [SCNMaterial] {
        let printable = model.parts.filter { $0.kind == .part }
        let faceCount = source.materials.count - 1   // the last element is the wireframe
        let tools = printable.count == faceCount
            ? printable.map { $0.extruder != 0 ? $0.extruder : model.extruder }
            : Array(repeating: model.extruder, count: max(faceCount, 1))
        var materials = tools.map { tool -> SCNMaterial in
            let m = SCNMaterial()
            m.diffuse.contents = palette?.colour(tool).uiColor ?? UIColor(white: 0.82, alpha: 1)
            m.lightingModel = .physicallyBased
            m.roughness.contents = Float(0.6)
            m.isDoubleSided = true
            return m
        }
        let hidden = SCNMaterial()
        hidden.transparency = 0
        materials.append(hidden)
        return materials
    }

    private static func rgba(_ image: UIImage, width: Int, height: Int) -> [UInt8]? {
        guard let cg = image.cgImage else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }
}

private extension SCNNode {
    /// World-space bounding box of the node's geometry and its children's.
    func boundingBoxInWorld() -> (SIMD3<Float>, SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        enumerateHierarchy { node, _ in
            guard node.geometry != nil else { return }
            let (a, b) = node.boundingBox
            for x in [a.x, b.x] { for y in [a.y, b.y] { for z in [a.z, b.z] {
                let p = node.simdConvertPosition(SIMD3(x, y, z), to: nil)
                lo = simd_min(lo, p); hi = simd_max(hi, p)
            } } }
        }
        return (lo, hi)
    }
}
