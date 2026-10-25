import Foundation

// The machine post: turns the engines' programs (pcb2gcode's layout, which
// the preview, the side view and the streamer all read) into the files a
// Makera Carvera runs. Two things change and nothing else:
//
//   1. Tool changes. The engines write `T<n>` / `M5` / `M6` / `M0` / `M3`
//      and the operator swaps the bit while the controller waits at `M0`.
//      Carvera's firmware does not implement `M0` at all (the line is a
//      no-op and the program would run on with the old bit), and its
//      `T<n> M6` is a real tool change: the changer picks slot n from the
//      rack and probes the bit's length. So every block becomes
//      `M5` / `T<slot> M6` / `S<rpm> M3`, with the slot numbers of one
//      rack shared by every file of the job (`Plan.rack`).
//   2. Files. One program per layer is the GRBL way; on a machine that
//      changes its own tools the natural unit is a *stage*: everything that
//      runs between two moments the operator must touch the board (paint
//      and cure the mask, flip it). The four stages are front isolation,
//      front finish (mask etch, drills, holes, cutout), back isolation and
//      back finish; stages with nothing in them are left out.
//
// Everything here is pure and `nonisolated`: `plan` needs no file access
// (drill sizes and times come from the parsed programs), so the sidebar can
// show the rack live; `write` reads the program texts once at Generate.
nonisolated enum MachinePost {

    // MARK: - Inputs

    /// One generated program, as the plan sees it.
    struct Program: Sendable {
        let layer: LayerKind
        let url: URL
        var toolDiameter: Double?
        /// The bit sizes a drill program changes to, mm (from its parse).
        var drillSizes: [Double] = []
        /// Feed-rate time estimate, seconds (0 when unknown).
        var estimatedTime: Double = 0

        init(layer: LayerKind, url: URL, toolDiameter: Double? = nil, drillSizes: [Double] = [], estimatedTime: Double = 0) {
            self.layer = layer
            self.url = url
            self.toolDiameter = toolDiameter
            self.drillSizes = drillSizes
            self.estimatedTime = estimatedTime
        }

        /// From a parsed preview layer: drill sizes and time come for free.
        init(parsed: ParsedLayer) {
            var sizes: [Double] = []
            for hole in parsed.drillHoles where !sizes.contains(where: { abs($0 - hole.diameter) < 1e-6 }) {
                sizes.append(hole.diameter)
            }
            self.init(layer: parsed.id, url: parsed.fileURL, toolDiameter: parsed.toolDiameter,
                      drillSizes: sizes.sorted(), estimatedTime: parsed.totalTime)
        }
    }

    /// What the plan and the writer need to know besides the programs.
    struct Context: Sendable {
        var profile: MachineProfile
        var snapshot: ParameterSnapshot
        var files: DetectedFiles
        var customLayers: [CustomLayer]
        /// Library tool names by id, for the bits custom layers picked.
        var toolNames: [String: String] = [:]
        /// The project's name: the prefix of every stage file.
        var jobName: String = ""
        /// Compressed air (`M7`) while cutting.
        var air: Bool = true
    }

    // MARK: - Plan

    /// A machine session: what runs between two moments the operator must
    /// touch the board.
    enum Stage: Int, CaseIterable, Sendable {
        case frontIsolation, frontFinish, backIsolation, backFinish

        /// The short code in file names and headers: 1F, 2F, 1B, 2B.
        var code: String { ["1F", "2F", "1B", "2B"][rawValue] }
        var isBack: Bool { self == .backIsolation || self == .backFinish }
        var isIsolation: Bool { self == .frontIsolation || self == .backIsolation }

        /// What the operator does before it.
        var before: String {
            switch self {
            case .frontIsolation: String(localized: "Clamp the bare board against Anchor 1 and set the work origin.")
            case .frontFinish: String(localized: "Paint the solder mask and cure it, board left clamped. Run with Auto Leveling unticked so stage 1F's grid is reused.")
            case .backIsolation: String(localized: "Flip the board (the way Machine setup → Board flips says) against the same anchor corner.")
            case .backFinish: String(localized: "Paint and cure the back-side mask, board left clamped. Auto Leveling unticked.")
            }
        }
    }

    /// A distinct bit the job needs.
    struct Bit: Hashable, Sendable {
        /// Stable identity: "id:<library uuid>", "vbit:<tip>:<angle>",
        /// "flat:<diameter>" or "drill:<diameter>".
        let key: String
        let label: String
    }

    /// One rack slot.
    struct RackEntry: Identifiable, Sendable {
        var id: String { bit.key }
        let bit: Bit
        var slot: Int
        /// The programs that use it, in machining order (display names).
        var programs: [String]
        /// The slot was fixed by hand (param.rackSlots).
        var fixed: Bool
        /// The bit sits in the machine's changer at this slot (ToolLibrary.rack).
        var loaded: Bool = false
    }

    struct StagePlan: Identifiable, Sendable {
        var id: Int { stage.rawValue }
        let stage: Stage
        var programs: [Program]
        /// "Front: mask etch, drilling, cutout"
        var title: String
        var fileName: String
        /// Slots used, in order of first use.
        var slots: [Int]
        var estimatedTime: Double
        /// Header code when it is not the stage's own ("1F+2F" for a
        /// sequence that spans sessions).
        var code: String? = nil

        var headerCode: String { code ?? stage.code }
    }

    /// A hand-picked set of the job's programs as one file for the tool
    /// changer (the Machine panel's "Send Layers…").
    struct Sequence: Sendable {
        var stage: StagePlan
        var ref: LayerKind.StageRef
        /// Spanning sessions, more bits than the rack holds…
        var warnings: [String]
    }

    /// Orders `kinds` the way the stages would (mask, drills, cutout…),
    /// numbers their bits from the whole job's rack and says what the
    /// operator should know. Nil when none of the kinds is in `all`.
    static func sequence(_ kinds: [LayerKind], programs all: [Program], context: Context) -> Sequence? {
        let chosen = all.filter { kinds.contains($0.layer) }
        guard !chosen.isEmpty else { return nil }
        let whole = plan(programs: all, context: context)
        let own = plan(programs: chosen, context: context)
        guard let first = own.stages.first else { return nil }
        let ordered = own.stages.flatMap(\.programs)
        var slots: [Int] = []
        for program in ordered {
            for bit in bits(of: program, context: context) {
                if let slot = whole.slot(for: bit.key), !slots.contains(slot) { slots.append(slot) }
            }
        }
        let code = own.stages.map(\.stage.code).joined(separator: "+")
        let title = own.stages.count == 1 ? first.title : own.stages.map(\.title).joined(separator: " + ")
        var stage = StagePlan(stage: first.stage, programs: ordered, title: title,
                              fileName: fileName(first.stage, ordered, context: context),
                              slots: slots, estimatedTime: ordered.reduce(0) { $0 + $1.estimatedTime })
        if own.stages.count > 1 {
            stage.code = code
            stage.fileName = stage.fileName.replacingOccurrences(of: "-\(first.stage.code)-", with: "-\(code.replacingOccurrences(of: "+", with: ""))-")
        }
        var warnings = whole.warnings
        if own.stages.count > 1 {
            warnings.append(String(localized: "These layers belong to different machine sessions (\(own.stages.map(\.stage.code).joined(separator: ", "))): the file runs straight through, with no stop to paint the mask or flip the board."))
        }
        let ref = LayerKind.StageRef(code: code, title: title, back: first.stage.isBack, layers: ordered.map(\.layer))
        return Sequence(stage: stage, ref: ref, warnings: warnings)
    }

    /// Renders a sequence with the slots of the whole job.
    static func render(sequence: Sequence, programs all: [Program], context: Context) throws -> Rendered {
        try render(stage: sequence.stage, plan: plan(programs: all, context: context), context: context)
    }

    /// True for a file this post wrote (a stage file from Generate or a
    /// sequence): its tool changes are already `T<n> M6` and must be sent,
    /// not rewritten again.
    static func isRenderedFile(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = String(decoding: handle.readData(ofLength: 1024), as: UTF8.self)
        return head.contains("CNC G-Coder") && head.contains("Rack for this job")
    }

    struct Plan: Sendable {
        var rack: [RackEntry] = []
        var stages: [StagePlan] = []
        /// Problems the operator must know about before loading the rack.
        var warnings: [String] = []
        /// Notes worth a line in the log.
        var notes: [String] = []

        func slot(for key: String) -> Int? { rack.first { $0.bit.key == key }?.slot }
        var slotCount: Int { rack.map(\.slot).max() ?? 0 }
    }

    /// Groups the programs into stages and numbers the bits.
    static func plan(programs: [Program], context: Context) -> Plan {
        var plan = Plan()

        // Which finish stage takes the side-neutral programs (drills, holes,
        // cutout): the first side's — front when there is any front work or
        // no back work at all.
        let hasFront = programs.contains { side(of: $0.layer) == .front }
        let hasBack = programs.contains { side(of: $0.layer) == .back }
        let finish: Stage = (hasFront || !hasBack) ? .frontFinish : .backFinish

        var grouped: [Stage: [Program]] = [:]
        for program in programs {
            grouped[stage(of: program.layer, neutralFinish: finish), default: []].append(program)
        }

        // Bits in order of first use across the stages → slots.
        var order: [Bit] = []
        var users: [String: [String]] = [:]
        for stage in Stage.allCases {
            guard let list = grouped[stage] else { continue }
            grouped[stage] = list.sorted { rank($0.layer) < rank($1.layer) }
            for program in grouped[stage]! {
                for bit in bits(of: program, context: context) {
                    if !order.contains(bit) { order.append(bit) }
                    let name = program.layer.displayName
                    if users[bit.key]?.last != name { users[bit.key, default: []].append(name) }
                }
            }
        }

        // Slots fixed per project first, then the library's preferred
        // slots, then the gaps in order of use.
        let overrides = ParametersStore.parseRackSlots(context.snapshot.rackSlots)
        var taken = Set<Int>()
        var entries: [RackEntry] = []
        for bit in order {
            if let fixed = overrides[bit.key], !taken.contains(fixed) {
                taken.insert(fixed)
                entries.append(RackEntry(bit: bit, slot: fixed, programs: users[bit.key] ?? [], fixed: true))
            } else {
                if let fixed = overrides[bit.key], taken.contains(fixed) {
                    plan.warnings.append(String(localized: "\(bit.label) was fixed on T\(fixed), already taken — it was numbered automatically."))
                }
                entries.append(RackEntry(bit: bit, slot: 0, programs: users[bit.key] ?? [], fixed: false))
            }
        }
        // Bits sitting in the machine's changer keep their slot — a drill
        // whose range covers a program's size serves it too.
        func loadedSlot(for key: String) -> Int? {
            if let slot = context.snapshot.rackTools[key] { return slot }
            if key.hasPrefix("drill:"), let size = Double(key.dropFirst(6)) {
                // The program's size is the hole plus its allowance.
                let hole = size - (Double(context.snapshot.drillHoleAllowance) ?? 0)
                return context.snapshot.rackDrillRanges.sorted { $0.key < $1.key }
                    .first { $0.value.contains(hole) || $0.value.contains(size) }?.key
            }
            return nil
        }
        for index in entries.indices where entries[index].slot == 0 {
            if let slot = loadedSlot(for: entries[index].bit.key), !taken.contains(slot) {
                entries[index].slot = slot
                entries[index].loaded = true
                taken.insert(slot)
            }
        }
        for index in entries.indices where entries[index].slot == 0 {
            if let preferred = context.snapshot.preferredSlots[entries[index].bit.key], !taken.contains(preferred) {
                entries[index].slot = preferred
                taken.insert(preferred)
            }
        }
        for index in entries.indices where entries[index].fixed {
            entries[index].loaded = loadedSlot(for: entries[index].bit.key) == entries[index].slot
        }
        // Automatic numbering prefers slots the changer has free: a slot
        // holding some other bit is used only once the free ones are gone
        // (then that bit has to come out, and the note says so).
        let occupied = Set(context.snapshot.rackTools.values)
        let automatic = context.profile.toolChange.automaticSlots ?? Int.max
        for index in entries.indices where entries[index].slot == 0 {
            var next = 1
            while taken.contains(next) || (occupied.contains(next) && next <= automatic) { next += 1 }
            if next > automatic {
                next = 1
                while taken.contains(next) { next += 1 }
            }
            entries[index].slot = next
            taken.insert(next)
        }
        plan.rack = entries.sorted { $0.slot < $1.slot }
        if !context.snapshot.rackTools.isEmpty {
            let missing = plan.rack.filter { !$0.loaded }
            if !missing.isEmpty {
                plan.notes.append(String(localized: "Not in the tool changer yet: \(missing.map { "T\($0.slot) \($0.bit.label)" }.joined(separator: ", ")) — load them before the job (Tool Changer…)."))
            }
        }

        let change = context.profile.toolChange
        if let max = change.maxToolNumber, plan.slotCount > max {
            plan.warnings.append(String(localized: "This job needs \(plan.rack.count) bits but the rack has \(max) slots (T1–T\(max)) — the firmware refuses T\(max + 1) and above. Combine drill sizes (bits on hand), or pick the community-firmware profile where higher numbers prompt for a manual change."))
        } else if let auto = change.automaticSlots, plan.slotCount > auto {
            plan.notes.append(String(localized: "T\(auto + 1) and above are manual changes: the machine parks and asks for the bit."))
        }

        for stage in Stage.allCases {
            guard let list = grouped[stage], !list.isEmpty else { continue }
            var slots: [Int] = []
            for program in list {
                for bit in bits(of: program, context: context) {
                    if let slot = plan.slot(for: bit.key), !slots.contains(slot) { slots.append(slot) }
                }
            }
            plan.stages.append(StagePlan(
                stage: stage, programs: list, title: title(stage, list), fileName: fileName(stage, list, context: context),
                slots: slots, estimatedTime: list.reduce(0) { $0 + $1.estimatedTime }))
        }
        return plan
    }

    // MARK: Stage membership

    private enum Side { case front, back, neutral }

    private static func side(of kind: LayerKind) -> Side {
        switch kind {
        case .front, .maskTop, .silkTop, .test: .front
        case .back, .maskBottom, .silkBottom: .back
        case .custom(let ref): ref.back ? .back : .front
        case .stage(let ref): ref.back ? .back : .front
        case .outline, .drill, .millDrill: .neutral
        }
    }

    private static func stage(of kind: LayerKind, neutralFinish: Stage) -> Stage {
        switch kind {
        case .front: .frontIsolation
        case .back: .backIsolation
        case .maskTop, .silkTop, .test: .frontFinish
        case .maskBottom, .silkBottom: .backFinish
        case .custom(let ref): ref.back ? .backFinish : .frontFinish
        case .stage(let ref): ref.back ? .backFinish : .frontFinish
        case .outline, .drill, .millDrill: neutralFinish
        }
    }

    /// Machining order inside a stage: mask, legend, drills (file order,
    /// milled holes right after their drills), cutout, drawn layers.
    private static func rank(_ kind: LayerKind) -> Int {
        switch kind {
        case .front, .back: 0
        case .maskTop, .maskBottom: 0
        case .silkTop, .silkBottom: 1
        case .drill(let index, _): 10 + 2 * index
        case .millDrill(let index, _): 11 + 2 * index
        case .outline: 1000
        case .custom(let ref): 2000 + ref.index
        case .test: 3000
        case .stage: 3100
        }
    }

    private static func title(_ stage: Stage, _ programs: [Program]) -> String {
        let side = stage.isBack ? String(localized: "Back") : String(localized: "Front")
        if stage.isIsolation { return String(localized: "\(side) isolation") }
        var parts: [String] = []
        func add(_ s: String) { if !parts.contains(s) { parts.append(s) } }
        for program in programs {
            switch program.layer {
            case .maskTop, .maskBottom: add(String(localized: "mask etch"))
            case .silkTop, .silkBottom: add(String(localized: "silkscreen"))
            case .drill, .millDrill: add(String(localized: "drilling"))
            case .outline: add(String(localized: "cutout"))
            case .custom: add(String(localized: "custom layers"))
            case .test: add(String(localized: "test board"))
            case .stage(let ref): add(ref.title)
            case .front, .back: add(String(localized: "isolation"))
            }
        }
        return "\(side): " + parts.joined(separator: ", ")
    }

    private static func fileName(_ stage: Stage, _ programs: [Program], context: Context) -> String {
        var tags: [String] = []
        func add(_ s: String) { if !tags.contains(s) { tags.append(s) } }
        for program in programs {
            switch program.layer {
            case .front, .back: add("isolation")
            case .maskTop, .maskBottom: add("mask")
            case .silkTop, .silkBottom: add("silk")
            case .drill, .millDrill: add("drill")
            case .outline: add("cut")
            case .custom: add("custom")
            case .test: add("test")
            case .stage: add("stage")
            }
        }
        let job = slug(context.jobName)
        let side = stage.isBack ? "back" : "front"
        let stem = ([job, stage.code, side] + tags).filter { !$0.isEmpty }.joined(separator: "-")
        return stem + "." + context.profile.fileExtension
    }

    static func slug(_ text: String) -> String {
        text.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }

    // MARK: Bits

    /// The bits a program changes to, in order.
    static func bits(of program: Program, context: Context) -> [Bit] {
        let p = context.snapshot.forLayer(program.layer, files: context.files)
        func group(_ g: ParametersStore.MotionGroup, fallback: String) -> Bit {
            if let key = p.toolKeys[g.rawValue] {
                return Bit(key: key, label: p.toolLabels[g.rawValue] ?? fallback)
            }
            let d = ParametersStore.format(program.toolDiameter ?? 0)
            return Bit(key: "flat:\(d)", label: String(localized: "\(fallback) \(d) mm"))
        }
        switch program.layer {
        case .front, .back: return [group(.iso, fallback: String(localized: "Isolation bit"))]
        case .outline: return [group(.cut, fallback: String(localized: "End mill"))]
        case .millDrill: return [group(.holeMill, fallback: String(localized: "End mill"))]
        case .maskTop, .maskBottom: return [group(.mask, fallback: String(localized: "Mask bit"))]
        case .silkTop, .silkBottom: return [group(.silk, fallback: String(localized: "Silkscreen bit"))]
        case .drill:
            let sizes = program.drillSizes.isEmpty ? [program.toolDiameter ?? 0] : program.drillSizes
            return sizes.map { drillBit($0, context: context) }
        case .custom(let ref):
            guard let layer = context.customLayers.first(where: { $0.id == ref.id }) else {
                return [Bit(key: "flat:\(ParametersStore.format(program.toolDiameter ?? 0))", label: ref.name)]
            }
            if layer.type == .drill { return [drillBit(layer.toolDiameter, context: context)] }
            if !layer.toolID.isEmpty, let name = context.toolNames[layer.toolID] {
                return [Bit(key: "id:" + layer.toolID, label: name)]
            }
            let d = ParametersStore.format(layer.toolDiameter)
            return [Bit(key: "flat:\(d)", label: String(localized: "End mill \(d) mm"))]
        case .test, .stage:
            let d = ParametersStore.format(program.toolDiameter ?? 0)
            return [Bit(key: "flat:\(d)", label: String(localized: "End mill \(d) mm"))]
        }
    }

    static func drillBit(_ size: Double, context: Context) -> Bit {
        let d = ParametersStore.format(size)
        return Bit(key: "drill:\(d)", label: context.snapshot.drillNames[d] ?? String(localized: "Drill \(d) mm"))
    }

    // MARK: - Writing

    struct WrittenFile: Sendable {
        let stage: StagePlan
        let url: URL
    }

    struct Rendered: Sendable {
        var text: String
        var notes: [String]
    }

    /// Writes every stage of `plan` into `outputDir`; the log tells what
    /// was rewritten.
    static func write(plan: Plan, context: Context, outputDir: URL) throws -> (files: [WrittenFile], log: String) {
        var files: [WrittenFile] = []
        var log = ""
        for stage in plan.stages {
            let rendered = try render(stage: stage, plan: plan, context: context)
            let url = outputDir.appendingPathComponent(stage.fileName)
            try rendered.text.write(to: url, atomically: true, encoding: .utf8)
            files.append(WrittenFile(stage: stage, url: url))
            log += "Stage \(stage.stage.code) → \(stage.fileName): " + rendered.notes.joined(separator: "; ") + "\n"
        }
        return (files, log)
    }

    /// One program alone, as its own file (Export program…).
    static func renderSingle(program: Program, context: Context) throws -> Rendered {
        let plan = plan(programs: [program], context: context)
        guard let stage = plan.stages.first else { throw Failure(reason: "Nothing to write.") }
        return try render(stage: stage, plan: plan, context: context)
    }

    /// One program with the slots of a whole job's rack (`plan` covers the
    /// other programs too), for sending a single program to the machine.
    static func renderProgram(_ program: Program, plan: Plan, context: Context) throws -> Rendered {
        let own = self.plan(programs: [program], context: context)
        guard var stage = own.stages.first else { throw Failure(reason: "Nothing to write.") }
        stage.slots = bits(of: program, context: context).compactMap { plan.slot(for: $0.key) }
        return try render(stage: stage, plan: plan, context: context)
    }

    struct Failure: LocalizedError {
        var reason: String
        var errorDescription: String? { reason }
    }

    /// The spindle as the file leaves it after each line.
    private struct Spindle {
        var on = false
        var rpm: Double?
        var clockwise = true
    }

    /// A tool-change block of the engines' layout: the lines from the first
    /// of `T` / `M5` before `M6` to the spin-up dwell after `M3`.
    private struct Block {
        var range: ClosedRange<Int>
        var rpm: Double?
        var clockwise = true
        var spinDown: Double?
        var spinUp: Double?
        var message: String?
    }

    static func render(stage: StagePlan, plan: Plan, context: Context) throws -> Rendered {
        let profile = context.profile
        var out: [String] = []
        var notes: [String] = []
        var removedPauses = 0, clampedFeeds = 0, clampedSpeeds = 0, changes = 0, skippedChanges = 0

        // Header: who, what, the rack, and the modal state every program
        // of the engines assumes.
        out.append(comment("CNC G-Coder · \(profile.name)" + (context.jobName.isEmpty ? "" : " · \(context.jobName)")))
        out.append(comment("Stage \(stage.headerCode) · \(stage.title)"))
        if stage.estimatedTime > 0 {
            out.append(comment("Estimated \(timeText(stage.estimatedTime)) at the programmed feeds"))
        }
        out.append(comment("Rack for this job:"))
        for entry in plan.rack {
            let used = stage.slots.contains(entry.slot) ? "" : " · not used in this stage"
            out.append(comment(String(format: "  T%-2d %@ — %@%@", entry.slot, entry.bit.label, entry.programs.joined(separator: ", "), used)))
        }
        out.append(comment("This stage uses " + stage.slots.map { "T\($0)" }.joined(separator: " ")))
        out.append(comment("Before it: " + stage.stage.before))
        out.append("G90 G94 G17 G21")
        out.append("G54")

        var active: Int?
        var activeCollet: Int?
        var spindle = Spindle()
        var airOn = false
        // The community firmware's `M6 S<collet>` tells the manual-change
        // prompt which collet to fit; only worth a word when the shank changes.
        let namesCollets: Bool = {
            if case .automaticOrManual = profile.toolChange { return true }
            return false
        }()

        func emitChange(slot: Int, label: String, key: String, rpm: Double?, clockwise: Bool, spinDown: Double?, spinUp: Double?) {
            let rpm = rpm.map { min($0, profile.spindleMax) }
            if active == slot, spindle.on {
                if let rpm, rpm != spindle.rpm || clockwise != spindle.clockwise {
                    out.append("S\(Int(rpm.rounded())) " + (clockwise ? "M3" : "M4"))
                    spindle.rpm = rpm
                    spindle.clockwise = clockwise
                } else {
                    out.append(comment("T\(slot) \(label) stays in the spindle"))
                }
                skippedChanges += 1
                return
            }
            if spindle.on {
                if airOn { out.append("M9"); airOn = false }
                out.append("M5")
                if let spinDown, spinDown > 0 { out.append("G4 P" + ParametersStore.format(spinDown)) }
                spindle.on = false
            }
            if active != slot {
                out.append(comment("Tool change: T\(slot) \(label)"))
                var change = "T\(slot) M6"
                if namesCollets, let shank = context.snapshot.shankDiameters[key] {
                    let collet = MachineTool.colletIndex(forShank: shank)
                    if let collet, collet != activeCollet { change += " S\(collet)" }
                    activeCollet = collet
                }
                out.append(change)
                active = slot
                changes += 1
            }
            let speed = rpm ?? spindle.rpm
            out.append((speed.map { "S\(Int($0.rounded())) " } ?? "") + (clockwise ? "M3" : "M4"))
            if let spinUp, spinUp > 0 { out.append("G4 P" + ParametersStore.format(spinUp)) }
            if context.air, !airOn { out.append("M7"); airOn = true }
            spindle = Spindle(on: true, rpm: speed, clockwise: clockwise)
        }

        for program in stage.programs {
            let text: String
            do { text = try String(contentsOf: program.url, encoding: .utf8) } catch {
                throw Failure(reason: "\(program.layer.displayName): \(error.localizedDescription)")
            }
            let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            out.append("")
            out.append(comment("———— \(program.layer.displayName) (\(program.url.lastPathComponent)) ————"))

            let footer = footerStart(lines)
            let blocks = toolBlocks(lines, before: footer)
            let programBits = bits(of: program, context: context)
            var bitIndex = 0
            var pendingRPM: Double?
            var sawChange = false

            var i = 0
            while i < footer {
                // A tool-change block of the engines → one Carvera change.
                if let block = blocks.first(where: { $0.range.lowerBound == i }) {
                    var bit = programBits.first ?? Bit(key: "?", label: "")
                    if program.layer.isDrill {
                        if let message = block.message, let size = GCodeParser.commentDiameter(message) {
                            bit = drillBit(size, context: context)
                        } else if bitIndex < programBits.count {
                            bit = programBits[bitIndex]
                        }
                        bitIndex += 1
                    }
                    if let message = block.message { out.append(comment(message)) }
                    let slot = plan.slot(for: bit.key) ?? (plan.slotCount + 1)
                    emitChange(slot: slot, label: bit.label, key: bit.key, rpm: block.rpm ?? pendingRPM, clockwise: block.clockwise,
                               spinDown: block.spinDown, spinUp: block.spinUp)
                    sawChange = true
                    removedPauses += lines[block.range].filter { hasWord($0, "M", 0) || hasWord($0, "M", 1) }.count
                    i = block.range.upperBound + 1
                    continue
                }

                let line = lines[i]
                i += 1
                let code = strippedOfComments(line)
                let words = GCodeWords.scan(line)

                if code.isEmpty {
                    // Comments: keep the useful ones, drop the engines' banners.
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty, !isBanner(trimmed) else { continue }
                    out.append(comment(commentText(trimmed)))
                    continue
                }
                if let message = GCodeWords.message(in: line) {
                    out.append(comment(message))
                    continue
                }

                // Modal header words: set once at the top of the file.
                if words.allSatisfy({ isHeaderWord($0) }) {
                    if let s = words.first(where: { $0.letter == "S" }) { pendingRPM = s.value }
                    continue
                }
                if words.contains(where: { $0.letter == "M" && [0, 1, 2, 30, 7, 8, 9].contains(Int($0.value)) }) {
                    if words.contains(where: { $0.letter == "M" && ($0.value == 0 || $0.value == 1) }) { removedPauses += 1 }
                    continue
                }
                if hasWord(line, "G", 64) || (hasWord(line, "G", 4) && words.contains { $0.letter == "P" && $0.value == 0 }) {
                    continue
                }
                // A spindle start without a tool-change block (drawn layers,
                // test boards): the stage's first bit is changed in here.
                if words.contains(where: { $0.letter == "M" && ($0.value == 3 || $0.value == 4) }), !GCodeWords.hasAxisWords(words) {
                    let clockwise = !words.contains { $0.letter == "M" && $0.value == 4 }
                    let rpm = words.first { $0.letter == "S" }?.value ?? pendingRPM
                    if !sawChange, let bit = programBits.first {
                        let slot = plan.slot(for: bit.key) ?? (plan.slotCount + 1)
                        emitChange(slot: slot, label: bit.label, key: bit.key, rpm: rpm, clockwise: clockwise, spinDown: 1, spinUp: nil)
                        sawChange = true
                    } else {
                        out.append((rpm.map { "S\(Int(min($0, profile.spindleMax).rounded())) " } ?? "") + (clockwise ? "M3" : "M4"))
                        spindle = Spindle(on: true, rpm: rpm, clockwise: clockwise)
                    }
                    continue
                }
                if words.count == 1, words[0].letter == "S" {
                    pendingRPM = words[0].value
                    continue
                }
                if hasWord(line, "M", 5), !GCodeWords.hasAxisWords(words) {
                    if spindle.on {
                        if airOn { out.append("M9"); airOn = false }
                        out.append("M5")
                        spindle.on = false
                    }
                    continue
                }

                // Everything else is motion or a dwell: clamp what the
                // machine cannot do and pass it through.
                var kept = line
                if let f = words.first(where: { $0.letter == "F" }), f.value > profile.maxFeed,
                   let clamped = GCodeWords.replacingValue(of: "F", in: kept, with: profile.maxFeed) {
                    kept = clamped
                    clampedFeeds += 1
                }
                if let s = words.first(where: { $0.letter == "S" }), s.value > profile.spindleMax,
                   let clamped = GCodeWords.replacingValue(of: "S", in: kept, with: profile.spindleMax) {
                    kept = clamped
                    clampedSpeeds += 1
                }
                out.append(asciiComments(kept))
            }
        }

        // End of the stage: spindle and air off, park, end.
        out.append("")
        if airOn { out.append("M9") }
        if spindle.on { out.append("M5") }
        out.append("G28")
        out.append("M2")

        notes.append("\(stage.programs.count) program\(stage.programs.count == 1 ? "" : "s"), \(changes) tool change\(changes == 1 ? "" : "s")")
        if skippedChanges > 0 { notes.append("\(skippedChanges) change\(skippedChanges == 1 ? "" : "s") skipped (bit already in the spindle)") }
        if removedPauses > 0 { notes.append("\(removedPauses) M0/M1 pause\(removedPauses == 1 ? "" : "s") removed (not supported by the firmware)") }
        if clampedFeeds > 0 { notes.append("\(clampedFeeds) feed\(clampedFeeds == 1 ? "" : "s") clamped to \(Int(profile.maxFeed)) mm/min") }
        if clampedSpeeds > 0 { notes.append("\(clampedSpeeds) spindle speed\(clampedSpeeds == 1 ? "" : "s") clamped to \(Int(profile.spindleMax)) rpm") }
        return Rendered(text: out.joined(separator: "\n") + "\n", notes: notes)
    }

    // MARK: Line analysis

    /// The tool-change blocks of the engines' layout before `end`.
    private static func toolBlocks(_ lines: [String], before end: Int) -> [Block] {
        var blocks: [Block] = []
        for (index, line) in lines.enumerated() where index < end && hasWord(line, "M", 6) {
            // Back over the quiet lines before M6 (T, M5, its dwell, the
            // message, blanks), never into the previous block.
            let floor = (blocks.last?.range.upperBound ?? -1) + 1
            var start = index
            while start > floor {
                let previous = lines[start - 1]
                let words = GCodeWords.scan(previous)
                let code = strippedOfComments(previous)
                let quiet = code.isEmpty || GCodeWords.message(in: previous) != nil
                    || words.allSatisfy { $0.letter == "T" || ($0.letter == "M" && $0.value == 5) || ($0.letter == "G" && $0.value == 4) || $0.letter == "P" || $0.letter == "S" }
                guard quiet, !GCodeWords.hasAxisWords(words) else { break }
                start -= 1
            }
            var finish = index
            var sawSpindle = false
            while finish + 1 < end {
                let next = lines[finish + 1]
                let words = GCodeWords.scan(next)
                guard !GCodeWords.hasAxisWords(words), !words.contains(where: { $0.letter == "F" }) else { break }
                let code = strippedOfComments(next)
                if code.isEmpty { finish += 1; continue }
                let spindleStart = words.contains { $0.letter == "M" && ($0.value == 3 || $0.value == 4) }
                let pause = words.contains { $0.letter == "M" && ($0.value == 0 || $0.value == 1) }
                let dwell = words.contains { $0.letter == "G" && $0.value == 4 }
                let speed = words.allSatisfy { $0.letter == "S" }
                if spindleStart { sawSpindle = true; finish += 1; continue }
                if pause || speed { finish += 1; continue }
                if dwell {
                    // The spin-up dwell ends the block; a dwell before the
                    // spindle start belongs to it too.
                    finish += 1
                    if sawSpindle { break }
                    continue
                }
                break
            }
            var block = Block(range: start...finish)
            var afterSpindle = false
            for i in start...finish {
                let words = GCodeWords.scan(lines[i])
                if let s = words.first(where: { $0.letter == "S" }) { block.rpm = s.value }
                if words.contains(where: { $0.letter == "M" && $0.value == 4 }) { block.clockwise = false }
                if words.contains(where: { $0.letter == "M" && ($0.value == 3 || $0.value == 4) }) { afterSpindle = true }
                if words.contains(where: { $0.letter == "G" && $0.value == 4 }), let p = words.first(where: { $0.letter == "P" }) {
                    if afterSpindle { block.spinUp = p.value } else if i < index { block.spinDown = p.value }
                }
                if let message = GCodeWords.message(in: lines[i]) { block.message = message }
            }
            blocks.append(block)
        }
        return blocks
    }

    /// Index of the first footer line: the trailing run of spindle-off,
    /// coolant-off, program-end, dwell, blank and comment lines.
    private static func footerStart(_ lines: [String]) -> Int {
        var start = lines.count
        while start > 0 {
            let line = lines[start - 1]
            let code = strippedOfComments(line)
            if code.isEmpty { start -= 1; continue }
            let words = GCodeWords.scan(line)
            let footerWord = words.allSatisfy {
                ($0.letter == "M" && [2, 5, 9, 30].contains(Int($0.value))) || ($0.letter == "G" && $0.value == 4) || $0.letter == "P"
            }
            guard footerWord, !words.isEmpty else { break }
            start -= 1
        }
        return start
    }

    private static func isHeaderWord(_ word: GCodeWords.Word) -> Bool {
        switch word.letter {
        case "G": return [94, 21, 90, 91.1, 17, 54, 40, 80, 0].contains(word.value)
        case "S": return true
        default: return false
        }
    }

    private static func hasWord(_ line: String, _ letter: Character, _ value: Double) -> Bool {
        GCodeWords.scan(line).contains { $0.letter == letter && $0.value == value }
    }

    private static func isBanner(_ comment: String) -> Bool {
        let lower = comment.lowercased()
        return lower.contains("pcb2gcode") || lower.contains("software-independent") || lower.contains("native engine")
            || lower.contains("g64 should not")
    }

    /// The text of a `( … )` comment line, parentheses removed.
    private static func commentText(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("(") { text.removeFirst() }
        if text.hasSuffix(")") { text.removeLast() }
        if text.hasPrefix(";") { text.removeFirst() }
        return text.trimmingCharacters(in: .whitespaces)
    }

    static func strippedOfComments(_ line: String) -> String {
        var out = ""
        var depth = 0
        for c in line {
            if c == "(" { depth += 1; continue }
            if c == ")" { depth = max(0, depth - 1); continue }
            if c == ";" { break }
            if depth == 0 { out.append(c) }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// The firmware's file reader discards any line over 128 characters,
    /// so a long comment is wrapped into several `( … )` lines (joined with
    /// newlines here; the file is joined on newlines anyway).
    static let maxCommentWidth = 96

    /// A comment the firmware's 8-bit parser is happy with: ASCII only, no
    /// nested parentheses, wrapped at `maxCommentWidth`.
    static func comment(_ text: String) -> String {
        wrap(ascii(text)).map { "( " + $0 + " )" }.joined(separator: "\n")
    }

    private static func wrap(_ text: String) -> [String] {
        guard text.count > maxCommentWidth else { return [text] }
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if candidate.count > maxCommentWidth, !current.isEmpty {
                lines.append(current)
                current = "  " + word
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.map { $0.count > 120 ? String($0.prefix(120)) : $0 }
    }

    private static func ascii(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "(", with: "[").replacingOccurrences(of: ")", with: "]")
        for (from, to) in [("°", " deg"), ("·", "-"), ("—", "-"), ("–", "-"), ("→", "->"), ("Ø", "D"), ("µ", "u"), ("×", "x"), ("’", "'"), ("“", "\""), ("”", "\"")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        return String(s.unicodeScalars.map { $0.isASCII ? Character($0) : "?" })
    }

    /// Comments inside a code line made ASCII (the engines write `µ` and `—`).
    private static func asciiComments(_ line: String) -> String {
        line.unicodeScalars.allSatisfy(\.isASCII) ? line : String(line.unicodeScalars.map { $0.isASCII ? Character($0) : "?" })
    }

    static func timeText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h) h \(m) min" : "\(m) min"
    }
}
