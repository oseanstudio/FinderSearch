import SwiftUI
import AppKit

// DIGUP: the Search route — find files by what is inside them
// ("the clause about pets in the lease", "zebra in a video"), powered by
// DigUp's on-device index.

@MainActor final class SemanticSearchModel: ObservableObject {
    @Published var query = "" { didSet { schedule() } }
    @Published var hits: [DigUpHit] = []
    @Published var strong = 0
    @Published var meaning = false
    @Published var embedMS = 0
    @Published var searchMS = 0
    @Published var searching = false
    @Published var selected = 0  // HOME: keyboard-highlighted result
    @Published var kindFilter: String? { didSet { if !query.isEmpty { runNow() } } }
    @Published var showFolders = false
    private var task: Task<Void, Never>?
    private var generation = 0

    static let kinds: [(value: String?, label: String, symbol: String)] = [
        (nil, "All", "square.grid.2x2"),
        ("screenshot", "Screenshots", "camera.on.rectangle"),
        ("image", "Images", "photo"),
        ("pdf", "PDFs", "doc.richtext"),
        ("doc", "Documents", "doc.text"),
        ("audio", "Audio", "music.note"),
        ("video", "Video", "film"),
    ]

    private func schedule() {
        generation += 1
        let revision = generation
        task?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else {
            hits = []; strong = 0; selected = 0; searching = false
            return
        }
        // Let the encoder start on what is typed so far; the search itself
        // waits for a short pause in typing.
        DigUpService.shared.embedAhead(text)
        searching = true
        task = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, revision == self.generation else { return }
            await self.run()
        }
    }

    func runNow() {
        generation += 1
        task?.cancel()
        Task { await run() }
    }

    private func run() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { return }
        searching = true
        do {
            let result = try await DigUpService.shared.search(
                text, kinds: kindFilter.map { [$0] } ?? [])
            hits = result.hits
            selected = 0
            strong = result.strong
            meaning = result.meaning
            embedMS = result.embedMS
            searchMS = result.searchMS
            searching = false
        } catch {
            hits = []
            strong = 0
            searching = false
        }
    }
}

struct SemanticSearchView: View {
    @ObservedObject var model: SearchModel
    @StateObject private var search = SemanticSearchModel()
    @StateObject private var setup = DigUpSetupModel()
    @StateObject private var indexing = DigUpIndexingModel()
    @StateObject private var service = DigUpService.shared
    @StateObject private var navigator = HomeKeyNavigator()  // HOME: keyboard support
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if setup.state?.ready != true {
                DigUpSetupView(setup: setup, onReady: {
                    DigUpService.shared.setRoots(DigUpService.effectiveRoots())
                    DigUpService.shared.prewarm()
                })
            } else {
                if indexing.running { indexingStrip }
                searchBar
                Divider()
                if search.query.trimmingCharacters(in: .whitespaces).count >= 2 {
                    results
                } else {
                    idle
                }
                Divider()
                footer
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $search.showFolders) {
            DigUpFoldersView {
                DigUpService.shared.setRoots(DigUpService.effectiveRoots())
                Task { await setup.refresh() }
            }
        }
        .task {
            await setup.refresh()
            DigUpService.shared.setRoots(DigUpService.effectiveRoots())
            DigUpService.shared.prewarm()
            fieldFocused = true
        }
        .onAppear { installNavigator() }
        .onDisappear { navigator.remove() }
    }

    // HOME: arrows step through results even while typing in the field;
    // Space Quick Looks and Return opens the highlighted one once focus
    // leaves the field.
    private func installNavigator() {
        navigator.install(
            isActive: { model.route == "semantic" && !search.hits.isEmpty },
            arrowsWhileEditing: true,
            onMove: { delta in
                search.selected = min(max(0, search.selected + delta), search.hits.count - 1)
            },
            onPreview: {
                guard search.hits.indices.contains(search.selected) else { return }
                model.preview = search.hits[search.selected].asHit
            },
            onOpen: {
                guard search.hits.indices.contains(search.selected) else { return }
                SpotPreviewController.shared.open(search.hits[search.selected])
            })
    }

    private var indexingStrip: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(
                indexing.total > 0
                    ? "Indexing \(indexing.done) of \(indexing.total) — \(indexing.currentFile)"
                    : "Scanning folders…"
            ).font(.caption).lineLimit(1).truncationMode(.middle)
            if !indexing.states.isEmpty {
                Text(indexing.states.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }
                    .joined(separator: ", "))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Stop") { indexing.stop() }.controlSize(.small)
        }.padding(.horizontal, 14).padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 16)).foregroundStyle(.secondary)
            TextField(
                "Describe what is inside the files, e.g. “the clause about pets in the lease”",
                text: $search.query
            ).textFieldStyle(.plain).font(.system(size: 15))
                .focused($fieldFocused)
                .onSubmit { search.runNow() }
            if search.searching { ProgressView().controlSize(.small) }
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var idle: some View {
        VStack(spacing: 14) {
            Spacer()
            ContentUnavailableView(
                "Search by Meaning",
                systemImage: "text.magnifyingglass",
                description: Text(
                    "Describe what a file contains — a photo's scene, a page's text, what is said in a recording. "
                        + "Everything is matched on this Mac, in DigUp's index.")
            )
            statusSummary.padding(.bottom, 24)
            Spacer()
        }
    }

    private var results: some View {
        VStack(spacing: 0) {
            kindChips
            Divider()
            if search.hits.isEmpty && !search.searching {
                ContentUnavailableView(
                    "No Good Matches",
                    systemImage: "questionmark.text.page",
                    description: Text(
                        search.meaning
                            ? "Nothing in the index matched that description."
                            : "Matches by keywords only so far; the meaning model is still starting.")
                )
            } else {
                resultRows
            }
        }
    }

    private var kindChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SemanticSearchModel.kinds, id: \.label) { entry in
                    Button {
                        search.kindFilter = entry.value
                    } label: {
                        Label(entry.label, systemImage: entry.symbol)
                            .font(.system(size: 12, weight: .medium))
                    }.buttonStyle(.bordered)
                        .tint(search.kindFilter == entry.value ? .accentColor : .secondary)
                }
                Spacer()
            }.padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    private var resultRows: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if search.strong < search.hits.count {
                    Text("Showing the \(search.strong) strongest of \(search.hits.count) matches")
                        .font(.caption).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(search.hits.enumerated()), id: \.element.id) {
                    index, hit in
                    DigUpResultRow(hit: hit, highlighted: index == search.selected)
                }
                if !search.hits.isEmpty {
                    Text(String(format: "embed %d ms · search %d ms · %@", search.embedMS, search.searchMS,
                                search.meaning ? "meaning" : "keywords"))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }.padding(14)
        }
    }

    private var statusSummary: some View {
        Group {
            if let state = setup.state {
                Text(state.summary)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if indexing.running {
                ProgressView().controlSize(.mini)
            }
            Image(systemName: "internaldrive").font(.system(size: 10))
            Text(serviceSummary).lineLimit(1).truncationMode(.middle)
            if search.query.trimmingCharacters(in: .whitespaces).count >= 2 {
                Text("· \(search.hits.count) results").monospacedDigit()
            }
            Spacer(minLength: 8)
            Button("Sync Now") {
                indexing.syncNow(roots: DigUpService.effectiveRoots())
            }.controlSize(.small)
                .disabled(indexing.running || DigUpService.effectiveRoots().isEmpty)
            Button("Manage Folders…") { search.showFolders = true }.controlSize(.small)
            if let error = service.lastError {
                Image(systemName: "exclamationmark.triangle")
                    .help(error).foregroundStyle(.orange)
            }
        }
        // HOME: this is the route's single bottom row (the shared bar is
        // hidden here), so it carries the same height and treatment.
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.horizontal, 14).frame(height: 28)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var serviceSummary: String {
        var parts: [String] = []
        if service.files > 0 {
            parts.append("\(service.files) files indexed")
        }
        if let state = setup.state, let version = state.appVersion {
            parts.append("DigUp \(version)")
        }
        switch service.encoderState {
        case "ready": parts.append("meaning model ready")
        case "starting": parts.append("starting model…")
        case "unavailable": parts.append("model unavailable")
        default: break
        }
        return parts.joined(separator: " · ")
    }
}

struct DigUpResultRow: View {
    let hit: DigUpHit
    var highlighted = false  // HOME: keyboard selection
    @ObservedObject private var theme = HomeTheme.shared

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            DigUpSegmentThumb(hit: hit)  // DIGUP: exact page/frame thumbnails
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(hit.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    Text(hit.kindLabel)
                        .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    if !hit.locationLabel.isEmpty {
                        Text(hit.locationLabel)
                            .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(theme.cardFill))
                    }
                }
                Text(hit.parent)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if let excerpt = hit.excerpt, !excerpt.isEmpty {
                    Text(excerpt)
                        .font(.caption).foregroundStyle(.primary.opacity(0.75))
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }.padding(10)
            .background(RoundedRectangle(cornerRadius: theme.cardRadius).fill(theme.cardFill))
            .overlay(
                RoundedRectangle(cornerRadius: theme.cardRadius)
                    .stroke(highlighted ? Color.accentColor : Color.clear, lineWidth: 2))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { SpotPreviewController.shared.open(hit) }  // DIGUP
            .onTapGesture {}
            .contextMenu {
                Button("Open at Matched Spot") { SpotPreviewController.shared.open(hit) }
                Button("Open File Normally") { hit.asHit.url.openInWorkspace() }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([hit.asHit.url])
                }
                Divider()
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(hit.path, forType: .string)
                }
            }
    }
}
