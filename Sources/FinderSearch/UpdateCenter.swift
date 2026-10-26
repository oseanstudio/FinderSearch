import SwiftUI
import AppKit

// UPDATES: watch both upstreams and install what they ship, keeping every
// fork feature intact:
//
//   • zeusinsight/FinderSearch — merging upstream/main into the fork's homy
//     branch (scripts/sync-upstream.sh) and rebuilding. Features live in
//     fork-only files, so the merge preserves them by construction.
//   • ARahim3/DigUp — the app update (brew or DMG). The model and index live
//     in DigUp's Application Support folder, untouched by either path.
//
// Checks run on launch, every six hours, and on demand; a badge on the
// toolbar bell and, when the app is not frontmost, a system notification
// announce what is new.

enum GitHubReleases {
    static let finderSearchRepo = "zeusinsight/FinderSearch"
    static let digUpRepo = "ARahim3/DigUp"
    static let apiBase = "https://api.github.com/repos"

    struct Asset: Codable, Equatable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    struct Release: Codable, Equatable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: URL?
        let publishedAt: Date?
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case body
            case htmlURL = "html_url"
            case publishedAt = "published_at"
            case assets
        }

        init(tagName: String, name: String?, body: String?, htmlURL: URL?, publishedAt: Date?, assets: [Asset]) {
            self.tagName = tagName
            self.name = name
            self.body = body
            self.htmlURL = htmlURL
            self.publishedAt = publishedAt
            self.assets = assets
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tagName = try container.decode(String.self, forKey: .tagName)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            body = try container.decodeIfPresent(String.self, forKey: .body)
            htmlURL = try container.decodeIfPresent(URL.self, forKey: .htmlURL)
            publishedAt = try container.decodeIfPresent(Date.self, forKey: .publishedAt)
            assets = try container.decodeIfPresent([Asset].self, forKey: .assets) ?? []
        }

        var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }
    }

    static func latest(repo: String) async throws -> Release {
        guard let url = URL(string: "\(apiBase)/\(repo)/releases/latest") else {
            throw DigUpError("bad release URL")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw DigUpError("GitHub returned an error for \(repo).")
        }
        return try JSONDecoder.standard.decode(Release.self, from: data)
    }

    /// Fetches a release asset to disk, streaming in chunks so even a large
    /// asset never sits in memory. HOMY
    static func download(
        url: URL, to destination: URL,
        progress: @escaping (Double, Int64, Int64) -> Void
    ) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw DigUpError("The download failed (\(status)).")
        }
        let total = (response as? HTTPURLResponse)?.expectedContentLength ?? -1
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
            let handle = try? FileHandle(forWritingTo: destination)
        else {
            throw DigUpError("Could not write the download to disk.")
        }
        defer { try? handle.close() }
        var written: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        let chunkLimit = 1 << 20
        var lastReport = Date.distantPast
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= chunkLimit {
                    try handle.write(contentsOf: buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if Date().timeIntervalSince(lastReport) > 0.1 {
                        lastReport = Date()
                        let known = total > 0
                        progress(known ? Double(written) / Double(total) : 0, written, max(total, 0))
                    }
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
            }
            progress(1, written, total > 0 ? total : written)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

extension JSONDecoder {
    static let standard: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// "1.2.3" ordering; anything non-numeric falls back to a string compare.
func compareVersions(_ left: String, _ right: String) -> ComparisonResult {
    let leftParts = left.split(separator: ".").map(String.init)
    let rightParts = right.split(separator: ".").map(String.init)
    for index in 0..<max(leftParts.count, rightParts.count) {
        let l = index < leftParts.count ? leftParts[index] : "0"
        let r = index < rightParts.count ? rightParts[index] : "0"
        if let ln = Int(l.filter { $0.isNumber }), let rn = Int(r.filter { $0.isNumber }),
            ln != rn
        {
            return ln < rn ? .orderedAscending : .orderedDescending
        }
        if l != r { return l < r ? .orderedAscending : .orderedDescending }
    }
    return .orderedSame
}

enum UpdateKind: String {
    case finderSearch
    case digUp
}

struct UpdateOffer: Identifiable {
    let kind: UpdateKind
    let currentVersion: String?
    let release: GitHubReleases.Release
    var id: String { kind.rawValue }
    var title: String {
        switch kind {
        case .finderSearch: return "FinderSearch \(release.version)"
        case .digUp: return "DigUp \(release.version)"
        }
    }
}

@MainActor final class UpdateCenter: ObservableObject {
    static let shared = UpdateCenter()
    static let checkInterval: TimeInterval = 6 * 3600

    @Published private(set) var offers: [UpdateOffer] = []
    @Published private(set) var checking = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var lastError: String?

    // Install progress, per offer.
    @Published var installKind: UpdateKind?
    @Published var installStage = ""
    @Published var installFraction: Double?
    @Published var installLog: String = ""
    @Published var installFailed = false
    @Published var relaunchReady = false

    private var monitorTask: Task<Void, Never>?

    // MARK: checking

    func startMonitoring() {
        // The update poller belongs to the running app; test hosts that render
        // the browser must not hit GitHub on a timer.
        guard monitorTask == nil,
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        else { return }
        monitorTask = Task {
            try? await Task.sleep(for: .seconds(10))
            while !Task.isCancelled {
                await checkNow()
                try? await Task.sleep(for: .seconds(Self.checkInterval))
            }
        }
    }

    func checkNow() async {
        guard !checking else { return }
        checking = true
        lastError = nil
        defer { checking = false }
        var found: [UpdateOffer] = []
        // Upstream FinderSearch: a release newer than the version this app
        // was built from (the version build.sh stamps into the bundle).
        do {
            let release = try await GitHubReleases.latest(repo: GitHubReleases.finderSearchRepo)
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            if let current, compareVersions(release.version, current) == .orderedDescending {
                found.append(UpdateOffer(kind: .finderSearch, currentVersion: current, release: release))
            }
        } catch {
            lastError = error.localizedDescription
        }
        // DigUp: only when it is installed here; a missing install is setup,
        // not an update.
        if DigUpPaths.locateApp() != nil || DigUpPaths.locateCLI() != nil {
            do {
                let release = try await GitHubReleases.latest(repo: GitHubReleases.digUpRepo)
                let installed = DigUpPaths.locateApp().flatMap(DigUpPaths.appVersion)
                    ?? release.version
                if let installed = installedAsCurrent(installed, release),
                    compareVersions(release.version, installed) == .orderedDescending
                {
                    found.append(UpdateOffer(kind: .digUp, currentVersion: installed, release: release))
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
        lastChecked = Date()
        let known = Set(offers.map(\.id))
        let fresh = found.filter { !known.contains($0.id) }
        offers = found
        if !fresh.isEmpty { announce(fresh) }
    }

    /// A DigUp install without a readable version (ad-hoc builds) cannot be
    /// compared; treat it as current so we never nag.
    private func installedAsCurrent(_ installed: String?, _ release: GitHubReleases.Release) -> String? {
        installed ?? release.version
    }

    private func announce(_ fresh: [UpdateOffer]) {
        NotificationCenter.default.post(name: .homyUpdatesFound, object: nil)
        // UNUserNotificationCenter aborts outside a real .app bundle (tests,
        // dev runs), so attention requests do the alerting instead.
        guard NSApp != nil else { return }
        if NSApp.isActive {
            NotificationCenter.default.post(name: .homyShowUpdates, object: nil)
        } else {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    // MARK: installing

    /// Repo checkout for the sync-and-rebuild path; build.sh writes the marker.
    static var repoRoot: URL? {
        guard
            let resource = Bundle.main.resourceURL,
            let marker = try? String(
                contentsOf: resource.appendingPathComponent("repo-root"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            FileManager.default.fileExists(atPath: marker + "/scripts/build.sh")
        else { return nil }
        return URL(fileURLWithPath: marker, isDirectory: true)
    }

    func install(_ offer: UpdateOffer) {
        guard installKind == nil else { return }
        installKind = offer.kind
        installFailed = false
        relaunchReady = false
        installStage = ""
        installFraction = nil
        installLog = ""
        Task {
            switch offer.kind {
            case .finderSearch:
                await installFinderSearch()
            case .digUp:
                await installDigUp(offer)
            }
        }
    }

    private func appendLog(_ line: String) {
        installLog += line + "\n"
        if installLog.count > 20000 { installLog = String(installLog.suffix(20000)) }
    }

    /// Upstream update: merge upstream/main into homy and rebuild. The fork's
    /// features are separate files with marked integration points, so the
    /// merge keeps them.
    private func installFinderSearch() async {
        guard let repo = Self.repoRoot else {
            installFailed = true
            installStage = "This app was not built from a local checkout."
            return
        }
        installStage = "Merging upstream…"
        do {
            try await runScript("/bin/zsh", ["scripts/sync-upstream.sh"], cwd: repo)
            installStage = "Rebuilding the app…"
            try await runScript("/bin/zsh", ["scripts/build.sh"], cwd: repo)
            installStage = "Rebuilt. Relaunch to pick it up."
            relaunchReady = true
        } catch {
            installFailed = true
            installStage = error.localizedDescription
        }
        installKind = nil
    }

    /// DigUp update: brew when it manages the install, otherwise the release
    /// DMG. Neither touches the model or the index.
    private func installDigUp(_ offer: UpdateOffer) async {
        // Kept on failure so the log can point at a manual-install DMG.
        var keptDownload: URL?
        do {
            appendLog("Updating DigUp to \(offer.release.version)…")
            if let brew = await Self.which("brew") {
                appendLog("Homebrew found at \(brew.path)")
                let listed = try? await runCapture(brew.path, ["list", "--cask", "digup"])
                if (listed?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) == false {
                    installStage = "Upgrading the DigUp cask…"
                    appendLog("brew manages the cask; running upgrade…")
                    try await runScript(
                        brew.path, ["upgrade", "--cask", "digup"], cwd: nil,
                        onLine: { [weak self] in self?.appendLog($0) })
                    installStage = "Updated via Homebrew. The model and index were kept."
                    offers.removeAll { $0.kind == .digUp }
                    DigUpService.shared.shutdown()
                    return
                }
                appendLog("brew does not manage DigUp; installing from the release DMG.")
            } else {
                appendLog("Homebrew not found; installing from the release DMG.")
            }
            guard
                let asset = offer.release.assets.first(where: {
                    $0.name.lowercased().hasSuffix(".dmg")
                })
            else {
                throw DigUpError("The release has no DMG; install it manually from GitHub.")
            }
            installStage = "Closing DigUp if it is running…"
            await quitDigUp()

            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("digup-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            keptDownload = temporary
            installStage = "Downloading \(asset.name)…"
            let dmg = temporary.appendingPathComponent(asset.name)
            appendLog("downloading \(asset.browserDownloadURL.absoluteString)")
            var downloadedBytes: Int64 = 0
            try await GitHubReleases.download(
                url: asset.browserDownloadURL, to: dmg,
                progress: { [weak self] fraction, bytes, _ in
                    Task { @MainActor in
                        self?.installFraction = fraction
                        downloadedBytes = bytes
                    }
                })
            appendLog("downloaded \(GitHubReleases.format(downloadedBytes))")
            installStage = "Mounting…"
            let mount = temporary.appendingPathComponent("mount", isDirectory: true)
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            try await runScript(
                "/usr/bin/hdiutil",
                ["attach", dmg.path, "-nobrowse", "-readonly", "-quiet", "-mountpoint", mount.path],
                cwd: nil,
                onLine: { [weak self] in self?.appendLog($0) })
            installStage = "Installing…"
            guard
                let bundle = (try? FileManager.default.contentsOfDirectory(
                    at: mount, includingPropertiesForKeys: nil))?.first(where: {
                        $0.lastPathComponent == "DigUp.app"
                    })
            else {
                throw DigUpError("DigUp.app was not inside the disk image.")
            }
            // /Applications needs group-admin rights; the user folder always works.
            var destination = URL(fileURLWithPath: "/Applications/DigUp.app")
            do {
                try installAppBundle(bundle, to: destination)
            } catch {
                appendLog("/Applications failed: \(error.localizedDescription)")
                installStage = "Installing to your Applications folder…"
                let homeApplications = URL(
                    fileURLWithPath: NSHomeDirectory() + "/Applications", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: homeApplications, withIntermediateDirectories: true)
                destination = homeApplications.appendingPathComponent("DigUp.app")
                try installAppBundle(bundle, to: destination)
            }
            appendLog("installed at \(destination.path)")
            try? await runScript(
                "/usr/bin/hdiutil", ["detach", mount.path, "-quiet"], cwd: nil,
                onLine: { [weak self] in self?.appendLog($0) })
            try? FileManager.default.removeItem(at: temporary)
            keptDownload = nil
            finishDigUpInstall("Updated. The model and index were kept.")
        } catch {
            installFailed = true
            installStage = error.localizedDescription
            appendLog("failed: \(error.localizedDescription)")
            if let keptDownload {
                appendLog("The downloaded disk image is still at \(keptDownload.path) — "
                    + "you can install it by double-clicking.")
            }
        }
        installKind = nil
    }

    private func installAppBundle(_ bundle: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: bundle, to: destination)
    }

    /// Drop the offer and forget the old helper process (it respawns from the
    /// new binary on the next search).
    private func finishDigUpInstall(_ message: String) {
        installStage = message
        offers.removeAll { $0.kind == .digUp }
        DigUpService.shared.shutdown()
    }

    /// Quits DigUp without launching it (a bare `tell … to quit` starts it),
    /// then makes sure it is really gone before its bundle is replaced.
    private func quitDigUp() async {
        appendLog("closing DigUp if it is running…")
        let script =
            "if application \"DigUp\" is running then\ntell application \"DigUp\" to quit saving no\nend if"
        try? await runScript("/usr/bin/osascript", ["-e", script], cwd: nil)
        for _ in 0..<15 {
            if !Self.digUpRunning() { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        if Self.digUpRunning() {
            appendLog("DigUp stayed up; asking it to stop.")
            try? await runScript("/usr/bin/pkill", ["-x", "DigUp"], cwd: nil)
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private nonisolated static func digUpRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "DigUp"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 && !data.isEmpty
        } catch {
            return false
        }
    }

    func relaunchFork() {
        guard let repo = Self.repoRoot else { return }
        let fresh = repo.appendingPathComponent("dist/Hearth.app")
        // HOMY: when Hearth runs from Applications (the Full Disk Access
        // flow installs it there), refresh that copy and relaunch into it —
        // otherwise the user would bounce back to the repo build.
        let installed = Bundle.main.bundleURL
        if FullDiskAccess.isInApplications(installed.path),
            installed.lastPathComponent == "Hearth.app"
        {
            do {
                if FileManager.default.fileExists(atPath: installed.path) {
                    try FileManager.default.removeItem(at: installed)
                }
                try FileManager.default.copyItem(at: fresh, to: installed)
                NSWorkspace.shared.open(installed)
            } catch {
                NSWorkspace.shared.open(fresh)
            }
        } else {
            NSWorkspace.shared.open(fresh)
        }
        NSApp.terminate(nil)
    }

    // MARK: process helpers

    /// HOMY: the blocking reads run detached — `brew list` alone stalls the
    /// main actor for a second or two.
    static func which(_ name: String) async -> URL? {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            process.arguments = [name]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }
                let path = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !path.isEmpty else { return nil }
                return URL(fileURLWithPath: path)
            } catch {
                return nil
            }
        }.value
    }

    private func runCapture(_ path: String, _ arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    /// Streams a script's output into the log, line by line. The PATH keeps
    /// the usual tool homes (brew, cargo) because Finder launches get a bare
    /// environment.
    private func runScript(
        _ path: String, _ arguments: [String], cwd: URL?,
        onLine: ((String) -> Void)? = nil
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-c", ([path] + arguments).map { "'\($0)'" }.joined(separator: " ")]
        if let cwd { process.currentDirectoryURL = cwd }
        let home = NSHomeDirectory()
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": "/opt/homebrew/bin:/usr/local/bin:\(home)/.cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        ]) { _, new in new }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let collector = OutputCollector()
        await collectOutput(output.fileHandleForReading, into: collector)
        for line in collector.lines {
            appendLog(line)
            onLine?(line)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DigUpError("The command failed (status \(process.terminationStatus)). See the log.")
        }
    }

    private nonisolated func collectOutput(_ handle: FileHandle, into collector: OutputCollector) async {
        await Task.detached(priority: .utility) {
            collector.store(handle.readDataToEndOfFile())
        }.value
    }

    /// Gathers process output off the main actor, split into lines.
    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        var lines: [String] {
            lock.lock(); defer { lock.unlock() }
            return text.split(separator: "\n").map(String.init)
        }
        func store(_ data: Data) {
            lock.lock(); text += String(decoding: data, as: UTF8.self); lock.unlock()
        }
    }
}

extension Notification.Name {
    static let homyUpdatesFound = Notification.Name("homy.updatesFound")
    static let homyShowUpdates = Notification.Name("homy.showUpdates")
}

// MARK: - UI

struct UpdatesSheet: View {
    @ObservedObject private var center = UpdateCenter.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Updates", systemImage: "arrow.down.circle")
                    .font(.headline)
                Spacer()
                if center.checking { ProgressView().controlSize(.small) }
                Button("Check Now") { Task { await center.checkNow() } }
                    .disabled(center.checking || center.installKind != nil)
                Button {  // HOMY: sheets on macOS ship no close control of their own
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close")
            }.padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = center.lastError {
                        Text("GitHub check failed: \(error)")
                            .font(.caption).foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                    if center.offers.isEmpty && !center.checking {
                        ContentUnavailableView(
                            "Everything Is Current",
                            systemImage: "checkmark.seal",
                            description: Text(
                                "FinderSearch and DigUp have no new releases right now.")
                        )
                    }
                    ForEach(center.offers) { offer in
                        UpdateOfferRow(offer: offer)
                    }
                    if !center.installStage.isEmpty || center.installKind != nil {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                if center.installKind != nil { ProgressView().controlSize(.small) }
                                Text(center.installStage)
                                    .font(.callout)
                                    .foregroundStyle(center.installFailed ? .orange : .primary)
                                    .textSelection(.enabled)
                            }
                            if let fraction = center.installFraction {
                                ProgressView(value: fraction)
                            }
                            if !center.installLog.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    ScrollView {
                                        Text(center.installLog)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }.frame(maxHeight: 160)
                                    HStack {
                                        Spacer()
                                        Button("Copy Log") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(
                                                center.installLog, forType: .string)
                                        }.controlSize(.small)
                                    }
                                }
                                .padding(8)
                                .background(Color(nsColor: .textBackgroundColor))
                                .cornerRadius(6)
                            }
                            if center.relaunchReady {
                                Button("Relaunch Now") { center.relaunchFork() }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                    if center.lastChecked != nil {
                        Text("Checked \(center.lastChecked!, style: .relative) ago")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }.padding(14)
            }
        }.frame(minWidth: 520, minHeight: 420)
            .task { await center.checkNow() }
    }
}

struct UpdateOfferRow: View {
    let offer: UpdateOffer
    @ObservedObject private var center = UpdateCenter.shared

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(
                systemName: offer.kind == .finderSearch
                    ? "arrow.triangle.branch" : "app.badge.fill"
            ).font(.system(size: 20)).foregroundStyle(Color.accentColor).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(offer.title).font(.headline)
                if let current = offer.currentVersion {
                    Text("installed: \(current)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let body = offer.release.body, !body.isEmpty {
                    Text(body.split(separator: "\n").prefix(4).joined(separator: "\n"))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                if offer.kind == .finderSearch {
                    Text(
                        "Installs by merging upstream and rebuilding — your fork features are kept."
                    ).font(.caption2).foregroundStyle(.tertiary)
                } else {
                    Text("The model and the index are kept.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button("Install") { center.install(offer) }
                .buttonStyle(.borderedProminent)
                .disabled(center.installKind != nil || offer.kind == .finderSearch && UpdateCenter.repoRoot == nil)
            if let url = offer.release.htmlURL {
                Link("Notes", destination: url)
            }
        }.padding(12)
            .background(
                RoundedRectangle(cornerRadius: HomyTheme.shared.cardRadius)
                    .fill(HomyTheme.shared.cardFill))
    }
}
