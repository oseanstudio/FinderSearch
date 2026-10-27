import SwiftUI
import AppKit
import AVKit
import PDFKit

// HOME: segment-accurate results for the Search route.
//
// Thumbnails come from DigUp's render op — the exact matched PDF page or
// video frame as a JPEG, not the file's generic icon. Opening goes through
// the spot preview: PDFs open at the matched page, videos and audio at the
// matched moment, in a window of their own. Everything else opens normally.

/// Renders the matched segment; falls back to the file's real icon while
/// loading or when the segment has no renderable spot.
struct DigUpSegmentThumb: View {
    let hit: DigUpHit
    @State private var image: NSImage?
    private static let pixels = 96

    /// The render kind for this hit, or nil when the segment has no spot.
    static func renderKind(for hit: DigUpHit) -> String? {
        switch hit.kind {
        case "pdf":
            return hit.loc != nil ? "pdf" : nil
        case "video":
            return hit.loc != nil ? "video" : nil
        case "image", "screenshot":
            return "image"
        default:
            return nil
        }
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                FileThumbnail(hit: hit.asHit, size: 44)
            }
        }.frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .task(id: hit.id) {
                guard let kind = Self.renderKind(for: hit) else { return }
                let image = await DigUpService.shared.render(
                    path: hit.path, kind: kind, loc: hit.loc, pixels: Self.pixels)
                guard !Task.isCancelled else { return }
                self.image = image
            }
    }
}

// MARK: - Spot preview window

@MainActor final class SpotPreviewController: NSObject {
    static let shared = SpotPreviewController()
    private var panel: NSPanel?
    private var player: AVPlayer?
    private var currentURL: URL?

    /// Opens the file at the hit's exact spot when one exists; otherwise a
    /// plain open. PDF → matched page, video/audio → matched moment.
    func open(_ hit: DigUpHit) {
        currentURL = hit.asHit.url
        switch (hit.kind, hit.segment, hit.loc) {
        case ("pdf", let segment, let page?) where segment == "page" || segment == "pageImage":
            showPDF(path: hit.path, page: max(1, Int(page)), title: hit.name)
        case ("video", "frame", let seconds?):
            showPlayer(path: hit.path, at: seconds, title: hit.name)
        case ("audio", "audio", let seconds?):
            showPlayer(path: hit.path, at: seconds, title: hit.name)
        default:
            hit.asHit.url.openInWorkspace()
        }
    }

    func close() {
        player?.pause()
        player = nil
        panel?.close()
        panel = nil
    }

    private func makePanel(title: String) -> NSPanel {
        if let panel { panel.title = title; return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 660),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.center()
        self.panel = panel
        return panel
    }

    private func showPDF(path: String, page: Int, title: String) {
        let panel = makePanel(title: "\(title) — p. \(page)")
        let view = PDFKitView(path: path, page: page)
        panel.contentView = NSHostingView(rootView: spotChrome(title: title, spot: "page \(page)") { view })
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showPlayer(path: String, at seconds: Double, title: String) {
        let panel = makePanel(title: "\(title) — at \(Self.clock(seconds))")
        let player = AVPlayer(url: URL(fileURLWithPath: path))
        self.player = player
        let view = AVPlayerViewRepresentable(player: player, seekTo: seconds)
        panel.contentView = NSHostingView(
            rootView: spotChrome(title: title, spot: "at \(Self.clock(seconds))") { view })
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        player.play()
    }

    private func spotChrome<V: View>(title: String, spot: String, @ViewBuilder content: () -> V)
        -> some View
    {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text("opened at \(spot)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open File") { self.currentURL?.openInWorkspace() }
                Button("Done") { self.close() }.keyboardShortcut(.cancelAction)
            }.padding(10)
            Divider()
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onDisappear { self.player?.pause() }
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Content views

/// PDFKit view that jumps to a page once the document loads.
private struct PDFKitView: NSViewRepresentable {
    let path: String
    let page: Int

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        Task.detached(priority: .userInitiated) {
            let document = PDFDocument(url: URL(fileURLWithPath: path))
            await MainActor.run {
                guard !Task.isCancelled else { return }
                view.document = document
                if let target = document?.page(at: max(0, page - 1)) {
                    view.go(to: target)
                }
            }
        }
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {}
}

private struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer
    let seekTo: Double

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        player.seek(to: CMTime(seconds: seekTo, preferredTimescale: 600))
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}
}
