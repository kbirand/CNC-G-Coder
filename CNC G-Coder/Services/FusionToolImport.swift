import Foundation
import Compression

/// Reads Fusion 360 tool libraries — Makera ships its Carvera bits this way
/// (`Makera Drill Bits.tools`, `… Engraving Bits.tools`, and the same data as
/// `.csv`) — into `MachineTool`s.
///
/// A `.tools` file is a zip holding one `tools.json`; the JSON is also
/// accepted on its own. Every tool carries several *presets* (one per
/// material); the PCB preset is taken when there is one, else Copper, else
/// the first. Depths are not part of Fusion's data, so they start from the
/// app's usual values for the kind of bit and are meant to be adjusted.
nonisolated enum FusionToolImport {

    struct Failure: LocalizedError {
        var reason: String
        var errorDescription: String? { reason }
    }

    /// The tools of a Fusion library, or nil when the data is not one
    /// (so the caller can try the other formats).
    static func parse(_ data: Data, filename: String) throws -> [MachineTool]? {
        // The file's name is the group the tools are filed under
        // ("Makera Drill Bits"); a bare tools.json gets a generic one.
        var group = (filename as NSString).deletingPathExtension.trimmingCharacters(in: .whitespaces)
        if group.lowercased() == "tools" || group.isEmpty { group = "Fusion library" }

        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            guard let json = try unzipFirstEntry(data, named: "tools.json") else {
                throw Failure(reason: "The archive holds no tools.json.")
            }
            return try parseJSON(json, group: group)
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["data"] is [Any] {
            return try parseJSON(data, group: group)
        }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
        if let text, text.prefix(20_000).contains("tool_type") {
            let tools = parseCSV(text, group: group)
            if tools.isEmpty {
                let rows = csvRows(text)
                throw Failure(reason: "The CSV has \(max(rows.count - 1, 0)) rows and \(rows.first?.count ?? 0) columns but no drill or milling bit the app can use.")
            }
            return tools
        }
        return nil
    }

    // MARK: - tools.json

    static func parseJSON(_ data: Data, group: String = "Fusion library") throws -> [MachineTool] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]] else {
            throw Failure(reason: "Not a Fusion tool library.")
        }
        var tools: [MachineTool] = []
        for entry in entries {
            guard let type = entry["type"] as? String, let geometry = entry["geometry"] as? [String: Any] else { continue }
            let presets = (((entry["start-values"] as? [String: Any])?["presets"] as? [[String: Any]]) ?? []).map { Preset(
                name: $0["name"] as? String ?? "",
                feed: number($0["v_f"]), plunge: number($0["v_f_plunge"]), rpm: number($0["n"]),
                stepdown: (($0["use-stepdown"] as? Bool) ?? true) ? number($0["stepdown"]) : nil,
                stepover: (($0["use-stepover"] as? Bool) ?? false) ? number($0["stepover"]) : nil) }
            let unitScale = (entry["unit"] as? String) == "inches" ? 25.4 : 1
            let source = Source(
                type: type, description: entry["description"] as? String ?? "",
                diameter: number(geometry["DC"]).map { $0 * unitScale },
                shank: number(geometry["SFDM"]).map { $0 * unitScale },
                taperAngle: number(geometry["TA"]),
                tipDiameter: number(geometry["tip-diameter"]).map { $0 * unitScale },
                link: entry["product-link"] as? String ?? "",
                group: group, presets: presets, preset: choosePreset(presets))
            if let tool = tool(from: source) { tools.append(tool) }
        }
        return tools
    }

    // MARK: - CSV export

    static func parseCSV(_ text: String, group: String = "Fusion library") -> [MachineTool] {
        let rows = csvRows(text)
        guard let header = rows.first else { return [] }
        func column(_ key: String) -> Int? { header.firstIndex { $0.contains("(\(key))") } }
        guard let typeCol = column("tool_type"), let descCol = column("tool_description") else { return [] }
        let diaCol = column("tool_diameter"), presetCol = column("preset_name"), feedCol = column("tool_feedCutting")
        let plungeCol = column("tool_feedPlunge"), rpmCol = column("tool_spindleSpeed"), stepCol = column("tool_stepdown")
        let overCol = column("tool_stepover"), useOverCol = column("use_tool_stepover"), useStepCol = column("use_tool_stepdown")
        let shankCol = column("tool_shaftDiameter"), taperCol = column("tool_taperAngle"), tipCol = column("tool_tipDiameter")
        let linkCol = column("tool_productLink"), unitCol = column("tool_unit")

        // One row per preset: group the rows of a tool, then pick its preset.
        var order: [String] = []
        var groups: [String: (Source, [Preset])] = [:]
        for row in rows.dropFirst() {
            func cell(_ index: Int?) -> String? {
                guard let index, index < row.count else { return nil }
                let v = row[index].trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
            func num(_ index: Int?) -> Double? { cell(index).flatMap(Double.init) }
            guard let type = cell(typeCol), let description = cell(descCol) else { continue }
            let scale = cell(unitCol) == "inches" ? 25.4 : 1.0
            let key = type + "|" + description + "|" + (cell(diaCol) ?? "")
            let preset = Preset(name: cell(presetCol) ?? "", feed: num(feedCol), plunge: num(plungeCol), rpm: num(rpmCol),
                                stepdown: (cell(useStepCol) ?? "true") == "true" ? num(stepCol) : nil,
                                stepover: cell(useOverCol) == "true" ? num(overCol) : nil)
            if groups[key] == nil {
                order.append(key)
                groups[key] = (Source(type: type, description: description, diameter: num(diaCol).map { $0 * scale },
                                      shank: num(shankCol).map { $0 * scale }, taperAngle: num(taperCol),
                                      tipDiameter: num(tipCol).map { $0 * scale }, link: cell(linkCol) ?? "",
                                      group: group, presets: [], preset: nil), [])
            }
            groups[key]!.1.append(preset)
        }
        return order.compactMap { key in
            guard let group = groups[key] else { return nil }
            var source = group.0
            let presets = group.1
            source.presets = presets
            source.preset = choosePreset(presets)
            return tool(from: source)
        }
    }

    /// RFC 4180-ish: quoted fields with doubled quotes, CRLF or LF rows.
    static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.makeIterator()
        var pending: Character? = nil
        func next() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }
        while let c = next() {
            if quoted {
                if c == "\"" {
                    if let n = next() {
                        if n == "\"" { field.append("\"") } else { quoted = false; pending = n }
                    } else { quoted = false }
                } else {
                    field.append(c)
                }
                continue
            }
            // Swift reads "\r\n" as ONE character: match every line ending.
            if c.isNewline {
                row.append(field); rows.append(row); row = []; field = ""
                continue
            }
            switch c {
            case "\"": quoted = true
            case ",": row.append(field); field = ""
            default: field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !$0.allSatisfy(\.isEmpty) }
    }

    // MARK: - Mapping

    struct Preset {
        var name: String
        var feed: Double?
        var plunge: Double?
        var rpm: Double?
        var stepdown: Double?
        var stepover: Double?
    }

    struct Source {
        var type: String
        var description: String
        var diameter: Double?
        var shank: Double?
        var taperAngle: Double?
        var tipDiameter: Double?
        var link: String
        var group: String
        /// Every material's row.
        var presets: [Preset]
        /// The one the tool's own fields start from.
        var preset: Preset?
    }

    /// Fusion derives feeds and rpm from surface speeds, so they come with
    /// float noise (996.85 mm/min, 11962 rpm): round them the way a person
    /// would type them.
    private static func roundFeed(_ v: Double?) -> Double { max(0, (v ?? 0).rounded()) }
    private static func roundRPM(_ v: Double?) -> Double {
        guard let v, v > 0 else { return 0 }
        return v >= 1000 ? (v / 100).rounded() * 100 : v.rounded()
    }

    /// Fusion's stepover is absolute; as a percentage it only makes sense
    /// against a flat or ball bit's diameter (a V-bit's width depends on
    /// the depth).
    private static func overlapPercent(stepover: Double?, diameter: Double?, vBit: Bool) -> Double {
        guard !vBit, let over = stepover, over > 0, let d = diameter, d > 0, over < d else { return 0 }
        return ((1 - over / d) * 100).rounded()
    }

    /// PCB first, then the metals a PCB job is closest to, else the first.
    static func choosePreset(_ presets: [Preset]) -> Preset? {
        for wanted in ["PCB", "Copper", "Carbon Fiber", "Aluminum", "Brass"] {
            if let p = presets.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) { return p }
        }
        return presets.first
    }

    static func tool(from s: Source) -> MachineTool? {
        var tool = MachineTool(name: s.description.isEmpty ? s.type : s.description)
        let lower = s.description.lowercased()
        switch s.type.lowercased() {
        case "drill":
            tool.use = .drilling
            tool.shape = .flat
            tool.diameter = s.diameter ?? tool.diameter
            tool.cutDepth = -1.8
        case "chamfer mill", "engrave mill", "v-bit":
            // Fusion's taper angle is the half angle; the app's is the included angle.
            tool.use = lower.contains("solder mask") ? .mask : .isolation
            tool.shape = .vBit
            tool.tipAngle = (s.taperAngle ?? 15) * 2
            tool.tipDiameter = s.tipDiameter ?? 0.1
            tool.diameter = s.diameter ?? tool.diameter
            tool.cutDepth = tool.use == .mask ? -0.1 : -0.06
        case "flat end mill", "bull nose end mill":
            tool.use = lower.contains("solder mask") ? .mask : .cutout
            tool.shape = .flat
            tool.diameter = s.diameter ?? tool.diameter
            tool.cutDepth = tool.use == .mask ? -0.1 : -1.8
        case "ball end mill":
            tool.use = .general
            tool.shape = .ball
            tool.diameter = s.diameter ?? tool.diameter
            tool.cutDepth = -0.1
        default:
            return nil   // thread mills, lasers, holders, probes
        }
        tool.shankDiameter = s.shank ?? 3.175
        tool.group = s.group
        var notes = [String(localized: "Imported from a Fusion / Makera tool library")]
        let isDrill = tool.use == .drilling
        // Every material's row stays with the tool (Tool Library → Material
        // picks one when the tool is applied); the chosen preset is also
        // copied into the tool's own fields as the starting point.
        tool.presets = s.presets.filter { !$0.name.isEmpty }.map { p in
            MachineTool.MaterialPreset(
                material: p.name, feedXY: isDrill ? roundFeed(p.plunge) : roundFeed(p.feed), feedZ: roundFeed(p.plunge),
                spindle: roundRPM(p.rpm), depthPerPass: isDrill ? 0 : max(0, p.stepdown ?? 0),
                overlap: overlapPercent(stepover: p.stepover, diameter: s.diameter, vBit: tool.shape == .vBit))
        }
        if let p = s.preset {
            tool = tool.applying(material: p.name)
            if !p.name.isEmpty { notes.append(String(localized: "preset \(p.name)")) }
        }
        tool.dwell = 1
        if !s.link.isEmpty { notes.append(s.link) }
        tool.notes = notes.joined(separator: " · ")
        return tool
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    // MARK: - Minimal zip reader

    /// The first entry called `name` (stored or deflated) of a zip archive.
    static func unzipFirstEntry(_ data: Data, named name: String) throws -> Data? {
        let bytes = [UInt8](data)
        var i = 0
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        while i + 30 <= bytes.count, bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x03, bytes[i + 3] == 0x04 {
            let flags = u16(i + 6), method = u16(i + 8)
            var compressed = u32(i + 18), uncompressed = u32(i + 22)
            let nameLength = u16(i + 26), extraLength = u16(i + 28)
            let nameStart = i + 30
            let entryName = String(decoding: bytes[nameStart..<(nameStart + nameLength)], as: UTF8.self)
            let dataStart = nameStart + nameLength + extraLength
            if flags & 0x08 != 0, compressed == 0 {
                // Sizes in a data descriptor after the data: find it by its signature.
                var j = dataStart
                while j + 16 <= bytes.count {
                    if bytes[j] == 0x50, bytes[j + 1] == 0x4B, bytes[j + 2] == 0x07, bytes[j + 3] == 0x08 {
                        compressed = u32(j + 8); uncompressed = u32(j + 12); break
                    }
                    j += 1
                }
            }
            guard dataStart + compressed <= bytes.count else { throw Failure(reason: "Truncated archive.") }
            let payload = Data(bytes[dataStart..<(dataStart + compressed)])
            if entryName.lowercased().hasSuffix(name.lowercased()) {
                switch method {
                case 0: return payload
                case 8: return try inflate(payload, expected: max(uncompressed, compressed * 8))
                default: throw Failure(reason: "Unsupported zip compression \(method).")
                }
            }
            i = dataStart + compressed
            if flags & 0x08 != 0 {
                // Skip the data descriptor (with or without signature).
                if i + 4 <= bytes.count, bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x07, bytes[i + 3] == 0x08 { i += 16 } else { i += 12 }
            }
        }
        return nil
    }

    /// Raw deflate (zip method 8) via Compression's zlib implementation.
    private static func inflate(_ data: Data, expected: Int) throws -> Data {
        var capacity = max(expected, 64 * 1024)
        while true {
            var out = Data(count: capacity)
            let written = out.withUnsafeMutableBytes { dst -> Int in
                data.withUnsafeBytes { src -> Int in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                              src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            if written == 0 { throw Failure(reason: "The archive could not be decompressed.") }
            if written < capacity { out.count = written; return out }
            capacity *= 4
            if capacity > 256 * 1024 * 1024 { throw Failure(reason: "The archive is too large.") }
        }
    }
}
