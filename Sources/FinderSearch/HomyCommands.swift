import SwiftUI

// HOMY: The Homy menu — one place for every feature the fork adds.

struct HomyCommandMenu: View {
    let model: SearchModel?
    @ObservedObject private var theme = HomyTheme.shared

    private var ocrTargets: [Hit] {
        (model?.selectedItems ?? []).filter(TextRecognition.supported)
    }

    private var audioTargets: [Hit] {
        (model?.selectedItems ?? []).filter(MusicPlayerModel.isAudio)
    }

    var body: some View {
        Button("Quick Search") { QuickSearchController.shared.toggle() }
            .keyboardShortcut(.space, modifiers: [.command, .shift])
        Button("Describe Contents…") { model?.sidebar("semantic") }  // DIGUP
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(model?.busy != false)
        Divider()
        Button("Home") { model?.sidebar("home") }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(model?.busy != false)
        Button("Downloaded From") { model?.sidebar("sources") }
            .keyboardShortcut("j", modifiers: [.command, .shift])
            .disabled(model?.busy != false)
        Button("Duplicates") { model?.sidebar("dupes") }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(model?.busy != false)
        Button("Clean Up") { model?.sidebar("cleanup") }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(model?.busy != false)
        Divider()
        Button("Text in Images…") { HomyPanels.shared.showOCR(ocrTargets) }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(ocrTargets.isEmpty)
        Button("Inspector") {
            if let hit = model?.selected { HomyPanels.shared.showInspector(hit) }
        }
        .keyboardShortcut("i", modifiers: [.command, .option])
        .disabled(model?.selection.isEmpty != false)
        Button("Play Music") {
            guard let model else { return }
            // Queue the audible files around the selection, falling back to
            // the selection itself when the current view has none.
            let selected = model.selectedItems.filter(MusicPlayerModel.isAudio)
            let pool = model.sortedHits.filter(MusicPlayerModel.isAudio)
            let queue = pool.isEmpty ? selected : pool
            MusicPlayerController.shared.play(queue, start: selected.first ?? queue.first)
        }
        .keyboardShortcut("p", modifiers: [.command, .control])
        .disabled(audioTargets.isEmpty)
        Divider()
        Button("Save Search…") {
            if let model { HomyPanels.shared.showSaveSearch(model) }
        }
        .keyboardShortcut("s")
        .disabled(model?.isSearch != true)
        Divider()
        Picker("Theme", selection: $theme.style) {
            ForEach(HomyTheme.Style.allCases, id: \.self) { style in
                Text(style.title).tag(style)
            }
        }
        Button("Switch Theme") { theme.toggle() }
            .keyboardShortcut("t", modifiers: [.command, .control])
        Divider()
        Button("Reset Sidebar Order") { SidebarSection.resetOrder() }  // HOMY
        Button("Check for Updates…") {  // HOMY
            NotificationCenter.default.post(name: .homyShowUpdates, object: nil)
        }
    }
}

extension Notification.Name {
    static let homySaveSearch = Notification.Name("homy.saveSearch")
}

/// Panel form of the save-search field, driven from the ⌘S command.
struct HomySaveSearchPanel: View {
    let query: String
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save Search").font(.headline)
            Text("“\(query)”").font(.callout).foregroundStyle(.secondary).lineLimit(2)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { NSApp.keyWindow?.close() }
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(16).frame(width: 320)
            .onAppear {
                let parsed = HomyQuery.parse(query)
                name = parsed.chipLabels.map { "\($0.field) \($0.value)" }
                    .joined(separator: ", ")
                if name.isEmpty { name = query }
            }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        SavedSearches.shared.add(trimmed, query: query)
        NSApp.keyWindow?.close()
    }
}
