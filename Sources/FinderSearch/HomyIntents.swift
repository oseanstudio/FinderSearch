import AppIntents
import AppKit
import Foundation

// HOMY: Shortcuts / Siri actions — Find Files, Get Latest Download and
// Search in Homy, registered with the system when running from the app
// bundle.

struct HomyIntentError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct HomyFindFilesIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Files"
    static var description = IntentDescription(
        "Search filenames across this Mac with the FinderSearch index.")

    @Parameter(title: "Search Query")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let reply = try await HomyServices.shared.engine.request([
            "q": HomyQuery.translate(query), "limit": 20,
        ])
        guard reply.ok else {
            throw HomyIntentError(message: "Search index is unavailable")
        }
        let files = (reply.hits ?? []).map { IntentFile(fileURL: $0.url) }
        return .result(value: files)
    }
}

struct HomyGetLatestDownloadIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Latest Download"
    static var description = IntentDescription(
        "Return the most recently downloaded file from Downloads.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let hits = try await LocalFiles.load(
            URL(fileURLWithPath: NSHomeDirectory() + "/Downloads"), hidden: false)
        guard
            let latest = hits.filter({ $0.kind == "file" }).max(by: { $0.mtime < $1.mtime })
        else {
            throw HomyIntentError(message: "Downloads folder is empty")
        }
        return .result(value: IntentFile(fileURL: latest.url))
    }
}

struct HomySearchInAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Search in Hearth"
    static var description = IntentDescription(
        "Open the Hearth browser window with the given search.")

    @Parameter(title: "Search Query")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult {
        let reply = try await HomyServices.shared.engine.request([
            "q": HomyQuery.translate(query), "limit": 20,
        ])
        let count = reply.hits?.count ?? 0
        NotificationCenter.default.post(
            name: .homyRunSavedSearch, object: nil, userInfo: ["query": query])
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" { NSWorkspace.shared.open(bundle) }
        return .result(dialog: count == 0 ? "No matches" : "Found \(count) files")
    }
}

struct HomyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: HomyFindFilesIntent(),
            phrases: [
                "\(.applicationName) find files",
            ],
            shortTitle: "Find Files",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: HomyGetLatestDownloadIntent(),
            phrases: [
                "\(.applicationName) latest download",
            ],
            shortTitle: "Latest Download",
            systemImageName: "arrow.down.circle"
        )
    }
}
