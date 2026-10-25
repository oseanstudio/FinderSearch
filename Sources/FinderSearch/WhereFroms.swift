import SwiftUI
import AppKit

// HOMY: "Downloaded From" — reads macOS's kMDItemWhereFroms extended attribute
// (written by browsers and most downloaders) and groups files by their source.

enum WhereFroms {
    /// [source URL, referring page URL] as recorded by the downloading app.
    /// getxattr is a single fast syscall, safe to call directly.
    static func from(_ url: URL) -> [URL] {
        let name = "com.apple.metadata:kMDItemWhereFroms"
        let path = url.path
        let length = path.withCString { getxattr($0, name, nil, 0, 0, 0) }
        guard length > 0 else { return [] }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { buffer in
            path.withCString { getxattr($0, name, buffer.baseAddress, length, 0, 0) }
        }
        guard read > 0 else { return [] }
        guard
            let list = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as? [String]
        else { return [] }
        return list.compactMap { URL(string: $0) }
    }

    /// Short, human label for a source host: known apps first, then the bare
    /// domain without "www.".
    static func label(for url: URL) -> String {
        guard let host = url.host?.lowercased() else { return url.absoluteString }
        let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let known: [String: String] = [
            "accounts.google.com": "Gmail",
            "mail.google.com": "Gmail",
            "googlemail.com": "Gmail",
            "slack.com": "Slack",
            "chatgpt.com": "ChatGPT",
            "openai.com": "ChatGPT",
            "github.com": "GitHub",
            "objects.githubusercontent.com": "GitHub",
            "codeload.github.com": "GitHub",
            "dropbox.com": "Dropbox",
            "dl.dropboxusercontent.com": "Dropbox",
            "drive.google.com": "Google Drive",
            "icloud.com": "iCloud",
            "figma.com": "Figma",
            "notion.so": "Notion",
            "apple.com": "Apple",
            "microsoft.com": "Microsoft",
            "outlook.com": "Outlook",
            "zoom.us": "Zoom",
            "telegram.org": "Telegram",
            "discord.com": "Discord",
            "cdn.discordapp.com": "Discord",
            "whatsapp.com": "WhatsApp",
        ]
        for (key, value) in known where domain == key || domain.hasSuffix("." + key) {
            return value
        }
        return domain
    }

    static func source(_ url: URL) -> String? {
        guard let first = from(url).first else { return nil }
        return label(for: first)
    }
}

struct DownloadSourceGroup: Identifiable {
    let source: String
    var files: [Hit]
    var id: String { source }
    var totalSize: UInt64 { files.reduce(0) { $0 + $1.size } }
}

@MainActor final class DownloadedFromModel: ObservableObject {
    @Published var groups: [DownloadSourceGroup] = []
    @Published var loading = true
    @Published var failed: String?
    @Published var selectedSource: String?
    private var generation = 0

    func load(folder: URL) async {
        generation += 1
        let revision = generation
        loading = groups.isEmpty
        failed = nil
        do {
            let hits = try await LocalFiles.load(folder, hidden: false)
            let labeled = await withTaskGroup(
                of: (Int, String?).self
            ) { group in
                for (index, hit) in hits.enumerated() where hit.kind == "file" {
                    group.addTask { (index, WhereFroms.source(hit.url)) }
                }
                var sources: [Int: String?] = [:]
                for await (index, source) in group { sources[index] = source }
                return hits.enumerated().compactMap { index, hit -> (Hit, String)? in
                    guard let source = sources[index] ?? nil else { return nil }
                    return (hit, source)
                }
            }
            guard revision == generation else { return }
            var bySource: [String: [Hit]] = [:]
            for (hit, source) in labeled {
                bySource[source, default: []].append(hit)
            }
            groups = bySource
                .map { DownloadSourceGroup(source: $0.key, files: $0.value.sorted { $0.mtime > $1.mtime }) }
                .sorted { $0.files.count > $1.files.count }
            loading = false
        } catch {
            guard revision == generation else { return }
            failed = error.localizedDescription
            loading = false
        }
    }

    var visibleGroups: [DownloadSourceGroup] {
        guard let selectedSource, selectedSource != "All Sources" else { return groups }
        return groups.filter { $0.source == selectedSource }
    }
}

struct DownloadedFromView: View {
    @ObservedObject var model: SearchModel
    @StateObject private var data = DownloadedFromModel()
    @ObservedObject private var theme = HomyTheme.shared
    private let downloads = URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")

    var body: some View {
        Group {
            if let failure = data.failed {
                ContentUnavailableView(
                    "Could Not Read Downloads",
                    systemImage: "exclamationmark.triangle",
                    description: Text(failure)
                )
            } else if data.loading && data.groups.isEmpty {
                ProgressView("Reading download sources…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if data.groups.isEmpty {
                ContentUnavailableView(
                    "No Sourced Downloads",
                    systemImage: "globe.desk",
                    description: Text(
                        "Files in your Downloads folder carry no download-source metadata yet.")
                )
            } else {
                list
            }
        }.task(id: model.id) { await data.load(folder: downloads) }
            .refreshable { await data.load(folder: downloads) }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Downloaded From").font(.system(size: 24, weight: .bold))
                        Text(
                            "\(data.groups.count) sources · \(data.groups.reduce(0) { $0 + $1.files.count }) files"
                        ).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Source", selection: $data.selectedSource) {
                        Text("All Sources").tag(String?.none)
                        ForEach(data.groups) { group in
                            Text(group.source).tag(String?.some(group.source))
                        }
                    }.frame(width: 220)
                }
                ForEach(data.visibleGroups) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "globe").foregroundStyle(theme.accent)
                            Text(group.source).font(.title3.weight(.semibold))
                            Text(
                                "\(group.files.count) files · "
                                    + ByteCountFormatter.string(
                                        fromByteCount: Int64(clamping: group.totalSize),
                                        countStyle: .file)
                            ).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(group.files) { hit in
                                    HomyFileCard(hit: hit)
                                }
                            }.padding(.vertical, 2)
                        }
                    }.padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: theme.cardRadius).fill(theme.cardFill))
                }
            }.padding(24)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}
