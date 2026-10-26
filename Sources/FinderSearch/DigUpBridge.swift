import Foundation
import AppKit

// DIGUP: bridge to DigUp (https://github.com/ARahim3/DigUp), the on-device
// semantic file search. This fork drives DigUp's documented CLI surfaces —
// never its internals — so a DigUp update keeps working as long as the CLI
// stays compatible:
//
//   • `digup search-service` (JSON lines)  → live searches with a warm encoder
//   • `digup index-service` (JSON lines)   → indexing with progress events
//   • `digup download-model` (JSON lines)  → model fetch, skipped when complete
//
// The model and the index live in DigUp's own Application Support folder, so
// an existing DigUp installation is reused as-is: nothing is downloaded or
// re-indexed unless it is genuinely missing.

enum DigUpPaths {
    static let appSupport = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/DigUp", isDirectory: true)
    /// DigUp's own index (AppPaths.defaultIndex in DigUpKit): shared, never copied.
    static let defaultIndex = appSupport.appendingPathComponent("index.noindex", isDirectory: true)
    /// DigUp's model folder (ModelFiles.installed): shared, never re-downloaded.
    static let models = appSupport.appendingPathComponent("Models", isDirectory: true)

    static func appBundles() -> [URL] {
        ["/Applications", NSHomeDirectory() + "/Applications"].map {
            URL(fileURLWithPath: $0 + "/DigUp.app", isDirectory: true)
        }
    }

    static func cliCandidates() -> [URL] {
        var urls: [URL] = []
        // getenv, not ProcessInfo: it sees overrides set after launch (tests).
        if let override = getenv("DIGUP_CLI") {
            urls.append(URL(fileURLWithPath: String(cString: override)))
        }
        for app in appBundles() {
            urls.append(app.appendingPathComponent("Contents/Helpers/digup"))
        }
        urls += [
            URL(fileURLWithPath: "/opt/homebrew/bin/digup"),
            URL(fileURLWithPath: "/usr/local/bin/digup"),
            URL(fileURLWithPath: NSHomeDirectory() + "/.local/bin/digup"),
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                urls.append(URL(fileURLWithPath: dir + "/digup"))
            }
        }
        return urls
    }

    static func locateCLI() -> URL? {
        cliCandidates().first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func locateApp() -> URL? {
        appBundles().first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func appVersion(_ app: URL) -> String? {
        Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// The model ships as llama.cpp weights; any .gguf in the Models folder
    /// means it is already there (DigUp verifies the pieces itself when asked).
    static var modelPresent: Bool {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: models, includingPropertiesForKeys: nil)) ?? []
        return contents.contains { $0.pathExtension.lowercased() == "gguf" }
    }

    static var indexPresent: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: defaultIndex.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

/// Folders DigUp.app itself was told to index (its defaults domain, key
/// "roots"). Reading them lets this fork search exactly what the user already
/// indexed in DigUp, with no second list to maintain.
enum DigUpSharedSettings {
    static let domain = "com.abdurrahim.DigUp"

    static var roots: [String] {
        guard let defaults = UserDefaults(suiteName: domain) else { return [] }
        return (defaults.stringArray(forKey: "roots") ?? []).filter { $0.hasPrefix("/") }
    }
}

/// The hit's `info` field: usually a string, sometimes a dictionary of
/// segment details ({"chars": "79"} or {"height": "1000"}). Stored ready to
/// display either way.
enum DigUpInfo: Hashable, Decodable {
    case text(String)
    case fields([String: String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
            return
        }
        if let strings = try? container.decode([String: String].self) {
            self = .fields(strings)
            return
        }
        if let numbers = try? container.decode([String: Int].self) {
            self = .fields(numbers.mapValues(String.init))
            return
        }
        self = .text("")
    }

    var label: String {
        switch self {
        case .text(let text): return text
        case .fields(let fields):
            return fields.sorted { $0.key < $1.key }.map { "\($0): \($1)" }
                .joined(separator: ", ")
        }
    }
}

/// One search result. Fields are optional on purpose: DigUp may add fields at
/// any release, and an older index omits what newer files carry.
struct DigUpHit: Identifiable, Decodable, Hashable {
    let path: String
    let kind: String
    let segment: String
    let segmentID: Int64?
    let score: Double
    let modified: Double
    let size: Int64
    let info: DigUpInfo
    let z: Double?
    let cosine: Double?
    let keywordRank: Int?
    let loc: Double?
    let locEnd: Double?
    let focus: Double?
    let excerpt: String?

    enum CodingKeys: String, CodingKey {
        case path, kind, segment
        case segmentID = "segment_id"
        case score, modified, size, info, z, cosine
        case keywordRank = "keyword_rank"
        case loc
        case locEnd = "loc_end"
        case focus, excerpt
    }

    init(
        path: String, kind: String, segment: String, segmentID: Int64?, score: Double,
        modified: Double, size: Int64, info: DigUpInfo, z: Double?, cosine: Double?,
        keywordRank: Int?, loc: Double?, locEnd: Double?, focus: Double?, excerpt: String?
    ) {
        self.path = path
        self.kind = kind
        self.segment = segment
        self.segmentID = segmentID
        self.score = score
        self.modified = modified
        self.size = size
        self.info = info
        self.z = z
        self.cosine = cosine
        self.keywordRank = keywordRank
        self.loc = loc
        self.locEnd = locEnd
        self.focus = focus
        self.excerpt = excerpt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
        segment = try container.decodeIfPresent(String.self, forKey: .segment) ?? ""
        segmentID = try container.decodeIfPresent(Int64.self, forKey: .segmentID)
        score = try container.decodeIfPresent(Double.self, forKey: .score) ?? 0
        modified = try container.decodeIfPresent(Double.self, forKey: .modified) ?? 0
        size = try container.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        info = try container.decodeIfPresent(DigUpInfo.self, forKey: .info) ?? .text("")
        z = try container.decodeIfPresent(Double.self, forKey: .z)
        cosine = try container.decodeIfPresent(Double.self, forKey: .cosine)
        keywordRank = try container.decodeIfPresent(Int.self, forKey: .keywordRank)
        loc = try container.decodeIfPresent(Double.self, forKey: .loc)
        locEnd = try container.decodeIfPresent(Double.self, forKey: .locEnd)
        focus = try container.decodeIfPresent(Double.self, forKey: .focus)
        excerpt = try container.decodeIfPresent(String.self, forKey: .excerpt)
    }

    var id: String { path + "#" + (segmentID.map(String.init) ?? segment) }
    var name: String { (path as NSString).lastPathComponent }
    var parent: String { (path as NSString).deletingLastPathComponent }
    var asHit: Hit {
        Hit(
            path: path, kind: "file",
            size: UInt64(max(0, size)),
            mtime: UInt64(max(0, modified)), score: 0)
    }

    var kindLabel: String {
        switch kind {
        case "screenshot": return "Screenshot"
        case "image": return "Image"
        case "pdf": return "PDF"
        case "doc": return "Document"
        case "audio": return "Audio"
        case "video": return "Video"
        default: return kind.capitalized
        }
    }

    /// Where in the file the match is, in the CLI's own words (main.swift's
    /// location()): a page, a moment, a part, lines, cells, or image text.
    var locationLabel: String {
        switch segment {
        case "page", "pageImage":
            return loc.map { "p. \(Int($0))" } ?? ""
        case "audio":
            return loc.map { "at \(Self.clock($0)) (sound)" } ?? ""
        case "frame":
            return loc.map { "at \(Self.clock($0))" } ?? ""
        case "chunk":
            return loc.map { "part \(Int($0))" } ?? ""
        case "lines":
            guard let loc else { return "" }
            return locEnd.map { "lines \(Int(loc))–\(Int($0))" } ?? "line \(Int(loc))"
        case "cells":
            guard let loc else { return "" }
            return locEnd.map { "cells \(Int(loc))–\(Int($0))" } ?? "cell \(Int(loc))"
        case "ocr":
            return "text in image"
        default:
            return ""
        }
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A long-lived `digup search-service` process: the index stays open and the
/// query encoder stays warm, so a search costs tens of milliseconds, not a
/// process start. One JSON request per line in, one JSON reply per line out.
@MainActor final class DigUpService: ObservableObject {
    static let shared = DigUpService()

    @Published private(set) var connected = false
    @Published private(set) var encoderState = "stopped"
    @Published private(set) var vectors = 0
    @Published private(set) var files = 0
    @Published private(set) var searchable = 0
    @Published private(set) var lastError: String?

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var roots: [String] = []

    var cliURL: URL? { DigUpPaths.locateCLI() }
    var isInstalled: Bool { cliURL != nil }

    /// Roots for the service: what this fork chose, plus what DigUp.app was
    /// already indexing. An existing DigUp setup needs no re-configuration.
    static func effectiveRoots() -> [String] {
        var seen = Set<String>()
        let stored = UserDefaults.standard.stringArray(forKey: "homy.digup.roots") ?? []
        return (DigUpSharedSettings.roots + stored)
            .filter { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
            .filter { seen.insert($0).inserted }
    }

    // MARK: lifecycle

    private func spawn() throws {
        guard let cli = cliURL else {
            throw DigUpError("DigUp is not installed. Install it from the Describe Contents page.")
        }
        let process = Process()
        process.executableURL = cli
        process.arguments = ["search-service"] + roots + ["--encoder-idle", "900"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.teardown() }
        }
        try process.run()
        self.process = process
        self.input = input.fileHandleForWriting
        self.output = output.fileHandleForReading
        buffer.removeAll()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { @MainActor [weak self] in self?.consume(chunk) }
        }
        connected = true
        lastError = nil
    }

    private func teardown() {
        output?.readabilityHandler = nil
        process = nil
        input = nil
        output = nil
        buffer.removeAll()
        connected = false
        let waiters = pending
        pending = [:]
        for (_, continuation) in waiters {
            continuation.resume(throwing: DigUpError("DigUp stopped."))
        }
    }

    func shutdown() {
        if connected {
            Task { _ = try? await request(["op": "quit"], timeout: 2) }
        }
        process?.terminate()
        teardown()
    }

    /// Point the service at a new folder set; restarts it when it is not
    /// running yet. The folders op applies live otherwise.
    func setRoots(_ newRoots: [String]) {
        roots = newRoots
        guard connected else { return }
        if process?.isRunning == true {
            Task {
                _ = try? await request(["op": "folders", "roots": roots], timeout: 5)
                await refreshStatus()
            }
        } else {
            teardown()
        }
    }

    func prewarm() {
        guard connected || cliURL != nil else { return }
        Task {
            if ensureConnected() {
                _ = try? await request(["op": "prewarm"], timeout: 90)
                await refreshStatus()
            }
        }
    }

    /// After indexing changed the index underneath the service.
    func reload() {
        guard connected else { return }
        Task {
            _ = try? await request(["op": "reload"], timeout: 30)
            await refreshStatus()
        }
    }

    @discardableResult
    func refreshStatus() async -> Bool {
        guard ensureConnected() else { return false }
        do {
            let reply = try await request(["op": "status"], timeout: 10)
            applyStatus(reply)
            return true
        } catch {
            return false
        }
    }

    private func applyStatus(_ reply: [String: Any]) {
        encoderState = reply["encoder"] as? String ?? "stopped"
        vectors = reply["vectors"] as? Int ?? 0
        files = reply["files"] as? Int ?? 0
        searchable = reply["searchable"] as? Int ?? 0
    }

    private func ensureConnected() -> Bool {
        if connected, process?.isRunning == true { return true }
        teardown()
        do {
            roots = Self.effectiveRoots()
            try spawn()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: requests

    private func request(_ fields: [String: Any], timeout: Double = 60) async throws -> [String: Any] {
        let id = nextID
        nextID += 1
        var payload = fields
        payload["id"] = id
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try input?.write(contentsOf: data + Data([10]))
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, let continuation = self.pending.removeValue(forKey: id) else {
                    return
                }
                continuation.resume(throwing: DigUpError("DigUp did not answer in \(Int(timeout)) s."))
            }
        }
    }

    func search(_ text: String, kinds: [String], limit: Int = 40) async throws -> (
        hits: [DigUpHit], meaning: Bool, strong: Int, embedMS: Int, searchMS: Int
    ) {
        guard ensureConnected() else {
            throw DigUpError(lastError ?? "DigUp is not available.")
        }
        var fields: [String: Any] = [
            "op": "search", "q": text, "limit": limit, "meaning": true,
        ]
        if !kinds.isEmpty { fields["kinds"] = kinds }
        let reply = try await request(fields)
        applyStatus(["encoder": (reply["meaning"] as? Bool == true ? "ready" : encoderState)])
        let rows = reply["hits"] as? [[String: Any]] ?? []
        let hitData = try JSONSerialization.data(withJSONObject: rows)
        let hits = (try? JSONDecoder().decode([DigUpHit].self, from: hitData)) ?? []
        let ms = reply["ms"] as? [String: Any]
        return (
            hits, reply["meaning"] as? Bool ?? false, reply["strong"] as? Int ?? 0,
            ms?["embed"] as? Int ?? 0, ms?["search"] as? Int ?? 0
        )
    }

    /// Ask the encoder to embed while the user is still typing, so the pause's
    /// vector is usually ready by the time a search runs.
    func embedAhead(_ text: String) {
        guard connected, !text.isEmpty else { return }
        Task { _ = try? await request(["op": "embed_ahead", "q": text], timeout: 30) }
    }

    /// HOMY: the service's render op — a JPEG of the exact matched PDF page
    /// or video moment, cached beside the index until the service restarts.
    /// Returns nil for kinds it cannot render.
    func render(path: String, kind: String, loc: Double?, pixels: Int) async -> NSImage? {
        guard ensureConnected() else { return nil }
        var fields: [String: Any] = ["op": "render", "path": path, "kind": kind, "pixels": pixels]
        if let loc { fields["loc"] = loc }
        guard
            let reply = try? await request(fields, timeout: 60),
            let imagePath = reply["image"] as? String
        else { return nil }
        return NSImage(contentsOfFile: imagePath)
    }

    // MARK: stdout

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }
            if let id = object["id"] as? Int {
                guard let continuation = pending.removeValue(forKey: id) else { continue }
                if let failure = object["error"] as? String {
                    continuation.resume(throwing: DigUpError(failure))
                } else {
                    continuation.resume(returning: object)
                }
            } else if let event = object["event"] as? String {
                handleEvent(event, object)
            }
        }
    }

    private func handleEvent(_ event: String, _ object: [String: Any]) {
        switch event {
        case "encoder":
            encoderState = object["state"] as? String ?? encoderState
        case "exit":
            teardown()
        default:
            break
        }
    }
}

struct DigUpError: LocalizedError {
    let description: String
    init(_ description: String) { self.description = description }
    var errorDescription: String? { description }
}
