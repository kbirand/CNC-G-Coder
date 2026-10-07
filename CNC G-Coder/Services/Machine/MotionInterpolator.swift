import Foundation
import simd

/// Snapshot interpolation of the machine's reported position, usable from
/// any thread (SceneKit's render callback included).
///
/// Status reports arrive a few times a second; between them the position is
/// dead-reckoned along the velocity of the last two distinct reports, capped
/// at 1.5 report intervals so a late report never lets the bit run away.
/// When a report lands, the displayed position stays continuous: the
/// difference between where the display was and where the report says it
/// should be becomes an offset that decays over ~80 ms instead of a jump.
nonisolated final class MotionInterpolator: @unchecked Sendable {
    private let lock = NSLock()
    private var last: (time: TimeInterval, position: MachinePosition)?
    private var previous: (time: TimeInterval, position: MachinePosition)?
    /// Displayed − expected at the time of the last report, decaying.
    private var offset = SIMD3<Double>(repeating: 0)
    private var offsetTime: TimeInterval = 0

    static let minimumSampleGap: TimeInterval = 0.02
    static let extrapolationFactor = 1.5
    static let catchUpTimeConstant = 0.08
    static let snapDistance = 3.0

    func reset() {
        lock.lock(); defer { lock.unlock() }
        last = nil; previous = nil; offset = .zero
    }

    /// A new report at `time` (ProcessInfo.systemUptime seconds).
    func push(_ position: MachinePosition, at time: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if let displayed = positionLocked(at: time) {
            let d = SIMD3(displayed.x - position.x, displayed.y - position.y, displayed.z - position.z)
            offset = simd_length(d) > Self.snapDistance ? .zero : d
            offsetTime = time
        }
        if let l = last, time - l.time < Self.minimumSampleGap {
            // Two reports of the same instant (a poll and an extra query):
            // keep the newer position, do not form a velocity from them.
            last = (l.time, position)
            return
        }
        previous = last
        last = (time, position)
    }

    /// Where to draw the machine at `time`.
    func position(at time: TimeInterval) -> MachinePosition? {
        lock.lock(); defer { lock.unlock() }
        return positionLocked(at: time)
    }

    private func positionLocked(at time: TimeInterval) -> MachinePosition? {
        guard let l = last else { return nil }
        var base = SIMD3(l.position.x, l.position.y, l.position.z)
        if let p = previous {
            let dt = l.time - p.time
            if dt >= Self.minimumSampleGap {
                let v = (base - SIMD3(p.position.x, p.position.y, p.position.z)) / dt
                let since = min(max(time - l.time, 0), dt * Self.extrapolationFactor)
                base += v * since
            }
        }
        let decay = exp(-max(time - offsetTime, 0) / Self.catchUpTimeConstant)
        let shown = base + offset * decay
        return MachinePosition(x: shown.x, y: shown.y, z: shown.z)
    }
}
