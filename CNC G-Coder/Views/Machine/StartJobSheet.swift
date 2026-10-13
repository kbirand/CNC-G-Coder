import SwiftUI

/// The reminder Send shows before a program streams: which layer is about
/// to be milled — name, file, side (back-side programs get a flip
/// reminder), tool, depth, estimated time, tool changes — what the streamed
/// copy carries (height map, backlash, Z clamp) and where the machine
/// stands. Start runs the pre-flight again and streams. Settings → Machine
/// "Confirm the layer before sending a program" (or the toggle at the
/// bottom) turns the sheet off; the dev hooks start without it.
struct StartJobSheet: View {
    @Bindable var machine: MachineController
    var program: MachineProgram
    @Environment(\.dismiss) private var dismiss

    @AppStorage(MachineSettings.Keys.confirmSend) private var confirmSend = MachineSettings.Defaults.confirmSend
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Start milling?")
                .font(.title3.weight(.semibold))
            layerBlock
            Divider()
            details
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Toggle("Ask before every send", isOn: $confirmSend)
                    .controlSize(.small)
                    .help("Off: Send streams at once. Settings → Machine turns the reminder back on.")
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help("Close without sending")
                Button("Start", systemImage: "paperplane.fill") { start() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!machine.isConnected || machine.streamer.isActive)
                    .help("Stream \(program.name) to the machine now")
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    // MARK: Pieces

    private var layerBlock: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: program.kind.isBackSide ? "rectangle.portrait.rotate" : "rectangle.portrait")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(program.kind.isBackSide ? Color.orange : Color.accentColor)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(program.kind.displayName)
                    .font(.title2.weight(.bold))
                Text(program.name)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                if program.kind.isBackSide {
                    Label("Back side — the board must be flipped, back copper up", systemImage: "arrow.uturn.backward")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("Front side", systemImage: "checkmark")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var details: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            row("Tool", toolText)
            row("Depth", depthText)
            row("Time", timeText)
            row("Streamed", streamedText)
            row("Machine", machineText)
        }
        .font(.callout)
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The source layer's bit and the number of tool changes (segments − 1:
    /// pcb2gcode writes a T, M6 and M0 line per change, so the line count
    /// would overstate it).
    private var toolText: String {
        let size = program.parsed.toolDiameter.map { String(localized: "Ø \(formatMM($0)) mm") } ?? String(localized: "as in the program")
        let changes = max(program.segments.count - 1, 0)
        let changeText = switch changes {
        case 0: String(localized: "no tool change")
        case 1: String(localized: "1 tool change")
        default: String(localized: "\(changes) tool changes")
        }
        return size + " · " + changeText
    }

    private var depthText: String {
        let p = program.parsed
        return String(localized: "cuts to Z \(formatMM(p.zMin)) mm · travel at Z \(formatMM(program.safeZ)) mm")
    }

    private var timeText: String {
        String(localized: "\(formatDuration(program.parsed.totalTime)) estimated · \(program.lines.count) lines")
    }

    private var streamedText: String {
        var parts: [String] = []
        if program.options.heightMap != nil { parts.append(String(localized: "height map applied")) }
        if program.backlashApplied { parts.append(String(localized: "backlash compensated")) }
        if program.options.clampZAboveWork != nil { parts.append(String(localized: "Z clamped to the top of travel")) }
        if program.options.fitArcs { parts.append(String(localized: "arcs fitted")) }
        return parts.isEmpty ? String(localized: "as generated") : parts.joined(separator: " · ")
    }

    private var machineText: String {
        let state = machine.machineState.name
        guard let work = machine.status.workPosition else { return state }
        return state + " · " + String(localized: "work X\(formatMM(work.x)) Y\(formatMM(work.y)) Z\(formatMM(work.z))")
    }

    // MARK: Action

    private func start() {
        if let refusal = machine.preflight(program) {
            problem = refusal
            return
        }
        dismiss()
        Task { await machine.streamer.start() }
    }
}
