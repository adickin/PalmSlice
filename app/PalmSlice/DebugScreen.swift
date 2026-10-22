#if DEBUG
import SwiftUI

/// Screens the DEBUG-only PALMSLICE_DEBUG_SCREEN launch variable can open,
/// so the simulator can be scripted to screenshot them.
enum DebugScreen: String, Identifiable {
    case sliceEditor, sliceAllSettings, materialEditor, printerEditor, printerLibrary, printPresets

    var id: String { rawValue }

    @MainActor @ViewBuilder
    var view: some View {
        DebugScreenHost(screen: self)
    }
}

private struct DebugScreenHost: View {
    let screen: DebugScreen
    @EnvironmentObject var profileStore: ProfileStore
    @EnvironmentObject var sliceProfileStore: SliceProfileStore
    @EnvironmentObject var materialProfileStore: MaterialProfileStore
    @State private var slice = SliceProfile()

    var body: some View {
        switch screen {
        case .sliceEditor:
            SliceProfileEditorView(mode: .edit, profile: sliceProfileStore.selectedProfile ?? SliceProfile())
        case .sliceAllSettings:
            NavigationStack {
                AllSettingsView(profile: $slice, baseSettings: PresetLibrary.settings(
                    .print, SliceSetup.base(printer: profileStore.selectedProfile ?? PrinterProfile(),
                                            material: nil, slice: slice)?.print ?? "") ?? [:])
            }
            .onAppear { slice = sliceProfileStore.selectedProfile ?? SliceProfile() }
        case .materialEditor:
            MaterialProfileEditorView(mode: .edit, profile: materialProfileStore.selectedProfile ?? MaterialProfile())
        case .printerEditor:
            PrinterProfileEditorView(mode: .edit, profile: profileStore.selectedProfile ?? PrinterProfile())
        case .printerLibrary:
            PresetPickerView(type: .printer, printerPreset: nil) { _ in }
        case .printPresets:
            PresetPickerView(type: .print, printerPreset: profileStore.selectedProfile?.systemPreset) { _ in }
        }
    }
}
#endif
