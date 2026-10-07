import Foundation

/// Character-counting flow control for streaming a program, as pure
/// bookkeeping. GRBL's receive buffer holds 128 bytes; a sender that keeps
/// at most that many unacknowledged bytes in flight never blocks the serial
/// link, and the planner stays fed because several lines are always queued
/// ahead of the one executing. Each `ok`/`error:` acknowledges exactly one
/// line, in order, so the in-flight lines form a FIFO whose head is the line
/// the next response belongs to.
///
/// Lines that touch EEPROM on a Grbl-serial board (`$x=`, `G10`, `G28.1`,
/// `G30.1`) stall the firmware while it writes, and Grbl drops characters
/// received meanwhile. Those lines are only sent into an empty window and
/// nothing follows them until their ack arrives (`needsDrain`).
nonisolated struct StreamWindow: Sendable {
    var byteBudget: Int
    var lineBudget: Int

    private(set) var inFlightBytes = 0
    private(set) var inFlightCount = 0

    /// Index and byte cost of every unacknowledged line, oldest first.
    private var pending: [(index: Int, cost: Int)] = []

    init(byteBudget: Int = 128, lineBudget: Int = 8) {
        self.byteBudget = byteBudget
        self.lineBudget = lineBudget
    }

    var isEmpty: Bool { pending.isEmpty }

    /// Indices of the unacknowledged lines, oldest first.
    var pendingIndices: [Int] { pending.map(\.index) }

    /// Bytes the line occupies in the controller's buffer: its UTF-8 plus the newline.
    static func cost(_ line: String) -> Int {
        line.utf8.count + 1
    }

    /// Whether the line must go out alone: any `$` command, or a block with a
    /// `G10`, `G28.1` or `G30.1` word (comments ignored).
    static func needsDrain(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("$") { return true }
        for word in gWords(in: trimmed) where word == 10 || word == 28.1 || word == 30.1 {
            return true
        }
        return false
    }

    /// Whether the line fits the budgets right now. A line that exceeds the
    /// byte budget on its own is still sendable into an empty window — the
    /// controller answers it (`error:11` on Grbl) and the stream moves on,
    /// instead of waiting forever for room that can never appear.
    func canSend(_ line: String) -> Bool {
        if Self.needsDrain(line) { return isEmpty }
        if isEmpty { return true }
        return inFlightBytes + Self.cost(line) <= byteBudget && inFlightCount < lineBudget
    }

    mutating func didSend(_ line: String, index: Int) {
        let cost = Self.cost(line)
        pending.append((index, cost))
        inFlightBytes += cost
        inFlightCount += 1
    }

    /// Acknowledges the oldest line and returns its index; nil when nothing is in flight
    /// (a stray `ok`, e.g. from a real-time command's side effect).
    mutating func ack() -> Int? {
        guard !pending.isEmpty else { return nil }
        let head = pending.removeFirst()
        inFlightBytes -= head.cost
        inFlightCount -= 1
        return head.index
    }

    /// Forgets everything in flight — after a soft reset or a banner, the
    /// controller's buffer is empty and no acks for these lines will come.
    mutating func reset() {
        pending.removeAll()
        inFlightBytes = 0
        inFlightCount = 0
    }

    // MARK: - Word scan

    /// Numeric values of the `G` words in a block, comments stripped, case-insensitive.
    private static func gWords(in block: String) -> [Double] {
        var values: [Double] = []
        var depth = 0
        var number = ""
        var collecting = false

        func flush() {
            if collecting, let value = Double(number) { values.append(value) }
            collecting = false
            number = ""
        }

        for char in block {
            if char == "(" { flush(); depth += 1; continue }
            if char == ")" { depth = max(0, depth - 1); continue }
            if depth > 0 { continue }
            if char == ";" { break }
            if collecting, char.isNumber || char == "." {
                number.append(char)
                continue
            }
            flush()
            if char == "G" || char == "g" { collecting = true }
        }
        flush()
        return values
    }
}
