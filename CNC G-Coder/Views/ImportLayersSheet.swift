import SwiftUI

/// Confirms the role of each file picked with Import Layer…. Roles are
/// pre-filled from the filename (and an M48 header for drill files).
struct ImportLayersSheet: View {
    @ObservedObject var model: AppModel

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

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.pendingImports = [] }
                    .keyboardShortcut(.cancelAction)
                Button("Import") { model.commitImports() }
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
