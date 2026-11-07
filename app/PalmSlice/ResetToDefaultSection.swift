import SwiftUI

/// "Reset to Default" for a saved copy of a built-in profile: puts the
/// built-in's values (and name) back in the editor. Save keeps them; Cancel
/// leaves the profile as it was.
struct ResetToDefaultSection: View {
    /// "printer", "slice profile", "material".
    let kind: String
    let onReset: () -> Void
    @State private var confirm = false

    var body: some View {
        Section {
            Button("Reset to Default", role: .destructive) { confirm = true }
        } footer: {
            Text("Puts back the values this built-in \(kind) comes with in this version of PalmSlice. Save to keep them.")
        }
        .confirmationDialog("Reset this \(kind) to its built-in values?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Reset to Default", role: .destructive, action: onReset)
        }
    }
}
