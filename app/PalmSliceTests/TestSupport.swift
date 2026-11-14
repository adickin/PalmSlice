import XCTest

/// Test files in the repo (Fixtures/), found from this source file.
enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
}

extension XCTestCase {
    /// A new, empty directory for this test's files, deleted when the test
    /// ends, so no file carries over to another run whatever it's named.
    func scratchDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
}

extension XCTestCase {
    /// Settings of the test's own, removed when it ends: stores made with
    /// these and a scratchDir() leave the app's own data alone.
    func scratchDefaults() -> UserDefaults {
        let name = "test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
}
