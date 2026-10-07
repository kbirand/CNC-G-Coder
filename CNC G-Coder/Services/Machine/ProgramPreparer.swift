import Foundation
import CoreGraphics

// Turns a generated program into the exact text that is streamed to the
// machine. Everything here is line-for-line: nothing is deleted or merged,
// so line N of the file on disk is line N as sent, is `sourceLine` N of
// the parsed layer the canvases draw. The only in-place rewrites are the
// tool-change words (`T`, `M6`, `M0`), which become comments — the
// streamer suspends *before* such a line instead of letting the controller
// park in `Hold:0` where nothing (jog, probe, zero) is accepted.

/// The lines one tool cuts, between two tool changes.
nonisolated struct ToolSegment: Equatable, Sendable {
    /// 1-based line numbers of the program text that belong to this segment.
    var lines: ClosedRange<Int>
    /// "T1", the `(MSG, …)` text found before the M6, or "Tool change".
    var toolLabel: String
    /// First line to send when continuing into this segment: its M3 line,
    /// or `lines.lowerBound`.
    var resumeLine: Int
}

nonisolated struct ProgramOptions: Equatable, Sendable {
    var applyBacklash: Bool = true
    var heightMap: HeightMap? = nil
    var applyBelowZ: Double = 1
    /// Design → this program's frame (`AppModel.heightMapFrame`), used to
    /// place the height map (design coordinates) under the program.
    var frame: CGAffineTransform = .identity
    /// "Clamp Z to top": every Z word above this work value on a motion line
    /// is replaced by it (air tests with work Z0 near the top of travel).
    /// Lower Z — the cutting depths — is never touched.
    var clampZAboveWork: Double? = nil
}

/// A program ready to stream: its text on disk, the tool segments and the
/// parse of that same text.
nonisolated struct MachineProgram: Sendable, Identifiable {
    let token: UUID
    var id: UUID { token }
    let kind: LayerKind
    /// "front-copper.ngc"
    let name: String
    /// The exact text sent, under `PreviewPaths.machineDir`.
    let url: URL
    /// The text split on "\n" — sent verbatim, one by one, every line.
    let lines: [String]
    /// At least one; `segments[0]` starts at line 1.
    let segments: [ToolSegment]
    /// Lines that were T/M6/M0 (now comments): the streamer suspends BEFORE sending one.
    let toolChangeLines: Set<Int>
    /// `GCodeParser.parse` of `url`, with the source layer's tool diameter.
    let parsed: ParsedLayer
    let options: ProgramOptions
    /// False when skipped (already-compensated header found, or inactive).
    let backlashApplied: Bool
    /// Human-readable log lines about what was done.
    let notes: [String]
    /// The height XY travel happens at (the most common Z of XY rapids):
    /// where a resume retracts to before moving across the board.
    let safeZ: Double

    /// The segment containing a line, if any.
    func segment(containing line: Int) -> ToolSegment? {
        segments.first { $0.lines.contains(line) }
    }

    /// The segment after the one containing `line` (the one a tool change
    /// at `line` leads into).
    func segment(after line: Int) -> ToolSegment? {
        guard let index = segments.firstIndex(where: { $0.lines.contains(line) }) else { return nil }
        return segments.indices.contains(index + 1) ? segments[index + 1] : nil
    }
}

/// The modal state a program has reached just before a line.
nonisolated struct ModalState: Equatable, Sendable {
    var units = "G21"
    var distance = "G90"
    var plane = "G17"
    var motion: Int?
    var feed: Double?
    var spindleRPM: Double?
    /// "M3" / "M4" while the spindle is on, nil when off or never started.
    var spindleOn: String?
    var x: Double?
    var y: Double?
    var z: Double?
    /// +1/−1: the sign of each axis's last change (for the backlash take-up).
    var lastDirection: [Axis: Int] = [:]
}

/// Letter–number words of a G-code block, comments ignored, exact values
/// (so `G91.1` is never mistaken for `G91`). Shared by the preparer, the
/// streamer and the controller.
nonisolated enum GCodeWords {
    struct Word: Equatable, Sendable {
        let letter: Character
        let value: Double
    }

    static func scan(_ line: String) -> [Word] {
        let chars = Array(line)
        var words: [Word] = []
        var depth = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "(" { depth += 1; i += 1; continue }
            if c == ")" { depth = max(0, depth - 1); i += 1; continue }
            if depth > 0 { i += 1; continue }
            if c == ";" { break }
            guard c.isLetter else { i += 1; continue }
            var j = i + 1
            while j < chars.count, chars[j] == " " { j += 1 }
            let start = j
            if j < chars.count, chars[j] == "-" || chars[j] == "+" { j += 1 }
            while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
            if let value = Double(String(chars[start..<j])) {
                words.append(Word(letter: Character(c.uppercased()), value: value))
                i = j
            } else {
                i += 1
            }
        }
        return words
    }

    /// The text of a `(MSG, …)` comment, if the line carries one.
    static func message(in line: String) -> String? {
        guard let open = line.range(of: "(MSG,", options: .caseInsensitive) else { return nil }
        let rest = line[open.upperBound...]
        let close = rest.firstIndex(of: ")") ?? rest.endIndex
        let text = rest[..<close].trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// Whether the words move an axis (X/Y/Z, or arc offsets).
    static func hasAxisWords(_ words: [Word]) -> Bool {
        words.contains { "XYZIJK".contains($0.letter) }
    }

    /// The line with the number of its first `letter` word (outside
    /// comments) replaced; nil when the line has no such word.
    static func replacingValue(of letter: Character, in line: String, with value: Double) -> String? {
        let chars = Array(line)
        var depth = 0
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "(" { depth += 1; i += 1; continue }
            if c == ")" { depth = max(0, depth - 1); i += 1; continue }
            if depth > 0 { i += 1; continue }
            if c == ";" { break }
            guard c.isLetter else { i += 1; continue }
            var j = i + 1
            while j < chars.count, chars[j] == " " { j += 1 }
            let start = j
            if j < chars.count, chars[j] == "-" || chars[j] == "+" { j += 1 }
            while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
            if Double(String(chars[start..<j])) != nil {
                if Character(c.uppercased()) == letter {
                    return String(chars[..<start]) + GRBLCommand.number(value) + String(chars[j...])
                }
                i = j
            } else {
                i += 1
            }
        }
        return nil
    }
}

nonisolated enum ProgramPreparer {

    struct Failure: LocalizedError {
        var reason: String
        var errorDescription: String? { reason }
    }

    /// A line that is replaced by a comment. The comment keeps GRBL's 80-byte
    /// line limit with room for the newline.
    private static let maxLineLength = 78

    // MARK: - Prepare

    /// Prepares `sourceText` (the snapshot of `layer.fileURL`) for the
    /// machine. Synchronous: call it from `Task.detached`.
    static func prepare(sourceText: String, layer: ParsedLayer, name: String, options: ProgramOptions,
                        backlash: BacklashCompensation.Settings) throws -> MachineProgram {
        // Line endings first: Swift treats "\r\n" as one Character, so a CRLF
        // file split on "\n" would come out as a single line (and Grbl ends a
        // line at "\r" too, which would make it acknowledge every line twice).
        var text = sourceText.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var notes: [String] = []

        // 1. Height map (before backlash: the take-ups are XY-only and the
        //    warp subdivides XY moves, so either order is geometrically the
        //    same, but warping first keeps the backlash header on top).
        if let map = options.heightMap {
            do {
                text = try map.apply(to: text, applyBelowZ: options.applyBelowZ, frame: options.frame)
                let deviation = map.maxDeviation.map { String(format: "%.3f", $0) } ?? "?"
                notes.append("Height map applied: \(map.nx)×\(map.ny), max deviation \(deviation) mm, below Z \(GRBLCommand.number(options.applyBelowZ)).")
            } catch {
                throw Failure(reason: "Height map cannot be applied: \(error.localizedDescription)")
            }
        }

        // 2. Backlash compensation, unless the text already carries it (test
        //    boards are compensated on disk) or it is off.
        var backlashApplied = false
        if options.applyBacklash, backlash.isActive {
            if isBacklashHeader(text) {
                notes.append("Backlash compensation already present in the file (header found) — not applied again.")
            } else {
                do {
                    let result = try BacklashCompensation.apply(backlash, to: text)
                    text = result.text
                    backlashApplied = true
                    notes.append("Backlash compensation (\(backlash.summary)): \(result.takeUps) take-up move\(result.takeUps == 1 ? "" : "s") inserted.")
                } catch {
                    throw Failure(reason: "Backlash compensation cannot be applied: \(error.localizedDescription)")
                }
            }
        } else if !options.applyBacklash, backlash.isActive {
            notes.append("Backlash compensation switched off for this program.")
        }

        // 3. Line-for-line rewrite: replace the tool-change words by comments.
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Keep at least one line, and drop a lone trailing empty line left by
        // the file's final newline (it would be sent as an empty block).
        if lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
        if lines.isEmpty { lines = [""] }

        // 3a. Clamp Z to the top of travel: motion lines only (never G53,
        //     offsets or G28/G30), only Z words above the clamp, line count kept.
        if let clamp = options.clampZAboveWork {
            let clamped = clampZ(&lines, above: clamp)
            notes.append("Z clamped to \(GRBLCommand.number(clamp)) (top of travel) on \(clamped) line\(clamped == 1 ? "" : "s").")
        }

        var toolChangeLines = Set<Int>()
        var toolChangeKinds: [Int: String] = [:]      // line -> "T1" / "M6" / "M0"
        var lastMessage: String?
        var messageAt: [Int: String] = [:]            // tool-change line -> the MSG that preceded it
        for index in lines.indices {
            let line = lines[index]
            if let message = GCodeWords.message(in: line) { lastMessage = message }
            let words = GCodeWords.scan(line)
            var marker: String?
            for word in words {
                switch (word.letter, word.value) {
                case ("T", _): marker = "T\(Int(word.value))"
                case ("M", 6): marker = "M6"
                case ("M", 0): marker = "M0"
                case ("M", 1): marker = "M1"
                default: break
                }
            }
            guard let marker else { continue }
            let number = index + 1
            toolChangeLines.insert(number)
            toolChangeKinds[number] = marker
            if let lastMessage { messageAt[number] = lastMessage }
            // Keep the words that matter next to the marker in the comment
            // so the program tab still reads like the original.
            let original = line.trimmingCharacters(in: .whitespaces)
            var comment = "( tool change: \(original.replacingOccurrences(of: "(", with: "[").replacingOccurrences(of: ")", with: "]")) )"
            if comment.count > maxLineLength { comment = String(comment.prefix(maxLineLength - 2)) + " )" }
            lines[index] = comment
        }

        // 4. Tool segments: a block of tool-change lines (with only
        //    non-motion lines between them) ends a segment; the next starts
        //    after the block, resuming at its M3.
        let blocks = toolChangeBlocks(lines: lines, changes: toolChangeLines)
        var segments: [ToolSegment] = []
        var start = 1
        var previousBlock: ClosedRange<Int>?
        func label(for block: ClosedRange<Int>?) -> String {
            guard let block else { return "Program" }
            // The MSG nearest the M6 names the tool going in (a T line at the
            // block's start may still carry the previous block's message).
            for number in block.reversed() {
                if let message = messageAt[number] { return message }
            }
            for number in block {
                if let kind = toolChangeKinds[number], kind.hasPrefix("T") { return kind }
            }
            return block.contains(where: { toolChangeKinds[$0] == "M6" || toolChangeKinds[$0]?.hasPrefix("T") == true })
                ? "Tool change" : "Program pause"
        }
        func resume(from first: Int, to last: Int) -> Int {
            guard first <= last else { return first }
            for number in first...last {
                let words = GCodeWords.scan(lines[number - 1])
                if words.contains(where: { $0.letter == "M" && ($0.value == 3 || $0.value == 4) }) { return number }
                // Any motion before the spindle line: resume at the segment start.
                if GCodeWords.hasAxisWords(words) { return first }
            }
            return first
        }
        for block in blocks {
            let end = block.upperBound
            segments.append(ToolSegment(lines: start...max(start, end), toolLabel: label(for: previousBlock),
                                        resumeLine: previousBlock == nil ? start : resume(from: start, to: end)))
            previousBlock = block
            start = end + 1
        }
        if start <= lines.count || segments.isEmpty {
            let end = max(start, lines.count)
            segments.append(ToolSegment(lines: start...end, toolLabel: label(for: previousBlock),
                                        resumeLine: previousBlock == nil ? start : resume(from: start, to: end)))
        }

        // 5. Static pre-flight: a feed move before any F word would be
        //    error:22 on the machine (and a feed hold) at the first plunge.
        try checkFeedBeforeMoves(lines)

        // 6. Write under the machine directory.
        let token = UUID()
        let dir = PreviewPaths.machineDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stem = (name as NSString).deletingPathExtension
        let url = dir.appendingPathComponent("\(stem.isEmpty ? "program" : stem)-\(token.uuidString.prefix(8)).ngc")
        let finalText = lines.joined(separator: "\n") + "\n"
        try finalText.write(to: url, atomically: true, encoding: .utf8)

        // 7. Parse the sent text so sourceLines match it.
        var parsed = try GCodeParser.parse(fileURL: url, layer: layer.id)
        parsed.toolDiameter = layer.toolDiameter
        let safeZ = travelHeight(of: parsed)
        notes.append("\(lines.count) lines, \(segments.count) tool segment\(segments.count == 1 ? "" : "s"), "
                     + "\(toolChangeLines.count) tool-change line\(toolChangeLines.count == 1 ? "" : "s") replaced.")

        return MachineProgram(token: token, kind: layer.id, name: name, url: url, lines: lines, segments: segments,
                              toolChangeLines: toolChangeLines, parsed: parsed, options: options,
                              backlashApplied: backlashApplied, notes: notes, safeZ: safeZ)
    }

    /// Replaces every Z word above `clamp` on a motion line by `clamp`;
    /// returns how many lines changed. Lines in machine coordinates (G53)
    /// and offset/park commands (G10, G92, G28, G30) are left alone.
    static func clampZ(_ lines: inout [String], above clamp: Double) -> Int {
        var count = 0
        for index in lines.indices {
            let words = GCodeWords.scan(lines[index])
            guard let z = words.first(where: { $0.letter == "Z" }), z.value > clamp + 1e-9 else { continue }
            let untouchable = words.contains { $0.letter == "G" && [53, 10, 92, 28, 30].contains(Int($0.value)) }
            if untouchable { continue }
            if let rewritten = GCodeWords.replacingValue(of: "Z", in: lines[index], with: clamp) {
                lines[index] = rewritten
                count += 1
            }
        }
        return count
    }

    /// Whether the text already starts with the backlash compensator's header.
    static func isBacklashHeader(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("( Backlash compensation")
    }

    /// Groups the tool-change lines into blocks: consecutive markers with
    /// only non-motion lines (M5, G4, comments, blanks) between them.
    private static func toolChangeBlocks(lines: [String], changes: Set<Int>) -> [ClosedRange<Int>] {
        var blocks: [ClosedRange<Int>] = []
        for number in changes.sorted() {
            if let last = blocks.last, number > last.upperBound {
                let between = (last.upperBound + 1)..<number
                let motionBetween = between.contains { GCodeWords.hasAxisWords(GCodeWords.scan(lines[$0 - 1])) }
                if !motionBetween {
                    blocks[blocks.count - 1] = last.lowerBound...number
                    continue
                }
            }
            blocks.append(number...number)
        }
        return blocks
    }

    /// Throws when a G1/G2/G3 move (explicit or modal) comes before the first `F`.
    private static func checkFeedBeforeMoves(_ lines: [String]) throws {
        var mode = 0
        var feedSeen = false
        for (index, line) in lines.enumerated() {
            let words = GCodeWords.scan(line)
            if words.contains(where: { $0.letter == "F" && $0.value > 0 }) { feedSeen = true }
            for w in words where w.letter == "G" && (0...3).contains(w.value) { mode = Int(w.value) }
            if words.contains(where: { $0.letter == "G" && ($0.value == 38.2 || $0.value == 38.3 || $0.value == 38.4 || $0.value == 38.5) }) {
                mode = 1
            }
            guard mode >= 1, GCodeWords.hasAxisWords(words), !feedSeen else { continue }
            throw Failure(reason: "line \(index + 1): a feed move (G\(mode)) before any feed rate (F) — the controller would reject it (error:22). Add an F word to the program.")
        }
    }

    /// The most common Z among XY-moving rapids — the travel height.
    private static func travelHeight(of parsed: ParsedLayer) -> Double {
        var counts: [Int: Int] = [:]
        for move in parsed.moves where move.kind == .rapid && move.feed == nil {
            let xyMoved = abs(move.end.x - move.start.x) > 1e-9 || abs(move.end.y - move.start.y) > 1e-9
            guard xyMoved, abs(move.zEnd - move.zStart) < 1e-9 else { continue }
            counts[Int((move.zEnd * 1000).rounded()), default: 0] += 1
        }
        if let best = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) }) {
            return Double(best.key) / 1000
        }
        return parsed.zMax
    }

    // MARK: - Modal state and resume preamble

    /// The modal state after lines 1…line−1 (`line` is 1-based).
    static func modalState(lines: [String], before line: Int) -> ModalState {
        var state = ModalState()
        let upTo = min(max(line - 1, 0), lines.count)
        for index in 0..<upTo {
            let words = GCodeWords.scan(lines[index])
            var absolute = state.distance == "G90"
            for w in words {
                switch (w.letter, w.value) {
                case ("G", 20): state.units = "G20"
                case ("G", 21): state.units = "G21"
                case ("G", 90): state.distance = "G90"; absolute = true
                case ("G", 91): state.distance = "G91"; absolute = false
                case ("G", 17): state.plane = "G17"
                case ("G", 18): state.plane = "G18"
                case ("G", 19): state.plane = "G19"
                case ("G", 0), ("G", 1), ("G", 2), ("G", 3): state.motion = Int(w.value)
                case ("F", _): state.feed = w.value
                case ("S", _): state.spindleRPM = w.value
                case ("M", 3): state.spindleOn = "M3"
                case ("M", 4): state.spindleOn = "M4"
                case ("M", 5): state.spindleOn = nil
                default: break
                }
            }
            // Positions: only tracked in absolute mode (the programs are), and
            // only on motion lines (G10/G92/G28 words redefine, not move).
            let nonMotion = words.contains { $0.letter == "G" && ($0.value == 10 || $0.value == 92 || $0.value == 28 || $0.value == 30 || $0.value == 53 || $0.value == 28.1 || $0.value == 30.1) }
            guard absolute, !nonMotion else { continue }
            for w in words {
                let axis: Axis
                switch w.letter {
                case "X": axis = .x
                case "Y": axis = .y
                case "Z": axis = .z
                default: continue
                }
                let previous: Double?
                switch axis {
                case .x: previous = state.x
                case .y: previous = state.y
                case .z: previous = state.z
                }
                if let previous, abs(w.value - previous) > 1e-9 {
                    state.lastDirection[axis] = w.value > previous ? 1 : -1
                }
                switch axis {
                case .x: state.x = w.value
                case .y: state.y = w.value
                case .z: state.z = w.value
                }
            }
        }
        return state
    }

    /// The lines that re-establish `modal` safely before line N is sent:
    /// units/distance/plane, retract (to the machine's safe height when
    /// `machineZBelowSafe`, else to `zSafe`) — before the spindle starts,
    /// so a bit sitting in the cut is never spun up there — spindle with
    /// warm-up, XY approach with a lead-in from the modelled backlash
    /// direction, then the plunge to the modal Z at `plungeFeed` when it is
    /// below `zSafe`, and the modal motion word with its feed.
    ///
    /// `segmentStart`: line N is a tool segment's resume line (its M3, or
    /// the segment's first line): the program's own M3 / retract / approach
    /// follow, so the approach and the plunge are left out — only the
    /// retract and the modal words are sent.
    static func resumePreamble(modal: ModalState, zSafe: Double, safePositionLine: String?, machineZBelowSafe: Bool,
                               backlash: BacklashCompensation.Settings, backlashApplied: Bool, plungeFeed: Double,
                               warmupSeconds: Double, segmentStart: Bool = false) -> [String] {
        var lines: [String] = ["G21 G90 G17"]
        let n = GRBLCommand.number

        var retractedToMachineTop = false
        if machineZBelowSafe, let safePositionLine {
            lines.append(safePositionLine)
            retractedToMachineTop = true
        } else {
            lines.append("G0 Z" + n(zSafe))
        }

        if let spindle = modal.spindleOn {
            if let rpm = modal.spindleRPM, rpm > 0 {
                lines.append("\(spindle) S\(Int(rpm.rounded()))")
            } else {
                lines.append(spindle)
            }
            if warmupSeconds > 0 { lines.append("G4 P" + String(format: "%.1f", warmupSeconds)) }
        }

        if !segmentStart {
            if let px = modal.x, let py = modal.y {
                let takeUp = backlashApplied && backlash.isActive
                let dx = takeUp && backlash.x > 0 ? Double(modal.lastDirection[.x] ?? 1) : 0
                let dy = takeUp && backlash.y > 0 ? Double(modal.lastDirection[.y] ?? 1) : 0
                if dx != 0 || dy != 0 {
                    let lead = BacklashCompensation.leadIn
                    lines.append("G0 X\(n(px - dx * lead)) Y\(n(py - dy * lead)) ( backlash lead-in )")
                }
                lines.append("G0 X\(n(px)) Y\(n(py))")
            }

            if retractedToMachineTop { lines.append("G0 Z" + n(zSafe)) }
            if let pz = modal.z, pz < zSafe - 1e-9 {
                lines.append("G1 Z\(n(pz)) " + GRBLCommand.feedWord(plungeFeed))
            }
        }

        // A bare G2/G3 is rejected without axis words, and the feed is modal
        // across G1/G2/G3, so the arc modes set the feed through G1.
        let motion = modal.motion.map { $0 >= 2 ? 1 : $0 } ?? 0
        if let feed = modal.feed, feed > 0 {
            lines.append("G\(motion) " + GRBLCommand.feedWord(feed))
        } else if modal.motion != nil {
            lines.append("G\(motion)")
        }
        return lines
    }
}
