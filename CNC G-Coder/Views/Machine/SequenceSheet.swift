import SwiftUI

/// "Send Layers…": pick several of the project's programs to go to the
/// machine as one file. On a Carvera the tool changer swaps the bits
/// between them (`T<n> M6`), so a whole stage — mask etch, drills, holes,
/// cutout — runs without anyone touching the machine. The list is grouped
/// the way Generate's stage files are; a stage's header ticks it whole.
/// Load hands the ordered layers back (`AppModel.prepareMachineSequence`).
struct SequenceSheet: View {
    @ObservedObject var model: AppModel
    var initial: [LayerKind]
    var load: ([LayerKind]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<LayerKind> = []

    var body: some View {
        let plan = model.machinePlan()
        let preview = selected.isEmpty ? nil : model.machineSequencePreview(Array(selected))
        VStack(alignment: .leading, spacing: 12) {
            Text("Send several layers as one program")
                .font(.title3.weight(.semibold))
            Text("The layers run back to back in machining order — mask etch, drills, milled holes, cutout, drawn layers — and the tool changer swaps the bits between them. Tick a whole stage, or any set.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let plan {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(plan.stages) { stage in
                            stageBox(stage, plan: plan)
                        }
                    }
                }
                .frame(maxHeight: 360)
                summary(preview)
            } else {
                Text("No Carvera preview: pick a Makera Carvera under Machine setup → Machine and let the preview generate.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Load", systemImage: "square.stack.3d.up") {
                    load(preview?.ref.layers ?? Array(selected))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(preview == nil)
                .help("Prepare the chosen layers as one program; Send in the Program tab streams it")
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear {
            selected = Set(initial)
            if selected.isEmpty, let first = plan?.stages.first(where: { !$0.stage.isIsolation }) ?? plan?.stages.first {
                selected = Set(first.programs.map(\.layer))
            }
        }
    }

    private func stageBox(_ stage: MachinePost.StagePlan, plan: MachinePost.Plan) -> some View {
        let kinds = stage.programs.map(\.layer)
        let all = kinds.allSatisfy { selected.contains($0) }
        return GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(stage.programs, id: \.layer) { program in
                    Toggle(isOn: binding(program.layer)) {
                        HStack {
                            Text(program.layer.displayName)
                            Spacer()
                            Text(slotsText(program, plan: plan))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(formatDuration(program.estimatedTime))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .trailing)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(.vertical, 2)
        } label: {
            HStack {
                Text("Stage \(stage.stage.code) · \(stage.title)")
                    .font(.headline)
                Spacer()
                Button(all ? "Clear" : "Whole stage") {
                    if all { selected.subtract(kinds) } else { selected.formUnion(kinds) }
                }
                .controlSize(.small)
                .help(all ? "Untick these layers" : "Tick every layer of this stage")
            }
        }
    }

    @ViewBuilder
    private func summary(_ preview: MachinePost.Sequence?) -> some View {
        if let preview {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(preview.ref.code) · \(preview.ref.title)")
                    .font(.callout.weight(.semibold))
                Text(preview.ref.layers.map(\.displayName).joined(separator: " → "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Rack slots \(preview.stage.slots.map { "T\($0)" }.joined(separator: " ")) · \(max(preview.stage.slots.count - 1, 0)) tool change\(preview.stage.slots.count == 2 ? "" : "s") · est. \(formatDuration(preview.stage.estimatedTime))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                ForEach(preview.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            Text("Tick at least one layer.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func slotsText(_ program: MachinePost.Program, plan: MachinePost.Plan) -> String {
        let context = model.machineContext(snapshot: model.parameters.snapshot(), files: model.detectedFiles, customLayers: model.customLayers)
        let slots = MachinePost.bits(of: program, context: context).compactMap { plan.slot(for: $0.key) }
        return slots.map { "T\($0)" }.joined(separator: " ")
    }

    private func binding(_ kind: LayerKind) -> Binding<Bool> {
        Binding(get: { selected.contains(kind) },
                set: { on in if on { selected.insert(kind) } else { selected.remove(kind) } })
    }
}
