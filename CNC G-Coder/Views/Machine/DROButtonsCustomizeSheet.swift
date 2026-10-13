import SwiftUI

/// Customize Buttons… for the DRO's grid, in the manner of a toolbar
/// customization sheet: the left list is the grid in order (drag to
/// reorder, − removes), the right list offers what is not shown yet — the
/// built-in actions, then the macros of the Macros tab (+ appends). New
/// Macro… creates a macro and adds it at once; a macro row's context menu
/// edits it. Every change is saved as it is made (`MachineSettings.droButtons`),
/// so the grid behind the sheet follows along; Restore Defaults puts the
/// original eight back.
struct DROButtonsCustomizeSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var shown: [MachineSettings.DROButton] = []
    @State private var macros = MachineSettings.macros
    @State private var editingMacro: MachineSettings.Macro?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Customize Buttons")
                .font(.title3.weight(.semibold))
            Text("Drag to reorder the buttons of the position panel; − removes one, + adds a built-in action or a macro at the end.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 14) {
                column(title: "Shown", count: shown.count) { shownList }
                column(title: "Available", count: available.count) { availableList }
            }
            .frame(height: 330)
            HStack(spacing: 10) {
                Button("Restore Defaults") {
                    shown = MachineSettings.defaultDROButtons
                    persist()
                }
                .help("Back to the original two rows: Zero XY, Zero Z, Zero All, Probe Z, Work Zero, Safe Z, Home, Unlock")
                Button("New Macro…", systemImage: "plus") {
                    editingMacro = MachineSettings.Macro(name: String(localized: "New macro"), lines: [])
                }
                .help("Create a macro (it also appears in the Macros tab and as a user button) and add it to the grid")
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(20)
        .frame(width: 620)
        .onAppear(perform: load)
        .sheet(item: $editingMacro) { macro in
            MacroEditSheet(macro: macro) { updated in
                if let index = macros.firstIndex(where: { $0.id == updated.id }) {
                    macros[index] = updated
                } else {
                    macros.append(updated)
                    shown.append(.macro(updated.id))
                }
                MachineSettings.macros = macros
                persist()
            }
        }
    }

    // MARK: Lists

    private func column<Content: View>(title: LocalizedStringKey, count: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MachineSectionLabel(title: title, detail: "\(count)")
            content()
                .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var shownList: some View {
        if shown.isEmpty {
            placeholder("No buttons. Add some from the list on the right.")
        } else {
            List {
                ForEach(shown, id: \.self) { button in
                    row(button, symbol: "minus.circle.fill", tint: .red, help: "Remove from the grid") {
                        shown.removeAll { $0 == button }
                        persist()
                    }
                }
                .onMove { source, destination in
                    shown.move(fromOffsets: source, toOffset: destination)
                    persist()
                }
            }
            .listStyle(.bordered)
        }
    }

    @ViewBuilder
    private var availableList: some View {
        if available.isEmpty {
            placeholder("Everything is in the grid. New Macro… adds another.")
        } else {
            List {
                ForEach(available, id: \.self) { button in
                    row(button, symbol: "plus.circle.fill", tint: .accentColor, help: "Add to the end of the grid") {
                        shown.append(button)
                        persist()
                    }
                }
            }
            .listStyle(.bordered)
        }
    }

    private func placeholder(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func row(_ button: MachineSettings.DROButton, symbol: String, tint: Color, help: LocalizedStringKey,
                     action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(of: button))
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text(title(of: button))
                .lineLimit(1)
            if case .macro(let id) = button {
                if macro(id)?.allowWhileRunning == true {
                    Text("while running")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                }
                Text("macro")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Button(action: action) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
            }
            .buttonStyle(.borderless)
            .help(help)
        }
        .padding(.vertical, 2)
        .contextMenu {
            if case .macro(let id) = button, let macro = macro(id) {
                Button("Edit Macro…", systemImage: "pencil") { editingMacro = macro }
            }
        }
    }

    // MARK: Data

    private var available: [MachineSettings.DROButton] {
        let builtIns = MachineSettings.DROBuiltIn.allCases.map(MachineSettings.DROButton.builtIn)
        let macroButtons = macros.map { MachineSettings.DROButton.macro($0.id) }
        return (builtIns + macroButtons).filter { !shown.contains($0) }
    }

    private func macro(_ id: UUID) -> MachineSettings.Macro? {
        macros.first { $0.id == id }
    }

    private func title(of button: MachineSettings.DROButton) -> String {
        switch button {
        case .builtIn(let action): action.title
        case .macro(let id): macro(id)?.name ?? String(localized: "Deleted macro")
        }
    }

    private func icon(of button: MachineSettings.DROButton) -> String {
        switch button {
        case .builtIn(let action): action.symbol
        case .macro(let id): macro(id)?.icon ?? "command"
        }
    }

    /// Macros deleted in the Macros tab drop out of the layout here, as
    /// they do from the grid.
    private func load() {
        macros = MachineSettings.macros
        shown = MachineSettings.droButtons.filter {
            if case .macro(let id) = $0 { return macro(id) != nil }
            return true
        }
    }

    private func persist() {
        MachineSettings.droButtons = shown
    }
}
