import AppKit
import SceneKit

/// Dev hook for documentation screenshots and visual checks without any
/// screen capture: `-debugWindowSnapshot /path.png` renders a window
/// offscreen `-debugWindowSnapshotAfter` seconds after the main window
/// appears (default 8) and, with `-debugWindowSnapshotExit 1`, quits. The
/// main window is rendered unless `-debugWindowSnapshotTitle "Tool Library"`
/// names another visible window. `-debugOpenWindow tools|machine|help`
/// (ContentView) opens that window at launch. Output paths must be inside
/// the app container (sandbox).
///
/// How the image is made (no window-server API is available to a sandboxed
/// app without the screen-recording permission): the window's frame view is
/// `cacheDisplay`ed for the title bar and toolbar, the content view is
/// rendered on its own and drawn over the content area (the frame view's
/// render leaves it blank), every SceneKit view is replaced by its own
/// `snapshot()` (Metal content never reaches `cacheDisplay`), and sheets are
/// composited on top at their real position with a shadow.
enum DebugWindowSnapshot {
    private static var armed = false

    static func arm() {
        guard !armed, let path = UserDefaults.standard.string(forKey: "debugWindowSnapshot") else { return }
        armed = true
        setvbuf(stdout, nil, _IOLBF, 0)
        var after = UserDefaults.standard.double(forKey: "debugWindowSnapshotAfter")
        if after <= 0 { after = 8 }
        print("[debug] window snapshot in \(after) s → \(path)")
        // Controls draw in their active state only for the key window of the
        // active app; the hook runs while a terminal is frontmost.
        DispatchQueue.main.asyncAfter(deadline: .now() + after - 0.5) {
            NSApp.activate(ignoringOtherApps: true)
            targetWindow()?.makeKeyAndOrderFront(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + after) {
            capture(to: path)
            if UserDefaults.standard.bool(forKey: "debugWindowSnapshotExit") { exit(0) }
        }
    }

    private static func targetWindow() -> NSWindow? {
        let visible = NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) && $0.sheetParent == nil }
        if let title = UserDefaults.standard.string(forKey: "debugWindowSnapshotTitle"), !title.isEmpty {
            if let match = visible.first(where: { $0.title.localizedCaseInsensitiveContains(title) }) { return match }
            print("[debug] window snapshot: no visible window titled \(title); windows: \(visible.map(\.title))")
        }
        return visible.first { $0.isMainWindow } ?? visible.first
    }

    /// `plain: true` renders with the window's non-vibrant appearance:
    /// views under a glass or visual-effect ancestor draw with a vibrant
    /// appearance (white, blended against the backdrop by the window
    /// server), which comes out as flat white in an offscreen bitmap.
    private static func cached(_ view: NSView, plain: Bool = false) -> NSBitmapImageRep? {
        let saved = view.appearance
        if plain {
            let dark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        }
        defer { if plain { view.appearance = saved } }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        // An own rep with alpha, zeroed: the rep AppKit hands out for some
        // transparent views (hosting views under glass) comes back opaque white.
        let scale = view.window?.backingScaleFactor ?? 2
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        return rep
    }

    private static func titlebarContainer(of frameView: NSView) -> NSView {
        frameView.subviews.first { String(describing: type(of: $0)).contains("TitlebarContainer") } ?? frameView
    }

    /// `NSBitmapImageRep.draw(in:)` replaces the destination (copy), which
    /// loses the background under transparent parts: blend instead.
    private static func blit(_ rep: NSBitmapImageRep, in rect: NSRect) {
        rep.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
    }

    private static func leaves(of view: NSView) -> [NSView] {
        if view.subviews.isEmpty { return [view] }
        return view.subviews.flatMap { leaves(of: $0) }
    }

    private static func views(in view: NSView, named fragment: String) -> [NSView] {
        var found: [NSView] = []
        if String(describing: type(of: view)).contains(fragment) { found.append(view) }
        for sub in view.subviews { found += views(in: sub, named: fragment) }
        return found
    }

    private static func sceneViews(in view: NSView) -> [SCNView] {
        var found: [SCNView] = []
        if let scene = view as? SCNView { found.append(scene) }
        for sub in view.subviews { found += sceneViews(in: sub) }
        return found
    }

    /// One window as an image in its own frame-view coordinates (points).
    /// `-debugWindowSnapshotMethod layer` renders the Core Animation layer
    /// tree instead of `cacheDisplay` (both skip Metal content, hence the
    /// SceneKit overlay); `-debugWindowSnapshotDump 1` prints the view tree.
    private static func render(_ window: NSWindow) -> NSImage? {
        guard let content = window.contentView else { return nil }
        let frameView = content.superview ?? content
        if UserDefaults.standard.bool(forKey: "debugWindowSnapshotDump") { dump(frameView, depth: 0) }
        let size = frameView.bounds.size
        let method = UserDefaults.standard.string(forKey: "debugWindowSnapshotMethod") ?? "cache"
        let blank = NSImage(size: size)
        return blank.compositing(size: size) { canvas in
            if method == "layer", let layer = frameView.layer, let cg = NSGraphicsContext.current?.cgContext {
                // CALayer renders top-down; AppKit's context is bottom-up.
                cg.saveGState()
                cg.translateBy(x: 0, y: size.height)
                cg.scaleBy(x: 1, y: -1)
                layer.render(in: cg)
                cg.restoreGState()
            } else {
                (window.backgroundColor ?? .windowBackgroundColor).setFill()
                NSRect(origin: .zero, size: size).fill()
                if let contentRep = cached(content) { blit(contentRep, in: content.frame); savePart(canvas, "pass-content") }
                // Glass containers (the sidebar on macOS 26) paint their
                // material white in cacheDisplay and hide what is under it:
                // fill their area with the window background and render the
                // classic hosting views inside their content holder instead.
                let background = (window.backgroundColor ?? .windowBackgroundColor)
                print("[debug] window snapshot: appearance \(window.effectiveAppearance.name.rawValue), current \(NSAppearance.current?.name.rawValue ?? "-"), background \(background.usingColorSpace(.deviceRGB).map { String(describing: $0) } ?? "?")")
                let glassViews = views(in: frameView, named: "GlassEffectView").filter { !$0.isDescendant(of: titlebarContainer(of: frameView)) }
                print("[debug] window snapshot: \(glassViews.count) glass view(s)")
                for glass in glassViews {
                    background.setFill()
                    glass.convert(glass.bounds, to: frameView).fill()
                    for holder in glass.subviews where String(describing: type(of: holder)).contains("ContentHolder") {
                        let hosts = views(in: holder, named: "NSHostingView<")
                        print("[debug] window snapshot: glass \(type(of: glass)) → \(hosts.count) host(s)")
                        for host in hosts {
                            if UserDefaults.standard.bool(forKey: "debugWindowSnapshotDump") { dump(host, depth: 0) }
                            // The hosting view's scroll view paints opaque white
                            // offscreen; its document view renders correctly, so
                            // draw that, clipped to the visible (clip view) area.
                            let scrolls = views(in: host, named: "ScrollView").compactMap { $0 as? NSScrollView }
                            if scrolls.isEmpty, let rep = cached(host, plain: true) {
                                blit(rep, in: host.convert(host.bounds, to: frameView))
                            }
                            for scroll in scrolls {
                                guard let doc = scroll.documentView else { continue }
                                let clip = scroll.contentView.convert(scroll.contentView.bounds, to: frameView)
                                NSGraphicsContext.saveGraphicsState()
                                NSBezierPath(rect: clip).addClip()
                                if let rep = cached(doc, plain: true) { blit(rep, in: doc.convert(doc.bounds, to: frameView)); savePart(rep, "document") }
                                NSGraphicsContext.restoreGraphicsState()
                            }
                        }
                    }
                }
                savePart(canvas, "pass-glass")
                // Title bar + toolbar: the same glass problem, so the strip is
                // rebuilt — background, a faint pill per glass platter, then
                // the toolbar items and the title bar's own views (buttons,
                // title) rendered one by one.
                for bar in frameView.subviews where String(describing: type(of: bar)).contains("TitlebarContainer") {
                    background.setFill()
                    bar.frame.fill()
                    for platter in views(in: bar, named: "ToolbarPlatterView") {
                        let r = platter.convert(platter.bounds, to: frameView)
                        NSColor.labelColor.withAlphaComponent(0.08).setFill()
                        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
                    }
                    for item in views(in: bar, named: "NSToolbarItemViewer") where !item.isHidden {
                        // The item's hosting views, not the viewer: a grouped
                        // item carries its own glass platter.
                        let hosts = views(in: item, named: "ToolbarItemHostingView")
                        for host in hosts.isEmpty ? [item] : hosts {
                            // The host itself paints white, and a zero-sized
                            // intermediate view clips its children in cacheDisplay:
                            // render the leaf views, each at its own frame.
                            for leaf in leaves(of: host) where !leaf.isHidden && !String(describing: type(of: leaf)).contains("FocusRing") {
                                if let rep = cached(leaf, plain: true) { blit(rep, in: leaf.convert(leaf.bounds, to: frameView)) }
                            }
                        }
                    }
                    // Traffic lights and the window title.
                    for widget in views(in: bar, named: "ThemeWidget") + views(in: bar, named: "NSTextField") where !widget.isHidden {
                        if let rep = cached(widget, plain: true) { blit(rep, in: widget.convert(widget.bounds, to: frameView)) }
                    }
                }
            }
            savePart(canvas, "pass-titlebar")
            for scene in sceneViews(in: content) where !scene.isHidden {
                let rect = scene.convert(scene.bounds, to: frameView)
                scene.snapshot().draw(in: rect)
            }
        }
    }

    /// `-debugWindowSnapshotParts /dir`: also writes each composited part.
    private static func savePart(_ rep: NSBitmapImageRep, _ name: String) {
        guard let dir = UserDefaults.standard.string(forKey: "debugWindowSnapshotParts") else { return }
        func px(_ x: Int, _ y: Int) -> String {
            guard x < rep.pixelsWide, y < rep.pixelsHigh, let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return "-" }
            return String(format: "%.2f/%.2f/%.2f/%.2f", c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
        }
        print("[debug] part \(name): \(rep.pixelsWide)×\(rep.pixelsHigh) corner=\(px(4, 4)) sidebar=\(px(200, 1000)) centre=\(px(rep.pixelsWide / 2, rep.pixelsHigh / 2))")
        // Saved over a dark backdrop so transparency is visible in a viewer.
        let image = NSImage(size: rep.size); image.addRepresentation(rep)
        let composed = NSImage(size: rep.size).compositing(size: rep.size) { _ in
            NSColor(white: 0.15, alpha: 1).setFill(); NSRect(origin: .zero, size: rep.size).fill()
            image.draw(in: NSRect(origin: .zero, size: rep.size))
        }
        guard let tiff = composed.tiffRepresentation, let out = NSBitmapImageRep(data: tiff),
              let data = out.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(Int(Date().timeIntervalSince1970 * 1000) % 100000).png"))
    }

    private static func dump(_ view: NSView, depth: Int) {
        let pad = String(repeating: "  ", count: depth)
        let f = view.frame
        print("[debug] \(pad)\(type(of: view)) \(Int(f.origin.x)),\(Int(f.origin.y)) \(Int(f.width))×\(Int(f.height))\(view.isHidden ? " hidden" : "")\(view.layer == nil ? "" : " layer")")
        if view.subviews.isEmpty, let layer = view.layer { dumpLayer(layer, depth: depth + 1) }
        if depth < 9 { for sub in view.subviews { dump(sub, depth: depth + 1) } }
    }

    private static func dumpLayer(_ layer: CALayer, depth: Int) {
        let pad = String(repeating: "  ", count: depth)
        let contents = layer.contents.map { String(describing: type(of: $0)) } ?? "-"
        let bg = (layer.backgroundColor?.components ?? []).map { String(format: "%.2f", $0) }.joined(separator: ",")
        print("[debug] \(pad)· \(type(of: layer)) \(Int(layer.frame.origin.x)),\(Int(layer.frame.origin.y)) \(Int(layer.frame.width))×\(Int(layer.frame.height)) contents=\(contents) bg=\(bg) opacity=\(layer.opacity) sublayers=\(layer.sublayers?.count ?? 0)\(layer.isHidden ? " hidden" : "")\(layer.delegate == nil ? "" : " delegate")")
        if depth < 6 { for sub in (layer.sublayers ?? []).prefix(8) { dumpLayer(sub, depth: depth + 1) } }
    }

    /// `-debugWindowSnapshotSidebarScroll bottom|<0…1>`: scrolls the sidebar's
    /// form before the capture, for sections at the end of a long form.
    private static func scrollSidebarIfRequested(_ window: NSWindow) {
        guard let spec = UserDefaults.standard.string(forKey: "debugWindowSnapshotSidebarScroll"), let content = window.contentView else { return }
        let fraction = spec == "bottom" ? 1.0 : (Double(spec) ?? 0)
        for glass in views(in: content, named: "GlassEffectView") {
            for scroll in views(in: glass, named: "ScrollView").compactMap({ $0 as? NSScrollView }) {
                guard let doc = scroll.documentView else { continue }
                let y = max(0, doc.bounds.height - scroll.contentView.bounds.height) * fraction
                scroll.contentView.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? y : doc.bounds.height - scroll.contentView.bounds.height - y))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
    }

    static func capture(to path: String) {
        guard let window = targetWindow() else { print("[debug] window snapshot: no window"); return }
        scrollSidebarIfRequested(window)
        guard let base = render(window) else { print("[debug] window snapshot: render failed"); return }
        let sheets = window.sheets.filter(\.isVisible)
        let scale = window.backingScaleFactor
        let size = base.size
        guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: canvas) else { return }
        canvas.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)   // the bitmap context counts pixels; draw in points
        base.draw(in: NSRect(origin: .zero, size: size))
        for sheet in sheets {
            guard let image = render(sheet) else { continue }
            let origin = NSPoint(x: sheet.frame.origin.x - window.frame.origin.x,
                                 y: sheet.frame.origin.y - window.frame.origin.y)
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 24
            shadow.shadowOffset = NSSize(width: 0, height: -8)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.set()
            image.draw(in: NSRect(origin: origin, size: sheet.frame.size))
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = canvas.representation(using: .png, properties: [:]) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("[debug] window snapshot written to \(path) (\(canvas.pixelsWide)×\(canvas.pixelsHigh) px, \(sheets.count) sheet(s), window \"\(window.title)\")")
        } catch {
            print("[debug] window snapshot: \(error.localizedDescription)")
        }
    }
}

private extension NSImage {
    /// A new image of `size` with this image drawn first and `draw` on top,
    /// rendered at the main screen's scale.
    func compositing(size: NSSize, _ draw: (NSBitmapImageRep) -> Void) -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return self }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)   // pixel-unit context, point-unit drawing
        self.draw(in: NSRect(origin: .zero, size: size))
        draw(rep)
        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: size)
        result.addRepresentation(rep)
        return result
    }
}
