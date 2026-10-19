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

    static let all: [SliceProfile] = [draft, standard, fine, thickWalls, lightweight]
}
