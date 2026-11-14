import SwiftUI

@main
struct PalmSliceApp: App {
    @StateObject private var profileStore = ProfileStore()
    @StateObject private var sliceProfileStore = SliceProfileStore()
    @StateObject private var materialProfileStore = MaterialProfileStore()

    init() {
        // Before any scene: a file opened with the app is copied into tmp.
        TempFiles.clearAtLaunch()
    }

    @State private var showSplash = true
    @State private var showEULA = false

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .modifier(StorageErrorAlert())
                    .environmentObject(profileStore)
                    .environmentObject(sliceProfileStore)
                    .environmentObject(materialProfileStore)
                    .fullScreenCover(isPresented: $showEULA) {
                        EULAView {
                            UserDefaults.standard.set(true, forKey: "hasAcceptedEULA")
                            showEULA = false
                        }
                    }
                if showSplash {
                    SplashView()
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .task {
                // Load OrcaSlicer's vendor presets off the main thread while
                // the splash shows (~1.5 s). Built-in printers are generated
                // from them, so the stores load afterwards; the splash stays
                // until they have (and at least a second, so it doesn't flash).
                let shown = ContinuousClock.now
                await Task.detached(priority: .userInitiated) { PresetLibrary.load() }.value
                profileStore.load()
                let printer = profileStore.selectedProfile?.systemPreset
                sliceProfileStore.load(printerPreset: printer)
                materialProfileStore.load(printerPreset: printer)
                try? await Task.sleep(until: shown + .seconds(1), clock: .continuous)
                withAnimation(.easeOut(duration: 0.3)) { showSplash = false }
                if !UserDefaults.standard.bool(forKey: "hasAcceptedEULA") {
                    showEULA = true
                }
            }
        }
    }
}

