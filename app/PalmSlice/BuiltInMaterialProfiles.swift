import Foundation

enum BuiltInMaterialProfiles {
    static let pla = MaterialProfile(
        name: "PLA",
        filamentDiameter: 1.75,
        firstLayerTemp: 215,
        otherLayersTemp: 210,
        firstLayerBedTemp: 60,
        otherLayersBedTemp: 55,
        extrusionMultiplier: 1.0,
        retractionEnabled: true,
        retractionLength: 5.0,
        retractionSpeed: 45.0,
        retractionRestartExtra: 0.0,
        zHop: 0.0,
        minTravelForRetraction: 1.0,
        coolingEnabled: true,
        minFanSpeed: 35,
        maxFanSpeed: 100,
        bridgeFanSpeed: 100,
        disableFanFirstLayers: 3,
        fanBelowLayerTime: 60,
        slowdownBelowLayerTime: 5,
        minPrintSpeed: 10.0
    )

    static let petg = MaterialProfile(
        name: "PETG",
        filamentDiameter: 1.75,
        firstLayerTemp: 235,
        otherLayersTemp: 230,
        firstLayerBedTemp: 80,
        otherLayersBedTemp: 75,
        extrusionMultiplier: 1.0,
        retractionEnabled: true,
        retractionLength: 6.0,
        retractionSpeed: 25.0,
        retractionRestartExtra: 0.2,
        zHop: 0.2,
        minTravelForRetraction: 1.5,
        coolingEnabled: true,
        minFanSpeed: 30,
        maxFanSpeed: 50,
        bridgeFanSpeed: 70,
        disableFanFirstLayers: 3,
        fanBelowLayerTime: 60,
        slowdownBelowLayerTime: 10,
        minPrintSpeed: 10.0
    )

    static let abs = MaterialProfile(
        name: "ABS",
        filamentDiameter: 1.75,
        firstLayerTemp: 250,
        otherLayersTemp: 245,
        firstLayerBedTemp: 105,
        otherLayersBedTemp: 100,
        extrusionMultiplier: 1.0,
        retractionEnabled: true,
        retractionLength: 4.0,
        retractionSpeed: 45.0,
        retractionRestartExtra: 0.0,
        zHop: 0.5,
        minTravelForRetraction: 1.0,
        coolingEnabled: false,
        minFanSpeed: 0,
        maxFanSpeed: 0,
        bridgeFanSpeed: 25,
        disableFanFirstLayers: 3,
        fanBelowLayerTime: 15,
        slowdownBelowLayerTime: 15,
        minPrintSpeed: 10.0
    )

    static let tpu = MaterialProfile(
        name: "TPU",
        filamentDiameter: 1.75,
        firstLayerTemp: 230,
        otherLayersTemp: 225,
        firstLayerBedTemp: 30,
        otherLayersBedTemp: 25,
        extrusionMultiplier: 1.0,
        retractionEnabled: false,
        retractionLength: 0.0,
        retractionSpeed: 25.0,
        retractionRestartExtra: 0.0,
        zHop: 0.0,
        minTravelForRetraction: 1.0,
        coolingEnabled: true,
        minFanSpeed: 50,
        maxFanSpeed: 100,
        bridgeFanSpeed: 100,
        disableFanFirstLayers: 2,
        fanBelowLayerTime: 60,
        slowdownBelowLayerTime: 5,
        minPrintSpeed: 5.0
    )

    // eSUN PLA-LW (foaming lightweight PLA). Sources: eSUN's notes (210–270 °C foaming
    // range, ~45% flow at 270 °C, retraction mostly ineffective, bed 45–55 °C) and
    // 3DLabPrint's thin-wall FAQ (part fan off, ~0.8 mm direct-drive retraction at
    // 15–20 mm/s, 0.05–0.2 mm restart extra). 240 °C on every layer keeps the foaming —
    // and so the 60% multiplier — consistent from the first layer up. Stays under 250 °C
    // because the stock Ender 3 S1 hotend is PTFE-lined.
    static let esunPLALW = MaterialProfile(
        name: "eSUN PLA-LW (Lightweight)",
        filamentDiameter: 1.75,
        firstLayerTemp: 240,
        otherLayersTemp: 240,
        firstLayerBedTemp: 55,
        otherLayersBedTemp: 50,
        extrusionMultiplier: 0.6,
        retractionEnabled: true,
        retractionLength: 0.8,
        retractionSpeed: 20.0,
        retractionRestartExtra: 0.1,
        zHop: 0.0,
        minTravelForRetraction: 2.0,
        coolingEnabled: true,
        minFanSpeed: 0,
        maxFanSpeed: 30,
        bridgeFanSpeed: 50,
        disableFanFirstLayers: 3,
        fanBelowLayerTime: 15,
        slowdownBelowLayerTime: 5,
        minPrintSpeed: 10.0
    )

    static let all: [MaterialProfile] = [pla, petg, abs, tpu, esunPLALW]
}
