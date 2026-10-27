import SwiftUI
import AppKit

// HOMY: Home dashboard — category totals, shelves of recent files, and quick
// links into Clean Up and Duplicates, mirroring Homy's home screen.

struct HomyShelf: Identifiable {
    let category: HomyCategory
    let files: [Hit]
    var id: String { category.rawValue }
}

/// HOMY: one user collection's recent files on the Home dashboard.
struct HomyCollectionShelf: Identifiable {
    let id: UUID
    let name: String
    let files: [Hit]
}

@MainActor final class HomeDashboardModel: ObservableObject {
    @Published var counts: [HomyCategory: Int] = [:]
    @Published var countOverflow: Set<HomyCategory> = []
    @Published var shelves: [HomyShelf] = []
    @Published var collectionShelves: [HomyCollectionShelf] = []
    @Published var loading = true
    @Published var failed = false
    private var generation = 0
    // HOMY: results are cached for a few minutes so revisiting Home is
    // instant; pull-to-refresh or visiting after a change forces a reload.
    private var lastLoaded: Date?
    private static let cacheTTL: TimeInterval = 300

    var shouldLoad: Bool {
        guard let lastLoaded else { return true }
        return Date().timeIntervalSince(lastLoaded) > Self.cacheTTL || counts.isEmpty
    }

    private static let shelfCategories: [HomyCategory] = [.images, .videos, .documents, .music]
    private static let shelfLimit = 14
    private static let countLimit = 1000

    func load(force: Bool = false) async {
        if !force, !shouldLoad, !shelves.isEmpty { return }
        generation += 1
        let revision = generation
        failed = false
        let collections = HomyCollections.shared.items
        var newCounts: [HomyCategory: Int] = [:]
        var overflow: Set<HomyCategory> = []
        var newShelves: [HomyShelf] = []
        await withTaskGroup(of: (HomyCategory, Int, Bool, [Hit]).self) { group in
            for category in HomyCategory.allCases {
                group.addTask {
                    await self.fetch(category: category)
                }
            }
            for await (category, count, hitCap, files) in group {
                newCounts[category] = count
                if hitCap { overflow.insert(category) }
                if !files.isEmpty {
                    newShelves.append(
                        HomyShelf(category: category, files: files.sorted { $0.mtime > $1.mtime }))
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
            of: HomyCollectionShelf.self
        ) { group in
            for collection in collections {
                group.addTask {
                    let files = await HomyCollections.files(
                        in: collection.folders, limit: Self.shelfLimit)
                    return HomyCollectionShelf(
                        id: collection.id, name: collection.name, files: files)
                }
            }
            var result: [HomyCollectionShelf] = []
            for await shelf in group where !shelf.files.isEmpty { result.append(shelf) }
            return result
        }
        guard revision == generation else { return }
        loading = false
        lastLoaded = Date()
    }

    private func fetch(category: HomyCategory) async -> (HomyCategory, Int, Bool, [Hit]) {
        let query = category.query + " in:" + NSHomeDirectory()
        let reply = try? await HomyServices.shared.engine.request([
            "q": query, "limit": Self.shelfLimit,
        ])
        var count = reply?.hits?.count ?? 0
        var capped = false
        if count >= Self.shelfLimit {
            capped = true
            let counted = try? await HomyServices.shared.engine.request([
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
    @ObservedObject private var theme = HomyTheme.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                categoryGrid
                toolCards
                ForEach(dashboard.shelves) { shelf in
                    shelfSection(shelf)
                }
                ForEach(dashboard.collectionShelves) { shelf in  // HOMY
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
            ForEach(HomyCategory.allCases) { category in
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

    private func countLabel(_ category: HomyCategory) -> String {
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

    // HOMY: a user collection's recent files.
    private func collectionShelfSection(_ shelf: HomyCollectionShelf) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(shelf.name, systemImage: "square.stack.3d.up")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Open") { model.sidebar("col:" + shelf.id.uuidString) }
                    .controlSize(.small)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(shelf.files) { hit in
                        HomyFileCard(hit: hit)
                    }
                }.padding(.vertical, 2)
            }
        }
    }

    private func shelfSection(_ shelf: HomyShelf) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(shelf.category.title, systemImage: shelf.category.symbol)
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("See All") { model.sidebar("cat:" + shelf.category.rawValue) }
                    .controlSize(.small)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(shelf.files) { hit in
                        HomyFileCard(hit: hit)
                    }
                }.padding(.vertical, 2)
            }
        }
    }
}

/// A thumbnail card for shelves and dashboard surfaces: click to open,
/// context menu for the common Homy actions.
struct HomyFileCard: View {
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
                RoundedRectangle(cornerRadius: HomyTheme.shared.cardRadius)
                    .fill(HomyTheme.shared.cardFill))
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
