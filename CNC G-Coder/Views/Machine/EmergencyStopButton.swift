import SwiftUI

/// The big red button: `MachineController.emergencyStop()` — jog cancel,
/// feed hold and soft reset in one write, no waiting. Full width in the
/// Machine panel's fixed header (under the DRO, so it is there on every
/// tab); `compact` is the shorter variant at the right end of the job bar.
/// Enabled whenever connected. ⇧⌘. (View → Emergency Stop) does the same.
struct EmergencyStopButton: View {
    @Bindable var machine: MachineController
    var compact: Bool = false

    var body: some View {
        Button {
            machine.emergencyStop()
        } label: {
            Label("E-STOP", systemImage: "exclamationmark.octagon.fill")
                .font((compact ? Font.callout : .headline).weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, compact ? 14 : 0)
                .frame(maxWidth: compact ? nil : .infinity)
                .frame(height: compact ? 36 : 44)
                .background(Color.red.opacity(machine.isConnected ? 1 : 0.35),
                            in: RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!machine.isConnected)
        .help("Emergency stop (⇧⌘.): jog cancel, feed hold and reset at once — the position is lost if the machine was moving")
        .accessibilityLabel("Emergency stop")
    }
}
