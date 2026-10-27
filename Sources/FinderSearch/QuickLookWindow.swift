import SwiftUI
import AppKit
import Quartz

// HOME: Quick Look in its own resizable window. The preview content is a
// QLPreviewView that this container scales (zoom) and offsets (pan):
//
//   • scroll wheel / trackpad two-finger scroll — zoom, anchored at the cursor
//   • pinch — zoom, anchored at the cursor
//   • middle-button drag, or plain drag — pan
//   • double-click — back to fit
//
// The window itself is a normal titled, resizable panel, so it can be made
// any size — including maximize/fullscreen — beyond the old sheet's ceiling.

// MARK: - Zoom canvas

final class ZoomCanvasView: NSView {
    private let preview: QLPreviewView
    private var url: URL
    private var scale: CGFloat = 1
    private var offset: CGPoint = .zero
    private var middlePan: (start: CGPoint, origin: CGPoint)?
    private var leftPan: (start: CGPoint, origin: CGPoint)?
    private static let minScale: CGFloat = 0.25
    private static let maxScale: CGFloat = 16

    init(url: URL) {
        self.url = url
        preview = QLPreviewView(frame: .zero, style: .normal)!
        super.init(frame: .zero)
        preview.previewItem = url as NSURL
        preview.autoresizingMask = []
        addSubview(preview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func update(url newURL: URL) {
        guard newURL != url else { return }
        url = newURL
        preview.previewItem = newURL as NSURL
        resetZoom()
    }

    func resetZoom() {
        scale = 1
        offset = .zero
        needsLayout = true
    }

    private var contentSize: CGSize {
        CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    override func layout() {
        super.layout()
        clamp()
        preview.frame = CGRect(origin: offset, size: contentSize)
    }

    /// Zoom by `factor`, keeping the content point under `anchor` stationary.
    private func zoom(by factor: CGFloat, around anchor: CGPoint) {
        let newScale = min(Self.maxScale, max(Self.minScale, scale * factor))
        let applied = newScale / scale
        guard applied != 1 else { return }
        let content = CGPoint(
            x: (anchor.x - offset.x) / scale, y: (anchor.y - offset.y) / scale)
        scale = newScale
        offset = CGPoint(
            x: anchor.x - content.x * newScale, y: anchor.y - content.y * newScale)
        clamp()
        needsLayout = true
    }

    /// Smaller-than-view content stays centered; larger content never leaves
    /// an empty edge on screen.
    private func clamp() {
        let size = contentSize
        if size.width <= bounds.width {
            offset.x = (bounds.width - size.width) / 2
        } else {
            offset.x = min(0, max(bounds.width - size.width, offset.x))
        }
        if size.height <= bounds.height {
            offset.y = (bounds.height - size.height) / 2
        } else {
            offset.y = min(0, max(bounds.height - size.height, offset.y))
        }
    }

    private func drag(to point: CGPoint, from pan: (start: CGPoint, origin: CGPoint)) {
        offset = CGPoint(
            x: pan.origin.x + (point.x - pan.start.x),
            y: pan.origin.y + (point.y - pan.start.y))
        clamp()
        needsLayout = true
    }

    // The container owns every event; the preview inside only renders.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }

    override func scrollWheel(with event: NSEvent) {
        let anchor = convert(event.locationInWindow, from: nil)
        // Any scroll zooms at the cursor; tuned so a plain wheel notch is
        // ≈1.2× and trackpad swipes feel proportional.
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return super.scrollWheel(with: event) }
        zoom(by: pow(1.08, delta * 0.25), around: anchor)
    }

    override func magnify(with event: NSEvent) {
        zoom(
            by: 1 + event.magnification,
            around: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            resetZoom()
            return
        }
        leftPan = (convert(event.locationInWindow, from: nil), offset)
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pan = leftPan else { return super.mouseDragged(with: event) }
        drag(to: convert(event.locationInWindow, from: nil), from: pan)
    }

    override func mouseUp(with event: NSEvent) {
        if leftPan != nil { NSCursor.pop() }
        leftPan = nil
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        middlePan = (convert(event.locationInWindow, from: nil), offset)
        NSCursor.closedHand.push()
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 2, let pan = middlePan
        else { return super.otherMouseDragged(with: event) }
        drag(to: convert(event.locationInWindow, from: nil), from: pan)
    }

    override func otherMouseUp(with event: NSEvent) {
        if middlePan != nil { NSCursor.pop() }
        middlePan = nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

struct ZoomablePreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> ZoomCanvasView {
        ZoomCanvasView(url: url)
    }

    func updateNSView(_ view: ZoomCanvasView, context: Context) {
        view.update(url: url)
    }
}

// MARK: - Window

@MainActor final class QuickLookWindowController: NSObject, NSWindowDelegate {
    static let shared = QuickLookWindowController()
    private var panel: NSPanel?
    private weak var model: SearchModel?

    func present(_ model: SearchModel) {
        if panel?.isVisible == true, self.model === model { return }
        dismiss()
        self.model = model
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        panel.title = "Quick Look"
        panel.isReleasedWhenClosed = false
        panel.setContentSize(NSSize(width: 1000, height: 700))
        panel.minSize = NSSize(width: 520, height: 380)
        panel.contentView = NSHostingView(rootView: QuickLookBrowser(model: model))
        panel.delegate = self
        panel.center()
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        model?.preview = nil
        model = nil
        panel.close()
    }

    /// Whether the visible panel is showing this model's preview (another
    /// tab's preview must not be dismissed from this model's change).
    func shows(_ model: SearchModel) -> Bool {
        panel?.isVisible == true && self.model === model
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            guard let window = notification.object as? NSWindow,
                QuickLookWindowController.shared.panel === window
            else { return }
            QuickLookWindowController.shared.panel = nil
            QuickLookWindowController.shared.model?.preview = nil
            QuickLookWindowController.shared.model = nil
        }
    }
}
