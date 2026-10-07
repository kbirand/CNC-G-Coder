import SwiftUI

/// The raw conversation with the controller: every line sent and received
/// (status polls hidden unless asked), app notes and warnings, and a command
/// field with ↑/↓ history. Typing is locked while a job runs except in the
/// tool-change suspension, when the operator may need a manual command.
struct ConsoleTab: View {
    @Bindable var machine: MachineController

    @State private var command = ""
    @State private var historyIndex: Int?
    @State private var version = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            MonoTextView(text: consoleText, contentVersion: version, autoScrollToBottom: true)
            Divider()
            commandField
        }
        .onChange(of: machine.console.last?.id) { _, _ in version += 1 }
        .onChange(of: machine.console.count) { _, _ in version += 1 }
        .onChange(of: machine.consoleShowStatus) { _, on in
            MachineSettings.consoleShowStatus = on
            version += 1
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Toggle("Show status reports", isOn: $machine.consoleShowStatus)
                .toggleStyle(.checkbox)
                .help("Include the ? polls and <…> reports (5 per second)")
            Spacer()
            Text("\(machine.console.count) lines")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Clear", systemImage: "trash") { machine.clearConsole() }
                .disabled(machine.console.isEmpty)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var commandField: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
            TextField("Command (e.g. $G, G0 X10, $/axes/x/max_travel_mm)", text: $command)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .focused($fieldFocused)
                .onSubmit { submit() }
                .onKeyPress(.upArrow) { recall(step: -1); return .handled }
                .onKeyPress(.downArrow) { recall(step: 1); return .handled }
            Button("Send") { submit() }
                .keyboardShortcut(.defaultAction)
                .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .disabled(!inputEnabled)
        .help(inputEnabled ? "Sent as typed; a single character like ! ~ ? is sent as a real-time byte" : "Locked while a program runs")
    }

    private var inputEnabled: Bool {
        machine.isConnected && !machine.jobLocksControls
    }

    private func submit() {
        let text = command.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, inputEnabled else { return }
        command = ""
        historyIndex = nil
        Task { await machine.sendConsoleCommand(text) }
    }

    /// ↑ walks back through the history, ↓ forward; past the newest entry
    /// the field is emptied again.
    private func recall(step: Int) {
        let history = machine.commandHistory
        guard !history.isEmpty else { return }
        let next: Int
        if let index = historyIndex {
            next = index + step
        } else {
            next = step < 0 ? history.count - 1 : history.count
        }
        if next < 0 { return }
        if next >= history.count {
            historyIndex = nil
            command = ""
            return
        }
        historyIndex = next
        command = history[next]
    }

    /// One line per entry: time, a direction mark, the text.
    private var consoleText: String {
        let showStatus = machine.consoleShowStatus
        var lines: [String] = []
        lines.reserveCapacity(machine.console.count)
        for entry in machine.console {
            if entry.direction == .status, !showStatus { continue }
            lines.append(Self.timeFormatter.string(from: entry.date) + " " + Self.prefix(entry.direction) + entry.text)
        }
        return lines.joined(separator: "\n")
    }

    private static func prefix(_ direction: MachineController.ConsoleEntry.Direction) -> String {
        switch direction {
        case .sent: "> "
        case .received: "< "
        case .info: "· "
        case .warning: "! "
        case .error: "!! "
        case .status: "? "
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
