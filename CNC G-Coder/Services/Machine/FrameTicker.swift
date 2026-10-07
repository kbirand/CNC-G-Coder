import AppKit
import QuartzCore

/// A main-thread callback once per screen refresh (`CADisplayLink`), for
/// state that must move with the frames: the live preview clock while a
/// job streams. `Task.sleep` loops drift and jitter against vsync; a
/// display link fires just before each frame is built.
@MainActor
final class FrameTicker: NSObject {
    private let tick: () -> Void
    private var link: CADisplayLink?

    init(_ tick: @escaping () -> Void) {
        self.tick = tick
    }

    var isRunning: Bool { link != nil }

    func start() {
        guard link == nil, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let link = screen.displayLink(target: self, selector: #selector(fire(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func fire(_ link: CADisplayLink) {
        tick()
    }
}
