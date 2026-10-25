import Foundation
import SQLite3

/// Reads Makera Studio's tool library — the SQLite file the app ships
/// (`/Applications/MakeraStudio.app/Contents/MacOS/makera_library.db`) and
/// the copy it keeps per user under Application Support, which also holds
/// the tools, groups and materials the user added in Studio.
///
/// It is the richest source of Makera cutting data: every bit carries one
/// row per stock (PCB, Copper, Brass, 6061 and 7075 Aluminum, Delrin,
/// Acrylic, …), with the shank, cutting diameter, tip, angle, flute length
/// and Makera's default tool number, filed in Studio's own group tree
/// ("Flat End · Corn Bits").
nonisolated enum MakeraLibraryImport {

    struct Failure: LocalizedError {
        var reason: String
        var errorDescription: String? { reason }
    }

    /// The copy inside the app bundle (read-only, Makera's own data).
    static let bundledURL = URL(fileURLWithPath: "/Applications/MakeraStudio.app/Contents/MacOS/makera_library.db")

    /// The user's copy (Makera's data plus their own additions). Under the
    /// App Sandbox this file can only be read once the user has picked it.
    static var userURL: URL {
        let home = String(cString: getpwuid(getuid()).pointee.pw_dir)
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/MakeraStudio/makera_library.db")
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: bundledURL.path) }

    /// Whether the data is a SQLite file (the magic header).
    static func isDatabase(_ data: Data) -> Bool {
        data.starts(with: Array("SQLite format 3\0".utf8))
    }

    // MARK: - Reading

    private struct Row {
        var id: String
        var groupID: String
        var name: String
        var number: Int
        var category: Int
        var shank: Double?
        var diameter: Double?
        var tip: Double?
        var angle: Double?
        var halfAngle: Double?
        var drill: Double?
        var flute: Double?
    }

    private struct Property {
        var material: String
        var rpm: Double
        var feed: Double
        var plunge: Double
        var stepDown: Double
        var stepOverPercent: Double
    }

    /// The tools of the library at `url`.
    static func parse(url: URL) throws -> [MachineTool] {
        var handle: OpaquePointer?
        // `immutable=1`: no locks, no journal — fine for a read of a file
        // another app may have open, and required inside the read-only bundle.
        let uri = "file:" + url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! + "?immutable=1"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(handle)
            throw Failure(reason: "Not a readable Makera Studio library (\(message)).")
        }
        defer { sqlite3_close(db) }

        let tables = Set(try query(db, "select name from sqlite_master where type = 'table'").map { $0[0] as? String ?? "" })
        guard tables.contains("t_MakeraCutterList"), tables.contains("t_MakeraCutterProperties") else {
            throw Failure(reason: "The database has no Makera tool tables.")
        }

        // Groups: id → (name, parent), from Makera's tree and the user's.
        var groups: [String: (name: String, parent: String)] = [:]
        for table in ["t_MakeraCutterGroup", "t_CustomerCutterGroup"] where tables.contains(table) {
            for row in try query(db, "select cutterGroupid, name, parentId from \(table)") {
                groups[row[0] as? String ?? ""] = (row[1] as? String ?? "", row[2] as? String ?? "")
            }
        }
        func groupPath(_ id: String) -> String {
            var parts: [String] = []
            var current = id
            var guardCount = 0
            while let g = groups[current], guardCount < 5 {
                if !g.name.isEmpty { parts.insert(g.name, at: 0) }
                current = g.parent
                guardCount += 1
            }
            return parts.joined(separator: " · ")
        }

        // Materials: id → name.
        var materials: [String: String] = [:]
        for table in ["t_MaterialList", "t_CustomerMaterialList"] where tables.contains(table) {
            for row in try query(db, "select materialID, materialSubcategoryName from \(table)") {
                materials[row[0] as? String ?? ""] = row[1] as? String ?? ""
            }
        }

        // Cutting data per tool.
        var properties: [String: [Property]] = [:]
        for table in ["t_MakeraCutterProperties", "t_CustomerCutterProperties"] where tables.contains(table) {
            let sql = "select cutterID, materialId, spindleSpeed, feedRate, plungeFeedRate, stepDown, stepOverPercent from \(table)"
            for row in try query(db, sql) {
                guard let material = materials[row[1] as? String ?? ""], !material.isEmpty else { continue }
                properties[row[0] as? String ?? "", default: []].append(Property(
                    material: material, rpm: double(row[2]), feed: double(row[3]), plunge: double(row[4]),
                    stepDown: double(row[5]), stepOverPercent: double(row[6])))
            }
        }

        // The tools themselves, Makera's then the user's.
        var rows: [Row] = []
        for table in ["t_MakeraCutterList", "t_CustomCutterList"] where tables.contains(table) {
            let sql = """
                select cutterId, groupId, cutterName, cutterNumber, cutterCategoryId, cutterDiameter, cutterMaxDiameter,
                       cutterTipDiameter, cutterAngle, cutterHalfAngle, drillDiameter, cutterFluteLength from \(table)
                """
            for row in try query(db, sql) {
                rows.append(Row(
                    id: row[0] as? String ?? "", groupID: row[1] as? String ?? "", name: row[2] as? String ?? "",
                    number: Int(double(row[3])), category: Int(double(row[4])),
                    shank: optional(row[5]), diameter: optional(row[6]), tip: optional(row[7]),
                    angle: optional(row[8]), halfAngle: optional(row[9]), drill: optional(row[10]), flute: optional(row[11])))
            }
        }

        return rows.compactMap { tool(from: $0, group: groupPath($0.groupID), properties: properties[$0.id] ?? []) }
    }

    // MARK: - Mapping

    /// Studio's cutter categories.
    private enum Category: Int {
        case ballNose = 0, flatEnd = 1, chamfer = 2, engraving = 3, drill = 5, thread = 6, taperedBall = 7
    }

    private static func tool(from r: Row, group: String, properties: [Property]) -> MachineTool? {
        guard let category = Category(rawValue: r.category), !r.name.isEmpty else { return nil }
        var tool = MachineTool(name: r.name)
        // Studio's ids are UUIDs: keeping them makes every later import (and
        // the set bundled with the app) update the same tools instead of
        // adding copies, even after the user renamed one.
        if let id = UUID(uuidString: r.id) { tool.id = id }
        let lower = (r.name + " " + group).lowercased()
        switch category {
        case .drill:
            tool.use = .drilling
            tool.shape = .flat
            tool.diameter = r.drill ?? r.diameter ?? tool.diameter
            tool.cutDepth = -1.8
        case .flatEnd:
            tool.use = .cutout
            tool.shape = .flat
            tool.diameter = r.diameter ?? tool.diameter
            tool.cutDepth = -1.8
        case .ballNose, .taperedBall:
            tool.use = .general
            tool.shape = .ball
            tool.diameter = r.diameter ?? tool.diameter
            tool.cutDepth = -0.1
        case .engraving, .chamfer:
            // Studio stores engraving bits by half angle and chamfers by the
            // included angle; the app wants the included angle.
            tool.use = lower.contains("solder mask") ? .mask : (category == .chamfer ? .general : .isolation)
            tool.shape = .vBit
            tool.tipAngle = r.angle ?? r.halfAngle.map { $0 * 2 } ?? 30
            tool.tipDiameter = r.tip ?? 0.1
            tool.diameter = r.diameter ?? r.shank ?? tool.diameter
            tool.cutDepth = tool.use == .mask ? -0.1 : -0.06
        case .thread:
            return nil
        }
        tool.shankDiameter = r.shank ?? 3.175
        tool.group = group.isEmpty ? "Makera Studio" : "Makera " + group
        tool.dwell = 1

        let isDrill = tool.use == .drilling
        tool.presets = properties.map { p in
            MachineTool.MaterialPreset(
                material: p.material,
                feedXY: isDrill ? p.plunge.rounded() : p.feed.rounded(),
                feedZ: p.plunge.rounded(),
                spindle: p.rpm.rounded(),
                depthPerPass: isDrill ? 0 : max(0, p.stepDown),
                overlap: (p.stepOverPercent > 0 && p.stepOverPercent < 100 && !isDrill) ? (100 - p.stepOverPercent).rounded() : 0)
        }
        var notes = [String(localized: "Imported from Makera Studio")]
        if r.number > 0 { notes.append(String(localized: "Makera tool number \(r.number)")) }
        if let base = basePreset(tool.presets.map(\.material)) {
            tool = tool.applying(material: base)
            notes.append(String(localized: "preset \(base)"))
        }
        tool.notes = notes.joined(separator: " · ")
        return tool
    }

    /// PCB first, then the metals a PCB job is closest to, else the first.
    private static func basePreset(_ names: [String]) -> String? {
        for wanted in ["PCB", "Copper", "Carbon Fiber", "6061 Aluminum", "7075 Aluminum", "Aluminum", "Brass"] {
            if let hit = names.first(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) { return hit }
        }
        return names.first
    }

    // MARK: - SQLite helpers

    /// Every row of a statement as untyped columns (String, Double or nil).
    private static func query(_ db: OpaquePointer, _ sql: String) throws -> [[Any?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure(reason: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        var rows: [[Any?]] = []
        let columns = Int(sqlite3_column_count(statement))
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [Any?] = []
            for index in 0..<columns {
                let column = Int32(index)
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row.append(Double(sqlite3_column_int64(statement, column)))
                case SQLITE_FLOAT: row.append(sqlite3_column_double(statement, column))
                case SQLITE_TEXT: row.append(String(cString: sqlite3_column_text(statement, column)))
                default: row.append(nil)
                }
            }
            rows.append(row)
        }
        return rows
    }

    private static func double(_ value: Any?) -> Double {
        switch value {
        case let d as Double: d
        case let s as String: Double(s) ?? 0
        default: 0
        }
    }

    private static func optional(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: d
        case let s as String: Double(s)
        default: nil
        }
    }
}
