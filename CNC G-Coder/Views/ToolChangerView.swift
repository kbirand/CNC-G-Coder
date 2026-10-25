import SwiftUI

/// The machine's tool changer, slot by slot: which library bit sits in T1,
/// T2… (`ToolLibrary.rack`). Machine state, not project state — it outlives
/// projects, and the rack numbering of every job follows it (a loaded bit
/// keeps its slot; the rest are numbered around it), the Tool menus list
/// the loaded bits first, and the Machine panel names the tool in the
/// spindle from it. "Load this job's rack" copies the current plan into
/// the slots, the quick way after loading the changer for a board.
struct ToolChangerView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var params: ParametersStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKeys.unitSystem) private var unitRaw = UnitSystem.metric.rawValue

    private var library: ToolLibrary { model.tools }
    private var slotCount: Int {
        max(params.profile.toolChange.automaticSlots ?? 6, library.rack.keys.max() ?? 0)
    }

    var body: some View {
        let plan = model.machinePlan()
        VStack(alignment: .leading, spacing: 12) {
            Text("Tool changer")
                .font(.title3.weight(.semibold))
            Text("What sits in the \(params.profile.name)'s rack right now. A bit loaded here keeps its slot in every job, the Tool menus offer it under “Tool changer”, and the Machine panel names it. A layer set by hand asks for a shape and size — any library bit of that shape and size counts as loaded. T0 is the wireless probe and stays free.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                ForEach(1...slotCount, id: \.self) { slot in
                    GridRow {
                        Text("T\(slot)")
                            .font(.body.weight(.semibold).monospaced())
                            .frame(width: 32, alignment: .leading)
                        slotMenu(slot)
                        usageView(slot, plan: plan)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if library.rack[slot] != nil {
                            Button {
                                library.rack[slot] = nil
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Empty this slot")
                        } else {
                            Color.clear.frame(width: 16, height: 1)
                        }
                    }
                }
            }
            if let plan, !plan.rack.isEmpty {
                let missing = plan.rack.filter { !$0.loaded }
                if missing.isEmpty {
                    Label("Every bit of this job is loaded in its slot.", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Label("This job still needs: " + missing.map { "T\($0.slot) \($0.bit.label)" }.joined(separator: ", "), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button("Load This Job's Rack") { loadJobRack(plan) }
                    .disabled(plan?.rack.isEmpty ?? true)
                    .help("Assigns every bit of the current job to the slot the rack list gives it — what to do after loading the changer for this board. Slots the job does not use are left as they are.")
                Button("Empty All") { library.rack = [:] }
                    .disabled(library.rack.isEmpty)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720)
    }

    private func slotMenu(_ slot: Int) -> some View {
        let current = library.rackTool(slot: slot)
        return Menu {
            let groups = ToolMenuContent.groups(of: library.tools)
            if groups.count <= 1 {
                toggles(library.tools, slot: slot, current: current)
            } else {
                toggles(library.tools.filter { $0.group.isEmpty }, slot: slot, current: current)
                ForEach(groups.filter { !$0.isEmpty }, id: \.self) { group in
                    Menu(group) { toggles(library.tools.filter { $0.group == group }, slot: slot, current: current) }
                }
            }
            Divider()
            Toggle("Empty", isOn: Binding(get: { current == nil }, set: { _ in library.rack[slot] = nil }))
        } label: {
            Text(current.map { "\($0.name)  ·  \(detail($0))" } ?? String(localized: "Empty"))
                .foregroundStyle(current == nil ? Color.secondary : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(width: 260, alignment: .leading)
        .help("The bit in slot T\(slot). A bit can sit in one slot only: picking it here frees the slot it had.")
    }

    private func toggles(_ tools: [MachineTool], slot: Int, current: MachineTool?) -> some View {
        ForEach(tools) { tool in
            Toggle(isOn: Binding(get: { current?.id == tool.id }, set: { _ in assign(tool, to: slot) })) {
                Text("\(tool.name)  ·  \(detail(tool))" + (library.rackSlot(of: tool).map { $0 == slot ? "" : "  (T\($0))" } ?? ""))
            }
        }
    }

    private func assign(_ tool: MachineTool, to slot: Int) {
        var rack = library.rack
        if let previous = library.rackSlot(of: tool) { rack[previous] = nil }
        rack[slot] = tool.id
        library.rack = rack
    }

    private func loadJobRack(_ plan: MachinePost.Plan?) {
        guard let plan else { return }
        var rack = library.rack
        for entry in plan.rack {
            guard let tool = library.tool(forBitKey: entry.bit.key) else { continue }
            if let previous = rack.first(where: { $0.value == tool.id })?.key { rack[previous] = nil }
            rack[entry.slot] = tool.id
        }
        library.rack = rack
    }

    /// What the current job does with this slot: the programs when the
    /// loaded bit serves them; otherwise what they need — the library bit
    /// by name, or the shape and size a hand-set layer asks for — with the
    /// matching library bits one click away.
    @ViewBuilder
    private func usageView(_ slot: Int, plan: MachinePost.Plan?) -> some View {
        if let entry = plan?.rack.first(where: { $0.slot == slot }) {
            if entry.loaded {
                Text(entry.programs.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                let candidates = library.candidates(forBitKey: entry.bit.key, tolerance: Double(params.drillBitTolerance) ?? 0.1,
                                                    holeAllowance: Double(params.drillHoleAllowance) ?? 0)
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.programs.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(entry.bit.key.hasPrefix("id:")
                             ? String(localized: "needs \(entry.bit.label)")
                             : String(localized: "needs any \(entry.bit.label)"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if candidates.count == 1, let only = candidates.first {
                        Button(String(localized: "Load \(only.name)")) { assign(only, to: slot) }
                            .controlSize(.small)
                            .lineLimit(1)
                            .help("Put this library bit in T\(slot)")
                    } else if candidates.count > 1 {
                        Menu {
                            ForEach(candidates) { tool in
                                Button("\(tool.name)  ·  \(detail(tool))") { assign(tool, to: slot) }
                            }
                        } label: {
                            Text("Load…")
                        }
                        .controlSize(.small)
                        .fixedSize()
                        .help("\(candidates.count) library bits of this shape and size — pick the one you are putting in T\(slot)")
                    } else {
                        Text("no such bit in the library")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Add one in the Tool Library, or set the layer from a library bit so the job asks for it by name")
                    }
                }
            }
        }
    }

    private func detail(_ tool: MachineTool) -> String {
        let units = UnitSystem(rawValue: unitRaw) ?? .metric
        let size = "\(units.length(tool.listDiameter)) \(units.lengthSymbol)"
        return tool.shape == .vBit ? "V \(ParametersStore.format(tool.tipAngle))° → \(size)" : "Ø \(size)"
    }
}
