import SwiftUI

struct ProfilePickerView: View {
    @EnvironmentObject var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var showAddEditor = false
    @State private var profileToEdit: PrinterProfile? = nil
    @State private var pendingUntestedSelection: PrinterProfile? = nil

    private var verifiedProfiles: [PrinterProfile] {
        profileStore.profiles.filter { $0.verified }
    }
    private var untestedProfiles: [PrinterProfile] {
        profileStore.profiles.filter { !$0.verified }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(verifiedProfiles) { profile in
                        ProfileRowView(
                            profile: profile,
                            isSelected: profileStore.selectedProfileId == profile.id,
                            onSelect: { profileStore.select(id: profile.id) },
                            onOpen:   { profileToEdit = profile },
                            onDelete: { profileStore.delete(id: profile.id) },
                            onToggleVerified: { setVerified(profile, false) },
                            canDelete: profileStore.profiles.count > 1
                        )
                    }
                } header: {
                    Text("Verified")
                } footer: {
                    Text("Confirmed to print correctly on real hardware.")
                }

                Section {
                    ForEach(untestedProfiles) { profile in
                        ProfileRowView(
                            profile: profile,
                            isSelected: profileStore.selectedProfileId == profile.id,
                            onSelect: { attemptSelect(profile) },
                            onOpen:   { profileToEdit = profile },
                            onDelete: { profileStore.delete(id: profile.id) },
                            onToggleVerified: { setVerified(profile, true) },
                            canDelete: profileStore.profiles.count > 1
                        )
                    }
                } header: {
                    Text("Untested")
                } footer: {
                    Text("Imported from an open-source printer configuration library but not yet verified on real hardware in this app. Once one prints well on your printer, swipe right on it (or touch and hold) and choose Mark Verified.")
                }
            }
            .navigationTitle("Printer Profile")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(
                leading: Button("Done") { dismiss() },
                trailing: Button(action: { showAddEditor = true }) {
                    Image(systemName: "plus")
                }
            )
            .sheet(isPresented: $showAddEditor) {
                PrinterProfileEditorView(mode: .add)
            }
            .sheet(item: $profileToEdit) { profile in
                PrinterProfileEditorView(mode: .edit, profile: profile)
            }
            .alert(
                "Untested Printer Profile",
                isPresented: Binding(
                    get: { pendingUntestedSelection != nil },
                    set: { if !$0 { pendingUntestedSelection = nil } }
                )
            ) {
                Button("Cancel", role: .cancel) { pendingUntestedSelection = nil }
                Button("Select Anyway") {
                    if let profile = pendingUntestedSelection {
                        profileStore.select(id: profile.id)
                    }
                    pendingUntestedSelection = nil
                }
            } message: {
                Text("\(pendingUntestedSelection?.name ?? "This profile") hasn't been verified on real hardware. Bed size, start/end G-code, and clearances came from an open-source printer configuration library as-is and may not be accurate for your printer — proceed with caution and check your first print closely.")
            }
        }
    }

    private func attemptSelect(_ profile: PrinterProfile) {
        if profile.verified {
            profileStore.select(id: profile.id)
        } else {
            pendingUntestedSelection = profile
        }
    }

    private func setVerified(_ profile: PrinterProfile, _ verified: Bool) {
        guard profile.verified != verified else { return }
        var updated = profile
        updated.verified = verified
        profileStore.update(updated)
    }
}

private struct ProfileRowView: View {
    let profile: PrinterProfile
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onDelete: () -> Void
    let onToggleVerified: () -> Void
    let canDelete: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Tap circle to make this the active printer
            Button(action: onSelect) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)

            // Tap name/details area to open editor
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if !profile.verified {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Text(profile.name)
                            .foregroundStyle(.primary)
                            .fontWeight(isSelected ? .semibold : .regular)
                    }
                    Text(bedSummary)
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
        .swipeActions(edge: .leading) {
            Button(action: onToggleVerified) {
                Label(
                    profile.verified ? "Mark Untested" : "Mark Verified",
                    systemImage: profile.verified ? "questionmark.circle" : "checkmark.circle"
                )
            }
            .tint(profile.verified ? .orange : .green)
        }
        .contextMenu {
            Button(action: onToggleVerified) {
                Label(
                    profile.verified ? "Mark as Untested" : "Mark as Verified",
                    systemImage: profile.verified ? "questionmark.circle" : "checkmark.circle"
                )
            }
        }
    }

    private var bedSummary: String {
        String(format: "%.0f × %.0f × %.0f mm · %@",
               profile.bedX, profile.bedY, profile.bedZ, profile.gcodeFlavor.rawValue)
    }
}
