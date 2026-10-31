import Foundation
import Security

// MARK: - Settings

/// The kind of print server PalmSlice uploads to.
enum PrintHostType: String, CaseIterable, Identifiable {
    /// OctoPrint's REST API (also accepted by Moonraker's OctoPrint emulation).
    case octoPrint
    /// Klipper's Moonraker API (Mainsail / Fluidd printers, Snapmaker U1).
    case moonraker

    var id: String { rawValue }
    var name: String { self == .octoPrint ? "OctoPrint" : "Moonraker" }
}

/// Print server connection settings. The base URL lives in UserDefaults; the API
/// key lives in the Keychain so it isn't stored in plain text.
final class OctoPrintSettings: ObservableObject {
    static let shared = OctoPrintSettings()

    private static let urlKey = "octoprint.baseURL"
    private static let hostTypeKey = "octoprint.hostType"
    private static let keychainService = "com.adickin.PalmSlice.octoprint"
    private static let keychainAccount = "apiKey"

    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: Self.urlKey) }
    }
    @Published var apiKey: String {
        didSet { Self.saveKeychain(apiKey) }
    }
    @Published var hostType: PrintHostType {
        didSet { UserDefaults.standard.set(hostType.rawValue, forKey: Self.hostTypeKey) }
    }

    /// Moonraker usually runs without an API key on the local network.
    var isConfigured: Bool {
        normalizedBaseURL != nil
            && (hostType == .moonraker || !apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// The base URL with a scheme added (http:// if omitted) and trailing slashes removed.
    var normalizedBaseURL: URL? {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "http://" + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), url.host != nil else { return nil }
        return url
    }

    private init() {
        baseURL = UserDefaults.standard.string(forKey: Self.urlKey) ?? ""
        apiKey  = Self.loadKeychain() ?? ""
        hostType = UserDefaults.standard.string(forKey: Self.hostTypeKey).flatMap(PrintHostType.init) ?? .octoPrint
    }

    private static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: keychainAccount]
    }

    private static func loadKeychain() -> String? {
        var q = keychainQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func saveKeychain(_ value: String) {
        SecItemDelete(keychainQuery as CFDictionary)
        guard !value.isEmpty else { return }
        var q = keychainQuery
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
}

// MARK: - Models

/// A folder on OctoPrint's local storage. `path` is relative to the storage
/// root ("" is the root itself), e.g. "parts/brackets".
struct OctoPrintFolder: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    var children: [OctoPrintFolder]
    var fileCount: Int
}

enum OctoPrintError: LocalizedError {
    case notConfigured
    case invalidResponse
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:   return "OctoPrint isn't set up. Enter its address and API key in OctoPrint settings."
        case .invalidResponse: return "OctoPrint returned an unexpected response."
        case .http(let code, let body):
            switch code {
            case 401, 403: return "OctoPrint rejected the API key (HTTP \(code))."
            case 409:      return "OctoPrint refused the request — a file or folder with that name may already exist, or a print is in progress (HTTP 409)."
            case 415:      return "OctoPrint doesn't accept this file type (HTTP 415)."
            default:       return body.isEmpty ? "OctoPrint returned HTTP \(code)." : "OctoPrint returned HTTP \(code): \(body)"
            }
        }
    }
}

// MARK: - Client

/// What PalmSlice does with a print server: a connection test, the folder
/// tree, new folders and uploads.
protocol PrintHostClient {
    /// The server's name and version; used as a connection test.
    func version() async throws -> String
    /// The root folder (path "") with every subfolder.
    func folderTree() async throws -> OctoPrintFolder
    func createFolder(named name: String, in parentPath: String) async throws
    func upload(fileURL: URL, as fileName: String, to folderPath: String,
                select: Bool, print: Bool,
                progress: @escaping @Sendable (Double) -> Void) async throws
}

enum PrintHost {
    static func client(settings: OctoPrintSettings) throws -> any PrintHostClient {
        guard settings.isConfigured, let url = settings.normalizedBaseURL else {
            throw OctoPrintError.notConfigured
        }
        switch settings.hostType {
        case .octoPrint: return OctoPrintClient(baseURL: url, apiKey: settings.apiKey)
        case .moonraker: return MoonrakerClient(baseURL: url, apiKey: settings.apiKey)
        }
    }
}

/// Minimal OctoPrint REST client: version check, folder listing, folder
/// creation, and file upload to local storage.
/// API reference: https://docs.octoprint.org/en/master/api/files.html
struct OctoPrintClient: PrintHostClient {
    let baseURL: URL
    let apiKey: String

    init(baseURL: URL, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(settings: OctoPrintSettings) throws {
        guard settings.isConfigured, let url = settings.normalizedBaseURL else {
            throw OctoPrintError.notConfigured
        }
        self.init(baseURL: url, apiKey: settings.apiKey)
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 600   // large G-code uploads over slow Wi-Fi
        return URLSession(configuration: cfg)
    }()

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        return req
    }

    private func check(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw OctoPrintError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            var body = String(data: data, encoding: .utf8) ?? ""
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = json["error"] as? String {
                body = err
            }
            throw OctoPrintError.http(http.statusCode, String(body.prefix(200)))
        }
    }

    /// Returns the OctoPrint server version string; used as a connection test.
    func version() async throws -> String {
        let (data, resp) = try await Self.session.data(for: request("api/version"))
        try check(data, resp)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OctoPrintError.invalidResponse
        }
        return (json["text"] as? String) ?? (json["server"] as? String) ?? "OctoPrint"
    }

    /// Fetches the full folder tree of local storage. The returned root folder has path "".
    func folderTree() async throws -> OctoPrintFolder {
        var req = request("api/files/local")
        req.url = URL(string: req.url!.absoluteString + "?recursive=true")
        let (data, resp) = try await Self.session.data(for: req)
        try check(data, resp)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = json["files"] as? [[String: Any]] else {
            throw OctoPrintError.invalidResponse
        }
        let (folders, count) = Self.parseEntries(files)
        return OctoPrintFolder(name: "Local Storage", path: "", children: folders, fileCount: count)
    }

    private static func parseEntries(_ entries: [[String: Any]]) -> ([OctoPrintFolder], Int) {
        var folders: [OctoPrintFolder] = []
        var fileCount = 0
        for e in entries {
            if (e["type"] as? String) == "folder" {
                let kids = (e["children"] as? [[String: Any]]) ?? []
                let (sub, n) = parseEntries(kids)
                folders.append(OctoPrintFolder(name: (e["name"] as? String) ?? "?",
                                               path: (e["path"] as? String) ?? "",
                                               children: sub, fileCount: n))
            } else {
                fileCount += 1
            }
        }
        folders.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return (folders, fileCount)
    }

    /// Creates `name` inside `parentPath` ("" for root).
    func createFolder(named name: String, in parentPath: String) async throws {
        var form = MultipartForm()
        form.addField("foldername", name)
        if !parentPath.isEmpty { form.addField("path", parentPath) }
        var req = request("api/files/local", method: "POST")
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await Self.session.upload(for: req, from: form.finish())
        try check(data, resp)
    }

    /// Uploads `fileURL` as `fileName` into `folderPath` ("" for root).
    /// `progress` is called on an arbitrary thread with values in 0...1.
    func upload(fileURL: URL, as fileName: String, to folderPath: String,
                select: Bool, print: Bool,
                progress: @escaping @Sendable (Double) -> Void) async throws {
        // Build the multipart body on disk so large G-code files don't sit in memory.
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("octoprint-upload-\(UUID().uuidString).multipart")
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var form = MultipartForm()
        if !folderPath.isEmpty { form.addField("path", folderPath) }
        if select { form.addField("select", "true") }
        if print  { form.addField("print", "true") }
        try form.writeFile(to: bodyURL, fieldName: "file", fileName: fileName, contents: fileURL)

        var req = request("api/files/local", method: "POST")
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        let delegate = UploadProgressDelegate(onProgress: progress)
        let (data, resp) = try await Self.session.upload(for: req, fromFile: bodyURL, delegate: delegate)
        try check(data, resp)
    }
}

// MARK: - Moonraker

/// Minimal Moonraker client (Klipper printers, including the Snapmaker U1):
/// server info, the gcodes folder tree, folder creation, upload (optionally
/// starting the print), print status and cancel.
/// API reference: https://moonraker.readthedocs.io/en/latest/web_api/
struct MoonrakerClient: PrintHostClient {
    let baseURL: URL
    let apiKey: String

    init(baseURL: URL, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A print job as Moonraker's print_stats / virtual_sdcard report it.
    struct PrintStatus: Equatable {
        /// standby, printing, paused, complete, cancelled or error.
        var state: String
        var fileName: String
        /// 0…1
        var progress: Double
        var isActive: Bool { state == "printing" || state == "paused" }
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 600
        return URLSession(configuration: cfg)
    }()

    private func request(_ path: String, query: [String: String] = [:], method: String = "GET") -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        return req
    }

    /// The response's "result" object; Moonraker errors carry {"error": {"message": …}}.
    private func result(_ req: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await Self.session.data(for: req)
        return try Self.result(data, resp)
    }

    private static func result(_ data: Data, _ response: URLResponse) throws -> [String: Any] {
        guard let http = response as? HTTPURLResponse else { throw OctoPrintError.invalidResponse }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String)
                ?? String(data: data, encoding: .utf8) ?? ""
            throw OctoPrintError.http(http.statusCode, String(message.prefix(200)))
        }
        guard let result = json?["result"] as? [String: Any] else { throw OctoPrintError.invalidResponse }
        return result
    }

    func version() async throws -> String {
        let info = try await result(request("server/info"))
        let version = info["moonraker_version"] as? String ?? ""
        let klippy = info["klippy_state"] as? String ?? ""
        return "Moonraker \(version)" + (klippy.isEmpty ? "" : " (Klipper \(klippy))")
    }

    func folderTree() async throws -> OctoPrintFolder {
        let (children, count) = try await folders(in: "", depth: 0)
        return OctoPrintFolder(name: "G-code Files", path: "", children: children, fileCount: count)
    }

    private func folders(in path: String, depth: Int) async throws -> ([OctoPrintFolder], Int) {
        let dir = try await result(request("server/files/directory",
                                           query: ["path": path.isEmpty ? "gcodes" : "gcodes/" + path]))
        let files = (dir["files"] as? [[String: Any]])?.count ?? 0
        var children: [OctoPrintFolder] = []
        for entry in (dir["dirs"] as? [[String: Any]]) ?? [] {
            guard let name = entry["dirname"] as? String, !name.hasPrefix(".") else { continue }
            let childPath = path.isEmpty ? name : path + "/" + name
            let (sub, n) = depth < 6 ? try await folders(in: childPath, depth: depth + 1) : ([], 0)
            children.append(OctoPrintFolder(name: name, path: childPath, children: sub, fileCount: n))
        }
        children.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return (children, files)
    }

    func createFolder(named name: String, in parentPath: String) async throws {
        let path = "gcodes/" + (parentPath.isEmpty ? name : parentPath + "/" + name)
        _ = try await result(request("server/files/directory", query: ["path": path], method: "POST"))
    }

    /// Uploads into gcodes/`folderPath`; `print` starts it right away
    /// (Moonraker has no separate "select").
    func upload(fileURL: URL, as fileName: String, to folderPath: String,
                select: Bool, print: Bool,
                progress: @escaping @Sendable (Double) -> Void) async throws {
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("moonraker-upload-\(UUID().uuidString).multipart")
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        var form = MultipartForm()
        form.addField("root", "gcodes")
        if !folderPath.isEmpty { form.addField("path", folderPath) }
        if print { form.addField("print", "true") }
        try form.writeFile(to: bodyURL, fieldName: "file", fileName: fileName, contents: fileURL)
        var req = request("server/files/upload", method: "POST")
        req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        let delegate = UploadProgressDelegate(onProgress: progress)
        let (data, resp) = try await Self.session.upload(for: req, fromFile: bodyURL, delegate: delegate)
        guard let http = resp as? HTTPURLResponse else { throw OctoPrintError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw OctoPrintError.http(http.statusCode, String((String(data: data, encoding: .utf8) ?? "").prefix(200)))
        }
    }

    func printStatus() async throws -> PrintStatus {
        let result = try await result(request("printer/objects/query",
                                              query: ["print_stats": "", "virtual_sdcard": ""]))
        let status = result["status"] as? [String: Any] ?? [:]
        let stats = status["print_stats"] as? [String: Any] ?? [:]
        let sdcard = status["virtual_sdcard"] as? [String: Any] ?? [:]
        return PrintStatus(state: stats["state"] as? String ?? "unknown",
                           fileName: stats["filename"] as? String ?? "",
                           progress: (sdcard["progress"] as? NSNumber)?.doubleValue ?? 0)
    }

    func cancelPrint() async throws {
        _ = try await result(request("printer/print/cancel", method: "POST"))
    }
}

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double) -> Void
    init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

// MARK: - Multipart encoding

private struct MultipartForm {
    let boundary = "PalmSlice-\(UUID().uuidString)"
    private var data = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(_ name: String, _ value: String) {
        data.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
    }

    mutating func finish() -> Data {
        var out = data
        out.append("--\(boundary)--\r\n")
        return out
    }

    /// Writes the accumulated fields, then the file part, then the closing boundary to `url`.
    func writeFile(to url: URL, fieldName: String, fileName: String, contents source: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        let safeName = fileName.replacingOccurrences(of: "\"", with: "'")
        var head = data
        head.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(safeName)\"\r\nContent-Type: application/octet-stream\r\n\r\n")
        try out.write(contentsOf: head)

        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
        try out.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }
}

private extension Data {
    mutating func append(_ s: String) { append(Data(s.utf8)) }
}
