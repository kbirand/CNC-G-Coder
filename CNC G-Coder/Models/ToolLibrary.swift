import Foundation
import Combine

/// One cutter in the tool library, with the cutting data that goes with it.
///
/// Modeled on FlatCAM's Tools Database: a tool is a physical bit plus the
/// depths, feeds and speed it is run at. Picking a tool for a layer COPIES
/// these values into that layer's parameters (as FlatCAM copies DB data into
/// an object's tool table) — the layer can then be tuned without touching the
/// library, and the sidebar shows when it no longer matches the tool.
///
/// Units: mm, mm/min, rpm, percent — like every stored parameter.
nonisolated struct MachineTool: Codable, Identifiable, Hashable, Sendable {

    enum Shape: String, Codable, CaseIterable, Identifiable, Sendable {
        case flat, ball, vBit
        var id: String { rawValue }
        var title: String {
            switch self {
            case .flat: String(localized: "Flat end mill / drill")
            case .ball: String(localized: "Ball nose")
            case .vBit: String(localized: "V-bit")
            }
        }
    }

    /// Climb or conventional milling (FlatCAM's "Milling Type").
    enum Direction: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Whatever Machine setup says.
        case machine, any, climb, conventional
        var id: String { rawValue }
        var title: String {
            switch self {
            case .machine: String(localized: "Machine default")
            case .any: String(localized: "Either (shortest path)")
            case .climb: String(localized: "Climb")
            case .conventional: String(localized: "Conventional")
            }
        }
    }

    /// Which layers the tool is offered for (FlatCAM's "Tool Target").
    enum Use: String, Codable, CaseIterable, Identifiable, Sendable {
        case general, isolation, drilling, cutout, mask, silk
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: String(localized: "General")
            case .isolation: String(localized: "Isolation")
            case .drilling: String(localized: "Drilling")
            case .cutout: String(localized: "Cutout")
            case .mask: String(localized: "Mask etch")
            case .silk: String(localized: "Silkscreen")
            }
        }
    }

    var id = UUID()
    var name: String
    var use: Use = .general
    var shape: Shape = .flat
    /// Cutting diameter of flat and ball tools. V-bits derive theirs from
    /// tip, angle and cut depth instead.
    var diameter: Double = 1.0
    var tipDiameter: Double = 0.1
    /// Included angle of a V-bit (a "30°" bit), degrees.
    var tipAngle: Double = 30
    /// Drills: the hole diameters this bit may drill. 0/0 = the layer's
    /// default tolerance around the bit's own diameter.
    var toleranceMin: Double = 0
    var toleranceMax: Double = 0
    var cutDepth: Double = -0.1
    /// Depth removed per pass (drills: per peck). 0 = full depth at once.
    var depthPerPass: Double = 0
    var feedXY: Double = 200
    var feedZ: Double = 60
    var spindle: Double = 12000
    /// Overlap between adjacent clearing passes, percent.
    var overlap: Double = 50
    /// Seconds to wait after the spindle starts; 0 = not set.
    var dwell: Double = 0
    /// Height for moves between cuts (FlatCAM's Travel Z); 0 = Machine setup's Safe Z.
    var travelZ: Double = 0
    /// Height for tool changes and the end of the program (FlatCAM's
    /// Tool-change Z / End Z); 0 = Machine setup's.
    var toolChangeZ: Double = 0
    /// Closed cuts run on this far past their start, so no sliver is left
    /// where the loop meets itself (FlatCAM's Extra Cut); 0 = off.
    var extraCut: Double = 0
    var direction: Direction = .machine
    /// M4 instead of M3 (FlatCAM's spindle direction CCW).
    var spindleCCW = false
    var notes: String = ""

    init(name: String) { self.name = name }

    /// The width this tool actually cuts at `depth`. A V-bit widens with
    /// depth: tip + 2·|depth|·tan(angle/2) — the same rule FlatCAM uses.
    func effectiveDiameter(atDepth depth: Double) -> Double {
        switch shape {
        case .vBit:
            let halfAngle = tipAngle / 2 * .pi / 180
            return tipDiameter + 2 * abs(depth) * tan(halfAngle)
        case .flat, .ball:
            return diameter
        }
    }

    /// The nominal diameter shown in lists: V-bits by their width at cut depth.
    var listDiameter: Double { effectiveDiameter(atDepth: cutDepth) }

    /// The hole range this drill covers, given the layer's default tolerance.
    func drillRange(defaultTolerance: Double) -> ClosedRange<Double> {
        if toleranceMin > 0 || toleranceMax > 0, toleranceMax >= toleranceMin {
            return toleranceMin...toleranceMax
        }
        return max(0, diameter - defaultTolerance)...(diameter + defaultTolerance)
    }

    // Decoded field by field so library files survive fields added later.
    private enum CodingKeys: String, CodingKey {
        case id, name, use, shape, diameter, tipDiameter, tipAngle, toleranceMin, toleranceMax
        case cutDepth, depthPerPass, feedXY, feedZ, spindle, overlap, dwell, notes
        case travelZ, toolChangeZ, extraCut, direction, spindleCCW
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = MachineTool(name: "")
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Unnamed tool"
        use = (try? c.decodeIfPresent(Use.self, forKey: .use)) ?? base.use
        shape = (try? c.decodeIfPresent(Shape.self, forKey: .shape)) ?? base.shape
        func d(_ key: CodingKeys, _ fallback: Double) -> Double {
            (try? c.decodeIfPresent(Double.self, forKey: key)) ?? fallback
        }
        diameter = d(.diameter, base.diameter)
        tipDiameter = d(.tipDiameter, base.tipDiameter)
        tipAngle = d(.tipAngle, base.tipAngle)
        toleranceMin = d(.toleranceMin, base.toleranceMin)
        toleranceMax = d(.toleranceMax, base.toleranceMax)
        cutDepth = d(.cutDepth, base.cutDepth)
        depthPerPass = d(.depthPerPass, base.depthPerPass)
        feedXY = d(.feedXY, base.feedXY)
        feedZ = d(.feedZ, base.feedZ)
        spindle = d(.spindle, base.spindle)
        overlap = d(.overlap, base.overlap)
        dwell = d(.dwell, base.dwell)
        travelZ = d(.travelZ, base.travelZ)
        toolChangeZ = d(.toolChangeZ, base.toolChangeZ)
        extraCut = d(.extraCut, base.extraCut)
        direction = (try? c.decodeIfPresent(Direction.self, forKey: .direction)) ?? base.direction
        spindleCCW = (try? c.decodeIfPresent(Bool.self, forKey: .spindleCCW)) ?? base.spindleCCW
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }
}

extension MachineTool.Use {
    /// Tools offered in a settings group's picker: the group's own tools,
    /// general-purpose ones, and — for mask and legend — isolation bits too,
    /// since the same fine V-bits do all three jobs.
    func fits(_ section: SettingsSection) -> Bool {
        if self == .general { return section != .setup }
        switch section {
        case .isolation: return self == .isolation
        case .drilling: return self == .drilling
        case .holeMill: return self == .cutout
        case .cutout: return self == .cutout
        case .mask: return self == .mask || self == .isolation
        case .silk: return self == .silk || self == .isolation
        case .custom: return self != .drilling   // any milling bit can follow a drawing
        case .setup: return false
        }
    }
}

/// The user's tool library, persisted as JSON in Application Support.
@MainActor
final class ToolLibrary: ObservableObject {
    @Published var tools: [MachineTool] = [] {
        didSet { save() }
    }
    /// Last load/save/import problem, for the library window.
    @Published var lastError: String?

    private let fileURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CNC G-Coder", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("ToolLibrary.json")
        load()
    }

    func tool(id: String) -> MachineTool? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return tools.first { $0.id == uuid }
    }

    func tools(for section: SettingsSection) -> [MachineTool] {
        tools.filter { $0.use.fits(section) }
            .sorted { ($0.use.rawValue, $0.listDiameter, $0.name) < ($1.use.rawValue, $1.listDiameter, $1.name) }
    }

    var drills: [MachineTool] {
        tools.filter { $0.use == .drilling }.sorted { $0.diameter < $1.diameter }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            tools = Self.starterTools
            return
        }
        do {
            tools = try JSONDecoder().decode([MachineTool].self, from: data)
        } catch {
            lastError = "Could not read the tool library: \(error.localizedDescription)"
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(tools).write(to: fileURL, options: .atomic)
        } catch {
            lastError = "Could not save the tool library: \(error.localizedDescription)"
        }
    }

    /// A small library matching the app's default parameters, so the picker
    /// is useful before anything is imported.
    private static var starterTools: [MachineTool] {
        var vbit = MachineTool(name: "V-bit 30° · 0.1 mm tip")
        vbit.use = .isolation; vbit.shape = .vBit
        vbit.tipDiameter = 0.1; vbit.tipAngle = 30
        vbit.cutDepth = -0.06; vbit.feedXY = 240; vbit.feedZ = 60; vbit.overlap = 50

        func drill(_ dia: Double) -> MachineTool {
            var t = MachineTool(name: String(format: "Drill %.1f mm", dia))
            t.use = .drilling; t.diameter = dia
            t.cutDepth = -1.8; t.feedXY = 80; t.feedZ = 80
            return t
        }

        var cutter = MachineTool(name: "End mill 1.0 mm")
        cutter.use = .cutout; cutter.diameter = 1.0
        cutter.cutDepth = -1.8; cutter.depthPerPass = 0.4; cutter.feedXY = 120; cutter.feedZ = 60

        var mask = MachineTool(name: "End mill 0.8 mm — mask")
        mask.use = .mask; mask.diameter = 0.8
        mask.cutDepth = -0.1; mask.feedXY = 120; mask.feedZ = 60; mask.overlap = 40

        return [vbit, drill(0.8), drill(1.0), cutter, mask]
    }

    // MARK: - Exchange with other installs

    /// A tool library export (.json) for other computers. Tools keep their
    /// IDs, so a project's "bits on hand" still match after importing it.
    nonisolated struct ExchangeFile: Codable, Sendable {
        var format = "cnc-gcoder-tool-library"
        var version = 1
        var exported = Date()
        var tools: [MachineTool]
    }

    func exportLibrary(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(ExchangeFile(tools: tools)).write(to: url, options: .atomic)
    }

    /// Imports a tool library export, the library file itself, or a FlatCAM
    /// Tools Database — whichever the file turns out to be. Tools already in
    /// the library (same ID, else same name) are updated, the rest added.
    func importTools(from url: URL) throws -> (added: Int, updated: Int, source: String) {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let incoming: [MachineTool]
        let source: String
        if let file = try? decoder.decode(ExchangeFile.self, from: data), file.format == "cnc-gcoder-tool-library" {
            incoming = file.tools
            source = "CNC G-Coder tool library"
        } else if let list = try? decoder.decode([MachineTool].self, from: data), !list.isEmpty {
            incoming = list
            source = "CNC G-Coder tool library"
        } else {
            incoming = try Self.parseFlatCAM(data)
            source = "FlatCAM Tools Database"
        }
        guard !incoming.isEmpty else { throw CocoaError(.fileReadCorruptFile) }

        var merged = tools
        var added = 0, updated = 0
        for var tool in incoming {
            if let index = merged.firstIndex(where: { $0.id == tool.id })
                ?? merged.firstIndex(where: { $0.name == tool.name }) {
                tool.id = merged[index].id
                merged[index] = tool
                updated += 1
            } else {
                merged.append(tool)
                added += 1
            }
        }
        tools = merged
        return (added, updated, source)
    }

    // MARK: - FlatCAM import

    /// Merges a FlatCAM Tools Database export (the JSON .TXT from
    /// Tools Database → Export). Tools whose name already exists are updated
    /// in place, so re-importing an edited database does not duplicate.
    /// Returns how many tools were read.
    @discardableResult
    func importFlatCAM(from url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        let imported = try Self.parseFlatCAM(data)
        var merged = tools
        for var tool in imported {
            if let index = merged.firstIndex(where: { $0.name == tool.name }) {
                tool.id = merged[index].id
                merged[index] = tool
            } else {
                merged.append(tool)
            }
        }
        tools = merged
        return imported.count
    }

    nonisolated static func parseFlatCAM(_ data: Data) throws -> [MachineTool] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // Keys are "1", "2", … — keep the database order.
        let entries = root.sorted { (Int($0.key) ?? .max) < (Int($1.key) ?? .max) }
        return entries.compactMap { _, value in
            guard let entry = value as? [String: Any] else { return nil }
            return tool(fromFlatCAM: entry)
        }
    }

    nonisolated private static func tool(fromFlatCAM entry: [String: Any]) -> MachineTool? {
        let data = entry["data"] as? [String: Any] ?? [:]
        func num(_ dict: [String: Any], _ key: String) -> Double? {
            switch dict[key] {
            case let n as NSNumber: n.doubleValue
            case let s as String: Double(s)
            default: nil
            }
        }
        func bool(_ key: String) -> Bool { (data[key] as? NSNumber)?.boolValue ?? false }

        var tool = MachineTool(name: entry["name"] as? String ?? "FlatCAM tool")
        tool.diameter = num(entry, "tooldia") ?? tool.diameter

        switch (entry["tool_type"] as? String ?? "").uppercased() {
        case "V":
            tool.shape = .vBit
            tool.tipDiameter = num(data, "vtipdia") ?? tool.tipDiameter
            tool.tipAngle = num(data, "vtipangle") ?? tool.tipAngle
        case "B":
            tool.shape = .ball
        default:
            tool.shape = .flat
        }

        // tool_target: 0 General, 1 Milling, 2 Drilling, 3 Isolation, 4 Paint,
        // 5 NCC, 6 Cutout. Older databases store the translated name instead.
        let target: Int = {
            if let n = data["tool_target"] as? NSNumber { return n.intValue }
            switch (data["tool_target"] as? String ?? "").lowercased() {
            case "milling": return 1
            case "drilling": return 2
            case "isolation": return 3
            case "cutout": return 6
            default: return 0
            }
        }()
        tool.use = switch target {
        case 1, 6: .cutout
        case 2: .drilling
        case 3: .isolation
        default: .general
        }

        tool.toleranceMin = num(data, "tol_min") ?? 0
        tool.toleranceMax = num(data, "tol_max") ?? 0

        if tool.use == .drilling {
            tool.cutDepth = num(data, "tools_drill_cutz") ?? num(data, "cutz") ?? tool.cutDepth
            tool.depthPerPass = bool("tools_drill_multidepth") ? (num(data, "tools_drill_depthperpass") ?? 0) : 0
            tool.feedZ = num(data, "tools_drill_feedrate_z") ?? tool.feedZ
            tool.feedXY = tool.feedZ
            let drillSpeed = num(data, "tools_drill_spindlespeed") ?? 0
            tool.spindle = drillSpeed > 0 ? drillSpeed : (num(data, "spindlespeed") ?? 0)
            tool.dwell = bool("tools_drill_dwell") ? (num(data, "tools_drill_dwelltime") ?? 0) : 0
        } else {
            tool.cutDepth = num(data, "cutz") ?? tool.cutDepth
            tool.depthPerPass = bool("multidepth") ? (num(data, "depthperpass") ?? 0) : 0
            tool.feedXY = num(data, "feedrate") ?? tool.feedXY
            tool.feedZ = num(data, "feedrate_z") ?? tool.feedZ
            tool.spindle = num(data, "spindlespeed") ?? 0
            tool.overlap = num(data, "tools_iso_overlap") ?? tool.overlap
            tool.dwell = bool("dwell") ? (num(data, "dwelltime") ?? 0) : 0
        }

        // Heights: pcb2gcode ends every program at the tool-change height, so
        // FlatCAM's tool-change Z (when tool changes are on) or End Z is it.
        tool.travelZ = num(data, tool.use == .drilling ? "tools_drill_travelz" : "travelz") ?? num(data, "travelz") ?? 0
        tool.toolChangeZ = (bool("toolchange") ? num(data, "toolchangez") : nil) ?? num(data, "endz") ?? 0
        if tool.use != .drilling {
            tool.extraCut = bool("extracut") ? (num(data, "extracut_length") ?? 0) : 0
            switch (data["tools_iso_milling_type"] as? String ?? "").lowercased() {
            case "cl": tool.direction = .climb
            case "cv": tool.direction = .conventional
            default: break
            }
        }
        tool.spindleCCW = (data["spindledir"] as? String ?? "").uppercased() == "CCW"

        var notes = ["Imported from FlatCAM"]
        if let offset = entry["offset"] as? String { notes.append("offset \(offset)") }
        if let type = entry["type"] as? String { notes.append("type \(type)") }
        if let shape = entry["tool_type"] as? String { notes.append("shape \(shape)") }
        tool.notes = notes.joined(separator: " · ")
        return tool
    }
}
