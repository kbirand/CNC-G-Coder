import SwiftUI

/// Confirms the role of each file picked with Import Layer…. Roles are
/// pre-filled from the filename (and an M48 header for drill files).
struct ImportLayersSheet: View {
    @ObservedObject var model: AppModel
    /// Keep the Gerber files' own X0 Y0, or zero the programs on the board.
    /// Starts on whatever the project currently does.
    @State private var useGerberOrigin: Bool?

    private var gerberOrigin: Binding<Bool> {
        Binding(get: { useGerberOrigin ?? !model.parameters.zeroStart }, set: { useGerberOrigin = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Layers")
                .font(.title2.bold())
            Text("Choose what each file is. Drill files are added as extra drill programs; any other role replaces the file currently in it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                ForEach($model.pendingImports) { $item in
                    Picker(selection: $item.slot) {
                        Text("Skip").tag(LayerSlot?.none)
                        Divider()
                        ForEach(LayerSlot.allCases) { slot in
                            Text(slot.title).tag(LayerSlot?.some(slot))
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Text(replacementNote(for: item))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .help(item.url.path)
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 120)

            Form {
                Picker("X0 Y0", selection: gerberOrigin) {
                    Text("Gerber file's origin").tag(true)
                    Text("Board \(model.zeroedOriginName)").tag(false)
                }
                .pickerStyle(.radioGroup)
                Text("Gerber files have an origin of their own — the X0 Y0 of the design in the PCB editor. Keep it, or move X0 Y0 onto the board so you can touch off there. This applies to the whole project and can be changed later under Machine setup → Origin.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.pendingImports = [] }
                    .keyboardShortcut(.cancelAction)
                Button("Import") { model.commitImports(useGerberOrigin: gerberOrigin.wrappedValue) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.pendingImports.allSatisfy { $0.slot == nil })
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func replacementNote(for item: PendingImport) -> String {
        guard let slot = item.slot else { return "Not imported" }
        if slot == .drill { return "Added as a drill program" }
        if let current = model.detectedFiles[slot] {
            return current == item.url ? "Already the \(slot.title.lowercased()) file" : "Replaces \(current.lastPathComponent)"
        }
        return "New \(slot.title.lowercased()) layer"
    }
}
