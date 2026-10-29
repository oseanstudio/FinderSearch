import SwiftUI
import AppKit
import Quartz
import UniformTypeIdentifiers

@main struct FinderSearchApp: App {
    init() { LegacyDefaults.migrate() }  // HOME: carry pre-rename settings over
    @Environment(\.openWindow) private var openWindow
    @FocusedObject private var model: SearchModel?
    @FocusedObject private var workspace: BrowserWorkspace?
    var body: some Scene {
        WindowGroup(id: "browser") {
            BrowserRoot().frame(minWidth: 850, minHeight: 470).onAppear {
                ApplicationIcon.registerBundle()
                NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
            }
        }
        .defaultSize(width: 1050, height: 680).windowToolbarStyle(.unified)
        MenuBarExtra("Hearth", systemImage: "magnifyingglass") {  // HOME
            MenuBarDownloadsView()
        }
        // Window style: the menu needs a live text field for its search bar.
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Window") { openWindow(id: "browser") }.keyboardShortcut("n")
                Button("New Tab") { workspace?.newTab() }.keyboardShortcut("t")
                Button("Reopen Closed Tab") { workspace?.reopenClosedTab() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(workspace?.closedTabs.isEmpty != false)
                Button("New Folder") { model?.newFolder() }.keyboardShortcut(
                    "n", modifiers: [.command, .shift]
                ).disabled(model?.busy != false || model?.canWriteHere != true)
                Button("Open…") { model?.chooseFolder() }.keyboardShortcut(
                    "o", modifiers: [.command, .option])
            }
            CommandGroup(replacing: .undoRedo) {
                Button(model?.undoStack.last.map { "Undo \($0.name)" } ?? "Undo") {
                    textOrFile("undo:") { model?.undo() }
                }.keyboardShortcut("z")
                Button(model?.redoStack.last.map { "Redo \($0.name)" } ?? "Redo") {
                    textOrFile("redo:") { model?.redo() }
                }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") { textOrFile("cut:") { model?.cut() } }.keyboardShortcut("x")
                Button("Copy") { textOrFile("copy:") { model?.copy() } }.keyboardShortcut("c")
                Button("Paste Items") { textOrFile("paste:") { model?.paste() } }.keyboardShortcut(
                    "v")
                Button("Move Items Here") { model?.paste(move: true) }.keyboardShortcut(
                    "v", modifiers: [.command, .option]
                ).disabled(model?.busy != false || model?.canWriteHere != true)
                Button("Select All") {
                    textOrFile("selectAll:") {
                        if let model { model.selection = Set(model.sortedHits.map(\.path)) }
                    }
                }.keyboardShortcut("a")
            }
            CommandGroup(after: .newItem) {
                Button("Open Selected") { model?.open() }.keyboardShortcut("o").disabled(
                    model?.selection.isEmpty != false)
                Button("Rename…") { model?.renameItems() }.disabled(
                    model?.selection.isEmpty != false || model?.busy == true)
                Button("Compress") { model?.compress() }.disabled(
                    model?.selection.isEmpty != false || model?.busy == true
                        || model?.canWriteHere != true)
                Button("Extract ZIP") { model?.extract() }.disabled(
                    model?.selectedItems.contains { $0.url.pathExtension.lowercased() == "zip" }
                        != true || model?.busy == true)
                Button("Duplicate") { model?.duplicate() }.keyboardShortcut("d").disabled(
                    model?.selection.isEmpty != false || model?.busy == true)
                Button("Move to Trash") {
                    textOrFile("deleteToBeginningOfLine:") { model?.trash() }
                }.keyboardShortcut(.delete)
                Button("Get Info") { model?.info() }.keyboardShortcut("i").disabled(
                    model?.selection.isEmpty != false)
                Button("Quick Look") { model?.preview = model?.selected }.keyboardShortcut("y")
                    .disabled(model?.selection.isEmpty != false)
            }
            CommandMenu("Go") {
                Button("Back") { model?.goBack() }.keyboardShortcut("[").disabled(
                    model?.backStack.isEmpty != false)
                Button("Forward") { model?.goForward() }.keyboardShortcut("]").disabled(
                    model?.forwardStack.isEmpty != false)
                Button("Enclosing Folder") {
                    if let model { model.navigate(model.location.deletingLastPathComponent()) }
                }.keyboardShortcut(.upArrow)
                Button("Go to Folder…") { model?.goToFolder() }.keyboardShortcut(
                    "g", modifiers: [.command, .shift])
                Button("Connect to Server…") {  // HOME: mounts SMB/AFP shares
                    connectToServerPrompt()
                }.keyboardShortcut("k")
                Divider()
                ForEach(GoDestination.allCases) { destination in
                    Button(destination.title) { model?.sidebar(destination.route) }
                        .keyboardShortcut(KeyEquivalent(destination.key), modifiers: destination.modifiers)
                        .disabled(model?.busy != false)
                }
            }
            CommandGroup(after: .toolbar) {
                ForEach(FileViewMode.allCases.indices, id: \.self) { index in
                    Button("As \(FileViewMode.allCases[index].title)") {
                        model?.viewMode = FileViewMode.allCases[index]
                    }.keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                }
                Button("Show Hidden Files") { model?.showHidden.toggle() }.keyboardShortcut(
                    ".", modifiers: [.command, .shift])
                Button("Refresh") { model?.schedule() }.keyboardShortcut("r")
                Button("Search") {
                    NotificationCenter.default.post(name: .focusSearch, object: nil)
                }.keyboardShortcut("f")
            }
            CommandMenu("Hearth") {  // HOME
                HomeCommandMenu(model: model)
            }
        }
    }
    private func textOrFile(_ selector: String, action: () -> Void) {
        if NSApp.keyWindow?.firstResponder is NSTextView {
            NSApp.sendAction(NSSelectorFromString(selector), to: nil, from: nil)
        } else {
            action()
        }
    }
}
extension Notification.Name { static let focusSearch = Notification.Name("focusSearch") }
struct BrowserRoot: View {
    @StateObject private var workspace = BrowserWorkspace(sessionDefaults: .standard)
    var body: some View {
        BrowserView(workspace: workspace, model: workspace.current)
            .focusedSceneObject(workspace).focusedSceneObject(workspace.current)
    }
}

struct BrowserView: View {
    @ObservedObject var workspace: BrowserWorkspace
    @ObservedObject var model: SearchModel
    @ObservedObject private var updates = UpdateCenter.shared  // HOME
    @State private var showUpdates = false  // HOME
    // HOME: sidebar layout; a plain @State so the EquatableView on the
    // sidebar sees the change (UserDefaults alone would not re-render it).
    @State private var sidebarLayout = SidebarLayout.load()
    @State private var showSidebarCustomize = false
    // HOME: embedded terminal drawer (F4) and dual panes (F3), like Shark.
    @State private var showTerminal = false
    @State private var terminalSession = HearthTerminalSession()
    @State private var showSplitPane = false
    @State private var splitModel = SearchModel()
    private enum KeyboardFocus: Hashable { case files, search }
    @FocusState private var keyboardFocus: KeyboardFocus?
    private var searchFocused: Bool { keyboardFocus == .search }
    // HOME: the toolbar search field's focus bridge (kept as a property so the
    // body expression stays inside the type-checker's budget).
    private var searchFocusBinding: Binding<Bool> {
        Binding(
            get: { keyboardFocus == .search },
            set: { keyboardFocus = $0 ? .search : nil })
    }
    // HOME: kept as properties so the body stays inside the type-checker budget.
    private var toolbarSortMenu: some View {
        Menu {
            Picker("Sort By", selection: $model.sort) {
                ForEach(FileSort.allCases, id: \.self) { sort in
                    Text(sort.rawValue).tag(sort)
                }
            }
            Toggle("Ascending", isOn: $model.ascending)
            Toggle("Show Hidden Files", isOn: $model.showHidden)
            Button("New Smart Folder…") {  // HOME: sidebar row was removed
                NotificationCenter.default.post(name: .homeEditSmartRule, object: nil)
            }
        } label: {
            GlassToolbarIcon(symbol: "arrow.up.arrow.down")
        }.help("Sort")
    }

    // HOME: split-panes and terminal toggles (Shark's F3/F4).
    private var toolbarSplitToggle: some View {
        Button {
            toggleSplitPane()
        } label: {
            GlassToolbarIcon(
                symbol: "rectangle.split.2x1",
                tint: showSplitPane ? Color.accentColor : Color.primary)
        }
        .help(showSplitPane ? "Close Split Panes (F3)" : "Split Panes (F3)")
    }

    private var toolbarTerminalToggle: some View {
        Button {
            showTerminal.toggle()
        } label: {
            GlassToolbarIcon(
                symbol: "terminal",
                tint: showTerminal ? Color.accentColor : Color.primary)
        }
        .help(showTerminal ? "Close Terminal (F4)" : "Terminal (F4)")
    }

    private var toolbarSearch: some View {
        let isExpanded = searchFocused || !model.query.isEmpty
        return ToolbarSearchButton(
            field: {
                ToolbarSearchField(
                    text: $model.query,
                    focused: searchFocusBinding,
                    onSubmit: { model.submitSearch() })
            },
            expand: { keyboardFocus = .search },
            expanded: isExpanded)
    }

    // HOME: reveal target while its folder loads (menu bar panel requests).
    @State private var revealTarget: String?
    // HOME: the rule builder, presented from the sidebar's context menu.
    @State private var editingRule: HomeSmartRule?
    @State private var showRuleBuilder = false
    @State private var fileNavigationActive = false
    @State private var keyMonitor: Any?
    @State private var browserWindow: NSWindow?
    // HOME: persisted so the zoom survives relaunches (bitmaps cap at 512px).
    @AppStorage("home.iconSize") private var iconSize: Double = 64
    // HOME: the user's column count for icon view — 0 means auto. Only the
    // keyboard shortcuts and the menu change it; the slider never does.
    @AppStorage("home.iconColumns") private var userColumns: Int = 0
    // HOME: show each item's size under its name in icon view (Finder's
    // "Show Item Info"); the Large Files route always shows sizes.
    @AppStorage("home.showItemInfo") private var showItemInfo = false
    @State private var gridWidth: Double = 0
    // HOME: the biggest thumbnail the current columns can show without
    // sideways scrolling; the slider's upper bound.
    @State private var iconSizeCeiling: Double = 256
    @State private var gridColumns = 5
    // HOME: the icon size actually drawn (capped by the fixed cell width).
    @State private var cellIconSize: Double = 64
    // HOME: type-select buffer (keystrokes within one second join the prefix).
    @State private var typeSelectBuffer = ""
    @State private var typeSelectReset: Task<Void, Never>?
    private let tags = SidebarTags.values
    var body: some View {
        NavigationSplitView {
            BrowserSidebar(
                state: SidebarState(
                    route: model.route, favorites: workspace.favorites,
                    volumes: workspace.volumes, ejectingVolumes: workspace.ejectingVolumes,
                    showDiskAccessHint: model.ready && !model.fullDiskAccess,
                    layout: sidebarLayout),  // HOME
                select: { route in
                    fileNavigationActive = false; model.sidebar(route)
                },
                removeFavorite: { workspace.removeFavorite($0) },
                openInNewTab: { workspace.newTab($0) },
                addFavoriteFolders: { await workspace.addFavoriteFolders($0) },
                eject: { volume in workspace.eject(volume) { model.error = $0 } }
            ).equatable()
        } detail: {
            VStack(spacing: 0) {
                detailHeader
                detailBody
                detailFooter
            }
            .navigationTitle(model.isSearch ? "Searching “\(model.query)”" : model.title)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    ControlGroup {
                        Button {
                            model.goBack()
                        } label: {
                            Image(systemName: "chevron.left")
                        }.disabled(model.backStack.isEmpty).help("Back")
                        Button {
                            model.goForward()
                        } label: {
                            Image(systemName: "chevron.right")
                        }.disabled(model.forwardStack.isEmpty).help("Forward")
                    }
                }
                ToolbarItem {
                    ViewModePicker(selection: $model.viewMode)
                        .frame(width: 150, height: 28)
                        .padding(.horizontal, 6)
                }
                ToolbarItem {
                    toolbarSortMenu
                }
                ToolbarItem {
                    ShareLink(items: model.selectedItems.map(\.url)) {
                        GlassToolbarIcon(symbol: "square.and.arrow.up")
                    }.disabled(model.selection.isEmpty).help("Share")
                }
                ToolbarItem {
                    Menu {
                        ForEach(tags, id: \.0) { name, _ in Button(name) { model.tag(name) } }
                    } label: {
                        GlassToolbarIcon(symbol: "tag")
                    }.disabled(model.selection.isEmpty).help("Tags")
                }
                ToolbarItem {
                    Menu {
                        actions
                    } label: {
                        GlassToolbarIcon(symbol: "ellipsis")
                    }.help("Actions")
                }
                // HOME: split-panes and terminal toggles (Shark's F3/F4).
                ToolbarItem {
                    toolbarSplitToggle
                }
                ToolbarItem {
                    toolbarTerminalToggle
                }
                ToolbarItem {  // HOME: update badge
                    updatesBadgeButton
                }
                // HOME: Finder-style search — a compact circle at rest that
                // expands into the field on click; see ToolbarSearchField for
                // why .searchable can't be used.
                ToolbarItem {
                    toolbarSearch
                }
            }
        }
        .background(BrowserWindowCapture { browserWindow = $0 }.frame(width: 0, height: 0))
        .background(
            MouseNavigationTarget { command in
                guard !model.busy, model.preview == nil else { return false }
                if command == .back { model.goBack() } else { model.goForward() }
                return true
            }.frame(width: 0, height: 0)
        )
        .onAppear {
            model.start()
            installKeyMonitor()
            QuickSearchController.shared.installHotkey()  // HOME
            updates.startMonitoring()  // HOME
        }
        .onChange(of: model.id) { _, _ in
            keyboardFocus = nil; fileNavigationActive = false
            model.start(); installKeyMonitor()
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
            fileNavigationActive = false; model.sort = .relevance; keyboardFocus = .search
        }
        .onReceive(NotificationCenter.default.publisher(for: .homeRunSavedSearch)) { note in  // HOME
            guard NSApp.keyWindow === browserWindow,
                let query = note.userInfo?["query"] as? String
            else { return }
            model.query = query
        }
        .onReceive(NotificationCenter.default.publisher(for: .homeShowUpdates)) { _ in  // HOME
            showUpdates = true
        }
        .onReceive(NotificationCenter.default.publisher(for: SidebarLayout.changed)) { _ in  // HOME
            sidebarLayout = SidebarLayout.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: SidebarLayout.customize)) { _ in  // HOME
            showSidebarCustomize = true
        }
        .sheet(isPresented: $showSidebarCustomize) {  // HOME
            CustomizeSidebarSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .homeEditSmartRule)) { note in  // HOME
            editingRule = note.object as? HomeSmartRule
            showRuleBuilder = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .homeRevealInHearth)) { note in  // HOME
            guard let url = note.userInfo?["url"] as? URL else { return }
            revealInHearth(url)
        }
        .sheet(isPresented: $showRuleBuilder) {  // HOME
            SmartRuleSheet(rule: editingRule)
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)
        ) { _ in workspace.refreshVolumes() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in workspace.refreshVolumes() }  // HOME: SMB shares mounted meanwhile
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)
        ) { _ in workspace.refreshVolumes() }
        .onChange(of: model.hits) { _, _ in selectRevealTargetIfLoaded() }  // HOME
        .onChange(of: model.viewMode) { _, _ in
            model.cancelRename()
            model.extraHits = []; model.selection.formIntersection(Set(model.hits.map(\.path)))
        }
        .onChange(of: model.renaming) { _, hit in
            if hit != nil {
                keyboardFocus = nil; fileNavigationActive = false
            } else if !searchFocused {
                fileNavigationActive = true
            }
        }
        .onChange(of: keyboardFocus) { _, focus in
            if focus == KeyboardFocus.search { fileNavigationActive = false }
        }
        .onChange(of: model.query) { _, text in
            if model.isSearch && model.sort != .relevance { model.sort = .relevance }
        }
        .task(id: model.id) { await model.monitor() }
        .sheet(item: $model.conflict) { conflict in
            ConflictSheet(conflict: conflict) { choice, all in
                model.resolveConflict(choice, applyToAll: all)
            }
            .interactiveDismissDisabled()
        }
        .sheet(item: $model.batchRename) { request in
            BatchRenameSheet(model: model, request: request)
        }
        .onChange(of: model.preview) { _, hit in  // HOME: Quick Look in its own resizable window
            if hit != nil {
                QuickLookWindowController.shared.present(model)
            } else if QuickLookWindowController.shared.shows(model) {
                QuickLookWindowController.shared.dismiss()
            }
        }
    }
    /// HOME: bring the window forward, open the file's folder and select it —
    /// Hearth's own reveal, used by the menu bar panel.
    private func revealInHearth(_ url: URL) {
        NSApp.activate(ignoringOtherApps: true)
        browserWindow?.makeKeyAndOrderFront(nil)
        let parent = url.deletingLastPathComponent()
        if model.location != parent { model.navigate(parent) }
        revealTarget = url.path
        selectRevealTargetIfLoaded()
    }

    private func selectRevealTargetIfLoaded() {
        guard let target = revealTarget,
            let hit = model.sortedHits.first(where: { $0.path == target })
        else { return }
        revealTarget = nil
        model.select(hit, extending: false, toggling: false)
        model.selectionNavigation.send((hit.path, false))
    }

    private var detailHeader: some View {
        VStack(spacing: 0) {
            if workspace.tabs.count > 1 { BrowserTabBar(workspace: workspace) }
            if model.isSearch { searchScopeBar; HomeSearchChipsBar(model: model) }  // HOME
            if model.error != nil { errorBanner; Divider() }
        }
    }

    private var detailBody: some View {
        paneContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contextMenu { backgroundActions }
            .modifier(SafeBackgroundDropTarget(model: model))
            .focusable(model.viewMode == .icons || model.viewMode == .gallery)
            .focused($keyboardFocus, equals: .files).focusEffectDisabled()
    }

    /// The Search route has its own single bottom row; the shared bar's
    /// crumbs, item count and icon slider mean nothing there.
    private var detailFooter: some View {
        VStack(spacing: 0) {
            if HomeRoute(model.route) != .semantic { bottomBar }
            if showTerminal {  // HOME: Shark-style terminal drawer (F4)
                TerminalPanel(
                    session: terminalSession, isPresented: $showTerminal,
                    currentDirectory: model.location)
            }
        }
    }

    private var errorBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
            Text(model.error ?? "").font(.callout).textSelection(.enabled)
            Spacer()
            Button {
                model.error = nil
            } label: {
                Image(systemName: "xmark")
            }.buttonStyle(.plain)
        }.padding(12).background(Color(nsColor: .controlBackgroundColor))
    }

    // HOME: split panes (Shark's F3) — the file area beside a second one.
    @ViewBuilder private var paneContent: some View {
        if showSplitPane {
            HSplitView {
                fileContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                splitPane.frame(minWidth: 320, idealWidth: 320, maxWidth: 420)
            }
        } else {
            fileContent.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var splitPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {  // Shark's pane header
                Circle().fill(Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                Text(splitModel.location.lastPathComponent)
                    .font(.system(size: 11)).lineLimit(1)
                Spacer()
                Button {
                    showSplitPane = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close Split View (F3)")
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            Divider()
            SplitPaneBrowser(model: splitModel, contextMenu: { AnyView(backgroundActions) })
        }
    }

    // HOME: split panes (Shark's F3) — a second browsing pane beside the
    // first, starting in the same folder.
    private func toggleSplitPane() {
        showSplitPane.toggle()
        if showSplitPane {
            splitModel = SearchModel()
            splitModel.navigate(model.location)
        }
    }

    private func installKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let browserWindow, NSApp.keyWindow === browserWindow else { return event }
            if let command = TabShortcut.command(for: event), !browserWindow.isSheet {
                if command == .new { workspace.newTab() } else { workspace.reopenClosedTab() }
                return nil
            }
            // HOME: F3 splits panes, F4 toggles the terminal drawer.
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                let characters = event.charactersIgnoringModifiers,
                let scalar = characters.unicodeScalars.first
            {
                if scalar.value == 0xF705 && !browserWindow.isSheet {  // F3
                    toggleSplitPane()
                    return nil
                }
                if scalar.value == 0xF706 && !browserWindow.isSheet {  // F4
                    showTerminal.toggle()
                    return nil
                }
            }
            // HOME: ⌘=/⌘− zoom thumbnails (column count follows the size).
            if event.modifierFlags.contains(.command), !event.modifierFlags.contains(.option) {
                if event.keyCode == 24 {  // = and +
                    zoomIcons(+32)
                    return nil
                }
                if event.keyCode == 27 {  // -
                    zoomIcons(-32)
                    return nil
                }
            }
            if searchFocused && event.keyCode == 125 && !model.sortedHits.isEmpty {
                focusFiles(); model.select(model.sortedHits[0], extending: false, toggling: false)
                model.selectionNavigation.send((model.sortedHits[0].path, false)); return nil
            }
            guard NSApp.keyWindow?.isSheet != true, model.preview == nil,
                fileNavigationActive && !searchFocused,
                !(NSApp.keyWindow?.firstResponder is NSTextView)
            else { return event }
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                // HOME: type-select — typing jumps through filenames by prefix
                // ("godot" lands on the first godot* item, cycling as you go).
                if event.specialKey == nil,
                    event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                    let characters = event.charactersIgnoringModifiers,
                    !characters.isEmpty,
                    characters.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value != 127 })
                {
                    typeSelectBuffer += characters
                    typeSelectReset?.cancel()
                    typeSelectReset = Task {
                        try? await Task.sleep(for: .seconds(1))
                        typeSelectBuffer = ""
                    }
                    model.selectTypeAhead(typeSelectBuffer)
                    return nil
                }
                if event.keyCode == 49 { model.preview = model.selected; return nil }
                if event.keyCode == 36 { model.rename(); return nil }
                if event.keyCode == 53 { model.selection = []; return nil }
                if (model.viewMode == .icons || model.viewMode == .gallery
                    || (model.viewMode == .columns && [125, 126].contains(event.keyCode))),
                    [123, 124, 125, 126].contains(event.keyCode)
                {
                    let stride = model.viewMode == .icons ? gridColumns : 1
                    let delta =
                        event.keyCode == 123
                        ? -1
                        : event.keyCode == 124 ? 1 : event.keyCode == 125 ? stride : -stride
                    model.moveSelection(
                        by: delta, extending: event.modifierFlags.contains(.shift))
                    return nil
                }
            }
            if event.modifierFlags.contains(.command), event.keyCode == 125 {
                model.open(); return nil
            }
            return event
        }
    }
    private var searchScopeBar: some View {
        HStack(spacing: 10) {
            Text("Search:").foregroundStyle(.secondary)
            // HOME: on a category or smart-folder route the search narrows to
            // it; the control makes that visible and widens in one click.
            if HomeRoute(model.route)?.engineQuery != nil {
                Picker("Scope", selection: $model.homeSearchWholeDisk) {
                    Text("In \(model.title)").tag(false)
                    Text("This Mac").tag(true)
                }.pickerStyle(.segmented)
                    .controlSize(.small)
                    .labelsHidden()
                    .frame(width: 230)
            } else {
                Button("This Mac") { model.scope = "" }.buttonStyle(.bordered).tint(
                    model.scope.isEmpty ? .accentColor : .secondary)
                Button(model.location.lastPathComponent) { model.scope = model.location.path }
                    .buttonStyle(.bordered).tint(model.scope.isEmpty ? .secondary : .accentColor)
            }
            Spacer()
            Picker("Kind", selection: $model.fileType) {
                Text("Any Kind").tag(""); Text("Folder").tag("dir"); Text("Document").tag("doc");
                Text("Image").tag("image"); Text("Movie").tag("video"); Text("Audio").tag("audio")
            }.labelsHidden().frame(width: 130)
        }.font(.system(size: 12)).padding(.horizontal, 16).padding(.vertical, 7).background(
            Color(nsColor: .controlBackgroundColor))
    }
    @ViewBuilder private var fileContent: some View {
        if let home = HomeSpecialContent(model: model, workspace: workspace) {  // HOME
            home.id(model.id)
        } else if model.viewMode == .columns && model.canWriteHere {
            ColumnBrowser(model: model, focusFiles: { focusFiles() }, rowMenu: rowActions).id(
                model.id)
        } else if (model.loading || model.searching) && model.sortedHits.isEmpty {
            FolderLoadingSkeleton(mode: model.viewMode, iconSize: iconSize)
        } else if model.sortedHits.isEmpty {
            ContentUnavailableView {
                Label(
                    model.isSearch ? "No Results" : "No Items",
                    systemImage: model.isSearch ? "magnifyingglass" : "folder")
            } description: {
                Text(
                    model.isSearch
                        ? "Try a different name or search location." : "This folder is empty.")
            }
        } else {
            switch model.viewMode {
            case .icons: iconGrid.id(model.id)
            case .list: fileTable
            case .columns:
                fileTable
            case .gallery:
                GalleryBrowser(model: model, select: select, rowMenu: rowActions).id(model.id)
            }
        }
    }
    private var iconGrid: some View {
        GeometryReader { geometry in
            iconScroll(minHeight: geometry.size.height)
                .onAppear { updateColumns(geometry.size.width) }
                .onChange(of: geometry.size.width) { _, width in updateColumns(width) }
                .onChange(of: iconSize) { _, _ in updateColumns(geometry.size.width) }
                .onChange(of: userColumns) { _, _ in
                    updateColumns(gridWidth > 0 ? gridWidth : geometry.size.width)
                }
        }
    }
    private func updateColumns(_ width: Double) {
        // HOME: the column count is the user's (shortcuts or menu; 0 = auto).
        // The grid never scrolls sideways: thumbnails cap at the cell, and
        // the slider's range ends exactly there — its max is the biggest
        // size the current columns can show. ⌘= removes a column to raise
        // that ceiling.
        gridWidth = width
        let auto = max(1, Int((width - 36) / (64.0 + 69.0)))
        gridColumns = userColumns > 0 ? min(16, max(1, userColumns)) : auto
        let spacing = 14.0
        let natural = (width - 36 - spacing * Double(gridColumns - 1)) / Double(gridColumns)
        iconSizeCeiling = max(56, natural - 30)
        cellIconSize = max(40, min(iconSize, iconSizeCeiling))
    }

    // HOME: ⌘= zooms in by removing a column (bigger cells, bigger
    // thumbnails); ⌘− adds one. The slider is untouched.
    private func zoomIcons(_ delta: Double) {
        if delta > 0 {
            userColumns = max(1, gridColumns - 1)
        } else {
            userColumns = min(16, gridColumns + 1)
        }
    }
    private func iconScroll(minHeight: Double) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 14), count: gridColumns),
                    alignment: .leading, spacing: 18
                ) {
                    ForEach(model.sortedHits) { hit in iconCell(hit) }
                }.padding(18)
                    .frame(minHeight: minHeight, alignment: .top)
                    .marqueeSelection(model: model, focusFiles: focusFiles)
            }
            .scrollPosition(id: $model.scrollAnchor)
            .onReceive(model.selectionNavigation) { request in
                proxy.scrollTo(request.path)
            }
        }
    }
    private func iconCell(_ hit: Hit) -> some View {
        VStack(spacing: 6) {
            FileThumbnail(hit: hit, size: cellIconSize).frame(
                width: cellIconSize + 10, height: cellIconSize + 10)
            FileNameLabel(model: model, hit: hit, lineLimit: 2, centered: true)
                .frame(height: 32, alignment: .top)
            if showItemInfo || HomeRoute(model.route) == .smart(.large) {  // HOME
                Text(ByteCountFormatter.string(fromByteCount: Int64(hit.size), countStyle: .file))
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .modifier(CutAppearance(path: hit.path))
        .padding(6).frame(maxWidth: .infinity)
        .background(
            model.selection.contains(hit.path) ? Color.accentColor.opacity(0.22) : Color.clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .contentShape(Rectangle())
        .modifier(FileClickActions(select: { select(hit) }, open: { model.open(hit) }))
        .contextMenu { rowActions(hit) }.draggable(hit.url)
        .modifier(FolderDropTarget(hit: hit, model: model))
        .onHover { hovering in if hovering && hit.isFolder { model.prefetchFolder(hit.url) } }
        .marqueeItem(hit.path, in: model.id)
        .id(hit.path)
        .accessibilityLabel(hit.name).accessibilityAddTraits(
            model.selection.contains(hit.path) ? [.isSelected] : [])
    }
    private var fileTable: some View {
        FileList(
            model: model, focusFiles: focusFiles, newTab: { workspace.newTab($0) },
            addFavorite: { workspace.addFavorite($0) })
    }
    // HOME: one bottom row — breadcrumbs on the left, the item count and the
    // icon-size slider together on the right (upstream stacked two rows).
    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                if model.loading || model.searching || model.sorting || model.busy {
                    ProgressView().controlSize(.mini)
                }
                if let progress = model.operationProgress {
                    if let fraction = progress.fraction {
                        ProgressView(value: fraction).frame(width: 100)
                    }
                    Text("\(model.operationName) · \(progress.item)").lineLimit(1)
                        .truncationMode(.middle)
                    if progress.bytes > 0 {
                        Text(
                            ByteCountFormatter.string(
                                fromByteCount: progress.bytes, countStyle: .file)
                        )
                        .monospacedDigit()
                    }
                    Button("Cancel") { model.cancelOperation() }.controlSize(.small)
                }
                crumbs
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(model.isSearch ? model.query : model.location.path)
                Spacer(minLength: 8)
                statusCluster.fixedSize()
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 14)
                .frame(height: 28)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var crumbChevron: some View {
        Image(systemName: "chevron.right").font(.system(size: 8))
            .foregroundStyle(.tertiary)
    }

    /// The selected item's folder chain, root first.
    private func selectionAncestors(_ hit: Hit) -> [URL] {
        var result: [URL] = []
        var url = hit.url.deletingLastPathComponent()
        while true {
            result.insert(url, at: 0)
            if url.path == "/" { break }
            url.deleteLastPathComponent()
        }
        return result
    }

    private var crumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                if !model.isSearch,
                    model.route == "recents" || model.route.hasPrefix("tag:")
                        || HomeRoute(model.route) != nil  // HOME
                {
                    Label(
                        model.title,
                        systemImage:
                            model.route == "recents"
                            ? "clock" : model.route.hasPrefix("tag:")
                                ? "tag" : HomeRoute(model.route)?.symbol ?? "house")  // HOME
                    // HOME: smart folders gather files from all over, so the
                    // selected item's path is the only way to see where it is.
                    if let hit = model.selected {
                        ForEach(selectionAncestors(hit), id: \.path) { url in
                            crumbChevron
                            Button {
                                model.navigate(url)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(
                                        systemName: url.path == "/"
                                            ? "internaldrive" : "folder.fill"
                                    ).font(.system(size: 11));
                                    Text(
                                        url.path == "/"
                                            ? "Macintosh HD" : url.lastPathComponent
                                    ).lineLimit(1)
                                }
                            }.buttonStyle(.plain)
                        }
                        crumbChevron
                        Text(hit.name).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(model.ancestors, id: \.path) { url in
                        Button {
                            model.navigate(url)
                        } label: {
                            HStack(spacing: 4) {
                                Image(
                                    systemName: url.path == "/"
                                        ? "internaldrive" : "folder.fill"
                                ).font(.system(size: 11));
                                Text(url.path == "/" ? "Macintosh HD" : url.lastPathComponent)
                            }
                        }.buttonStyle(.plain)
                        if url != model.ancestors.last {
                            Image(systemName: "chevron.right").font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }.padding(.vertical, 6)
        }
    }

    /// The count/selection label next to the icon-size slider.
    private var statusCluster: some View {
        HStack(spacing: 6) {
            Text(
                model.selection.isEmpty
                    ? (model.isSearch && model.hits.count == 500
                        ? "First 500 matches" : "\(model.sortedHits.count) items")
                    : "\(model.selection.count) selected")
            if model.isSearch { Text(String(format: "· %.1f ms", model.elapsed)).monospacedDigit() }
            if model.viewMode == .icons {
                Image(systemName: "square").font(.system(size: 8));
                // HOME: the range tops out at the current columns' biggest
                // size; ⌘= raises the ceiling by removing a column.
                Slider(value: $iconSize, in: 40...max(56, iconSizeCeiling)).frame(width: 110)
                    .accessibilityLabel("Icon Size");
                Image(systemName: "square").font(.system(size: 13))
            }
        }
    }
    // HOME: toolbar bell for pending updates; the badge counts the repos. The
    // item always exists — appearing/disappearing toolbar items re-layout the
    // toolbar mid-session, which on this OS evicts the .searchable field into
    // an empty full-width row below the toolbar.
    private var updatesBadgeButton: some View {
        let pending = !updates.offers.isEmpty
        return Button {
            if pending { showUpdates = true }
        } label: {
            GlassToolbarIcon(symbol: "arrow.down.circle.fill", tint: Color.accentColor)
                .opacity(pending ? 1 : 0)
                .overlay(alignment: .topTrailing) {
                    if pending {
                        Text("\(updates.offers.count)")
                            .font(.system(size: 9, weight: .bold))
                            .padding(2).frame(minWidth: 12)
                            .background(Capsule().fill(Color.red))
                            .foregroundStyle(Color.white)
                            .offset(x: 6, y: -6)
                    }
                }
        }
        .disabled(!pending)
        .help(pending ? "Updates available" : "No pending updates")
        // HOME: a popover (not a sheet) — clicking outside dismisses it. The
        // item always exists, so the menu-bar trigger anchors here too.
        .popover(isPresented: $showUpdates, arrowEdge: .bottom) {
            UpdatesSheet()
        }
    }

    @ViewBuilder private var backgroundActions: some View {
        Menu("Sort By") {  // HOME: Finder's right-click sort menu
            Picker("Sort By", selection: $model.sort) {
                ForEach(FileSort.allCases, id: \.self) { sort in
                    Text(sort.rawValue).tag(sort)
                }
            }
            Divider()
            Picker("Direction", selection: $model.ascending) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            }
        }
        Divider()
        Button("New Folder") { model.newFolder() }.disabled(model.busy || !model.canWriteHere)
        Button("New Text File") { model.newTextFile() }.disabled(model.busy || !model.canWriteHere)
        Button("Paste Items") { model.paste() }.disabled(model.busy || !model.canWriteHere)
        Button("Move Items Here") { model.paste(move: true) }.disabled(
            model.busy || !model.canWriteHere)
        Divider()
        Button("Open in New Tab") { workspace.newTab(model.location) }.disabled(!model.canWriteHere)
        Button("Add Folder to Sidebar") { workspace.addFavorite(model.location) }.disabled(
            !model.canWriteHere)
        Divider()
        Menu("View") {
            ForEach(FileViewMode.allCases, id: \.self) { mode in
                Button(mode.title) { model.viewMode = mode }
            }
            Divider()
            Toggle("Split Panes (F3)", isOn: Binding(  // HOME
                get: { showSplitPane }, set: { _ in toggleSplitPane() }))
            Toggle("Terminal (F4)", isOn: Binding(  // HOME
                get: { showTerminal }, set: { _ in showTerminal.toggle() }))
            Divider()
            Menu("Icons per Row") {  // HOME: icon-view density; 0 = auto
                Button("Automatically") { userColumns = 0 }
                Divider()
                ForEach(1...10, id: \.self) { count in
                    Button("\(count) per Row") { userColumns = count }
                }
            }
            Toggle("Show File Sizes", isOn: $showItemInfo)  // HOME
        }
        Toggle("Show Hidden Files", isOn: $model.showHidden)
        Button("New Smart Folder…") {  // HOME: sidebar row was removed
            NotificationCenter.default.post(name: .homeEditSmartRule, object: nil)
        }
        Button("Refresh") { model.schedule() }.disabled(model.busy)
    }
    @ViewBuilder private var actions: some View {
        Button("Open") { model.open() }.disabled(model.selection.isEmpty)
        Button("Open in New Tab") {
            if let hit = model.selected, hit.isFolder { workspace.newTab(hit.url) }
        }.disabled(model.selected?.isFolder != true)
        Divider()
        Button("Get Info") { model.info() }.disabled(model.selection.isEmpty)
        Button("Quick Look") { model.preview = model.selected }.disabled(model.selection.isEmpty)
        Button("Rename…") { model.renameItems() }.disabled(model.selection.isEmpty || model.busy)
        Button("Duplicate") { model.duplicate() }.disabled(model.selection.isEmpty || model.busy)
        Button("Cut") { model.cut() }.disabled(model.selection.isEmpty || model.busy)
        Button("Copy") { model.copy() }.disabled(model.selection.isEmpty)
        Button("Copy Path") { model.copyPath() }.disabled(model.selection.isEmpty)
        Button("Paste Items") { model.paste() }.disabled(model.busy || !model.canWriteHere)
        Button("Move Items Here") { model.paste(move: true) }.disabled(
            model.busy || !model.canWriteHere)
        Divider()
        Button("New Folder") { model.newFolder() }.disabled(model.busy || !model.canWriteHere)
        Button("New Text File") { model.newTextFile() }.disabled(model.busy || !model.canWriteHere)
        Button("Add Folder to Sidebar") {
            workspace.addFavorite(
                model.selected?.isFolder == true ? model.selected!.url : model.location)
        }
        Button("Show in Finder") { model.reveal() }.disabled(model.selection.isEmpty)
        Divider()
        Button("Move to Trash") { model.trash() }.disabled(model.selection.isEmpty || model.busy)
    }
    @ViewBuilder private func rowActions(_ hit: Hit) -> some View {
        Button("Open") { model.open(hit) }
        OpenWithMenu(model: model, hit: hit)
        Button("Open in New Tab") { workspace.newTab(hit.url) }.disabled(!hit.isFolder)
        Button("Quick Look") { model.preview = hit }
        Button("Open Enclosing Folder") { model.navigate(hit.url.deletingLastPathComponent()) }
        Divider()
        Button("Get Info") {
            contextual(hit); model.info()
        }
        Button("Rename…") {
            contextual(hit); model.renameItems()
        }
        Button("Compress") {
            contextual(hit); model.compress()
        }.disabled(model.busy || !model.canWriteHere)
        Button("Extract ZIP") {
            contextual(hit); model.extract()
        }.disabled(model.busy || hit.url.pathExtension.lowercased() != "zip")
        Button("Duplicate") {
            contextual(hit); model.duplicate()
        }
        Button("Copy") {
            contextual(hit); model.copy()
        }
        Button("Copy Path") {
            contextual(hit); model.copyPath()
        }
        Menu("Tags") {
            ForEach(tags, id: \.0) { name, _ in
                Button(name) {
                    contextual(hit); model.tag(name)
                }
            }
        }
        Divider()
        Button("Move to Trash") {
            contextual(hit); model.trash()
        }
    }
    private func contextual(_ hit: Hit) {
        if !model.selection.contains(hit.path) { model.selection = [hit.path] }
    }
    private func focusFiles() {
        keyboardFocus = nil; fileNavigationActive = true
        if NSApp.keyWindow?.firstResponder is NSTextView {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }
    private func select(_ hit: Hit) {
        guard model.renaming?.path != hit.path else { return }
        focusFiles()
        model.select(
            hit, extending: NSEvent.modifierFlags.contains(.shift),
            toggling: NSEvent.modifierFlags.contains(.command))
    }

}

struct QuickLook: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        QLPreviewView(frame: .zero, style: .normal)!
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) != url as NSURL { view.previewItem = url as NSURL }
    }
}

// HOME: a real NSSearchField in the toolbar row. SwiftUI's .searchable gets
// demoted by narrow windows into a dedicated row at the top of the sidebar,
// and on this OS that row renders empty — the blank band users see above the
// sidebar. A plain toolbar item can't demote: at narrow widths it overflows
// into the standard toolbar overflow menu instead.
struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search"
        field.sendsWholeSearchString = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        let editor = field.currentEditor()
        let isActive =
            field.window?.firstResponder === editor
            || field.window?.firstResponder === field
        if focused, !isActive, let window = field.window {
            window.makeFirstResponder(field)
        } else if !focused, isActive {
            field.window?.makeFirstResponder(nil)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: ToolbarSearchField
        init(_ parent: ToolbarSearchField) { self.parent = parent }

        @objc func submit() { parent.onSubmit() }

        func controlTextDidBeginEditing(_ obj: Notification) {
            if !parent.focused { parent.focused = true }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            // Return keeps the field focused; only a real blur drops it.
            guard let field = obj.object as? NSSearchField, let window = field.window
            else { return }
            if window.firstResponder !== field.currentEditor() { parent.focused = false }
        }

        func control(
            _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else {
                return false
            }
            if !parent.text.isEmpty {
                parent.text = ""
            } else {
                parent.focused = false
                control.window?.makeFirstResponder(nil)
            }
            return true
        }
    }
}

// HOME: Finder's toolbar search shape — a small circle at rest that expands
// into the field when clicked (or while focused/holding text).
struct ToolbarSearchButton<Field: View>: View {
    @ViewBuilder var field: () -> Field
    var expand: () -> Void
    var expanded: Bool

    var body: some View {
        HStack(spacing: 0) {
            if expanded {
                field()
                    .frame(width: 200, height: 22)
                    .transition(.opacity)
            } else {
                Button(action: expand) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(.primary.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Search")
            }
        }
        .animation(.snappy(duration: 0.2), value: expanded)
    }
}


/// HOME: Finder's toolbar icon treatment — each action sits in the subtle
/// circular glass well the system gives Finder's buttons.
struct GlassToolbarIcon: View {
    let symbol: String
    var tint: Color? = nil
    @State private var hovering = false

    @Environment(\.isEnabled) private var isDisabled

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint ?? .primary)
            .frame(width: 26, height: 26)
            .background(
                Circle().fill(Color.primary.opacity(hovering ? 0.16 : 0.09)))
            .contentShape(Circle())
            .opacity(isDisabled ? 0.4 : 1)
            .onHover { if !isDisabled { hovering = $0 } }
    }
}


/// HOME: Finder's Connect to Server. The URL mounts through the system
/// (Finder handles any credential prompt); the share then appears under
/// Locations via the mount notifications.
@MainActor func connectToServerPrompt(refresh: @escaping () -> Void = {}) {
    let alert = NSAlert()
    alert.messageText = "Connect to Server"
    alert.informativeText = "Enter a server address, like smb://server/share"
    alert.addButton(withTitle: "Connect")
    alert.addButton(withTitle: "Cancel")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    field.placeholderString = "smb://server/share"
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    var text = field.stringValue.trimmingCharacters(in: .whitespaces)
    if text.isEmpty { return }
    if !text.contains("://") { text = "smb://" + text }
    guard let url = URL(string: text) else { return }
    NSWorkspace.shared.open(url)
    refresh()
}
