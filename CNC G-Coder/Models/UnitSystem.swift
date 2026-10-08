import SwiftUI

/// Display and entry units.
///
/// The pipeline itself is metric end to end: parameters are stored in
/// millimetres, pcb2gcode receives explicitly `mm`-suffixed arguments, the
/// generated programs are metric (G21) and every parsed toolpath coordinate is
/// a millimetre. This setting only changes the numbers the user reads and
/// types — a US user can work in inches without the machine ever seeing one.
nonisolated enum UnitSystem: String, CaseIterable, Identifiable, Sendable {
    case metric
    case imperial

    var id: String { rawValue }

    var title: String {
        switch self {
        case .metric: String(localized: "Metric — millimetres")
        case .imperial: String(localized: "Imperial — inches")
        }
    }

    var lengthSymbol: String {
        switch self {
        case .metric: "mm"
        case .imperial: "in"
        }
    }

    var feedSymbol: String {
        switch self {
        case .metric: "mm/min"
        case .imperial: "in/min"
        }
    }

    /// Display units per millimetre.
    var perMM: Double {
        switch self {
        case .metric: 1
        case .imperial: 1 / 25.4
        }
    }

    /// Decimals that keep the finest useful PCB dimension distinguishable:
    /// 0.01 mm, and 0.0001 in (0.1 mil) for the inch side.
    var lengthDecimals: Int {
        switch self {
        case .metric: 2
        case .imperial: 4
        }
    }

    var feedDecimals: Int {
        switch self {
        case .metric: 0
        case .imperial: 1
        }
    }

    /// Fixed-width `X…Y…Z…` format for the playback readout: wide enough that
    /// the sign and every digit fit, so values never jostle during playback.
    var positionFormat: String {
        switch self {
        case .metric: " · X%7.2f Y%7.2f Z%7.3f"
        case .imperial: " · X%8.4f Y%8.4f Z%9.5f"
        }
    }

    func fromMM(_ mm: Double) -> Double { mm * perMM }
    func toMM(_ value: Double) -> Double { value / perMM }

    /// A millimetre length, rendered in this unit system.
    func length(_ mm: Double, decimals: Int? = nil) -> String {
        String(format: "%.\(decimals ?? lengthDecimals)f", fromMM(mm))
    }

    /// A mm/min feed rate, rendered in this unit system.
    func feed(_ mmPerMinute: Double) -> String {
        String(format: "%.\(feedDecimals)f", fromMM(mmPerMinute))
    }

    /// Trims a converted value to the shortest form that round-trips at this
    /// unit's precision — for storing what the user typed, not for display.
    func canonicalMM(from displayValue: Double) -> String {
        let mm = toMM(displayValue)
        var text = String(format: "%.5f", mm)
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

nonisolated extension UnitSystem {
    /// The unit system outside a SwiftUI view (canvases resolve it per frame).
    static var current: UnitSystem {
        UnitSystem(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.unitSystem) ?? "") ?? .metric
    }
}
