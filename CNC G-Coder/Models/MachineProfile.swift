import Foundation

/// The machine a project's programs are written for: its G-code dialect,
/// its limits and how it changes tools. The choice is a project parameter
/// (`param.machineProfile`) so presets and project files reproduce the same
/// output; the machine window's connection settings are separate and
/// app-wide (`MachineSettings`).
///
/// `grbl` is today's output, unchanged: one `.ngc` per program, tool changes
/// as `T` / `M6` / `M0` pauses. `carvera` is Makera's Smoothieware-based
/// firmware, whose rules differ in ways that matter (see `MachinePost`):
/// `M0` is not implemented there, `T<n> M6` drives the automatic tool
/// changer, and the natural output is one file per machine session.
nonisolated struct MachineProfile: Identifiable, Hashable, Sendable {

    enum Kind: String, Sendable {
        /// GRBL 1.1 / FluidNC / LinuxCNC-style output (pcb2gcode's own layout).
        case grbl
        /// Makera Carvera / Carvera Air / Z1 (Smoothieware fork).
        case carvera
    }

    /// What a tool change in the file makes the machine do.
    enum ToolChange: Hashable, Sendable {
        /// `M6` followed by `M0`: the program stops, the operator swaps the bit.
        case pause
        /// `T<n> M6` picks slot n from the rack automatically; numbers above
        /// `slots` are refused by the firmware.
        case automatic(slots: Int)
        /// `T<n> M6` picks from the rack for n ≤ `slots`, and prompts for a
        /// manual change above that (Carvera community firmware).
        case automaticOrManual(slots: Int)
        /// `T<n> M6` always prompts the operator (Carvera Air, Z1).
        case manualPrompt

        /// Rack positions the firmware changes by itself, nil when none.
        var automaticSlots: Int? {
            switch self {
            case .automatic(let slots), .automaticOrManual(let slots): slots
            case .pause, .manualPrompt: nil
            }
        }

        /// The highest tool number a file may use, nil when unlimited.
        var maxToolNumber: Int? {
            if case .automatic(let slots) = self { return slots }
            return nil
        }
    }

    let id: String
    let name: String
    let kind: Kind
    /// Work area, mm (nil when unknown).
    let travelX: Double?
    let travelY: Double?
    let travelZ: Double?
    /// Spindle range, rpm.
    let spindleMin: Double
    let spindleMax: Double
    /// The machine's rapid speed, mm/min — the ceiling for feeds in its files
    /// and the rapid speed its time estimates assume.
    let maxFeed: Double
    let toolChange: ToolChange
    /// Extension of the program files ("ngc", "cnc").
    let fileExtension: String
    /// Compressed air (`M7`) while cutting — Carvera's own PCB files use it.
    let airDefault: Bool

    var isCarvera: Bool { kind == .carvera }

    // MARK: - Bundled profiles

    static let grbl = MachineProfile(
        id: "grbl", name: "Generic GRBL / FluidNC", kind: .grbl,
        travelX: nil, travelY: nil, travelZ: nil, spindleMin: 0, spindleMax: 99999, maxFeed: 99999,
        toolChange: .pause, fileExtension: "ngc", airDefault: false)

    static let carvera = MachineProfile(
        id: "carvera", name: "Makera Carvera", kind: .carvera,
        travelX: 360, travelY: 240, travelZ: 140, spindleMin: 0, spindleMax: 15000, maxFeed: 6000,
        toolChange: .automatic(slots: 6), fileExtension: "cnc", airDefault: true)

    static let carveraCommunity = MachineProfile(
        id: "carvera-community", name: "Makera Carvera (community firmware)", kind: .carvera,
        travelX: 360, travelY: 240, travelZ: 140, spindleMin: 0, spindleMax: 15000, maxFeed: 6000,
        toolChange: .automaticOrManual(slots: 6), fileExtension: "cnc", airDefault: true)

    static let carveraAir = MachineProfile(
        id: "carvera-air", name: "Makera Carvera Air", kind: .carvera,
        travelX: 300, travelY: 200, travelZ: 130, spindleMin: 0, spindleMax: 13000, maxFeed: 4000,
        toolChange: .manualPrompt, fileExtension: "cnc", airDefault: true)

    static let z1 = MachineProfile(
        id: "z1", name: "Makera Z1", kind: .carvera,
        travelX: 200, travelY: 200, travelZ: 100, spindleMin: 0, spindleMax: 13000, maxFeed: 1200,
        toolChange: .manualPrompt, fileExtension: "cnc", airDefault: true)

    static let all: [MachineProfile] = [grbl, carvera, carveraCommunity, carveraAir, z1]

    /// The profile behind a stored id; unknown or empty → `grbl`.
    static func named(_ id: String) -> MachineProfile {
        all.first { $0.id == id.trimmingCharacters(in: .whitespaces) } ?? grbl
    }

    /// One line for the sidebar's footer and the Generate dialog.
    var summary: String {
        switch kind {
        case .grbl:
            return String(localized: "One .ngc program per layer; tool changes pause the program (M6 / M0) for a manual bit swap. For GRBL, FluidNC and LinuxCNC-style controllers.")
        case .carvera:
            let change: String
            switch toolChange {
            case .automatic(let slots):
                change = String(localized: "T1–T\(slots) are the tool changer's slots; the firmware refuses higher numbers.")
            case .automaticOrManual(let slots):
                change = String(localized: "T1–T\(slots) are the tool changer's slots; higher numbers prompt for a manual change.")
            case .manualPrompt:
                change = String(localized: "Every T<n> M6 prompts for the bit and probes its length.")
            case .pause:
                change = ""
            }
            return String(localized: "One .cnc file per machine session, tool changes as T<n> M6 with the machine's own tool-length probe, no M0 pauses. \(change)")
        }
    }
}
