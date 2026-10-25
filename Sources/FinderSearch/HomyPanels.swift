import SwiftUI
import AppKit
import AVFoundation
import ImageIO
import CoreGraphics
import PDFKit

// HOMY: Inspector (⌥⌘I) — everything Homy shows: kind, size, dates, tags,
// image dimensions, camera EXIF, media duration/resolution and download
// source, with Quick Look-sized preview and one-click actions.

struct HomyInspectorData {
    var hit: Hit
    var created: Date?
    var dimensions: CGSize?
    var duration: Double?
    var camera: String?
    var lens: String?
    var exposure: String?
    var source: String?
    var sourceURL: URL?
    var tags: [String] = []

    static func load(_ hit: Hit) async -> HomyInspectorData {
        var data = HomyInspectorData(hit: hit)
        let url = hit.url
        let ext = url.pathExtension.lowercased()
        if hit.isImageFile {
            if let info = await imageInfo(url) {
                data.dimensions = info.dimensions
                data.camera = info.camera
                data.lens = info.lens
                data.exposure = info.exposure
            }
        } else if hit.isPDF {
            data.dimensions = await pdfPageSize(url)
        }
        if mediaExtensions.contains(ext), let media = await mediaInfo(url) {
            data.duration = media.duration
            if data.dimensions == nil { data.dimensions = media.dimensions }
        }
        if let first = WhereFroms.from(url).first {
            data.sourceURL = first
            data.source = WhereFroms.label(for: first)
        }
        if let values = try? url.resourceValues(forKeys: [.creationDateKey]) {
            data.created = values.creationDate
        }
        if let tagNames = try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames {
            data.tags = tagNames.sorted()
        }
        return data
    }

    private static let mediaExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aiff", "flac", "alac", "ogg",
        "mov", "mp4", "m4v", "avi", "mkv", "webm",
    ]

    private static func imageInfo(_ url: URL) async -> (dimensions: CGSize, camera: String?, lens: String?, exposure: String?)? {
        (try? await BackgroundWork.run {
            guard
                let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
                let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
            else { return nil }
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            var exposure: String?
            if let seconds = exif?[kCGImagePropertyExifExposureTime] as? Double {
                exposure = seconds >= 1
                    ? String(format: "%.0fs", seconds)
                    : String(format: "1/%.0fs", 1 / max(seconds, 0.0001))
            }
            if let fNumber = exif?[kCGImagePropertyExifFNumber] as? Double {
                let f = String(format: "ƒ%.1f", fNumber)
                exposure = exposure.map { $0 + " " + f } ?? f
            }
            if let iso = exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int], let first = iso.first {
                exposure = exposure.map { $0 + " ISO \(first)" } ?? "ISO \(first)"
            }
            return (
                CGSize(width: width, height: height),
                tiff?[kCGImagePropertyTIFFModel] as? String,
                exif?[kCGImagePropertyExifLensModel] as? String,
                exposure
            )
        }) ?? nil
    }

    private static func pdfPageSize(_ url: URL) async -> CGSize? {
        (try? await BackgroundWork.run {
            guard let document = PDFDocument(url: url), let page = document.page(at: 0)
            else { return nil }
            let box = page.bounds(for: .mediaBox)
            return CGSize(width: Int(box.width), height: Int(box.height))
        }) ?? nil
    }

    private static func mediaInfo(_ url: URL) async -> (duration: Double?, dimensions: CGSize?)? {
        let asset = AVURLAsset(url: url)
        guard
            let duration = try? await asset.load(.duration),
            duration.seconds.isFinite
        else { return nil }
        var size: CGSize?
        if let tracks = try? await asset.loadTracks(withMediaType: .video),
            let track = tracks.first,
            let natural = try? await track.load(.naturalSize)
        {
            size = natural
        }
        guard duration.seconds > 0 || size != nil else { return nil }
        return (duration.seconds, size)
    }
}

struct HomyInspectorView: View {
    let hit: Hit
    @State private var data: HomyInspectorData?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Inspector", systemImage: "info.circle").font(.headline)
                Spacer()
                Text(hit.name).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }.padding(12)
            Divider()
            Group {
                if let data {
                    ScrollView {
                        VStack(spacing: 14) {
                            FileThumbnail(hit: hit, size: 128)
                                .frame(maxWidth: .infinity)
                            rows(data)
                        }.padding(16)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                Button("Open") { hit.url.openInWorkspace() }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([hit.url])
                }
                Spacer()
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(hit.path, forType: .string)
                }
            }.padding(10)
        }.frame(minWidth: 380, minHeight: 460)
            .task(id: hit.path) { data = await HomyInspectorData.load(hit) }
    }

    @ViewBuilder private func rows(_ data: HomyInspectorData) -> some View {
        row("Kind", data.hit.typeName)
        row(
            "Size",
            ByteCountFormatter.string(
                fromByteCount: Int64(clamping: data.hit.size), countStyle: .file))
        if let created = data.created {
            row("Created", created.formatted())
        }
        row("Modified", data.hit.modified.formatted())
        if let dimensions = data.dimensions {
            row("Dimensions", "\(Int(dimensions.width)) × \(Int(dimensions.height)) px")
        }
        if let duration = data.duration, duration > 0 {
            row("Duration", durationFormatter.string(from: duration) ?? "")
        }
        if let camera = data.camera {
            row("Camera", camera)
        }
        if let lens = data.lens {
            row("Lens", lens)
        }
        if let exposure = data.exposure {
            row("Exposure", exposure)
        }
        if let source = data.source {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Downloaded From").foregroundStyle(.secondary)
                    Spacer()
                    Text(source).fontWeight(.medium)
                }
                if let url = data.sourceURL {
                    Text(url.absoluteString)
                        .font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }.font(.system(size: 12))
        }
        if !data.tags.isEmpty {
            row("Tags", data.tags.joined(separator: ", "))
        }
        VStack(alignment: .leading, spacing: 3) {
            Text("Where").foregroundStyle(.secondary).font(.system(size: 12))
            Text(data.hit.parent)
                .font(.system(size: 12)).textSelection(.enabled)
                .lineLimit(2).truncationMode(.middle)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }.font(.system(size: 12))
    }

    private var durationFormatter: DateComponentsFormatter {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }
}

// MARK: - Panel host for OCR and Inspector

@MainActor final class HomyPanels {
    static let shared = HomyPanels()
    private var ocrPanel: NSPanel?
    private var inspectorPanel: NSPanel?
    private var savePanel: NSPanel?

    func showSaveSearch(_ model: SearchModel) {
        guard model.isSearch else { return }
        if savePanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 340, height: 180),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "Save Search"
            panel.isReleasedWhenClosed = false
            panel.center()
            savePanel = panel
        }
        savePanel?.contentView = NSHostingView(
            rootView: HomySaveSearchPanel(query: model.query))
        savePanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showOCR(_ hits: [Hit]) {
        let supported = hits.filter(TextRecognition.supported)
        guard !supported.isEmpty else { return }
        if ocrPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 460),
                styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered,
                defer: false)
            panel.title = "Text in Images"
            panel.isReleasedWhenClosed = false
            panel.center()
            ocrPanel = panel
        }
        ocrPanel?.contentView = NSHostingView(rootView: TextRecognitionView(hits: supported))
        ocrPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showInspector(_ hit: Hit) {
        if inspectorPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
                styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered,
                defer: false)
            panel.title = "Inspector"
            panel.isReleasedWhenClosed = false
            panel.center()
            inspectorPanel = panel
        }
        inspectorPanel?.contentView = NSHostingView(rootView: HomyInspectorView(hit: hit))
        inspectorPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
