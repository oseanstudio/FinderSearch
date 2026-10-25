import SwiftUI
import AppKit

// HOMY: Clean Up — smart cards that surface reclaimable space: old
// installers, forgotten downloads, old screenshots, big videos and unused
// apps. Everything goes to Trash; nothing is deleted permanently.

struct CleanupCard: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let queries: [(folder: String, query: String)]
    var files: [Hit] = []
    var loaded = false
    var totalSize: UInt64 { files.reduce(0) { $0 + $1.size } }
}

@MainActor final class CleanupModel: ObservableObject {
    @Published var cards: [CleanupCard] = []
    @Published var loading = true
    @Published var trashed = 0
    private var generation = 0

    static let definitions: [CleanupCard] = [
        CleanupCard(
            id: "installers", title: "Old Installers",
            subtitle: ".dmg and .pkg files older than 30 days",
            symbol: "shippingbox",
            queries: [
                (NSHomeDirectory() + "/Downloads", "*.{dmg,pkg} kind:file mtime:>30d"),
            ]),
        CleanupCard(
            id: "downloads", title: "Forgotten Downloads",
            subtitle: "Files sitting in Downloads for 60+ days",
            symbol: "arrow.down.circle",
            queries: [
                (NSHomeDirectory() + "/Downloads", "kind:file mtime:>60d"),
            ]),
        CleanupCard(
            id: "screenshots", title: "Old Screenshots",
            subtitle: "Screenshots older than 30 days",
            symbol: "camera.on.rectangle",
            queries: [("", "Screenshot kind:file mtime:>30d in:" + NSHomeDirectory())]),
        CleanupCard(
            id: "videos", title: "Big Videos",
            subtitle: "Movies and clips over 500 MB",
            symbol: "film",
            queries: [("", "type:video size:>500mb kind:file in:" + NSHomeDirectory())]),
        CleanupCard(
            id: "apps", title: "Unused Apps",
            subtitle: "Applications not touched for 180+ days",
            symbol: "square.grid.2x2",
            queries: [
                ("/Applications", "*.app mtime:>180d"),
                (NSHomeDirectory() + "/Applications", "*.app mtime:>180d"),
            ]),
    ]

    func load() async {
        generation += 1
        let revision = generation
        loading = true
        var loaded: [CleanupCard] = []
        for definition in Self.definitions {
            var files: [Hit] = []
            for (folder, query) in definition.queries {
                var fields: [String: Any] = ["q": query, "limit": 1000]
                if !folder.isEmpty { fields["in"] = folder }
                guard
                    let reply = try? await HomyServices.shared.engine.request(fields),
                    reply.ok
                else { continue }
                files += reply.hits ?? []
            }
            if definition.id == "screenshots" {
                files = files.filter { $0.isScreenshot && $0.kind == "file" }
            } else {
                files = files.filter { $0.kind == "file" }
            }
            files.sort { $0.size > $1.size }
            loaded.append(
                CleanupCard(
                    id: definition.id, title: definition.title, subtitle: definition.subtitle,
                    symbol: definition.symbol, queries: definition.queries, files: files,
                    loaded: true))
        }
        guard revision == generation else { return }
        cards = loaded
        loading = false
    }

    func trash(_ hits: [Hit], cardID: String, via model: SearchModel) {
        guard !hits.isEmpty else { return }
        let count = hits.count
        model.perform(hits.map { .trash($0.url) }, name: "Clean Up") { _ in
            if let index = self.cards.firstIndex(where: { $0.id == cardID }) {
                let removed = Set(hits.map(\.path))
                self.cards[index].files.removeAll { removed.contains($0.path) }
            }
            self.trashed += count
        }
    }

    func trashAll(via model: SearchModel) {
        let doomed = cards.flatMap(\.files)
        guard !doomed.isEmpty else { return }
        let count = doomed.count
        model.perform(doomed.map { .trash($0.url) }, name: "Clean Up All") { _ in
            for index in self.cards.indices { self.cards[index].files = [] }
            self.trashed += count
        }
    }
}

// HomyCore.swift provides Hit.isScreenshot.

struct CleanupView: View {
    @ObservedObject var model: SearchModel
    @StateObject private var data = CleanupModel()
    @ObservedObject private var theme = HomyTheme.shared
    @State private var expanded: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Clean Up").font(.system(size: 22, weight: .bold))
                        Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Refresh") { Task { await data.load() } }
                        .disabled(data.loading)
                    Button("Trash All") { data.trashAll(via: model) }
                        .disabled(data.cards.allSatisfy { $0.files.isEmpty })
                }
                if data.loading && data.cards.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView("Scanning for reclaimable space…")
                        Spacer()
                    }.padding(.vertical, 50)
                }
                ForEach(data.cards) { card in
                    CleanupCardView(
                        card: card, expanded: $expanded, data: data, model: model)
                }
            }.padding(20)
        }.background(Color(nsColor: .windowBackgroundColor))
            .task { if data.cards.isEmpty { await data.load() } }
            .refreshable { await data.load() }
    }

    private var subtitle: String {
        let total = data.cards.reduce(0) { $0 + $1.totalSize }
        let count = data.cards.reduce(0) { $0 + $1.files.count }
        let trashedNote = data.trashed > 0 ? " · \(data.trashed) trashed" : ""
        return
            ByteCountFormatter.string(fromByteCount: Int64(clamping: total), countStyle: .file)
            + " across \(count) files" + trashedNote
            + ". Trashed files are recoverable."
    }
}

struct CleanupCardView: View {
    let card: CleanupCard
    @Binding var expanded: Set<String>
    @ObservedObject var data: CleanupModel
    @ObservedObject var model: SearchModel
    @ObservedObject private var theme = HomyTheme.shared
    @State private var selection: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: card.symbol)
                    .font(.system(size: 22)).foregroundStyle(theme.accent).frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title).font(.headline)
                    Text(card.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !card.files.isEmpty {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(card.files.count) files").font(.callout)
                        Text(
                            ByteCountFormatter.string(
                                fromByteCount: Int64(clamping: card.totalSize), countStyle: .file)
                        ).font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Trash All") {
                        data.trash(card.files, cardID: card.id, via: model)
                    }.controlSize(.small)
                    Button(expanded.contains(card.id) ? "Hide" : "Show") {
                        if expanded.contains(card.id) {
                            expanded.remove(card.id)
                        } else {
                            expanded.insert(card.id)
                        }
                    }.controlSize(.small)
                } else {
                    Label("Clean", systemImage: "checkmark")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if expanded.contains(card.id) {
                Divider()
                ForEach(card.files) { hit in
                    HStack(spacing: 10) {
                        Image(systemName: selection.contains(hit.path) ? "checkmark.square" : "square")
                            .foregroundStyle(.secondary)
                            .onTapGesture { toggle(hit.path) }
                        FileThumbnail(hit: hit, size: 28)
                        Text(hit.name).lineLimit(1).truncationMode(.middle)
                        Text(hit.parent).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(
                            ByteCountFormatter.string(
                                fromByteCount: Int64(clamping: hit.size), countStyle: .file)
                        ).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Text(hit.modified.formatted(.relative(presentation: .named)))
                            .font(.caption).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                        .onTapGesture { toggle(hit.path) }
                        .contextMenu {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([hit.url])
                            }
                        }
                }
                if !selection.isEmpty {
                    HStack {
                        Button("Trash Selected (\(selection.count))") {
                            let hits = card.files.filter { selection.contains($0.path) }
                            data.trash(hits, cardID: card.id, via: model)
                            selection = []
                        }.controlSize(.small)
                        Button("Select All") {
                            selection = Set(card.files.map(\.path))
                        }.controlSize(.small)
                        Spacer()
                    }
                }
            }
        }.padding(14)
            .background(RoundedRectangle(cornerRadius: theme.cardRadius).fill(theme.cardFill))
    }

    private func toggle(_ path: String) {
        if selection.contains(path) {
            selection.remove(path)
        } else {
            selection.insert(path)
        }
    }
}
