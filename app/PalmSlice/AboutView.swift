import SwiftUI

private struct ThirdPartyLicense: Identifiable {
    let id = UUID()
    let name: String
    let license: String
}

// Kept in sync with LICENSE.md's "Third-Party Licenses" table.
private let thirdPartyLicenses: [ThirdPartyLicense] = [
    .init(name: "PrusaSlicer / libslic3r", license: "AGPL-3.0"),
    .init(name: "Boost",                   license: "Boost Software License 1.0"),
    .init(name: "oneTBB",                  license: "Apache-2.0"),
    .init(name: "CGAL",                    license: "GPL-3.0 / LGPL-3.0"),
    .init(name: "GMP",                     license: "LGPL-3.0"),
    .init(name: "MPFR",                    license: "LGPL-3.0"),
    .init(name: "Eigen",                   license: "MPL-2.0"),
    .init(name: "Clipper2",                license: "Boost Software License 1.0"),
    .init(name: "Qhull",                   license: "Qhull license (permissive)"),
    .init(name: "LibBGCode",               license: "AGPL-3.0"),
    .init(name: "heatshrink",              license: "ISC"),
    .init(name: "nlohmann/json",           license: "MIT"),
    .init(name: "NanoSVG",                 license: "zlib"),
    .init(name: "NLopt",                   license: "LGPL-2.1+"),
    .init(name: "zlib",                    license: "zlib"),
    .init(name: "libpng",                  license: "libpng"),
    .init(name: "expat",                   license: "MIT"),
]

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PalmSlice")
                            .font(.title2.weight(.semibold))
                        Text("Version \(appVersion)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("An on-device 3D printing slicer. Slicing runs entirely on your device. The only network connection is the optional upload to an OctoPrint server you set up.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                    .padding(.vertical, 4)
                }

                Section("Source & License") {
                    Text("PalmSlice embeds libslic3r (the PrusaSlicer slicing engine) and is distributed, as a derivative work, under the GNU Affero General Public License v3.0. The complete source code is publicly available.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Link(destination: URL(string: "https://github.com/adickin/ISlicer")!) {
                        Label("Source Code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Link(destination: URL(string: "https://github.com/adickin/ISlicer/blob/main/LICENSE.md")!) {
                        Label("AGPL-3.0 License", systemImage: "doc.text")
                    }
                }

                Section("Privacy") {
                    Link(destination: URL(string: "https://github.com/adickin/ISlicer/blob/main/PRIVACY.md")!) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
                }

                Section("Third-Party Licenses") {
                    ForEach(thirdPartyLicenses) { entry in
                        HStack {
                            Text(entry.name)
                                .font(.footnote)
                            Spacer()
                            Text(entry.license)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    AboutView()
}
