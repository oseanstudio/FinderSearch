import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum SidebarTags {
    static let values: [(String, Color)] = [
        ("Red", .red), ("Orange", .orange), ("Yellow", .yellow), ("Green", .green),
        ("Blue", .blue), ("Purple", .purple), ("Gray", .gray),
    ]
}

enum FavoriteFolders {
    static let key = "sidebarFavorites"
    static let changed = Notification.Name("FinderSearch.sidebarFavoritesChanged")

    static func defaults(home: String = NSHomeDirectory()) -> [String] {
        ["/Applications"]
            + ["Documents", "Downloads", "Desktop", "Pictures", "Music", "Movies"]
            .map { home + "/" + $0 }
    }

    static func load(from defaults: UserDefaults) -> [String] {
        let paths =
            defaults.stringArray(forKey: key)
            ?? (Self.defaults() + (defaults.stringArray(forKey: "favorites") ?? []))
        var seen = Set<String>()
        return paths.filter { $0.hasPrefix("/") }.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        .filter { seen.insert($0).inserted }
    }

    static func existingDirectories(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            guard url.isFileURL else { return nil }
            let url = url.standardizedFileURL
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
                values.isDirectory == true, values.isPackage != true,
                seen.insert(url.path).inserted
            else { return nil }
            return url
        }
    }

    static func label(for path: String) -> (name: String, symbol: String) {
        let names = [
            "Applications", "Documents", "Downloads", "Desktop", "Pictures", "Music", "Movies",
        ]
        let symbols = [
            "a.square", "doc", "arrow.down.circle", "menubar.dock.rectangle", "photo", "music.note",
            "film",
        ]
        if let index = defaults().firstIndex(of: path) { return (names[index], symbols[index]) }
        return ((path as NSString).lastPathComponent, "folder")
    }
}

/// HOME: sidebar sections. Their order comes from the user's layout (drag a
/// section title to move it), and anything — sections or built-in rows — can
/// be hidden from the sidebar and restored via Customize Sidebar.
enum SidebarSection: String, CaseIterable, Hashable, Codable {
    case categories, smartFolders, favorites, locations, tags

    var title: String {
        switch self {
        case .categories: return "Categories"
        case .smartFolders: return "Smart Folders"
        case .favorites: return "Favorites"
        case .locations: return "Locations"
        case .tags: return "Tags"
        }
    }
}

/// HOME: the user's sidebar — section order, per-section item order, plus
/// everything they removed. Hidden identifiers are "sec:<section>" or
/// "row:<id>"; missing sections in a stored order fall back to the default
/// sequence, and items never ordered fall back to their natural sequence.
struct SidebarLayout: Codable, Equatable {
    var sections: [SidebarSection]
    var hidden: Set<String>
    var itemOrder: [String: [String]] = [:]
    var collapsed: Set<String> = []

    private enum CodingKeys: String, CodingKey { case sections, hidden, itemOrder, collapsed }

    init(sections: [SidebarSection], hidden: Set<String>) {
        self.sections = sections
        self.hidden = hidden
    }

    // Set is not Codable; persist the hidden ids as a sorted array. Unknown
    // section names (from a future version) are dropped, not fatal.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let names = try container.decode([String].self, forKey: .sections)
        sections = names.compactMap(SidebarSection.init(rawValue:))
        hidden = Set(try container.decode([String].self, forKey: .hidden))
        itemOrder =
            (try? container.decode([String: [String]].self, forKey: .itemOrder)) ?? [:]
        collapsed = Set(
            (try? container.decode([String].self, forKey: .collapsed)) ?? [])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sections, forKey: .sections)
        try container.encode(hidden.sorted(), forKey: .hidden)
        if !itemOrder.isEmpty {
            try container.encode(itemOrder, forKey: .itemOrder)
        }
        if !collapsed.isEmpty {
            try container.encode(collapsed.sorted(), forKey: .collapsed)
        }
    }

    static let key = "home.sidebarLayout"
    static let changed = Notification.Name("home.sidebarLayoutChanged")
    static let customize = Notification.Name("home.customizeSidebar")

    static func load() -> SidebarLayout {
        var layout = SidebarLayout(sections: Array(SidebarSection.allCases), hidden: [])
        if let data = UserDefaults.standard.data(forKey: key),
            let stored = try? JSONDecoder().decode(SidebarLayout.self, from: data)
        {
            layout = stored
        }
        // Fill in sections this version knows that the stored layout lacks.
        for section in SidebarSection.allCases where !layout.sections.contains(section) {
            layout.sections.append(section)
        }
        layout.sections.removeAll { !SidebarSection.allCases.contains($0) }
        return layout
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func isHidden(_ id: String) -> Bool { hidden.contains(id) }

    mutating func setHidden(_ id: String, _ hidden: Bool) {
        if hidden {
            self.hidden.insert(id)
        } else {
            self.hidden.remove(id)
        }
    }

    mutating func reset() {
        sections = Array(SidebarSection.allCases)
        hidden = []
        itemOrder = [:]
        collapsed = []
    }

    func isCollapsed(_ section: SidebarSection) -> Bool {
        collapsed.contains("sec:" + section.rawValue)
    }

    mutating func toggleCollapsed(_ section: SidebarSection) {
        let id = "sec:" + section.rawValue
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }

    var visibleSections: [SidebarSection] {
        sections.filter { !hidden.contains("sec:" + $0.rawValue) }
    }

    /// Sections that both exist and aren't collapsed open (headers render).
    var openSections: [SidebarSection] {
        visibleSections.filter { !collapsed.contains("sec:" + $0.rawValue) }
    }

    /// The section's items in the stored order, with anything not yet ordered
    /// (new items, fresh installs) appended in their natural sequence.
    func orderedIDs(section: SidebarSection, current: [String]) -> [String] {
        let stored = itemOrder[section.rawValue] ?? []
        var seen = Set<String>()
        let known = stored.filter { current.contains($0) && seen.insert($0).inserted }
        return known + current.filter { !seen.contains($0) }
    }

    mutating func setOrder(section: SidebarSection, _ ids: [String]) {
        itemOrder[section.rawValue] = ids
    }
}

struct SidebarState: Equatable {
    let selection: String?
    let favorites: [String]
    let volumes: [MountedVolume]
    let ejectingVolumes: Set<String>
    let showDiskAccessHint: Bool
    // HOME: the user's sidebar layout (dragged sections, hidden items).
    let layout: SidebarLayout

    @MainActor init(
        route: String, favorites: [String], volumes: [MountedVolume], ejectingVolumes: Set<String>,
        showDiskAccessHint: Bool, layout: SidebarLayout = SidebarLayout.load()
    ) {
        let home = NSHomeDirectory()
        var fixedRoutes =
            [
                "recents", home,
                home + "/Library/Mobile Documents/com~apple~CloudDocs",
            ]
            + SidebarTags.values.map { "tag:" + $0.0 }
            + HomeRoute.sidebarSelectionRoutes  // HOME
            + HomeCollections.shared.items.map { "col:" + $0.id.uuidString }  // HOME
            + HomeSmartRules.shared.items.map { "rule:" + $0.id.uuidString }  // HOME
        // HOME: hidden rows cannot be selected, so an active route inside a
        // removed row still selects nothing.
        fixedRoutes = fixedRoutes.filter { !layout.isHidden("row:" + $0) || $0 == route }
        // An ordinary child folder selects no sidebar row. Moving between such
        // folders should leave the entire sidebar untouched.
        selection = (fixedRoutes + favorites + volumes.map(\.id)).contains(route) ? route : nil
        self.favorites = favorites
        self.volumes = volumes
        self.ejectingVolumes = ejectingVolumes
        self.showDiskAccessHint = showDiskAccessHint
        self.layout = layout
    }
    /// Everything except the selected route. Selection-only changes must not
    /// reload the table — a reload during the mouse-down-to-drag transition
    /// cancels AppKit's native drag before it starts.
    func structureMatches(_ other: SidebarState) -> Bool {
        favorites == other.favorites && volumes == other.volumes
            && ejectingVolumes == other.ejectingVolumes
            && showDiskAccessHint == other.showDiskAccessHint && layout == other.layout
    }
}


struct BrowserSidebar: View, Equatable {
    let state: SidebarState
    let select: (String) -> Void
    let removeFavorite: (String) -> Void
    let openInNewTab: (URL) -> Void
    let addFavoriteFolders: ([URL]) async -> Bool
    let eject: (MountedVolume) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        // Callbacks target the same browser and workspace for this view's lifetime;
        // the browser's identity changes when switching tabs.
        lhs.state == rhs.state
    }


    var body: some View {
        VStack(spacing: 0) {
            // HOME: native NSTableView — Finder's own control — so drag
            // reordering (row lift, opening gap, native drop) comes from
            // AppKit, for every row, not just favorites.
            SidebarTableView(state: state, actions: SidebarTableActions(
                select: select,
                removeFavorite: removeFavorite,
                openInNewTab: openInNewTab,
                addFavoriteFolders: addFavoriteFolders,
                eject: eject
            ))
            if state.showDiskAccessHint {
                Divider()
                Button {
                    FullDiskAccess.requestEnable()  // HOME: offers a move when dist-built
                } label: {
                    Text("Enable Full Disk Access…")
                        .font(.caption).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain).padding(12)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .navigationSplitViewColumnWidth(min: 170, ideal: 208, max: 280)
    }
}

struct CustomizeSidebarSheet: View {
    @State private var layout = SidebarLayout.load()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Pinned") {
                toggle("Home", "row:home")
                toggle("Search", "row:semantic")
                toggle("Recents", "row:recents")
            }
            ForEach(layout.sections, id: \.self) { section in
                Section(section.title) {
                    toggle("Entire Section", "sec:" + section.rawValue)
                    builtInRows(section)
                }
            }
        }
        .frame(minWidth: 380, minHeight: 460)
        .navigationTitle("Customize Sidebar")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Reset Sidebar") {
                    layout.reset()
                    layout.save()
                }
            }
        }
    }

    @ViewBuilder private func builtInRows(_ section: SidebarSection) -> some View {
        switch section {
        case .categories:
            ForEach(HomeCategory.allCases) { category in
                toggle(category.title, "row:cat:" + category.rawValue)
            }
        case .smartFolders:
            ForEach(HomeSmartFolder.allCases) { smart in
                toggle(smart.title, "row:smart:" + smart.rawValue)
            }
        case .locations:
            toggle("iCloud Drive", "row:loc:icloud")
            toggle((NSHomeDirectory() as NSString).lastPathComponent, "row:loc:home")
        case .tags:
            ForEach(SidebarTags.values, id: \.0) { name, _ in
                toggle(name, "row:tag:" + name)
            }
        case .favorites:
            EmptyView()
        }
    }

    private func toggle(_ title: String, _ id: String) -> some View {
        Toggle(
            isOn: Binding(
                get: { !layout.isHidden(id) },
                set: { visible in
                    layout.setHidden(id, !visible)
                    layout.save()
                }
            )
        ) {
            Text(title)
        }
    }
}
