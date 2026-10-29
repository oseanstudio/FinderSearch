import AppKit
import Darwin
import SwiftUI
import SwiftTerm

// HOME: embedded terminal drawer, adapted from Shark (github.com/andronasef/shark,
// MIT license). The session owns the PTY; the drawer borrows its terminal view,
// and browsing never injects shell input — "Use Current Folder" copies a quoted
// cd command for pasting instead.

/// A window owns the session; the drawer only borrows its terminal view.
@MainActor
final class HearthTerminalSession: NSObject, ObservableObject {
    @Published private(set) var currentWorkingDirectory: URL
    @Published private(set) var hasReportedDirectory = false
    @Published private(set) var isRunning = false
    private(set) var hasStarted = false
    @Published private(set) var exitCode: Int32?
    @Published private(set) var fontSize: Double
    private(set) var terminalView: LocalProcessTerminalView?
    private let preferences = UserDefaults.standard

    static let fontPreferenceKey = "home.terminalFontSize"

    init(workingDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        currentWorkingDirectory = workingDirectory
        let saved = preferences.object(forKey: Self.fontPreferenceKey) as? Double ?? 12
        fontSize = saved.isFinite ? min(36, max(8, saved)) : 12
        super.init()
    }

    func prepareInitialDirectory(_ directory: URL) {
        guard !hasStarted else { return }
        currentWorkingDirectory = directory
    }

    /// SwiftTerm cannot establish that arbitrary shells have an empty, safe
    /// prompt; return a command for the clipboard, leaving live input alone.
    @discardableResult
    func useDirectory(_ directory: URL) throws -> String {
        let resolved = directory.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue, FileManager.default.isReadableFile(atPath: resolved.path)
        else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: directory.path])
        }
        return "cd -- " + resolved.path.shellQuoted + "\n"
    }

    func makeTerminalView() -> LocalProcessTerminalView {
        if let terminalView { return terminalView }
        let view = HearthTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 220))
        view.session = self
        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        terminalView = view
        return view
    }

    func start() {
        guard !hasStarted else { return }
        let view = makeTerminalView()
        hasStarted = true
        view.startProcess(
            executable: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
            args: ["-l"], currentDirectory: currentWorkingDirectory.path)
        isRunning = view.process.running
    }

    func restart() {
        terminate()
        terminalView?.removeFromSuperview()
        terminalView = nil
        hasStarted = false
        hasReportedDirectory = false
        exitCode = nil
        start()
    }

    func focus() {
        guard isRunning, let terminalView else { return }
        terminalView.window?.makeFirstResponder(terminalView)
    }

    func adjustFontSize(by delta: Double) {
        guard delta.isFinite else { return }
        fontSize = min(36, max(8, fontSize + delta))
        preferences.set(fontSize, forKey: Self.fontPreferenceKey)
        terminalView?.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    func resetFontSize() { adjustFontSize(by: 12 - fontSize) }

    func clear() {
        terminalView?.clearScrollback()
        terminalView?.feed(text: "\u{1b}[2J\u{1b}[H")
    }

    func terminate() {
        if let process = terminalView?.process, process.running {
            let foreground = tcgetpgrp(process.childfd)
            if foreground > 0 { kill(-foreground, SIGHUP) }
            if process.shellPid > 0 { kill(-process.shellPid, SIGHUP) }
            terminalView?.terminate()
        }
        isRunning = false
    }
}

extension HearthTerminalSession: @preconcurrency LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {
        guard source === terminalView, let directory, let url = URL(string: directory),
            url.isFileURL
        else { return }
        currentWorkingDirectory = url
        hasReportedDirectory = true
    }
    func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
        guard source === terminalView else { return }
        self.exitCode = exitCode
        isRunning = false
    }
}

/// Intercept native editing equivalents before SwiftUI's file menu shortcuts,
/// and hand shell-flavored keys to the shell (adapted from Shark).
@MainActor
final class HearthTerminalView: LocalProcessTerminalView {
    weak var session: HearthTerminalSession?

    /// Whether a key belongs to the focused shell: anything without ⌘ that
    /// uses ⌃/⌥ or is a function key — except the F3/F4 app toggles.
    static func shellOwns(modifiers: NSEvent.ModifierFlags, characters: String?) -> Bool {
        let mods = modifiers.intersection([.command, .control, .option])
        guard !mods.contains(.command), let scalar = characters?.unicodeScalars.first else {
            return false
        }
        if scalar.value == 0xF706 && mods.isEmpty { return false }  // F4 drawer
        if scalar.value == 0xF705 && mods.isEmpty { return false }  // F3 split
        let isFunctionKey = (0xF700...0xF8FF).contains(scalar.value)
        return !mods.isEmpty || isFunctionKey
    }

}

/// The embeddable terminal surface: mounts the session's terminal view.
struct HearthTerminalSurface: NSViewRepresentable {
    @ObservedObject var session: HearthTerminalSession

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        mount(in: host)
        return host
    }

    func updateNSView(_ host: NSView, context: Context) { mount(in: host) }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        // Detach, never terminate: the session keeps shell and scrollback.
        nsView.subviews.forEach { $0.removeFromSuperview() }
    }

    private func mount(in host: NSView) {
        let terminal = session.makeTerminalView()
        if terminal.superview !== host {
            host.subviews.forEach { $0.removeFromSuperview() }
            terminal.removeFromSuperview()
            terminal.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(terminal)
            NSLayoutConstraint.activate([
                terminal.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                terminal.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                terminal.topAnchor.constraint(equalTo: host.topAnchor),
                terminal.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
            DispatchQueue.main.async { session.focus() }
        }
    }
}

/// The bottom drawer: resize handle, header bar, terminal surface.
struct TerminalPanel: View {
    @ObservedObject var session: HearthTerminalSession
    @Binding var isPresented: Bool
    let currentDirectory: URL
    @State private var drawerHeight: Double = 220
    @State private var resizeStartHeight: Double?
    @State private var copiedCommand = false

    var body: some View {
        VStack(spacing: 0) {
            resizeHandle
            headerBar
            HearthTerminalSurface(session: session)
                .frame(height: max(100, drawerHeight))
                .overlay(alignment: .bottom) {
                    if !session.isRunning {
                        HStack {
                            Text("Shell exited")
                            if let code = session.exitCode { Text("(\(code))") }
                            Button("Restart") { session.restart() }
                        }
                        .font(.system(size: 12))
                        .padding(8)
                        .background(.regularMaterial)
                    }
                }
        }
        .background(Color(white: 0.1))
        .onAppear { session.start() }
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 3)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if resizeStartHeight == nil { resizeStartHeight = drawerHeight }
                        let newHeight = (resizeStartHeight ?? drawerHeight) - value.translation.height
                        let available =
                            session.terminalView?.window?.contentView?.bounds.height ?? 720
                        drawerHeight = min(max(newHeight, 100), max(100, available - 180))
                    }
                    .onEnded { _ in resizeStartHeight = nil }
            )
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
            Text("Terminal")
                .font(.system(size: 11, weight: .semibold))
            Text(
                (session.hasReportedDirectory ? "" : "Started in: ")
                    + session.currentWorkingDirectory.path
            )
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(
                Capsule().fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
            Spacer()
            Button(
                copiedCommand ? "Directory command copied" : "Use Current Folder"
            ) {
                do {
                    let command = try session.useDirectory(currentDirectory)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copiedCommand = true
                    session.focus()
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copiedCommand = false
                    }
                } catch { NSAlert(error: error).runModal() }
            }
            .font(.system(size: 10))
            .help("Copy a quoted cd command for the current folder")
            Menu {
                Button("Restart Shell…") { session.restart() }
                Button("Terminate Shell…") {
                    if confirmTermination() { session.terminate() }
                }.disabled(!session.isRunning)
                Divider()
                Button("Increase Text Size") { session.adjustFontSize(by: 1) }
                Button("Decrease Text Size") { session.adjustFontSize(by: -1) }
                Button("Reset Text Size") { session.resetFontSize() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }.menuStyle(.borderlessButton).frame(width: 20)
            Button {
                session.clear()
            } label: {
                Image(systemName: "trash").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear Terminal Buffer")
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close Terminal (F4)")
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Color(white: 0.14))
        .overlay(Divider(), alignment: .bottom)
    }

    private func confirmTermination() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Terminate this terminal session?"
        alert.informativeText = "This stops the shell and its running commands."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Terminate")
        return alert.runModal() == .alertSecondButtonReturn
    }
}

private extension String {
    /// Literal POSIX shell argument, including spaces, quotes, and mixed paths.
    var shellQuoted: String { "'" + replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// HOME: the secondary split pane's browsing surface — a plain folder view
/// with its own model, sharing the window's engine.
struct SplitPaneBrowser: View {
    @ObservedObject var model: SearchModel
    @ViewBuilder var contextMenu: () -> AnyView

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 119), spacing: 14)],
                alignment: .leading, spacing: 18
            ) {
                ForEach(model.sortedHits) { hit in
                    VStack(spacing: 6) {
                        FileThumbnail(hit: hit, size: 64).frame(width: 74, height: 74)
                        FileNameLabel(model: model, hit: hit, lineLimit: 2, centered: true)
                            .frame(height: 32, alignment: .top)
                    }
                    .padding(6).frame(maxWidth: .infinity)
                    .background(
                        model.selection.contains(hit.path)
                            ? Color.accentColor.opacity(0.22) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                    .modifier(
                        FileClickActions(
                            select: { model.select(hit, extending: false, toggling: false) },
                            open: { model.open(hit) }))
                    .contextMenu { contextMenu() }
                    .id(hit.path)
                }
            }.padding(18)
        }
        .onAppear { model.start() }
        .onTapGesture { }
    }
}
