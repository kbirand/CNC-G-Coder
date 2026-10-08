import SwiftUI

/// Named command lists (`machine.macros`): run one with the machine idle,
/// edit, add, delete, restore the defaults. A line `@goto <saved position>`
/// expands to the safe-move legs of that saved position. Every macro is
/// also a user button on the Control tab (`UserButtonsSection`).
struct MacrosTab: View {
    @Bindable var machine: MachineController

    var body: some View {
        MacrosControls(machine: machine)
    }
}

/// The macro list itself — the window's tab fills with it, the main
/// window's panel section shows it with a bounded height (`bounded`) since
/// it sits inside a scrolling column.
struct MacrosControls: View {
    @Bindable var machine: MachineController
    var bounded: Bool = false

    @State private var macros = MachineSettings.macros
    @State private var editing: MachineSettings.Macro?
    @State private var running: UUID?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if macros.isEmpty {
                Text("No macros. Click Add to create one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: bounded ? nil : .infinity)
                    .padding(.vertical, bounded ? 10 : 0)
            } else {
                List {
                    ForEach(macros) { macro in
                        row(macro)
                    }
                    .onMove { source, destination in
                        macros.move(fromOffsets: source, toOffset: destination)
                        persist()
                    }
                }
                .listStyle(.inset)
                .frame(height: bounded ? min(CGFloat(macros.count) * 52 + 16, 280) : nil)
            }
        }
        .sheet(item: $editing) { macro in
            MacroEditSheet(macro: macro) { updated in
                if let index = macros.firstIndex(where: { $0.id == updated.id }) {
                    macros[index] = updated
                } else {
                    macros.append(updated)
                }
                persist()
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button("Add", systemImage: "plus") {
                editing = MachineSettings.Macro(name: "New macro", lines: [])
            }
            .help("New macro: a name, an optional icon and the G-code lines it sends. It also becomes a user button on the Control tab.")
            Button("Restore Defaults") {
                macros = MachineSettings.defaultMacros
                persist()
            }
            .help("Replace the list with the built-in examples — your own macros are removed")
            Spacer()
            Text("Lines are sent one after another with the machine idle; `@goto <position>` moves to a saved position.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(bounded ? 3 : 2)
        }
        .controlSize(.small)
        .padding(.horizontal, bounded ? 0 : 14)
        .padding(.vertical, 6)
    }

    private var canRun: Bool {
        machine.isConnected && machine.machineState == .idle && !machine.jobLocksControls && machine.alarmCode == nil && running == nil
    }

    private func row(_ macro: MachineSettings.Macro) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if let icon = macro.icon { Image(systemName: icon).foregroundStyle(.secondary) }
                    Text(macro.name)
                        .font(.callout.weight(.semibold))
                    if macro.allowWhileRunning {
                        Text("while running")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                    }
                }
                Text(macro.lines.joined(separator: "  ·  "))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if running == macro.id {
                ProgressView().controlSize(.small)
            }
            Button("Run", systemImage: "play.fill") { run(macro) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canRun || macro.lines.isEmpty)
                .help(canRun ? "Send the lines one after another and wait for each to be acknowledged" : "Needs the machine connected and idle, with no alarm and no program running")
            Button("Edit", systemImage: "pencil") { editing = macro }
                .controlSize(.small)
                .help("Change the name, icon or lines. Right-click the row to duplicate or delete it.")
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Edit…", systemImage: "pencil") { editing = macro }
            Button("Duplicate", systemImage: "plus.square.on.square") {
                macros.append(MachineSettings.Macro(name: macro.name + " copy", lines: macro.lines,
                                                    icon: macro.icon, allowWhileRunning: macro.allowWhileRunning))
                persist()
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                macros.removeAll { $0.id == macro.id }
                persist()
            }
        }
    }

    private func run(_ macro: MachineSettings.Macro) {
        running = macro.id
        Task {
            await machine.runMacro(macro)
            running = nil
        }
    }

    private func persist() {
        MachineSettings.macros = macros
    }
}

/// Name, button icon, lines and the while-running flag of one macro.
private struct MacroEditSheet: View {
    var macro: MachineSettings.Macro
    var onSave: (MachineSettings.Macro) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var icon = ""
    @State private var allowWhileRunning = false
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit macro").font(.title3.weight(.semibold))
            HStack(spacing: 8) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .help("Shown in the list and on the user button")
                TextField("SF Symbol (optional)", text: $icon)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                    .help("Icon for the user button on the Control tab, e.g. fan.fill, drop.fill, house")
                Image(systemName: icon.trimmingCharacters(in: .whitespaces).isEmpty ? "square.dashed" : icon.trimmingCharacters(in: .whitespaces))
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
            }
            Toggle("Allow while a program runs", isOn: $allowWhileRunning)
                .help("Keep the user button enabled during a job; the lines are queued between the program's. Only for short commands (coolant, a light), never for motion.")
            Text("One command per line. `@goto <saved position>` moves there safely (Z first when rising).")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(height: 200)
                .border(.quaternary)
                .help("One G-code or $ command per line, sent in order with the machine idle. @goto <saved position> expands to a safe move to that position (Z first when rising).")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help("Discard the changes")
                Button("Save") {
                    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    let symbol = icon.trimmingCharacters(in: .whitespaces)
                    onSave(MachineSettings.Macro(id: macro.id, name: name.trimmingCharacters(in: .whitespaces).isEmpty ? String(localized: "Macro") : name,
                                                 lines: lines, icon: symbol.isEmpty ? nil : symbol, allowWhileRunning: allowWhileRunning))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            name = macro.name
            icon = macro.icon ?? ""
            allowWhileRunning = macro.allowWhileRunning
            text = macro.lines.joined(separator: "\n")
        }
    }
}
