import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// HOME: the sidebar is a real NSTableView — the same control Finder uses — so
// drag-and-drop reordering comes from AppKit itself: the row lifts as a drag
// image, the other rows open a gap, and the drop animates natively. Every
// sidebar row is draggable, not just favorites; section headers drag their
// whole section. Item order persists per section in SidebarLayout.itemOrder.

/// One renderable row: either a section header or a sidebar item.
enum SidebarEntry: Equatable {
    case header(SidebarSection)
    case item(SidebarItem)

    var section: SidebarSection? {
        switch self {
        case .header(let section): return section
        case .item(let item): return item.section
        }
    }
}

/// A single sidebar row. `id` orders the row inside its section; `route`
/// selects it; `run` marks action rows ("New Collection…"); `volume` carries
/// eject state. Items are rebuilt from `SidebarState` on every change.
struct SidebarItem: Equatable {
    enum Kind {
        case pinnedHome, pinnedSearch, recents
        case category(HomeCategory)
        case smart(HomeSmartFolder)
        case rule(HomeSmartRule)
        case collection(HomeCollection)
        case savedSearch(SavedSearch)
        case favorite(path: String)
        case iCloud, homeFolder
        case volume(MountedVolume)
        case tag(name: String, color: NSColor)
        case newSmartFolder, newCollection
    }

    let id: String  // stable order key inside the section
    let section: SidebarSection?
    let route: String?
    let title: String
    let symbol: String
    var dot: NSColor?
    var kind: Kind
    var run: (() -> Void)?

    static func == (lhs: SidebarItem, rhs: SidebarItem) -> Bool { lhs.id == rhs.id }

    var hiddenID: String { "row:" + id }
}

/// The callbacks the table needs back into the browser.
struct SidebarTableActions {
    var select: (String) -> Void
    var removeFavorite: (String) -> Void
    var openInNewTab: (URL) -> Void
    var addFavoriteFolders: ([URL]) async -> Bool
    var eject: (MountedVolume) -> Void
}

/// Builds the flat row list: pinned rows, then one header row per visible
/// section followed by its visible, order-aware items.
@MainActor enum SidebarEntries {
    static func build(state: SidebarState, actions: SidebarTableActions) -> [SidebarEntry] {
        var entries: [SidebarEntry] = []
        let layout = state.layout

        if !layout.isHidden("row:home") {
            entries.append(.item(SidebarItem(
                id: "home", section: nil, route: "home", title: "Home",
                symbol: "house.fill", kind: .pinnedHome)))
        }
        if !layout.isHidden("row:semantic") {
            entries.append(.item(SidebarItem(
                id: "semantic", section: nil, route: "semantic", title: "Search",
                symbol: "text.magnifyingglass", kind: .pinnedSearch)))
        }
        if !layout.isHidden("row:recents") {
            entries.append(.item(SidebarItem(
                id: "recents", section: nil, route: "recents", title: "Recents",
                symbol: "clock", kind: .recents)))
        }

        for section in layout.visibleSections {
            entries.append(.header(section))
            if !layout.isCollapsed(section) {
                entries.append(
                    contentsOf: items(section: section, state: state, actions: actions))
            }
        }
        return entries
    }

    private static func items(
        section: SidebarSection, state: SidebarState, actions: SidebarTableActions
    ) -> [SidebarEntry] {
        let layout = state.layout
        switch section {
        case .categories:
            let current = HomeCategory.allCases
                .filter { !layout.isHidden("row:cat:" + $0.rawValue) }
                .map { "cat:" + $0.rawValue }
            return ordered(current: current, section: section, layout: layout)
                .compactMap { id in
                    guard let category = HomeCategory(rawValue: String(id.dropFirst(4))) else {
                        return nil
                    }
                    return .item(SidebarItem(
                        id: id, section: section, route: id, title: category.title,
                        symbol: category.symbol, kind: .category(category)))
                }

        case .smartFolders:
            var current = HomeSmartFolder.allCases
                .filter { !layout.isHidden("row:smart:" + $0.rawValue) }
                .map { "smart:" + $0.rawValue }
            current += HomeSmartRules.shared.items.map { "rule:" + $0.id.uuidString }
            var entries = ordered(current: current, section: section, layout: layout)
                .compactMap { id -> SidebarEntry? in
                    if id.hasPrefix("smart:") {
                        guard let smart = HomeSmartFolder(rawValue: String(id.dropFirst(6))) else {
                            return nil
                        }
                        return .item(SidebarItem(
                            id: id, section: section, route: id, title: smart.title,
                            symbol: smart.symbol, kind: .smart(smart)))
                    }
                    guard id.hasPrefix("rule:"),
                        let rule = HomeSmartRules.shared.items.first(where: {
                            "rule:" + $0.id.uuidString == id
                        })
                    else { return nil }
                    return .item(SidebarItem(
                        id: id, section: section, route: id, title: rule.name,
                        symbol: "slider.horizontal.3", kind: .rule(rule)))
                }
            return entries

        case .favorites:
            return layout.orderedIDs(section: section, current: state.favorites)
                .compactMap { path -> SidebarEntry? in
                    guard state.favorites.contains(path) else { return nil }
                    let label = FavoriteFolders.label(for: path)
                    return .item(SidebarItem(
                        id: path, section: section, route: path, title: label.name,
                        symbol: label.symbol, kind: .favorite(path: path)))
                }

        case .locations:
            var entries: [SidebarEntry] = []
            if !layout.isHidden("row:loc:icloud") {
                let path = NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs"
                entries.append(.item(SidebarItem(
                    id: "row:loc:icloud", section: section, route: path,
                    title: "iCloud Drive", symbol: "icloud", kind: .iCloud)))
            }
            if !layout.isHidden("row:loc:home") {
                let path = NSHomeDirectory()
                entries.append(.item(SidebarItem(
                    id: "row:loc:home", section: section, route: path,
                    title: (path as NSString).lastPathComponent, symbol: "house",
                    kind: .homeFolder)))
            }
            for volume in state.volumes {
                entries.append(.item(SidebarItem(
                    id: volume.id, section: section, route: volume.id, title: volume.name,
                    symbol: "externaldrive", kind: .volume(volume))))
            }
            return entries

        case .tags:
            let current = SidebarTags.values.map { "tag:" + $0.0 }
            return ordered(current: current, section: section, layout: layout).compactMap { id in
                guard let tag = SidebarTags.values.first(where: { "tag:" + $0.0 == id }) else {
                    return nil
                }
                if layout.isHidden("row:" + id) { return nil }
                return .item(SidebarItem(
                    id: id, section: section, route: id, title: tag.0, symbol: "circle.fill",
                    dot: NSColor(tag.1), kind: .tag(name: tag.0, color: NSColor(tag.1))))
            }
        }
    }

    /// Order the built-in ids (categories, smart folders, tags) through the
    /// persisted order; favorites/collections/saved searches already run
    /// through `orderedIDs` inline.
    private static func ordered(
        current: [String], section: SidebarSection, layout: SidebarLayout
    ) -> [String] {
        layout.orderedIDs(section: section, current: current)
    }
}

/// The native table. Owns drag-and-drop, selection sync, context menus,
/// type-select, and the eject buttons.
struct SidebarTableView: NSViewRepresentable {
    var state: SidebarState
    var actions: SidebarTableActions

    func makeCoordinator() -> SidebarTableCoordinator {
        SidebarTableCoordinator(actions: actions)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = SidebarNSTableView()
        table.identifier = NSUserInterfaceItemIdentifier("sidebarTable")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.rowHeight = 32
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .regular
        table.style = .inset
        table.focusRingType = .none
        table.allowsTypeSelect = true
        table.draggingDestinationFeedbackStyle = .gap
        // Section headers scroll away with their sections; no pinning.
        table.floatsGroupRows = false
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.registerForDraggedTypes([.fileURL, .sidebarItem, .sidebarSection])
        table.allowsEmptySelection = true
        table.backgroundColor = .clear
        table.coordinator = context.coordinator
        table.sizeLastColumnToFit()

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        // HOME: Finder look — the sidebar material and scroller run the full
        // window height under the titlebar (the browser adds ignoresSafeArea
        // on this view); rows clip below the titlebar via the content inset.
        scroll.verticalScroller?.scrollerStyle = .overlay
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        context.coordinator.scroll = scroll
        context.coordinator.observeWindow(scroll)
        context.coordinator.reapplyInsets()
        context.coordinator.rebuild(state: state)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.actions = actions
        guard coordinator.state != state else { return }
        // Selection-only changes just move the highlight; a reload here would
        // cancel an in-progress native drag.
        if let old = coordinator.state, old.structureMatches(state) {
            coordinator.state = state
            if old.selection != state.selection,
                let table = scroll.documentView as? NSTableView
            {
                coordinator.syncSelection(table: table)
            }
        } else {
            coordinator.rebuild(state: state)
        }
    }
}

extension NSPasteboard.PasteboardType {
    static let sidebarItem = NSPasteboard.PasteboardType("local.findersearch.sidebar.item")
    static let sidebarSection = NSPasteboard.PasteboardType("local.findersearch.sidebar.section")
}

final class SidebarNSTableView: NSTableView {
    // Finder-style sidebars have no alternating rows and no focus ring;
    // rows keep the window's sidebar material behind them.
    override var allowsVibrancy: Bool { true }
    weak var coordinator: SidebarTableCoordinator?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { coordinator?.observeWindow(self) }
        coordinator?.reapplyInsets()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: NSPoint(x: 0, y: convert(event.locationInWindow, from: nil).y))
        let menu = super.menu(for: event)
        NSLog("HEARTHMENU menu(for event) row=\(row) items=\(menu?.items.count ?? -1)")
        return menu
    }

}

@MainActor final class SidebarTableCoordinator: NSObject {
    var state: SidebarState?
    var actions: SidebarTableActions
    var entries: [SidebarEntry] = []
    weak var scroll: NSScrollView?
    private var cancellables: Set<AnyCancellable> = []
    private var suppressReload = false
    private var windowObserver: NSObjectProtocol?

    init(actions: SidebarTableActions) {
        self.actions = actions
        super.init()
        HomeSmartRules.shared.objectWillChange
            .sink { [weak self] _ in self?.reloadFromModel() }.store(in: &cancellables)
        HomeCollections.shared.objectWillChange
            .sink { [weak self] _ in self?.reloadFromModel() }.store(in: &cancellables)
        SavedSearches.shared.objectWillChange
            .sink { [weak self] _ in self?.reloadFromModel() }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: SidebarLayout.changed)
            .sink { [weak self] _ in self?.reloadFromModel() }.store(in: &cancellables)
    }

    private func reloadFromModel() {
        guard let state else { return }
        guard !suppressReload else { return }
        rebuild(state: state)
    }

    // MARK: window geometry — material runs under the titlebar glass like
    // Finder's sidebar; the first row clears the titlebar plus a breath.

    func observeWindow(_ view: NSView) {
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: view.window, queue: .main
        ) { [weak self] _ in self?.reapplyInsets() }
    }

    func reapplyInsets() {
        guard let scroll, let window = scroll.window else { return }
        let titlebar = window.frame.height - window.contentLayoutRect.maxY
        guard titlebar > 0 else { return }  // window not settled; didUpdate retries
        let target = NSEdgeInsets(top: titlebar + 8, left: 0, bottom: 0, right: 0)
        let current = scroll.contentInsets
        if current.top != target.top {
            scroll.contentInsets = target
        }
    }

    func rebuild(state: SidebarState) {
        self.state = state
        entries = SidebarEntries.build(state: state, actions: actions)
        guard let table = scroll?.documentView as? NSTableView else { return }
        // Finder eases reorders in; a short crossfade matches it.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.allowsImplicitAnimation = true
            table.reloadData()
        }
        syncSelection(table: table)
    }


    // MARK: selection

    func entry(at row: Int) -> SidebarEntry? {
        entries.indices.contains(row) ? entries[row] : nil
    }

    func row(forRoute route: String) -> Int? {
        entries.firstIndex {
            if case .item(let item) = $0 { return item.route == route }
            return false
        }
    }

    func syncSelection(table: NSTableView) {
        guard let state else { return }
        let row = state.selection.flatMap { row(forRoute: $0) } ?? -1
        if table.selectedRowIndexes != IndexSet(integer: row) {
            syncingSelection = true
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            syncingSelection = false
        }
        scrollDocumentToVisible(row: row)
    }

    private var syncingSelection = false

    private func scrollDocumentToVisible(row: Int) {
        guard row >= 0, let table = scroll?.documentView as? NSTableView else { return }
        let rect = table.rect(ofRow: row)
        if let documentRect = scroll?.documentVisibleRect, !documentRect.contains(rect) {
            table.scrollRowToVisible(row)
        }
    }

    private func didSelect(row: Int, table: NSTableView) {
        guard !syncingSelection, let state, let entry = entry(at: row) else { return }
        switch entry {
        case .header(let section):
            // Finder behavior: click a section header to collapse or open it,
            // with the native slide animation.
            var layout = SidebarLayout.load()
            layout.toggleCollapsed(section)
            let rows = IndexSet(
                entries.indices.filter { index in
                    if case .item(let item) = entries[index] {
                        return item.section == section
                    }
                    return false
                })
            suppressReload = true
            layout.save()
            suppressReload = false
            let collapsed = layout.isCollapsed(section)
            if let current = self.state {
                var updated = current
                updated.layout = layout
                self.state = updated
                entries = SidebarEntries.build(state: updated, actions: actions)
            }
            table.beginUpdates()
            if collapsed {
                table.removeRows(at: rows, withAnimation: .effectGap)
            } else {
                table.insertRows(at: rows, withAnimation: .effectGap)
            }
            table.endUpdates()
            table.deselectRow(row)
            table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        case .item(let item):
            if let run = item.run {
                run()
                table.deselectRow(row)
            } else if let route = item.route, route != state.selection {
                actions.select(route)
            }
        }
    }

    // MARK: context menus

    func menu(for row: Int) -> NSMenu? {
        NSLog("HEARTHSIDE menu(for:\(row)) entries=\(entries.count) state=\(state != nil)")
        guard let entry = entry(at: row), let state else { return nil }
        switch entry {
        case .header(let section):
            return headerMenu(section)
        case .item(let item):
            return itemMenu(item, state: state)
        }
    }

    private func headerMenu(_ section: SidebarSection) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(removeSectionItem(section))
        menu.addItem(customizeItem())
        return menu
    }

    private func removeSectionItem(_ section: SidebarSection) -> NSMenuItem {
        let item = NSMenuItem(
            title: "Remove from Sidebar", action: #selector(removeSection(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = section
        return item
    }

    private func customizeItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Customize Sidebar…", action: #selector(openCustomize(_:)), keyEquivalent: "")
        item.target = self
        return item
    }

    private func itemMenu(_ item: SidebarItem, state: SidebarState) -> NSMenu? {
        let menu = NSMenu()
        func add(_ title: String, _ selector: Selector, _ object: Any? = nil) {
            let menuItem = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = object
            menu.addItem(menuItem)
        }
        switch item.kind {
        case .favorite(let path):
            add("Open", #selector(openPath(_:)), path)
            add("Open in New Tab", #selector(openInNewTab(_:)), path)
            add("Reveal in Finder", #selector(revealPath(_:)), path)
            menu.addItem(.separator())
            add("Remove from Sidebar", #selector(removeFavoriteRow(_:)), path)
        case .volume(let volume):
            add("Open", #selector(openPath(_:)), volume.id)
            add("Open in New Tab", #selector(openInNewTab(_:)), volume.id)
            add("Reveal in Finder", #selector(revealPath(_:)), volume.id)
            if volume.canEject {
                menu.addItem(.separator())
                let ejectItem = NSMenuItem(
                    title: "Eject \u{201C}\(volume.name)\u{201D}",
                    action: #selector(ejectRow(_:)), keyEquivalent: "")
                ejectItem.target = self
                ejectItem.representedObject = volume.id
                ejectItem.isEnabled = !state.ejectingVolumes.contains(volume.id)
                menu.addItem(ejectItem)
            }
        case .iCloud, .homeFolder:
            if let route = item.route {
                add("Open", #selector(openPath(_:)), route)
                add("Open in New Tab", #selector(openInNewTab(_:)), route)
                add("Reveal in Finder", #selector(revealPath(_:)), route)
                menu.addItem(.separator())
            }
            add("Remove from Sidebar", #selector(removeRow(_:)), item.hiddenID)
        case .rule(let rule):
            let edit = NSMenuItem(title: "Edit…", action: #selector(editRule(_:)), keyEquivalent: "")
            edit.target = self
            edit.representedObject = rule
            menu.addItem(edit)
            menu.addItem(.separator())
            add("Delete", #selector(deleteRule(_:)), rule.id)
        case .savedSearch(let entry):
            add("Run Search", #selector(runSavedSearch(_:)), entry)
            menu.addItem(.separator())
            add("Remove", #selector(deleteSavedSearch(_:)), entry)
        case .collection(let collection):
            add("Add Folder…", #selector(addCollectionFolders(_:)), collection.id)
            add("Rename…", #selector(renameCollection(_:)), collection.id)
            menu.addItem(.separator())
            for path in collection.folders {
                let name = URL(fileURLWithPath: path).lastPathComponent
                let remove = NSMenuItem(
                    title: "Remove \(name)", action: #selector(removeCollectionFolder(_:)),
                    keyEquivalent: "")
                remove.target = self
                remove.representedObject = [collection.id, path]
                remove.isEnabled = collection.folders.count > 1
                menu.addItem(remove)
            }
            if !collection.folders.isEmpty { menu.addItem(.separator()) }
            add("Delete Collection", #selector(deleteCollection(_:)), collection.id)
        case .newSmartFolder, .newCollection:
            return nil
        case .pinnedHome, .pinnedSearch, .recents, .category, .smart, .tag:
            add("Remove from Sidebar", #selector(removeRow(_:)), item.hiddenID)
            menu.addItem(customizeItem())
        }
        return menu.items.isEmpty ? nil : menu
    }

    @objc private func removeSection(_ sender: NSMenuItem) {
        guard let section = sender.representedObject as? SidebarSection else { return }
        var layout = SidebarLayout.load()
        layout.setHidden("sec:" + section.rawValue, true)
        layout.save()
    }

    @objc private func openCustomize(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: SidebarLayout.customize, object: nil)
    }

    @objc private func removeRow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var layout = SidebarLayout.load()
        layout.setHidden(id, true)
        layout.save()
    }

    @objc private func removeFavoriteRow(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        actions.removeFavorite(path)
    }

    @objc private func openPath(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        actions.select(path)
    }

    @objc private func openInNewTab(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        actions.openInNewTab(URL(fileURLWithPath: path, isDirectory: true))
    }

    @objc private func revealPath(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func ejectRow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
            let volume = state?.volumes.first(where: { $0.id == id })
        else { return }
        actions.eject(volume)
    }

    @objc private func editRule(_ sender: NSMenuItem) {
        guard let rule = sender.representedObject as? HomeSmartRule else { return }
        NotificationCenter.default.post(name: .homeEditSmartRule, object: rule)
    }

    @objc private func deleteRule(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        HomeSmartRules.shared.remove(id)
    }

    @objc private func runSavedSearch(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? SavedSearch else { return }
        SavedSearches.shared.run(entry, select: actions.select)
    }

    @objc private func deleteSavedSearch(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? SavedSearch else { return }
        SavedSearches.shared.remove(entry)
    }

    @objc private func addCollectionFolders(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        HomeCollections.addFoldersPanel(to: id)
    }

    @objc private func renameCollection(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
            let collection = HomeCollections.shared.items.first(where: { $0.id == id })
        else { return }
        if let name = HomeCollections.promptName(
            title: "Rename Collection", initial: collection.name)
        {
            HomeCollections.shared.rename(id, to: name)
        }
    }

    @objc private func removeCollectionFolder(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [Any],
            let id = payload.first as? UUID, let path = payload.last as? String
        else { return }
        HomeCollections.shared.removeFolder(path, from: id)
    }

    @objc private func deleteCollection(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        HomeCollections.shared.remove(id)
    }
}

extension Notification.Name {
    static let homeEditSmartRule = Notification.Name("home.editSmartRule")
}

// MARK: - NSTableView plumbing

extension SidebarTableCoordinator: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        switch entry(at: row) {
        case .header(let section):
            let cell = tableView.makeView(
                withIdentifier: NSUserInterfaceItemIdentifier("header"), owner: nil
            ) as? SidebarHeaderCell ?? SidebarHeaderCell(frame: .zero)
            cell.configure(section: section, coordinator: self, row: row)
            return cell
        case .item(let item):
            let cell = tableView.makeView(
                withIdentifier: NSUserInterfaceItemIdentifier("item"), owner: nil
            ) as? SidebarItemCell ?? SidebarItemCell(frame: .zero)
            cell.configure(
                item: item, selected: tableView.selectedRowIndexes.contains(row),
                ejecting: state?.ejectingVolumes.contains(item.id) ?? false,
                coordinator: self, row: row)
            return cell
        case nil:
            return nil
        }
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = entry(at: row) { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        // Headers must be selectable for AppKit to start a drag on them;
        // group rows draw no selection, and didSelect ignores them anyway.
        if case .header = entry(at: row) { return true }
        switch entry(at: row) {
        case .item(let item): return item.run == nil || item.route != nil
        default: return false
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        NSLog("HEARTHSIDE selectionDidChange row=\((notification.object as? NSTableView)?.selectedRow ?? -1)")
        guard let table = notification.object as? NSTableView, table === scroll?.documentView
        else { return }
        let row = table.selectedRow
        guard row >= 0 else { return }
        didSelect(row: row, table: table)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        // HOME: Finder's measured rhythm — 32pt row pitch, 56pt of air above
        // each section header, ~24pt below the header to the first row.
        if case .header = entry(at: row) { return 78 }
        return 32
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int)
        -> String?
    {
        if case .item(let item) = entry(at: row) { return item.title }
        return nil
    }

    // MARK: drag source

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        NSLog("HEARTHSIDE writer row=\(row)")
        guard let entry = entry(at: row) else { return nil }
        switch entry {
        case .header(let section):
            let writer = NSPasteboardItem()
            writer.setString(section.rawValue, forType: .sidebarSection)
            return writer
        case .item(let item):
            // Volumes and action rows don't reorder.
            if case .volume = item.kind { return nil }
            if item.run != nil, item.route == nil { return nil }
            guard let section = entry.section else { return nil }
            let writer = NSPasteboardItem()
            writer.setString(item.id, forType: .sidebarItem)
            writer.setString(section.rawValue, forType: .sidebarSection)
            return writer
        }
    }

    // MARK: drop destination

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation)
        -> NSDragOperation
    {
        NSLog("HEARTHSIDE validateDrop row=\(row) op=\(dropOperation.rawValue) types=\(info.draggingPasteboard.types ?? [])")
        // External file drops land anywhere and become favorites.
        if info.draggingPasteboard.types?.contains(NSPasteboard.PasteboardType.fileURL) == true {
            tableView.setDropRow(entries.count, dropOperation: .above)
            return .copy
        }
        guard (info.draggingSource as? NSTableView) === tableView,
            let payload = dragPayload(info)
        else { return [] }
        // Cross-section item drops are invalid; only headers move sections.
        let valid: Bool
        switch payload {
        case .section:
            valid = true
        case .item(_, let sourceSection):
            valid = Self.section(forInsertionAtRow: row, entries: entries) == sourceSection
        }
        guard valid else { return [] }
        // AppKit proposes .on by default; reorder always inserts between rows.
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool
    {
        NSLog("HEARTHSIDE acceptDrop row=\(row)")
        // External file drops anywhere in the sidebar become favorites.
        if info.draggingPasteboard.types?.contains(NSPasteboard.PasteboardType.fileURL) == true {
            var urls: [URL] = []
            for item in info.draggingPasteboard.pasteboardItems ?? [] {
                if let data = item.data(forType: .fileURL),
                    let url = try? URL(dataRepresentation: data, relativeTo: nil)
                {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else { return false }
            let add = actions.addFavoriteFolders
            Task { _ = await add(urls) }
            return true
        }
        guard let payload = dragPayload(info) else { return false }
        switch payload {
        case .section(let raw):
            guard let section = SidebarSection(rawValue: raw) else { return false }
            return acceptSectionDrop(section, targetRow: row)
        case .item(let id, let sourceSection):
            return acceptItemDrop(id: id, section: sourceSection, targetRow: row)
        }
    }

    private enum DragPayload {
        case section(String)
        case item(id: String, section: SidebarSection)
    }

    private func dragPayload(_ info: NSDraggingInfo) -> DragPayload? {
        let pasteboard = info.draggingPasteboard
        if let raw = pasteboard.string(forType: .sidebarSection) {
            if pasteboard.string(forType: .sidebarItem) != nil {
                guard let section = SidebarSection(rawValue: raw) else { return nil }
                return .item(id: pasteboard.string(forType: .sidebarItem) ?? "", section: section)
            }
            return .section(raw)
        }
        return nil
    }

    /// The section a drop gap above `row` belongs to — governed by the row
    /// above the gap: a header means the gap starts that section, an item
    /// means the gap trails that item's section.
    static func section(forInsertionAtRow row: Int, entries: [SidebarEntry]) -> SidebarSection? {
        let above = row - 1
        guard above >= 0, above < entries.count else { return nil }
        switch entries[above] {
        case .header(let section): return section
        case .item(let item): return item.section
        }
    }

    private func acceptSectionDrop(_ section: SidebarSection, targetRow: Int) -> Bool {
        var layout = SidebarLayout.load()
        let visible = layout.visibleSections
        guard visible.contains(section) else { return false }
        let ordered = Self.sectionOrder(
            visible: visible, dragged: section, targetRow: targetRow, entries: entries)
        guard ordered != visible else { return false }
        // Hidden sections keep trailing (they return via Customize).
        layout.sections = ordered + layout.sections.filter { !ordered.contains($0) }
        layout.save()
        return true
    }

    private func acceptItemDrop(id: String, section: SidebarSection, targetRow: Int) -> Bool {
        guard let state else { return false }
        let current = currentIDs(section: section, state: state)
        guard current.contains(id) else { return false }
        var ordered = state.layout.orderedIDs(section: section, current: current)
        guard let sourceIndex = ordered.firstIndex(of: id) else { return false }
        var insertIndex = Self.itemInsertionIndex(
            entries: entries, section: section, orderableIDs: current, targetRow: targetRow)
        // A downward move's gap count includes the dragged row itself.
        if insertIndex > sourceIndex { insertIndex -= 1 }
        guard insertIndex != sourceIndex else { return false }
        ordered.remove(at: sourceIndex)
        ordered.insert(id, at: min(max(insertIndex, 0), ordered.count))

        var layout = SidebarLayout.load()
        layout.setOrder(section: section, ordered)
        layout.save()
        return true
    }

    /// The insertion index inside a section's own orderable list for a drop
    /// gap above `targetRow`: how many of the section's orderable items sit
    /// above the gap. Pure so the reorder math is unit-testable.
    static func itemInsertionIndex(
        entries: [SidebarEntry], section: SidebarSection, orderableIDs: [String], targetRow: Int
    ) -> Int {
        var insertIndex = 0
        for index in 0..<min(targetRow, entries.count) {
            if case .item(let item) = entries[index], item.section == section,
                orderableIDs.contains(item.id)
            {
                insertIndex += 1
            }
        }
        return insertIndex
    }

    /// Pure section reorder: where a header dropped with a gap above
    /// `targetRow` lands among the visible sections.
    static func sectionOrder(
        visible: [SidebarSection], dragged: SidebarSection, targetRow: Int, entries: [SidebarEntry]
    ) -> [SidebarSection] {
        guard let currentIndex = visible.firstIndex(of: dragged) else { return visible }
        var slot = visible.count
        if targetRow < entries.count {
            switch entries[targetRow] {
            case .header(let target):
                slot = visible.firstIndex(of: target) ?? slot
            case .item(let item):
                if let targetSection = item.section,
                    let index = visible.firstIndex(of: targetSection)
                {
                    slot = index + 1
                }
            }
        }
        var ordered = visible
        ordered.removeAll { $0 == dragged }
        let clamped = max(0, slot > currentIndex ? slot - 1 : slot)
        ordered.insert(dragged, at: min(clamped, ordered.count))
        return ordered
    }

    private func currentIDs(section: SidebarSection, state: SidebarState) -> [String] {
        entries.compactMap { entry in
            if case .item(let item) = entry, item.section == section,
                !item.id.hasPrefix("action:")
            {
                return item.id
            }
            return nil
        }
    }
}

// MARK: - Cells

final class SidebarHeaderCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private weak var coordinator: SidebarTableCoordinator?
    private var row = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("header")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        for view in [chevron, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            chevron.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(section: SidebarSection, coordinator: SidebarTableCoordinator, row: Int) {
        label.stringValue = section.title
        self.coordinator = coordinator
        self.row = row
        // Finder's disclosure: chevron points right when collapsed, down when open.
        let open = !SidebarLayout.load().isCollapsed(section)
        let name = open ? "chevron.down" : "chevron.right"
        chevron.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    override var menu: NSMenu? {
        get { coordinator?.menu(for: row) }
        set { super.menu = newValue }
    }
}

final class SidebarItemCell: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let ejectButton = NSButton(title: "", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private weak var coordinator: SidebarTableCoordinator?
    private var row = 0
    private var volumeID: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("item")
        for view in [icon, label, ejectButton, spinner] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        label.cell?.wraps = false
        ejectButton.bezelStyle = .regularSquare
        ejectButton.isBordered = false
        ejectButton.image = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: nil)
        ejectButton.contentTintColor = .secondaryLabelColor
        ejectButton.target = self
        ejectButton.action = #selector(ejectClicked)
        spinner.controlSize = .small
        spinner.style = .spinning
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            ejectButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            ejectButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            ejectButton.widthAnchor.constraint(equalToConstant: 20),
            spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        item: SidebarItem, selected: Bool, ejecting: Bool,
        coordinator: SidebarTableCoordinator, row: Int
    ) {
        label.stringValue = item.title
        self.coordinator = coordinator
        self.row = row
        label.textColor = selected ? .alternateSelectedControlTextColor : .labelColor

        if let dot = item.dot {
            icon.image = Self.dotSwatch(dot)
            icon.contentTintColor = nil
        } else {
            icon.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            icon.contentTintColor = .controlAccentColor
        }

        if case .volume(let volume) = item.kind, volume.canEject {
            volumeID = volume.id
            spinner.isHidden = !ejecting
            ejectButton.isHidden = ejecting
            ejectButton.isEnabled = !ejecting
            ejectButton.toolTip = ejecting ? "Ejecting \(volume.name)…" : "Eject \(volume.name)"
        } else {
            volumeID = nil
            spinner.isHidden = true
            ejectButton.isHidden = true
        }
    }

    @objc private func ejectClicked() {
        guard let volumeID, let coordinator else { return }
        if let volume = coordinator.state?.volumes.first(where: { $0.id == volumeID }) {
            coordinator.actions.eject(volume)
        }
    }

    /// Action rows ("New Collection…") aren't selectable; a click runs them.
    override func mouseDown(with event: NSEvent) {
        NSLog("HEARTHHIT cell mouseDown configuredRow=\(row)")
        if let coordinator, let table = coordinator.scroll?.documentView as? NSTableView {
            let local = table.convert(event.locationInWindow, from: nil)
            NSLog("HEARTHHIT table row(at:) = \(table.row(at: NSPoint(x: 0, y: local.y))), cellRow=\(row)")
        }
        if let coordinator, case .item(let item) = coordinator.entry(at: row),
            item.run != nil, item.route == nil
        {
            item.run?()
            return
        }
        super.mouseDown(with: event)
    }

    override var menu: NSMenu? {
        get { coordinator?.menu(for: row) }
        set { super.menu = newValue }
    }

    private static func dotSwatch(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 11, height: 11), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
