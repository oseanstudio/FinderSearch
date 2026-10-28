import AppKit
import SwiftUI

enum MouseNavigationCommand {
    case back, forward
    static func command(type: NSEvent.EventType, button: Int) -> Self? {
        guard type == .otherMouseDown else { return nil }
        switch button {
        case 3, 8: return .back  // 8: some Logitech/MX mice
        case 4, 9: return .forward
        default: return nil
        }
    }
}

/// Each window owns one monitor; its callback follows the selected tab.
struct MouseNavigationTarget: NSViewRepresentable {
    let navigate: (MouseNavigationCommand) -> Bool
    func makeNSView(context: Context) -> MouseNavigationView {
        MouseNavigationView(navigate: navigate)
    }
    func updateNSView(_ view: MouseNavigationView, context: Context) { view.navigate = navigate }
}

final class MouseNavigationView: NSView {
    var navigate: (MouseNavigationCommand) -> Bool
    private var monitor: Any?
    init(navigate: @escaping (MouseNavigationCommand) -> Bool) {
        self.navigate = navigate
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            NSLog("HEARTHMOUSE otherMouseDown button=\(event.buttonNumber) windowMatch=\(event.window === self?.window)")
            guard let self,
                self.handle(
                    MouseNavigationCommand.command(type: event.type, button: event.buttonNumber),
                    in: event.window)
            else { return event }
            return nil
        }
    }
    func handle(_ command: MouseNavigationCommand?, in eventWindow: NSWindow?) -> Bool {
        guard let window, eventWindow === window, window.attachedSheet == nil,
            NSApp.modalWindow == nil, let command
        else { return false }
        return navigate(command)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
