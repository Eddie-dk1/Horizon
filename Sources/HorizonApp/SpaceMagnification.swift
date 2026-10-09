import AppKit
import SwiftUI

/// Native trackpad magnification and Escape reach the map regardless of focus.
/// The observing view never intercepts clicks, drags or file drops.
struct SpaceMagnification: NSViewRepresentable {
    let changed: (Double, CGPoint) -> Void
    let escape: () -> Bool
    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView(); view.changed = changed; view.escape = escape
        return view
    }
    func updateNSView(_ view: ObserverView, context: Context) { view.changed = changed; view.escape = escape }
    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.stop() }

    final class ObserverView: NSView {
        var changed: ((Double, CGPoint) -> Void)?
        var escape: (() -> Bool)?
        private var monitor: Any?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .keyDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                if event.type == .keyDown {
                    guard event.keyCode == 53, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                          window.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
                    return self.escape?() == true ? nil : event
                }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point), event.magnification.isFinite else { return event }
                self.changed?(Double(event.magnification), point)
                return nil
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
