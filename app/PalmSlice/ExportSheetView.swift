import SwiftUI
import UIKit

/// Identifies a sliced G-code file to export. Driving the sheet with an item
/// (rather than a Bool plus a separate URL) guarantees the sheet's content
/// always sees the file it was opened for.
struct ExportRequest: Identifiable {
    let id = UUID()
    let sourceURL: URL
    /// The plate as a PrusaSlicer project (.3mf), if one was written.
    var projectURL: URL? = nil
}

private enum ExportRoute: Hashable {
    case octoPrintFolder(path: String)
    case octoPrintSettings
}

private struct StagedFile: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - Export sheet

/// Shown when the user taps Export: lets them rename the G-code, then save it
/// to Files, share it, or upload it to OctoPrint.
struct ExportSheetView: View {
    let request: ExportRequest

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var octoSettings = OctoPrintSettings.shared
    @StateObject private var browser = OctoPrintBrowserModel()

    @State private var stem: String
    @State private var nav: [ExportRoute] = []
    @State private var saveItem: StagedFile?
    @State private var shareItem: StagedFile?
    @State private var errorMessage: String?
    @State private var savedMessage: String?

    init(request: ExportRequest) {
        self.request = request
        _stem = State(initialValue: request.sourceURL.deletingPathExtension().lastPathComponent)
    }

    /// The final filename, always ending in .gcode, with path separators removed.
    var fileName: String {
        var s = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasSuffix(".gcode") { s = String(s.dropLast(6)) }
        s = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if s.isEmpty { s = request.sourceURL.deletingPathExtension().lastPathComponent }
        return s + ".gcode"
    }

    var body: some View {
        NavigationStack(path: $nav) {
            Form {
                Section {
                    HStack(spacing: 4) {
                        TextField("File name", text: $stem)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .submitLabel(.done)
                        Text(".gcode").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("File Name")
                }

                Section {
                    Button {
                        stage { saveItem = StagedFile(url: $0) }
                    } label: {
                        Label("Save to Files…", systemImage: "folder")
                    }
                    Button {
                        stage { shareItem = StagedFile(url: $0) }
                    } label: {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                    if let project = request.projectURL {
                        Button {
                            do {
                                let name = String(fileName.dropLast(6)) + ".3mf"
                                saveItem = StagedFile(url: try stageExportCopy(of: project, named: name))
                            } catch {
                                errorMessage = "Could not prepare the project: \(error.localizedDescription)"
                            }
                        } label: {
                            Label("Save PrusaSlicer Project (.3mf)…", systemImage: "shippingbox")
                        }
                    }
                } header: {
                    Text("Save")
                }

                Section {
                    if octoSettings.isConfigured {
                        NavigationLink(value: ExportRoute.octoPrintFolder(path: "")) {
                            Label("Send to \(octoSettings.hostType.name)…", systemImage: "printer.dotmatrix")
                        }
                    }
                    NavigationLink(value: ExportRoute.octoPrintSettings) {
                        Label(octoSettings.isConfigured ? "Printer Connection" : "Set Up Printer Connection…",
                              systemImage: "gearshape")
                    }
                    if octoSettings.isConfigured && octoSettings.hostType == .moonraker {
                        MoonrakerStatusRow()
                    }
                } header: {
                    Text("Send to Printer")
                } footer: {
                    if let host = octoSettings.normalizedBaseURL?.host, octoSettings.isConfigured {
                        Text("Uploads to \(host). Choose an existing folder or create a new one.")
                    }
                }
            }
            .navigationTitle("Export G-code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: ExportRoute.self) { route in
                switch route {
                case .octoPrintFolder(let path):
                    OctoPrintFolderView(
                        path: path,
                        model: browser,
                        fileName: fileName,
                        sourceURL: request.sourceURL,
                        openFolder: { nav.append(.octoPrintFolder(path: $0)) },
                        onUploaded: { dest in
                            savedMessage = "Uploaded to \(octoSettings.hostType.name): \(dest)"
                        }
                    )
                case .octoPrintSettings:
                    OctoPrintSettingsView(settings: octoSettings)
                }
            }
        }
        // Drop the cached folder tree if the server changes.
        .onChange(of: octoSettings.baseURL) { _ in browser.root = nil }
        .onChange(of: octoSettings.apiKey) { _ in browser.root = nil }
        .onChange(of: octoSettings.hostType) { _ in browser.root = nil }
        .sheet(item: $saveItem) { item in
            ExportDocumentPicker(url: item.url) { saved in
                if saved { savedMessage = "Saved \(item.url.lastPathComponent)" }
            }
            .ignoresSafeArea()
        }
        .sheet(item: $shareItem) { item in
            ShareSheetView(items: [item.url]).ignoresSafeArea()
        }
        .alert("Export Failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Exported", isPresented: Binding(
            get: { savedMessage != nil },
            set: { if !$0 { savedMessage = nil } }
        )) {
            Button("OK") { dismiss() }
        } message: {
            Text(savedMessage ?? "")
        }
    }

    /// Copies the sliced file to a temp location under the chosen name and
    /// passes the copy on. The original temp slice is left untouched so the
    /// user can export again with a different name.
    private func stage(_ then: (URL) -> Void) {
        do {
            then(try stageExportCopy(of: request.sourceURL, named: fileName))
        } catch {
            errorMessage = "Could not prepare \(fileName): \(error.localizedDescription)"
        }
    }
}

/// Copies `source` into a fresh temp directory as `name`.
func stageExportCopy(of source: URL, named name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("Export", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let dest = dir.appendingPathComponent(name)
    try FileManager.default.copyItem(at: source, to: dest)
    return dest
}

// MARK: - Save to Files picker

/// UIDocumentPickerViewController in export mode: the user chooses where in
/// Files (On My iPhone, iCloud Drive, …) the G-code is saved.
struct ExportDocumentPicker: UIViewControllerRepresentable {
    let url: URL
    let onFinish: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uvc: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: (Bool) -> Void
        init(onFinish: @escaping (Bool) -> Void) { self.onFinish = onFinish }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onFinish(true)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish(false)
        }
    }
}

// MARK: - OctoPrint folder browser

@MainActor
final class OctoPrintBrowserModel: ObservableObject {
    @Published var root: OctoPrintFolder?
    @Published var isLoading = false
    @Published var loadError: String?

    func load(force: Bool = false) async {
        if root != nil && !force { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let client = try PrintHost.client(settings: .shared)
            root = try await client.folderTree()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func folder(at path: String) -> OctoPrintFolder? {
        guard let root else { return nil }
        if path.isEmpty { return root }
        var current = root
        var prefix = ""
        for part in path.split(separator: "/") {
            prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
            guard let next = current.children.first(where: { $0.path == prefix }) else { return nil }
            current = next
        }
        return current
    }

    /// Creates the folder and refreshes the tree; returns the new folder's path.
    func createFolder(named name: String, in parent: String) async throws -> String {
        let client = try PrintHost.client(settings: .shared)
        try await client.createFolder(named: name, in: parent)
        await load(force: true)
        let created = folder(at: parent)?.children.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
        // OctoPrint may sanitize the name (e.g. spaces → underscores); fall back to a best guess.
        return created?.path ?? (parent.isEmpty ? name : parent + "/" + name)
    }
}

private struct OctoPrintFolderView: View {
    let path: String
    @ObservedObject var model: OctoPrintBrowserModel
    let fileName: String
    let sourceURL: URL
    let openFolder: (String) -> Void
    let onUploaded: (String) -> Void

    @AppStorage("octoprint.selectAfterUpload") private var selectAfterUpload = false
    @AppStorage("octoprint.printAfterUpload") private var printAfterUpload = false

    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var uploadProgress: Double?
    @State private var errorMessage: String?

    private var folder: OctoPrintFolder? { model.folder(at: path) }
    private var title: String { path.isEmpty ? OctoPrintSettings.shared.hostType.name : (folder?.name ?? path) }
    private var isUploading: Bool { uploadProgress != nil }

    var body: some View {
        List {
            if let folder {
                Section {
                    if folder.children.isEmpty {
                        Text("No subfolders").foregroundStyle(.secondary)
                    }
                    ForEach(folder.children) { child in
                        Button { openFolder(child.path) } label: {
                            HStack {
                                Label(child.name, systemImage: "folder")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("\(child.fileCount)")
                                    .font(.caption).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    Button {
                        newFolderName = ""
                        showNewFolder = true
                    } label: {
                        Label("New Folder…", systemImage: "folder.badge.plus")
                    }
                } header: {
                    Text(path.isEmpty ? "Local Storage" : "/" + path)
                }

                Section {
                    Toggle("Select file after upload", isOn: $selectAfterUpload)
                    Toggle("Start printing after upload", isOn: $printAfterUpload)
                } footer: {
                    if printAfterUpload {
                        Text("The print will start immediately. Make sure the bed is clear.")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    if let p = uploadProgress {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(p < 1 ? "Uploading \(fileName)…" : "Waiting for the printer…")
                                .font(.subheadline)
                            ProgressView(value: p)
                        }
                    } else {
                        Button {
                            Task { await upload() }
                        } label: {
                            Label("Upload \(fileName) here", systemImage: "arrow.up.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                }
            } else if model.isLoading {
                HStack { Spacer(); ProgressView("Connecting…"); Spacer() }
            } else if let err = model.loadError {
                Section {
                    Text(err).foregroundStyle(.red)
                    Button("Retry") { Task { await model.load(force: true) } }
                }
            } else if model.root != nil {
                Text("This folder no longer exists on the printer.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.load(force: true) } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.isLoading || isUploading)
            }
        }
        .task { await model.load() }
        .refreshable { await model.load(force: true) }
        .disabled(isUploading)
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newFolderName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) {}
            Button("Create") { Task { await createFolder() } }
        } message: {
            Text("Create a folder in \(path.isEmpty ? "Local Storage" : "/" + path).")
        }
        .alert("Upload Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func createFolder() async {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        guard !name.isEmpty else { return }
        do {
            let newPath = try await model.createFolder(named: name, in: path)
            openFolder(newPath)
        } catch {
            errorMessage = "Could not create folder: \(error.localizedDescription)"
        }
    }

    private func upload() async {
        uploadProgress = 0
        defer { uploadProgress = nil }
        do {
            let client = try PrintHost.client(settings: .shared)
            try await client.upload(fileURL: sourceURL, as: fileName, to: path,
                                    select: selectAfterUpload || printAfterUpload,
                                    print: printAfterUpload) { p in
                Task { @MainActor in uploadProgress = p }
            }
            await model.load(force: true)
            onUploaded((path.isEmpty ? "/" : "/" + path + "/") + fileName)
        } catch {
            errorMessage = "Upload failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - OctoPrint settings

struct OctoPrintSettingsView: View {
    @ObservedObject var settings: OctoPrintSettings

    @State private var testState: TestState = .idle

    private enum TestState {
        case idle, testing
        case ok(String)
        case failed(String)
    }

    var body: some View {
        Form {
            Section {
                Picker("Server", selection: $settings.hostType) {
                    ForEach(PrintHostType.allCases) { Text($0.name).tag($0) }
                }
                TextField(settings.hostType == .moonraker ? "http://192.168.1.50" : "http://octopi.local",
                          text: $settings.baseURL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField(settings.hostType == .moonraker ? "API key (optional)" : "API key", text: $settings.apiKey)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Printer Connection")
            } footer: {
                if settings.hostType == .moonraker {
                    Text("For Klipper printers (Mainsail, Fluidd, Snapmaker U1): enter the printer's address. An API key is only needed if Moonraker requires one. It's stored in the iOS Keychain.")
                } else {
                    Text("Enter your OctoPrint address (hostname or IP). Create an API key in OctoPrint under Settings → Application Keys. The key is stored in the iOS Keychain.")
                }
            }

            Section {
                Button {
                    Task { await test() }
                } label: {
                    HStack {
                        Text("Test Connection")
                        Spacer()
                        switch testState {
                        case .idle:    EmptyView()
                        case .testing: ProgressView()
                        case .ok:      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .failed:  Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        }
                    }
                }
                .disabled(!settings.isConfigured)
            } footer: {
                switch testState {
                case .ok(let v):     Text(settings.hostType == .moonraker ? "Connected — \(v)" : "Connected — OctoPrint \(v)")
                case .failed(let m): Text(m).foregroundStyle(.red)
                default:             EmptyView()
                }
            }
        }
        .navigationTitle("Printer Connection")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: settings.hostType) { _ in testState = .idle }
        .onChange(of: settings.baseURL) { _ in testState = .idle }
        .onChange(of: settings.apiKey) { _ in testState = .idle }
    }

    private func test() async {
        testState = .testing
        do {
            let client = try PrintHost.client(settings: settings)
            testState = .ok(try await client.version())
        } catch {
            testState = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Moonraker print status

/// The Moonraker printer's current job, refreshed every few seconds, with Cancel.
private struct MoonrakerStatusRow: View {
    @State private var status: MoonrakerClient.PrintStatus?
    @State private var error: String?
    @State private var confirmCancel = false

    var body: some View {
        HStack {
            Image(systemName: icon).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                if let status, status.isActive {
                    ProgressView(value: status.progress)
                } else if let error {
                    Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            if status?.isActive == true {
                Button("Cancel", role: .destructive) { confirmCancel = true }
                    .buttonStyle(.borderless)
            }
        }
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .confirmationDialog("Cancel the print on the printer?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel Print", role: .destructive) { Task { await cancel() } }
        }
    }

    private var icon: String {
        switch status?.state {
        case "printing": return "printer.fill"
        case "paused": return "pause.circle"
        case "complete": return "checkmark.circle"
        case "error": return "exclamationmark.triangle"
        default: return "printer"
        }
    }

    private var title: String {
        guard let status else { return error == nil ? "Checking printer…" : "Printer unavailable" }
        switch status.state {
        case "printing", "paused":
            return "\(status.state.capitalized) \(status.fileName) — \(Int(status.progress * 100))%"
        case "standby": return "Printer idle"
        default: return "Printer: \(status.state)" + (status.fileName.isEmpty ? "" : " (\(status.fileName))")
        }
    }

    private func client() throws -> MoonrakerClient {
        guard let client = try PrintHost.client(settings: .shared) as? MoonrakerClient else { throw OctoPrintError.notConfigured }
        return client
    }

    private func refresh() async {
        do {
            status = try await client().printStatus()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func cancel() async {
        do {
            try await client().cancelPrint()
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
