import SwiftUI

struct MaterialProfilePickerView: View {
    @EnvironmentObject var materialProfileStore: MaterialProfileStore
    @EnvironmentObject var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss
    /// The tool (1-based) whose material is picked; tool 1 is the selected profile.
    var tool: Int = 1
    /// Number of tools on the printer (shows "Tool n" in the title when > 1).
    var toolCount: Int = 1

    private var selectedID: UUID? {
        tool == 1 ? materialProfileStore.selectedProfileId : materialProfileStore.material(forTool: tool)?.id
    }

    private func choose(_ id: UUID) {
        materialProfileStore.setMaterial(id, forTool: tool)
    }

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
                        isSelected: selectedID == profile.id,
                        onSelect: { choose(profile.id) },
                        onOpen:   { profileToEdit = profile },
                        onDelete: { materialProfileStore.delete(id: profile.id) },
                        canDelete: materialProfileStore.profiles.count > 1
                    )
                }
            }
            .iniImporter(MaterialProfile.self, isPresented: $showIniImport) { imported in
                for profile in imported { materialProfileStore.add(profile) }
                if let last = imported.last { choose(last.id) }
            }
            .navigationTitle(toolCount > 1 ? "Tool \(tool) Material" : "Material Profile")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(
                leading: Button("Done") { dismiss() },
                trailing: Menu {
                    Button("New Material") {
                        newProfile = .newProfile(for: profileStore.selectedProfile)
                    }
                    Button("From Default Filaments…") { showPresetPicker = true }
                    Button("Import .ini…") { showIniImport = true }
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

            Circle()
                .fill((HexColour(profile.colour) ?? .grey).color)
                .overlay(Circle().strokeBorder(.secondary.opacity(0.4), lineWidth: 0.5))
                .frame(width: 16, height: 16)

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
