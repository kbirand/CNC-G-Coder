import SwiftUI

/// Named machine positions (port of the pendant's list), in two lists chosen
/// by the Machine / Work switch: **Machine** spots the spindle goes back to
/// (Save current…, Go with confirmation, Go to coordinates… for a typed
/// target) and **Work** zeros — the work origin as a machine point, saved by
/// hand (Save work zero) or by the app whenever a program is sent (Settings →
/// Machine), so the same origin can be re-established after a reset or
/// re-homing with Use as zero (`G10 L2 P0` at the stored point — no motion,
/// confirmed first). Rename / Overwrite / Delete in the context menu, drag to
/// reorder. The panel's Positions tab shows it `tall`; the Machine window's
/// pendant column keeps the short list.
struct PositionsSection: View {
    @Bindable var machine: MachineController
    var tall: Bool = false

    @AppStorage(MachineSettings.Keys.jogFeed) private var feed = MachineSettings.Defaults.jogFeed
    @AppStorage(MachineSettings.Keys.positionsKind) private var kindRaw = SavedPosition.Kind.machine.rawValue

    @State private var savePrompt: SavePrompt?
    @State private var newName = ""
    @State private var renaming: SavedPosition?
    @State private var renameText = ""
    @State private var pendingGoTo: SavedPosition?
    @State private var pendingZero: SavedPosition?
    @State private var showGoTo = false
    @State private var notice: Notice?

    private var store: SavedPositionsStore { machine.positions }
    private var kind: SavedPosition.Kind { SavedPosition.Kind(rawValue: kindRaw) ?? .machine }
    private var shown: [SavedPosition] { store.positions(of: kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            kindPicker
            hint
            list
            if let error = store.lastSaveError {
                Text("Could not save positions: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .controlSize(.small)
        .machinePanel()
        .modifier(PositionAlerts(savePrompt: $savePrompt, newName: $newName, renaming: $renaming, renameText: $renameText,
                                 pendingGoTo: $pendingGoTo, pendingZero: $pendingZero, notice: $notice,
                                 feed: feed, store: store, goTo: goTo, useAsZero: useAsZero))
        .sheet(isPresented: $showGoTo) {
            GoToSheet(machine: machine)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            MachineSectionLabel(title: "Positions", detail: shown.isEmpty ? nil : "\(shown.count)")
            switch kind {
            case .machine:
                Button("Save current…", systemImage: "plus") {
                    guard let mpos = machine.status.machinePosition else { return }
                    newName = "Position \(shown.count + 1)"
                    savePrompt = SavePrompt(title: String(localized: "Save position"), position: mpos)
                }
                .disabled(!machine.isConnected || machine.status.machinePosition == nil)
                .help("Store the machine coordinates the spindle is at now")
                Button("Go to…", systemImage: "location") { showGoTo = true }
                    .help("Type a machine coordinate and move there")
                    .disabled(!machine.isConnected)
            case .workZero:
                Button("Save work zero", systemImage: "scope") { saveWorkZero() }
                    .disabled(!machine.isConnected)
                    .help("Store where work X0 Y0 Z0 is in machine coordinates, so the zero can be restored later with Use as zero")
            }
        }
    }

    private var kindPicker: some View {
        Picker("Positions list", selection: $kindRaw) {
            Text("Machine").tag(SavedPosition.Kind.machine.rawValue)
            Text("Work").tag(SavedPosition.Kind.workZero.rawValue)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Machine: spots the spindle returns to. Work: saved work origins, to restore a zero after a reset or re-homing")
    }

    private var hint: some View {
        Group {
            switch kind {
            case .machine:
                Text("Spots in machine coordinates the spindle can go back to — a parking place, the tool-change spot, the probe clip.")
            case .workZero:
                Text(MachineSettings.autoSaveWorkZero
                     ? "Where work X0 Y0 Z0 was, in machine coordinates. Every Send records one, named after the program and the time (Settings → Machine); Use as zero restores that origin after a reset or re-homing."
                     : "Where work X0 Y0 Z0 was, in machine coordinates. Use as zero restores that origin after a reset or re-homing. Settings → Machine can record one automatically whenever a program is sent.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var list: some View {
        if shown.isEmpty {
            Group {
                switch kind {
                case .machine:
                    Text("No machine positions yet. Jog to a spot and click Save current.")
                case .workZero:
                    Text("No work zeros yet. Zero the machine on the board and click Save work zero — or send a program with the automatic save on.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        } else {
            List {
                ForEach(shown) { saved in
                    row(for: saved)
                        .listRowInsets(EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4))
                }
                .onMove { source, destination in store.move(fromOffsets: source, toOffset: destination, in: kind) }
                .onDelete { offsets in store.delete(at: offsets, in: kind) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: min(CGFloat(shown.count) * 36 + 8, tall ? 420 : 150))
            .id(kind)
        }
    }

    private func row(for saved: SavedPosition) -> some View {
        HStack(spacing: 8) {
            Image(systemName: saved.kind == .workZero ? (saved.automatic ? "clock.badge.checkmark" : "scope") : "mappin.circle.fill")
                .foregroundStyle(Color.accentColor)
                .help(saved.automatic ? "Recorded by the app when this program was sent" : "")
            VStack(alignment: .leading, spacing: 0) {
                Text(saved.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(saved.position.summary)
                    .font(.system(size: 10, design: .monospaced).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            switch saved.kind {
            case .machine:
                Button("Go") { pendingGoTo = saved }
                    .buttonStyle(.borderedProminent)
                    .disabled(!machine.positioningEnabled)
                    .help(machine.positioningEnabled
                          ? "Move there at the jog feed, after a confirmation — Z first when rising, last when descending. Right-click the row to rename, overwrite or delete it."
                          : "Needs the machine connected, idle, not in alarm, and a trusted (homed) position")
            case .workZero:
                Button("Use as zero", systemImage: "scope") { pendingZero = saved }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSetZero)
                    .help("Make this machine point the work origin again (G10 L2) — the machine does not move. Right-click the row to rename, overwrite or delete it.")
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            switch saved.kind {
            case .machine:
                Button("Use as Work Zero…", systemImage: "scope") { pendingZero = saved }
                    .disabled(!canSetZero)
                Button("Overwrite with Current Position", systemImage: "arrow.triangle.2.circlepath") {
                    if let mpos = machine.status.machinePosition { store.overwrite(saved.id, with: mpos) }
                }
                .disabled(machine.status.machinePosition == nil)
            case .workZero:
                Button("Go There…", systemImage: "location") { pendingGoTo = saved }
                    .disabled(!machine.positioningEnabled)
                Button("Overwrite with Current Work Zero", systemImage: "scope") {
                    if let wco = machine.workOffset { store.overwrite(saved.id, with: wco) }
                }
                .disabled(machine.workOffset == nil)
            }
            Button("Rename…", systemImage: "pencil") {
                renameText = saved.name
                renaming = saved
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { store.delete(saved.id) }
        }
    }

    /// `G10 L2` needs the controller idle (or handed back for a tool change)
    /// and not in alarm; the position itself need not be trusted — that is
    /// the point of restoring the zero after a re-home.
    private var canSetZero: Bool {
        machine.isConnected && !machine.jobBlocksCommands && machine.alarmCode == nil
            && (machine.machineState == .idle || machine.streamer.isSuspended)
    }

    private func saveWorkZero() {
        guard let wco = machine.workOffset else {
            notice = Notice(title: "Work offset unknown",
                            text: "The controller has not reported its work offset yet. Wait for a status report (or query $#) and try again.")
            return
        }
        newName = String(localized: "Work zero") + " " + Date.now.formatted(date: .abbreviated, time: .shortened)
        savePrompt = SavePrompt(title: String(localized: "Save work zero"), position: wco, kind: .workZero)
    }

    private func goTo(_ position: MachinePosition) {
        let feed = self.feed
        Task {
            do { try await machine.goTo(machine: position, feed: feed) } catch {
                notice = Notice(title: "Could not move", text: error.localizedDescription)
            }
        }
    }

    private func useAsZero(_ position: MachinePosition) {
        Task { await machine.setWorkOrigin(machine: position) }
    }
}

/// The section's alerts, split out to keep the body small: save (name
/// prompt), rename, Go confirmation, Use as zero confirmation, notices.
private struct PositionAlerts: ViewModifier {
    @Binding var savePrompt: SavePrompt?
    @Binding var newName: String
    @Binding var renaming: SavedPosition?
    @Binding var renameText: String
    @Binding var pendingGoTo: SavedPosition?
    @Binding var pendingZero: SavedPosition?
    @Binding var notice: Notice?
    var feed: Double
    var store: SavedPositionsStore
    var goTo: (MachinePosition) -> Void
    var useAsZero: (MachinePosition) -> Void

    func body(content: Content) -> some View {
        content
            .alert(savePrompt?.title ?? String(localized: "Save position"), isPresented: present($savePrompt), presenting: savePrompt) { prompt in
                TextField("Name", text: $newName)
                Button("Save") { store.add(name: newName, position: prompt.position, kind: prompt.kind) }
                Button("Cancel", role: .cancel) {}
            } message: { prompt in
                Text(String(localized: "Machine ") + prompt.position.summary)
            }
            .alert("Rename position", isPresented: present($renaming)) {
                TextField("Name", text: $renameText)
                Button("Rename") {
                    if let renaming { store.rename(renaming.id, to: renameText) }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .alert("Move to \(pendingGoTo?.name ?? "position")?", isPresented: present($pendingGoTo), presenting: pendingGoTo) { target in
                Button("Go") { goTo(target.position) }
                Button("Cancel", role: .cancel) {}
            } message: { target in
                Text("\(target.position.summary)\nat \(Int(feed)) mm/min. Z moves first if it is going up, otherwise last.")
            }
            .alert("Use \(pendingZero?.name ?? "position") as work zero?", isPresented: present($pendingZero), presenting: pendingZero) { target in
                Button("Set Zero") { useAsZero(target.position) }
                Button("Cancel", role: .cancel) {}
            } message: { target in
                let p = target.position
                Text("Set the work zero to machine X\(formatMM(p.x)) Y\(formatMM(p.y)) Z\(formatMM(p.z))? The machine does not move.")
            }
            .alert(notice?.title ?? "", isPresented: present($notice), presenting: notice) { _ in
                Button("OK") {}
            } message: { notice in
                Text(notice.text)
            }
    }

    private func present<T>(_ item: Binding<T?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

/// What "Save…" is about to store: the spindle's position or the work origin.
private struct SavePrompt: Identifiable {
    let id = UUID()
    var title: String
    var position: MachinePosition
    var kind: SavedPosition.Kind = .machine
}

private struct Notice: Identifiable {
    let id = UUID()
    var title: String
    var text: String
}
