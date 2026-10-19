import SwiftUI

/// Shown once, on first launch, before the app can be used. Not dismissible
/// except by tapping Accept — see PalmSliceApp for the gating logic.
struct EULAView: View {
    let onAccept: () -> Void
    @State private var declined = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Beta Software")
                        .font(.title2.weight(.semibold))

                    Text("PalmSlice is beta software under active development. Please read before continuing.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    bulletList

                    Text("You must accept these terms to use PalmSlice.")
                        .font(.subheadline.weight(.medium))
                        .padding(.top, 8)
                }
                .padding(20)
                .padding(.bottom, 80)
            }
            .navigationTitle("Before You Continue")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if declined {
                        Text("PalmSlice can't be used without accepting these terms.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }

                    Button(action: onAccept) {
                        Text("I Understand & Accept")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button(role: .destructive) {
                        // Declining keeps the cover up; the app is unusable until accepted.
                        // (No exit(0) — App Review rejects apps that quit themselves.)
                        withAnimation { declined = true }
                    } label: {
                        Text("Decline")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding()
                .background(.ultraThinMaterial)
            }
        }
        .interactiveDismissDisabled()
    }

    private var bulletList: some View {
        VStack(alignment: .leading, spacing: 12) {
            bullet("This is beta software. Bugs, crashes, and inaccurate slicing results may occur.")
            bullet("You use PalmSlice, and print any G-code it produces, entirely at your own risk.")
            bullet("Always supervise your 3D printer during operation, and review sliced output before printing.")
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\u{2022}")
                .font(.subheadline.weight(.bold))
            Text(text)
                .font(.subheadline)
        }
    }
}

#Preview {
    EULAView(onAccept: {})
}
