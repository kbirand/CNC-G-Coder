import SwiftUI
import AppKit

/// Invisible overlay that feeds scroll-wheel events to a handler without
/// blocking clicks or drags: hit testing passes through, and a local event
/// monitor picks up wheel events whose cursor is over this view.
struct ScrollWheelCatcher: NSViewRepresentable {
    var onScroll: (_ deltaY: CGFloat, _ location: CGPoint, _ size: CGSize) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat, CGPoint, CGSize) -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true }   // match SwiftUI's top-left origin
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    guard let self, let window = self.window, event.window === window else { return event }
                    let location = self.convert(event.locationInWindow, from: nil)
                    guard self.bounds.contains(location) else { return event }
                    let delta = event.hasPreciseScrollingDeltas
                        ? event.scrollingDeltaY
                        : event.scrollingDeltaY * 8
                    self.onScroll?(delta, location, self.bounds.size)
                    return nil
                }
            } else if window == nil, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

/// Thin draggable divider for persistent split layouts.
struct SplitDragHandle: View {
    /// true: divider between left/right panes (horizontal drag);
    /// false: divider between top/bottom panes (vertical drag).
    var axisVertical: Bool
    var onDrag: (CGFloat) -> Void

    @State private var last: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Color.black.opacity(0.001))   // invisible but hit-testable
            .frame(width: axisVertical ? 7 : nil, height: axisVertical ? nil : 7)
            .overlay(
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: axisVertical ? 1 : nil, height: axisVertical ? nil : 1)
            )
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    (axisVertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let current = axisVertical ? value.translation.width : value.translation.height
                        onDrag(current - last)
                        last = current
                    }
                    .onEnded { _ in last = 0 }
            )
    }
}

/// Ends editing in whichever text field currently has focus.
@MainActor
func resignTextFieldFocus() {
    NSApp.keyWindow?.makeFirstResponder(nil)
}

/// "m:ss" under an hour, "h:mm:ss" above.
nonisolated func formatDuration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    if s >= 3600 {
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
    return String(format: "%d:%02d", s / 60, s % 60)
}

/// Invisible overlay that pans with the right or middle mouse button, the
/// way the 3D view does, without taking left clicks or drags from the views
/// underneath. A local event monitor picks up drags that start over it.
struct MousePanCatcher: NSViewRepresentable {
    var onPan: (_ delta: CGSize) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onPan = onPan
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onPan = onPan
    }

    final class CatcherView: NSView {
        var onPan: ((CGSize) -> Void)?
        private var monitor: Any?
        private var last: CGPoint?

        override var isFlipped: Bool { true }   // match SwiftUI's top-left origin
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, monitor == nil {
                let mask: NSEvent.EventTypeMask = [.rightMouseDown, .rightMouseDragged, .rightMouseUp,
                                                   .otherMouseDown, .otherMouseDragged, .otherMouseUp]
                monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                    guard let self, let window = self.window, event.window === window else { return event }
                    let location = self.convert(event.locationInWindow, from: nil)
                    switch event.type {
                    case .rightMouseDown, .otherMouseDown:
                        guard self.bounds.contains(location) else { return event }
                        self.last = location
                        return nil   // no context menu: the button pans here
                    case .rightMouseDragged, .otherMouseDragged:
                        guard let last = self.last else { return event }
                        self.onPan?(CGSize(width: location.x - last.x, height: location.y - last.y))
                        self.last = location
                        return nil
                    default:
                        guard self.last != nil else { return event }
                        self.last = nil
                        return nil
                    }
                }
            } else if window == nil, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
