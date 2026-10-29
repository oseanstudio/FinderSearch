import AppKit
import Combine
import SwiftUI

/// HOME: the browser toolbar is a real NSToolbar — the same control Finder
/// uses — so its buttons, hover, search field, and titlebar sizing come from
/// AppKit itself instead of SwiftUI approximations.
@MainActor
final class NativeToolbarController: NSObject, NSToolbarDelegate {
    private let model: SearchModel
    private let workspace: BrowserWorkspace
    private var cancellables: Set<AnyCancellable> = []
    private weak var window: NSWindow?
    private var toolbar: NSToolbar?

    private weak var backItem: NSToolbarItem?
    private weak var forwardItem: NSToolbarItem?
    private weak var segment: NSSegmentedControl?
    private weak var sortMenu: NSMenu?
    private weak var shareItem: NSSharingServicePickerToolbarItem?
    private weak var tagsMenu: NSMenu?
    private weak var actionsMenu: NSMenu?
    private var bellButton: NSButton?
    private var bellPopover: NSPopover?
    private(set) weak var searchItem: NSSearchToolbarItem?
    private var splitIsOn: () -> Bool = { false }
    private var toggleSplit: () -> Void = {}
    private var terminalIsOn: () -> Bool = { false }
    private var toggleTerminal: () -> Void = {}

    /// Posted when the updates bell is clicked; the browser shows its panel.
    var showUpdates: () -> Void = {}

    init(model: SearchModel, workspace: BrowserWorkspace, showUpdates: @escaping () -> Void) {
        self.model = model
        self.workspace = workspace
        self.showUpdates = showUpdates
        super.init()
    }

    // MARK: installation

    func install(
        on window: NSWindow,
        split: (isOn: () -> Bool, toggle: () -> Void),
        terminal: (isOn: () -> Bool, toggle: () -> Void),
        showUpdates: @escaping () -> Void
    ) {
        self.splitIsOn = split.isOn
        self.toggleSplit = split.toggle
        self.terminalIsOn = terminal.isOn
        self.toggleTerminal = terminal.toggle
        self.showUpdates = showUpdates
        install(on: window)
    }

    func install(on window: NSWindow) {
        if self.window === window, let toolbar { window.toolbar = toolbar; return }
        cancellables.removeAll()
        let toolbar = NSToolbar(identifier: "hearth.browser")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        self.toolbar = toolbar
        self.window = window
        bind()
    }

    func detach() {
        window?.toolbar = nil
        window = nil
        toolbar = nil
        cancellables.removeAll()
    }

    private func bind() {
        model.$backStack.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.syncNavigation()
        }.store(in: &cancellables)
        model.$forwardStack.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.syncNavigation()
        }.store(in: &cancellables)
        model.$viewMode.receive(on: DispatchQueue.main).sink { [weak self] mode in
            self?.selectSegment(matching: mode.title)
        }.store(in: &cancellables)
        model.$selection.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.syncSelectionState()
        }.store(in: &cancellables)
        model.$busy.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.syncSelectionState()
        }.store(in: &cancellables)
        model.$route.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.syncTitle()
        }.store(in: &cancellables)
        model.$query.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.syncTitle()
        }.store(in: &cancellables)
        model.$route.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.syncSortState()
        }.store(in: &cancellables)
        model.$sort.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.syncSortState()
        }.store(in: &cancellables)
    }

    private func syncTitle() {
        window?.title = model.isSearch ? "Searching \u{201C}\(model.query)\u{201D}" : model.title
    }

    private func selectSegment(matching title: String) {
        guard let segment else { return }
        for index in 0..<segment.segmentCount {
            if segment.label(forSegment: index) == title {
                segment.selectedSegment = index
                return
            }
        }
    }

    private func syncNavigation() {
        backItem?.isEnabled = !model.backStack.isEmpty
        forwardItem?.isEnabled = !model.forwardStack.isEmpty
    }

    private func syncSelectionState() {
        let hasSelection = !model.selection.isEmpty
        for menu in [tagsMenu, actionsMenu].compactMap({ $0 }) {
            for item in menu.items {
                if let action = item.action {
                    switch action {
                    case #selector(performOpen), #selector(performInfo),
                        #selector(performQuickLook), #selector(performRename),
                        #selector(performDuplicate), #selector(performCut),
                        #selector(performCopy), #selector(performCopyPath),
                        #selector(performTrash), #selector(performReveal):
                        item.isEnabled = hasSelection && !model.busy
                    case #selector(performPaste), #selector(performPasteHere),
                        #selector(performNewFolder), #selector(performNewTextFile):
                        item.isEnabled = !model.busy && model.canWriteHere
                    default:
                        break
                    }
                }
                for sub in item.submenu?.items ?? [] { _ = sub }
            }
        }
        shareItem?.isEnabled = hasSelection
    }

    private func syncSortState() {
        for item in sortMenu?.items ?? [] {
            item.state = item.representedObject as? FileSort == model.sort ? .on : .off
        }
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        itemIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        itemIdentifiers
    }

    private var itemIdentifiers: [NSToolbarItem.Identifier] {
        [
            .backForward, .viewSwitcher, .sortItem, .shareItem, .tagsItem, .actionsItem,
            .splitItem, .terminalItem, .updatesItem, .flexibleSpace, .searchItem,
        ]
    }



    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .backForward:
            let group = NSToolbarItemGroup(itemIdentifier: .backForward)
            let back = makeItem(
                identifier: .init("back"), symbol: "chevron.left", help: "Back",
                action: #selector(performBack))
            let forward = makeItem(
                identifier: .init("forward"), symbol: "chevron.right", help: "Forward",
                action: #selector(performForward))
            group.subitems = [back, forward]
            backItem = back
            forwardItem = forward
            syncNavigation()
            return group
        case .viewSwitcher:
            let item = NSToolbarItem(itemIdentifier: .viewSwitcher)
            item.visibilityPriority = .low
            let control = NSSegmentedControl()
            for mode in FileViewMode.allCases {
                control.segmentCount += 1
                control.setLabel(mode.title, forSegment: control.segmentCount - 1)
                if let symbol = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: nil) {
                    control.setImage(
                        symbol.withSymbolConfiguration(
                            .init(pointSize: 13, weight: .regular)), forSegment: control.segmentCount - 1)
                }
            }
            control.segmentStyle = .texturedRounded
            control.trackingMode = .selectOne
            control.target = self
            control.action = #selector(performViewSwitch(_:))
            selectSegment(matching: model.viewMode.title)
            item.view = control
            item.label = "View"
            segment = control
            let size = NSSize(width: 168, height: 26)
            item.minSize = size
            item.maxSize = size
            return item
        case .sortItem:
            let item = NSToolbarItem(itemIdentifier: .sortItem)
            item.label = "Sort"
            let menu = NSMenu()
            for sort in FileSort.allCases {
                let entry = NSMenuItem(
                    title: sort.rawValue, action: #selector(performSort(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = sort
                menu.addItem(entry)
            }
            menu.addItem(.separator())
            menu.addItem(
                menuItem("New Smart Folder…", #selector(performNewRule(_:))))
            menu.autoenablesItems = false
            menu.items.forEach { $0.isEnabled = true }
            let wrapper = NSMenuItem(title: "Sort", action: nil, keyEquivalent: "")
            wrapper.submenu = menu
            item.menuFormRepresentation = wrapper
            item.isBordered = true
            item.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "Sort")
            sortMenu = menu
            syncSortState()
            return item
        case .shareItem:
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: .shareItem)
            item.delegate = self
            shareItem = item
            return item
        case .tagsItem:
            let item = NSToolbarItem(itemIdentifier: .tagsItem)
            item.label = "Tags"
            let menu = NSMenu()
            for (name, _) in SidebarTags.values {
                let entry = NSMenuItem(title: name, action: #selector(performTag(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = name
                menu.addItem(entry)
            }
            let wrapper = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
            wrapper.submenu = menu
            item.menuFormRepresentation = wrapper
            item.isBordered = true
            item.image = NSImage(systemSymbolName: "tag", accessibilityDescription: "Tags")
            tagsMenu = menu
            return item
        case .actionsItem:
            let item = NSToolbarItem(itemIdentifier: .actionsItem)
            item.label = "Actions"
            item.menuFormRepresentation = actionsMenuItem()
            item.isBordered = true
            item.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Actions")
            actionsMenu = item.menuFormRepresentation?.submenu
            syncSelectionState()
            return item
        case .splitItem:
            let item = NSToolbarItem(itemIdentifier: .splitItem)
            item.label = "Split Panes"
            item.isBordered = true
            item.image = NSImage(
                systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Split Panes")
            item.target = self
            item.action = #selector(performToggleSplit(_:))
            item.toolTip = splitIsOn() ? "Close Split Panes (F3)" : "Split Panes (F3)"
            return item
        case .terminalItem:
            let item = NSToolbarItem(itemIdentifier: .terminalItem)
            item.label = "Terminal"
            item.isBordered = true
            item.image = NSImage(
                systemSymbolName: "terminal", accessibilityDescription: "Terminal")
            item.target = self
            item.action = #selector(performToggleTerminal(_:))
            item.toolTip = terminalIsOn() ? "Close Terminal (F4)" : "Terminal (F4)"
            return item
        case .updatesItem:
            let item = NSToolbarItem(itemIdentifier: .updatesItem)
            item.label = "Updates"
            let button = NSButton(
                image: NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: "Updates")!,
                target: self, action: #selector(performUpdates(_:)))
            button.bezelStyle = .texturedRounded
            button.isBordered = false
            button.imagePosition = .imageOnly
            item.view = button
            let size = NSSize(width: 30, height: 26)
            item.minSize = size
            item.maxSize = size
            bellButton = button
            return item
        case .searchItem:
            let item = NSSearchToolbarItem(itemIdentifier: .searchItem)
            item.searchField.placeholderString = "Search"
            item.searchField.target = self
            item.searchField.action = #selector(performSearchSubmit(_:))
            item.resignsFirstResponderWithCancel = true
            searchItem = item
            return item
        default:
            return nil
        }
    }

    private func makeItem(
        identifier: NSToolbarItem.Identifier, symbol: String, help: String, action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        item.isBordered = true
        item.target = self
        item.action = action
        item.toolTip = help
        item.isEnabled = false
        return item
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        return item
    }

    private func actionsMenuItem() -> NSMenuItem {
        let wrapper = NSMenuItem(title: "Actions", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in actionsEntries() { menu.addItem(item) }
        wrapper.submenu = menu
        return wrapper
    }

    private func actionsEntries() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        func add(_ title: String, _ action: Selector) {
            items.append(menuItem(title, action))
        }
        add("Open", #selector(performOpen))
        add("Open in New Tab", #selector(performOpenTab))
        items.append(.separator())
        add("Get Info", #selector(performInfo))
        add("Quick Look", #selector(performQuickLook))
        add("Rename…", #selector(performRename))
        add("Duplicate", #selector(performDuplicate))
        items.append(.separator())
        add("Cut", #selector(performCut))
        add("Copy", #selector(performCopy))
        add("Copy Path", #selector(performCopyPath))
        add("Paste Items", #selector(performPaste))
        add("Move Items Here", #selector(performPasteHere))
        items.append(.separator())
        add("New Folder", #selector(performNewFolder))
        add("New Text File", #selector(performNewTextFile))
        add("Show in Finder", #selector(performReveal))
        items.append(.separator())
        add("Move to Trash", #selector(performTrash))
        return items
    }

    // MARK: search plumbing

    func beginSearch() {
        searchItem?.beginSearchInteraction()
    }

    var searchText: String {
        get { searchItem?.searchField.stringValue ?? "" }
        set { searchItem?.searchField.stringValue = newValue }
    }

    // MARK: actions

    @objc private func performBack() { model.goBack() }
    @objc private func performForward() { model.goForward() }

    @objc private func performViewSwitch(_ sender: NSSegmentedControl) {
        guard
            let label = sender.label(forSegment: sender.selectedSegment),
            let mode = FileViewMode.allCases.first(where: { $0.title == label })
        else { return }
        model.viewMode = mode
    }

    @objc private func performSort(_ sender: NSMenuItem) {
        if let sort = sender.representedObject as? FileSort { model.sort = sort }
        syncSortState()
    }

    @objc private func performNewRule(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: .homeEditSmartRule, object: nil)
    }

    @objc private func performTag(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { model.tag(name) }
    }

    @objc private func performToggleSplit(_ sender: NSToolbarItem) {
        toggleSplit()
        sender.toolTip = splitIsOn() ? "Close Split Panes (F3)" : "Split Panes (F3)"
    }

    @objc private func performToggleTerminal(_ sender: NSToolbarItem) {
        toggleTerminal()
        sender.toolTip = terminalIsOn() ? "Close Terminal (F4)" : "Terminal (F4)"
    }

    @objc private func performUpdates(_ sender: NSButton) {
        showUpdates()
    }

    /// HOME: the updates popover anchored to the toolbar bell (click outside
    /// closes it, like a menu).
    func presentUpdatesPopover(content: NSViewController, relativeTo button: NSButton) {
        let popover = NSPopover()
        popover.contentViewController = content
        popover.behavior = .transient
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @objc private func performSearchSubmit(_ sender: NSSearchField) {
        model.query = sender.stringValue
        model.submitSearch()
    }

    @objc private func performOpen() { model.open() }
    @objc private func performOpenTab() {
        if let hit = model.selected, hit.isFolder { workspace.newTab(hit.url) }
    }
    @objc private func performInfo() { model.info() }
    @objc private func performQuickLook() { model.preview = model.selected }
    @objc private func performRename() { model.renameItems() }
    @objc private func performDuplicate() { model.duplicate() }
    @objc private func performCut() { model.cut() }
    @objc private func performCopy() { model.copy() }
    @objc private func performCopyPath() { model.copyPath() }
    @objc private func performPaste() { model.paste() }
    @objc private func performPasteHere() { model.paste(move: true) }
    @objc private func performNewFolder() { model.newFolder() }
    @objc private func performNewTextFile() { model.newTextFile() }
    @objc private func performReveal() { model.reveal() }
    @objc private func performTrash() { model.trash() }
}

extension NativeToolbarController: NSSharingServicePickerToolbarItemDelegate {
    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        model.selectedItems.map(\.url)
    }
}

extension NSToolbarItem.Identifier {
    static let backForward = NSToolbarItem.Identifier("hearth.backForward")
    static let splitItem = NSToolbarItem.Identifier("hearth.split")
    static let terminalItem = NSToolbarItem.Identifier("hearth.terminal")
    static let viewSwitcher = NSToolbarItem.Identifier("hearth.viewSwitcher")
    static let sortItem = NSToolbarItem.Identifier("hearth.sort")
    static let shareItem = NSToolbarItem.Identifier("hearth.share")
    static let tagsItem = NSToolbarItem.Identifier("hearth.tags")
    static let actionsItem = NSToolbarItem.Identifier("hearth.actions")
    static let updatesItem = NSToolbarItem.Identifier("hearth.updates")
    static let searchItem = NSToolbarItem.Identifier("hearth.search")
}
