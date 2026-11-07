import SwiftUI

struct SliceProfilePickerView: View {
    @EnvironmentObject var sliceProfileStore: SliceProfileStore
    @EnvironmentObject var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var newProfile: SliceProfile? = nil
    @State private var showIniImport = false
    @State private var profileToEdit: SliceProfile? = nil

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(sliceProfileStore.systemProfiles) { row($0) }
                } header: {
                    Text("OrcaSlicer · \(profileStore.selectedProfile?.name ?? "this printer")")
                }
                Section {
                    ForEach(sliceProfileStore.customProfiles) { row($0) }
                } header: {
                    Text("My Qualities")
                } footer: {
                    Text("Your qualities keep only what you change and apply it over this printer's OrcaSlicer quality nearest their layer height, so they work on every printer.")
                }
            }
            .iniImporter(SliceProfile.self, isPresented: $showIniImport) { imported in
                for profile in imported { sliceProfileStore.add(profile) }
                if let last = imported.last { sliceProfileStore.select(id: last.id) }
            }
            .navigationTitle("Quality")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(
                leading: Button("Done") { dismiss() },
                trailing: Menu {
                    Button("New Quality") {
                        newProfile = .newProfile(for: profileStore.selectedProfile)
                    }
                    Button("Import .ini…") { showIniImport = true }
                } label: {
                    Image(systemName: "plus")
                }
            )
            .sheet(item: $newProfile) { draft in
                SliceProfileEditorView(mode: .add, profile: draft)
            }
            .sheet(item: $profileToEdit) { profile in
                SliceProfileEditorView(mode: .edit, profile: profile)
            }
        }
    }

    private func row(_ profile: SliceProfile) -> some View {
        SliceProfileRowView(
            profile: profile,
            isSelected: sliceProfileStore.selectedProfileId == profile.id,
            onSelect: { sliceProfileStore.select(id: profile.id) },
            onOpen:   { profileToEdit = profile },
            onDelete: { sliceProfileStore.delete(id: profile.id) },
            canDelete: !profile.isSystem
        )
    }
}

private struct SliceProfileRowView: View {
    let profile: SliceProfile
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
