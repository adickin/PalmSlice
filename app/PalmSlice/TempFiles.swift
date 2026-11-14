import Foundation

/// The app's temp folder holds imported model copies (`<uuid>_<name>`,
/// `import-*`, `drop-*`), painting copies (`paint-*`), sliced output and
/// export staging (`Export/`). None of it outlives the session, so it's
/// cleared at launch, and files are deleted once nothing uses them.
enum TempFiles {
    static var root: URL { FileManager.default.temporaryDirectory }

    /// Deletes everything left in the temp folder by an earlier session.
    static func clearAtLaunch() {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: url)
        }
    }

    /// The files a model reads from.
    static func files(of model: PlacedModel) -> Set<URL> {
        var urls: Set<URL> = [model.url.standardizedFileURL]
        if let native = model.nativeURL { urls.insert(native.standardizedFileURL) }
        for part in model.parts { if let mesh = part.meshURL { urls.insert(mesh.standardizedFileURL) } }
        return urls
    }

    /// Deletes the temp files of `removed` that none of `remaining` uses, and
    /// the per-import folders left empty. Copies of a model share its files.
    static func remove(filesOf removed: [PlacedModel], keeping remaining: [PlacedModel]) {
        let inUse = remaining.reduce(into: Set<URL>()) { $0.formUnion(files(of: $1)) }
        let unused = removed.reduce(into: Set<URL>()) { $0.formUnion(files(of: $1)) }.subtracting(inUse)
        delete(Array(unused))
    }

    /// Deletes temp files (never anything outside the temp folder), then their
    /// folders if they're now empty per-import folders.
    static func delete(_ urls: [URL]) {
        let fm = FileManager.default
        let base = root.standardizedFileURL.path
        for url in urls where url.standardizedFileURL.path.hasPrefix(base) {
            try? fm.removeItem(at: url)
            let dir = url.deletingLastPathComponent()
            let name = dir.lastPathComponent
            if dir.standardizedFileURL.path != base,
               ["import-", "paint-", "drop-"].contains(where: name.hasPrefix),
               (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
                try? fm.removeItem(at: dir)
            }
        }
    }
}
