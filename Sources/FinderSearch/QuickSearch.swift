import SwiftUI
import AppKit
import Carbon.HIToolbox
import Combine

// HOMY: Quick Search (⇧⌘Space, works from any app) — a Spotlight-style
// panel over the same fsearch index, with recents shown while empty.

@MainActor final class QuickSearchModel: ObservableObject {
    @Published var query = "" { didSet { schedule() } }
    @Published var results: [Hit] = []
    @Published var recents: [Hit] = []
    @Published var selection: Int = 0
    @Published var searching = false
    private var task: Task<Void, Never>?
    private var generation = 0
    private var recentsLoaded = false
    // HOMY: the app-wide shared engine; the model stays inert until the
    // panel is first shown, so launching the app spawns nothing.
    private let engine: Engine

    init(engine: Engine = HomyServices.shared.engine) {
        self.engine = engine
    }

    /// HOMY: called when the panel is shown, not at launch — the first open
    /// warms the recents list; later opens refresh it silently.
    func warm() async {
        await loadRecents()
    }

    private func loadRecents() async {
        guard
            let reply = try? await engine.request([
                "op": "recent", "limit": 12,
            ]), reply.ok
        else { return }
        recentsLoaded = true
        recents = reply.hits ?? []
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            results = recents
        }
    }

    private func schedule() {
        generation += 1
        let revision = generation
        task?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            results = recents
            selection = 0
            searching = false
            return
        }
        searching = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(80))
                try Task.checkCancellation()
                let reply = try await self.engine.request([
                    "q": HomyQuery.translate(text), "limit": 12,
                ])
                guard revision == self.generation, !Task.isCancelled else { return }
                self.results = reply.ok ? (reply.hits ?? []) : []
                self.selection = 0
                self.searching = false
            } catch is CancellationError {
            } catch {
                guard revision == self.generation else { return }
                self.results = []
                self.searching = false
            }
        }
    }

    var visible: [Hit] { results }

    func move(_ delta: Int) {
        guard !visible.isEmpty else { return }
        selection = min(max(0, selection + delta), visible.count - 1)
    }

    func open(reveal: Bool = false) {
        guard visible.indices.contains(selection) else { return }
        let hit = visible[selection]
        if reveal {
            NSWorkspace.shared.activateFileViewerSelecting([hit.url])
        } else {
            _ = NSWorkspace.shared.open(hit.url)
            // Tell the index what we opened so future ranking improves.
            Task { _ = try? await engine.request(["op": "open", "path": hit.path]) }
        }
        QuickSearchController.shared.hide()
    }
}

struct QuickSearchView: View {
    @ObservedObject var model: QuickSearchModel
    let close: () -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18)).foregroundStyle(.secondary)
                TextField("Quick Search", text: $model.query)
                    .textFieldStyle(.plain).font(.system(size: 20))
                    .focused($fieldFocused)
                    .onSubmit { model.open() }
                    .onExitCommand { close() }
                if model.searching {
                    ProgressView().controlSize(.small)
                }
            }.padding(.horizontal, 16).padding(.vertical, 14)
            Divider()
            if model.visible.isEmpty {
                HStack {
                    Text(model.query.isEmpty ? "Recent Files" : "No Results")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }.padding(.horizontal, 16).padding(.vertical, 10)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.visible.enumerated()), id: \.element.path) {
                        index, hit in
                        row(hit, selected: index == model.selection)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selection = index
                                model.open()
                            }
                            .onHover { hovering in
                                if hovering { model.selection = index }
                            }
                    }
                }.padding(.vertical, 6)
            }
            HStack {
                Text("↩ Open    ⌘↩ Reveal    Esc Close")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
            }.padding(.horizontal, 16).padding(.vertical, 8)
        }
        .frame(width: 620)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .onAppear { fieldFocused = true }
        .background(
            KeySink {
                if $0 == .moveDown { model.move(1) } else if $0 == .moveUp { model.move(-1) }
            } receiveAction: { action in
                switch action {
                case .enter: model.open()
                case .commandEnter: model.open(reveal: true)
                case .escape: close()
                }
                return true
            }
            .frame(width: 0, height: 0)
        )
    }

    private func row(_ hit: Hit, selected: Bool) -> some View {
        HStack(spacing: 10) {
            FileThumbnail(hit: hit, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.name).lineLimit(1).truncationMode(.middle)
                Text(hit.parent)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(hit.modified.formatted(.relative(presentation: .named)))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor.opacity(0.18) : Color.clear))
    }
}

/// Arrow-key navigation that the plain TextField does not forward.
struct KeySink: NSViewRepresentable {
    enum Action { case enter, commandEnter, escape }
    let onArrow: (NSMoveCommand) -> Void
    let receiveAction: (Action) -> Bool

    func makeNSView(context: Context) -> KeySinkView {
        KeySinkView(onArrow: onArrow, receiveAction: receiveAction)
    }

    func updateNSView(_ view: KeySinkView, context: Context) {
        view.onArrow = onArrow
        view.receiveAction = receiveAction
    }

    final class KeySinkView: NSView {
        var onArrow: (NSMoveCommand) -> Void
        var receiveAction: (Action) -> Bool
        private var monitor: Any?

        init(onArrow: @escaping (NSMoveCommand) -> Void, receiveAction: @escaping (Action) -> Bool) {
            self.onArrow = onArrow
            self.receiveAction = receiveAction
            super.init(frame: .zero)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.window?.isKeyWindow == true else { return event }
                switch event.specialKey {
                case .downArrow:
                    self.onArrow(.moveDown); return nil
                case .upArrow:
                    self.onArrow(.moveUp); return nil
                case .carriageReturn where event.modifierFlags.contains(.command):
                    _ = self.receiveAction(.commandEnter); return nil
                case .carriageReturn:
                    _ = self.receiveAction(.enter); return nil
                default:
                    // keyCode 53 is Escape; this SDK has no SpecialKey member.
                    if event.keyCode == 53 {
                        _ = self.receiveAction(.escape); return nil
                    }
                    return event
                }
            }
        }

        required init?(coder: NSCoder) { nil }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

enum NSMoveCommand { case moveUp, moveDown }

@MainActor final class QuickSearchController: ObservableObject {
    static let shared = QuickSearchController()
    static let signature: OSType = 0x484F4D59  // 'HOMY'
    static let identifier: UInt32 = 1

    // HOMY: lazy — created on the first toggle/show, never at launch.
    private(set) lazy var model = QuickSearchModel()
    private var panel: NSPanel?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    func installHotkey() {
        guard eventHandler == nil else { return }
        var hotKeySpec = EventTypeSpec()
        hotKeySpec.eventClass = OSType(kEventClassKeyboard)
        hotKeySpec.eventKind = UInt32(kEventHotKeyPressed)
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                var keyID = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &keyID)
                if keyID.signature == QuickSearchController.signature {
                    let controller = Unmanaged<QuickSearchController>
                        .fromOpaque(userData!).takeUnretainedValue()
                    Task { @MainActor in controller.toggle() }
                    return noErr
                }
                return OSStatus(eventNotHandledErr)
            },
            1, [hotKeySpec],
            Unmanaged.passUnretained(self).toOpaque(), &eventHandler
        )
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = Self.signature
        hotKeyID.id = Self.identifier
        RegisterEventHotKey(
            UInt32(kVK_Space), UInt32(cmdKey | shiftKey), hotKeyID,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
    }

    func toggle() {
        if panel?.isVisible == true {
            hide()
        } else {
            show()
        }
    }

    func show() {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
                styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
                backing: .buffered, defer: false)
            panel.title = "Quick Search"
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.backgroundColor = .clear
            panel.isOpaque = false
            self.panel = panel
        }
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let hosting = NSHostingView(
            rootView: QuickSearchView(model: model, close: { self.hide() }))
        panel?.contentView = hosting
        // Size to the SwiftUI content: short lists make a short panel.
        let fitting = hosting.fittingSize
        panel?.setContentSize(NSSize(width: 624, height: max(220, min(520, fitting.height + 20))))
        panel?.setFrameOrigin(
            NSPoint(
                x: screenFrame.midX - 312,
                y: screenFrame.midY + screenFrame.height * 0.18))
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.query = ""
        // HOMY: recents load on first show (and refresh after), not at launch.
        Task {
            await model.warm()
            if model.query.isEmpty { model.results = model.recents }
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }
}
