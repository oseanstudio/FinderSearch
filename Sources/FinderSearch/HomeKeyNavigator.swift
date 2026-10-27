import SwiftUI
import AppKit
import Combine

// HOME: keyboard support for the fork's card-based views. A local key
// monitor scoped to the browser window: up/down move the highlighted row,
// Space Quick Looks it, Return opens it. While a text field has focus, only
// the vertical arrows are taken (they move results, Spotlight-style) and
// typing passes straight through. Sheets and other routes are left alone.

@MainActor final class HomeKeyNavigator: ObservableObject {
    private var monitor: Any?
    private var isActive: (() -> Bool)?
    private var onMove: ((Int) -> Void)?
    private var onPreview: (() -> Void)?
    private var onOpen: (() -> Void)?

    /// Installs while the view is on screen; `isActive` is re-checked on
    /// every event so the view stays quiet on other routes. Set
    /// `arrowsWhileEditing` when the view has a search field the user types
    /// in: up/down then step through results from inside the field.
    func install(
        isActive: @escaping () -> Bool,
        arrowsWhileEditing: Bool = false,
        onMove: @escaping (Int) -> Void,
        onPreview: @escaping () -> Void,
        onOpen: @escaping () -> Void
    ) {
        guard monitor == nil else { return }
        self.isActive = isActive
        self.onMove = onMove
        self.onPreview = onPreview
        self.onOpen = onOpen
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self, let isActive = self.isActive, isActive(),
                NSApp.keyWindow?.isSheet != true
            else { return event }
            let editing = NSApp.keyWindow?.firstResponder is NSTextView
            let vertical = event.keyCode == 125 || event.keyCode == 126
            if editing && !(arrowsWhileEditing && vertical) { return event }
            switch event.keyCode {
            case 125:  // down
                self.onMove?(1); return nil
            case 126:  // up
                self.onMove?(-1); return nil
            case 49 where !editing:  // space
                self.onPreview?(); return nil
            case 36 where !editing:  // return
                self.onOpen?(); return nil
            default:
                return event
            }
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isActive = nil
        onMove = nil
        onPreview = nil
        onOpen = nil
    }
}
