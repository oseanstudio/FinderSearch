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
    case collection(UUID)  // HOMY: user-defined folder group
    case rule(UUID)  // HOMY: user-defined smart folder
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
            } else if route.hasPrefix("col:"), let id = UUID(
                uuidString: String(route.dropFirst(4)))
            {
                self = .collection(id)  // HOMY
            } else if route.hasPrefix("rule:"), let id = UUID(
                uuidString: String(route.dropFirst(5)))
            {
                self = .rule(id)  // HOMY
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
        case .collection(let id): return "col:" + id.uuidString
        case .rule(let id): return "rule:" + id.uuidString
        case .sources: return "sources"
        case .duplicates: return "dupes"
        case .cleanup: return "cleanup"
        }
    }

    static var sidebarSelectionRoutes: [String] {
        allCases.map(\.route)
    }

    @MainActor var title: String {
        switch self {
        case .home: return "Home"
        case .semantic: return "Describe Contents"
        case .category(let category): return category.title
        case .smart(let smart): return smart.title
        case .collection(let id):
            return HomyCollections.shared.items.first { $0.id == id }?.name ?? "Collection"
        case .rule(let id):
            return HomySmartRules.shared.items.first { $0.id == id }?.name ?? "Smart Folder"
        case .sources: return "Downloaded From"
        case .duplicates: return "Duplicates"
        case .cleanup: return "Clean Up"
        }
    }

    @MainActor var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .semantic: return "text.magnifyingglass"
        case .category(let category): return category.symbol
        case .smart(let smart): return smart.symbol
        case .collection: return "square.stack.3d.up"
        case .rule: return "slider.horizontal.3"
        case .sources: return "globe.desk"
        case .duplicates: return "square.on.square"
        case .cleanup: return "sparkles"
        }
    }

    /// Non-nil routes render through the normal file surfaces.
    @MainActor var engineQuery: String? {
        switch self {
        case .home, .semantic, .collection, .sources, .duplicates, .cleanup: return nil
        case .category(let category): return category.query
        case .smart(.large): return "size:>100mb kind:file"
        case .smart(.screenshots): return "Screenshot kind:file"
        case .rule(let id): return HomySmartRules.shared.query(for: id)
        }
    }

    /// HOMY: routes whose toolbar search filters the route itself.
    @MainActor var searchFiltersSelf: Bool {
        if case .collection = self { return true }
        return engineQuery != nil
    }

    /// HOMY: a where-from source the results must match (rules only).
    @MainActor var sourceFilter: String? {
        if case .rule(let id) = self {
            return HomySmartRules.shared.items.first { $0.id == id }?.source
        }
        return nil
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

/// Shared services for Homy surfaces. HOMY: one stdio engine client for the
/// whole app — tabs, Homy views, Quick Search and the menu bar all queue on
/// this instance instead of each spawning their own fsearch process.
@MainActor final class HomyServices {
    static let shared = HomyServices()
    let engine: Engine = Engine()
    private init() {}
}

// MARK: - Sidebar sections

/// Home and Describe Contents stay pinned at the top; everything below them
/// is a reorderable section (drag a section's title onto another's).
struct HomyPinnedSections: View {
    let select: (String) -> Void
    let layout: SidebarLayout

    var body: some View {
        if !layout.isHidden("row:home") {
            Label("Home", systemImage: "house.fill").tag("home")
                .contextMenu { SidebarRowMenu(itemID: "row:home") }
        }
        if !layout.isHidden("row:semantic") {
            Label("Describe Contents", systemImage: "text.magnifyingglass").tag("semantic")  // DIGUP
                .contextMenu { SidebarRowMenu(itemID: "row:semantic") }
        }
    }
}

struct HomyCategorySection: View {
    let layout: SidebarLayout

    var body: some View {
        Section {
            ForEach(HomyCategory.allCases) { category in
                if !layout.isHidden("row:cat:" + category.rawValue) {
                    Label(category.title, systemImage: category.symbol)
                        .tag("cat:" + category.rawValue)
                        .contextMenu { SidebarRowMenu(itemID: "row:cat:" + category.rawValue) }
                }
            }
        } header: {
            SidebarSectionHeader(title: "Categories", section: .categories)
        }
    }
}

struct HomySmartFolderSection: View {
    let layout: SidebarLayout

    var body: some View {
        Section {
            ForEach(HomySmartFolder.allCases) { smart in
                if !layout.isHidden("row:smart:" + smart.rawValue) {
                    Label(smart.title, systemImage: smart.symbol)
                        .tag("smart:" + smart.rawValue)
                        .contextMenu {
                            SidebarRowMenu(itemID: "row:smart:" + smart.rawValue)
                        }
                }
            }
            HomyUserRulesSection()  // HOMY: user-built smart folders
        } header: {
            SidebarSectionHeader(title: "Smart Folders", section: .smartFolders)
        }
    }
}

struct HomySavedSearchSection: View {
    let select: (String) -> Void
    @ObservedObject private var saved = SavedSearches.shared

    var body: some View {
        if !saved.entries.isEmpty {
            Section {
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
            } header: {
                SidebarSectionHeader(title: "Saved Searches", section: .savedSearches)
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
    /// Category, smart-folder, collection and rule routes fetch through the
    /// shared engine and reuse the model's existing ordering pipeline (hits'
    /// didSet sorts). HOMY: with a filter, results narrow to names matching
    /// the search text — searching *within* the route, not the whole disk.
    func loadHomy(_ route: HomyRoute, filter: String = "") {
        // Collections merge one query per member folder instead.
        if case .collection(let id) = route {
            loadCollection(id, filter: filter)
            return
        }
        guard let engineQuery = route.engineQuery else {
            hits = []; selection = []; loading = false; searching = false; return
        }
        generation += 1
        let revision = generation
        task?.cancel()
        error = nil
        loading = sortedHits.isEmpty
        searching = !filter.isEmpty
        let limit = route.engineLimit
        let source = route.sourceFilter
        task = Task {
            do {
                if !filter.isEmpty { try await Task.sleep(for: .milliseconds(120)) }
                try Task.checkCancellation()
                var fields: [String: Any] = ["q": engineQuery, "limit": limit]
                if route != .category(.apps) { fields["in"] = NSHomeDirectory() }
                let reply = try await HomyServices.shared.engine.request(fields)
                guard reply.ok else {
                    throw Engine.Failure.message(reply.error ?? "Search failed")
                }
                guard revision == self.generation, !Task.isCancelled else { return }
                var result = reply.hits ?? []
                if route.needsLocalFilter { result = result.filter(\.isScreenshot) }
                if let source, !source.isEmpty {
                    let fetched = result
                    result = (try? await BackgroundWork.run {
                        fetched.filter { HomyQuery.matchesSource($0, source: source) }
                    }) ?? fetched
                }
                result = Self.filteredByRoute(result, route: route, filter: filter)
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

    /// HOMY: name filtering shared by every engine-backed route search.
    private static func filteredByRoute(_ hits: [Hit], route: HomyRoute, filter: String) -> [Hit]
    {
        guard !filter.isEmpty else { return hits }
        let tokens = filter.split(separator: " ").map(String.init)
        return hits.filter { hit in
            tokens.allSatisfy { hit.name.localizedCaseInsensitiveContains($0) }
        }
    }

    /// HOMY: a collection's files — one concurrent query per member folder,
    /// merged, then filtered like any other route.
    private func loadCollection(_ id: UUID, filter: String) {
        generation += 1
        let revision = generation
        task?.cancel()
        error = nil
        loading = sortedHits.isEmpty
        searching = !filter.isEmpty
        let folders = HomyCollections.shared.collection(id)?.folders ?? []
        Task { [weak self] in
            if !filter.isEmpty { try? await Task.sleep(for: .milliseconds(120)) }
            var result = await HomyCollections.files(in: folders, limit: 2000)
            guard let self, revision == self.generation, !Task.isCancelled else { return }
            result = Self.filteredByRoute(result, route: .collection(id), filter: filter)
            self.elapsed = 0
            self.hits = result
            self.selection = []
            self.loading = false
            self.searching = false
        }
    }
}
