import SwiftUI
import AppKit

// HOMY: Menu-bar list of the latest downloads with thumbnails, clickable and
// draggable, refreshed by watching the Downloads folder.

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

struct MenuBarDownloadsView: View {
    @StateObject private var model = MenuBarDownloadsModel()

    var body: some View {
        Group {
            if model.files.isEmpty {
                Text("No recent downloads").padding(8)
            } else {
                ForEach(model.files) { hit in
                    HStack(spacing: 10) {
                        FileThumbnail(hit: hit, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.name).lineLimit(1).truncationMode(.middle)
                            Text(hit.modified.formatted(.relative(presentation: .named)))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let source = WhereFroms.source(hit.url) {
                            Text(source)
                                .font(.caption2).foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }.padding(.horizontal, 8).padding(.vertical, 3)
                        .contentShape(Rectangle())
                        .onTapGesture { hit.url.openInWorkspace() }
                        .draggable(hit.url)
                        .contextMenu {
                            Button("Open") { hit.url.openInWorkspace() }
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([hit.url])
                            }
                        }
                }
                Divider()
            }
            Button("Open Downloads Folder") {
                URL(fileURLWithPath: NSHomeDirectory() + "/Downloads").openInWorkspace()
            }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }.frame(width: 320)
            .task { model.start() }
    }
}
