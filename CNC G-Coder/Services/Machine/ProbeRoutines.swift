import Foundation

// The Z touch-off as pure line builders. The controller runs them one by
// one (each `G38.2` answers only when the probe has stopped), reads the
// trigger point from the `[PRB:…]` line attributed to that command, reads
// where the axis actually came to rest from the next status report, and
// inserts the `G10 L20` itself — so the origin is placed at the exact
// trigger point whatever overshoot the slow pass had. The overshoot is
// real: FluidNC keeps executing the step segments it had queued when the
// probe tripped, about 0.1 s, i.e. 0.03–0.05 mm at F20–30 — more than the
// copper foil is thick. Three boards lost their pads to a zero set at the
// resting position (2026-10-09).

/// Parameters of a two-pass Z probe. Distances in mm, feeds in mm/min.
nonisolated struct ZProbeSpec: Equatable, Sendable {
    /// How far the fast pass may descend before giving up (ALARM:5).
    var maxTravel: Double
    var feedFast: Double
    var feedSlow: Double
    /// Lift after the fast contact, before the slow pass.
    var backoff: Double = 1
    /// Lift after the slow contact, once the origin is set.
    var retract: Double
    /// Thickness of a touch plate between bit and surface; 0 when the bit
    /// touches the copper itself.
    var plateThickness: Double
    /// Travel of the slow pass: must cover `backoff` with margin.
    var finalPass: Double = 2
}

nonisolated enum ProbeRoutines {

    /// The lines before the origin is known, all incremental so the current
    /// work Z (stale from a previous board, or already far below) never
    /// changes how far the probe travels:
    /// `G21 G91`, fast probe down, back off, slow probe down.
    static func zProbeHead(_ spec: ZProbeSpec) -> [String] {
        [
            "G21 G91",
            GRBLCommand.probe(axis: .z, distance: -abs(spec.maxTravel), feed: spec.feedFast),
            "G0 Z" + GRBLCommand.number(abs(spec.backoff)),
            GRBLCommand.probe(axis: .z, distance: -abs(spec.finalPass), feed: spec.feedSlow),
        ]
    }

    /// After the origin is set: lift clear and restore absolute mode.
    static func zProbeTail(_ spec: ZProbeSpec) -> [String] {
        [
            "G0 Z" + GRBLCommand.number(abs(spec.retract)),
            "G90",
        ]
    }

    /// Sets the active system's Z origin on the contact point from the
    /// position the bit came to rest at: `overshoot` = PRB Z − resting Z
    /// (how far the axis ran on past the trigger before it stopped), so
    /// `G10 L20 P0 Z<plate − overshoot>` makes the resting position read
    /// `plate − overshoot` and the contact itself read `plate`. `L20` lets
    /// the controller fold any G92 or tool length offset in itself, and
    /// does not depend on how the firmware treats `L2 P0` (FluidNC 4.0.3
    /// left the G54 origin untouched by it).
    static func originLine(plate: Double, overshoot: Double) -> String {
        "G10 L20 P0 Z" + GRBLCommand.number(plate - overshoot)
    }

    /// The machine-coordinate origin `originLine` should produce, for the read-back check.
    static func expectedOrigin(prbMachineZ: Double, plate: Double) -> Double { prbMachineZ - plate }

    /// Why the spec cannot run, or nil. `remainingZTravel` is how far the
    /// axis can still descend from where it is (machine Z minus the range's
    /// bottom), nil when unknown.
    static func validate(_ spec: ZProbeSpec, remainingZTravel: Double?) -> String? {
        guard spec.maxTravel.isFinite, spec.maxTravel > 0 else { return "Probe max travel must be positive." }
        guard spec.feedFast > 0, spec.feedSlow > 0 else { return "Probe feeds must be positive." }
        guard spec.finalPass > spec.backoff else {
            return "The slow pass (\(GRBLCommand.number(spec.finalPass)) mm) must be longer than the back-off (\(GRBLCommand.number(spec.backoff)) mm)."
        }
        guard spec.maxTravel > spec.backoff + 2 else {
            return "Probe max travel must exceed the back-off plus 2 mm (at least \(GRBLCommand.number(spec.backoff + 2)) mm)."
        }
        guard spec.plateThickness >= 0, spec.plateThickness < 50 else { return "Plate thickness is out of range." }
        guard spec.retract >= 0 else { return "Probe retract cannot be negative." }
        if let remainingZTravel, remainingZTravel.isFinite, spec.maxTravel > remainingZTravel + 1e-6 {
            return String(format: "Probe max travel (%.1f mm) exceeds the remaining Z travel (%.1f mm): lower the travel or raise Z first.",
                          spec.maxTravel, remainingZTravel)
        }
        return nil
    }
}
