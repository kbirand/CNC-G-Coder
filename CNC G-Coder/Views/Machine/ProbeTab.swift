import SwiftUI

/// Z probing: the bit touches the copper with a clip on the board (plate
/// thickness 0), or a touch plate on the mask side. Two passes (fast, back
/// off, slow), then the work origin is placed at the trigger point with
/// `G10 L2` — immune to overshoot. The settings here are the app-wide
/// `machine.probe.*` keys, shared with the Settings pane.
struct ProbeTab: View {
    @Bindable var machine: MachineController

    var body: some View {
        ScrollView {
            ProbeControls(machine: machine)
                .padding(16)
                .frame(maxWidth: 640, alignment: .leading)
        }
    }
}

/// The probe form itself — the window's tab and the main window's panel
/// section both show it; it lays out in a column about 380 pt wide.
struct ProbeControls: View {
    @Bindable var machine: MachineController

    @AppStorage(MachineSettings.Keys.probeFeedFast) private var feedFast = MachineSettings.Defaults.probeFeedFast
    @AppStorage(MachineSettings.Keys.probeFeedSlow) private var feedSlow = MachineSettings.Defaults.probeFeedSlow
    @AppStorage(MachineSettings.Keys.probeMaxTravel) private var maxTravel = MachineSettings.Defaults.probeMaxTravel
    @AppStorage(MachineSettings.Keys.probeRetract) private var retract = MachineSettings.Defaults.probeRetract
    @AppStorage(MachineSettings.Keys.probePlateThickness) private var plateThickness = MachineSettings.Defaults.probePlateThickness

    @State private var probing = false
    @State private var resultMessage: String?
    @State private var resultIsFailure = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            zProbeSection
            lastProbeSection
            edgeProbeSection
        }
    }

    // MARK: Z probe

    private var zProbeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            MachineSectionLabel(title: "Z probe")
            Text("Clip the probe lead to the board, position the bit over bare copper, then probe. The fast pass finds the surface, the slow pass refines it; work Z then reads the plate thickness at the trigger point.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Max travel")
                    numberField($maxTravel, unit: "mm")
                }
                GridRow {
                    Text("Retract after")
                    numberField($retract, unit: "mm")
                }
                GridRow {
                    Text("Fast feed")
                    numberField($feedFast, unit: "mm/min")
                }
                GridRow {
                    Text("Slow feed")
                    numberField($feedSlow, unit: "mm/min")
                }
                GridRow {
                    Text("Plate thickness")
                    HStack(spacing: 8) {
                        numberField($plateThickness, unit: "mm")
                        Text("0 = bit on copper").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .controlSize(.small)
            HStack(spacing: 10) {
                Button {
                    runProbe()
                } label: {
                    Label(probing ? "Probing…" : "Probe Z", systemImage: "arrow.down.to.line")
                        .frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canProbe)
                if probing { ProgressView().controlSize(.small) }
                if machine.status.pins.contains("P") {
                    Label("Probe input closed", systemImage: "bolt.horizontal.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            if let reason = refusal {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let resultMessage {
                Label(resultMessage, systemImage: resultIsFailure ? "xmark.octagon.fill" : "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(resultIsFailure ? .red : .green)
            }
        }
        .machinePanel()
    }

    private func numberField(_ value: Binding<Double>, unit: String) -> some View {
        HStack(spacing: 4) {
            TextField("", value: value, format: .number.precision(.fractionLength(0...3)).grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .multilineTextAlignment(.trailing)
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var spec: ZProbeSpec {
        ZProbeSpec(maxTravel: maxTravel, feedFast: feedFast, feedSlow: feedSlow, retract: retract, plateThickness: plateThickness)
    }

    /// How far Z can still go down in machine coordinates, when the range is known.
    private var remainingZTravel: Double? {
        guard let range = machine.axisRanges[.z], let mpos = machine.status.machinePosition else { return nil }
        return mpos.z - range.lowerBound
    }

    private var refusal: String? {
        guard machine.isConnected else { return "Not connected." }
        if let reason = ProbeRoutines.validate(spec, remainingZTravel: remainingZTravel) { return reason }
        if machine.status.pins.contains("P") { return "Probe already triggered — the bit is touching, or the lead is shorted." }
        if !machine.positionTrusted { return "Position may be lost — home first." }
        if machine.jobLocksControls { return "A program is running." }
        if machine.alarmCode != nil { return "Clear the alarm first." }
        if !machine.canProbe { return "The machine must be idle with a known work offset." }
        return nil
    }

    private var canProbe: Bool { !probing && refusal == nil }

    private func runProbe() {
        probing = true
        resultMessage = nil
        Task {
            let failure = await machine.probeZ()
            probing = false
            if let failure {
                resultIsFailure = true
                resultMessage = failure
            } else {
                resultIsFailure = false
                let z = machine.lastProbe.map { " at machine Z\(formatMM($0.position.z))" } ?? ""
                resultMessage = "Probe OK\(z) — work Z now reads \(formatMM(plateThickness)) there."
            }
        }
    }

    // MARK: Last probe

    @ViewBuilder
    private var lastProbeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            MachineSectionLabel(title: "Last probe")
            if let probe = machine.lastProbe {
                HStack(spacing: 12) {
                    Image(systemName: probe.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(probe.success ? .green : .red)
                    Text(probe.position.summary)
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    Text(probe.date.formatted(date: .omitted, time: .standard))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("machine coordinates")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No [PRB:] received yet.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .machinePanel()
    }

    // MARK: Edge probing (later)

    private var edgeProbeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            MachineSectionLabel(title: "Edge / corner probe")
            Text("Finding the board's XY edges with the bit (Candle's two-pass edge probe) is planned for a later release. For now, jog to the corner and use Zero XY.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .machinePanel()
        .opacity(0.7)
    }
}
