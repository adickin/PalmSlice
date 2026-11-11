import SwiftUI
import UIKit
import UniformTypeIdentifiers
import SceneKit

// MARK: - State

enum SliceState {
    case idle
    case slicing(phase: String, progress: Double)
    case done(gcodeURL: URL, printTime: String?, filamentG: String?, stats: SliceStats?)
    case failed(message: String)
}

// Choice offered when slicer_check_slice_config flags wall/top/bottom
// settings that are too aggressive for the loaded model's geometry.
private enum SliceConfigDecision {
    case autoAdjust
    case sliceAnyway
    case cancel
}

// MARK: - Progress relay
// Boxes a Swift closure so it can be passed as a C void* context pointer.

private final class ProgressRelay: @unchecked Sendable {
    var handler: (Float) -> Void = { _ in }
}

// MARK: - ContentView

struct ContentView: View {
    @EnvironmentObject var profileStore: ProfileStore
    @EnvironmentObject var sliceProfileStore: SliceProfileStore
    @EnvironmentObject var materialProfileStore: MaterialProfileStore

    @State private var state: SliceState = .idle
    /// Set when the user taps Export; drives the export sheet.
    @State private var exportRequest: ExportRequest? = nil
    @State private var showFilePicker = false
    @State private var showErrorAlert = false
    @State private var showProfilePicker = false
    @State private var showSliceProfilePicker = false
    /// Tool whose material picker is open. An item, not a flag plus a tool
    /// number: with `isPresented` the first sheet showed the previous tool.
    @State private var materialPickerTool: MaterialPickerTool? = nil
    @State private var showMixes = false
    /// Paint mode on the selected model.
    @State private var paintController: PaintController? = nil
    @State private var showNoProfileAlert = false
    @State private var showNoSliceProfileAlert = false
    #if DEBUG
    @State private var debugScreen: DebugScreen? = nil
    #endif
    @State private var showAbout = false
    @State private var showSliceStats = false
    /// Part whose settings-from-file sheet is open.
    @State private var fileSettingsModelID: UUID? = nil
    /// Model whose Parts & Tools sheet is open.
    @State private var partsModelID: UUID? = nil
    /// Model whose Part Settings sheet is open.
    @State private var partSettingsModelID: UUID? = nil
    /// Auto-orient is working out the selected model's rotation.
    @State private var isOrienting = false
    /// Placing copies (Duplicate / Fill Plate) with the arranger.
    @State private var isArranging = false
    @State private var arrangeMessage: String? = nil
    /// Volume shown in the 3D view from the Parts & Tools sheet.
    @State private var shownPart: STLSceneView.ShownPart? = nil
    /// Wipe tower position dragged on the bed this session (printer mm); nil = the default.
    @State private var wipeTowerPosition: SIMD2<Double>? = nil
    /// The last slice's wipe tower depth (mm); nil = estimate it.
    @State private var slicedTowerDepth: Double? = nil
    /// Settings of the PrusaSlicer print preset the slice profile is layered on.
    @State private var basePrintSettings: [String: String] = [:]
    /// A just-imported file's print settings, offered for use (see offerFileProfiles).
    @State private var fileProfilesOffer: FileProfilesOffer? = nil
    @State private var showIntersectingAlert = false
    @State private var showUnitScaleAlert = false
    @State private var unitScaleAlertModelID: UUID? = nil
    @State private var unitScaleAlertScale: Float = 1000
    @State private var unitScaleAlertOriginalSizeMM: SIMD3<Float> = .zero
    @State private var showConfigWarningAlert = false
    /// The last slice's colliding paths (an object and the wipe tower, or two objects).
    @State private var pathConflictMessage: String?
    @State private var configWarningCheck: SlicerSliceConfigCheck?
    @State private var configWarningOriginal: (walls: Int, top: Int, bottom: Int)?
    @State private var configDecisionContinuation: CheckedContinuation<SliceConfigDecision, Never>?
    @State private var isPanelExpanded = true

    // iPad (regular width) layout: collapsible side columns around the viewer.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showSidebar = true
    @State private var showInspector = true
    @State private var isFloatingColumns = false

    // Multi-model state
    @State private var models: [PlacedModel] = []
    @State private var selectedModelID: UUID? = nil

    // Gizmo + transform panel state
    @State private var showTransformPanel = false
    @State private var gizmoMode: GizmoMode = .translate
    @State private var lockScale = true

    // Camera — persists so toggling layer preview doesn't reset it
    @State private var cameraHasBeenSet = false

    // Export filename
    @State private var exportFileName: String = ""

    // Viewer controls
    @State private var showWireframe: Bool = false
    @State private var viewerColorMode: ViewerColorMode = .solid
    /// The session's ColorMix mixes (from imported files and the mix editor).
    @State private var mixes: [ToolMix] = []
    @State private var isParsingSTL = false

    // Layer preview
    @State private var showLayerPreview: Bool = false
    @State private var parsedLayers: [GCodeLayer] = []
    @State private var previewColouring: PreviewColouring = .tool
    /// The sliced G-code uses more than one tool (offer colouring by tool).
    @State private var previewUsesSeveralTools = false
    @State private var currentLayerIndex: Int = 0

    /// Retained while a slice is in progress; lets the cancel button reach slicer_cancel().
    @State private var activeHandle: SlicerHandle? = nil

    /// Debounce token for the precise (mesh-BVH) collision check. Each call
    /// to updateIntersections cancels the prior task; the precise check only
    /// runs once placement has been still for ~750ms.
    @State private var preciseCheckTask: Task<Void, Never>? = nil

    // MARK: Helpers

    private var selectedModel: PlacedModel? {
        guard let id = selectedModelID else { return nil }
        return models.first { $0.id == id }
    }
    private var selectedIndex: Int? {
        guard let id = selectedModelID else { return nil }
        return models.firstIndex { $0.id == id }
    }
    private var isBusy: Bool {
        if case .slicing = state { return true }
        return false
    }
    private var hasModels: Bool { !models.isEmpty }
    private var anyIntersecting: Bool { models.contains { $0.isIntersecting } }

    private var bedXVal: Double { profileStore.selectedProfile?.bedX ?? 220 }
    private var bedYVal: Double { profileStore.selectedProfile?.bedY ?? 220 }
    private var bedZVal: Double { profileStore.selectedProfile?.bedZ ?? 250 }

    // Transform binding for the selected model — used by the transform panel and bar.
    private var selectedTransformBinding: Binding<ModelTransform> {
        Binding(
            get: { self.selectedModel?.transform ?? .identity },
            set: { newVal in
                if let idx = self.selectedIndex {
                    self.models[idx].transform = newVal
                    self.updateIntersections()
                }
            }
        )
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularLayout
            } else {
                compactLayout
            }
        }
        .task(id: "\(profileStore.selectedProfileId?.uuidString ?? "")|\(sliceProfileStore.selectedProfileId?.uuidString ?? "")") {
            // The stores load after the vendor presets; don't start that load here.
            guard let printer = profileStore.selectedProfile, let slice = sliceProfileStore.selectedProfile else { return }
            basePrintSettings = await Task.detached(priority: .utility) {
                SliceSetup.base(printer: printer, material: nil, slice: slice)
                    .flatMap { PresetLibrary.settings(.print, $0.print) } ?? [:]
            }.value
            wipeTowerPosition = nil
            slicedTowerDepth = nil
        }
        .onChange(of: plateTools) { _ in slicedTowerDepth = nil }
        // Qualities and filaments follow the printer (OrcaSlicer's per-printer lists).
        .onChange(of: profileStore.selectedProfile?.systemPreset) { preset in
            sliceProfileStore.setPrinter(preset)
            materialProfileStore.setPrinter(preset)
        }
        .onChange(of: viewerColorMode) { _ in
            let mode = viewerColorMode
            for model in models {
                let url     = model.url
                let modelID = model.id
                let parts   = model.partFacetCounts
                Task.detached(priority: .userInitiated) {
                    let geo = try? parseSTL(url: url, colorMode: mode, partFacetCounts: parts)
                    await MainActor.run {
                        if let i = models.firstIndex(where: { $0.id == modelID }) {
                            models[i].geometry = geo
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showFilePicker) {
            DocumentPickerView { url in importModel(from: url) }
        }
        #if DEBUG
        // Simulator scripting: `SIMCTL_CHILD_PALMSLICE_DEBUG_STL=/path/a.stl xcrun simctl launch …`
        .task {
            // `PALMSLICE_DEBUG_PRINTER=<OrcaSlicer printer preset>` selects (adding if
            // needed) a printer from the vendor presets, e.g. a multi-tool one.
            if let preset = ProcessInfo.processInfo.environment["PALMSLICE_DEBUG_PRINTER"] {
                if let existing = profileStore.profiles.first(where: { $0.systemPreset == preset }) {
                    profileStore.select(id: existing.id)
                } else if let printer = PrinterProfile(systemPreset: preset) {
                    profileStore.add(printer)
                    profileStore.select(id: printer.id)
                }
            }
            if let path = ProcessInfo.processInfo.environment["PALMSLICE_DEBUG_STL"], models.isEmpty {
                importModel(from: URL(fileURLWithPath: path))
            }
        }
        // `SIMCTL_CHILD_PALMSLICE_DEBUG_SCREEN=<name>` opens a screen at launch
        // for screenshots (see DebugScreen).
        .sheet(item: $debugScreen) { $0.view }
        .task {
            try? await Task.sleep(for: .seconds(3))   // after the splash and store loads
            // `PALMSLICE_DEBUG_TOOL_COLOURS=#FF0000,#00FF00,…` loads a copy of the
            // selected material in that colour into each tool.
            if let colours = ProcessInfo.processInfo.environment["PALMSLICE_DEBUG_TOOL_COLOURS"],
               let base = materialProfileStore.selectedProfile {
                for (i, colour) in colours.split(separator: ",").enumerated() {
                    let name = "\(base.name) T\(i + 1)"
                    var m = materialProfileStore.profiles.first { $0.name == name } ?? base
                    if m.id == base.id { m.id = UUID(); m.name = name; materialProfileStore.add(m) }
                    m.colour = String(colour)
                    materialProfileStore.update(m)
                    materialProfileStore.setMaterial(m.id, forTool: i + 1)
                }
            }
            // `PALMSLICE_DEBUG_FILL=1` fills the plate with the first model.
            if ProcessInfo.processInfo.environment["PALMSLICE_DEBUG_FILL"] == "1" {
                while models.isEmpty || models.contains(where: { $0.geometry == nil }) {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                addCopies(of: models[0].id, count: nil)
                while isArranging { try? await Task.sleep(for: .milliseconds(200)) }
            }
            // `PALMSLICE_DEBUG_SLICE=1` slices once the models have loaded.
            if ProcessInfo.processInfo.environment["PALMSLICE_DEBUG_SLICE"] == "1" {
                while models.isEmpty || models.contains(where: { $0.geometry == nil })
                        || profileStore.selectedProfile == nil {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                triggerSlice()
            }
            let screen = ProcessInfo.processInfo.environment["PALMSLICE_DEBUG_SCREEN"]
            if screen == "sliceStats" {
                while sliceStats == nil { try? await Task.sleep(for: .milliseconds(500)) }
                showSliceStats = true
            } else if screen == "fileSettings" {
                fileSettingsModelID = models.first?.id   // with PALMSLICE_DEBUG_STL set to a 3MF
            } else if screen == "paint" {
                selectedModelID = models.last?.id
                startPainting()
            } else if screen == "partSettings" {
                partSettingsModelID = models.first?.id
                models.indices.first.map { models[$0].partSettings.objectSettings = ["wall_loops": "4"] }
                models.indices.first.map { models[$0].partSettings.ranges = [.init(minZ: 0, maxZ: 5, settings: ["sparse_infill_density": "100%"])] }
            } else if screen == "parts" {
                partsModelID = models.first?.id
                shownPart = models.first.flatMap { m in
                    m.parts.firstIndex { $0.kind == .modifier && $0.extruder == 0 }.map { .init(model: m.id, part: $0) }
                }
            } else {
                debugScreen = screen.flatMap(DebugScreen.init)
            }
        }
        #endif
        .sheet(item: $exportRequest) { req in
            ExportSheetView(request: req)
        }
        .sheet(isPresented: $showProfilePicker) { ProfilePickerView() }
        .sheet(isPresented: $showSliceProfilePicker) { SliceProfilePickerView() }
        .sheet(isPresented: $showMixes) {
            MixesView(mixes: $mixes, palette: toolPalette, usedTools: plateTools)
        }
        .sheet(item: $materialPickerTool) {
            MaterialProfilePickerView(tool: $0.tool, toolCount: toolCount)
        }
        .sheet(isPresented: $showAbout) { AboutView() }
        .sheet(isPresented: $showSliceStats) {
            if let stats = sliceStats { SliceStatsView(stats: stats) }
        }
        .alert("Use This File's Print Settings?",
               isPresented: Binding(get: { fileProfilesOffer != nil }, set: { if !$0 { fileProfilesOffer = nil } }),
               presenting: fileProfilesOffer) { offer in
            Button("Use File's Settings") {
                FileProfiles.apply(offer.project, fallback: offer.fileName,
                                   slices: sliceProfileStore, materials: materialProfileStore)
            }
            Button("Keep My Profiles", role: .cancel) {}
        } message: { offer in
            let n = FileProfiles.names(offer.project, fallback: offer.fileName)
            Text("\(offer.fileName) was set up with the slice profile “\(n.print)” and material “\(n.filament)”. Use them? Your printer stays the same, and the part's own settings from the file are used either way.")
        }
        .sheet(isPresented: Binding(get: { fileSettingsModelID != nil },
                                    set: { if !$0 { fileSettingsModelID = nil } })) {
            if let id = fileSettingsModelID, let binding = modelBinding(id: id) {
                ModelFileSettingsView(model: binding)
            }
        }
        .sheet(isPresented: Binding(get: { partSettingsModelID != nil },
                                    set: { if !$0 { partSettingsModelID = nil } })) {
            if let id = partSettingsModelID, let binding = modelBinding(id: id) {
                PartSettingsView(model: binding,
                                 baseSettings: basePrintSettings.merging(
                                    sliceProfileStore.selectedProfile?.slicerSettings() ?? [:]) { _, own in own })
            }
        }
        .sheet(isPresented: Binding(get: { partsModelID != nil },
                                    set: { if !$0 { partsModelID = nil } })) {
            if let id = partsModelID, let binding = modelBinding(id: id) {
                ModelPartsView(model: binding, palette: toolPalette,
                               shownPart: Binding(get: { shownPart?.model == id ? shownPart?.part : nil },
                                                  set: { shownPart = $0.map { .init(model: id, part: $0) } }))
                    .presentationDetents([.medium, .large])
                    .interactiveBehindMediumSheet()
            }
        }
        .sheet(isPresented: $showTransformPanel) {
            if let info = selectedModel?.meshInfo {
                TransformPanelView(
                    transform: selectedTransformBinding,
                    meshInfo: info,
                    bedX: bedXVal,
                    bedY: bedYVal,
                    bedZ: bedZVal,
                    lockScale: $lockScale
                )
            } else {
                TransformPanelView(
                    transform: selectedTransformBinding,
                    meshInfo: nil,
                    bedX: bedXVal,
                    bedY: bedYVal,
                    bedZ: bedZVal,
                    lockScale: $lockScale
                )
            }
        }
        .alert("Slicing Error", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            if case .failed(let msg) = state { Text(msg) }
        }
        .alert("No Printer Selected", isPresented: $showNoProfileAlert) {
            Button("Choose Printer") { showProfilePicker = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Please select a printer profile before slicing.")
        }
        .alert("No Slice Profile Selected", isPresented: $showNoSliceProfileAlert) {
            Button("Choose Profile") { showSliceProfilePicker = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Please select a slice profile before slicing.")
        }
        .alert("Models Overlapping", isPresented: $showIntersectingAlert) {
            Button("Slice Anyway", role: .destructive) { startSlice() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Some models are intersecting. Slicing may produce unexpected results. Continue?")
        }
        .alert("Model Seems Very Small", isPresented: $showUnitScaleAlert) {
            Button("Scale \u{00d7}\(Int(unitScaleAlertScale))") {
                if let id = unitScaleAlertModelID, let idx = models.firstIndex(where: { $0.id == id }) {
                    models[idx].transform.scale = SIMD3(repeating: unitScaleAlertScale)
                }
            }
            Button("Keep As Is", role: .cancel) {}
        } message: {
            let s = unitScaleAlertOriginalSizeMM
            Text("""
            This model is \(String(format: "%.3f", s.x)) \u{00d7} \(String(format: "%.3f", s.y)) \u{00d7} \(String(format: "%.3f", s.z)) mm — \
            too small to print. STL and OBJ files don't store units, so this is likely modeled in meters, not millimeters. \
            Scale \u{00d7}\(Int(unitScaleAlertScale)) to fix it?
            """)
        }
        .alert("No Room on the Plate", isPresented: Binding(get: { arrangeMessage != nil },
                                                            set: { if !$0 { arrangeMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(arrangeMessage ?? "")
        }
        .alert("Paths Collide", isPresented: Binding(get: { pathConflictMessage != nil },
                                                     set: { if !$0 { pathConflictMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pathConflictMessage ?? "")
        }
        .alert("Settings May Not Print Cleanly", isPresented: $showConfigWarningAlert) {
            Button("Auto-Adjust") {
                configDecisionContinuation?.resume(returning: .autoAdjust)
                configDecisionContinuation = nil
            }
            Button("Slice Anyway", role: .destructive) {
                configDecisionContinuation?.resume(returning: .sliceAnyway)
                configDecisionContinuation = nil
            }
            Button("Cancel", role: .cancel) {
                configDecisionContinuation?.resume(returning: .cancel)
                configDecisionContinuation = nil
            }
        } message: {
            if let check = configWarningCheck, let orig = configWarningOriginal {
                Text("""
                Wall count (\(orig.walls)) and/or top/bottom layers (\(orig.top)/\(orig.bottom)) are more than this \
                model's size and your nozzle diameter can support — this tends to cause overlapping or missing \
                perimeters instead of a clean print.

                Suggested: \(check.suggested_wall_count) walls, \(check.suggested_top_layers) top / \(check.suggested_bottom_layers) bottom layers.
                """)
            }
        }
    }

    // MARK: - Phone layout

    private var compactLayout: some View {
        ZStack(alignment: .bottom) {
            sceneViewer
                .ignoresSafeArea()

            viewerControlsOverlay

            if showLayerPreview && !parsedLayers.isEmpty {
                layerSliderView
            }

            // Sits just above the collapsed panel's bottom-right corner; the
            // expanded panel (full width, much taller) naturally draws over it
            // since it's added to the ZStack afterward.
            HStack {
                Spacer()
                infoButton
            }
            .padding(.trailing, 16)
            .padding(.bottom, 140)

            bottomPanel
        }
        .ignoresSafeArea(edges: .top)
    }

    // MARK: - iPad layout
    //
    // Regular width (iPad full screen, or the larger side of Split View): models +
    // transform in a left sidebar, the viewer in the middle, and output / profiles /
    // slice actions in a right inspector. Same state and actions as the phone layout;
    // in Slide Over or narrow Split View the size class drops to compact and the phone
    // layout takes over.

    /// Below this width (iPad portrait, wide Split View) the side columns float over
    /// the viewer one at a time instead of docking beside it.
    private static let dockedColumnsMinWidth: CGFloat = 1000

    private static let sidebarWidth: CGFloat = 320
    private static let inspectorWidth: CGFloat = 320

    /// The 3D view always runs edge to edge; the columns sit on top of it as
    /// translucent material so the scene shows through instead of hard black/grey walls.
    private var regularLayout: some View {
        GeometryReader { geo in
            let docked = geo.size.width >= Self.dockedColumnsMinWidth
            ZStack {
                sceneViewer
                    .ignoresSafeArea()
                    .onDrop(of: [UTType.data], isTargeted: nil, perform: importDroppedModels)

                // In docked mode keep the overlay buttons beside the columns, not under them.
                iPadViewerOverlay
                    .padding(.leading, docked && showSidebar ? Self.sidebarWidth : 0)
                    .padding(.trailing, docked && showInspector ? Self.inspectorWidth : 0)

                HStack(spacing: 0) {
                    if showSidebar {
                        Group {
                            if docked { dockedColumn(iPadSidebar, width: Self.sidebarWidth) }
                            else { floatingColumn(iPadSidebar) }
                        }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    Spacer(minLength: 0)
                    if showInspector {
                        Group {
                            if docked { dockedColumn(iPadInspector, width: Self.inspectorWidth) }
                            else { floatingColumn(iPadInspector) }
                        }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, docked ? 0 : 88)   // floating: keep the overlay buttons uncovered
            }
            .onAppear { isFloatingColumns = !docked; enforceSingleFloatingColumn(preferInspector: true) }
            .onChange(of: docked) { d in
                isFloatingColumns = !d
                if d {
                    // Rotating to landscape: there's room again for whatever portrait hid.
                    showSidebar = true
                    showInspector = true
                } else {
                    enforceSingleFloatingColumn(preferInspector: true)
                }
            }
        }
    }

    /// Full-height translucent column pinned to a screen edge (wide windows).
    private func dockedColumn<Content: View>(_ content: Content, width: CGFloat) -> some View {
        content
            .scrollContentBackground(.hidden)
            .frame(width: width)
            .background(.ultraThinMaterial, ignoresSafeAreaEdges: .all)
            // The viewer is always dark; light-mode material over it reads as muddy grey.
            .environment(\.colorScheme, .dark)
    }

    private func floatingColumn<Content: View>(_ content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .frame(width: 340)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 16, y: 4)
            .environment(\.colorScheme, .dark)
            .padding(.vertical, 12)
    }

    /// Floating columns overlap each other in portrait, so only one is open at a time.
    private func enforceSingleFloatingColumn(preferInspector: Bool) {
        guard isFloatingColumns, showSidebar, showInspector else { return }
        if preferInspector { showSidebar = false } else { showInspector = false }
    }

    private func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.25)) {
            showSidebar.toggle()
            enforceSingleFloatingColumn(preferInspector: false)
        }
    }

    private func toggleInspector() {
        withAnimation(.easeInOut(duration: 0.25)) {
            showInspector.toggle()
            enforceSingleFloatingColumn(preferInspector: true)
        }
    }

    private var iPadViewerOverlay: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                overlayButton(icon: "sidebar.left", label: "Models", active: showSidebar) { toggleSidebar() }
                Spacer()
                VStack(spacing: 10) {
                    overlayButton(icon: "sidebar.right", label: "Slice", active: showInspector) { toggleInspector() }
                    Divider().frame(width: 36).padding(.vertical, 2)
                    viewerToolButtons(includeValues: false)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Spacer()

            if !hasModels && !isParsingSTL {
                emptyViewerHint
                Spacer()
            }

            if showLayerPreview && !parsedLayers.isEmpty {
                layerSliderCard
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
            }
        }
    }

    private var emptyViewerHint: some View {
        VStack(spacing: 12) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Drop a model here, or")
                .foregroundStyle(.secondary)
            Button { showFilePicker = true } label: {
                Label("Add Model", systemImage: "plus.app")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var iPadSidebar: some View {
        List {
            Section {
                ForEach(models) { model in
                    sidebarModelRow(model)
                }
                Button { showFilePicker = true } label: {
                    Label("Add Model…", systemImage: "plus")
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(isBusy)
            } header: {
                Text("Models")
            } footer: {
                if anyIntersecting {
                    Text("Models highlighted in red overlap each other or extend past the bed.")
                }
            }

            if showLayerPreview {
                Section {
                    Button { showLayerPreview = false } label: {
                        Label("Back to Model View to Edit", systemImage: "cube.transparent")
                    }
                }
            } else if let model = selectedModel {
                TransformPanelView(
                    transform: selectedTransformBinding,
                    meshInfo: model.meshInfo,
                    bedX: bedXVal,
                    bedY: bedYVal,
                    bedZ: bedZVal,
                    lockScale: $lockScale,
                    embedded: true
                )
                .disabled(isBusy)
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func sidebarModelRow(_ model: PlacedModel) -> some View {
        let isSelected = model.id == selectedModelID
        Button { selectedModelID = model.id } label: {
            HStack(spacing: 10) {
                Image(systemName: model.isIntersecting ? "exclamationmark.triangle.fill" : "cube.fill")
                    .foregroundStyle(model.isIntersecting ? Color.red : Color.accentColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                        .lineLimit(1)
                        .foregroundStyle(model.isIntersecting ? Color.red : Color.primary)
                    if let info = model.meshInfo {
                        let s = model.transform.scale
                        Text(String(format: "%.1f \u{00d7} %.1f \u{00d7} %.1f mm",
                                    info.sizeMMX * s.x, info.sizeMMZ * s.y, info.sizeMMY * s.z))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.isPainted {
                    Image(systemName: "paintbrush.pointed.fill").foregroundStyle(.secondary)
                        .accessibilityLabel("Painted")
                }
                if showsToolColours || !model.parts.isEmpty {
                    Button { partsModelID = model.id } label: {
                        ToolBadge(tool: model.extruder, colour: toolPalette.colour(model.extruder))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Parts and tools")
                }
                if model.fileSettings != nil || model.projectSettings != nil {
                    Button { fileSettingsModelID = model.id } label: { FileSettingsBadge(model: model) }
                        .buttonStyle(.borderless)
                }
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
        }
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.15) : nil)
        .disabled(isBusy)
        .swipeActions {
            Button(role: .destructive) { removeModel(id: model.id) } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .contextMenu {
            Button { partsModelID = model.id } label: {
                Label("Parts & Tools…", systemImage: "square.stack.3d.up")
            }
            if model.fileSettings != nil || model.projectSettings != nil {
                Button { fileSettingsModelID = model.id } label: {
                    Label("Settings from File…", systemImage: "slider.horizontal.3")
                }
            }
            Button { addCopies(of: model.id, count: 1) } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Button { addCopies(of: model.id, count: nil) } label: {
                Label("Fill Plate", systemImage: "square.grid.3x3")
            }
            Button(role: .destructive) { removeModel(id: model.id) } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    /// After importing a 3MF that stores PrusaSlicer print settings, offer to
    /// use its slice profile and material — unless they're already selected.
    private func offerFileProfiles(_ project: [String: String]?, fileName: String) {
        guard let project, project["print_settings_id"] != nil || project["filament_settings_id"] != nil,
              !FileProfiles.alreadySelected(project, fallback: fileName,
                                            slices: sliceProfileStore, materials: materialProfileStore)
        else { return }
        fileProfilesOffer = FileProfilesOffer(fileName: fileName, project: project)
    }

    private func modelBinding(id: UUID) -> Binding<PlacedModel>? {
        guard models.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { models.first { $0.id == id } ?? PlacedModel(id: id, url: URL(fileURLWithPath: "/"), name: "",
                                                                geometry: nil, transform: ModelTransform()) },
            set: { new in
                if let i = models.firstIndex(where: { $0.id == id }) { models[i] = new }
            })
    }

    private var iPadInspector: some View {
        List {
            Section("Output") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(panelModelSummary)
                        .font(.headline)
                    if let sp = sliceProfileStore.selectedProfile {
                        Text(sp.pickerSubtitle)
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("No slice profile selected")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: "doc.badge.gearshape")
                        .foregroundStyle(.secondary)
                    TextField(autoOutputFileName, text: $exportFileName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .disabled(isBusy)
                }
                .font(.subheadline)
            }

            Section("Profiles") {
                profileRows
            }

            Section("Status") {
                HStack(alignment: .top, spacing: 12) {
                    statusIcon
                    Text(statusMessage)
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                }
                if case .slicing(_, let p) = state {
                    ProgressView(value: p).animation(.linear(duration: 0.15), value: p)
                }
                sliceDetailsButton
            }

            Section {
                actionButtons
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                Button { showAbout = true } label: {
                    Label("About & Licenses", systemImage: "info.circle")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func removeModel(id: UUID) {
        models.removeAll { $0.id == id }
        if selectedModelID == id {
            selectedModelID = models.first?.id
        }
        updateIntersections()
    }

    /// Drag-and-drop from Files / other apps onto the viewer. Each provider's file is
    /// only valid inside its load callback, so it's staged to temp before importModel
    /// (which makes its own copy) runs on the main actor.
    private func importDroppedModels(_ providers: [NSItemProvider]) -> Bool {
        let modelProviders = providers.filter { provider in
            guard let name = provider.suggestedName else { return true }
            let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
            return ext.isEmpty || supportedModelExtensions.contains(ext)
        }
        guard !modelProviders.isEmpty, !isBusy else { return false }
        for provider in modelProviders {
            let typeID = provider.registeredTypeIdentifiers.first ?? UTType.data.identifier
            provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, _ in
                guard let url else { return }
                var name = provider.suggestedName ?? url.lastPathComponent
                if URL(fileURLWithPath: name).pathExtension.isEmpty { name += ".stl" }
                guard supportedModelExtensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased()) else { return }
                let stagingDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("drop-" + UUID().uuidString, isDirectory: true)
                let staged = stagingDir.appendingPathComponent(name)
                do {
                    try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: staged)
                } catch { return }
                DispatchQueue.main.async {
                    importModel(from: staged)
                    try? FileManager.default.removeItem(at: stagingDir)
                }
            }
        }
        return true
    }

    // MARK: - 3D viewer (shared by both layouts)

    @ViewBuilder
    private var sceneViewer: some View {
        if showLayerPreview && !parsedLayers.isEmpty {
            GCodeSceneView(
                layers: parsedLayers,
                currentLayerIndex: currentLayerIndex,
                bedX: bedXVal,
                bedY: bedYVal,
                colouring: previewUsesSeveralTools ? previewColouring : .feature,
                toolColours: toolPalette.physical
            )
        } else {
            STLSceneView(
                models: models,
                selectedModelID: selectedModelID,
                bedX: bedXVal,
                bedY: bedYVal,
                bedZ: bedZVal,
                showWireframe: showWireframe,
                gizmoMode: gizmoMode,
                lockScale: lockScale,
                didSetCamera: cameraHasBeenSet,
                onTransformChange: { id, newTransform in
                    if let idx = models.firstIndex(where: { $0.id == id }) {
                        models[idx].transform = newTransform
                    }
                },
                onSelectionChange: { id in
                    selectedModelID = id
                },
                onDragEnded: {
                    updateIntersections()
                },
                onCameraSet: {
                    cameraHasBeenSet = true
                },
                onPencilAction: { cycleGizmoMode() },
                palette: showsToolColours ? toolPalette : nil,
                shownPart: shownPart,
                wipeTower: wipeTower,
                bedCentreMM: bedCentreMM,
                onWipeTowerMove: { wipeTowerPosition = $0 },
                paintController: paintController
            )
            .overlay(alignment: .bottom) {
                // The phone layout shows the paint controls where the transform bar goes,
                // clear of the slide-up panel.
                if horizontalSizeClass == .regular, let controller = paintController {
                    PaintToolbar(controller: controller, palette: toolPalette, colourAvailable: showsToolColours,
                                 supportsOff: !(sliceProfileStore.selectedProfile?.generateSupport ?? false)) { finishPainting() }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                }
            }
            .overlay {
                if isParsingSTL {
                    Color(.systemGray6).opacity(0.7)
                        .overlay { ProgressView("Loading…") }
                }
            }
        }
    }

    /// Apple Pencil double-tap / squeeze: Move → Rotate → Scale → Move.
    private func cycleGizmoMode() {
        guard !showLayerPreview, selectedModelID != nil else { return }
        gizmoMode = switch gizmoMode {
        case .translate: .rotate
        case .rotate:    .scale
        case .scale:     .translate
        }
    }

    // MARK: - Viewer controls overlay

    private var viewerControlsOverlay: some View {
        // ZStack lets left and right columns each anchor independently from the
        // top so the model list doesn't push the gizmo buttons down.
        ZStack(alignment: .top) {
            // LEFT column: model list, then transform bar spanning to gizmo column
            VStack(alignment: .leading, spacing: 8) {
                if !showLayerPreview {
                    ModelListView(
                        models: $models,
                        selectedModelID: $selectedModelID,
                        onAdd: { showFilePicker = true },
                        disabled: isBusy,
                        onModelsChanged: { updateIntersections() },
                        onShowFileSettings: { fileSettingsModelID = $0 },
                        onShowParts: { partsModelID = $0 },
                        onShowPartSettings: { partSettingsModelID = $0 },
                        onDuplicate: { addCopies(of: $0, count: 1) },
                        onFillPlate: { addCopies(of: $0, count: nil) },
                        palette: showsToolColours ? toolPalette : nil
                    )
                }
                if let controller = paintController {
                    PaintToolbar(controller: controller, palette: toolPalette, colourAvailable: showsToolColours,
                                 supportsOff: !(sliceProfileStore.selectedProfile?.generateSupport ?? false)) { finishPainting() }
                        .padding(.leading, 16)
                        .padding(.trailing, 72)
                } else if !showLayerPreview && selectedModelID != nil && selectedModel != nil {
                    transformBarContent
                        .padding(.leading, 16)
                        .padding(.trailing, 72)
                }
                Spacer()
            }
            .padding(.top, 60)
            .frame(maxWidth: .infinity, alignment: .leading)

            // RIGHT column: gizmo & viewer buttons
            VStack(alignment: .trailing, spacing: 8) {
                viewerToolButtons(includeValues: true)
                    .padding(.trailing, 16)

                Spacer()
            }
            .padding(.top, 60)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// Wireframe / colour mode / gizmo mode / layer-preview toggles. The iPad
    /// layout drops "Values" since its sidebar already shows the full transform form.
    @ViewBuilder
    private func viewerToolButtons(includeValues: Bool) -> some View {
        VStack(spacing: 10) {
            if !showLayerPreview && hasModels {
                overlayButton(
                    icon: "square.3.layers.3d",
                    label: showWireframe ? "Wire On" : "Wire Off",
                    active: showWireframe
                ) { showWireframe.toggle() }

                overlayButton(
                    icon: viewerColorMode.icon,
                    label: viewerColorMode.displayName,
                    active: viewerColorMode != .solid
                ) { viewerColorMode = viewerColorMode.next }

                if selectedModelID != nil {
                    if includeValues {
                        overlayButton(
                            icon: "slider.vertical.3",
                            label: "Values",
                            active: !(selectedModel?.transform.isIdentity ?? true)
                        ) { showTransformPanel = true }
                    }

                    Divider().frame(width: 36).padding(.vertical, 2)
                    overlayButton(icon: "move.3d",   label: "Move",   active: gizmoMode == .translate) { gizmoMode = .translate }
                    overlayButton(icon: "rotate.3d", label: "Rotate", active: gizmoMode == .rotate)    { gizmoMode = .rotate }
                    overlayButton(icon: "scale.3d",  label: "Scale",  active: gizmoMode == .scale)     { gizmoMode = .scale }
                    overlayButton(icon: "slider.horizontal.3", label: "Settings",
                                  active: !(selectedModel?.partSettings.isEmpty ?? true)) {
                        partSettingsModelID = selectedModelID
                    }
                    Divider().frame(width: 36).padding(.vertical, 2)
                    overlayButton(icon: "paintbrush.pointed", label: "Paint", active: paintController != nil) {
                        if paintController == nil { startPainting() } else { finishPainting() }
                    }
                }
            }

            if case .done = state, !parsedLayers.isEmpty {
                overlayButton(
                    icon: showLayerPreview ? "cube.transparent" : "square.3.layers.3d.slash",
                    label: showLayerPreview ? "Layers" : "Model",
                    active: showLayerPreview
                ) { showLayerPreview.toggle() }
            }
        }
    }

    // MARK: - Transform bar

    @ViewBuilder
    private var transformBarContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(gizmoModeTitle)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            if gizmoMode == .scale, let info = selectedModel?.meshInfo {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        axisField("X", color: .red,   binding: scaleXBinding, fmt: "%.3g", width: 54)
                        axisField("Y", color: .green, binding: scaleYBinding, fmt: "%.3g", width: 54)
                        axisField("Z", color: .blue,  binding: scaleZBinding, fmt: "%.3g", width: 54)
                        Text("\u{d7}").font(.caption2).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        axisField("X", color: .red,   binding: sizeMMBinding(base: info.sizeMMX, scale: scaleXBinding), fmt: "%.4g", width: 54)
                        axisField("Y", color: .green, binding: sizeMMBinding(base: info.sizeMMZ, scale: scaleYBinding), fmt: "%.4g", width: 54)
                        axisField("Z", color: .blue,  binding: sizeMMBinding(base: info.sizeMMY, scale: scaleZBinding), fmt: "%.4g", width: 54)
                        Text("mm").font(.caption2).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    }
                }
            } else {
                HStack(spacing: 6) {
                    axisField("X", color: .red,   binding: currentXBinding)
                    axisField("Y", color: .green, binding: currentYBinding)
                    axisField("Z", color: .blue,  binding: currentZBinding)
                    if !currentUnit.isEmpty {
                        Text(currentUnit).font(.caption2).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    }
                }
            }

            switch gizmoMode {
            case .scale:
                HStack(spacing: 6) {
                    Toggle("", isOn: $lockScale)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .scaleEffect(0.75, anchor: .leading)
                        .frame(width: 40)
                    Image(systemName: lockScale ? "lock.fill" : "lock.open")
                        .font(.caption2)
                        .foregroundStyle(lockScale ? Color.accentColor : Color.secondary)
                    Text("Lock aspect ratio")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            case .translate:
                HStack(spacing: 6) {
                    Button("Drop to Bed") { dropToBed() }
                    if let id = selectedModelID {
                        Button("Duplicate") { addCopies(of: id, count: 1) }
                        Button { addCopies(of: id, count: nil) } label: {
                            if isArranging { ProgressView().controlSize(.mini) } else { Text("Fill Plate") }
                        }
                    }
                }
                .disabled(isArranging)
                .buttonStyle(.bordered).controlSize(.mini)
            case .rotate:
                HStack(spacing: 6) {
                    Button { autoOrient() } label: {
                        if isOrienting { ProgressView().controlSize(.mini) } else { Text("Auto-Orient") }
                    }
                    .disabled(isOrienting)
                    Button("Reset") { writeTransform { $0.rotationDeg = .zero } }
                }
                .buttonStyle(.bordered).controlSize(.mini)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func axisField(_ label: String, color: Color, binding: Binding<Float>, fmt: String = "%.2f", width: CGFloat = 42) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            FloatField(value: binding, fmt: fmt)
                .font(.caption.monospacedDigit())
                .frame(width: width)
        }
    }

    /// Binding for a size-in-mm quick field: setting it back-solves the scale factor via the
    /// underlying scale binding (which already applies lock-aspect-ratio propagation).
    private func sizeMMBinding(base: Float, scale: Binding<Float>) -> Binding<Float> {
        Binding(
            get: { base * scale.wrappedValue },
            set: { newSizeMM in
                guard base > 0, newSizeMM > 0 else { return }
                scale.wrappedValue = newSizeMM / base
            }
        )
    }

    @ViewBuilder
    private func dimensionRows(info: STLMeshInfo, transform: ModelTransform) -> some View {
        let w = info.sizeMMX * transform.scale.x
        let h = info.sizeMMZ * transform.scale.y
        let d = info.sizeMMY * transform.scale.z
        VStack(alignment: .leading, spacing: 2) {
            Text("Dimensions").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                dimDot(Color.red,   value: w)
                dimDot(Color.green, value: h)
                dimDot(Color.blue,  value: d)
                Text("mm").font(.caption2).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
        }
    }

    @ViewBuilder
    private func dimDot(_ color: Color, value: Float) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(String(format: "%.2f", value)).font(.caption2.monospacedDigit()).lineLimit(1).fixedSize()
        }
    }

    // MARK: - Transform bar helpers

    private var gizmoModeTitle: String {
        switch gizmoMode { case .translate: "Position"; case .rotate: "Rotation"; case .scale: "Scale" }
    }
    private var currentUnit: String {
        switch gizmoMode { case .translate: "mm"; case .rotate: "°"; case .scale: "" }
    }

    private var currentXBinding: Binding<Float> {
        switch gizmoMode {
        case .translate: Binding(
            get: { self.selectedModel?.transform.positionMM.x ?? 0 },
            set: { v in self.writeTransform { $0.positionMM.x = v } })
        case .rotate: Binding(
            get: { self.selectedModel?.transform.rotationDeg.x ?? 0 },
            set: { v in self.writeTransform { $0.rotationDeg.x = v } })
        case .scale: scaleXBinding
        }
    }
    private var currentYBinding: Binding<Float> {
        switch gizmoMode {
        case .translate: Binding(
            get: { self.selectedModel?.transform.positionMM.y ?? 0 },
            set: { v in self.writeTransform { $0.positionMM.y = v } })
        case .rotate: Binding(
            get: { self.selectedModel?.transform.rotationDeg.y ?? 0 },
            set: { v in self.writeTransform { $0.rotationDeg.y = v } })
        case .scale: scaleYBinding
        }
    }
    private var currentZBinding: Binding<Float> {
        switch gizmoMode {
        case .translate: Binding(
            get: { self.selectedModel?.transform.positionMM.z ?? 0 },
            set: { v in self.writeTransform { $0.positionMM.z = v } })
        case .rotate: Binding(
            get: { self.selectedModel?.transform.rotationDeg.z ?? 0 },
            set: { v in self.writeTransform { $0.rotationDeg.z = v } })
        case .scale: scaleZBinding
        }
    }

    private func writeTransform(_ mutation: (inout ModelTransform) -> Void) {
        guard let idx = selectedIndex else { return }
        mutation(&models[idx].transform)
        updateIntersections()
    }

    /// Runs the cheap OBB intersection pass immediately (instant red feedback)
    /// and schedules a debounced precise mesh-BVH pass for ~750ms after the
    /// last placement change. Call from any transform mutation site.
    private func updateIntersections() {
        checkIntersections(models: &models, bedX: bedXVal, bedY: bedYVal)
        schedulePreciseIntersectionCheck()
    }

    private func schedulePreciseIntersectionCheck() {
        preciseCheckTask?.cancel()
        preciseCheckTask = Task.detached(priority: .userInitiated) {
            do { try await Task.sleep(nanoseconds: 750_000_000) }
            catch { return }                       // cancelled

            let snapshot: [PlacedModel] = await MainActor.run { self.models }
            let bx: Double = await MainActor.run { self.bedXVal }
            let by: Double = await MainActor.run { self.bedYVal }
            if Task.isCancelled { return }

            let intersectingIDs = preciseIntersectionResults(
                models: snapshot, bedX: bx, bedY: by)
            if Task.isCancelled { return }

            await MainActor.run {
                for i in self.models.indices {
                    self.models[i].isIntersecting =
                        intersectingIDs.contains(self.models[i].id)
                }
            }
        }
    }

    private func centerOnBed() {
        writeTransform { $0.positionMM.x = 0; $0.positionMM.y = 0 }
    }

    // MARK: Duplicate / Fill Plate

    /// Adds copies of a model where there's room around the other models and
    /// the wipe tower (PlateArrange): `count` copies, or as many as fit
    /// when nil. A duplicate with no room goes beside the original, off the
    /// plate. Copies share the model's files (painting saves a new file).
    private func addCopies(of id: UUID, count: Int?) {
        guard !isBusy, !isArranging, let printer = profileStore.selectedProfile,
              let source = models.first(where: { $0.id == id }), let info = source.meshInfo else { return }
        let placed = models.compactMap { m in m.meshInfo.map { (m.transform, $0) } }
        let tower = wipeTower.map { PlateArrange.footprint($0, bedCentre: bedCentreMM) }
        let bed = PlateArrange.bed(printer)
        isArranging = true
        Task.detached(priority: .userInitiated) {
            let footprint = source.transform.footprintMM(meshInfo: info)
            var fixed = placed.map { t, i in
                t.footprintMM(meshInfo: i).map { $0 + SIMD2(t.positionMM.x, -t.positionMM.y) }
            }
            if let tower { fixed.append(tower) }
            let wanted = count ?? PlateArrange.maxCopies(of: footprint, bed: bed)
            // A duplicate goes as near the original as it can; a fill packs rows.
            let near = count == nil ? nil : SIMD2(source.transform.positionMM.x, -source.transform.positionMM.y)
            var spots = PlateArrange.place(Array(repeating: footprint, count: wanted), around: fixed, bed: bed,
                                           prefer: near).compactMap { $0 }
            if spots.isEmpty, count != nil {
                let width = (footprint.map(\.x).max() ?? 0) - (footprint.map(\.x).min() ?? 0)
                spots = [SIMD2(source.transform.positionMM.x + width + PlateArrange.spacingMM,
                               -source.transform.positionMM.y)]
            }
            await MainActor.run {
                isArranging = false
                guard !spots.isEmpty else {
                    arrangeMessage = "There's no room for another \(source.name). Make room or scale it down, then try again."
                    return
                }
                for spot in spots {
                    var copy = source
                    copy.id = UUID()
                    copy.transform.positionMM.x = spot.x
                    copy.transform.positionMM.y = -spot.y
                    copy.geometry = source.geometry?.copy() as? SCNGeometry
                    copy.partGeometries = source.partGeometries.compactMapValues { $0.copy() as? SCNGeometry }
                    models.append(copy)
                }
                selectedModelID = models.last?.id
                state = .idle
                showLayerPreview = false
                parsedLayers = []
                updateIntersections()
            }
        }
    }

    private func dropToBed() {
        guard let idx = selectedIndex else { return }
        if let info = selectedModel?.meshInfo {
            models[idx].transform = models[idx].transform.droppedToBed(meshInfo: info)
        } else {
            models[idx].transform.positionMM.z = 0
        }
        updateIntersections()
    }

    /// Turns the selected model the way that needs the least support.
    private func autoOrient() {
        guard let id = selectedModelID, let info = selectedModel?.meshInfo else { return }
        isOrienting = true
        Task.detached(priority: .userInitiated) {
            let rotation = AutoOrient.rotation(for: info)
            await MainActor.run {
                isOrienting = false
                guard let i = models.firstIndex(where: { $0.id == id }) else { return }
                models[i].transform.rotationDeg = rotation
                models[i].transform = models[i].transform.droppedToBed(meshInfo: info)
                updateIntersections()
            }
        }
    }

    private func layFlatInline() {
        guard let info = selectedModel?.meshInfo, let idx = selectedIndex else { return }

        var bestScore: Float = -.infinity
        var bestNormal = SIMD3<Float>(0, 0, -1)
        for face in info.faces {
            let score = -face.normal.z * face.area
            if score > bestScore { bestScore = score; bestNormal = face.normal }
        }

        models[idx].transform.rotationDeg = AutoOrient.rotationDeg(placing: bestNormal)
        models[idx].transform = models[idx].transform.droppedToBed(meshInfo: info)
        updateIntersections()
    }

    private var scaleXBinding: Binding<Float> {
        Binding(get: { self.selectedModel?.transform.scale.x ?? 1 }) { v in
            guard v > 0, let idx = self.selectedIndex else { return }
            if self.lockScale, self.models[idx].transform.scale.x > 0 {
                let r = v / self.models[idx].transform.scale.x
                self.models[idx].transform.scale.x = v
                self.models[idx].transform.scale.y *= r
                self.models[idx].transform.scale.z *= r
            } else {
                self.models[idx].transform.scale.x = v
            }
            self.updateIntersections()
        }
    }
    private var scaleYBinding: Binding<Float> {
        Binding(get: { self.selectedModel?.transform.scale.y ?? 1 }) { v in
            guard v > 0, let idx = self.selectedIndex else { return }
            if self.lockScale, self.models[idx].transform.scale.y > 0 {
                let r = v / self.models[idx].transform.scale.y
                self.models[idx].transform.scale.y = v
                self.models[idx].transform.scale.x *= r
                self.models[idx].transform.scale.z *= r
            } else {
                self.models[idx].transform.scale.y = v
            }
            self.updateIntersections()
        }
    }
    private var scaleZBinding: Binding<Float> {
        Binding(get: { self.selectedModel?.transform.scale.z ?? 1 }) { v in
            guard v > 0, let idx = self.selectedIndex else { return }
            if self.lockScale, self.models[idx].transform.scale.z > 0 {
                let r = v / self.models[idx].transform.scale.z
                self.models[idx].transform.scale.z = v
                self.models[idx].transform.scale.x *= r
                self.models[idx].transform.scale.y *= r
            } else {
                self.models[idx].transform.scale.z = v
            }
            self.updateIntersections()
        }
    }

    @ViewBuilder
    private func overlayButton(icon: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        VStack(spacing: 3) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.title3)
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(active ? Color.accentColor : Color.clear, lineWidth: 1.5)
                    )
            }
            .buttonStyle(.plain)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.7), radius: 2, x: 0, y: 1)
        }
    }

    private var infoButton: some View {
        Button { showAbout = true } label: {
            Image(systemName: "info.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
                .padding(8)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Layer slider

    private var layerSliderView: some View {
        layerSliderCard
            .padding(.leading, 16)
            .padding(.trailing, 72)
            .padding(.top, 60)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var layerSliderCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Layer")
                LayerIndexField(layerIndex: $currentLayerIndex, layerCount: parsedLayers.count)
                Text("of \(parsedLayers.count)")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)

            if previewUsesSeveralTools {
                Picker("Colour by", selection: $previewColouring) {
                    ForEach(PreviewColouring.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
            }
            if showsToolColours {
                toolChangeHereMenu
                    .fixedSize()
            }

            Slider(
                value: Binding(
                    get: { Double(currentLayerIndex) },
                    set: { currentLayerIndex = Int($0.rounded()) }
                ),
                in: 0...Double(max(0, parsedLayers.count - 1)),
                step: 1
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Colour by height from the preview: from the current layer up, the
    /// selected model (or every model, if none is selected) prints with a tool.
    private var toolChangeHereMenu: some View {
        Menu {
            let choices = Array(1...toolCount) + mixes.map(\.id)
            ForEach(choices, id: \.self) { tool in
                Button(toolMenuTitle(tool)) { addToolChangeAtCurrentLayer(tool) }
            }
        } label: {
            Label("Tool from here", systemImage: "paintpalette")
                .font(.caption.weight(.semibold))
        }
        .disabled(isBusy)
    }

    private func toolMenuTitle(_ tool: Int) -> String {
        if let mix = mixes.first(where: { $0.id == tool }) {
            return "\(mix.name) (" + mix.tools.map { "T\($0)" }.joined(separator: "+") + ")"
        }
        return "T\(tool) – \(materialProfileStore.material(forTool: tool)?.name ?? "")"
    }

    private func addToolChangeAtCurrentLayer(_ tool: Int) {
        guard parsedLayers.indices.contains(currentLayerIndex) else { return }
        // The band starts at the bottom of the current layer, so it includes it.
        let from = currentLayerIndex > 0 ? Double(parsedLayers[currentLayerIndex - 1].z) : 0
        let rounded = (from * 1000).rounded() / 1000
        for i in models.indices where selectedModelID == nil || models[i].id == selectedModelID {
            models[i].toolBands.removeAll { abs($0.fromZ - rounded) < 0.001 }
            models[i].toolBands.append(ToolBand(fromZ: rounded, tool: tool))
            models[i].toolBands.sort { $0.fromZ < $1.fromZ }
        }
        triggerSlice()
    }

    // MARK: - Bottom Panel

    private var bottomPanel: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isPanelExpanded.toggle()
                }
            } label: {
                VStack(spacing: 4) {
                    Capsule()
                        .fill(Color(.systemGray3))
                        .frame(width: 36, height: 4)
                    Image(systemName: isPanelExpanded ? "chevron.down" : "chevron.up")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            if isPanelExpanded {
                expandedPanelContent
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                collapsedPanelContent
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: -4)
    }

    /// Filename stem PalmSlice will use when the output filename field is left blank —
    /// the sole model's name, or "multimodel_N" for multiple models.
    private func autoOutputStem(for models: [PlacedModel]) -> String {
        if models.count == 1 {
            // Use the original name, not the temp copy's URL (which is prefixed with a UUID).
            return URL(fileURLWithPath: models[0].name).deletingPathExtension().lastPathComponent
        }
        return "multimodel_\(models.count)"
    }

    /// Live preview of the exact .gcode filename that will be saved if the
    /// output filename field is left blank. Shown as the field's placeholder.
    private var autoOutputFileName: String {
        guard !models.isEmpty, let profile = sliceProfileStore.selectedProfile else {
            return "Output filename (auto)"
        }
        return String(format: "%@_%.2fmm_%d.gcode", autoOutputStem(for: models), profile.layerHeight, profile.infillDensity)
    }

    private var panelModelSummary: String {
        switch models.count {
        case 0: return "No models loaded"
        case 1: return models[0].name
        default: return "\(models.count) models"
        }
    }

    private var collapsedPanelContent: some View {
        HStack(spacing: 12) {
            statusIcon.scaleEffect(0.9)

            VStack(alignment: .leading, spacing: 1) {
                Text(panelModelSummary)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(collapsedSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isBusy {
                Button(role: .destructive) {
                    if let h = activeHandle { slicer_cancel(h) }
                } label: {
                    Image(systemName: "xmark.circle.fill").imageScale(.large)
                }
                .buttonStyle(.plain)
            } else {
                if case .done = state {
                    Button {
                        exportGCode()
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                Button {
                    triggerSlice()
                } label: {
                    Label(isSliced ? "Re-slice" : "Slice", systemImage: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold))
                }
                .tint(isSliced ? .gray : .accentColor)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isBusy)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 28)
    }

    private var collapsedSubtitle: String {
        switch state {
        case .idle:            return profileStore.selectedProfile?.name ?? "No printer selected"
        case .slicing(let phase, _): return phase
        case .done(_, let time, _, _): return time.map { "Done · \($0)" } ?? "Done"
        case .failed:          return "Error — tap to expand"
        }
    }

    private var expandedPanelContent: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                // File row
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(panelModelSummary)
                            .font(.headline)
                        if let sp = sliceProfileStore.selectedProfile {
                            Text(sp.pickerSubtitle)
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("No slice profile selected")
                                .font(.caption).foregroundStyle(.red)
                        }
                    }
                    Spacer()
                    Button { showFilePicker = true } label: {
                        Label("Add Model", systemImage: "plus.app")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
                }

                // Export filename field
                HStack(spacing: 8) {
                    Image(systemName: "doc.badge.gearshape")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                    TextField(autoOutputFileName, text: $exportFileName)
                        .font(.subheadline)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .disabled(isBusy)
                }

                Divider()

                profileRows

                Divider()

                HStack(spacing: 12) {
                    statusIcon
                    Text(statusMessage)
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                    Spacer()
                }

                if case .slicing(_, let p) = state {
                    ProgressView(value: p).animation(.linear(duration: 0.15), value: p)
                }

                sliceDetailsButton

                Divider()

                actionButtons
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            Color.clear.frame(height: 20)
        }
    }

    /// Printer / slice / material profile pickers.
    @ViewBuilder
    private var profileRows: some View {
        // Printer profile row
        Button { showProfilePicker = true } label: {
            HStack {
                Label(
                    profileStore.selectedProfile?.name ?? "No Printer Selected",
                    systemImage: "printer"
                )
                .font(.subheadline)
                .foregroundStyle(profileStore.selectedProfile == nil ? .red : .primary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .disabled(isBusy)

        // Slice profile row
        Button { showSliceProfilePicker = true } label: {
            HStack {
                Label(
                    sliceProfileStore.selectedProfile?.name ?? "No Slice Profile Selected",
                    systemImage: "slider.horizontal.3"
                )
                .font(.subheadline)
                .foregroundStyle(sliceProfileStore.selectedProfile == nil ? .red : .primary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .disabled(isBusy)

        // Material profile row; one per tool on a multi-tool printer.
        if toolCount <= 1 {
            Button { materialPickerTool = MaterialPickerTool(tool: 1) } label: {
                HStack {
                    Label(
                        materialProfileStore.selectedProfile?.name ?? "No Material Selected",
                        systemImage: "drop"
                    )
                    .font(.subheadline)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .disabled(isBusy)
        } else {
            toolStrip
        }
    }

    /// Tools 1…N with their materials, flagging tools the plate doesn't use.
    @ViewBuilder
    private var toolStrip: some View {
        let used = toolPalette.physicalTools(plateTools)
        ForEach(1...toolCount, id: \.self) { tool in
            let material = materialProfileStore.material(forTool: tool)
            Button { materialPickerTool = MaterialPickerTool(tool: tool) } label: {
                HStack(spacing: 8) {
                    ToolBadge(tool: tool, colour: toolPalette.colour(tool))
                    Text(material?.name ?? "No Material Selected")
                        .font(.subheadline)
                        .foregroundStyle(used.contains(tool) ? Color.primary : Color.secondary)
                    if !used.contains(tool) {
                        Text("unused").font(.caption2).foregroundStyle(.secondary)
                    } else if tool > 1 && !materialProfileStore.hasOwnMaterial(tool: tool) {
                        Text("same as T1").font(.caption2).foregroundStyle(.orange)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .disabled(isBusy)
        }
        if ToolMix.isSupported {
            Button { showMixes = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "circle.lefthalf.filled").frame(width: 28)
                    Text(mixes.isEmpty ? "Mixes" : "Mixes (\(mixes.count))").font(.subheadline)
                    ForEach(mixes.prefix(5)) { MixSwatch(mix: $0, palette: toolPalette).scaleEffect(0.6).frame(width: 18, height: 18) }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .disabled(isBusy)
        }
        if let hint = mixLayerHint {
            Label(hint, systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
        }
    }

    /// ColorMix looks best with thin layers; nudge when a mix is used with thick ones.
    private var mixLayerHint: String? {
        guard plateTools.contains(where: ToolMix.isMix),
              let height = sliceProfileStore.selectedProfile?.layerHeight, height > 0.12 else { return nil }
        return String(format: "Mixes look smoothest at 0.08–0.12 mm layers (now %g mm). Each layer change in a mixed area is a tool change.", height)
    }

    // MARK: Tools

    private var toolCount: Int { max(1, profileStore.selectedProfile?.numberOfExtruders ?? 1) }

    /// Display colours for tools 1…N (their materials) and the session's mixes.
    /// Tool colours for the 3D view, painting and mixes. A tool that would show
    /// the same colour as an earlier one (e.g. it borrows tool 1's material) gets a
    /// distinct stand-in so paint stays readable.
    private var toolPalette: ToolPalette {
        var physical: [HexColour] = []
        for tool in 1...toolCount {
            let colour = HexColour(materialProfileStore.material(forTool: tool)?.colour ?? "") ?? .grey
            physical.append(physical.contains(colour)
                ? HexColour.standIn(forTool: tool, avoiding: physical) : colour)
        }
        return ToolPalette(physical: physical, mixes: mixes)
    }

    /// The wipe tower the slice will print, when the plate uses several tools.
    private var wipeTower: WipeTowerFootprint? {
        let height = models.compactMap { m in m.meshInfo.map { Double($0.sizeMMZ * m.transform.scale.z) } }.max() ?? 0
        return WipeTowerFootprint.make(
            settings: sliceProfileStore.selectedProfile?.slicerSettings() ?? [:], base: basePrintSettings,
            toolCount: toolCount, toolsUsed: toolPalette.physicalTools(plateTools).count,
            modelHeight: height, slicedDepth: slicedTowerDepth, position: wipeTowerXY)
    }

    /// Where the wipe tower goes: dragged, or the default for this bed.
    private var wipeTowerXY: SIMD2<Double> {
        wipeTowerPosition ?? WipeTowerFootprint.defaultPosition(
            bedX: bedXVal, bedY: bedYVal, originAtCenter: profileStore.selectedProfile?.originAtCenter == true)
    }

    /// Bed centre in printer coordinates; model positions are relative to it.
    private var bedCentreMM: SIMD2<Double> {
        profileStore.selectedProfile?.originAtCenter == true ? .zero : SIMD2(bedXVal / 2, bedYVal / 2)
    }

    // MARK: Painting

    /// Paints the selected model; an STL model first becomes a native object.
    private func startPainting() {
        guard let id = selectedModelID, let i = models.firstIndex(where: { $0.id == id }) else { return }
        if models[i].nativeURL == nil {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("paint-" + UUID().uuidString)
            guard let object = try? importModelFile(at: models[i].url, outputDir: dir).objects.first else {
                state = .failed(message: "Could not prepare \(models[i].name) for painting.")
                showErrorAlert = true
                return
            }
            models[i].nativeURL = object.nativeURL
            models[i].parts = object.parts
        }
        guard let controller = PaintController(model: models[i]) else { return }
        controller.tool = toolCount > 1 ? 2 : 1
        // With one tool there's no colour to paint, only supports and seams.
        if !showsToolColours { controller.layer = .supports }
        controller.onModelChange = { updated in
            guard let j = models.firstIndex(where: { $0.id == updated.id }) else { return }
            models[j].nativeURL = updated.nativeURL
            models[j].parts = updated.parts
            models[j].paint = updated.paint
            models[j].annotation = updated.annotation
            models[j].paintVersion = updated.paintVersion
        }
        showLayerPreview = false
        paintController = controller
        // On the phone the expanded panel covers most of the model.
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { isPanelExpanded = false }
    }

    private func finishPainting() {
        guard let controller = paintController else { return }
        let updated = controller.finish()
        if let j = models.firstIndex(where: { $0.id == updated.id }) {
            models[j].nativeURL = updated.nativeURL
            models[j].parts = updated.parts
            if models[j].annotation != nil {
                models[j].annotation = nil
                models[j].paintVersion += 1
            }
        }
        paintController = nil
    }

    /// Tint models by tool when there's more than one colour to tell apart.
    private var showsToolColours: Bool { toolCount > 1 || !mixes.isEmpty }

    /// Every tool (PalmSlice number) the models on the plate print with.
    private var plateTools: Set<Int> {
        models.reduce(into: Set<Int>()) { $0.formUnion($1.usedTools) }
    }

    // MARK: Sub-views

    @ViewBuilder
    private var statusIcon: some View {
        switch state {
        case .idle:    Image(systemName: "circle").foregroundStyle(.secondary)
        case .slicing: ProgressView().scaleEffect(0.9)
        case .done:    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:  Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private var statusMessage: String {
        switch state {
        case .idle:               return "Ready to slice."
        case .slicing(let p, _): return p
        case .done(let url, let time, let filament, let stats):
            var msg = "Sliced: \(url.lastPathComponent)\nReview the preview, then tap Export."
            if let t = time { msg += "\nTime: \(t)" }
            if let stats { msg += "\nFilament: \(stats.summaryText)" }
            else if let f = filament { msg += "\nFilament: \(f)" }
            return msg
        case .failed(let msg):   return "Error: \(msg)"
        }
    }

    private var sliceStats: SliceStats? {
        if case .done(_, _, _, let stats) = state { return stats }
        return nil
    }

    /// Opens the slice's filament use, cost and filament changes.
    @ViewBuilder
    private var sliceDetailsButton: some View {
        if sliceStats != nil {
            Button { showSliceStats = true } label: {
                Label("Filament Use & Cost", systemImage: "chart.bar.doc.horizontal")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                triggerSlice()
            } label: {
                Label(isSliced ? "Re-slice" : "Slice", systemImage: "slider.horizontal.3")
                    .labelStyle(.titleAndIcon)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isBusy || !hasModels)
            .keyboardShortcut("r", modifiers: .command)

            if isBusy {
                Button(role: .destructive) {
                    if let h = activeHandle { slicer_cancel(h) }
                } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                        .labelStyle(.titleAndIcon)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            if case .done = state {
                Button {
                    exportGCode()
                } label: {
                    Label("Export G-code", systemImage: "square.and.arrow.up")
                        .labelStyle(.titleAndIcon)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .keyboardShortcut("e", modifiers: .command)
            }
        }
    }

    private var isSliced: Bool {
        if case .done = state { return true }
        return false
    }

    /// Opens the export sheet for the previewed slice, where the user can rename
    /// it and choose Files, Share, or OctoPrint. Slicing alone never writes outside temp.
    private func exportGCode() {
        guard case .done(let tempURL, _, _, _) = state else { return }
        let project = tempURL.deletingPathExtension().appendingPathExtension("3mf")
        exportRequest = ExportRequest(sourceURL: tempURL,
                                      projectURL: FileManager.default.fileExists(atPath: project.path) ? project : nil)
    }

    // MARK: - File import

    /// Imports an STL directly, or converts a 3MF / OBJ / AMF file into one STL per
    /// object via libslic3r and imports each of those.
    private func importModel(from url: URL) {
        let ext = url.pathExtension.lowercased()
        guard supportedModelExtensions.contains(ext) else {
            state = .failed(message: "\(url.lastPathComponent) isn't a supported model file. PalmSlice can open STL, 3MF, OBJ and AMF files.")
            showErrorAlert = true
            return
        }

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let importID = UUID()
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(importID.uuidString + "_" + url.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            state = .failed(message: "Could not import \(url.lastPathComponent): \(error.localizedDescription)")
            showErrorAlert = true
            return
        }

        let checkUnits = modelFormatLacksUnits(ext)
        if ext == "stl" {
            addModels([ConvertedModelObject(url: dest, name: url.lastPathComponent, offsetMM: .zero)],
                      checkUnits: checkUnits)
            return
        }

        let fileName = url.lastPathComponent
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-" + importID.uuidString, isDirectory: true)
        isParsingSTL = true
        let sessionMixes = mixes
        Task.detached(priority: .userInitiated) {
            let result = Result { try importModelFile(at: dest, outputDir: outputDir, mixes: sessionMixes) }
            try? FileManager.default.removeItem(at: dest)
            await MainActor.run {
                isParsingSTL = false
                switch result {
                case .success(let file):
                    var objects = file.objects
                    mixes = file.mixes
                    // A single-object file keeps the file's name, like an STL import.
                    if objects.count == 1 {
                        objects[0].name = fileName
                        objects[0].offsetMM = .zero
                    }
                    addModels(objects, checkUnits: checkUnits)
                    offerFileProfiles(objects.first?.projectSettings, fileName: fileName)
                case .failure(let error):
                    state = .failed(message: "Could not import \(fileName): \(error.localizedDescription)")
                    showErrorAlert = true
                }
            }
        }
    }

    /// Adds STL-backed models to the plate, keeping their relative layout, and parses
    /// their geometry in the background.
    private func addModels(_ objects: [ConvertedModelObject], checkUnits: Bool) {
        guard !objects.isEmpty else { return }

        // Offset each additional import along X so it doesn't land exactly on top of
        // existing models in the slicer (which can crash libslic3r with coincident objects).
        let baseX: Float = models.isEmpty ? 0 : Float(models.count) * 50
        var added: [(id: UUID, url: URL, name: String, parts: [Int], volumes: [(Int, URL)],
                     native: (url: URL, parts: [ModelPart])?)] = []
        for object in objects {
            var initialTransform = ModelTransform()
            initialTransform.positionMM.x = baseX + object.offsetMM.x
            // positionMM.y is SceneKit Z, which points opposite to print Y.
            initialTransform.positionMM.y = -object.offsetMM.y
            let id = UUID()
            models.append(PlacedModel(
                id: id,
                url: object.url,
                name: object.name,
                geometry: nil,
                transform: initialTransform,
                fileSettings: object.fileSettings,
                projectSettings: object.projectSettings,
                nativeURL: object.nativeURL,
                extruder: object.extruder,
                parts: object.parts
            ))
            let volumes = object.parts.enumerated().compactMap { k, part in part.meshURL.map { (k, $0) } }
            added.append((id, object.url, object.name, models.last!.partFacetCounts, volumes,
                          object.nativeURL.map { ($0, object.parts) }))
        }
        selectedModelID = added.last?.id
        state = .idle
        showLayerPreview = false
        parsedLayers = []

        let mode = viewerColorMode
        isParsingSTL = true

        Task.detached(priority: .userInitiated) {
            for model in added {
                let parsed = Result { () throws -> (SCNGeometry, STLMeshInfo) in
                    (try parseSTL(url: model.url, colorMode: mode, partFacetCounts: model.parts),
                     try parseSTLMeshInfo(url: model.url))
                }
                let bvh = (try? parsed.get()).flatMap { TriangleBVH.build(triangleVertices: $0.1.vertices) }
                // Colour painting from the file, drawn over the model.
                let paint = model.native.flatMap { loadPaintMesh(nativeURL: $0.url, parts: $0.parts) }
                // Other volumes, centred like the object's geometry.
                var volumeGeometries: [Int: SCNGeometry] = [:]
                if let info = try? parsed.get().1 {
                    let centre = (info.boundingBoxMM.min + info.boundingBoxMM.max) * 0.5
                    for (k, url) in model.volumes {
                        volumeGeometries[k] = try? parseSTL(url: url, centreMM: centre)
                    }
                }
                await MainActor.run {
                    guard let idx = models.firstIndex(where: { $0.id == model.id }) else { return }
                    switch parsed {
                    case .success(let (geo, info)):
                        models[idx].geometry = geo
                        models[idx].meshInfo = info
                        models[idx].bvh      = bvh
                        models[idx].partGeometries = volumeGeometries
                        models[idx].paint = paint
                        models[idx].paintVersion += 1
                        updateIntersections()

                        if checkUnits, !showUnitScaleAlert, let scale = info.suspectedUnitScale {
                            unitScaleAlertModelID = model.id
                            unitScaleAlertScale = scale
                            unitScaleAlertOriginalSizeMM = SIMD3(info.sizeMMX, info.sizeMMY, info.sizeMMZ)
                            showUnitScaleAlert = true
                        }
                    case .failure(let error):
                        models.remove(at: idx)
                        if selectedModelID == model.id { selectedModelID = models.last?.id }
                        updateIntersections()
                        state = .failed(message: "Could not read \(model.name): \(error.localizedDescription)")
                        showErrorAlert = true
                    }
                }
            }
            await MainActor.run { isParsingSTL = false }
        }
    }

    // MARK: - Slice trigger (checks for intersection first)

    private func triggerSlice() {
        guard anyIntersecting else { startSlice(); return }
        // The quick box check flags models whose boxes overlap (e.g. nested
        // copies from Fill Plate); confirm with the mesh check before warning.
        preciseCheckTask?.cancel()
        let snapshot = models, bx = bedXVal, by = bedYVal
        Task {
            let ids = await Task.detached(priority: .userInitiated) {
                preciseIntersectionResults(models: snapshot, bedX: bx, bedY: by)
            }.value
            for i in models.indices { models[i].isIntersecting = ids.contains(models[i].id) }
            if anyIntersecting { showIntersectingAlert = true } else { startSlice() }
        }
    }

    /// Slices in the background-capable way and taps out the result.
    private func startSlice() {
        SliceActivity.shared.begin { if let h = activeHandle { slicer_cancel(h) } }
        Task.detached(priority: .userInitiated) {
            await runSlice()
            await MainActor.run {
                let success: Bool
                switch state {
                case .done: success = true
                case .failed: success = false
                default:   // cancelled
                    SliceActivity.shared.end(success: false)
                    return
                }
                SliceActivity.shared.end(success: success, title: sliceNotificationTitle,
                                         body: sliceNotificationBody)
                UINotificationFeedbackGenerator().notificationOccurred(success ? .success : .error)
            }
        }
    }

    /// What the background notification says about the slice that just ended.
    private var sliceNotificationTitle: String {
        if case .done(let url, _, _, _) = state { return "Sliced \(url.deletingPathExtension().lastPathComponent)" }
        return "Slice Failed"
    }

    private var sliceNotificationBody: String {
        switch state {
        case .done(_, let time, let filament, let stats):
            let parts = [time, stats?.summaryText ?? filament?.split(separator: "\n").first.map(String.init)].compactMap { $0 }
            return parts.isEmpty ? "Ready to preview." : parts.joined(separator: " · ")
        case .failed(let message): return message
        default: return ""
        }
    }

    // MARK: - Slicing

    private func setPhase(_ msg: String, progress: Double = 0) async {
        await MainActor.run {
            state = .slicing(phase: msg, progress: progress)
            SliceActivity.shared.update(phase: msg, progress: progress)
        }
    }

    private func runSlice() async {
        // 0. Require models
        guard await MainActor.run(body: { hasModels }) else {
            await MainActor.run { state = .failed(message: "No models loaded") ; showErrorAlert = true }
            return
        }

        // 1. Require profiles
        guard let printerProfile = await MainActor.run(body: { profileStore.selectedProfile }) else {
            await MainActor.run { showNoProfileAlert = true }
            return
        }
        guard let sliceProfile = await MainActor.run(body: { sliceProfileStore.selectedProfile }) else {
            await MainActor.run { showNoSliceProfileAlert = true }
            return
        }

        // 2. Snapshot models on main thread
        let snapshotModels = await MainActor.run(body: { models })

        // 3. Output path in the temp folder — copied to Documents only on Export
        let docs = FileManager.default.temporaryDirectory
        let customName = await MainActor.run(body: { exportFileName.trimmingCharacters(in: .whitespaces) })
        let stem: String
        if !customName.isEmpty {
            stem = customName.hasSuffix(".gcode") ? String(customName.dropLast(6)) : customName
        } else {
            stem = await MainActor.run(body: { autoOutputStem(for: snapshotModels) })
        }
        let outName = String(format: "%@_%.2fmm_%d.gcode",
                             stem, sliceProfile.layerHeight, sliceProfile.infillDensity)
        let gcodeURL = docs.appendingPathComponent(outName)

        // 4. Create slicer context
        await setPhase("Initialising slicer…")
        guard let handle = slicer_create() else {
            await MainActor.run { state = .failed(message: "slicer_create() returned nil") ; showErrorAlert = true }
            return
        }
        await MainActor.run { activeHandle = handle }
        defer {
            slicer_destroy(handle)
            Task { @MainActor in activeHandle = nil }
        }

        // 5. Settings: PrusaSlicer presets, then the printer, material and
        //    slice profiles on top (SliceSetup).
        await setPhase("Applying profiles…")
        let selectedMaterial = await MainActor.run(body: { materialProfileStore.selectedProfile })
        let toolMaterials = await MainActor.run(body: {
            materialProfileStore.toolMaterials(count: printerProfile.numberOfExtruders)
        })
        do {
            try SliceSetup.configure(handle, printer: printerProfile,
                                     material: selectedMaterial, slice: sliceProfile,
                                     toolMaterials: toolMaterials)
        } catch {
            await MainActor.run { state = .failed(message: "\(error)") ; showErrorAlert = true }
            return
        }
        // Struct form of the slice profile for the wall/top/bottom geometry check.
        var sliceCfg = sliceProfile.bridgeConfig()

        // Keep the printer's G-code thumbnails; they're rendered after slicing.
        slicer_enable_thumbnails(handle, 1)

        // The wipe tower where the bed view shows it.
        let tower = await MainActor.run(body: { wipeTowerXY })
        slicer_set_wipe_tower_position(handle, Float(tower.x), Float(tower.y), 0)

        // Mixes before the models: their tool numbers depend on them.
        let sessionMixes = await MainActor.run(body: { mixes })
        if slicer_set_virtual_extruders(handle, ToolMix.json(sessionMixes)) != 0 {
            let msg = String(cString: slicer_last_error(handle))
            await MainActor.run { state = .failed(message: msg) ; showErrorAlert = true }
            return
        }

        // 9. Load each model. Copies that slice the same (Duplicate / Fill
        // Plate) become instances of the first: sliced once, printed at each spot.
        var loaded: [(model: PlacedModel, object: Int32)] = []
        for (i, model) in snapshotModels.enumerated() {
            await setPhase("Loading \(model.name)… (\(i+1)/\(snapshotModels.count))")
            if let original = loaded.first(where: { $0.model.slicesLike(model) }) {
                if slicer_add_object_instance(handle, original.object, model.transform.positionMM.x,
                                              model.transform.positionMM.y) != 0 {
                    let msg = String(cString: slicer_last_error(handle))
                    await MainActor.run { state = .failed(message: msg) ; showErrorAlert = true }
                    return
                }
                continue
            }
            let objIdx = model.nativeURL.map {
                slicer_add_model_object(handle, $0.path, model.useFileSettings ? 1 : 0)
            } ?? slicer_add_stl(handle, model.url.path)
            if objIdx < 0 {
                let msg = String(cString: slicer_last_error(handle))
                await MainActor.run { state = .failed(message: msg) ; showErrorAlert = true }
                return
            }

            var mt = SlicerModelTransform()
            mt.pos_x_mm  = model.transform.positionMM.x
            // positionMM.y = print Y (bed depth) = SceneKit Z → pos_z_mm
            mt.pos_z_mm  = model.transform.positionMM.y
            mt.rot_x_deg = model.transform.rotationDeg.x
            // Pivot eulerAngles = (rx, rz, ry) so SceneKit Euler Y = rotationDeg.z
            mt.rot_y_deg = model.transform.rotationDeg.z
            // SceneKit Euler Z = rotationDeg.y
            mt.rot_z_deg = model.transform.rotationDeg.y
            mt.scale_x   = model.transform.scale.x
            // Pivot scale = (sx, sz, sy) so SceneKit Y scale = scale.z
            mt.scale_y   = model.transform.scale.z
            // SceneKit Z scale = scale.y
            mt.scale_z   = model.transform.scale.y
            if slicer_set_object_transform(handle, objIdx, &mt) != 0 {
                let msg = String(cString: slicer_last_error(handle))
                await MainActor.run { state = .failed(message: msg) ; showErrorAlert = true }
                return
            }
            if let msg = SliceSetup.applyTools(handle, object: objIdx, model: model) {
                await MainActor.run { state = .failed(message: "\(model.name): \(msg)") ; showErrorAlert = true }
                return
            }
            // Settings the model's 3MF stores on it, over the profiles. Heights
            // follow the part's Z scale; a tilted part keeps only the
            // height-independent settings.
            if model.useFileSettings, let fileSettings = model.fileSettings {
                let text = fileSettings.text(heightScale: Double(model.transform.scale.z),
                                             includeHeights: model.transform.keepsFileHeights)
                if slicer_set_object_file_settings(handle, objIdx, text) != 0 {
                    let msg = "\(model.name): \(String(cString: slicer_last_error(handle)))"
                    await MainActor.run { state = .failed(message: msg) ; showErrorAlert = true }
                    return
                }
            }
            // The user's Part Settings, on top. Heights are as placed.
            if !model.partSettings.isEmpty {
                let height = model.meshInfo.map { Double($0.sizeMMZ * model.transform.scale.z) } ?? .infinity
                if slicer_set_object_file_settings(handle, objIdx, model.partSettings.userText(partHeight: height)) != 0 {
                    let msg = "\(model.name) Part Settings: \(String(cString: slicer_last_error(handle)))"
                    await MainActor.run { state = .failed(message: msg) ; showErrorAlert = true }
                    return
                }
            }
            if let msg = SliceSetup.applyToolBands(handle, object: objIdx, model: model) {
                await MainActor.run { state = .failed(message: "\(model.name): \(msg)") ; showErrorAlert = true }
                return
            }
            loaded.append((model, objIdx))
        }

        // 8.5 Sanity-check wall/top/bottom settings against the now-loaded,
        // now-transformed model geometry (must run after step 8, since the
        // check needs real instance bounding boxes).
        var configCheck = SlicerSliceConfigCheck()
        if slicer_check_slice_config(handle, &sliceCfg, &configCheck) == 0,
           configCheck.needs_warning != 0 {
            let original = (walls: Int(sliceCfg.wall_count),
                            top: Int(sliceCfg.top_layers),
                            bottom: Int(sliceCfg.bottom_layers))
            let decision: SliceConfigDecision = await withCheckedContinuation { continuation in
                Task { @MainActor in
                    configWarningCheck = configCheck
                    configWarningOriginal = original
                    configDecisionContinuation = continuation
                    showConfigWarningAlert = true
                }
            }

            switch decision {
            case .cancel:
                await MainActor.run { state = .idle }
                return
            case .autoAdjust:
                sliceCfg.wall_count = configCheck.suggested_wall_count
                sliceCfg.top_layers = configCheck.suggested_top_layers
                sliceCfg.bottom_layers = configCheck.suggested_bottom_layers
                do {
                    try SliceSetup.applySettings([
                        "wall_loops": String(configCheck.suggested_wall_count),
                        "top_shell_layers": String(configCheck.suggested_top_layers),
                        "bottom_shell_layers": String(configCheck.suggested_bottom_layers),
                    ], label: "Adjusted settings", to: handle)
                } catch {
                    await MainActor.run { state = .failed(message: "\(error)") ; showErrorAlert = true }
                    return
                }
            case .sliceAnyway:
                break
            }
        }

        // 10. Slice with progress
        let lhStr = String(format: "%.2g", sliceProfile.layerHeight)
        await setPhase("Slicing at \(lhStr) mm / \(sliceProfile.infillDensity)% infill…")

        let relay = ProgressRelay()
        relay.handler = { pct in
            Task { @MainActor in
                if case .slicing(let phase, _) = state {
                    state = .slicing(phase: phase, progress: Double(pct) / 100.0)
                    SliceActivity.shared.update(phase: phase, progress: Double(pct) / 100.0)
                }
            }
        }
        let relayPtr = Unmanaged.passRetained(relay).toOpaque()

        let sliceResult = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = slicer_slice_with_progress(
                    handle,
                    Float(sliceProfile.layerHeight),
                    Int32(sliceProfile.infillDensity),
                    { pct, ctx in
                        guard let ctx else { return }
                        Unmanaged<ProgressRelay>.fromOpaque(ctx).takeUnretainedValue().handler(pct)
                    },
                    relayPtr
                )
                continuation.resume(returning: result)
            }
        }
        Unmanaged<ProgressRelay>.fromOpaque(relayPtr).release()

        if sliceResult != 0 {
            let msg = String(cString: slicer_last_error(handle))
            await MainActor.run {
                if msg == "canceled" { state = .idle }
                else { state = .failed(message: msg) ; showErrorAlert = true }
            }
            return
        }

        // 10.5 Thumbnails the printer asks for (e.g. its screen's preview).
        var sizes = [Int32](repeating: 0, count: 16)
        let sizeCount = min(Int(slicer_thumbnail_sizes(handle, &sizes, 8)), 8)
        if sizeCount > 0 {
            for i in 0..<sizeCount {
                let (w, h) = (Int(sizes[2 * i]), Int(sizes[2 * i + 1]))
                let pixels = await MainActor.run(body: {
                    ThumbnailRenderer.render(models: snapshotModels, palette: showsToolColours ? toolPalette : nil,
                                             width: w, height: h)
                })
                if let pixels { slicer_set_thumbnail(handle, Int32(w), Int32(h), pixels) }
            }
        }

        // 11. Write G-code (to temp; the user exports after previewing)
        await setPhase("Generating G-code…", progress: 0.95)
        if slicer_export_gcode(handle, gcodeURL.path) != 0 {
            let msg = String(cString: slicer_last_error(handle))
            await MainActor.run { state = .failed(message: msg) ; showErrorAlert = true }
            return
        }

        let conflict = Self.pathConflictMessage(String(cString: slicer_path_conflict(handle)))

        // 12. Parse stats and layer preview
        await setPhase("Parsing results…", progress: 0.99)
        var towerDepth: Float = 0
        let hasTower = slicer_wipe_tower_size(handle, &towerDepth, nil, nil) == 0
        // The same plate as a PrusaSlicer project, offered next to the G-code.
        let projectURL = gcodeURL.deletingPathExtension().appendingPathExtension("3mf")
        try? FileManager.default.removeItem(at: projectURL)
        slicer_export_project_3mf(handle, projectURL.path)
        let stats = SliceStats(json: String(cString: slicer_print_stats(handle)))
        // Free the slice before reading the G-code back: big plates need both otherwise.
        slicer_release_print(handle)
        let summary = GCodeSummary(url: gcodeURL)
        let layers = parseGCode(url: gcodeURL)
        let severalTools = layers.contains { $0.moves.contains { $0.tool != 0 } }

        await MainActor.run {
            var filament = summary?.filamentText
            if let changes = summary?.toolChanges, changes > 0 { filament = (filament ?? "") + "\nTool changes: \(changes)" }
            var stats = stats
            let palette = toolPalette
            for f in stats?.filaments ?? [] {
                stats?.materialNames[f.tool] = materialProfileStore.material(forTool: f.tool)?.name
                stats?.toolColours[f.tool] = palette.colour(f.tool)
            }
            state = .done(gcodeURL: gcodeURL, printTime: summary?.printTime, filamentG: filament, stats: stats)
            previewUsesSeveralTools = severalTools
            slicedTowerDepth = hasTower ? Double(towerDepth) : nil
            parsedLayers = layers
            currentLayerIndex = max(0, layers.count - 1)
            showLayerPreview = !layers.isEmpty
            pathConflictMessage = conflict
        }
    }

    /// Explains slicer_path_conflict's "<name>\n<name>\n<height>", or nil.
    static func pathConflictMessage(_ conflict: String) -> String? {
        let fields = conflict.split(separator: "\n").map(String.init)
        guard fields.count == 3 else { return nil }
        let height = Double(fields[2]).map { String(format: "%.2f mm", $0) } ?? fields[2]
        let objects = fields[..<2].filter { $0 != "WipeTower" }
        if objects.count == 1 {
            return "\(objects[0]) runs into the wipe tower at \(height). Move the model or drag the wipe tower " +
                "so they don't overlap, then slice again."
        }
        return "\(fields[0]) and \(fields[1]) run into each other at \(height). Move them apart, then slice again."
    }
}

// MARK: - Layer Index Field

/// Text-entry companion to the layer slider; shows/edits a 1-based layer number.
struct LayerIndexField: View {
    @Binding var layerIndex: Int
    let layerCount: Int

    @State private var text = ""
    @State private var editing = false

    var body: some View {
        TextField("", text: $text) { isEditing in
            editing = isEditing
            if isEditing {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
                }
            } else { commit() }
        }
        .keyboardType(.numberPad)
        .multilineTextAlignment(.center)
        .frame(width: 34)
        .onAppear { text = render(layerIndex) }
        .onChange(of: layerIndex) { v in if !editing { text = render(v) } }
    }

    private func render(_ index: Int) -> String { String(index + 1) }

    private func commit() {
        if let n = Int(text) {
            layerIndex = min(max(n - 1, 0), max(0, layerCount - 1))
        }
        text = render(layerIndex)
    }
}

// MARK: - Document Picker

struct DocumentPickerView: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: supportedModelContentTypes)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uvc: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}

// MARK: - Share Sheet

struct ShareSheetView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uvc: UIActivityViewController, context: Context) {}
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(ProfileStore())
        .environmentObject(SliceProfileStore())
        .environmentObject(MaterialProfileStore())
}

/// A file's project settings offered after import.
struct FileProfilesOffer {
    let fileName: String
    let project: [String: String]
}

private struct MaterialPickerTool: Identifiable {
    let tool: Int
    var id: Int { tool }
}
