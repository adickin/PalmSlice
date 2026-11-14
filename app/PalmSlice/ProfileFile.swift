import Foundation
import SwiftUI

/// Reading and writing a store's JSON file without losing the user's data:
/// a file that won't decode is moved aside before defaults replace it, and
/// failures are reported instead of dropped.
enum ProfileFile {
    enum Loaded<T> {
        case missing
        case loaded(T)
        /// The file didn't decode; it was moved to `backup` (nil if that failed too).
        case unreadable(backup: URL?)
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> Loaded<T> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        if let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(T.self, from: data) {
            return .loaded(value)
        }
        return .unreadable(backup: moveAside(url))
    }

    /// Renames `url` to "<name>.bad-<date>"; returns the new URL.
    static func moveAside(_ url: URL) -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".bad-" + stamp)
        do {
            try FileManager.default.moveItem(at: url, to: backup)
            return backup
        } catch {
            return nil
        }
    }

    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    /// What to tell the user when a store's file couldn't be read.
    static func unreadableMessage(_ what: String, backup: URL?) -> String {
        if let backup {
            return "Your saved \(what) couldn't be read, so the defaults were loaded. " +
                "The old file was kept as \(backup.lastPathComponent) in the app's Documents folder."
        }
        return "Your saved \(what) couldn't be read, so the defaults were loaded."
    }

    static func saveFailedMessage(_ what: String, _ error: Error) -> String {
        "Your \(what) couldn't be saved: \(error.localizedDescription)"
    }
}

/// Shows a store's load or save problem (`storageError`) as an alert.
struct StorageErrorAlert: ViewModifier {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var sliceProfileStore: SliceProfileStore
    @EnvironmentObject private var materialProfileStore: MaterialProfileStore

    private var message: String? {
        profileStore.storageError ?? sliceProfileStore.storageError ?? materialProfileStore.storageError
    }

    func body(content: Content) -> some View {
        content.alert("Saved Profiles",
                      isPresented: Binding(get: { message != nil }, set: { shown in
                          guard !shown else { return }
                          if profileStore.storageError != nil { profileStore.storageError = nil }
                          else if sliceProfileStore.storageError != nil { sliceProfileStore.storageError = nil }
                          else { materialProfileStore.storageError = nil }
                      })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }
}
