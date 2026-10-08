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
                        .help("Rapids (G0) at a quarter speed — for the first run of a program, or to watch a move closely")
                    Button("50") { machine.overrideRapid(50) }
                        .help("Rapids (G0) at half speed")
                    Button("100") { machine.overrideRapid(100) }
                        .help("Rapids (G0) at full speed")
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
        .help(overrideHelp(title, range: range))
    }

    private func overrideHelp(_ title: String, range: String) -> String {
        switch title {
        case "Feed": "Scales every cutting feed (G1/G2/G3) of the running program, \(range). Slow down when the cut sounds laboured; the program itself is not changed."
        case "Rapid": "Scales the rapid (G0) moves, \(range). Lower it to watch a program's first run at a safe pace."
        default: "Scales the spindle speed (S), \(range) — the controller reports the percentage in use."
        }
    }

    private func stepButtons(minus10: @escaping () -> Void, minus1: @escaping () -> Void, reset: @escaping () -> Void,
                             plus1: @escaping () -> Void, plus10: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Button("−10", action: minus10)
                .help("10 % slower. Takes effect at once, even mid-program — the controller reports the value it is using.")
            Button("−1", action: minus1)
                .help("1 % slower")
            Button("100") { reset() }
                .help("Reset to 100 %")
            Button("+1", action: plus1)
                .help("1 % faster")
            Button("+10", action: plus10)
                .help("10 % faster. Takes effect at once, even mid-program — the controller reports the value it is using.")
        }
    }
}
