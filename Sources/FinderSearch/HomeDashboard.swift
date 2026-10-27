import SwiftUI
import AppKit

// HOME: Home dashboard — category totals, shelves of recent files, and quick
// links into Clean Up and Duplicates, mirroring Home's home screen.

struct HomeShelf: Identifiable {
    let category: HomeCategory
    let files: [Hit]
    var id: String { category.rawValue }
}

/// HOME: one user collection's recent files on the Home dashboard.
struct HomeCollectionShelf: Identifiable {
    let id: UUID
    let name: String
    let files: [Hit]
}

@MainActor final class HomeDashboardModel: ObservableObject {
    @Published var counts: [HomeCategory: Int] = [:]
    @Published var countOverflow: Set<HomeCategory> = []
    @Published var shelves: [HomeShelf] = []
    @Published var collectionShelves: [HomeCollectionShelf] = []
    @Published var loading = true
    @Published var failed = false
    private var generation = 0
    // HOME: results are cached for a few minutes so revisiting Home is
    // instant; pull-to-refresh or visiting after a change forces a reload.
    private var lastLoaded: Date?
    private static let cacheTTL: TimeInterval = 300

    var shouldLoad: Bool {
        guard let lastLoaded else { return true }
        return Date().timeIntervalSince(lastLoaded) > Self.cacheTTL || counts.isEmpty
    }

    private static let shelfCategories: [HomeCategory] = [.images, .videos, .documents, .music]
    private static let shelfLimit = 14
    private static let countLimit = 1000

    func load(force: Bool = false) async {
        if !force, !shouldLoad, !shelves.isEmpty { return }
        generation += 1
        let revision = generation
        failed = false
        let collections = HomeCollections.shared.items
        var newCounts: [HomeCategory: Int] = [:]
        var overflow: Set<HomeCategory> = []
        var newShelves: [HomeShelf] = []
        await withTaskGroup(of: (HomeCategory, Int, Bool, [Hit]).self) { group in
            for category in HomeCategory.allCases {
                group.addTask {
                    await self.fetch(category: category)
                }
            }
            for await (category, count, hitCap, files) in group {
                newCounts[category] = count
                if hitCap { overflow.insert(category) }
                if !files.isEmpty {
                    newShelves.append(
                        HomeShelf(category: category, files: files.sorted { $0.mtime > $1.mtime }))
                }
            }
        }
        guard revision == generation else { return }
        if newCounts.isEmpty && collections.isEmpty { failed = true }
        counts = newCounts
        countOverflow = overflow
        shelves = Self.shelfCategories.compactMap { category in
            newShelves.first { $0.category == category }
        }
        collectionShelves = await withTaskGroup(
            of: HomeCollectionShelf.self
        ) { group in
            for collection in collections {
                group.addTask {
                    let files = await HomeCollections.files(
                        in: collection.folders, limit: Self.shelfLimit)
                    return HomeCollectionShelf(
                        id: collection.id, name: collection.name, files: files)
                }
            }
            var result: [HomeCollectionShelf] = []
            for await shelf in group where !shelf.files.isEmpty { result.append(shelf) }
            return result
        }
        guard revision == generation else { return }
        loading = false
        lastLoaded = Date()
    }

    private func fetch(category: HomeCategory) async -> (HomeCategory, Int, Bool, [Hit]) {
        let query = category.query + " in:" + NSHomeDirectory()
        let reply = try? await HomeServices.shared.engine.request([
            "q": query, "limit": Self.shelfLimit,
        ])
        var count = reply?.hits?.count ?? 0
        var capped = false
        if count >= Self.shelfLimit {
            capped = true
            let counted = try? await HomeServices.shared.engine.request([
                "q": query, "limit": Self.countLimit,
            ])
            count = counted?.hits?.count ?? 0
            if count >= Self.countLimit { capped = true } else { capped = false }
        }
        return (category, count, capped, reply?.hits ?? [])
    }
}

struct HomeDashboard: View {
    @ObservedObject var model: SearchModel
    @StateObject private var dashboard = HomeDashboardModel()
    @ObservedObject private var theme = HomeTheme.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                categoryGrid
                toolCards
                ForEach(dashboard.shelves) { shelf in
                    shelfSection(shelf)
                }
                ForEach(dashboard.collectionShelves) { shelf in  // HOME
                    collectionShelfSection(shelf)
                }
                if dashboard.loading && dashboard.shelves.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView("Scanning your files…")
                        Spacer()
                    }.padding(.vertical, 60)
                }
                if dashboard.failed && !dashboard.loading {
                    HStack {
                        Spacer()
                        ContentUnavailableView(
                            "Search Index Unavailable",
                            systemImage: "externaldrive.badge.exclamationmark"
                        )
                        Spacer()
                    }.padding(.vertical, 40)
                }
            }.padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task { if dashboard.shouldLoad { await dashboard.load() } }
        .refreshable { await dashboard.load(force: true) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).month().day()))
                .font(.callout).foregroundStyle(.secondary)
            Text("Home")
                .font(.system(size: 28, weight: .bold))
        }
    }

    private var categoryGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12
        ) {
            ForEach(HomeCategory.allCases) { category in
                Button {
                    model.sidebar("cat:" + category.rawValue)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: category.symbol)
                            .font(.system(size: 20))
                            .foregroundStyle(theme.accent)
                            .frame(width: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.title).font(.headline)
                            Text(countLabel(category))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: theme.cardRadius)
                            .fill(theme.cardFill)
                    )
                }.buttonStyle(.plain)
            }
        }
    }

    private func countLabel(_ category: HomeCategory) -> String {
        guard let count = dashboard.counts[category] else { return "—" }
        if dashboard.countOverflow.contains(category) { return "\(count)+ items" }
        return count == 1 ? "1 item" : "\(count) items"
    }

    private var toolCards: some View {
        HStack(spacing: 12) {
            toolCard(
                "Clean Up", "sparkles", "Old installers, downloads and screenshots"
            ) { model.sidebar("cleanup") }
            toolCard(
                "Duplicates", "square.on.square", "Identical files and look-alike photos"
            ) { model.sidebar("dupes") }
            toolCard(
                "Downloads", "globe.desk", "Grouped by source"
            ) { model.sidebar("sources") }
        }
    }

    private func toolCard(
        _ title: String, _ symbol: String, _ subtitle: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }.padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: theme.cardRadius).fill(theme.cardFill))
        }.buttonStyle(.plain)
    }

    // HOME: a user collection's recent files.
    private func collectionShelfSection(_ shelf: HomeCollectionShelf) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(shelf.name, systemImage: "square.stack.3d.up")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Open") { model.sidebar("col:" + shelf.id.uuidString) }
                    .controlSize(.small)
            }
            ShelfStrip(files: shelf.files)
        }
    }

    private func shelfSection(_ shelf: HomeShelf) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(shelf.category.title, systemImage: shelf.category.symbol)
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("See All") { model.sidebar("cat:" + shelf.category.rawValue) }
                    .controlSize(.small)
            }
            ShelfStrip(files: shelf.files)
        }
    }
}

/// A thumbnail card for shelves and dashboard surfaces: click to open,
/// context menu for the common Home actions.
struct HomeFileCard: View {
    let hit: Hit
    var size: Double = 86

    var body: some View {
        VStack(spacing: 6) {
            FileThumbnail(hit: hit, size: size)
                .frame(width: size + 8, height: size + 8)
            Text(hit.name)
                .font(.caption)
                .lineLimit(1)
                .frame(width: size + 16)
                .truncationMode(.middle)
            Text(hit.modified.formatted(.relative(presentation: .named)))
                .font(.caption2).foregroundStyle(.tertiary)
        }.padding(6)
            .background(
                RoundedRectangle(cornerRadius: HomeTheme.shared.cardRadius)
                    .fill(HomeTheme.shared.cardFill))
            .contentShape(Rectangle())
            .onTapGesture { hit.url.openInWorkspace() }
            .contextMenu {
                Button("Open") { hit.url.openInWorkspace() }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([hit.url])
                }
                Divider()
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(hit.path, forType: .string)
                }
                Button("Move to Trash") {
                    try? FileManager.default.trashItem(at: hit.url, resultingItemURL: nil)
                }
            }
            .draggable(hit.url)
    }
}

extension URL {
    func openInWorkspace() { _ = NSWorkspace.shared.open(self) }
}


/// HOME: a full-bleed horizontal shelf with Finder-style arrows. The strip
/// runs edge to edge; the chevrons step one card per click and auto-repeat
/// while held down.
struct ShelfStrip: View {
    let files: [Hit]
    @State private var offset = 0

    var body: some View {
        ScrollViewReader { proxy in
            ZStack {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(files.enumerated()), id: \.offset) { index, hit in
                            HomeFileCard(hit: hit)
                                .id(index)
                        }
                    }
                    .padding(.leading, 24)
                    .padding(.trailing, 24)
                    .padding(.vertical, 2)
                }
                // Bleed to the window edges: the dashboard pads its content
                // by 24, so the strip cancels it and re-pads inside.
                .padding(.horizontal, -24)
                HStack {
                    if offset > 0 {
                        ShelfArrow(system: "chevron.left") {
                            step(proxy, -1)
                        }
                    }
                    Spacer()
                    if files.count > 3 {
                        ShelfArrow(system: "chevron.right") {
                            step(proxy, 1)
                        }
                    }
                }
                .padding(.horizontal, 5)
            }
            .onAppear {
                offset = 0
                proxy.scrollTo(0, anchor: .leading)
            }
            .onChange(of: files.count) { _, _ in
                offset = 0
                proxy.scrollTo(0, anchor: .leading)
            }
        }
    }

    private func step(_ proxy: ScrollViewProxy, _ delta: Int) {
        guard !files.isEmpty else { return }
        offset = min(max(0, offset + delta), files.count - 1)
        withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo(offset, anchor: delta > 0 ? .trailing : .leading)
        }
    }
}

/// HOME: a round chevron that steps on click and keeps stepping while held.
private struct ShelfArrow: View {
    let system: String
    let step: () -> Void
    @State private var timer: Timer?
    @State private var pressing = false

    var body: some View {
        Image(systemName: system)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.primary)
            .frame(width: 24, height: 24)
            .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            .scaleEffect(pressing ? 0.88 : 1)
            .onLongPressGesture(minimumDuration: .infinity, maximumDistance: 40) {
                // never completes at infinite duration
            } onPressingChanged: { pressing in
                self.pressing = pressing
                timer?.invalidate()
                timer = nil
                if pressing {
                    step()
                    timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                        step()
                    }
                }
            }
            .onDisappear {
                timer?.invalidate()
                timer = nil
            }
    }
}
