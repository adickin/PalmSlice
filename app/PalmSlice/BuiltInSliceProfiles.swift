import Foundation

enum BuiltInSliceProfiles {
    static let draft = SliceProfile(
        name: "Draft (0.3 mm)",
        layerHeight: 0.3,
        firstLayerHeight: 0.3,
        wallCount: 2,
        topLayers: 3,
        bottomLayers: 3,
        infillDensity: 15,
        infillPattern: .grid,
        printSpeed: 80,
        infillSpeed: 100,
        travelSpeed: 150,
        firstLayerSpeed: 30
    )

    static let standard = SliceProfile(
        name: "Standard (0.2 mm)",
        layerHeight: 0.2,
        firstLayerHeight: 0.2,
        wallCount: 3,
        topLayers: 4,
        bottomLayers: 4,
        infillDensity: 20,
        infillPattern: .gyroid,
        printSpeed: 60,
        infillSpeed: 80,
        travelSpeed: 120,
        firstLayerSpeed: 30
    )

    static let fine = SliceProfile(
        name: "Fine (0.1 mm)",
        layerHeight: 0.1,
        firstLayerHeight: 0.1,
        wallCount: 4,
        topLayers: 6,
        bottomLayers: 6,
        infillDensity: 20,
        infillPattern: .gyroid,
        printSpeed: 40,
        infillSpeed: 60,
        travelSpeed: 120,
        firstLayerSpeed: 20
    )

    // Thicker walls and top/bottom shells for parts that need to be strong or
    // watertight rather than fast/economical. Top/Bottom thickness is set
    // directly in mm (layer counts below are kept in sync with it) — ironing
    // is on since 6 solid top layers otherwise show visible infill ridges.
    static let thickWalls = SliceProfile(
        name: "Thick Walls (0.2 mm)",
        layerHeight: 0.2,
        firstLayerHeight: 0.2,
        wallCount: 6,
        horizontalExpansion: 0.0,
        topLayers: 6,
        bottomLayers: 6,
        topThickness: 1.2,
        bottomThickness: 1.2,
        infillDensity: 20,
        infillPattern: .gyroid,
        printSpeed: 50,
        infillSpeed: 70,
        travelSpeed: 120,
        firstLayerSpeed: 25,
        solidInfillSpeed: 20,
        topSolidInfillSpeed: 15,
        ironingEnabled: true,
        ironingType: .topSurfaces,
        ironingFlowrate: 15,
        ironingSpeed: 15,
        ironingSpacing: 0.1
    )

    // Pairs with the "eSUN PLA-LW (Lightweight)" material. Foaming PLA is used for
    // light, thin-walled parts, so: 2 walls, thin shells, sparse infill. eSUN says
    // not to slow the first layer (its flow already matches the foamed layers),
    // so first-layer speed equals print speed; fast travel limits oozing, since
    // retraction is barely effective with foaming filament.
    static let lightweight = SliceProfile(
        name: "Lightweight LW-PLA (0.2 mm)",
        layerHeight: 0.2,
        firstLayerHeight: 0.2,
        wallCount: 2,
        topLayers: 3,
        bottomLayers: 3,
        infillDensity: 10,
        infillPattern: .gyroid,
        printSpeed: 45,
        infillSpeed: 45,
        travelSpeed: 150,
        firstLayerSpeed: 45,
        solidInfillSpeed: 30,
        topSolidInfillSpeed: 25
    )

    // 3DLabPrint RC plane parts, with the settings from 3dlabprint.com/faq/prusaslicer
    // (LW-PLA values). Their models build skins, ribs and spars into the geometry,
    // so the slicer prints one wall and nothing else: no top/bottom shells, no
    // infill. Even/Odd slicing, Classic walls and a 0 gap-closing radius are
    // required for that geometry to slice correctly. First layer is 50% of wall
    // speed, as specified there. Not for ordinary models: they would print as
    // hollow single-wall shells.
    static let rcPlane = SliceProfile(
        name: "3DLabPrint RC Plane (LW-PLA 0.3 mm)",
        layerHeight: 0.3,
        firstLayerHeight: 0.3,
        wallCount: 1,
        wallGenerator: .classic,
        externalPerimetersFirst: true,
        topLayers: 0,
        bottomLayers: 0,
        infillDensity: 0,
        infillPattern: .gyroid,
        slicingMode: .evenOdd,
        gapClosingRadius: 0,
        extrusionWidth: 0.42,
        firstLayerExtrusionWidth: 0.44,
        printSpeed: 40,
        infillSpeed: 40,
        travelSpeed: 150,
        firstLayerSpeed: 20,
        solidInfillSpeed: 30,
        topSolidInfillSpeed: 25,
        adhesionType: .skirt
    )

    static let all: [SliceProfile] = [draft, standard, fine, thickWalls, lightweight, rcPlane]
}
