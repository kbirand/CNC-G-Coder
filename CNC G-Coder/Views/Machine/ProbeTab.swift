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
    @State private var carveraProbing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            zProbeSection
            toolReferenceSection
            lastProbeSection
            edgeProbeSection
        }
    }

    // MARK: Z probe

    private var zProbeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            MachineSectionLabel(title: "Z probe")
            Text(machine.isCarvera
                 ? "The Carvera probes with its wireless probe, no clip: position the spindle over the board, press Probe with the Carvera, and the machine fetches the probe, touches the surface twice, sets work Z0 there and retracts. Probe Z below is the plain G38.2 probe for a bit wired to the probe input."
                 : "Clip the probe lead to the board, position the bit over bare copper, then probe. The fast pass finds the surface, the slow pass refines it; work Z then reads the plate thickness at the trigger point.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if machine.isCarvera {
                HStack(spacing: 10) {
                    Button {
                        runCarveraProbe()
                    } label: {
                        Label(carveraProbing ? "Probing…" : "Probe with the Carvera", systemImage: "scope")
                            .frame(minWidth: 100)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(carveraProbing || probing || !machine.isConnected || machine.streamer.isActive || machine.status.workPosition == nil)
                    .help("M495 at the spindle's work XY: the firmware changes to its wireless probe (T0), probes fast and slow, sets work Z0 at the surface and retracts. The probe must be in its rack slot.")
                    if carveraProbing { ProgressView().controlSize(.small) }
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Max travel")
                        .help("How far down the probe may go before it gives up. A little more than the gap between the bit and the board; the probe fails without an alarm if nothing is touched.")
                    numberField($maxTravel, unit: "mm",
                                help: "How far down the probe may go (G38.2 Z−…) before it gives up. A little more than the gap between the bit and the board; the probe fails without an alarm if nothing is touched.")
                }
                GridRow {
                    Text("Retract after")
                        .help("How far the bit backs off after the fast pass (before the slow one) and after the last pass")
                    numberField($retract, unit: "mm",
                                help: "How far the bit backs off after the fast pass (before the slow one) and after the last pass")
                }
                GridRow {
                    Text("Fast feed")
                        .help("Speed of the first pass, which only has to find the surface")
                    numberField($feedFast, unit: "mm/min",
                                help: "Speed of the first pass, which only has to find the surface")
                }
                GridRow {
                    Text("Slow feed")
                        .help("Speed of the second pass, which sets the Z — slower is more precise (20 mm/min is typical)")
                    numberField($feedSlow, unit: "mm/min",
                                help: "Speed of the second pass, which sets the Z — slower is more precise (20 mm/min is typical)")
                }
                GridRow {
                    Text("Plate thickness")
                        .help("What work Z reads at the trigger point: 0 for the bit touching the copper itself, the plate's thickness when probing through a touch plate laid on the board")
                    HStack(spacing: 8) {
                        numberField($plateThickness, unit: "mm",
                                    help: "What work Z reads at the trigger point: 0 for the bit touching the copper itself, the plate's thickness when probing through a touch plate laid on the board")
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
                .help(refusal ?? String(localized: "Probe down twice (fast, back off, slow) and set work Z at the trigger point — immune to overshoot. Keep a hand near the stop: the probe lead must be clipped on."))
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

    private func numberField(_ value: Binding<Double>, unit: LocalizedStringKey, help: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            TextField("", value: value, format: .number.precision(.fractionLength(0...3)).grouping(.never))
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .multilineTextAlignment(.trailing)
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
        .help(help)
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

    private func runCarveraProbe() {
        guard let work = machine.status.workPosition else { return }
        carveraProbing = true
        resultMessage = nil
        Task {
            let failure = await machine.carveraProbeZ(atWork: CGPoint(x: work.x, y: work.y))
            carveraProbing = false
            resultIsFailure = failure != nil
            resultMessage = failure ?? String(localized: "Probed with the Carvera's probe — work Z0 is on the surface there.")
        }
    }

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

    // MARK: Tool reference

    @State private var referenceBusy = false
    @State private var referenceResult: String?
    @State private var referenceFailed = false
    @State private var toolReference = MachineSettings.toolReference

    /// The off-board Z reference: set while work Z0 is valid, probe after a
    /// bit change (or once the board is masked) to restore that Z0 from the
    /// contact difference. The spot is a machine property (`MachineSettings
    /// .toolReference`), like backlash.
    private var toolReferenceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            MachineSectionLabel(title: "Tool reference")
            Text("A fixed block or switch-type setter on the bed, wired in parallel with the probe. Set it once while work Z0 sits on bare copper; after a bit change — or once the board is solder-masked and cannot be probed — probing it restores Z0 by the contact difference and re-anchors the height map.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let reference = toolReference {
                HStack(spacing: 12) {
                    Text("machine X\(formatMM(reference.x)) Y\(formatMM(reference.y)) · contact Z\(formatMM(reference.contactZ))")
                        .font(.system(.callout, design: .monospaced))
                    Spacer()
                    Text(reference.savedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button {
                        runReference(restore: true)
                    } label: {
                        Label(referenceBusy ? "Probing…" : "Probe & Restore Z0", systemImage: "arrow.uturn.down")
                            .frame(minWidth: 130)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(referenceBusy || refusal != nil)
                    .help("Move to the reference at the safe height, probe it, and shift work Z0 by the difference to the stored contact — the new bit's length is absorbed and the height map re-anchored")
                    if referenceBusy { ProgressView().controlSize(.small) }
                }
                HStack(spacing: 10) {
                    Button("Re-set Here") { runReference(restore: false) }
                        .disabled(referenceBusy || refusal != nil)
                        .help("Probe down at the current position and remember the contact together with the current work Z0 — do it while Z0 is freshly probed on the surface that matters")
                    Button("Clear", role: .destructive) {
                        MachineSettings.toolReference = nil
                        toolReference = nil
                        referenceResult = nil
                    }
                    .disabled(referenceBusy)
                    .help("Forget the stored reference")
                }
            } else {
                Text("No reference set. Jog the bit a few millimetres above the spot, then:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button {
                        runReference(restore: false)
                    } label: {
                        Label(referenceBusy ? "Probing…" : "Set Reference Here", systemImage: "mappin.and.ellipse")
                            .frame(minWidth: 130)
                    }
                    .disabled(referenceBusy || refusal != nil)
                    .help("Probe down at the current position and remember the contact together with the current work Z0 — do it while Z0 is freshly probed on the surface that matters")
                    if referenceBusy { ProgressView().controlSize(.small) }
                }
            }
            if let referenceResult {
                Label(referenceResult, systemImage: referenceFailed ? "xmark.octagon.fill" : "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(referenceFailed ? .red : .green)
            }
        }
        .machinePanel()
    }

    private func runReference(restore: Bool) {
        referenceBusy = true
        referenceResult = nil
        Task {
            let failure = restore ? await machine.probeToolReference() : await machine.setToolReference()
            referenceBusy = false
            toolReference = MachineSettings.toolReference
            referenceFailed = failure != nil
            referenceResult = failure ?? (restore
                ? String(localized: "Work Z0 restored from the reference.")
                : String(localized: "Reference stored — probe it after the next bit change."))
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
            Text("Finding the board's XY edges with the bit — a fast touch, back off, a slow touch, on each edge — is planned for a later release. For now, jog to the corner and use Zero XY.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .machinePanel()
        .opacity(0.7)
    }
}
