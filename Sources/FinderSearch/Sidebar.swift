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

/// HOMY: sidebar sections. Their order comes from the user's layout (drag a
/// section title to move it), and anything — sections or built-in rows — can
/// be hidden from the sidebar and restored via Customize Sidebar.
enum SidebarSection: String, CaseIterable, Hashable, Codable {
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
}

/// HOMY: the user's sidebar — section order plus everything they removed.
/// Hidden identifiers are "sec:<section>" or "row:<id>"; missing sections in
/// a stored order fall back to the default sequence.
struct SidebarLayout: Codable, Equatable {
    var sections: [SidebarSection]
    var hidden: Set<String>

    private enum CodingKeys: String, CodingKey { case sections, hidden }

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
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sections, forKey: .sections)
        try container.encode(hidden.sorted(), forKey: .hidden)
    }

    static let key = "homy.sidebarLayout"
    static let changed = Notification.Name("homy.sidebarLayoutChanged")
    static let customize = Notification.Name("homy.customizeSidebar")

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
    }

    var visibleSections: [SidebarSection] {
        sections.filter { !hidden.contains("sec:" + $0.rawValue) }
    }
}

/// HOMY: Finder-style drag for section titles. An AppKit event catcher under
/// each title consumes the mouse events before the List's selection machinery
/// can react, so dragging never changes the active location. Coordinates live
/// in the reference box's space (anchored to the whole sidebar, y-up).
@MainActor final class SidebarDragCoordinator: ObservableObject {
    static let shared = SidebarDragCoordinator()

    struct Session: Equatable {
        let section: SidebarSection
        let grabOffset: CGPoint
        var location: CGPoint
        var slot: Int  // insertion slot among the other visible sections
    }

    @Published var session: Session?
    @Published var frames: [SidebarSection: CGRect] = [:]

    func reportFrame(_ section: SidebarSection, _ frame: CGRect) {
        if frames[section] != frame { frames[section] = frame }
    }

    func dragged(to point: CGPoint, section: SidebarSection) {
        if session == nil {
            guard let frame = frames[section] else { return }
            session = Session(
                section: section,
                grabOffset: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY),
                location: point, slot: 0)
        }
        session?.location = point
        session?.slot = slot(at: point, dragged: section)
    }

    /// How many of the other visible section titles sit above the point
    /// (larger y in the reference space means higher on screen).
    private func slot(at point: CGPoint, dragged: SidebarSection) -> Int {
        let others = SidebarLayout.load().visibleSections.filter { $0 != dragged }
        return others.filter { section in
            (frames[section]?.midY ?? -.greatestFiniteMagnitude) > point.y
        }.count
    }

    func ended() {
        guard let session else { return }
        self.session = nil
        var layout = SidebarLayout.load()
        var ordered = layout.visibleSections.filter { $0 != session.section }
        ordered.insert(session.section, at: min(session.slot, ordered.count))
        // Hidden sections keep existing (they come back via Customize), at
        // the end; their position is invisible until restored.
        layout.sections = ordered + layout.sections.filter { !ordered.contains($0) }
        layout.save()
    }
}

/// HOMY: an invisible view anchoring the sidebar-wide coordinate space that
/// drag events and header frames share.
final class SidebarReferenceBox: NSView {
    static weak var current: SidebarReferenceBox?
}

struct SidebarSpaceAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> SidebarReferenceBox {
        let view = SidebarReferenceBox()
        SidebarReferenceBox.current = view
        return view
    }

    func updateNSView(_ view: SidebarReferenceBox, context: Context) {}
}

/// HOMY: consumes the header's mouse events so the List never turns a drag
/// into a selection change; reports its frame and drives the coordinator.
final class SidebarDragCatcher: NSView {
    var section: SidebarSection
    private var pressing = false
    private var dragging = false
    private var startScreen = NSPoint.zero

    init(section: SidebarSection) {
        self.section = section
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func reportFrame() {
        guard let reference = SidebarReferenceBox.current else { return }
        SidebarDragCoordinator.shared.reportFrame(section, convert(bounds, to: reference))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportFrame()
    }

    override func layout() {
        super.layout()
        reportFrame()
    }

    override func mouseDown(with event: NSEvent) {
        pressing = true
        dragging = false
        startScreen = NSEvent.mouseLocation
        reportFrame()
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressing else { return }
        let screen = NSEvent.mouseLocation
        if !dragging {
            guard hypot(screen.x - startScreen.x, screen.y - startScreen.y) > 3 else { return }
            dragging = true
        }
        guard
            let reference = SidebarReferenceBox.current,
            window != nil
        else { return }
        let point = convert(event.locationInWindow, from: nil)
        let referencePoint = convert(point, to: reference)
        SidebarDragCoordinator.shared.dragged(to: referencePoint, section: section)
    }

    override func mouseUp(with event: NSEvent) {
        if dragging { SidebarDragCoordinator.shared.ended() }
        pressing = false
        dragging = false
    }
}

struct SidebarDragHandle: NSViewRepresentable {
    let section: SidebarSection

    func makeNSView(context: Context) -> SidebarDragCatcher {
        SidebarDragCatcher(section: section)
    }

    func updateNSView(_ view: SidebarDragCatcher, context: Context) {
        view.section = section
    }
}

/// A section title: drag handle (Finder-style lift and insertion line) plus
/// the right-click menu for removing the section and customizing.
struct SidebarSectionHeader: View {
    let title: String
    let section: SidebarSection
    @ObservedObject private var drag = SidebarDragCoordinator.shared

    private var isDragged: Bool { drag.session?.section == section }

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 7)).foregroundStyle(.tertiary)
        }
        .opacity(isDragged ? 0.35 : 1)
        // HOMY: the catcher consumes mouse events before the List's selection
        // machinery can react; right-clicks still reach the context menu.
        .background(SidebarDragHandle(section: section))
        .contextMenu { headerMenu }
        .help("Drag to reorder · right-click for options")
    }

    @ViewBuilder private var headerMenu: some View {
        Button("Remove from Sidebar") {
            var layout = SidebarLayout.load()
            layout.setHidden("sec:" + section.rawValue, true)
            layout.save()
        }
        Button("Customize Sidebar…") {
            NotificationCenter.default.post(name: SidebarLayout.customize, object: nil)
        }
    }
}

struct SidebarState: Equatable {
    let selection: String?
    let favorites: [String]
    let volumes: [MountedVolume]
    let ejectingVolumes: Set<String>
    let showDiskAccessHint: Bool
    // HOMY: the user's sidebar layout (dragged sections, hidden items).
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
            + HomyRoute.sidebarSelectionRoutes  // HOMY
            + HomyCollections.shared.items.map { "col:" + $0.id.uuidString }  // HOMY
            + HomySmartRules.shared.items.map { "rule:" + $0.id.uuidString }  // HOMY
        // HOMY: hidden rows cannot be selected, so an active route inside a
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
}

struct BrowserSidebar: View, Equatable {
    let state: SidebarState
    let select: (String) -> Void
    let removeFavorite: (String) -> Void
    let moveFavorites: (IndexSet, Int) -> Void
    let openInNewTab: (URL) -> Void
    let addFavoriteFolders: ([URL]) async -> Bool
    @State private var folderDropTargeted = false
    @State private var draggingSelection = false  // HOMY: mouse is mid-drag
    @State private var dragGuardMonitors: [Any] = []
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
                    FullDiskAccess.requestEnable()  // HOMY: offers a move when dist-built
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
        .onAppear { installDragGuard() }  // HOMY
        .onDisappear { dragGuardMonitors.forEach { NSEvent.removeMonitor($0) } }
    }

    /// HOMY: a press-drag over sidebar rows must not walk the selection (and
    /// navigate) underneath the user; only genuine clicks navigate.
    private func installDragGuard() {
        guard dragGuardMonitors.isEmpty else { return }
        dragGuardMonitors = [
            NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { event in
                Task { @MainActor in draggingSelection = true }
                return event
            },
            NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                Task { @MainActor in draggingSelection = false }
                return event
            },
            NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
                Task { @MainActor in
                    draggingSelection = false
                    // Nudge a re-render so the List's transient drag selection
                    // snaps back to the real one.
                    folderDropTargeted.toggle()
                    folderDropTargeted.toggle()
                }
                return event
            },
        ]
    }

    private var locations: some View {
        ZStack(alignment: .topLeading) {  // HOMY: hosts the drag overlay
            List(
                selection: Binding<String?>(
                    get: { state.selection },
                    // HOMY: drags must not walk the selection (and navigate);
                    // only genuine clicks change the active location.
                    set: { if let route = $0, !draggingSelection { select(route) } }
                )
            ) {
                HomyPinnedSections(select: select, layout: state.layout)  // HOMY
                if !state.layout.isHidden("row:recents") {  // HOMY
                    recentsRow
                        .contextMenu { SidebarRowMenu(itemID: "row:recents") }
                }
                // HOMY: drag a section's title to move it; right-click hides.
                ForEach(state.layout.visibleSections, id: \.self) { section in
                    sectionRows(section)
                }
            }
            SidebarDragOverlay()  // HOMY
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(SidebarSpaceAnchor())  // HOMY: shared drag coordinate space
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

    // HOMY: content of each reorderable section; right-click hides a whole
    // section, individual rows hide via their own context menus.
    @ViewBuilder private func sectionRows(_ section: SidebarSection) -> some View {
        if !state.layout.isHidden("sec:" + section.rawValue) {
            switch section {
            case .categories: HomyCategorySection(layout: state.layout)
            case .smartFolders: HomySmartFolderSection(layout: state.layout)
            case .collections: HomyCollectionSection(select: select)
            case .savedSearches: HomySavedSearchSection(select: select)
            case .favorites: favoritesSection
            case .locations: locationsSection
            case .tags: tagsSection
            }
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
            if !state.layout.isHidden("row:loc:icloud") {  // HOMY
                row(
                    "iCloud Drive", "icloud",
                    home + "/Library/Mobile Documents/com~apple~CloudDocs"
                ).contextMenu {
                    folderActions(home + "/Library/Mobile Documents/com~apple~CloudDocs")
                    Divider()
                    SidebarRowMenu(itemID: "row:loc:icloud")
                }
            }
            if !state.layout.isHidden("row:loc:home") {  // HOMY
                row((home as NSString).lastPathComponent, "house", home)
                    .contextMenu {
                        folderActions(home)
                        Divider()
                        SidebarRowMenu(itemID: "row:loc:home")
                    }
            }
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
                if !state.layout.isHidden("row:tag:" + name) {  // HOMY
                    Label {
                        Text(name)
                    } icon: {
                        Image(systemName: "circle.fill").font(.system(size: 10))
                            .foregroundStyle(color)
                    }.tag("tag:" + name)
                        .contextMenu { SidebarRowMenu(itemID: "row:tag:" + name) }
                }
            }
        } header: {
            SidebarSectionHeader(title: "Tags", section: .tags)
        }
    }

    private func row(_ name: String, _ symbol: String, _ path: String) -> some View {
        Label(name, systemImage: symbol).tag(path)
    }
}


/// HOMY: restore anything removed from the sidebar, Finder-style.
/// HOMY: standard context menu for hideable built-in sidebar rows.
struct SidebarRowMenu: View {
    let itemID: String
    @ViewBuilder var body: some View {
        Button("Remove from Sidebar") {
            var layout = SidebarLayout.load()
            layout.setHidden(itemID, true)
            layout.save()
        }
        Button("Customize Sidebar…") {
            NotificationCenter.default.post(name: SidebarLayout.customize, object: nil)
        }
    }
}

/// HOMY: the floating drag preview and insertion line, drawn over the list.
/// Coordinates arrive in the reference box's space (y-up) and are converted
/// to SwiftUI's local space (y-down) for drawing.
struct SidebarDragOverlay: View {
    @ObservedObject private var drag = SidebarDragCoordinator.shared

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            Group {
                if let session = drag.session {
                    insertionLine(session, height: height)
                    liftPreview(session, height: height)
                }
            }
        }.allowsHitTesting(false)
    }

    private func local(_ rect: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    private func local(_ point: CGPoint, height: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: height - point.y)
    }

    /// Accent line at the boundary the section would land at.
    @ViewBuilder private func insertionLine(
        _ session: SidebarDragCoordinator.Session, height: CGFloat
    ) -> some View {
        let layout = SidebarLayout.load()
        let others = layout.visibleSections.filter { $0 != session.section }
        // In reference space (y-up), visual top-to-bottom is descending midY.
        let ordered = others.compactMap { drag.frames[$0] }.sorted { $0.midY > $1.midY }
        let line: CGRect? = {
            guard !ordered.isEmpty else { return nil }
            if session.slot < ordered.count {
                let frame = ordered[session.slot]
                return CGRect(
                    x: frame.minX, y: frame.maxY - 1.5, width: frame.width + 60, height: 3)
            }
            let frame = ordered[ordered.count - 1]
            return CGRect(
                x: frame.minX, y: frame.minY - 1.5, width: frame.width + 60, height: 3)
        }()
        if let line {
            let localRect = local(line, height: height)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor)
                .frame(width: localRect.width, height: localRect.height)
                .position(x: localRect.midX, y: localRect.midY)
                .shadow(radius: 1)
        }
    }

    /// The lifted title following the cursor.
    @ViewBuilder private func liftPreview(
        _ session: SidebarDragCoordinator.Session, height: CGFloat
    ) -> some View {
        if let frame = drag.frames[session.section] {
            let center = CGPoint(
                x: session.location.x - session.grabOffset.x + frame.width / 2,
                y: session.location.y - session.grabOffset.y + frame.height / 2)
            let localCenter = local(center, height: height)
            HStack(spacing: 4) {
                Text(session.section.title)
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 7)).foregroundStyle(.tertiary)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .frame(width: max(90, min(frame.width + 24, 190)), alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
            .position(x: localCenter.x, y: localCenter.y)
        }
    }
}

/// HOMY: restore anything removed from the sidebar, Finder-style.
struct CustomizeSidebarSheet: View {
    @State private var layout = SidebarLayout.load()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Pinned") {
                toggle("Home", "row:home")
                toggle("Describe Contents", "row:semantic")
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
            ForEach(HomyCategory.allCases) { category in
                toggle(category.title, "row:cat:" + category.rawValue)
            }
        case .smartFolders:
            ForEach(HomySmartFolder.allCases) { smart in
                toggle(smart.title, "row:smart:" + smart.rawValue)
            }
        case .locations:
            toggle("iCloud Drive", "row:loc:icloud")
            toggle((NSHomeDirectory() as NSString).lastPathComponent, "row:loc:home")
        case .tags:
            ForEach(SidebarTags.values, id: \.0) { name, _ in
                toggle(name, "row:tag:" + name)
            }
        case .favorites, .collections, .savedSearches:
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
