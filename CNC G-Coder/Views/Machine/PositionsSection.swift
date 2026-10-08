import SwiftUI

/// Named machine positions (port of the pendant's list): Save current…, Save
/// work zero (the current work origin as a machine point, so it can be
/// restored after a reset or re-homing), Go with confirmation, Use as zero
/// (`G10 L2 P0` at the stored point — no motion, confirmed first), Rename /
/// Overwrite / Delete in the context menu, drag to reorder, plus "Go to
/// coordinates…" for a typed target. The panel's Positions tab shows it
/// `tall`; the Machine window's pendant column keeps the short list.
struct PositionsSection: View {
    @Bindable var machine: MachineController
    var tall: Bool = false

    @AppStorage(MachineSettings.Keys.jogFeed) private var feed = MachineSettings.Defaults.jogFeed

    @State private var savePrompt: SavePrompt?
    @State private var newName = ""
    @State private var renaming: SavedPosition?
    @State private var renameText = ""
    @State private var pendingGoTo: SavedPosition?
    @State private var pendingZero: SavedPosition?
    @State private var showGoTo = false
    @State private var notice: Notice?

    private var store: SavedPositionsStore { machine.positions }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
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
            MachineSectionLabel(title: "Positions", detail: store.positions.isEmpty ? nil : "\(store.positions.count)")
            Button("Save current…", systemImage: "plus") {
                guard let mpos = machine.status.machinePosition else { return }
                newName = "Position \(store.positions.count + 1)"
                savePrompt = SavePrompt(title: "Save position", position: mpos)
            }
            .disabled(!machine.isConnected || machine.status.machinePosition == nil)
            .help("Store the machine coordinates the spindle is at now")
            Button("Save work zero", systemImage: "scope") { saveWorkZero() }
                .disabled(!machine.isConnected)
                .help("Store where work X0 Y0 Z0 is in machine coordinates, so the zero can be restored later with Use as zero")
            Button("Go to…", systemImage: "location") { showGoTo = true }
                .help("Type a machine coordinate and move there")
                .disabled(!machine.isConnected)
        }
    }

    private var hint: some View {
        Text("Positions are machine coordinates. Save the work zero so it can be restored after a reset or re-homing.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var list: some View {
        if store.positions.isEmpty {
            Text("No positions saved yet. Jog to a spot and click Save current, or Save work zero.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        } else {
            List {
                ForEach(store.positions) { saved in
                    row(for: saved)
                        .listRowInsets(EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4))
                }
                .onMove { source, destination in store.move(fromOffsets: source, toOffset: destination) }
                .onDelete { offsets in store.delete(at: offsets) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: min(CGFloat(store.positions.count) * 36 + 8, tall ? 420 : 150))
        }
    }

    private func row(for saved: SavedPosition) -> some View {
        HStack(spacing: 8) {
            Image(systemName: saved.name.lowercased().hasPrefix("work zero") ? "scope" : "mappin.circle.fill")
                .foregroundStyle(Color.accentColor)
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
            Button("Use as zero", systemImage: "scope") { pendingZero = saved }
                .disabled(!canSetZero)
                .help("Make this machine point the work origin (G10 L2) — the machine does not move")
            Button("Go") { pendingGoTo = saved }
                .buttonStyle(.borderedProminent)
                .disabled(!machine.positioningEnabled)
                .help(machine.positioningEnabled
                      ? "Move there at the jog feed, after a confirmation — Z first when rising, last when descending. Right-click the row to rename, overwrite or delete it."
                      : "Needs the machine connected, idle, not in alarm, and a trusted (homed) position")
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Use as Work Zero…", systemImage: "scope") { pendingZero = saved }
                .disabled(!canSetZero)
            Button("Rename…", systemImage: "pencil") {
                renameText = saved.name
                renaming = saved
            }
            Button("Overwrite with Current Position", systemImage: "arrow.triangle.2.circlepath") {
                if let mpos = machine.status.machinePosition { store.overwrite(saved.id, with: mpos) }
            }
            .disabled(machine.status.machinePosition == nil)
            Button("Overwrite with Current Work Zero", systemImage: "scope") {
                if let wco = machine.workOffset { store.overwrite(saved.id, with: wco) }
            }
            .disabled(machine.workOffset == nil)
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
        newName = "Work zero " + Date.now.formatted(date: .abbreviated, time: .shortened)
        savePrompt = SavePrompt(title: "Save work zero", position: wco)
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
            .alert(savePrompt?.title ?? "Save position", isPresented: present($savePrompt), presenting: savePrompt) { prompt in
                TextField("Name", text: $newName)
                Button("Save") { store.add(name: newName, position: prompt.position) }
                Button("Cancel", role: .cancel) {}
            } message: { prompt in
                Text("Machine " + prompt.position.summary)
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
}

private struct Notice: Identifiable {
    let id = UUID()
    var title: String
    var text: String
}
