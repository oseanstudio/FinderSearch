import SwiftUI
import AppKit

// HOME: Big Folders — a lightweight space map inside Clean Up. One engine
// query lists the root's files; their sizes aggregate into per-folder bars
// you can drill into. Estimates draw from up to 20,000 indexed files.

struct SpaceRow: Identifiable {
    let name: String
    let path: String
    let bytes: UInt64
    let isFileBucket: Bool
    var id: String { path }
}

@MainActor final class SpaceMapModel: ObservableObject {
    @Published var rows: [SpaceRow] = []
    @Published var totalBytes: UInt64 = 0
    @Published var loading = false
    @Published var root: URL = URL(fileURLWithPath: NSHomeDirectory())
    private var generation = 0

    var rootLabel: String { root.path == NSHomeDirectory() ? "Home" : root.lastPathComponent }

    func load(root newRoot: URL? = nil) {
        if let newRoot { root = newRoot }
        generation += 1
        let revision = generation
        loading = true
        let folder = root
        Task {
            let reply = try? await HomeServices.shared.engine.request([
                "q": "kind:file in:" + folder.path, "limit": 20000,
            ])
            guard revision == self.generation else { return }
            let files = (reply?.ok == true) ? (reply?.hits ?? []) : []
            var byChild: [String: UInt64] = [:]
            var directFiles: UInt64 = 0
            for file in files {
                let path = file.path
                guard path.hasPrefix(folder.path) else { continue }
                let remainder = path.dropFirst(folder.path.count + (folder.path == "/" ? 0 : 1))
                if let slash = remainder.firstIndex(of: "/") {
                    let child = String(remainder[..<slash])
                    byChild[folder.path + "/" + child, default: 0] += file.size
                } else {
                    directFiles += file.size
                }
            }
            var rows = byChild
                .map { child, bytes -> SpaceRow in
                    SpaceRow(
                        name: URL(fileURLWithPath: child).lastPathComponent, path: child,
                        bytes: bytes, isFileBucket: false)
                }
                .sorted { $0.bytes > $1.bytes }
            if directFiles > 0 {
                rows.append(
                    SpaceRow(
                        name: "Files directly here", path: folder.path, bytes: directFiles,
                        isFileBucket: true))
            }
            rows = Array(rows.prefix(12))
            self.rows = rows
            self.totalBytes = rows.reduce(0) { $0 + $1.bytes }
            self.loading = false
        }
    }
}

struct BigFoldersCard: View {
    @StateObject private var model = SpaceMapModel()
    @ObservedObject private var theme = HomeTheme.shared
    private let barColors: [Color] = [.blue, .orange, .purple, .green, .pink, .teal]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Where your space goes", systemImage: "chart.bar.horizontal")
                    .font(.headline)
                Text("estimate from up to 20k indexed files")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if model.rootLabel != "Home" {
                    Button("Back to Home") { model.load(root: URL(fileURLWithPath: NSHomeDirectory())) }
                        .controlSize(.small)
                }
                Button("Refresh") { model.load() }.controlSize(.small)
            }
            if model.loading && model.rows.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 18)
            } else if model.rows.isEmpty {
                Text("No indexed files under \(model.rootLabel).")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                    spaceRow(row, color: barColors[index % barColors.count])
                }
            }
        }.padding(14)
            .background(RoundedRectangle(cornerRadius: theme.cardRadius).fill(theme.cardFill))
            .task { if model.rows.isEmpty { model.load() } }
    }

    private func spaceRow(_ row: SpaceRow, color: Color) -> some View {
        let fraction =
            model.totalBytes > 0 ? Double(row.bytes) / Double(model.totalBytes) : 0
        return Button {
            guard !row.isFileBucket else { return }
            model.load(root: URL(fileURLWithPath: row.path))
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(
                        systemName: row.isFileBucket
                            ? "doc" : "folder.fill"
                    ).font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(row.isFileBucket ? row.name : row.name)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: row.bytes), countStyle: .file))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.primary.opacity(0.05))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color.opacity(0.65))
                            .frame(width: max(4, geometry.size.width * fraction))
                    }
                }.frame(height: 8)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
            .disabled(row.isFileBucket)
            .help(row.isFileBucket ? row.name : "Open \(row.name)")
    }
}
