import SwiftUI
import AppKit

// HOMY: the menu-bar icon opens a compact panel, not a list of files: a
// search bar that searches this Mac from anywhere, one glance row (the
// latest download), free disk space, and a small footer. The old
// ten-download list is gone — files belong in the browser.

@MainActor final class MenuBarSearchModel: ObservableObject {
    @Published var query = "" { didSet { schedule() } }
    @Published var results: [Hit] = []
    @Published var searching = false
    private var task: Task<Void, Never>?
    private var generation = 0

    var hasQuery: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private func schedule() {
        generation += 1
        let revision = generation
        task?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else {
            results = []; searching = false
            return
        }
        searching = true
        task = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, revision == generation else { return }
            do {
                let reply = try await HomyServices.shared.engine.request([
                    "q": HomyQuery.translate(text), "limit": 6,
                ])
                guard revision == generation, !Task.isCancelled else { return }
                results = reply.ok ? (reply.hits ?? []) : []
                searching = false
            } catch {
                guard revision == generation else { return }
                results = []; searching = false
            }
        }
    }

    func open(_ hit: Hit) {
        _ = NSWorkspace.shared.open(hit.url)
        MenuBarDownloadsView.closeMenu()
    }

    func openFirst() {
        guard let hit = results.first else { return }
        open(hit)
    }
}

@MainActor final class MenuBarDownloadsModel: ObservableObject {
    @Published var files: [Hit] = []
    private var watcher: DispatchSourceFileSystemObject?

    func start() {
        guard watcher == nil else { return }
        refresh()
        let folder = URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
        let fd = Darwin.open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            self?.refresh(after: .milliseconds(600))
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        watcher = source
    }

    private var refreshTask: Task<Void, Never>?
    private func refresh(after delay: Duration = .zero) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            if let hits = try? await LocalFiles.load(
                URL(fileURLWithPath: NSHomeDirectory() + "/Downloads"), hidden: false)
            {
                let latest = hits
                    .filter { $0.kind == "file" }
                    .sorted { $0.mtime > $1.mtime }
                    .prefix(10)
                if !Task.isCancelled { self.files = Array(latest) }
            }
        }
    }
}

/// HOMY: full-width menu row with a hover highlight, like a real menu item.
private struct MenuRowStyle: ButtonStyle {
    var tint = Color.primary
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(hovering ? 0.09 : 0)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

struct MenuBarDownloadsView: View {
    @StateObject private var model = MenuBarDownloadsModel()
    @StateObject private var search = MenuBarSearchModel()
    @ObservedObject private var updates = UpdateCenter.shared
    @State private var freeSpace: String?
    @FocusState private var searchFocused: Bool

    static func closeMenu() {
        NSApp.keyWindow?.orderOut(nil)
    }

    static func freeDiskSpace() -> String? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard
            let values = try? url.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
            let bytes = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " free"
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if search.hasQuery {
                searchResults
            } else {
                atGlance
            }
            Divider()
            footer
        }
        .frame(width: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            model.start()
            if freeSpace == nil { freeSpace = Self.freeDiskSpace() }
            searchFocused = true
        }
        .onExitCommand { Self.closeMenu() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Search this Mac", text: $search.query)
                .textFieldStyle(.plain).font(.system(size: 13))
                .focused($searchFocused)
                .onSubmit { search.openFirst() }
            if search.searching { ProgressView().controlSize(.mini) }
        }.padding(.horizontal, 12).padding(.vertical, 9)
    }

    @ViewBuilder private var searchResults: some View {
        if search.results.isEmpty && !search.searching {
            Text("No Results")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
        } else {
            VStack(spacing: 0) {
                ForEach(search.results) { hit in
                    Button {
                        search.open(hit)
                    } label: {
                        HStack(spacing: 8) {
                            FileThumbnail(hit: hit, size: 20)
                            Text(hit.name)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                        }
                    }.buttonStyle(MenuRowStyle())
                        .contextMenu {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([hit.url])
                            }
                        }
                    Divider().padding(.leading, 40)
                }
                Text("↩ opens the top hit · Esc closes")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
    }

    private var atGlance: some View {
        VStack(spacing: 0) {
            if let latest = model.files.first {
                Button {
                    _ = NSWorkspace.shared.open(latest.url)
                    Self.closeMenu()
                } label: {
                    HStack(spacing: 8) {
                        FileThumbnail(hit: latest, size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Latest download").font(.caption2).foregroundStyle(.secondary)
                            Text(latest.name)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                    }
                }.buttonStyle(MenuRowStyle())
                Divider()
            }
            if let freeSpace {
                HStack(spacing: 6) {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(freeSpace)
                    Spacer()
                }.font(.callout)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                Divider()
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            footerButton("Quick Search", hint: "⇧⌘Space") {
                QuickSearchController.shared.toggle()
                Self.closeMenu()
            }
            Divider().padding(.leading, 12)
            footerButton("Open Downloads Folder") {
                URL(fileURLWithPath: NSHomeDirectory() + "/Downloads").openInWorkspace()
                Self.closeMenu()
            }
            Divider().padding(.leading, 12)
            footerButton(
                updates.offers.isEmpty ? "Check for Updates"
                    : "Check for Updates (\(updates.offers.count))",
                highlight: !updates.offers.isEmpty
            ) {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .homyShowUpdates, object: nil)
                Self.closeMenu()
            }
            Divider()
            footerButton("Quit", hint: "⌘Q") { NSApp.terminate(nil) }
        }
    }

    private func footerButton(
        _ title: String, hint: String? = nil, highlight: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if let hint {
                    Text(hint).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }.buttonStyle(MenuRowStyle(tint: highlight ? .accentColor : .primary))
    }
}
