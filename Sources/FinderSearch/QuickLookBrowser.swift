import SwiftUI

struct QuickLookBrowser: View {
    @ObservedObject var model: SearchModel
    @State private var keyMonitor: Any?
    var body: some View {
        VStack(spacing: 0) {
            if let hit = model.preview {
                HStack {
                    Button {
                        model.advancePreview(-1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!model.canAdvancePreview(-1)).help("Previous file")
                    Button {
                        model.advancePreview(1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(!model.canAdvancePreview(1)).help("Next file")
                Text(hit.name).font(.headline).lineLimit(1)
                    .help(hit.path)
                    Spacer()
                Text("scroll zooms · drag pans · double-click fits")
                    .font(.caption2).foregroundStyle(.tertiary)  // HOMY
                Text(model.previewPosition).foregroundStyle(.secondary).monospacedDigit()
                Button("Open") {
                    model.open(hit); model.preview = nil
                }
                Button("Done") { model.preview = nil }
            }.padding()
            Divider()
            // HOMY: zoomable, pannable preview in its own resizable window.
            ZoomablePreview(url: hit.url).frame(minWidth: 500, minHeight: 340)
            }
        }
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard model.preview != nil,
                    event.modifierFlags.intersection([.command, .option, .control]).isEmpty
                else { return event }
                if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable {
                    return event
                }
                if event.keyCode == 123 || event.keyCode == 126 {
                    model.advancePreview(-1); return nil
                }
                if event.keyCode == 124 || event.keyCode == 125 {
                    model.advancePreview(1); return nil
                }
                if event.keyCode == 49 || event.keyCode == 53 {  // HOMY: 53 = Esc, no sheet now
                    model.preview = nil; return nil
                }
                return event
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil
        }
    }
}
extension SearchModel {
    var previewIndex: Int? {
        preview.flatMap { hit in previewItems.firstIndex { $0.path == hit.path } }
    }
    var previewPosition: String { previewIndex.map { "\($0 + 1) of \(previewItems.count)" } ?? "" }
    func canAdvancePreview(_ offset: Int) -> Bool {
        guard let index = previewIndex else { return false }
        return previewItems.indices.contains(index + offset)
    }
    func advancePreview(_ offset: Int) {
        guard let index = previewIndex, previewItems.indices.contains(index + offset) else {
            return
        }
        let hit = previewItems[index + offset]
        preview = hit; select(hit, extending: false, toggling: false)
        selectionNavigation.send((hit.path, false))
    }
}
