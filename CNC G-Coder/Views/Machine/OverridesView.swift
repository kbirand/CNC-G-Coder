import SwiftUI

/// Feed (10–200 %), rapid (25/50/100 %) and spindle (50–200 %) overrides.
/// The buttons send the real-time bytes directly; the percentages shown are
/// what the controller reports back in `Ov:`, never a local guess.
struct OverridesView: View {
    @Bindable var machine: MachineController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MachineSectionLabel(title: "Overrides")
            overrideRow("Feed", value: machine.status.overrides?.feed, range: "10–200 %") {
                stepButtons(minus10: { machine.overrideFeed(-10) }, minus1: { machine.overrideFeed(-1) },
                            reset: { machine.overrideFeed(0) }, plus1: { machine.overrideFeed(1) }, plus10: { machine.overrideFeed(10) })
            }
            overrideRow("Rapid", value: machine.status.overrides?.rapid, range: "25/50/100 %") {
                HStack(spacing: 4) {
                    Button("25") { machine.overrideRapid(25) }
                    Button("50") { machine.overrideRapid(50) }
                    Button("100") { machine.overrideRapid(100) }
                }
            }
            overrideRow("Spindle", value: machine.status.overrides?.spindle, range: "50–200 %") {
                stepButtons(minus10: { machine.overrideSpindle(-10) }, minus1: { machine.overrideSpindle(-1) },
                            reset: { machine.overrideSpindle(0) }, plus1: { machine.overrideSpindle(1) }, plus10: { machine.overrideSpindle(10) })
            }
        }
        .controlSize(.small)
        .disabled(!machine.isConnected)
        .machinePanel()
    }

    private func overrideRow<Buttons: View>(_ title: String, value: Int?, range: String, @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 50, alignment: .leading)
            Text(value.map { "\($0) %" } ?? "— %")
                .font(.system(.body, design: .monospaced))
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
                .foregroundStyle(value == nil || value == 100 ? .secondary : .primary)
            Spacer(minLength: 0)
            buttons()
        }
        .help("\(title) override, \(range)")
    }

    private func stepButtons(minus10: @escaping () -> Void, minus1: @escaping () -> Void, reset: @escaping () -> Void,
                             plus1: @escaping () -> Void, plus10: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Button("−10", action: minus10)
            Button("−1", action: minus1)
            Button("100") { reset() }
                .help("Reset to 100 %")
            Button("+1", action: plus1)
            Button("+10", action: plus10)
        }
    }
}
