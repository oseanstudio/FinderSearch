import SwiftUI
import AppKit

// HOMY: This file and its siblings implement the Homy (tryhomy.app) feature
// set on top of upstream FinderSearch. Integration points in upstream files
// are marked with `// HOMY:` comments so upstream merges stay small.

enum HomyCategory: String, CaseIterable, Identifiable {
    case images, videos, music, documents, archives, apps
    var id: String { rawValue }

    var title: String {
        switch self {
        case .images: return "Images"
        case .videos: return "Videos"
        case .music: return "Music"
        case .documents: return "Documents"
        case .archives: return "Archives"
        case .apps: return "Apps"
        }
    }

    var symbol: String {
        switch self {
        case .images: return "photo"
        case .videos: return "film"
        case .music: return "music.note"
        case .documents: return "doc.text"
        case .archives: return "doc.zipper"
        case .apps: return "square.grid.2x2"
        }
    }

    /// fsearch query fragment; engine type filters reuse the values upstream's
    /// search scope picker already sends, globs cover the rest.
    var query: String {
        switch self {
        case .images: return "type:image kind:file"
        case .videos: return "type:video kind:file"
        case .music: return "type:audio kind:file"
        case .documents: return "type:doc kind:file"
        case .archives: return "*.{zip,rar,7z,tar,gz,xz,tbz,dmg,iso,pkg} kind:file"
        case .apps: return "*.app"
        }
    }

    var isAudio: Bool { self == .music }
}

enum HomySmartFolder: String, CaseIterable, Identifiable {
    case large, screenshots
    var id: String { rawValue }

    var title: String {
        switch self {
        case .large: return "Large Files"
        case .screenshots: return "Screenshots"
        }
    }

    var symbol: String {
        switch self {
        case .large: return "arrow.up.circle"
        case .screenshots: return "camera.on.rectangle"
        }
    }
}

/// Sidebar destinations added by this fork. Routes that carry an engine query
/// render as a normal file list; the others own their dashboard-style views.
enum HomyRoute: Equatable, CaseIterable {
    case home
    case semantic  // DIGUP: describe-contents search
    case category(HomyCategory)
    case smart(HomySmartFolder)
    case sources
    case duplicates
    case cleanup

    static var allCases: [HomyRoute] {
        [.home, .semantic]
            + HomyCategory.allCases.map(HomyRoute.category)
            + HomySmartFolder.allCases.map(HomyRoute.smart)
            + [.sources, .duplicates, .cleanup]
    }

    init?(_ route: String) {
        switch route {
        case "home": self = .home
        case "semantic": self = .semantic
        case "sources": self = .sources
        case "dupes": self = .duplicates
        case "cleanup": self = .cleanup
        default:
            if route.hasPrefix("cat:"), let category = HomyCategory(
                rawValue: String(route.dropFirst(4)))
            {
                self = .category(category)
            } else if route.hasPrefix("smart:"), let smart = HomySmartFolder(
                rawValue: String(route.dropFirst(6)))
            {
                self = .smart(smart)
            } else {
                return nil
            }
        }
    }

    var route: String {
        switch self {
        case .home: return "home"
        case .semantic: return "semantic"
        case .category(let category): return "cat:" + category.rawValue
        case .smart(let smart): return "smart:" + smart.rawValue
        case .sources: return "sources"
        case .duplicates: return "dupes"
        case .cleanup: return "cleanup"
        }
    }

    static var sidebarSelectionRoutes: [String] {
        allCases.map(\.route)
    }

    var title: String {
        switch self {
        case .home: return "Home"
        case .semantic: return "Describe Contents"
        case .category(let category): return category.title
        case .smart(let smart): return smart.title
        case .sources: return "Downloaded From"
        case .duplicates: return "Duplicates"
        case .cleanup: return "Clean Up"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .semantic: return "text.magnifyingglass"
        case .category(let category): return category.symbol
        case .smart(let smart): return smart.symbol
        case .sources: return "globe.desk"
        case .duplicates: return "square.on.square"
        case .cleanup: return "sparkles"
        }
    }

    /// Non-nil routes render through the normal file surfaces.
    var engineQuery: String? {
        switch self {
        case .home, .semantic, .sources, .duplicates, .cleanup: return nil
        case .category(let category): return category.query
        case .smart(.large): return "size:>100mb kind:file"
        case .smart(.screenshots): return "Screenshot kind:file"
        }
    }

    var engineLimit: Int {
        switch self {
        case .category: return 2000
        case .smart(.large): return 1000
        case .smart(.screenshots): return 2000
        default: return 500
        }
    }

    /// Screenshots come back as fuzzy "Screenshot" matches; tighten locally.
    var needsLocalFilter: Bool { self == .smart(.screenshots) }

    var listSort: FileSort {
        switch self {
        case .smart(.large): return .size
        default: return .modified
        }
    }

    var listAscending: Bool { false }
}

extension Hit {
    var isScreenshot: Bool {
        let lowered = name.lowercased()
        guard lowered.contains("screenshot") || lowered.contains("screen shot") else { return false }
        let ext = url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "heic", "tiff", "webp", "mov", "mp4"].contains(ext)
    }

    var isImageFile: Bool {
        let ext = url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "heic", "tiff", "webp", "gif", "bmp", "avif"].contains(ext)
    }

    var isPDF: Bool { url.pathExtension.lowercased() == "pdf" }
}

/// Shared services for Homy surfaces: a second stdio client so dashboard and
/// panel queries never queue behind a tab's search.
@MainActor final class HomyServices {
    static let shared = HomyServices()
    let engine: Engine = Engine()
    private init() {}
}

// MARK: - Sidebar sections

/// Home, Categories, Smart Folders and Saved Searches, inserted above
/// upstream's Recents row.
struct HomySidebarSections: View {
    let select: (String) -> Void
    @ObservedObject private var saved = SavedSearches.shared
    @ObservedObject private var theme = HomyTheme.shared

    var body: some View {
    Label("Home", systemImage: "house.fill").tag("home")
        Label("Describe Contents", systemImage: "text.magnifyingglass").tag("semantic")  // DIGUP
        Section("Categories") {
            ForEach(HomyCategory.allCases) { category in
                Label(category.title, systemImage: category.symbol)
                    .tag("cat:" + category.rawValue)
            }
        }
        Section("Smart Folders") {
            ForEach(HomySmartFolder.allCases) { smart in
                Label(smart.title, systemImage: smart.symbol)
                    .tag("smart:" + smart.rawValue)
            }
        }
        if !saved.entries.isEmpty {
            Section("Saved Searches") {
                ForEach(saved.entries) { entry in
                    Button {
                        saved.run(entry, select: select)
                    } label: {
                        HStack {
                            Label(entry.name, systemImage: "magnifyingglass")
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Run Search") { saved.run(entry, select: select) }
                        Divider()
                        Button("Remove") { saved.remove(entry) }
                    }
                }
            }
        }
    }
}

// MARK: - Special content routing

/// Renders the dashboard-style Homy routes inside the browser's detail pane;
/// nil means the route should render upstream's file surfaces.
struct HomySpecialContent: View {
    @ObservedObject var model: SearchModel
    @ObservedObject var workspace: BrowserWorkspace

    init?(model: SearchModel, workspace: BrowserWorkspace) {
        guard !model.isSearch, let route = HomyRoute(model.route), route.engineQuery == nil
        else { return nil }
        self.model = model
        self.workspace = workspace
    }

    var body: some View {
        switch HomyRoute(model.route) {
        case .home: HomeDashboard(model: model)
        case .semantic: SemanticSearchView(model: model)  // DIGUP
        case .sources: DownloadedFromView(model: model)
        case .duplicates: DuplicatesView(model: model)
        case .cleanup: CleanupView(model: model)
        default: EmptyView()
        }
    }
}

// MARK: - Engine-backed route loading

extension SearchModel {
    /// Category and smart-folder routes fetch through the shared engine and
    /// reuse the model's existing ordering pipeline (hits' didSet sorts).
    func loadHomy(_ route: HomyRoute) {
        guard let query = route.engineQuery else {
            hits = []; selection = []; loading = false; searching = false; return
        }
        generation += 1
        let revision = generation
        task?.cancel()
        error = nil
        loading = sortedHits.isEmpty
        let limit = route.engineLimit
        task = Task {
            do {
                var fields: [String: Any] = ["q": query, "limit": limit]
                if route != .category(.apps) { fields["in"] = NSHomeDirectory() }
                let reply = try await HomyServices.shared.engine.request(fields)
                guard reply.ok else { throw Engine.Failure.message(reply.error ?? "Search failed") }
                guard revision == self.generation, !Task.isCancelled else { return }
                var result = reply.hits ?? []
                if route.needsLocalFilter { result = result.filter(\.isScreenshot) }
                elapsed = Double(reply.took_us ?? 0) / 1000
                hits = result
                selection = []
                loading = false; searching = false
            } catch is CancellationError {
            } catch {
                guard revision == self.generation else { return }
                self.error = error.localizedDescription
                hits = []; selection = []; loading = false; searching = false
            }
        }
    }
}
