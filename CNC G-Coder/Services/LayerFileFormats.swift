import Foundation
import CoreGraphics

/// Why a layer file cannot be edited.
nonisolated struct LayerFileError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Gerber (RS-274X)

/// Reads a Gerber file into objects and writes them back. The output is a
/// clean RS-274X file in the input's units: apertures and macros as they
/// were (plus any added by edits), every draw, flash and region in order,
/// polarity changes kept. Object attributes (%TO/%TA) are metadata no CAM
/// step here reads, and are dropped.
nonisolated enum GerberFile {

    static func read(_ url: URL) throws -> GerberImage {
        let data = try Data(contentsOf: url)
        return try parse(String(decoding: data, as: UTF8.self))
    }

    // MARK: Reading

    static func parse(_ text: String) throws -> GerberImage {
        var image = GerberImage()
        var intDigits = 2, decDigits = 4
        var trailingOmitted = false
        var current = CGPoint.zero
        var aperture: Int?
        enum Interpolation { case linear, clockwise, counterclockwise }
        var interpolation = Interpolation.linear
        var multiQuadrant = true
        var dark = true
        var region: [GerberPath]?
        var contour: GerberPath?
        var track: GerberObject?
        var lastOperation: Int?
        var sawObject = false

        func number(_ s: Substring) -> Double {
            if s.contains(".") { return (Double(s) ?? 0) * image.unit }
            var digits = s
            var sign = 1.0
            if let f = digits.first, f == "-" || f == "+" {
                if f == "-" { sign = -1 }
                digits = digits.dropFirst()
            }
            var string = String(digits)
            if trailingOmitted, string.count < intDigits + decDigits {
                string += String(repeating: "0", count: intDigits + decDigits - string.count)
            }
            return sign * (Double(string) ?? 0) / pow(10, Double(decDigits)) * image.unit
        }

        func flushTrack() {
            if let t = track { image.objects.append(t) }
            track = nil
        }
        func flushContour() {
            if let c = contour, !c.segments.isEmpty { region?.append(c) }
            contour = nil
        }

        /// Arc from `s` to `e`; `i`/`j` offset the centre from the start.
        func arc(from s: CGPoint, to e: CGPoint, i: Double, j: Double, clockwise: Bool) -> GerberSegment {
            if multiQuadrant {
                return .arc(to: e, center: CGPoint(x: s.x + i, y: s.y + j), clockwise: clockwise)
            }
            // Single quadrant (G74): the offsets are unsigned; the centre is
            // the one of the four candidates that makes a ≤ 90° arc.
            var best: (Double, CGPoint)?
            for (sx, sy) in [(1.0, 1.0), (-1, 1), (1, -1), (-1, -1)] {
                let c = CGPoint(x: s.x + sx * abs(i), y: s.y + sy * abs(j))
                let sweep = GerberSegment.sweep(from: s, to: e, center: c, clockwise: clockwise)
                guard sweep <= .pi / 2 + 1e-3 else { continue }
                let mismatch = abs(ShapeMath.distance(s, c) - ShapeMath.distance(e, c))
                if mismatch < (best?.0 ?? .infinity) { best = (mismatch, c) }
            }
            return .arc(to: e, center: best?.1 ?? CGPoint(x: s.x + i, y: s.y + j), clockwise: clockwise)
        }

        func extended(_ body: String) throws {
            let blocks = body.split(separator: "*").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard let first = blocks.first else { return }
            let code = first.prefix(2)
            switch code {
            case "FS":
                trailingOmitted = first.dropFirst(2).first == "T"
                if first.contains("I") { throw LayerFileError(message: "Incremental coordinates are not supported.") }
                if let x = first.firstIndex(of: "X") {
                    let d = first[first.index(after: x)...].prefix(2).compactMap { $0.wholeNumberValue }
                    if d.count == 2 { intDigits = d[0]; decDigits = d[1] }
                }
            case "MO":
                image.inches = first.hasPrefix("MOIN")
            case "AD":
                // ADD10C,0.5X0.3 — code, template, parameters.
                var rest = first.dropFirst(3)
                let digits = rest.prefix { $0.isNumber }
                rest = rest.dropFirst(digits.count)
                guard let number = Int(digits) else { return }
                let parts = rest.split(separator: ",", maxSplits: 1)
                let template = parts.first.map(String.init) ?? ""
                let params = parts.count > 1 ? parts[1].split(separator: "X").compactMap { Double($0) } : []
                image.apertures[number] = GerberAperture(code: number, template: template, params: params)
            case "AM":
                image.macros.append(GerberMacro(name: String(first.dropFirst(2)), blocks: Array(blocks.dropFirst())))
            case "LP":
                let newDark = first.dropFirst(2).first != "C"
                if newDark != dark { flushTrack() }
                dark = newDark
            case "SR":
                let values = first.dropFirst(2).split(whereSeparator: { "XYIJ".contains($0) }).compactMap { Double($0) }
                if values.prefix(2).contains(where: { $0 > 1 }) {
                    throw LayerFileError(message: "Step-and-repeat blocks (%SR) are not supported by the editor.")
                }
            case "AB":
                throw LayerFileError(message: "Block apertures (%AB) are not supported by the editor.")
            case "TA", "TO", "TD", "LN":
                break
            default:
                if !sawObject { image.header.append(blocks.joined(separator: "*")) }
            }
        }

        func word(_ block: Substring) throws {
            if block.hasPrefix("G04") || block.hasPrefix("G4 ") {
                if !sawObject { image.comments.append(block.dropFirst(3).trimmingCharacters(in: .whitespaces)) }
                return
            }
            var gCodes: [Int] = []
            var dCode: Int?
            var x: Substring?, y: Substring?, iOff: Substring?, jOff: Substring?
            var index = block.startIndex
            while index < block.endIndex {
                let letter = block[index]
                index = block.index(after: index)
                let start = index
                while index < block.endIndex, block[index].isNumber || "+-.".contains(block[index]) {
                    index = block.index(after: index)
                }
                let value = block[start..<index]
                switch letter {
                case "G": if let g = Int(value) { gCodes.append(g) }
                case "D": dCode = Int(value)
                case "X": x = value
                case "Y": y = value
                case "I": iOff = value
                case "J": jOff = value
                case "M": if Int(value) == 2 { return }
                default: break   // N (sequence numbers) and the like
                }
            }
            for g in gCodes {
                switch g {
                case 1: interpolation = .linear
                case 2: interpolation = .clockwise
                case 3: interpolation = .counterclockwise
                case 74: multiQuadrant = false
                case 75: multiQuadrant = true
                case 70: image.inches = true
                case 71: image.inches = false
                case 91: throw LayerFileError(message: "Incremental coordinates (G91) are not supported.")
                case 36:
                    flushTrack()
                    region = []
                case 37:
                    flushContour()
                    if let contours = region, !contours.isEmpty {
                        image.objects.append(GerberObject(kind: .region(contours: contours), dark: dark))
                        sawObject = true
                    }
                    region = nil
                default: break
                }
            }
            var operation: Int?
            if let d = dCode {
                if d >= 10 {
                    if aperture != d { flushTrack() }
                    aperture = d
                } else {
                    operation = d
                }
            }
            let hasCoordinates = x != nil || y != nil || iOff != nil || jOff != nil
            if operation == nil, hasCoordinates { operation = lastOperation }   // deprecated modal D-code
            guard let op = operation else { return }
            lastOperation = op
            let target = CGPoint(x: x.map(number) ?? current.x, y: y.map(number) ?? current.y)
            switch op {
            case 1:
                let segment: GerberSegment = interpolation == .linear
                    ? .line(to: target)
                    : arc(from: current, to: target, i: iOff.map(number) ?? 0, j: jOff.map(number) ?? 0,
                          clockwise: interpolation == .clockwise)
                if region != nil {
                    if contour == nil { contour = GerberPath(start: current) }
                    contour?.segments.append(segment)
                } else if let a = aperture {
                    if case .track(let ta, let path)? = track?.kind, ta == a, path.end == current {
                        track?.kind = .track(aperture: a, path: GerberPath(start: path.start, segments: path.segments + [segment]))
                    } else {
                        flushTrack()
                        track = GerberObject(kind: .track(aperture: a, path: GerberPath(start: current, segments: [segment])), dark: dark)
                        sawObject = true
                    }
                }
            case 2:
                flushTrack()
                if region != nil {
                    flushContour()
                    contour = GerberPath(start: target)
                }
            case 3:
                flushTrack()
                if region == nil, let a = aperture {
                    image.objects.append(GerberObject(kind: .flash(aperture: a, at: target), dark: dark))
                    sawObject = true
                }
            default:
                break
            }
            current = target
        }

        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "%" {
                var j = i + 1
                while j < chars.count, chars[j] != "%" { j += 1 }
                try extended(String(chars[(i + 1)..<min(j, chars.count)]).filter { $0 != "\n" && $0 != "\r" })
                i = j + 1
            } else if c.isWhitespace {
                i += 1
            } else {
                var j = i
                while j < chars.count, chars[j] != "*", chars[j] != "%" { j += 1 }
                let block = String(chars[i..<j]).filter { $0 != "\n" && $0 != "\r" }
                try word(Substring(block))
                i = j < chars.count && chars[j] == "*" ? j + 1 : j
            }
        }
        flushTrack()
        if region != nil {
            flushContour()
            if let contours = region, !contours.isEmpty {
                image.objects.append(GerberObject(kind: .region(contours: contours), dark: dark))
            }
        }
        if image.objects.isEmpty, image.apertures.isEmpty {
            throw LayerFileError(message: "No Gerber data found in the file.")
        }
        return image
    }

    // MARK: Writing

    static func write(_ image: GerberImage) -> String {
        var out: [String] = []
        for comment in image.comments where !comment.isEmpty { out.append("G04 \(comment)*") }
        out.append("G04 Edited with CNC G-Coder*")
        // Leading zeros omitted, absolute; six decimals whatever the input had.
        out.append(image.inches ? "%FSLAX36Y36*%" : "%FSLAX46Y46*%")
        out.append(image.inches ? "%MOIN*%" : "%MOMM*%")
        for body in image.header { out.append("%\(body)*%") }
        for macro in image.macros {
            out.append((["%AM\(macro.name)*"] + macro.blocks.map { "\($0)*" }).joined(separator: "\n") + "%")
        }
        let used = Set(image.objects.compactMap(\.aperture))
        for code in image.apertures.keys.sorted() where used.contains(code) {
            let a = image.apertures[code]!
            let params = a.params.map(format).joined(separator: "X")
            out.append("%ADD\(code)\(a.template)\(params.isEmpty ? "" : "," + params)*%")
        }
        out.append("G75*")
        out.append("%LPD*%")

        let unit = image.unit
        func c(_ v: Double) -> String { String(Int((v / unit * 1_000_000).rounded())) }
        func xy(_ p: CGPoint) -> String { "X\(c(p.x))Y\(c(p.y))" }

        var dark = true
        var aperture: Int?
        var mode = ""
        func setMode(_ g: String) {
            if mode != g { out.append("\(g)*"); mode = g }
        }
        func segments(_ path: GerberPath) {
            var cursor = path.start
            for segment in path.segments {
                switch segment {
                case .line(let to):
                    setMode("G01")
                    out.append("\(xy(to))D01*")
                case .arc(let to, let center, let cw):
                    setMode(cw ? "G02" : "G03")
                    out.append("\(xy(to))I\(c(center.x - cursor.x))J\(c(center.y - cursor.y))D01*")
                }
                cursor = segment.end
            }
        }

        for object in image.objects {
            if object.dark != dark {
                dark = object.dark
                out.append(dark ? "%LPD*%" : "%LPC*%")
            }
            switch object.kind {
            case .track(let a, let path):
                if aperture != a { out.append("D\(a)*"); aperture = a }
                out.append("\(xy(path.start))D02*")
                segments(path)
            case .flash(let a, let at):
                if aperture != a { out.append("D\(a)*"); aperture = a }
                out.append("\(xy(at))D03*")
            case .region(let contours):
                out.append("G36*")
                for contour in contours {
                    out.append("\(xy(contour.start))D02*")
                    segments(contour)
                }
                out.append("G37*")
            }
        }
        out.append("M02*")
        return out.joined(separator: "\n") + "\n"
    }

    /// A parameter without trailing zeros: 0.5, 3, 1.27.
    static func format(_ v: Double) -> String {
        var s = String(format: "%.6f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }
}

// MARK: - Excellon

/// Reads an Excellon drill file into holes and writes it back — always in
/// millimetres with explicit decimal points, which leaves no zero-suppression
/// or digit-format guessing for whatever reads it next.
nonisolated enum ExcellonFile {

    static func read(_ url: URL) throws -> ExcellonImage {
        let data = try Data(contentsOf: url)
        return try parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ text: String) throws -> ExcellonImage {
        var image = ExcellonImage()
        var inHeader = false
        var inch = false
        /// true = leading zeros kept (LZ, trailing ones may be dropped).
        var leadingZeros: Bool?
        var intDigits: Int?, decDigits: Int?
        var tool: Int?
        var current = CGPoint.zero
        var routeStart: CGPoint?
        var sawBody = false
        var sawHeader = false

        func units(_ line: String) {
            inch = line.hasPrefix("INCH") || line == "M72"
            if line.contains(",LZ") { leadingZeros = true }
            if line.contains(",TZ") { leadingZeros = false }
            // METRIC,LZ,000.000 spells the digit format out.
            if let template = line.split(separator: ",").first(where: { $0.contains(".") && $0.allSatisfy { $0 == "0" || $0 == "." } }) {
                let halves = template.split(separator: ".", omittingEmptySubsequences: false)
                if halves.count == 2 { intDigits = halves[0].count; decDigits = halves[1].count }
            }
        }

        func number(_ s: Substring) -> Double {
            let scale = inch ? 25.4 : 1
            if s.contains(".") { return (Double(s) ?? 0) * scale }
            var digits = s
            var sign = 1.0
            if let f = digits.first, f == "-" || f == "+" {
                if f == "-" { sign = -1 }
                digits = digits.dropFirst()
            }
            let int = intDigits ?? (inch ? 2 : 3)
            let dec = decDigits ?? (inch ? 4 : 3)
            var string = String(digits)
            if leadingZeros == true, string.count < int + dec {
                string += String(repeating: "0", count: int + dec - string.count)
            }
            return sign * (Double(string) ?? 0) / pow(10, Double(dec)) * scale
        }

        func point(_ s: Substring) -> CGPoint {
            var p = current
            var index = s.startIndex
            while index < s.endIndex {
                let letter = s[index]
                index = s.index(after: index)
                let start = index
                while index < s.endIndex, s[index].isNumber || "+-.".contains(s[index]) { index = s.index(after: index) }
                if letter == "X" { p.x = number(s[start..<index]) }
                if letter == "Y" { p.y = number(s[start..<index]) }
            }
            return p
        }

        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix(";") {
                if !sawBody { image.comments.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)) }
                if let r = line.range(of: "FILE_FORMAT=") {
                    let d = line[r.upperBound...].split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    if d.count == 2 { intDigits = d[0]; decDigits = d[1] }
                }
                continue
            }
            let u = line.uppercased()
            if u == "M48" { inHeader = true; sawHeader = true; continue }
            if inHeader, u == "%" || u == "M95" { inHeader = false; continue }
            if u.hasPrefix("METRIC") || u.hasPrefix("INCH") || u == "M71" || u == "M72" { units(u); continue }
            if u == "M30" || u == "M00" { break }
            if u.hasPrefix("T") {
                let digits = u.dropFirst().prefix { $0.isNumber }
                guard let n = Int(digits) else { continue }
                if let c = u.firstIndex(of: "C") {
                    // Tool definition: T01C0.915 (other words may sit before the C).
                    let value = u[u.index(after: c)...].prefix { $0.isNumber || $0 == "." }
                    if let d = Double(value) { image.tools[n] = d * (inch ? 25.4 : 1) }
                    if !inHeader { tool = n }
                } else {
                    tool = n == 0 ? nil : n
                }
                continue
            }
            // Rout mode (KiCad's oval holes): G00 to the start, M15 down,
            // G01 to the end, M16 up — kept as a slot.
            if u.hasPrefix("G00") {
                sawBody = true
                routeStart = point(u.dropFirst(3))
                current = routeStart!
                continue
            }
            if u.hasPrefix("G01") {
                let end = point(u.dropFirst(3))
                if let tool, let start = routeStart {
                    image.holes.append(ExcellonHole(tool: tool, at: start, slotEnd: ShapeMath.distance(start, end) > 1e-6 ? end : nil))
                }
                routeStart = end
                current = end
                continue
            }
            if u.hasPrefix("G02") || u.hasPrefix("G03") {
                throw LayerFileError(message: "Routed arcs in drill files are not supported by the editor.")
            }
            if ["M15", "M16", "M17", "G05", "G90"].contains(u) {
                if u == "G05" || u == "M17" { routeStart = nil }
                continue
            }
            if u.hasPrefix("R"), u.dropFirst().first?.isNumber == true {
                throw LayerFileError(message: "Repeated holes (R codes) are not supported by the editor.")
            }
            guard u.hasPrefix("X") || u.hasPrefix("Y") else { continue }
            sawBody = true
            guard let tool else { continue }
            let parts = u.components(separatedBy: "G85")
            let start = point(Substring(parts[0]))
            current = start
            var hole = ExcellonHole(tool: tool, at: start)
            if parts.count > 1 {
                let end = point(Substring(parts[1]))
                if ShapeMath.distance(start, end) > 1e-6 { hole.slotEnd = end }
                current = end
            }
            image.holes.append(hole)
        }
        if image.holes.isEmpty, image.tools.isEmpty, !sawHeader {
            throw LayerFileError(message: "No Excellon drill data found in the file.")
        }
        return image
    }

    static func write(_ image: ExcellonImage) -> String {
        var out = ["M48"]
        for comment in image.comments where !comment.isEmpty && !comment.hasPrefix("FILE_FORMAT") && !comment.hasPrefix("FORMAT") {
            out.append(";\(comment)")
        }
        out.append(";Edited with CNC G-Coder")
        out.append(";FORMAT={-:-/ absolute / metric / decimal}")
        out.append("METRIC")
        // Tools without holes are left out — unless there are no holes at
        // all, when the table is all that is left of the file.
        let used = Set(image.holes.map(\.tool))
        let tools = image.tools.keys.sorted().filter { used.isEmpty || used.contains($0) }
        for t in tools {
            out.append(String(format: "T%02dC%.4f", t, image.tools[t] ?? 0))
        }
        out.append("%")
        out.append("G90")
        out.append("G05")
        func c(_ v: Double) -> String {
            var s = String(format: "%.4f", v)
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s += "0" }
            return s == "-0.0" ? "0.0" : s
        }
        for t in tools {
            out.append(String(format: "T%02d", t))
            for hole in image.holes where hole.tool == t {
                var line = "X\(c(hole.at.x))Y\(c(hole.at.y))"
                if let end = hole.slotEnd { line += "G85X\(c(end.x))Y\(c(end.y))" }
                out.append(line)
            }
        }
        out.append("T00")
        out.append("M30")
        return out.joined(separator: "\n") + "\n"
    }
}
