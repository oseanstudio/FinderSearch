import SwiftUI
import AppKit
import CryptoKit
import Vision
import CoreGraphics
import ImageIO

// HOMY: Duplicates — identical files confirmed by SHA-256 and look-alike
// photos found with Vision feature prints, with keep-one trash-the-rest.

struct DuplicateGroup: Identifiable, Sendable {
    enum Kind: Sendable { case identical, similarPhotos }
    let kind: Kind
    var files: [DuplicateFile]
    /// Path of the copy the user keeps; every other copy is trashable.
    var keeper: String
    let id = UUID()
    var reclaimable: UInt64 {
        let extra = files.filter { $0.hit.path != keeper }.count
        return UInt64(extra) * (files.map(\.hit.size).max() ?? 0)
    }
}

struct DuplicateFile: Identifiable, Sendable {
    let hit: Hit
    var dimensions: CGSize?
    var id: String { hit.path }
}

/// All scanning runs away from the main thread, with hard caps so a big
/// library cannot turn into an endless scan.
enum DuplicateScanner {
    /// Images that get dimension checks (most recent first); the Vision stage
    /// then works on at most `maxVisionImages` of them.
    static let maxDimensionScan = 4000
    static let maxVisionImages = 2000

    static func find(
        in files: [Hit], progress: @escaping @Sendable (String) -> Void
    ) async throws -> [DuplicateGroup] {
        let candidates = files.filter { $0.size > 0 && $0.kind == "file" }
        var bySize: [UInt64: [Hit]] = [:]
        for hit in candidates { bySize[hit.size, default: []].append(hit) }
        let sizeGroups = bySize.values.filter { $0.count > 1 }

        // Stage 1: a head+tail hash narrows same-size groups cheaply.
        // Stage 2: a full SHA-256 confirms true duplicates.
        var confirmed: [String: [Hit]] = [:]
        for (index, sameSize) in sizeGroups.enumerated() {
            try Task.checkCancellation()
            if index % 8 == 0 { progress("Hashing size groups (\(index)/\(sizeGroups.count))…") }
            var byHead: [String: [Hit]] = [:]
            for hit in sameSize {
                try Task.checkCancellation()
                let key = quickHash(hit.url, size: hit.size)
                byHead[key, default: []].append(hit)
            }
            for probable in byHead.values where probable.count > 1 {
                for hit in probable {
                    try Task.checkCancellation()
                    confirmed[try fullHash(hit.url), default: []].append(hit)
                }
            }
        }
        var groups: [DuplicateGroup] = []
        var alreadyGrouped = Set<String>()
        for identical in confirmed.values where identical.count > 1 {
            let items = identical.map { DuplicateFile(hit: $0, dimensions: nil) }
                .sorted { $0.hit.mtime > $1.hit.mtime }
            alreadyGrouped.formUnion(items.map(\.hit.path))
            groups.append(
                DuplicateGroup(kind: .identical, files: items, keeper: keeperDefault(items)))
        }

        // Look-alike photos: images sharing pixel dimensions, clustered by
        // Vision feature-print distance (byte-identical pairs covered above).
        progress("Reading image dimensions…")
        let images = candidates
            .filter { $0.isImageFile && $0.size < 50_000_000 }
            .sorted { $0.mtime > $1.mtime }
            .prefix(maxDimensionScan)
        var byDimension: [String: [Hit]] = [:]
        var dimensions: [String: CGSize] = [:]
        for hit in images {
            try Task.checkCancellation()
            if let size = imageDimensions(hit.url) {
                byDimension["\(Int(size.width))x\(Int(size.height))", default: []].append(hit)
                dimensions[hit.path] = size
            }
        }
        // Only the biggest clusters go through Vision, and together they
        // never exceed maxVisionImages — feature prints are expensive.
        var visionBudget = maxVisionImages
        let clustersByCount = byDimension.values
            .filter { $0.count > 1 && $0.count <= 60 }
            .sorted { $0.count > $1.count }
        for sameShape in clustersByCount {
            try Task.checkCancellation()
            guard sameShape.count <= visionBudget else { continue }
            visionBudget -= sameShape.count
            progress("Comparing \(sameShape.count) similar-shaped photos…")
            guard let clusters = try similarClusters(sameShape) else { continue }
            for members in clusters {
                let fresh = members.filter { !alreadyGrouped.contains($0.path) }
                guard fresh.count > 1 else { continue }
                alreadyGrouped.formUnion(fresh.map(\.path))
                let items = fresh.map {
                    DuplicateFile(hit: $0, dimensions: dimensions[$0.path])
                }.sorted { $0.hit.mtime > $1.hit.mtime }
                groups.append(
                    DuplicateGroup(
                        kind: .similarPhotos, files: items, keeper: keeperDefault(items)))
            }
        }
        return groups.sorted { $0.reclaimable > $1.reclaimable }
    }

    /// Keeps the newest copy by default.
    static func keeperDefault(_ files: [DuplicateFile]) -> String {
        files.max { $0.hit.mtime < $1.hit.mtime }?.hit.path ?? files[0].hit.path
    }

    /// Head and tail chunks rule out almost every same-size pair without
    /// reading whole files.
    static func quickHash(_ url: URL, size: UInt64) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return UUID().uuidString }
        defer { try? handle.close() }
        let chunk = 64 * 1024
        let head = (try? handle.read(upToCount: chunk)) ?? Data()
        var tail = Data()
        if size > UInt64(chunk) * 2 {
            let start = UInt64(clamping: Int64(max(0, Int64(size) - Int64(chunk))))
            try? handle.seek(toOffset: start)
            tail = (try? handle.read(upToCount: chunk)) ?? Data()
        }
        return SHA256.hash(data: head + tail).description
    }

    static func fullHash(_ url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return UUID().uuidString }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
        }
        return hasher.finalize().description
    }

    static func imageDimensions(_ url: URL) -> CGSize? {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
            let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
        else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Greedy clustering by feature-print distance; returns nil when Vision
    /// is unavailable for the batch.
    static func similarClusters(_ hits: [Hit]) throws -> [[Hit]]? {
        var prints: [String: VNFeaturePrintObservation] = [:]
        for hit in hits {
            let request = VNGenerateImageFeaturePrintRequest()
            let handler = VNImageRequestHandler(url: hit.url, options: [:])
            guard (try? handler.perform([request])) != nil,
                let print = request.results?.first
            else { continue }
            prints[hit.path] = print
        }
        guard prints.count > 1 else { return nil }
        var parent: [String: String] = [:]
        for hit in hits { parent[hit.path] = hit.path }
        func root(_ path: String) -> String {
            var current = path
            while parent[current] != current { current = parent[current]! }
            parent[path] = current
            return current
        }
        for left in hits {
            try Task.checkCancellation()
            guard let leftPrint = prints[left.path] else { continue }
            for right in hits where left.path < right.path {
                guard let rightPrint = prints[right.path] else { continue }
                var distance: Float = 0
                guard (try? leftPrint.computeDistance(&distance, to: rightPrint)) != nil,
                    distance < 4.0
                else { continue }
                let leftRoot = root(left.path), rightRoot = root(right.path)
                if leftRoot != rightRoot { parent[rightRoot] = leftRoot }
            }
        }
        var clusters: [String: [Hit]] = [:]
        for hit in hits { clusters[root(hit.path), default: []].append(hit) }
        return clusters.values.filter { $0.count > 1 }
    }
}

@MainActor final class DuplicatesModel: ObservableObject {
    @Published var groups: [DuplicateGroup] = []
    @Published var scanning = false
    @Published var progress: String?
    @Published var scopeLabel = "This Mac"
    @Published var trashed = 0
    private var generation = 0
    private var scanTask: Task<Void, Never>?

    var totalReclaimable: UInt64 { groups.reduce(0) { $0 + $1.reclaimable } }

    func scan(scope: URL, label: String) {
        generation += 1
        let revision = generation
        scopeLabel = label
        scanning = true
        groups = []
        progress = "Listing files…"
        scanTask?.cancel()
        scanTask = Task {
            do {
                let reply = try await HomyServices.shared.engine.request([
                    "q": "kind:file in:" + scope.path, "limit": 20000,
                ])
                guard revision == generation else { return }
                guard reply.ok else { throw Engine.Failure.message(reply.error ?? "Search failed") }
                // Hashing and Vision comparisons run detached: they must never
                // occupy the main actor, whatever the caller's executor is.
                let files = reply.hits ?? []
                let report: @Sendable (String) -> Void = { text in
                    Task { @MainActor [weak self] in
                        guard let self, revision == self.generation else { return }
                        self.progress = text
                    }
                }
                let scan = Task.detached(priority: .userInitiated) {
                    try await DuplicateScanner.find(in: files, progress: report)
                }
                let found = try await withTaskCancellationHandler {
                    try await scan.value
                } onCancel: {
                    scan.cancel()
                }
                guard revision == generation else { return }
                groups = found
                scanning = false
                progress = nil
            } catch is CancellationError {
                guard revision == generation else { return }
                scanning = false
                progress = nil
            } catch {
                guard revision == generation else { return }
                scanning = false
                progress = nil
            }
        }
    }

    func stop() {
        generation += 1
        scanTask?.cancel()
        scanning = false
        progress = nil
    }

    func trashExtras(_ group: DuplicateGroup, via model: SearchModel) {
        let doomed = group.files.filter { $0.hit.path != group.keeper }.map {
            FileMutation.trash($0.hit.url)
        }
        guard !doomed.isEmpty else { return }
        model.perform(doomed, name: "Trash Duplicate") { _ in
            self.groups.removeAll { $0.id == group.id }
            self.trashed += doomed.count
        }
    }

    func trashAll(via model: SearchModel) {
        let doomed = groups.flatMap { group in
            group.files.filter { $0.hit.path != group.keeper }.map { FileMutation.trash($0.hit.url) }
        }
        guard !doomed.isEmpty else { return }
        let count = doomed.count
        let ids = Set(groups.map(\.id))
        model.perform(doomed, name: "Trash Duplicates") { _ in
            self.groups.removeAll { ids.contains($0.id) }
            self.trashed += count
        }
    }
}

struct DuplicatesView: View {
    @ObservedObject var model: SearchModel
    @StateObject private var data = DuplicatesModel()
    @StateObject private var navigator = HomyKeyNavigator()  // HOMY: keyboard support
    @ObservedObject private var theme = HomyTheme.shared
    @State private var selectedGroup = 0

    private enum ScanScope: Hashable { case home, folder }
    @State private var scanScope: ScanScope = .home

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Duplicates").font(.system(size: 22, weight: .bold))
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if data.scanning {
                    ProgressView().controlSize(.small)
                    Text(data.progress ?? "Scanning…")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Stop") { data.stop() }.controlSize(.small)
                } else {
                    Picker("Scan", selection: $scanScope) {
                        Text("This Mac").tag(ScanScope.home)
                        Text("This Folder").tag(ScanScope.folder)
                    }.pickerStyle(.radioGroup).controlSize(.small)
                    Button("Rescan") { startScan() }
                    Button("Trash All Duplicates") { data.trashAll(via: model) }
                        .disabled(data.groups.isEmpty)
                }
            }.padding(16)
            Divider()
            if !data.groups.isEmpty && !data.scanning {
                ScrollView {
                    // Lazy: a home library can yield hundreds of groups; an
                    // eager VStack would build every card on the main thread.
                    LazyVStack(spacing: 14) {
                        ForEach(Array(data.groups.enumerated()), id: \.element.id) {
                            index, group in
                            DuplicateGroupCard(
                                group: groupBinding(index), data: data, model: model,
                                highlighted: index == selectedGroup)
                        }
                    }.padding(16)
                }
            } else if data.scanning {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(data.progress ?? "Scanning…").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No Duplicates Found",
                    systemImage: "checkmark.seal",
                    description: Text("Identical files and look-alike photos will appear here.")
                )
            }
        }.background(Color(nsColor: .windowBackgroundColor))
            .task { if !data.scanning && data.groups.isEmpty { startScan() } }
            .onAppear { installNavigator() }
            .onDisappear { navigator.remove() }
            .onChange(of: data.groups.count) { _, count in
                selectedGroup = min(max(0, selectedGroup), max(0, count - 1))
            }
    }

    private func groupBinding(_ index: Int) -> Binding<DuplicateGroup> {
        Binding(
            get: { data.groups.indices.contains(index) ? data.groups[index] : data.groups[0] },
            set: { if data.groups.indices.contains(index) { data.groups[index] = $0 } })
    }

    /// HOMY: arrows step through groups, Space Quick Looks the keeper,
    /// Return opens it. Active only on the duplicates route.
    private func installNavigator() {
        navigator.install(
            isActive: { model.route == "dupes" && !data.groups.isEmpty && !data.scanning },
            onMove: { delta in
                selectedGroup = min(max(0, selectedGroup + delta), data.groups.count - 1)
            },
            onPreview: {
                guard data.groups.indices.contains(selectedGroup),
                    let file = data.groups[selectedGroup].files.first(where: {
                        $0.hit.path == data.groups[selectedGroup].keeper
                    })
                else { return }
                model.preview = file.hit
            },
            onOpen: {
                guard data.groups.indices.contains(selectedGroup),
                    let file = data.groups[selectedGroup].files.first(where: {
                        $0.hit.path == data.groups[selectedGroup].keeper
                    })
                else { return }
                file.hit.url.openInWorkspace()
            })
    }

    private var subtitle: String {
        if data.groups.isEmpty { return data.scanning ? "Scanning…" : "Nothing to reclaim" }
        return
            "\(data.groups.count) groups · "
            + ByteCountFormatter.string(
                fromByteCount: Int64(clamping: data.totalReclaimable), countStyle: .file)
            + " recoverable"
            + (data.trashed > 0 ? " · \(data.trashed) already trashed" : "")
    }

    private func startScan() {
        if scanScope == .folder, model.canWriteHere, model.route.hasPrefix("/") {
            data.scan(scope: model.location, label: model.location.lastPathComponent)
        } else {
            data.scan(scope: URL(fileURLWithPath: NSHomeDirectory()), label: "This Mac")
        }
    }
}

struct DuplicateGroupCard: View {
    @Binding var group: DuplicateGroup
    @ObservedObject var data: DuplicatesModel
    @ObservedObject var model: SearchModel
    var highlighted = false  // HOMY: keyboard selection
    @ObservedObject private var theme = HomyTheme.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(
                    group.kind == .identical ? "Identical" : "Look-alike Photos",
                    systemImage: group.kind == .identical ? "doc.on.doc" : "photo.on.rectangle"
                ).font(.headline)
                Text(
                    ByteCountFormatter.string(
                        fromByteCount: Int64(clamping: group.reclaimable), countStyle: .file)
                        + " recoverable"
                ).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Trash Others") { data.trashExtras(group, via: model) }.controlSize(.small)
            }
            ForEach(group.files) { file in
                let isKeeper = file.hit.path == group.keeper
                HStack(spacing: 10) {
                    Image(systemName: isKeeper ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isKeeper ? .green : .secondary)
                    FileThumbnail(hit: file.hit, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.hit.name).lineLimit(1).truncationMode(.middle)
                        Text(file.hit.parent)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    if let dimensions = file.dimensions {
                        Text("\(Int(dimensions.width))×\(Int(dimensions.height))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(file.hit.modified.formatted(.relative(presentation: .named)))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isKeeper ? Color.green.opacity(0.08) : Color.clear))
                    .contentShape(Rectangle())
                    .onTapGesture { group.keeper = file.hit.path }
                    .contextMenu {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([file.hit.url])
                        }
                        Button("Open") { file.hit.url.openInWorkspace() }
                    }
            }
        }.padding(14)
            .background(RoundedRectangle(cornerRadius: theme.cardRadius).fill(theme.cardFill))
            .overlay(
                // HOMY: keyboard-selected card.
                RoundedRectangle(cornerRadius: theme.cardRadius)
                    .stroke(
                        highlighted ? Color.accentColor : Color.clear,
                        lineWidth: 2))
    }
}
