import SwiftUI
import AppKit

/// Hands back the `NSWindow` hosting the SwiftUI hierarchy once the view is
/// attached to it (a zero-size view in a `.background`).
struct WindowAccessor: NSViewRepresentable {
    var onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowAccessorView {
        let view = WindowAccessorView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: WindowAccessorView, context: Context) {
        view.onWindow = onWindow
    }
}

final class WindowAccessorView: NSView {
    var onWindow: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onWindow?(window) }
    }
}

/// Keeps the main window at least as wide as its columns. SwiftUI's own
/// `.frame(minWidth:)` on the window content is no use for this: it lays the
/// content out wider than the window and centres it, clipping both edges,
/// and AppKit never grows an existing window when that minimum changes.
/// Instead the policy knows the measured column widths and
/// 1. sets `window.contentMinSize` to sidebar + detail + inspector (+
///    dividers), so a drag can never make the window narrower than the
///    content;
/// 2. grows the window to that width when the panel is shown, a column
///    widens or the sidebar reappears (left edge kept, clamped to the
///    screen) — immediately on toggles, debounced for width changes, never
///    during a live resize (applied when the drag ends);
/// 3. on a screen too small for all three, grows as far as the screen
///    allows — the panel then yields down to its minimum (ContentView) —
///    and collapses the sidebar if even that does not fit, rather than clip.
@MainActor
final class WindowSizePolicy {
    /// Below this the preview is useless; the detail content carries the same `.frame(minWidth:)`.
    static let detailMinWidth: CGFloat = 420
    /// The window content's own minimum (`CNC_G_CoderApp`), the floor for `contentMinSize`.
    static let baseMinWidth: CGFloat = 900
    static let minHeight: CGFloat = 700
    /// NavigationSplitView's sidebar item is 8 pt wider than the sidebar
    /// content (divider + shadow), as the view dump shows (488 for 480).
    static let divider: CGFloat = 8

    private(set) weak var window: NSWindow?
    private(set) var sidebarVisible = true
    private(set) var sidebarWidth: CGFloat = ColumnWidthKeys.sidebarDefault
    private(set) var inspectorShown = false
    /// The panel's width as laid out (it yields when the window is tight).
    private(set) var inspectorWidth: CGFloat = ColumnWidthKeys.inspectorDefault
    /// The panel's stored width — what the window should make room for.
    private(set) var inspectorStoredWidth: CGFloat = ColumnWidthKeys.inspectorDefault
    /// Last measured content width of the window and detail width (log only).
    private(set) var contentWidth: CGFloat = 0
    var detailWidth: CGFloat = 0

    /// Asked to collapse the sidebar (through the view's binding) when the
    /// screen is too small for it beside the preview and the panel's minimum.
    var collapseSidebar: (() -> Void)?

    /// `-debugWindowSize` logging; `-debugScreenWidth N` caps the usable
    /// screen width to exercise the small-screen path on a large display.
    var logging = UserDefaults.standard.string(forKey: "debugWindowSize") != nil
    var screenWidthCap: CGFloat? = {
        let cap = UserDefaults.standard.double(forKey: "debugScreenWidth")
        return cap > 0 ? cap : nil
    }()

    private var pending: Task<Void, Never>?

    private func width(panel: CGFloat) -> CGFloat {
        var width = Self.detailMinWidth
        if sidebarVisible { width += sidebarWidth + Self.divider }
        if inspectorShown { width += panel + 1 }
        return width
    }

    /// What the window should grow to: the panel at its stored width.
    var desiredWidth: CGFloat { width(panel: inspectorStoredWidth) }
    /// What the user may not drag below: the columns as laid out now.
    var minimumWidth: CGFloat { width(panel: inspectorWidth) }
    /// Below this even the panel's minimum does not fit beside the sidebar.
    var floorWidth: CGFloat { width(panel: ColumnWidthKeys.inspectorMin) }

    // MARK: Inputs

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        Self.disableContentSizing(in: window)
        apply(immediate: true)
    }

    /// SwiftUI's hosting view re-measures the entire hierarchy (`minSize`)
    /// on every AppKit constraint pass — with the sidebar form, the machine
    /// panel and the canvases that is tens of milliseconds, and a running
    /// job (DRO, job bar) triggers it several times a second: a quarter of
    /// the main thread went there, starving status handling and the live
    /// bit. The window's minimum is this policy's `contentMinSize`, so the
    /// hosting view's own min/max/intrinsic sizing is not needed.
    private static func disableContentSizing(in window: NSWindow) {
        func visit(_ view: NSView, depth: Int) -> Bool {
            if let host = view as? HostingSizingControl { host.disableContentSizing(); return true }
            guard depth < 4 else { return false }
            for sub in view.subviews where visit(sub, depth: depth + 1) { return true }
            return false
        }
        guard let content = window.contentView else { return }
        let found = visit(content, depth: 0)
        if DebugFlags.renderLog { print("[debug] hosting view sizing options cleared: \(found) (content view \(type(of: content)))") }
    }


    func setSidebarVisible(_ visible: Bool) {
        guard sidebarVisible != visible else { return }
        sidebarVisible = visible
        apply(immediate: true)
    }

    func setInspectorShown(_ shown: Bool) {
        guard inspectorShown != shown else { return }
        inspectorShown = shown
        apply(immediate: true)
    }

    func setSidebarWidth(_ width: CGFloat) {
        guard width > 0, sidebarWidth != width else { return }
        sidebarWidth = width
        apply(immediate: false)
    }

    func setInspectorWidth(_ width: CGFloat) {
        guard width > 0, inspectorWidth != width else { return }
        inspectorWidth = width
        apply(immediate: false)
    }

    func setInspectorStoredWidth(_ width: CGFloat) {
        guard width > 0, inspectorStoredWidth != width else { return }
        inspectorStoredWidth = width
        apply(immediate: false)
    }

    func setContentWidth(_ width: CGFloat) {
        contentWidth = width
    }

    /// The user's drag ended (or starts): re-assert the minimum and fix up.
    func liveResizeEnded() { apply(immediate: true) }
    func liveResizeStarting() { updateMinimum() }

    /// Any other resize — a restored frame, a screen change, a programmatic
    /// `setFrame` — is checked after a pause; a live drag is handled above.
    func windowResized() {
        guard let window, !window.inLiveResize else { return }
        apply(immediate: false)
    }

    // MARK: Enforcement

    private func apply(immediate: Bool) {
        pending?.cancel()
        if immediate {
            enforce()
        } else {
            pending = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                self?.enforce()
            }
        }
    }

    private func updateMinimum() {
        guard let window else { return }
        let minimum = NSSize(width: max(minimumWidth, Self.baseMinWidth), height: Self.minHeight)
        if window.contentMinSize != minimum { window.contentMinSize = minimum }
    }

    private func enforce() {
        guard let window else { return }
        if window.inLiveResize { return }   // picked up by liveResizeEnded()
        updateMinimum()
        let contentWidth = window.contentRect(forFrameRect: window.frame).width
        if contentWidth >= desiredWidth {
            log("fits: content \(Int(contentWidth)) ≥ desired \(Int(desiredWidth))")
            return
        }
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        var usable = screen.map { window.contentRect(forFrameRect: NSRect(origin: .zero, size: $0.size)).width } ?? desiredWidth
        if let cap = screenWidthCap { usable = min(usable, cap) }

        if desiredWidth <= usable {
            grow(to: desiredWidth, within: screen)
            return
        }
        // The screen is too small for the panel at its stored width: take
        // what the screen gives (the panel yields), and if even the panel's
        // minimum does not fit beside the sidebar, the sidebar goes.
        log("screen allows \(Int(usable)) < desired \(Int(desiredWidth)): the panel yields")
        grow(to: usable, within: screen)
        let now = window.contentRect(forFrameRect: window.frame).width
        if now < floorWidth, sidebarVisible, let collapseSidebar {
            log("content \(Int(now)) < floor \(Int(floorWidth)): collapsing the sidebar")
            sidebarVisible = false
            collapseSidebar()
        }
        updateMinimum()
    }

    private func grow(to contentWidth: CGFloat, within screen: NSRect?) {
        guard let window else { return }
        var content = window.contentRect(forFrameRect: window.frame)
        guard content.width < contentWidth else { return }
        content.size.width = contentWidth
        var frame = window.frameRect(forContentRect: content)
        if let screen {
            if frame.width > screen.width { frame.size.width = screen.width }
            if frame.maxX > screen.maxX { frame.origin.x = max(screen.minX, screen.maxX - frame.width) }
            if frame.minX < screen.minX { frame.origin.x = screen.minX }
        }
        window.setFrame(frame, display: true, animate: false)
        log("grew to content \(Int(window.contentRect(forFrameRect: window.frame).width)) for desired \(Int(desiredWidth))")
    }

    private func log(_ message: String) {
        guard logging else { return }
        let columns = "sidebar \(sidebarVisible ? Int(sidebarWidth) : 0)\(sidebarVisible ? "" : " (collapsed)"), detail \(Int(detailWidth)), panel \(inspectorShown ? Int(inspectorWidth) : 0)\(inspectorShown ? "" : " (hidden)") (stored \(Int(inspectorStoredWidth)))"
        let minimum = window.map { "min \(Int($0.contentMinSize.width))" } ?? "no window"
        print("[debug] window policy: \(message) — \(columns); content \(Int(contentWidth)); \(minimum)")
    }
}


/// Lets the window policy reach `NSHostingView.sizingOptions` without
/// knowing the hosting view's generic content type.
@MainActor
private protocol HostingSizingControl: AnyObject {
    func disableContentSizing()
}

extension NSHostingView: HostingSizingControl {
    func disableContentSizing() {
        if !sizingOptions.isEmpty { sizingOptions = [] }
    }
}

/// The main window's root layout. AppKit asks SwiftUI's hosting view for
/// the content's minimum size on every constraint pass, and the hosting
/// view schedules one after every SwiftUI update (any observed value that
/// changes — a status report, a clock tick). With a `.frame(minWidth:)`
/// root that query measured the entire hierarchy — every button and
/// segmented control in the sidebar, the preview header and the machine
/// panel — at a different proposal than the real layout, so nothing was
/// cached: tens of milliseconds, dozens of times a second while a job
/// streams, starving status handling and the live bit. This layout never
/// measures its child for a size query: it reports `minimum` for small
/// proposals, `ideal` for an unspecified one, and the proposal otherwise,
/// then lays the child out in the full bounds. The window's real minimum
/// is `WindowSizePolicy.contentMinSize`.
struct RootSizeIsolator: Layout {
    var minimum: CGSize
    var ideal: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: max(proposal.width ?? ideal.width, minimum.width),
               height: max(proposal.height ?? ideal.height, minimum.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
    }
}
