import SwiftUI
import Combine

/// A plain value copy of all machining parameters, safe to hand to background work.
/// Diameters are EFFECTIVE: a V-bit's width at its cut depth, already worked out.
nonisolated struct ParameterSnapshot: Sendable {
    var millDiameter, isolationWidth, zWork, millFeed, millVertFeed, millSpeed: String
    var millOverlap, millInfeed: String
    var zDrill, drillFeed, drillSpeed, drillPeck: String
    /// pcb2gcode --drills-available entries ("0.8mm:-0.1mm:+0.1mm"); empty = drill every size as designed.
    var drillBits: [String]
    /// Added to every designed hole diameter before anything else (mm).
    var drillHoleAllowance: String
    var drillMillLarge: Bool
    var drillMillFrom: String
    var holeMillDiameter, holeMillDepth, holeMillInfeed, holeMillFeed, holeMillVertFeed, holeMillSpeed: String
    /// Seconds to wait after the spindle starts (and stops), per program kind.
    var millDwell, drillDwell, holeMillDwell, cutDwell, maskDwell, silkDwell: String
    var cutterDiameter, zCut, cutFeed, cutVertFeed, cutSpeed, cutInfeed: String
    var bridgeWidth, bridgeCount, zBridge: String
    var maskMode: String                        // "off" | "gcode" | "svg"
    var maskTool, maskDepth, maskClearWidth, maskFeed, maskVertFeed, maskSpeed, maskOverlap: String
    var silkMode: String                        // "off" | "gcode"
    var silkTool, silkDepth, silkClearWidth, silkFeed, silkVertFeed, silkSpeed, silkOverlap: String
    var zSafe, zChange, mirrorAxis, plungeClearance: String
    var millDirection: String                   // "any" | "climb" | "conventional"
    var originMode: String                      // see ParametersStore.originMode
    var originX, originY: String                // custom origin, design coordinates
    var mirrorYAxis, zeroStart: Bool
    /// Per settings group (keyed by ParametersStore.MotionGroup prefix):
    /// travel and tool-change heights ("" = Machine setup's), extra cut
    /// length, milling direction ("" = Machine setup's) and "cw"/"ccw".
    var travelZ: [String: String] = [:]
    var changeZ: [String: String] = [:]
    var extraCut: [String: String] = [:]
    var direction: [String: String] = [:]
    var spindleDir: [String: String] = [:]
    /// G0 speed for time estimates, mm/min.
    var rapidFeed = "2000"
    /// "pcb2gcode" or "native".
    var engine = "pcb2gcode"
    /// Drill files with settings of their own (by file name): a complete
    /// snapshot each, with that file's drilling and hole-milling values.
    var drillLayers: [String: ParameterSnapshot] = [:]

    /// The settings that drive the drill file `file` (its name): its own
    /// where it has them, otherwise these.
    func forDrill(file: String) -> ParameterSnapshot {
        drillLayers[file] ?? self
    }

    /// The settings behind one program: a drill program (drilled or milled
    /// holes) uses its drill file's own; every other program uses these.
    func forLayer(_ kind: LayerKind, files: DetectedFiles) -> ParameterSnapshot {
        guard let index = kind.drillIndex, files.drills.indices.contains(index) else { return self }
        return forDrill(file: files.drills[index].lastPathComponent)
    }

    /// The group's travel height, or Machine setup's Safe Z.
    func zSafe(_ group: ParametersStore.MotionGroup) -> String {
        travelZ[group.rawValue].flatMap { Double($0) != nil ? $0 : nil } ?? zSafe
    }

    /// The group's tool-change (and end-of-program) height, or Machine setup's.
    func zChange(_ group: ParametersStore.MotionGroup) -> String {
        changeZ[group.rawValue].flatMap { Double($0) != nil ? $0 : nil } ?? zChange
    }

    /// "any" | "climb" | "conventional" for the group.
    func millDirection(_ group: ParametersStore.MotionGroup) -> String {
        let own = direction[group.rawValue] ?? ""
        return own.isEmpty ? millDirection : own
    }

    func extraCutLength(_ group: ParametersStore.MotionGroup) -> Double {
        max(0, Double(extraCut[group.rawValue] ?? "") ?? 0)
    }

    func spindleCCW(_ group: ParametersStore.MotionGroup) -> Bool {
        spindleDir[group.rawValue] == "ccw"
    }
}

/// A complete set of parameter values: the defaults under their preset
/// keys, and every drill file's own values (see
/// ParametersStore.drillLayerValues). What the undo history steps between.
nonisolated struct ParameterState: Equatable, Sendable {
    var values: [String: String] = [:]
    var drillLayers: [String: [String: String]] = [:]

    /// The keys whose value differs from `other`'s: preset keys, and
    /// "file/key" for a drill file's own value.
    func changedKeys(from other: ParameterState) -> [String] {
        var keys = Array(Set(values.keys).union(other.values.keys).filter { values[$0] != other.values[$0] })
        for file in Set(drillLayers.keys).union(other.drillLayers.keys) {
            let mine = drillLayers[file] ?? [:], theirs = other.drillLayers[file] ?? [:]
            keys += Set(mine.keys).union(theirs.keys).filter { mine[$0] != theirs[$0] }.map { "\(file)/\($0)" }
        }
        return keys.sorted()
    }
}

/// All user-editable machining parameters, persisted across launches.
@MainActor
final class ParametersStore: ObservableObject {
    /// Resolves the drill bits on hand; set by AppModel.
    weak var library: ToolLibrary?

    // Copper isolation
    @AppStorage("param.millToolID") var millToolID = ""
    @AppStorage("param.millShape") var millShape = "flat"          // flat | vbit
    @AppStorage("param.millDiameter") var millDiameter = "0.10"
    @AppStorage("param.millVTip") var millVTip = "0.10"
    @AppStorage("param.millVAngle") var millVAngle = "30"
    @AppStorage("param.isolationWidth") var isolationWidth = "0.20"
    @AppStorage("param.zWork") var zWork = "-0.06"
    // Depth per pass; 0 = the whole cut depth in one pass.
    @AppStorage("param.millInfeed") var millInfeed = "0"
    @AppStorage("param.millOverlap") var millOverlap = "50"
    @AppStorage("param.millFeed") var millFeed = "240"
    @AppStorage("param.millVertFeed") var millVertFeed = "60"
    @AppStorage("param.millSpeed") var millSpeed = "12000"
    // Pause after M3 for the spindle to reach speed (and after M5 to stop), seconds.
    @AppStorage("param.millDwell") var millDwell = "1.0"

    // Drilling
    @AppStorage("param.drillToolID") var drillToolID = ""
    @AppStorage("param.zDrill") var zDrill = "-1.80"
    @AppStorage("param.drillFeed") var drillFeed = "80"
    @AppStorage("param.drillSpeed") var drillSpeed = "12000"
    // Depth per peck; 0 = straight through.
    @AppStorage("param.drillPeck") var drillPeck = "0"
    // Library drill IDs, comma-separated. Empty = one bit per designed size.
    @AppStorage("param.drillBitIDs") var drillBitIDs = ""
    // Tolerance for bits whose library entry has no range of its own.
    @AppStorage("param.drillBitTolerance") var drillBitTolerance = "0.10"
    // Added to every hole's designed diameter (FR4 closes up a little).
    @AppStorage("param.drillHoleAllowance") var drillHoleAllowance = "0.125"
    @AppStorage("param.drillDwell") var drillDwell = "1.0"
    // Hole milling: holes from drillMillFrom up are milled as helices with
    // their own end mill instead of drilled.
    @AppStorage("param.drillMillLarge") var drillMillLarge = false
    @AppStorage("param.drillMillFrom") var drillMillFrom = "2.0"
    @AppStorage("param.holeMillToolID") var holeMillToolID = ""
    @AppStorage("param.holeMillDiameter") var holeMillDiameter = "1.0"
    @AppStorage("param.holeMillDepth") var holeMillDepth = "-1.8"
    @AppStorage("param.holeMillInfeed") var holeMillInfeed = "0.6"
    @AppStorage("param.holeMillFeed") var holeMillFeed = "120"
    @AppStorage("param.holeMillVertFeed") var holeMillVertFeed = "60"
    @AppStorage("param.holeMillSpeed") var holeMillSpeed = "12000"
    @AppStorage("param.holeMillDwell") var holeMillDwell = "1.0"

    // Board cutout
    @AppStorage("param.cutToolID") var cutToolID = ""
    @AppStorage("param.cutterDiameter") var cutterDiameter = "1.00"
    @AppStorage("param.zCut") var zCut = "-1.80"
    @AppStorage("param.cutFeed") var cutFeed = "120"
    @AppStorage("param.cutVertFeed") var cutVertFeed = "60"
    @AppStorage("param.cutSpeed") var cutSpeed = "12000"
    @AppStorage("param.cutDwell") var cutDwell = "1.0"
    @AppStorage("param.cutInfeed") var cutInfeed = "0.40"
    @AppStorage("param.bridgeWidth") var bridgeWidth = "2.00"
    @AppStorage("param.bridgeCount") var bridgeCount = "4"
    @AppStorage("param.zBridge") var zBridge = "-0.80"

    // Solder mask (openings are etched away after painting/curing the mask)
    @AppStorage("param.maskMode") var maskMode = "gcode"   // off | gcode | svg
    @AppStorage("param.maskToolID") var maskToolID = ""
    @AppStorage("param.maskShape") var maskShape = "flat"
    @AppStorage("param.maskTool") var maskTool = "0.80"
    @AppStorage("param.maskVTip") var maskVTip = "0.10"
    @AppStorage("param.maskVAngle") var maskVAngle = "30"
    @AppStorage("param.maskDepth") var maskDepth = "-0.10"
    // How far inward each opening is cleared. Must be at least half the widest
    // mask opening. Generation time explodes with larger values, so keep small.
    @AppStorage("param.maskClearWidth") var maskClearWidth = "1.2"
    // On: the clear width is half the widest opening of the mask layers
    // (plus a little), so every opening is cleared to its centre and no
    // wider — maskClearWidth is then only the fallback with no mask files.
    @AppStorage("param.maskClearAuto") var maskClearAuto = true
    /// The widest opening of the project's mask layers (mm), measured by
    /// AppModel whenever the files change; nil without mask layers.
    @Published var widestMaskOpening: Double?
    @AppStorage("param.maskOverlap") var maskOverlap = "40"
    @AppStorage("param.maskFeed") var maskFeed = "120"
    @AppStorage("param.maskVertFeed") var maskVertFeed = "60"
    @AppStorage("param.maskSpeed") var maskSpeed = "12000"
    @AppStorage("param.maskDwell") var maskDwell = "1.0"

    // Silkscreen legend (engraved after the mask, or laser-marked)
    @AppStorage("param.silkMode") var silkMode = "off"     // off | gcode
    @AppStorage("param.silkToolID") var silkToolID = ""
    @AppStorage("param.silkShape") var silkShape = "flat"
    @AppStorage("param.silkTool") var silkTool = "0.10"
    @AppStorage("param.silkVTip") var silkVTip = "0.10"
    @AppStorage("param.silkVAngle") var silkVAngle = "30"
    @AppStorage("param.silkDepth") var silkDepth = "-0.05"
    // Legend strokes are thin (0.15–0.25 mm), so a little clearing covers them.
    @AppStorage("param.silkClearWidth") var silkClearWidth = "0.30"
    @AppStorage("param.silkOverlap") var silkOverlap = "40"
    @AppStorage("param.silkFeed") var silkFeed = "180"
    @AppStorage("param.silkVertFeed") var silkVertFeed = "60"
    @AppStorage("param.silkSpeed") var silkSpeed = "12000"
    @AppStorage("param.silkDwell") var silkDwell = "1.0"

    // Alignment / safety
    @AppStorage("param.zSafe") var zSafe = "3.0"
    @AppStorage("param.zChange") var zChange = "10.0"
    // Plunges rapid through the air down to this height above the board, then
    // feed; retracts feed up to it, then rapid. 0 disables the optimization.
    @AppStorage("param.plungeClearance") var plungeClearance = "0.30"
    @AppStorage("param.millDirection") var millDirection = "any"    // any | climb | conventional
    @AppStorage("param.mirrorAxis") var mirrorAxis = "0.0"
    @AppStorage("param.mirrorYAxis") var mirrorYAxis = false
    @AppStorage("param.zeroStart") var zeroStart = true
    // Where X0/Y0 goes when zeroing: bottomLeft | bottomRight | topLeft |
    // topRight | center — a corner of the project as the machine sees it, on
    // each side — or custom: the point originX/originY in design (Gerber)
    // coordinates, which is the same physical spot on both sides.
    @AppStorage("param.originMode") var originMode = "bottomLeft"
    @AppStorage("param.originX") var originX = "0"
    @AppStorage("param.originY") var originY = "0"

    // Heights, extra cut and directions per settings group (FlatCAM's
    // per-tool Travel Z, Tool-change Z, Extra Cut, Milling Type and spindle
    // direction). Empty heights and directions follow Machine setup.
    @AppStorage("param.isoTravelZ") var isoTravelZ = ""
    @AppStorage("param.isoChangeZ") var isoChangeZ = ""
    @AppStorage("param.isoExtraCut") var isoExtraCut = "0"
    @AppStorage("param.isoDirection") var isoDirection = ""
    @AppStorage("param.isoSpindleDir") var isoSpindleDir = "cw"
    @AppStorage("param.drillTravelZ") var drillTravelZ = ""
    @AppStorage("param.drillChangeZ") var drillChangeZ = ""
    @AppStorage("param.drillSpindleDir") var drillSpindleDir = "cw"
    @AppStorage("param.holeMillSpindleDir") var holeMillSpindleDir = "cw"
    @AppStorage("param.cutTravelZ") var cutTravelZ = ""
    @AppStorage("param.cutChangeZ") var cutChangeZ = ""
    @AppStorage("param.cutDirection") var cutDirection = ""
    @AppStorage("param.cutSpindleDir") var cutSpindleDir = "cw"
    @AppStorage("param.maskTravelZ") var maskTravelZ = ""
    @AppStorage("param.maskChangeZ") var maskChangeZ = ""
    @AppStorage("param.maskExtraCut") var maskExtraCut = "0"
    @AppStorage("param.maskDirection") var maskDirection = ""
    @AppStorage("param.maskSpindleDir") var maskSpindleDir = "cw"
    @AppStorage("param.silkTravelZ") var silkTravelZ = ""
    @AppStorage("param.silkChangeZ") var silkChangeZ = ""
    @AppStorage("param.silkExtraCut") var silkExtraCut = "0"
    @AppStorage("param.silkDirection") var silkDirection = ""
    @AppStorage("param.silkSpindleDir") var silkSpindleDir = "cw"
    /// G0 speed of the machine, for time estimates only (mm/min).
    @AppStorage("param.rapidFeed") var rapidFeed = "2000"
    /// What turns the Gerbers into programs: "pcb2gcode" (built into the
    /// app) or "native" (NativeToolpathEngine).
    @AppStorage("param.engine") var engine = "pcb2gcode"

    // MARK: - Per drill file

    /// Every drill file's own drilling and hole-milling settings, by file
    /// name: preset key → value, for the keys it has set itself. A key a
    /// file has not set follows the drilling defaults above (the values a
    /// drill file starts from). The sidebar edits the selected drill
    /// program's file here, never the defaults, so two drill files never
    /// share a setting. Saved with the project next to its drill files,
    /// not in UserDefaults.
    @Published var drillLayerValues: [String: [String: String]] = [:]

    /// The keys a drill file sets for itself: everything in the Drilling
    /// and Hole milling groups, their heights and spindle directions.
    static let drillLayerKeys: Set<String> = {
        var keys = Set(stringFields.map(\.0).filter { $0.hasPrefix("drill") || $0.hasPrefix("holeMill") || $0 == "zDrill" })
        keys.insert("drillMillLarge")
        return keys
    }()

    /// `key` as it applies to the drill file `file` (nil: the default).
    /// Switches read "true" / "false".
    func drillValue(_ key: String, file: String?) -> String {
        if let file, let own = drillLayerValues[file]?[key] { return own }
        return value(forKey: key) ?? ""
    }

    func drillBool(_ key: String, file: String?) -> Bool {
        drillValue(key, file: file) == "true"
    }

    /// Sets `key` for the drill file `file` only; without a file (or for a
    /// key no drill file owns) the default itself.
    func setDrillValue(_ key: String, _ value: String, file: String?) {
        guard let file, Self.drillLayerKeys.contains(key) else {
            setValue(value, forKey: key)
            return
        }
        guard drillLayerValues[file]?[key] != value else { return }
        drillLayerValues[file, default: [:]][key] = value
    }

    func drillBinding(_ key: String, file: String?) -> Binding<String> {
        Binding(get: { self.drillValue(key, file: file) }, set: { self.setDrillValue(key, $0, file: file) })
    }

    func drillBoolBinding(_ key: String, file: String?) -> Binding<Bool> {
        Binding(get: { self.drillBool(key, file: file) }, set: { self.setDrillValue(key, String($0), file: file) })
    }

    /// Carries a drill file's settings over to the file replacing it.
    func renameDrillLayer(_ old: String, to new: String) {
        guard old != new, let own = drillLayerValues.removeValue(forKey: old) else { return }
        drillLayerValues[new] = own
    }

    /// A default's value under its preset key ("true" / "false" for switches).
    func value(forKey key: String) -> String? {
        if let path = Self.stringPaths[key] { return self[keyPath: path] }
        if let path = Self.boolPaths[key] { return String(self[keyPath: path]) }
        return nil
    }

    private func setValue(_ value: String, forKey key: String) {
        if let path = Self.stringPaths[key] {
            self[keyPath: path] = value
        } else if let path = Self.boolPaths[key] {
            self[keyPath: path] = (value == "true")
        }
    }

    /// The settings groups that have their own heights, extra cut and
    /// directions; the raw value prefixes their parameter keys.
    nonisolated enum MotionGroup: String, CaseIterable, Sendable {
        case iso, drill, holeMill, cut, mask, silk

        /// Hole milling runs in the drilling invocation: same heights.
        var hasHeights: Bool { self != .holeMill }
        /// Closed contours that can overrun their start.
        var hasExtraCut: Bool { self == .iso || self == .mask || self == .silk }
        var hasDirection: Bool { self == .iso || self == .cut || self == .mask || self == .silk }

        var label: String {
            switch self {
            case .iso: "Isolation"
            case .drill: "Drilling"
            case .holeMill: "Hole milling"
            case .cut: "Cutout"
            case .mask: "Mask"
            case .silk: "Silkscreen"
            }
        }

        init?(_ section: SettingsSection) {
            switch section {
            case .isolation: self = .iso
            case .drilling: self = .drill
            case .holeMill: self = .holeMill
            case .cutout: self = .cut
            case .mask: self = .mask
            case .silk: self = .silk
            case .custom, .setup: return nil
            }
        }

        init?(_ kind: LayerKind) {
            switch kind {
            case .front, .back: self = .iso
            case .outline: self = .cut
            case .drill: self = .drill
            case .millDrill: self = .holeMill
            case .maskTop, .maskBottom: self = .mask
            case .silkTop, .silkBottom: self = .silk
            case .custom, .test: return nil
            }
        }
    }

    /// The parameter behind one of a group's motion settings, if it has it.
    /// The drilling and hole-milling groups' belong to the drill file
    /// `drill` when one is given.
    func motionBinding(_ field: String, _ group: MotionGroup, drill file: String? = nil) -> Binding<String>? {
        let key = group.rawValue + field
        guard let path = Self.stringPaths[key] else { return nil }
        if let file, Self.drillLayerKeys.contains(key) { return drillBinding(key, file: file) }
        return Binding(get: { self[keyPath: path] }, set: { self[keyPath: path] = $0 })
    }

    // MARK: - Key table

    /// Every string parameter under its preset key. Presets, the preview
    /// signature and tool matching all read this one list, so a new field
    /// cannot be forgotten in one of them.
    private static let stringFields: [(String, ReferenceWritableKeyPath<ParametersStore, String>)] = [
        ("millToolID", \.millToolID), ("millShape", \.millShape), ("millDiameter", \.millDiameter),
        ("millVTip", \.millVTip), ("millVAngle", \.millVAngle), ("isolationWidth", \.isolationWidth),
        ("zWork", \.zWork), ("millInfeed", \.millInfeed), ("millOverlap", \.millOverlap),
        ("millFeed", \.millFeed), ("millVertFeed", \.millVertFeed), ("millSpeed", \.millSpeed),
        ("drillToolID", \.drillToolID), ("zDrill", \.zDrill), ("drillFeed", \.drillFeed),
        ("drillSpeed", \.drillSpeed), ("drillPeck", \.drillPeck), ("drillBitIDs", \.drillBitIDs),
        ("drillBitTolerance", \.drillBitTolerance), ("drillHoleAllowance", \.drillHoleAllowance),
        ("drillMillFrom", \.drillMillFrom),
        ("holeMillToolID", \.holeMillToolID), ("holeMillDiameter", \.holeMillDiameter),
        ("holeMillDepth", \.holeMillDepth), ("holeMillInfeed", \.holeMillInfeed),
        ("holeMillFeed", \.holeMillFeed), ("holeMillVertFeed", \.holeMillVertFeed),
        ("holeMillSpeed", \.holeMillSpeed),
        ("millDwell", \.millDwell), ("drillDwell", \.drillDwell), ("holeMillDwell", \.holeMillDwell),
        ("cutDwell", \.cutDwell), ("maskDwell", \.maskDwell), ("silkDwell", \.silkDwell),
        ("cutToolID", \.cutToolID), ("cutterDiameter", \.cutterDiameter), ("zCut", \.zCut),
        ("cutFeed", \.cutFeed), ("cutVertFeed", \.cutVertFeed), ("cutSpeed", \.cutSpeed),
        ("cutInfeed", \.cutInfeed), ("bridgeWidth", \.bridgeWidth), ("bridgeCount", \.bridgeCount),
        ("zBridge", \.zBridge),
        ("maskMode", \.maskMode), ("maskToolID", \.maskToolID), ("maskShape", \.maskShape),
        ("maskTool", \.maskTool), ("maskVTip", \.maskVTip), ("maskVAngle", \.maskVAngle),
        ("maskDepth", \.maskDepth), ("maskClearWidth", \.maskClearWidth), ("maskOverlap", \.maskOverlap),
        ("maskFeed", \.maskFeed), ("maskVertFeed", \.maskVertFeed), ("maskSpeed", \.maskSpeed),
        ("silkMode", \.silkMode), ("silkToolID", \.silkToolID), ("silkShape", \.silkShape),
        ("silkTool", \.silkTool), ("silkVTip", \.silkVTip), ("silkVAngle", \.silkVAngle),
        ("silkDepth", \.silkDepth), ("silkClearWidth", \.silkClearWidth), ("silkOverlap", \.silkOverlap),
        ("silkFeed", \.silkFeed), ("silkVertFeed", \.silkVertFeed), ("silkSpeed", \.silkSpeed),
        ("zSafe", \.zSafe), ("zChange", \.zChange), ("plungeClearance", \.plungeClearance),
        ("millDirection", \.millDirection), ("mirrorAxis", \.mirrorAxis),
        ("originMode", \.originMode), ("originX", \.originX), ("originY", \.originY),
        ("isoTravelZ", \.isoTravelZ), ("isoChangeZ", \.isoChangeZ), ("isoExtraCut", \.isoExtraCut),
        ("isoDirection", \.isoDirection), ("isoSpindleDir", \.isoSpindleDir),
        ("drillTravelZ", \.drillTravelZ), ("drillChangeZ", \.drillChangeZ), ("drillSpindleDir", \.drillSpindleDir),
        ("holeMillSpindleDir", \.holeMillSpindleDir),
        ("cutTravelZ", \.cutTravelZ), ("cutChangeZ", \.cutChangeZ), ("cutDirection", \.cutDirection),
        ("cutSpindleDir", \.cutSpindleDir),
        ("maskTravelZ", \.maskTravelZ), ("maskChangeZ", \.maskChangeZ), ("maskExtraCut", \.maskExtraCut),
        ("maskDirection", \.maskDirection), ("maskSpindleDir", \.maskSpindleDir),
        ("silkTravelZ", \.silkTravelZ), ("silkChangeZ", \.silkChangeZ), ("silkExtraCut", \.silkExtraCut),
        ("silkDirection", \.silkDirection), ("silkSpindleDir", \.silkSpindleDir),
        ("rapidFeed", \.rapidFeed), ("engine", \.engine)
    ]

    private static let boolFields: [(String, ReferenceWritableKeyPath<ParametersStore, Bool>)] = [
        ("drillMillLarge", \.drillMillLarge), ("mirrorYAxis", \.mirrorYAxis), ("zeroStart", \.zeroStart),
        ("maskClearAuto", \.maskClearAuto)
    ]

    private static let stringPaths = Dictionary(uniqueKeysWithValues: stringFields)
    private static let boolPaths = Dictionary(uniqueKeysWithValues: boolFields)

    // MARK: - Effective diameters

    /// Width a milling tool cuts at `depth`: as entered for flat bits,
    /// tip + 2·|depth|·tan(angle/2) for V-bits. Nil when a field does not parse.
    static func effectiveDiameter(shape: String, diameter: String, tip: String,
                                  angle: String, depth: String) -> Double? {
        func v(_ s: String) -> Double? { Double(s.trimmingCharacters(in: .whitespaces)) }
        guard shape == "vbit" else { return v(diameter) }
        guard let tip = v(tip), let angle = v(angle), let depth = v(depth) else { return nil }
        return tip + 2 * abs(depth) * tan(angle / 2 * .pi / 180)
    }

    var effectiveMillDiameter: Double? {
        Self.effectiveDiameter(shape: millShape, diameter: millDiameter, tip: millVTip, angle: millVAngle, depth: zWork)
    }
    var effectiveMaskTool: Double? {
        Self.effectiveDiameter(shape: maskShape, diameter: maskTool, tip: maskVTip, angle: maskVAngle, depth: maskDepth)
    }
    var effectiveSilkTool: Double? {
        Self.effectiveDiameter(shape: silkShape, diameter: silkTool, tip: silkVTip, angle: silkVAngle, depth: silkDepth)
    }

    /// The automatic mask clear width: half the widest opening plus 0.05 mm,
    /// rounded up to 0.01 mm. Nil while no mask layer has been measured.
    var automaticMaskClearWidth: String? {
        widestMaskOpening.map { Self.format(ceil(($0 / 2 + 0.05) * 100) / 100) }
    }

    /// The clear width the mask programs are made with.
    var effectiveMaskClearWidth: String {
        (maskClearAuto ? automaticMaskClearWidth : nil) ?? maskClearWidth.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Isolation passes

    /// pcb2gcode cuts n passes when the isolation width is exactly
    /// d·(1 + (n−1)·(1 − overlap)); one micron more adds a pass.
    nonisolated static func passes(width: Double, diameter: Double, overlapPercent: Double) -> Int {
        let step = diameter * (1 - overlapPercent / 100)
        guard width > diameter + 1e-6, step > 0 else { return 1 }
        return Int(((width - diameter) / step - 1e-6).rounded(.up)) + 1
    }

    /// How many passes the isolation width takes with this bit and overlap.
    var effectivePasses: Int? {
        guard let w = Double(isolationWidth.trimmingCharacters(in: .whitespaces)),
              let d = effectiveMillDiameter,
              let ov = Double(millOverlap.trimmingCharacters(in: .whitespaces)) else { return nil }
        return Self.passes(width: w, diameter: d, overlapPercent: ov)
    }

    // MARK: - Drill bits on hand

    /// The bits checked for the drill file `file` (nil: the default).
    func drillBitIDSet(file: String? = nil) -> Set<String> {
        Set(drillValue("drillBitIDs", file: file).split(separator: ",").map(String.init))
    }

    func setDrillBit(_ id: UUID, onHand: Bool, file: String? = nil) {
        var ids = drillBitIDSet(file: file)
        if onHand { ids.insert(id.uuidString) } else { ids.remove(id.uuidString) }
        setDrillValue("drillBitIDs", ids.sorted().joined(separator: ","), file: file)
    }

    /// The checked library drills that still exist, smallest first.
    func drillBitsOnHand(file: String? = nil) -> [MachineTool] {
        let ids = drillBitIDSet(file: file)
        return (library?.drills ?? []).filter { ids.contains($0.id.uuidString) }
    }

    /// --drills-available entries. Every bit carries an explicit range:
    /// without one pcb2gcode rounds EVERY hole to the nearest bit — a 3 mm
    /// mounting hole silently becomes a 1 mm one. With ranges, a hole no bit
    /// covers keeps its own size (and shows up in the Log).
    private func drillBitSpecs(ids: String, tolerance: String) -> [String] {
        let tolerance = Double(tolerance.trimmingCharacters(in: .whitespaces)) ?? 0.1
        let checked = Set(ids.split(separator: ",").map(String.init))
        return (library?.drills ?? []).filter { checked.contains($0.id.uuidString) }.map { bit in
            let range = bit.drillRange(defaultTolerance: tolerance)
            return String(format: "%@mm:-%@mm:+%@mm",
                          Self.format(bit.diameter),
                          Self.format(max(0, bit.diameter - range.lowerBound)),
                          Self.format(max(0, range.upperBound - bit.diameter)))
        }
    }

    private var drillBitSpecs: [String] {
        drillBitSpecs(ids: drillBitIDs, tolerance: drillBitTolerance)
    }

    // MARK: - Snapshot

    /// The defaults, with every drill file that has settings of its own
    /// under `drillLayers`.
    func snapshot() -> ParameterSnapshot {
        let defaults = exportValues()
        var snapshot = makeSnapshot(defaults)
        for (file, own) in drillLayerValues where !own.isEmpty {
            snapshot.drillLayers[file] = makeSnapshot(defaults.merging(own) { _, own in own })
        }
        return snapshot
    }

    /// One snapshot from a complete set of values (preset keys).
    private func makeSnapshot(_ values: [String: String]) -> ParameterSnapshot {
        func raw(_ key: String) -> String { values[key] ?? "" }
        func t(_ key: String) -> String { raw(key).trimmingCharacters(in: .whitespaces) }
        func flag(_ key: String) -> Bool { values[key] == "true" }
        func eff(_ prefix: String, _ diameterKey: String, depth: String) -> String {
            Self.effectiveDiameter(shape: raw(prefix + "Shape"), diameter: raw(diameterKey), tip: raw(prefix + "VTip"),
                                   angle: raw(prefix + "VAngle"), depth: raw(depth)).map(Self.format) ?? t(diameterKey)
        }
        var snapshot = ParameterSnapshot(
            millDiameter: eff("mill", "millDiameter", depth: "zWork"), isolationWidth: t("isolationWidth"), zWork: t("zWork"),
            millFeed: t("millFeed"), millVertFeed: t("millVertFeed"), millSpeed: t("millSpeed"),
            millOverlap: t("millOverlap"), millInfeed: t("millInfeed"),
            zDrill: t("zDrill"), drillFeed: t("drillFeed"), drillSpeed: t("drillSpeed"), drillPeck: t("drillPeck"),
            drillBits: drillBitSpecs(ids: raw("drillBitIDs"), tolerance: raw("drillBitTolerance")),
            drillHoleAllowance: t("drillHoleAllowance"), drillMillLarge: flag("drillMillLarge"), drillMillFrom: t("drillMillFrom"),
            holeMillDiameter: t("holeMillDiameter"), holeMillDepth: t("holeMillDepth"), holeMillInfeed: t("holeMillInfeed"),
            holeMillFeed: t("holeMillFeed"), holeMillVertFeed: t("holeMillVertFeed"), holeMillSpeed: t("holeMillSpeed"),
            millDwell: t("millDwell"), drillDwell: t("drillDwell"), holeMillDwell: t("holeMillDwell"),
            cutDwell: t("cutDwell"), maskDwell: t("maskDwell"), silkDwell: t("silkDwell"),
            cutterDiameter: t("cutterDiameter"), zCut: t("zCut"), cutFeed: t("cutFeed"),
            cutVertFeed: t("cutVertFeed"), cutSpeed: t("cutSpeed"), cutInfeed: t("cutInfeed"),
            bridgeWidth: t("bridgeWidth"), bridgeCount: t("bridgeCount"), zBridge: t("zBridge"),
            maskMode: raw("maskMode"),
            maskTool: eff("mask", "maskTool", depth: "maskDepth"), maskDepth: t("maskDepth"),
            maskClearWidth: (flag("maskClearAuto") ? automaticMaskClearWidth : nil) ?? t("maskClearWidth"),
            maskFeed: t("maskFeed"), maskVertFeed: t("maskVertFeed"), maskSpeed: t("maskSpeed"), maskOverlap: t("maskOverlap"),
            silkMode: raw("silkMode"),
            silkTool: eff("silk", "silkTool", depth: "silkDepth"), silkDepth: t("silkDepth"), silkClearWidth: t("silkClearWidth"),
            silkFeed: t("silkFeed"), silkVertFeed: t("silkVertFeed"), silkSpeed: t("silkSpeed"), silkOverlap: t("silkOverlap"),
            zSafe: t("zSafe"), zChange: t("zChange"), mirrorAxis: t("mirrorAxis"),
            plungeClearance: t("plungeClearance"), millDirection: raw("millDirection"),
            originMode: raw("originMode"), originX: t("originX"), originY: t("originY"),
            mirrorYAxis: flag("mirrorYAxis"), zeroStart: flag("zeroStart")
        )
        for group in MotionGroup.allCases {
            let g = group.rawValue
            if let v = values[g + "TravelZ"] { snapshot.travelZ[g] = v.trimmingCharacters(in: .whitespaces) }
            if let v = values[g + "ChangeZ"] { snapshot.changeZ[g] = v.trimmingCharacters(in: .whitespaces) }
            if let v = values[g + "ExtraCut"] { snapshot.extraCut[g] = v.trimmingCharacters(in: .whitespaces) }
            if let v = values[g + "Direction"] { snapshot.direction[g] = v }
            if let v = values[g + "SpindleDir"] { snapshot.spindleDir[g] = v }
        }
        snapshot.rapidFeed = t("rapidFeed")
        snapshot.engine = raw("engine")
        return snapshot
    }

    /// The drilling fields that must be numbers, as they apply to the drill
    /// file `file` (nil: the defaults). Heights may be empty (= Machine setup).
    private func drillNumberFields(file: String?) -> [(String, String)] {
        func v(_ key: String) -> String { drillValue(key, file: file) }
        var fields: [(String, String)] = [
            ("Drill depth", v("zDrill")), ("Drill feed", v("drillFeed")), ("Drill spindle", v("drillSpeed")),
            ("Peck depth", v("drillPeck")), ("Drill bit tolerance", v("drillBitTolerance")),
            ("Hole tolerance", v("drillHoleAllowance")), ("Drill dwell", v("drillDwell"))
        ]
        if drillBool("drillMillLarge", file: file) {
            fields += [("Mill holes from", v("drillMillFrom")), ("Hole mill diameter", v("holeMillDiameter")),
                       ("Hole mill depth", v("holeMillDepth")), ("Hole mill pass depth", v("holeMillInfeed")),
                       ("Hole mill XY feed", v("holeMillFeed")), ("Hole mill Z feed", v("holeMillVertFeed")),
                       ("Hole mill spindle", v("holeMillSpeed")), ("Hole mill dwell", v("holeMillDwell"))]
        }
        for (field, name) in [("drillTravelZ", "Drilling travel Z"), ("drillChangeZ", "Drilling tool-change Z")] {
            let height = v(field).trimmingCharacters(in: .whitespaces)
            if !height.isEmpty { fields.append((name, height)) }
        }
        return fields
    }

    /// Display name of the first field whose value does not parse as a number, or nil if all are valid.
    var validationError: String? {
        func bad(_ fields: [(String, String)]) -> String? {
            fields.first { Double($0.1.trimmingCharacters(in: .whitespaces)) == nil }?.0
        }
        var doubles: [(String, String)] = [
            ("Isolation width", isolationWidth), ("Cut depth", zWork), ("Isolation depth per pass", millInfeed),
            ("Isolation overlap", millOverlap),
            ("Isolation XY feed", millFeed), ("Isolation Z feed", millVertFeed), ("Isolation spindle", millSpeed),
            ("Cutter diameter", cutterDiameter), ("Cutout depth", zCut), ("Cutout XY feed", cutFeed),
            ("Cutout Z feed", cutVertFeed), ("Cutout spindle", cutSpeed), ("Cutout pass depth", cutInfeed),
            ("Bridge width", bridgeWidth), ("Bridge Z", zBridge),
            ("Safe Z", zSafe), ("Tool-change Z", zChange), ("Mirror axis", mirrorAxis),
            ("Plunge clearance", plungeClearance),
            ("Isolation dwell", millDwell), ("Cutout dwell", cutDwell)
        ]
        doubles += millShape == "vbit"
            ? [("V-bit tip", millVTip), ("V-bit angle", millVAngle)]
            : [("Tool diameter", millDiameter)]
        doubles += drillNumberFields(file: nil)
        // Each drill file's own values, named after the file.
        for file in drillLayerValues.keys.sorted() where !(drillLayerValues[file] ?? [:]).isEmpty {
            doubles += drillNumberFields(file: file).map { ("\(file): \($0.0)", $0.1) }
        }
        if zeroStart, originMode == "custom" { doubles += [("Origin X", originX), ("Origin Y", originY)] }
        doubles.append(("Rapid feed", rapidFeed))
        // Per-group heights may be empty (= Machine setup); extra cuts may not.
        // (The drilling group's heights are checked above, per drill file.)
        for group in MotionGroup.allCases where group != .drill {
            let label = group.label
            if group.hasHeights {
                for (field, name) in [("TravelZ", "travel Z"), ("ChangeZ", "tool-change Z")] {
                    let v = motionBinding(field, group)?.wrappedValue.trimmingCharacters(in: .whitespaces) ?? ""
                    if !v.isEmpty { doubles.append(("\(label) \(name)", v)) }
                }
            }
            if group.hasExtraCut, let v = motionBinding("ExtraCut", group)?.wrappedValue {
                doubles.append(("\(label) extra cut", v))
            }
        }
        if let name = bad(doubles) { return name }
        if Int(bridgeCount.trimmingCharacters(in: .whitespaces)) == nil { return "Bridge count" }
        if maskMode == "gcode" {
            var maskFields: [(String, String)] = [
                ("Mask etch depth", maskDepth), ("Mask clear width", effectiveMaskClearWidth), ("Mask overlap", maskOverlap),
                ("Mask XY feed", maskFeed), ("Mask Z feed", maskVertFeed), ("Mask spindle", maskSpeed),
                ("Mask dwell", maskDwell)
            ]
            maskFields += maskShape == "vbit"
                ? [("Mask V-bit tip", maskVTip), ("Mask V-bit angle", maskVAngle)]
                : [("Mask tool diameter", maskTool)]
            if let name = bad(maskFields) { return name }
        }
        if silkMode == "gcode" {
            var silkFields: [(String, String)] = [
                ("Silkscreen depth", silkDepth), ("Silkscreen clear width", silkClearWidth),
                ("Silkscreen overlap", silkOverlap),
                ("Silkscreen XY feed", silkFeed), ("Silkscreen Z feed", silkVertFeed),
                ("Silkscreen spindle", silkSpeed), ("Silkscreen dwell", silkDwell)
            ]
            silkFields += silkShape == "vbit"
                ? [("Silkscreen V-bit tip", silkVTip), ("Silkscreen V-bit angle", silkVAngle)]
                : [("Silkscreen tool diameter", silkTool)]
            if let name = bad(silkFields) { return name }
        }
        return nil
    }

    // MARK: - Presets

    /// All parameter values as a plain dictionary (preset serialization).
    func exportValues() -> [String: String] {
        var values: [String: String] = [:]
        for (key, path) in Self.stringFields { values[key] = self[keyPath: path] }
        for (key, path) in Self.boolFields { values[key] = String(self[keyPath: path]) }
        return values
    }

    /// Applies a preset dictionary to the defaults; keys absent from the
    /// dictionary keep their current value, so presets stay compatible
    /// across app versions. Drill files' own values are left alone.
    func apply(_ values: [String: String]) {
        for (key, path) in Self.stringFields {
            if let value = values[key] { self[keyPath: path] = value }
        }
        for (key, path) in Self.boolFields {
            if let value = values[key] { self[keyPath: path] = (value == "true") }
        }
    }

    /// Everything the undo history records: the defaults and every drill
    /// file's own values.
    func exportState() -> ParameterState {
        ParameterState(values: exportValues(), drillLayers: drillLayerValues)
    }

    func restoreState(_ state: ParameterState) {
        apply(state.values)
        if drillLayerValues != state.drillLayers { drillLayerValues = state.drillLayers }
    }

    /// Changes whenever any parameter changes; used for preview staleness checks.
    /// Includes the resolved drill bits, so editing a bit in the library
    /// refreshes the preview too, and every drill file's own values.
    var signature: String {
        var parts = Self.stringFields.map { self[keyPath: $0.1] }
            + Self.boolFields.map { String(self[keyPath: $0.1]) }
            + drillBitSpecs
        parts.append(automaticMaskClearWidth ?? "")
        for file in drillLayerValues.keys.sorted() {
            let own = drillLayerValues[file] ?? [:]
            guard !own.isEmpty else { continue }
            parts.append(file + "{" + own.keys.sorted().map { "\($0)=\(own[$0] ?? "")" }.joined(separator: ",") + "}")
            parts += drillBitSpecs(ids: drillValue("drillBitIDs", file: file), tolerance: drillValue("drillBitTolerance", file: file))
        }
        return parts.joined(separator: "|")
    }

    // MARK: - Tools

    /// The parameter values picking `tool` for `section` sets (preset keys).
    /// Zero feeds and speeds mean "not set" in FlatCAM databases and leave
    /// the layer's own value alone.
    func toolValues(_ tool: MachineTool, for section: SettingsSection) -> [String: String] {
        let f = Self.format
        var v: [String: String] = [:]
        func positive(_ key: String, _ value: Double) { if value > 0 { v[key] = f(value) } }
        // FlatCAM's "dwell off" is 0 here; it leaves the layer's own dwell alone.
        func dwell(_ key: String) { positive(key, tool.dwell) }
        func shapeKeys(prefix: String, diameterKey: String) {
            if tool.shape == .vBit {
                v[prefix + "Shape"] = "vbit"
                v[prefix + "VTip"] = f(tool.tipDiameter)
                v[prefix + "VAngle"] = f(tool.tipAngle)
            } else {
                v[prefix + "Shape"] = "flat"
                v[diameterKey] = f(tool.diameter)
            }
        }
        if let group = MotionGroup(section) {
            let g = group.rawValue
            if group.hasHeights {
                v[g + "TravelZ"] = tool.travelZ > 0 ? f(tool.travelZ) : ""
                v[g + "ChangeZ"] = tool.toolChangeZ > 0 ? f(tool.toolChangeZ) : ""
            }
            if group.hasExtraCut { v[g + "ExtraCut"] = f(max(0, tool.extraCut)) }
            if group.hasDirection { v[g + "Direction"] = tool.direction == .machine ? "" : tool.direction.rawValue }
            v[g + "SpindleDir"] = tool.spindleCCW ? "ccw" : "cw"
        }
        switch section {
        case .isolation:
            v["millToolID"] = tool.id.uuidString
            shapeKeys(prefix: "mill", diameterKey: "millDiameter")
            v["zWork"] = f(tool.cutDepth)
            v["millInfeed"] = f(tool.depthPerPass)
            positive("millOverlap", tool.overlap)
            positive("millFeed", tool.feedXY)
            positive("millVertFeed", tool.feedZ)
            positive("millSpeed", tool.spindle)
            dwell("millDwell")
        case .drilling:
            v["drillToolID"] = tool.id.uuidString
            v["zDrill"] = f(tool.cutDepth)
            v["drillPeck"] = f(tool.depthPerPass)
            positive("drillFeed", tool.feedZ)
            positive("drillSpeed", tool.spindle)
            dwell("drillDwell")
        case .holeMill:
            v["holeMillToolID"] = tool.id.uuidString
            v["holeMillDiameter"] = f(tool.diameter)
            v["holeMillDepth"] = f(tool.cutDepth)
            v["holeMillInfeed"] = f(tool.depthPerPass > 0 ? tool.depthPerPass : abs(tool.cutDepth))
            positive("holeMillFeed", tool.feedXY)
            positive("holeMillVertFeed", tool.feedZ)
            positive("holeMillSpeed", tool.spindle)
            dwell("holeMillDwell")
        case .cutout:
            v["cutToolID"] = tool.id.uuidString
            v["cutterDiameter"] = f(tool.shape == .vBit ? tool.listDiameter : tool.diameter)
            v["zCut"] = f(tool.cutDepth)
            v["cutInfeed"] = f(tool.depthPerPass > 0 ? tool.depthPerPass : abs(tool.cutDepth))
            positive("cutFeed", tool.feedXY)
            positive("cutVertFeed", tool.feedZ)
            positive("cutSpeed", tool.spindle)
            dwell("cutDwell")
        case .mask:
            v["maskToolID"] = tool.id.uuidString
            shapeKeys(prefix: "mask", diameterKey: "maskTool")
            v["maskDepth"] = f(tool.cutDepth)
            positive("maskOverlap", tool.overlap)
            positive("maskFeed", tool.feedXY)
            positive("maskVertFeed", tool.feedZ)
            positive("maskSpeed", tool.spindle)
            dwell("maskDwell")
        case .silk:
            v["silkToolID"] = tool.id.uuidString
            shapeKeys(prefix: "silk", diameterKey: "silkTool")
            v["silkDepth"] = f(tool.cutDepth)
            positive("silkOverlap", tool.overlap)
            positive("silkFeed", tool.feedXY)
            positive("silkVertFeed", tool.feedZ)
            positive("silkSpeed", tool.spindle)
            dwell("silkDwell")
        case .custom, .setup:
            break   // drawn layers copy tool data into the layer itself
        }
        return v
    }

    /// Copies a library tool's cutting data into a settings group — for the
    /// drilling and hole-milling groups, into the drill file `drill` when
    /// one is given.
    func applyTool(_ tool: MachineTool, to section: SettingsSection, drill file: String? = nil) {
        let values = toolValues(tool, for: section)
        guard let file, section.isDrilling else { return apply(values) }
        for (key, value) in values { setDrillValue(key, value, file: file) }
    }

    /// Whether the group's fields still hold exactly what `tool` would set.
    func matches(_ tool: MachineTool, for section: SettingsSection, drill file: String? = nil) -> Bool {
        let file = section.isDrilling ? file : nil
        return toolValues(tool, for: section).allSatisfy { key, value in
            let now = drillValue(key, file: file)
            if let a = Double(now.trimmingCharacters(in: .whitespaces)), let b = Double(value) {
                return abs(a - b) < 1e-9
            }
            return now == value
        }
    }

    /// The preset key recording which library tool a group was set from.
    private static func toolIDKey(_ section: SettingsSection) -> String? {
        switch section {
        case .isolation: "millToolID"
        case .drilling: "drillToolID"
        case .holeMill: "holeMillToolID"
        case .cutout: "cutToolID"
        case .mask: "maskToolID"
        case .silk: "silkToolID"
        case .custom, .setup: nil
        }
    }

    /// The library tool a group was set from (drilling groups: for the drill
    /// file `drill`, or the defaults).
    func toolID(for section: SettingsSection, drill file: String? = nil) -> String {
        guard let key = Self.toolIDKey(section) else { return "" }
        return drillValue(key, file: section.isDrilling ? file : nil)
    }

    func clearToolID(for section: SettingsSection, drill file: String? = nil) {
        guard let key = Self.toolIDKey(section) else { return }
        setDrillValue(key, "", file: section.isDrilling ? file : nil)
    }

    /// Machine setup's Safe Z / Tool-change Z, shown where a group leaves them empty.
    func machineHeight(_ field: String) -> String {
        field == "TravelZ" ? zSafe : zChange
    }

    /// Shortest decimal text for a millimetre value (at most 5 places).
    nonisolated static func format(_ value: Double) -> String {
        var text = String(format: "%.5f", value)
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }
}
