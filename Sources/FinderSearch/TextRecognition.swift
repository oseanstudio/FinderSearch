import SwiftUI
import AppKit
import Vision
import PDFKit

// HOMY: Text in images — on-device OCR via the Vision framework for selected
// screenshots, photos and PDFs, with copy-to-clipboard output.

enum TextRecognition {
    /// Recognized text per input, preserved in input order.
    static func recognize(_ urls: [URL]) async -> [(url: URL, text: String)] {
        (try? await BackgroundWork.run {
            urls.compactMap { url -> (URL, String)? in
                try? Task.checkCancellation()
                if url.pathExtension.lowercased() == "pdf" {
                    guard let text = recognizePDF(url) else { return nil }
                    return (url, text)
                }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(url: url, options: [:])
                guard (try? handler.perform([request])) != nil else { return nil }
                let text = (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                guard !text.isEmpty else { return nil }
                return (url, text)
            }
        }) ?? []
    }

    private static func recognizePDF(_ url: URL) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }
        // PDFKit's own text layer is faster than OCR when present.
        let embedded = (0..<document.pageCount).compactMap {
            document.page(at: $0)?.string
        }.joined(separator: "\n")
        let cleaned = embedded.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count >= 20 { return embedded }
        // Scanned PDF: OCR the first pages.
        var pages: [String] = []
        for index in 0..<min(document.pageCount, 10) {
            guard let page = document.page(at: index) else { continue }
            let image = page.thumbnail(of: CGSize(width: 1600, height: 2200), for: .mediaBox)
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { continue }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            guard (try? handler.perform([request])) != nil else { continue }
            let text = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            if !text.isEmpty { pages.append(text) }
        }
        return pages.isEmpty ? nil : pages.joined(separator: "\n\n")
    }

    /// Everything Homy's ⇧⌘C accepts: images and PDFs.
    static func supported(_ hit: Hit) -> Bool {
        hit.kind == "file" && (hit.isImageFile || hit.isPDF)
    }
}

@MainActor final class TextRecognitionModel: ObservableObject {
    @Published var results: [(url: URL, text: String)] = []
    @Published var running = false
    @Published var error: String?
}

struct TextRecognitionView: View {
    let hits: [Hit]
    @StateObject private var model = TextRecognitionModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Text in Images", systemImage: "text.viewfinder")
                    .font(.headline)
                Spacer()
                if model.running {
                    ProgressView().controlSize(.small)
                    Text("Recognizing…").foregroundStyle(.secondary)
                } else if !model.results.isEmpty {
                    Button("Copy All") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            model.results.map(\.text).joined(separator: "\n\n"),
                            forType: .string)
                    }
                }
            }.padding(12)
            Divider()
            if let error = model.error {
                Text(error).foregroundStyle(.secondary).padding(20)
            } else if model.results.isEmpty && !model.running {
                ContentUnavailableView(
                    "No Text Found",
                    systemImage: "text.magnifyingglass",
                    description: Text(
                        model.running
                            ? "Recognizing…" : "Select screenshots, photos or PDFs first.")
                )
            } else {
                TabView {
                    ForEach(model.results, id: \.url.absoluteString) { result in
                        ScrollView {
                            Text(result.text)
                                .font(.system(size: 13, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(16)
                        }.tabItem { Text(result.url.lastPathComponent) }
                    }
                }
            }
        }.frame(minWidth: 560, minHeight: 420)
            .task {
                guard model.results.isEmpty, !model.running else { return }
                model.running = true
                let hits = hits
                let recognized = await TextRecognition.recognize(hits.map(\.url))
                model.results = recognized
                model.running = false
                if recognized.isEmpty {
                    model.error = "No selectable text was found in the selected files."
                }
            }
    }
}
