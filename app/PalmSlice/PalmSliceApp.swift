import SwiftUI

@main
struct PalmSliceApp: App {
    @StateObject private var profileStore = ProfileStore()
    @StateObject private var sliceProfileStore = SliceProfileStore()
    @StateObject private var materialProfileStore = MaterialProfileStore()

@State private var showSplash = true
    @State private var showEULA = false

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(profileStore)
                    .environmentObject(sliceProfileStore)
                    .environmentObject(materialProfileStore)
                    .task {
                        // Load PrusaSlicer's vendor presets off the main thread
                        // while the splash shows (~1.5 s); slicing needs them.
                        Task.detached(priority: .userInitiated) { PresetLibrary.load() }
                        profileStore.load()
                        sliceProfileStore.load()
                        materialProfileStore.load()
                    }
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
                try? await Task.sleep(for: .seconds(2))
                withAnimation(.easeOut(duration: 0.3)) { showSplash = false }
                if !UserDefaults.standard.bool(forKey: "hasAcceptedEULA") {
                    showEULA = true
                }
            }
        }
    }
}

