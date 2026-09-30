//
//  ContentView.swift
//  CNC G-Coder
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            ParameterFormView(model: model, params: model.parameters,
                              preview: model.preview, playback: model.player)
                .navigationSplitViewColumnWidth(min: 310, ideal: 360, max: 480)
        } detail: {
            PreviewPane(model: model, preview: model.preview, playback: model.player)
        }
        .navigationTitle(model.projectURL == nil ? "CNC G-Coder" : model.projectName)
        .navigationSubtitle(windowSubtitle)
        .modifier(ProjectDocumentProxy(url: model.projectURL))
        .sheet(isPresented: Binding(
            get: { !model.pendingImports.isEmpty },
            set: { if !$0 { model.pendingImports = [] } }
        )) {
            ImportLayersSheet(model: model)
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $model.showTestBoardDialog) {
            TestBoardDialog(model: model)
        }
        .sheet(isPresented: $model.showGenerateDialog) {
            GenerateDialog(model: model)
        }
    }

    private var windowSubtitle: String {
        let base = model.projectURL == nil
            ? (model.projectFolder?.lastPathComponent ?? "No project")
            : (model.projectFolder?.lastPathComponent ?? "")
        return model.isProjectEdited ? base + " — Edited" : base
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // The project folder is chosen in the sidebar; the toolbar holds only
        // secondary controls and the one prominent action.
        ToolbarItemGroup {
            PresetsMenu(params: model.parameters)

            Menu {
                Button {
                    model.openOutputFolder()
                } label: {
                    Label("Open Output Folder", systemImage: "folder.badge.gearshape")
                }
                .disabled(model.outputDir == nil)

                Button {
                    model.copyCommand()
                } label: {
                    Label("Copy pcb2gcode Command", systemImage: "document.on.clipboard")
                }
                .disabled(model.outputDir == nil)

                Divider()

                Button {
                    model.addCustomLayer()
                } label: {
                    Label("New Custom Layer", systemImage: "pencil.and.outline")
                }
                .help("Add a layer to draw on — lines, rectangles, circles and text, machined with a tool of your choice.")

                Button {
                    model.showTestBoardDialog = true
                } label: {
                    Label("Generate Test Board…", systemImage: "square.grid.3x3.topleft.filled")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("Output folder, command copying, and the parameter-calibration test board")

            Button {
                openWindow(id: "help")
            } label: {
                Label("Help", systemImage: "questionmark.circle")
            }
            .help("Open the user guide: workflow, parameter reference, preview features, machining tips")
        }

        ToolbarSpacer(.fixed)

        // The one prominent action stands alone. It opens the Generate sheet,
        // which owns the target, the destination and the progress.
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.showGenerateDialog = true
            } label: {
                if model.isGenerating {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.horizontal, 4)
                } else {
                    Label("Generate", systemImage: "hammer.fill")
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 4)
                }
            }
            .buttonStyle(.glassProminent)
            .disabled(!model.detectedFiles.hasAnything && !model.customLayers.hasShapes)
            .help("Choose what to produce — CNC G-code or laser artwork — where to put it, and watch it run.")
        }
    }
}

/// The title-bar proxy icon for the open project file (none when untitled).
private struct ProjectDocumentProxy: ViewModifier {
    let url: URL?
    func body(content: Content) -> some View {
        if let url { content.navigationDocument(url) } else { content }
    }
}

/// Save/recall complete parameter sets from the toolbar.
struct PresetsMenu: View {
    @ObservedObject var params: ParametersStore

    @AppStorage("paramPresets") private var presetsData = Data()
    @State private var showingSavePreset = false
    @State private var presetName = ""

    private var presets: [String: [String: String]] {
        (try? JSONDecoder().decode([String: [String: String]].self, from: presetsData)) ?? [:]
    }

    var body: some View {
        Menu {
            if presets.isEmpty {
                Text("No presets saved")
            } else {
                ForEach(presets.keys.sorted(), id: \.self) { name in
                    Button(name) { params.apply(presets[name] ?? [:]) }
                }
            }
            Divider()
            Button("Save Current as Preset…") {
                presetName = ""
                showingSavePreset = true
            }
            if !presets.isEmpty {
                Menu("Delete Preset") {
                    ForEach(presets.keys.sorted(), id: \.self) { name in
                        Button(name, role: .destructive) { deletePreset(name) }
                    }
                }
            }
        } label: {
            Label("Presets", systemImage: "slider.horizontal.3")
        }
        .help("Save and recall complete parameter sets (tools, feeds, depths). Useful per material or per machine.")
        .alert("Save Preset", isPresented: $showingSavePreset) {
            TextField("Preset name", text: $presetName)
            Button("Save") {
                let name = presetName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { savePreset(named: name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stores all current machining parameters under this name.")
        }
    }

    private func savePreset(named name: String) {
        var all = presets
        all[name] = params.exportValues()
        if let data = try? JSONEncoder().encode(all) { presetsData = data }
    }

    private func deletePreset(_ name: String) {
        var all = presets
        all.removeValue(forKey: name)
        if let data = try? JSONEncoder().encode(all) { presetsData = data }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppModel())
}
