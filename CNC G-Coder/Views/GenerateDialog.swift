import SwiftUI
import AppKit

/// The Generate sheet: pick what to produce and where, then watch it run.
///
/// Both targets share one pcb2gcode batch, so the only real choice is what is
/// written at the end — .ngc programs for the machine, or 1:1 artwork for a
/// laser. Progress is reported per stage rather than as a spinner, because a
/// full batch with masks and silkscreen takes long enough that "is it stuck?"
/// is a fair question.
struct GenerateDialog: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage("generate.target") private var targetRaw = AppModel.GenerateTarget.cnc.rawValue

    /// Options of the Carvera stage files (read by AppModel at Generate).
    enum Keys {
        /// Compressed air (M7) while cutting; unset = the profile's default.
        static let carveraAir = "generate.carveraAir"
        /// Also copy the single-layer .ngc programs next to the stage files.
        static let carveraKeepPrograms = "generate.carveraKeepPrograms"
    }
    @AppStorage(Keys.carveraAir) private var carveraAir = true
    @AppStorage(Keys.carveraKeepPrograms) private var carveraKeepPrograms = false

    // Laser options, shared with the sidebar's per-layer export controls.
    @AppStorage(ArtworkExport.Keys.format) private var exportFormat = ArtworkExport.Format.svg.rawValue
    @AppStorage(ArtworkExport.Keys.polarity) private var exportPolarity = ArtworkExport.Polarity.whiteOnBlack.rawValue
    @AppStorage(ArtworkExport.Keys.dpi) private var exportDPI = 1000
    @AppStorage(ArtworkExport.Keys.frame) private var exportFrame = ArtworkExport.FrameMode.board.rawValue

    /// The folder the user last picked, per target, so reopening the sheet
    /// does not silently fall back to the default beside the project.
    @AppStorage("generate.destination.cnc") private var cncDestination = ""
    @AppStorage("generate.destination.laser") private var laserDestination = ""
    /// Their security-scoped bookmarks: the sandbox only lets the app write
    /// there again after a relaunch through one.
    @AppStorage("generate.destination.cnc.bookmark") private var cncBookmark = Data()
    @AppStorage("generate.destination.laser.bookmark") private var laserBookmark = Data()

    private var target: AppModel.GenerateTarget {
        AppModel.GenerateTarget(rawValue: targetRaw) ?? .cnc
    }

    private var storedDestination: String {
        get { target == .cnc ? cncDestination : laserDestination }
        nonmutating set {
            if target == .cnc { cncDestination = newValue } else { laserDestination = newValue }
        }
    }

    private var storedBookmark: Data {
        get { target == .cnc ? cncBookmark : laserBookmark }
        nonmutating set {
            if target == .cnc { cncBookmark = newValue } else { laserBookmark = newValue }
        }
    }

    /// Where the run will write, defaulting to a folder beside the project —
    /// when the app may write there (in the sandbox only if that folder was
    /// itself opened, e.g. with Open Gerber Folder).
    private var resolvedDestination: URL? {
        if !storedBookmark.isEmpty, let url = FileAccess.resolve(storedBookmark) { return url }
        if !storedDestination.isEmpty, !FileAccess.isSandboxed {
            return URL(fileURLWithPath: storedDestination, isDirectory: true)
        }
        guard let folder = model.projectFolder, FileManager.default.isWritableFile(atPath: folder.path) else { return nil }
        return folder.appendingPathComponent(target.folderName, isDirectory: true)
    }

    private var blocker: String? { model.generationBlocker(for: target) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Form {
                targetSection
                if target == .laser { laserSection }
                if target == .cnc, model.parameters.profile.isCarvera { carveraSection }
                destinationSection
                if model.isGenerating || model.generationSummary != nil { progressSection }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Divider()
            footer
        }
        .frame(width: 460)
        .frame(minHeight: 380, maxHeight: 640)
    }

    // MARK: - Header / footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: statusIcon)
                    .font(.title2)
                    .foregroundStyle(statusTint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Generate")
                        .font(.headline)
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(model.generationFailed && !model.isGenerating ? .red : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            // Pinned outside the scroll view: a long batch must never hide its
            // own progress behind a scrollbar.
            if model.isGenerating {
                ProgressView(value: Double(model.generationSteps.filter(\.isDone).count),
                             total: Double(max(model.generationTotal, model.generationSteps.count, 1)))
                    .progressViewStyle(.linear)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var statusLine: String {
        if model.isGenerating {
            let done = model.generationSteps.filter(\.isDone).count
            let total = max(model.generationTotal, model.generationSteps.count)
            let running = model.generationSteps.filter { !$0.isDone }.map(\.label)
            return "\(done) of \(total) done — " + (running.isEmpty ? "starting…" : running.joined(separator: " · "))
        }
        if let summary = model.generationSummary { return summary }
        return model.projectFolder?.lastPathComponent ?? String(localized: "No project")
    }

    private var statusIcon: String {
        if model.isGenerating { return target.icon }
        guard let _ = model.generationSummary else { return target.icon }
        return model.generationFailed ? "xmark.octagon.fill" : "checkmark.seal.fill"
    }

    private var statusTint: Color {
        if !model.isGenerating, model.generationSummary != nil {
            return model.generationFailed ? .red : .green
        }
        return target == .cnc ? Color.accentColor : .pink
    }

    private var footer: some View {
        HStack {
            if let summary = model.generationSummary, !model.isGenerating {
                Button("Open Folder") { model.openOutputFolder() }
                    .disabled(model.generationFailed)
                    .help(summary)
            }
            Spacer()
            if model.isGenerating {
                Button("Cancel Run") { model.cancelGeneration() }
                    .help("Stops after the stage that is currently running.")
            } else {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Button {
                if let destination = resolvedDestination {
                    model.startGeneration(target: target, destination: destination)
                }
            } label: {
                Text(model.generationSummary == nil ? "Generate" : "Generate Again")
                    .frame(minWidth: 72)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.isGenerating || blocker != nil || resolvedDestination == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Sections

    private var targetSection: some View {
        Section {
            Picker("Produce", selection: $targetRaw) {
                ForEach(AppModel.GenerateTarget.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isGenerating)
        } footer: {
            switch target {
            case .cnc where model.parameters.profile.isCarvera:
                Text("Generates the toolpaths with the current parameters and writes one .cnc file per machine session for the \(model.parameters.profile.name): tool changes become T<n> M6 for its tool changer, with no M0 pauses.")
            case .cnc:
                Text("Generates the toolpaths with the current parameters and writes the .ngc programs — the files the preview is showing.")
            case .laser:
                Text("Generates the same programs, then writes each one as 1:1 artwork for a laser engraver instead of G-code. The .ngc files are not kept.")
            }
        }
    }

    private var laserSection: some View {
        Section("Artwork") {
            Picker("Format", selection: $exportFormat) {
                ForEach(ArtworkExport.Format.allCases) { format in
                    Text(format.title).tag(format.rawValue)
                }
            }
            .pickerStyle(.segmented)

            Picker("Polarity", selection: $exportPolarity) {
                ForEach(ArtworkExport.Polarity.allCases) { polarity in
                    Text(polarity.title).tag(polarity.rawValue)
                }
            }
            .pickerStyle(.segmented)

            if ArtworkExport.Format(rawValue: exportFormat) == .png {
                Picker("Resolution", selection: $exportDPI) {
                    Text("300 dpi").tag(300)
                    Text("600 dpi").tag(600)
                    Text("1000 dpi").tag(1000)
                    Text("2400 dpi").tag(2400)
                }
            }

            Picker("Frame", selection: $exportFrame) {
                ForEach(ArtworkExport.FrameMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
        }
        .disabled(model.isGenerating)
    }

    /// The stage files a Carvera profile will write, from the preview.
    @ViewBuilder
    private var carveraSection: some View {
        let plan = model.machinePlan()
        Section {
            if let plan {
                ForEach(plan.stages) { stage in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(stage.stage.code)
                            .font(.caption.weight(.semibold).monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(stage.title)
                            Text("\(stage.fileName) · \(stage.slots.map { "T\($0)" }.joined(separator: " ")) · \(MachinePost.timeText(stage.estimatedTime))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                    }
                    .help(stage.stage.before)
                }
                ForEach(plan.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                Text("The stages appear once the preview has run.")
                    .foregroundStyle(.secondary)
            }
            Toggle("Compressed air while cutting (M7)", isOn: $carveraAir)
                .help("Turns the Carvera's compressed-air nozzle on after every spindle start and off before every tool change — Makera's own PCB programs do the same; it keeps the fibreglass dust off the cut.")
            Toggle("Also write the single-layer programs", isOn: $carveraKeepPrograms)
                .help("Copies the per-layer .ngc programs the preview shows next to the stage files, as the GRBL profile would write them (they still contain M0 pauses, which the Carvera ignores).")
        } header: {
            Text("Stage files")
        } footer: {
            Text("One file per machine session: front isolation; mask etch, drilling and cutout after the mask is cured; the same two for the back after the flip. The rack list is at the top of every file and under Machine setup.")
        }
        .disabled(model.isGenerating)
    }

    private var destinationSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(resolvedDestination?.lastPathComponent ?? String(localized: "No folder"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(resolvedDestination?.deletingLastPathComponent().path ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
                Button("Choose…") { chooseDestination() }
                    .disabled(model.isGenerating)
            }
            .help(resolvedDestination?.path ?? "")
        } header: {
            Text("Destination")
        } footer: {
            if let blocker {
                Label(blocker, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if resolvedDestination == nil {
                Text("Choose a folder for the generated files.")
            } else {
                Text("Created if it does not exist. Existing files with the same names are replaced.")
            }
        }
    }

    private var progressSection: some View {
        Section {
            ForEach(model.generationSteps) { step in
                HStack(spacing: 8) {
                    if step.isDone {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        ProgressView().controlSize(.small).frame(width: 16)
                    }
                    Text(step.label)
                        .foregroundStyle(step.isDone ? .secondary : .primary)
                    Spacer()
                }
                .font(.callout)
            }
        } header: {
            Text(model.isGenerating ? "Running" : "Result")
        } footer: {
            Text("The full output, with per-stage timings, is in the Log tab.")
        }
    }

    // MARK: - Actions

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = String(localized: "Choose the folder for the generated files — use New Folder to create one.")
        panel.directoryURL = resolvedDestination?.deletingLastPathComponent() ?? model.projectFolder
        if panel.runModal() == .OK, let url = panel.url {
            storedDestination = url.path
            storedBookmark = FileAccess.bookmark(url) ?? Data()
        }
    }
}
