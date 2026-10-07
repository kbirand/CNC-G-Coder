import SwiftUI

/// Type an absolute machine coordinate and drive there (`G53 G90 G1`, Z
/// first when rising, last when descending — `GRBLCommand.safeMoveLegs`).
struct GoToSheet: View {
    @Bindable var machine: MachineController
    @Environment(\.dismiss) private var dismiss

    @State private var texts: [Axis: String] = [:]
    @State private var feedText = ""
    @State private var confirm = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Go to coordinates")
                .font(.title3.weight(.semibold))
            Text("Target in machine coordinates (G53).")
                .font(.caption)
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                ForEach(Axis.allCases, id: \.self) { axis in
                    GridRow {
                        Text(axis.gcodeLetter).font(.headline).frame(width: 20)
                        TextField("0.000", text: binding(axis))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                        Text(rangeText(axis))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 130, alignment: .leading)
                        Button("Current") {
                            if let mpos = machine.status.machinePosition { texts[axis] = formatMM(mpos[axis]) }
                        }
                        .disabled(machine.status.machinePosition == nil)
                    }
                }
                GridRow {
                    Text("F").font(.headline).frame(width: 20)
                    TextField("500", text: $feedText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                    Text("mm/min").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Now at: \(machine.status.machinePosition?.summary ?? "—")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Go") { confirm = true }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!machine.positioningEnabled || target == nil || feed == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            if texts.isEmpty, let mpos = machine.status.machinePosition {
                for axis in Axis.allCases { texts[axis] = formatMM(mpos[axis]) }
            }
            if feedText.isEmpty { feedText = formatMM(MachineSettings.jogFeed, decimals: 0) }
        }
        .alert("Move to \(target?.summary ?? "")?", isPresented: $confirm) {
            Button("Go") { go() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Z moves first when the target is higher than the current Z, otherwise X and Y move first.")
        }
    }

    private func binding(_ axis: Axis) -> Binding<String> {
        Binding(get: { texts[axis] ?? "" }, set: { texts[axis] = $0 })
    }

    private var target: MachinePosition? {
        guard let x = parseNumber(texts[.x] ?? ""), let y = parseNumber(texts[.y] ?? ""), let z = parseNumber(texts[.z] ?? "") else { return nil }
        return MachinePosition(x: x, y: y, z: z)
    }

    private var feed: Double? {
        guard let f = parseNumber(feedText), f > 0 else { return nil }
        return f
    }

    private func rangeText(_ axis: Axis) -> String {
        guard let range = machine.axisRanges[axis] else { return "" }
        return "\(formatMM(range.lowerBound, decimals: 1)) … \(formatMM(range.upperBound, decimals: 1))"
    }

    private func go() {
        guard let target, let feed else { return }
        Task {
            do {
                try await machine.goTo(machine: target, feed: feed)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
