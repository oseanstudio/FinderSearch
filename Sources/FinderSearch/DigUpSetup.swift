import SwiftUI
import AppKit

// DIGUP: setup and maintenance — install DigUp from its GitHub releases when
// it is missing, fetch the model only when it is genuinely absent, run
// indexing through `digup index-service`, and manage which folders are
// searched. An existing DigUp installation is detected and reused as-is:
// same model, same index, same folder list.

struct DigUpInstallState {
    var cliURL: URL?
    var appURL: URL?
    var appVersion: String?
    var modelPresent: Bool
    var indexPresent: Bool

    static func detect() -> DigUpInstallState {
        let app = DigUpPaths.locateApp()
        return DigUpInstallState(
            cliURL: DigUpPaths.locateCLI(),
            appURL: app,
            appVersion: app.flatMap(DigUpPaths.appVersion),
            modelPresent: DigUpPaths.modelPresent,
            indexPresent: DigUpPaths.indexPresent)
    }

    /// Everything the search needs: the CLI (inside DigUp.app), the model,
    /// and an index folder. Indexing may still be pending, but the pieces exist.
    var ready: Bool { cliURL != nil && modelPresent && indexPresent }

    var summary: String {
        var parts: [String] = []
        if let version = appVersion { parts.append("DigUp \(version)") }
        parts.append(modelPresent ? "model installed" : "model not downloaded")
        parts.append(indexPresent ? "index present" : "no index yet")
        return parts.joined(separator: " · ")
    }
}

@MainActor final class DigUpSetupModel: ObservableObject {
    @Published var state: DigUpInstallState?
    @Published var installing = false
    @Published var installStage = ""
    @Published var downloadFraction: Double?
    @Published var downloadDetail = ""
    @Published var error: String?

    func refresh() async {
        state = DigUpInstallState.detect()
    }

    // MARK: install DigUp from its latest GitHub release

    func installFromGitHub() async {
        guard !installing else { return }
        installing = true
        error = nil
        defer { installing = false; installStage = ""; downloadFraction = nil }
        do {
            installStage = "Looking up the latest DigUp release…"
            let release = try await GitHubReleases.latest(repo: GitHubReleases.digUpRepo)
            guard
                let asset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") })
            else {
                throw DigUpError("The latest DigUp release has no DMG to install.")
            }
            // DigUp.app must not be running while it is replaced.
            installStage = "Closing DigUp if it is running…"
            let quit = Process()
            quit.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            quit.arguments = ["-e", "tell application \"DigUp\" to quit saving no"]
            try? quit.run()
            quit.waitUntilExit()

            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("digup-install-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }

            installStage = "Downloading \(asset.name)…"
            let dmg = temporary.appendingPathComponent(asset.name)
            try await GitHubReleases.download(
                url: asset.browserDownloadURL, to: dmg,
                progress: { fraction, bytes, total in
                    Task { @MainActor in
                        self.downloadFraction = fraction
                        self.downloadDetail = "\(GitHubReleases.format(bytes)) of \(GitHubReleases.format(total))"
                    }
                })
            installStage = "Mounting the disk image…"
            let mount = temporary.appendingPathComponent("mount", isDirectory: true)
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            try runTool("/usr/bin/hdiutil", [
                "attach", dmg.path, "-nobrowse", "-readonly", "-quiet",
                "-mountpoint", mount.path,
            ])
            defer { detachSilently(mount) }

            guard
                let bundle = (try? FileManager.default.contentsOfDirectory(
                    at: mount, includingPropertiesForKeys: nil))?.first(where: {
                        $0.pathExtension == "app" && $0.lastPathComponent == "DigUp.app"
                    })
            else {
                throw DigUpError("DigUp.app was not inside the disk image.")
            }
            installStage = "Copying DigUp.app to /Applications…"
            let destination = URL(fileURLWithPath: "/Applications/DigUp.app")
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: bundle, to: destination)
            installStage = "Installed."
            await refresh()
        } catch {
            self.error = error.localizedDescription
            await refresh()
        }
    }

    // MARK: model

    /// `digup download-model` checks the Models folder first and skips every
    /// file already there (it also copies from the Hugging Face cache), so
    /// this never re-downloads an existing model — it completes the missing
    /// pieces only.
    func downloadModel() async {
        guard let cli = state?.cliURL ?? DigUpPaths.locateCLI(), !installing else { return }
        installing = true
        error = nil
        downloadFraction = 0
        defer { installing = false; installStage = ""; downloadFraction = nil }
        do {
            try await runProcess(cli, ["download-model"]) { line in
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any], let event = object["event"] as? String else { return }
                switch event {
                case "progress":
                    let bytes = object["all_bytes"] as? Int64 ?? 0
                    let total = object["all_total"] as? Int64 ?? 1
                    Task { @MainActor in
                        self.downloadFraction = Double(bytes) / Double(max(1, total))
                        self.downloadDetail =
                            "\(GitHubReleases.format(bytes)) of \(GitHubReleases.format(total))"
                    }
                case "file":
                    if let name = object["name"] as? String, let from = object["from"] as? String {
                        Task { @MainActor in self.installStage = "Fetching \(name) (\(from))…" }
                    }
                case "verifying":
                    Task { @MainActor in self.installStage = "Verifying…" }
                case "done":
                    Task { @MainActor in self.installStage = "Model ready." }
                case "error":
                    let message = object["message"] as? String ?? "the model download failed"
                    Task { @MainActor in self.error = message }
                default:
                    break
                }
            }
            await refresh()
        } catch {
            self.error = error.localizedDescription
            await refresh()
        }
    }

    /// Create the index folder by asking DigUp for its status once; indexing
    /// itself is a user action (Sync Now), never a side effect.
    func ensureIndexFolder() {
        try? FileManager.default.createDirectory(at: DigUpPaths.defaultIndex, withIntermediateDirectories: true)
        Task { await refresh() }
    }

    // MARK: tool helpers

    @discardableResult
    private func runTool(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw DigUpError(text.split(separator: "\n").last.map(String.init) ?? "\(path) failed")
        }
        return text
    }

    /// Fire-and-forget cleanup: detaching must work from a defer, so it cannot
    /// await.
    private func detachSilently(_ mount: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mount.path, "-quiet"]
        try? process.run()
    }

    /// Runs a tool to completion, feeding stdout lines to the handler as they
    /// arrive (the model download reports progress this way).
    @discardableResult
    private func runProcess(
        _ executable: URL, _ arguments: [String],
        onLine: @escaping @MainActor (String) -> Void
    ) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        final class LineSplitter: @unchecked Sendable {
            private let lock = NSLock()
            private var buffer = Data()
            func feed(_ chunk: Data, emit: (String) -> Void) {
                lock.lock()
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    emit(String(decoding: buffer.prefix(upTo: newline), as: UTF8.self))
                    buffer.removeSubrange(...newline)
                }
                lock.unlock()
            }
            func flush(emit: (String) -> Void) {
                lock.lock()
                if !buffer.isEmpty { emit(String(decoding: buffer, as: UTF8.self)) }
                buffer.removeAll()
                lock.unlock()
            }
        }
        let splitter = LineSplitter()
        for pipe in [output, errors] {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                splitter.feed(chunk) { line in
                    let line = line
                    Task { @MainActor in onLine(line) }
                }
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                finished.wait()
                continuation.resume()
            }
        }
        for pipe in [output, errors] { pipe.fileHandleForReading.readabilityHandler = nil }
        splitter.flush { line in
            Task { @MainActor in onLine(line) }
        }
        // Give the just-enqueued line tasks a beat to run.
        try? await Task.sleep(for: .milliseconds(50))
        guard process.terminationStatus == 0 else {
            throw DigUpError("\(executable.lastPathComponent) exited with status \(process.terminationStatus)")
        }
        return ""
    }
}

struct DigUpSetupView: View {
    @ObservedObject var setup: DigUpSetupModel
    let onReady: () -> Void
    @ObservedObject private var theme = HomyTheme.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Describe Contents", systemImage: "text.magnifyingglass")
                        .font(.system(size: 24, weight: .bold))
                    Text(
                        "Search files by what is inside them — photos, PDFs, documents, recordings — "
                            + "on this Mac only, with [DigUp](https://github.com/ARahim3/DigUp)."
                    ).font(.callout).foregroundStyle(.secondary)
                }
                if let error = setup.error {
                    Text(error).font(.callout)
                        .foregroundStyle(.orange)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: theme.cardRadius).fill(theme.cardFill))
                }
                cards
            }.padding(22)
        }
        .task { await setup.refresh() }
    }

    @ViewBuilder private var cards: some View {
        if let state = setup.state {
            if state.cliURL == nil {
                setupCard(
                    title: "Install DigUp",
                    detail:
                        "Downloads the latest release from GitHub and installs it in /Applications. "
                        + "Free and open source; everything stays on this Mac.",
                    button: setup.installing ? "Installing…" : "Install DigUp",
                    action: { Task { await setup.installFromGitHub(); onReady() } }
                )
                progressArea
            } else if !state.modelPresent {
                setupCard(
                    title: "Download the model",
                    detail:
                        "One 865 MB download of the embedding model, kept in DigUp's folder. "
                        + "If you already have DigUp installed, the model is already there and this is skipped.",
                    button: setup.installing ? "Downloading…" : "Download Model",
                    action: { Task { await setup.downloadModel(); onReady() } }
                )
                progressArea
            } else if !state.indexPresent {
                setupCard(
                    title: "Create the index",
                    detail:
                        "The index folder does not exist yet. Create it, then choose folders to index below.",
                    button: "Create Index Folder",
                    action: {
                        setup.ensureIndexFolder()
                        onReady()
                    }
                )
            } else {
                setupCard(
                    title: "Ready",
                    detail: "Everything is in place. Choose folders to index to start searching.",
                    button: "Choose Folders",
                    action: { onReady() }
                )
            }
            statusRow(state)
        }
    }

    @ViewBuilder private var progressArea: some View {
        if setup.installing {
            VStack(alignment: .leading, spacing: 6) {
                if !setup.installStage.isEmpty {
                    Text(setup.installStage).font(.callout)
                }
                if let fraction = setup.downloadFraction {
                    ProgressView(value: fraction)
                    Text(setup.downloadDetail).font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }.padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: theme.cardRadius).fill(theme.cardFill))
        }
    }

    private func setupCard(title: String, detail: String, button: String, action: @escaping () -> Void)
        -> some View
    {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(button, action: action)
                .buttonStyle(.borderedProminent)
                .disabled(setup.installing)
        }.padding(14)
            .background(RoundedRectangle(cornerRadius: theme.cardRadius).fill(theme.cardFill))
    }

    private func statusRow(_ state: DigUpInstallState) -> some View {
        Text(state.summary).font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - Folders

@MainActor final class DigUpFoldersModel: ObservableObject {
    @Published var ownRoots: [String] {
        didSet { UserDefaults.standard.set(ownRoots, forKey: "homy.digup.roots") }
    }
    @Published var digUpRoots: [String] = []

    init() {
        ownRoots = UserDefaults.standard.stringArray(forKey: "homy.digup.roots") ?? []
    }

    func refresh() {
        digUpRoots = DigUpSharedSettings.roots
    }

    func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !ownRoots.contains(url.path) {
            ownRoots.append(url.standardizedFileURL.path)
        }
    }

    func remove(_ path: String) {
        ownRoots.removeAll { $0 == path }
    }
}

struct DigUpFoldersView: View {
    let onChange: () -> Void
    @StateObject private var model = DigUpFoldersModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Search Folders").font(.headline)
                Spacer()
                Button("Add Folder…") { model.add() }
            }.padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !model.digUpRoots.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Already indexed by DigUp").font(.subheadline.weight(.semibold))
                            ForEach(model.digUpRoots, id: \.self) { path in
                                Label(path, systemImage: "folder.fill")
                                    .font(.callout).lineLimit(1).truncationMode(.middle)
                            }
                            Text(
                                "These come from DigUp's own settings and are searched without re-indexing."
                            ).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Added here").font(.subheadline.weight(.semibold))
                        if model.ownRoots.isEmpty {
                            Text("No folders added yet.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(model.ownRoots, id: \.self) { path in
                            HStack {
                                Label(path, systemImage: "folder")
                                    .font(.callout).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button {
                                    model.remove(path)
                                } label: {
                                    Image(systemName: "minus.circle").foregroundStyle(.secondary)
                                }.buttonStyle(.borderless)
                            }
                        }
                    }
                }.padding(14)
            }
            Divider()
            HStack {
                Text(
                    "Indexing runs through DigUp and skips what it already knows; the model is never downloaded twice."
                ).font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Done") {
                    onChange()
                    dismiss()
                }.buttonStyle(.borderedProminent)
            }.padding(12)
        }.frame(minWidth: 480, minHeight: 380)
            .onAppear { model.refresh() }
    }
}

// MARK: - Indexing

@MainActor final class DigUpIndexingModel: ObservableObject {
    @Published var running = false
    @Published var done = 0
    @Published var total = 0
    @Published var currentFile = ""
    @Published var states: [String: Int] = [:]
    @Published var lastMessage: String?
    private var process: Process?
    private var input: FileHandle?

    func syncNow(roots: [String]) {
        guard !running, let cli = DigUpPaths.locateCLI(), !roots.isEmpty else { return }
        running = true
        done = 0; total = 0; states = [:]; lastMessage = nil
        let process = Process()
        process.executableURL = cli
        process.arguments = ["index-service"] + roots + ["--backfill", "--prune"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.running = false
                self.process = nil
                // The search service sees the index change only when told.
                DigUpService.shared.reload()
            }
        }
        do {
            try process.run()
        } catch {
            running = false
            lastMessage = error.localizedDescription
            return
        }
        self.process = process
        self.input = input.fileHandleForWriting
        var buffer = Data()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let lines = { (data: Data) -> [String] in
                var local = data
                var result: [String] = []
                while let newline = local.firstIndex(of: 10) {
                    result.append(String(decoding: local.prefix(upTo: newline), as: UTF8.self))
                    local.removeSubrange(...newline)
                }
                return result
            }(buffer + chunk)
            if let last = chunk.last, last == 10 { buffer = Data() } else { buffer += chunk }
            Task { @MainActor [weak self] in
                for line in lines { self?.consume(line) }
            }
        }
        // The service syncs on start; ask again to pick up any changes since.
        try? input.fileHandleForWriting.write(contentsOf: Data("sync\n".utf8))
    }

    private func consume(_ line: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            let event = object["event"] as? String
        else { return }
        switch event {
        case "file":
            done = object["done"] as? Int ?? done
            total = object["total"] as? Int ?? total
            currentFile = (object["path"] as? String ?? "").split(separator: "/").last.map(String.init) ?? ""
        case "summary":
            if let summaryStates = object["states"] as? [String: Int] {
                states = summaryStates
            }
        case "waiting":
            lastMessage = "The model is not downloaded yet; names are searchable meanwhile."
        case "error":
            lastMessage = object["message"] as? String
        case "idle", "exit":
            break
        default:
            break
        }
    }

    func stop() {
        try? input?.write(contentsOf: Data("stop\n".utf8))
        try? input?.close()
        process?.terminate()
    }
}
