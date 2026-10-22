import SwiftUI

struct MaterialProfilePickerView: View {
    @EnvironmentObject var materialProfileStore: MaterialProfileStore
    @EnvironmentObject var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var newProfile: MaterialProfile? = nil
    @State private var showPresetPicker = false
    @State private var showIniImport = false
    @State private var profileToEdit: MaterialProfile? = nil

    var body: some View {
        NavigationStack {
            List {
                ForEach(materialProfileStore.profiles) { profile in
                    MaterialProfileRowView(
                        profile: profile,
                        isSelected: materialProfileStore.selectedProfileId == profile.id,
                        onSelect: { materialProfileStore.select(id: profile.id) },
                        onOpen:   { profileToEdit = profile },
                        onDelete: { materialProfileStore.delete(id: profile.id) },
                        canDelete: materialProfileStore.profiles.count > 1
                    )
                }
            }
            .iniImporter(MaterialProfile.self, isPresented: $showIniImport) { imported in
                for profile in imported { materialProfileStore.add(profile) }
                if let last = imported.last { materialProfileStore.select(id: last.id) }
            }
            .navigationTitle("Material Profile")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(
                leading: Button("Done") { dismiss() },
                trailing: Menu {
                    Button("New Material") {
                        newProfile = .newProfile(for: profileStore.selectedProfile)
                    }
                    Button("From PrusaSlicer Filament…") { showPresetPicker = true }
                    Button("Import PrusaSlicer .ini…") { showIniImport = true }
                } label: {
                    Image(systemName: "plus")
                }
            )
            .sheet(item: $newProfile) { draft in
                MaterialProfileEditorView(mode: .add, profile: draft)
            }
            .sheet(isPresented: $showPresetPicker) {
                PresetPickerView(type: .filament, printerPreset: profileStore.selectedProfile?.systemPreset) { name in
                    // Let this sheet finish dismissing before presenting the editor.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        newProfile = .from(filamentPreset: name)
                    }
                }
            }
            .sheet(item: $profileToEdit) { profile in
                MaterialProfileEditorView(mode: .edit, profile: profile)
            }
        }
    }
}

private struct MaterialProfileRowView: View {
    let profile: MaterialProfile
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onDelete: () -> Void
    let canDelete: Bool

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSelect) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .foregroundStyle(.primary)
                        .fontWeight(isSelected ? .semibold : .regular)
                    Text(profile.pickerSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
            .disabled(!canDelete)
        }
    }
}
