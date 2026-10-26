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

/// HOMY: sidebar sections the user can reorder by dragging one section's
/// title onto another's. The order persists; missing entries fall back to
/// the default sequence.
enum SidebarSection: String, CaseIterable, Hashable {
    case categories, smartFolders, collections, savedSearches, favorites, locations, tags

    var title: String {
        switch self {
        case .categories: return "Categories"
        case .smartFolders: return "Smart Folders"
        case .collections: return "Collections"
        case .savedSearches: return "Saved Searches"
        case .favorites: return "Favorites"
        case .locations: return "Locations"
        case .tags: return "Tags"
        }
    }

    static let orderKey = "homy.sidebarSections"

    static func loadOrder() -> [SidebarSection] {
        let stored = UserDefaults.standard.stringArray(forKey: orderKey) ?? []
        var seen = Set<String>()
        let custom = stored.compactMap { SidebarSection(rawValue: $0) }
            .filter { seen.insert($0.rawValue).inserted }
        return custom + allCases.filter { !seen.contains($0.rawValue) }
    }

    static func saveOrder(_ order: [SidebarSection]) {
        UserDefaults.standard.set(order.map(\.rawValue), forKey: orderKey)
        NotificationCenter.default.post(name: .homySidebarOrderChanged, object: nil)
    }

    /// Drag `dragged` so it sits directly above `target`.
    static func reorder(_ dragged: SidebarSection, before target: SidebarSection) {
        var order = loadOrder()
        guard dragged != target, let from = order.firstIndex(of: dragged),
            order.firstIndex(of: target) != nil
        else { return }
        let item = order.remove(at: from)
        order.insert(item, at: order.firstIndex(of: target)!)
        saveOrder(order)
    }

    static func resetOrder() {
        UserDefaults.standard.removeObject(forKey: orderKey)
        saveOrder(allCases)
    }
}

/// A section title that accepts drags of other section titles to reorder.
struct SidebarSectionHeader: View {
    let title: String
    let section: SidebarSection
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 7)).foregroundStyle(.tertiary)
        }
        .draggable(section.rawValue)
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let dragged = SidebarSection(rawValue: raw),
                dragged != section
            else { return false }
            SidebarSection.reorder(dragged, before: section)
            return true
        } isTargeted: { targeted = $0 }
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor.opacity(targeted ? 0.2 : 0)))
        .help("Drag to another section title to reorder")
    }
}

/// Folder results and loading phases have no bearing on sidebar content.
struct SidebarState: Equatable {
    let selection: String?
    let favorites: [String]
    let volumes: [MountedVolume]
    let ejectingVolumes: Set<String>
    let showDiskAccessHint: Bool
    // HOMY: the user's section order (dragged section titles).
    let sections: [SidebarSection]

    @MainActor init(
        route: String, favorites: [String], volumes: [MountedVolume], ejectingVolumes: Set<String>,
        showDiskAccessHint: Bool, sections: [SidebarSection] = SidebarSection.allCases
    ) {
        let home = NSHomeDirectory()
        let fixedRoutes =
            [
                "recents", home,
                home + "/Library/Mobile Documents/com~apple~CloudDocs",
            ]
            + SidebarTags.values.map { "tag:" + $0.0 }
            + HomyRoute.sidebarSelectionRoutes  // HOMY
            + HomyCollections.shared.items.map { "col:" + $0.id.uuidString }  // HOMY
            + HomySmartRules.shared.items.map { "rule:" + $0.id.uuidString }  // HOMY
        // An ordinary child folder selects no sidebar row. Moving between such
        // folders should leave the entire sidebar untouched.
        selection = (fixedRoutes + favorites + volumes.map(\.id)).contains(route) ? route : nil
        self.favorites = favorites
        self.volumes = volumes
        self.ejectingVolumes = ejectingVolumes
        self.showDiskAccessHint = showDiskAccessHint
        self.sections = sections
    }
}

struct BrowserSidebar: View, Equatable {
    let state: SidebarState
    let select: (String) -> Void
    let removeFavorite: (String) -> Void
    let moveFavorites: (IndexSet, Int) -> Void
    let openInNewTab: (URL) -> Void
    let addFavoriteFolders: ([URL]) async -> Bool
    @State private var folderDropTargeted = false
    let eject: (MountedVolume) -> Void
    private let home = NSHomeDirectory()

    static func == (lhs: Self, rhs: Self) -> Bool {
        // Callbacks target the same browser and workspace for this view's lifetime;
        // the browser's identity changes when switching tabs.
        lhs.state == rhs.state
    }

    var body: some View {
        VStack(spacing: 0) {
            locations
            if state.showDiskAccessHint {
                Divider()
                Button {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
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

    private var locations: some View {
        List(
            selection: Binding<String?>(
                get: { state.selection },
                set: { if let route = $0 { select(route) } }
            )
        ) {
            HomyPinnedSections(select: select)  // HOMY
            recentsRow
            // HOMY: every section is reorderable by dragging its title.
            ForEach(state.sections, id: \.self) { section in
                sectionRows(section)
            }
        }
        // Recreate the native list after a reorder so selection follows the path,
        // rather than the previous row index retained by AppKit.
        .id(state.favorites)
        .listStyle(.sidebar)
        .onDrop(of: [UTType.fileURL], isTargeted: $folderDropTargeted) { providers in
            FavoriteFolderDrop.perform(providers, add: addFavoriteFolders)
        }
        .overlay {
            if folderDropTargeted {
                RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 2)
                    .padding(4).allowsHitTesting(false)
            }
        }
    }

    // HOMY: content of each reorderable section.
    @ViewBuilder private func sectionRows(_ section: SidebarSection) -> some View {
        switch section {
        case .categories: HomyCategorySection()
        case .smartFolders: HomySmartFolderSection()
        case .collections: HomyCollectionSection(select: select)  // HOMY
        case .savedSearches: HomySavedSearchSection(select: select)
        case .favorites: favoritesSection
        case .locations: locationsSection
        case .tags: tagsSection
        }
    }

    @ViewBuilder private func folderActions(_ path: String) -> some View {
        Button("Open") { select(path) }
        Button("Open in New Tab") { openInNewTab(URL(fileURLWithPath: path, isDirectory: true)) }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    private var recentsRow: some View {
        Label("Recents", systemImage: "clock").tag("recents")
    }

    @ViewBuilder private var favoritesSection: some View {
        Section {
            ForEach(state.favorites, id: \.self) { path in
                let label = FavoriteFolders.label(for: path)
                row(label.name, label.symbol, path)
                    .contextMenu {
                        folderActions(path)
                        Divider()
                        Button("Remove from Sidebar") { removeFavorite(path) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        FavoriteDragTarget(path: path) { source, target in
                            guard let from = state.favorites.firstIndex(of: source),
                                let to = state.favorites.firstIndex(of: target)
                            else { return }
                            moveFavorites(IndexSet(integer: from), to > from ? to + 1 : to)
                        }
                    }
            }
        } header: {
            SidebarSectionHeader(title: "Favorites", section: .favorites)
        }
    }

    @ViewBuilder private var locationsSection: some View {
        Section {
            row(
                "iCloud Drive", "icloud",
                home + "/Library/Mobile Documents/com~apple~CloudDocs"
            ).contextMenu {
                folderActions(home + "/Library/Mobile Documents/com~apple~CloudDocs")
            }
            row((home as NSString).lastPathComponent, "house", home)
                .contextMenu { folderActions(home) }
            ForEach(state.volumes) { volume in
                let ejecting = state.ejectingVolumes.contains(volume.id)
                let ejectLabel = ejecting ? "Ejecting \(volume.name)…" : "Eject \(volume.name)"
                HStack {
                    Label(volume.name, systemImage: "externaldrive")
                    Spacer(minLength: 4)
                    if volume.canEject {
                        Button {
                            eject(volume)
                        } label: {
                            Group {
                                if ejecting {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "eject.fill").font(.system(size: 11))
                                        .foregroundStyle(.primary)
                                }
                            }.frame(width: 24, height: 24)
                        }
                        .buttonStyle(.borderless)
                        .disabled(ejecting)
                        .help(ejectLabel)
                        .accessibilityLabel(ejectLabel)
                    }
                }.tag(volume.id)
                    .contextMenu {
                        folderActions(volume.id)
                        if volume.canEject {
                            Divider()
                            Button("Eject “\(volume.name)”") { eject(volume) }
                                .disabled(ejecting)
                        }
                    }
            }
        } header: {
            SidebarSectionHeader(title: "Locations", section: .locations)
        }
    }

    @ViewBuilder private var tagsSection: some View {
        Section {
            ForEach(SidebarTags.values, id: \.0) { name, color in
                Label {
                    Text(name)
                } icon: {
                    Image(systemName: "circle.fill").font(.system(size: 10))
                        .foregroundStyle(color)
                }.tag("tag:" + name)
            }
        } header: {
            SidebarSectionHeader(title: "Tags", section: .tags)
        }
    }

    private func row(_ name: String, _ symbol: String, _ path: String) -> some View {
        Label(name, systemImage: symbol).tag(path)
    }
}
