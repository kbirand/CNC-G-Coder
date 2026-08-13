import SwiftUI
import Combine

/// A plain value copy of all machining parameters, safe to hand to background work.
nonisolated struct ParameterSnapshot: Sendable {
    var millDiameter, isolationWidth, zWork, millFeed, millVertFeed, millSpeed: String
    var zDrill, drillFeed, drillSpeed: String
    var cutterDiameter, zCut, cutFeed, cutVertFeed, cutSpeed, cutInfeed: String
    var bridgeWidth, bridgeCount, zBridge: String
    var maskMode: String                        // "off" | "gcode" | "svg"
    var maskTool, maskDepth, maskClearWidth, maskFeed, maskVertFeed, maskSpeed: String
    var zSafe, zChange, mirrorAxis, plungeClearance: String
    var mirrorYAxis, zeroStart: Bool
}

/// All user-editable machining parameters, persisted across launches.
@MainActor
final class ParametersStore: ObservableObject {
    // Copper isolation
    @AppStorage("param.millDiameter") var millDiameter = "0.10"
    @AppStorage("param.isolationWidth") var isolationWidth = "0.20"
    @AppStorage("param.zWork") var zWork = "-0.06"
    @AppStorage("param.millFeed") var millFeed = "240"
    @AppStorage("param.millVertFeed") var millVertFeed = "60"
    @AppStorage("param.millSpeed") var millSpeed = "12000"

    // Drilling
    @AppStorage("param.zDrill") var zDrill = "-1.80"
    @AppStorage("param.drillFeed") var drillFeed = "80"
    @AppStorage("param.drillSpeed") var drillSpeed = "12000"

    // Board cutout
    @AppStorage("param.cutterDiameter") var cutterDiameter = "1.00"
    @AppStorage("param.zCut") var zCut = "-1.80"
    @AppStorage("param.cutFeed") var cutFeed = "120"
    @AppStorage("param.cutVertFeed") var cutVertFeed = "60"
    @AppStorage("param.cutSpeed") var cutSpeed = "12000"
    @AppStorage("param.cutInfeed") var cutInfeed = "0.40"
    @AppStorage("param.bridgeWidth") var bridgeWidth = "2.00"
    @AppStorage("param.bridgeCount") var bridgeCount = "4"
    @AppStorage("param.zBridge") var zBridge = "-0.80"

    // Solder mask (openings are etched away after painting/curing the mask)
    @AppStorage("param.maskMode") var maskMode = "gcode"   // off | gcode | svg
    @AppStorage("param.maskTool") var maskTool = "0.80"
    @AppStorage("param.maskDepth") var maskDepth = "-0.10"
    // How far inward each opening is cleared. Must be at least half the widest
    // mask opening. Generation time explodes with larger values, so keep small.
    @AppStorage("param.maskClearWidth") var maskClearWidth = "1.2"
    @AppStorage("param.maskFeed") var maskFeed = "120"
    @AppStorage("param.maskVertFeed") var maskVertFeed = "60"
    @AppStorage("param.maskSpeed") var maskSpeed = "12000"

    // Alignment / safety
    @AppStorage("param.zSafe") var zSafe = "3.0"
    @AppStorage("param.zChange") var zChange = "10.0"
    // Plunges rapid through the air down to this height above the board, then
    // feed; retracts feed up to it, then rapid. 0 disables the optimization.
    @AppStorage("param.plungeClearance") var plungeClearance = "0.30"
    @AppStorage("param.mirrorAxis") var mirrorAxis = "0.0"
    @AppStorage("param.mirrorYAxis") var mirrorYAxis = false
    @AppStorage("param.zeroStart") var zeroStart = true

    func snapshot() -> ParameterSnapshot {
        func t(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
        return ParameterSnapshot(
            millDiameter: t(millDiameter), isolationWidth: t(isolationWidth), zWork: t(zWork),
            millFeed: t(millFeed), millVertFeed: t(millVertFeed), millSpeed: t(millSpeed),
            zDrill: t(zDrill), drillFeed: t(drillFeed), drillSpeed: t(drillSpeed),
            cutterDiameter: t(cutterDiameter), zCut: t(zCut), cutFeed: t(cutFeed),
            cutVertFeed: t(cutVertFeed), cutSpeed: t(cutSpeed), cutInfeed: t(cutInfeed),
            bridgeWidth: t(bridgeWidth), bridgeCount: t(bridgeCount), zBridge: t(zBridge),
            maskMode: maskMode,
            maskTool: t(maskTool), maskDepth: t(maskDepth), maskClearWidth: t(maskClearWidth),
            maskFeed: t(maskFeed), maskVertFeed: t(maskVertFeed), maskSpeed: t(maskSpeed),
            zSafe: t(zSafe), zChange: t(zChange), mirrorAxis: t(mirrorAxis),
            plungeClearance: t(plungeClearance),
            mirrorYAxis: mirrorYAxis, zeroStart: zeroStart
        )
    }

    /// Display name of the first field whose value does not parse as a number, or nil if all are valid.
    var validationError: String? {
        let doubles: [(String, String)] = [
            ("Tool diameter", millDiameter), ("Isolation width", isolationWidth), ("Cut depth", zWork),
            ("Isolation XY feed", millFeed), ("Isolation Z feed", millVertFeed), ("Isolation spindle", millSpeed),
            ("Drill depth", zDrill), ("Drill feed", drillFeed), ("Drill spindle", drillSpeed),
            ("Cutter diameter", cutterDiameter), ("Cutout depth", zCut), ("Cutout XY feed", cutFeed),
            ("Cutout Z feed", cutVertFeed), ("Cutout spindle", cutSpeed), ("Cutout pass depth", cutInfeed),
            ("Bridge width", bridgeWidth), ("Bridge Z", zBridge),
            ("Safe Z", zSafe), ("Tool-change Z", zChange), ("Mirror axis", mirrorAxis),
            ("Plunge clearance", plungeClearance)
        ]
        for (name, value) in doubles where Double(value.trimmingCharacters(in: .whitespaces)) == nil {
            return name
        }
        if Int(bridgeCount.trimmingCharacters(in: .whitespaces)) == nil { return "Bridge count" }
        if maskMode == "gcode" {
            let maskFields: [(String, String)] = [
                ("Mask tool diameter", maskTool), ("Mask etch depth", maskDepth),
                ("Mask clear width", maskClearWidth),
                ("Mask XY feed", maskFeed), ("Mask Z feed", maskVertFeed), ("Mask spindle", maskSpeed)
            ]
            for (name, value) in maskFields where Double(value.trimmingCharacters(in: .whitespaces)) == nil {
                return name
            }
        }
        return nil
    }

    /// All parameter values as a plain dictionary (preset serialization).
    func exportValues() -> [String: String] {
        [
            "millDiameter": millDiameter, "isolationWidth": isolationWidth, "zWork": zWork,
            "millFeed": millFeed, "millVertFeed": millVertFeed, "millSpeed": millSpeed,
            "zDrill": zDrill, "drillFeed": drillFeed, "drillSpeed": drillSpeed,
            "cutterDiameter": cutterDiameter, "zCut": zCut, "cutFeed": cutFeed,
            "cutVertFeed": cutVertFeed, "cutSpeed": cutSpeed, "cutInfeed": cutInfeed,
            "bridgeWidth": bridgeWidth, "bridgeCount": bridgeCount, "zBridge": zBridge,
            "maskMode": maskMode, "maskTool": maskTool, "maskDepth": maskDepth,
            "maskClearWidth": maskClearWidth, "maskFeed": maskFeed,
            "maskVertFeed": maskVertFeed, "maskSpeed": maskSpeed,
            "zSafe": zSafe, "zChange": zChange, "mirrorAxis": mirrorAxis,
            "plungeClearance": plungeClearance,
            "mirrorYAxis": String(mirrorYAxis), "zeroStart": String(zeroStart)
        ]
    }

    /// Applies a preset dictionary; keys absent from the dictionary keep their
    /// current value, so presets stay compatible across app versions.
    func apply(_ values: [String: String]) {
        func set(_ key: String, _ assign: (String) -> Void) {
            if let value = values[key] { assign(value) }
        }
        set("millDiameter") { millDiameter = $0 }
        set("isolationWidth") { isolationWidth = $0 }
        set("zWork") { zWork = $0 }
        set("millFeed") { millFeed = $0 }
        set("millVertFeed") { millVertFeed = $0 }
        set("millSpeed") { millSpeed = $0 }
        set("zDrill") { zDrill = $0 }
        set("drillFeed") { drillFeed = $0 }
        set("drillSpeed") { drillSpeed = $0 }
        set("cutterDiameter") { cutterDiameter = $0 }
        set("zCut") { zCut = $0 }
        set("cutFeed") { cutFeed = $0 }
        set("cutVertFeed") { cutVertFeed = $0 }
        set("cutSpeed") { cutSpeed = $0 }
        set("cutInfeed") { cutInfeed = $0 }
        set("bridgeWidth") { bridgeWidth = $0 }
        set("bridgeCount") { bridgeCount = $0 }
        set("zBridge") { zBridge = $0 }
        set("maskMode") { maskMode = $0 }
        set("maskTool") { maskTool = $0 }
        set("maskDepth") { maskDepth = $0 }
        set("maskClearWidth") { maskClearWidth = $0 }
        set("maskFeed") { maskFeed = $0 }
        set("maskVertFeed") { maskVertFeed = $0 }
        set("maskSpeed") { maskSpeed = $0 }
        set("zSafe") { zSafe = $0 }
        set("zChange") { zChange = $0 }
        set("mirrorAxis") { mirrorAxis = $0 }
        set("plungeClearance") { plungeClearance = $0 }
        set("mirrorYAxis") { mirrorYAxis = ($0 == "true") }
        set("zeroStart") { zeroStart = ($0 == "true") }
    }

    /// Changes whenever any parameter changes; used for preview staleness checks.
    var signature: String {
        [millDiameter, isolationWidth, zWork, millFeed, millVertFeed, millSpeed,
         zDrill, drillFeed, drillSpeed,
         cutterDiameter, zCut, cutFeed, cutVertFeed, cutSpeed, cutInfeed,
         bridgeWidth, bridgeCount, zBridge,
         maskMode, maskTool, maskDepth, maskClearWidth, maskFeed, maskVertFeed, maskSpeed,
         zSafe, zChange, mirrorAxis, plungeClearance,
         String(mirrorYAxis), String(zeroStart)]
            .joined(separator: "|")
    }
}
