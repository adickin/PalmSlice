import SceneKit
import Foundation

struct PlacedModel: Identifiable {
    let id: UUID
    var url: URL
    var name: String
    var geometry: SCNGeometry?
    var transform: ModelTransform
    var meshInfo: STLMeshInfo?
    var bvh: TriangleBVH?
    var isIntersecting: Bool = false
    /// PrusaSlicer settings stored on this object in its 3MF/AMF file.
    var fileSettings: ModelFileSettings? = nil
    /// Whether to slice with fileSettings (the user can switch them off).
    var useFileSettings: Bool = true
    /// The source file's project-wide PrusaSlicer settings, for creating profiles.
    var projectSettings: [String: String]? = nil
}
