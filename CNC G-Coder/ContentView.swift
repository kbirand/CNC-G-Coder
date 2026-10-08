//
//  ContentView.swift
//  CNC G-Coder
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    // The column widths the user dragged to: the sidebar's is restored as
    // its ideal width, the panel's is applied directly (see `panelWidth`).
    @AppStorage(ColumnWidthKeys.sidebar) private var sidebarWidth = ColumnWidthKeys.sidebarDefault
    @AppStorage(ColumnWidthKeys.inspector) private var inspectorWidth = ColumnWidthKeys.inspectorDefault
    @AppStorage(ColumnWidthKeys.sidebarVisible) private var sidebarVisible = true
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Keeps the window wide enough for the visible columns (see the class).
    @State private var windowPolicy = WindowSizePolicy()

    /// The Machine panel is a manually sized trailing column, not
    /// `.inspector`: the inspector tries to grow the window for its width
    /// and, when the screen stops it, lets the split view and itself overlap
    /// (both edges clipped). Here the panel takes the stored width, yields
    /// when the window is tight, and the sidebar collapses if even the
    /// panel's minimum does not fit beside it — the content never exceeds
    /// the window.
    var body: some View {
        let _ = DebugFlags.renderLog ? Self._printChanges() : ()
        GeometryReader { geometry in
            columns(totalWidth: geometry.size.width)
                .onChange(of: geometry.size.width, initial: true) { _, width in windowPolicy.setContentWidth(width) }
        }
        .animation(.easeInOut(duration: 0.2), value: model.showMachineInspector)
        .background(WindowAccessor { windowPolicy.attach($0); DebugWindowSnapshot.arm() })
        .onAppear {
            // Dev hook: `-debugOpenSettings 1` opens Settings after launch.
            if UserDefaults.standard.bool(forKey: "debugOpenSettings") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { openSettings() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willStartLiveResizeNotification)) { note in
            if (note.object as? NSWindow) === windowPolicy.window { windowPolicy.liveResizeStarting() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndLiveResizeNotification)) { note in
            if (note.object as? NSWindow) === windowPolicy.window { windowPolicy.liveResizeEnded() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { note in
            if (note.object as? NSWindow) === windowPolicy.window { windowPolicy.windowResized() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) { note in
            if (note.object as? NSWindow) === windowPolicy.window { windowPolicy.windowResized() }
        }
        .onChange(of: model.showMachineInspector, initial: true) { _, shown in windowPolicy.setInspectorShown(shown) }
        .onChange(of: inspectorWidth, initial: true) { _, width in windowPolicy.setInspectorStoredWidth(width) }
        .onChange(of: columnVisibility) { _, visibility in
            sidebarVisible = visibility != .detailOnly
            windowPolicy.setSidebarVisible(sidebarVisible)
        }
        .background {
            // ⌘. stops the machine from anywhere in the main window while the
            // panel is shown; invisible, but it keeps the shortcut in the
            // responder chain (same pattern as the Machine window).
            if model.showMachineInspector {
                Button("Stop") { Task { await model.machine.stop() } }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.machine.isConnected)
                    .opacity(0)
                    .frame(width: 0, height: 0)
            }
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
        .onAppear {
            columnVisibility = sidebarVisible ? .all : .detailOnly
            windowPolicy.setSidebarVisible(sidebarVisible)
            windowPolicy.setSidebarWidth(sidebarWidth)
            windowPolicy.collapseSidebar = { columnVisibility = .detailOnly }
            // Dev hook: `-debugMachineWindow 1` shows the Machine panel at
            // launch; `-debugMachineWindow window` opens the separate window;
            // `-debugMachineWindowAfter 3` shows the panel 3 s after launch.
            switch UserDefaults.standard.string(forKey: "debugMachineWindow") {
            case "window": openWindow(id: "machine")
            case "1", "true", "YES": model.showMachineInspector = true
            default: break
            }
            // Dev hook: `-debugOpenWindow tools|machine|help` opens that window at launch.
            if let id = UserDefaults.standard.string(forKey: "debugOpenWindow"), !id.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { openWindow(id: id) }
            }
            if let delay = Double(UserDefaults.standard.string(forKey: "debugMachineWindowAfter") ?? ""), delay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    print("[debug] showing the Machine panel after \(delay) s")
                    model.showMachineInspector = true
                }
            }
            // Dev hook: `-debugWindowSize 1100x700` resizes the main window
            // (the window's own minimum still applies) and logs the frames.
            if let spec = UserDefaults.standard.string(forKey: "debugWindowSize") {
                setvbuf(stdout, nil, _IOLBF, 0)   // the hook's log lines reach a redirected file at once
                dumpViewsIfRequested()
                applyDebugWindowSize(spec)
            }
        }
    }

    // MARK: Columns

    private static let panelDivider: CGFloat = 1

    /// The panel's width for a window of `totalWidth`: the stored width,
    /// reduced to what is left beside the sidebar and a 420 pt preview,
    /// never below the panel's minimum (then the policy collapses the sidebar).
    private func panelWidth(totalWidth: CGFloat) -> CGFloat {
        let sidebar = sidebarVisible ? sidebarWidth + WindowSizePolicy.divider : 0
        let available = totalWidth - sidebar - WindowSizePolicy.detailMinWidth - Self.panelDivider
        return min(inspectorWidth, max(ColumnWidthKeys.inspectorMin, available))
    }

    private func columns(totalWidth: CGFloat) -> some View {
        let panelShown = model.showMachineInspector
        let panel = panelShown ? panelWidth(totalWidth: totalWidth) : 0
        let navigationWidth = max(0, totalWidth - (panelShown ? panel + Self.panelDivider : 0))
        return HStack(spacing: 0) {
            navigationSplit
                .frame(width: navigationWidth)
                .background(FrameReporter(name: "navigation"))
            if panelShown {
                panelDivider(totalWidth: totalWidth)
                MachineInspector()
                    .environmentObject(model)
                    .frame(width: panel)
                    .background(ColumnWidthRecorder(key: nil, name: "panel") { windowPolicy.setInspectorWidth($0) })
                    .background(FrameReporter(name: "panel"))
                    .transition(.move(edge: .trailing))
            }
        }
    }

    private var navigationSplit: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ParameterFormView(model: model, params: model.parameters,
                              preview: model.preview, playback: model.player, layerEditor: model.layerEditor)
                .navigationSplitViewColumnWidth(min: 310, ideal: sidebarWidth, max: 480)
                .background(ColumnWidthRecorder(key: ColumnWidthKeys.sidebar, name: "sidebar") { windowPolicy.setSidebarWidth($0) })
        } detail: {
            PreviewPane(model: model, preview: model.preview, playback: model.player, layerEditor: model.layerEditor)
                .frame(minWidth: WindowSizePolicy.detailMinWidth)
                .background(ColumnWidthRecorder(key: nil, name: "detail") { windowPolicy.detailWidth = $0 })
        }
    }

    /// A 1 pt separator with a 9 pt grab zone: dragging it resizes the
    /// panel live, within 360…560 and the space beside a 420 pt preview.
    private func panelDivider(totalWidth: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: Self.panelDivider)
            .overlay {
                Color.black.opacity(0.001)
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                // The panel's left edge follows the pointer.
                                let sidebar = sidebarVisible ? sidebarWidth + WindowSizePolicy.divider : 0
                                let available = totalWidth - sidebar - WindowSizePolicy.detailMinWidth - Self.panelDivider
                                let wanted = totalWidth - value.location.x - Self.panelDivider / 2
                                let upper = min(ColumnWidthKeys.inspectorMax, max(ColumnWidthKeys.inspectorMin, available))
                                inspectorWidth = min(upper, max(ColumnWidthKeys.inspectorMin, wanted)).rounded()
                            }
                    )
            }
    }

    /// Dev hook: `-debugDumpViews 1` prints the window's split-view layout
    /// (class, frame) a few seconds after launch, to see where the width goes.
    private func dumpViewsIfRequested() {
        guard UserDefaults.standard.bool(forKey: "debugDumpViews") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            guard let window = NSApp.windows.first(where: { $0.contentView != nil && $0.isVisible }), let root = window.contentView else { return }
            print("[debug] views: window \(Int(window.frame.width))×\(Int(window.frame.height))")
            @MainActor func dump(_ view: NSView, _ depth: Int) {
                let name = String(describing: type(of: view))
                let f = view.frame
                let interesting = name.contains("Split") || name.contains("Inspector") || name.contains("Sidebar") || name.contains("Hosting") || depth < 3
                if interesting {
                    print("[debug] views: " + String(repeating: "  ", count: depth) + "\(name) x=\(Int(f.minX)) w=\(Int(f.width)) h=\(Int(f.height))")
                }
                guard depth < 7 else { return }
                for sub in view.subviews { dump(sub, depth + 1) }
            }
            dump(root, 0)
        }
    }

    private func applyDebugWindowSize(_ spec: String, attempt: Int = 0) {
        let parts = spec.lowercased().split(separator: "x").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // The main window may not be on screen yet when onAppear runs;
            // retry for a few seconds.
            let mainWindow = NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0.contentView != nil }
            guard let window = mainWindow else {
                if attempt < 10 { applyDebugWindowSize(spec, attempt: attempt + 1) }
                else { print("[debug] window size: no main window found (\(NSApp.windows.count) windows)") }
                return
            }
            // setFrame ignores minSize on purpose: a restored frame or a
            // smaller screen can leave the window below it, and the layout
            // must cope (panel yields, sidebar collapses) rather than clip.
            var frame = window.frame
            frame.size = NSSize(width: parts[0], height: parts[1])
            window.setFrame(frame, display: true)
            let content = window.contentView?.frame.size ?? .zero
            print("[debug] window frame \(Int(window.frame.width))×\(Int(window.frame.height)) (asked \(Int(parts[0]))×\(Int(parts[1])), min \(Int(window.minSize.width))×\(Int(window.minSize.height)), content \(Int(content.width))×\(Int(content.height)))")
        }
    }

    /// The toolbar's machine icon reflects the link: streaming, connected, or not.
    private var machineIcon: String {
        let machine = model.machine
        if machine.isStreaming { return "dot.radiowaves.left.and.right" }
        return machine.isConnected ? "cpu.fill" : "cpu"
    }

    private var windowSubtitle: String {
        let base = model.projectURL == nil
            ? (model.projectFolder?.lastPathComponent ?? String(localized: "No project"))
            : (model.projectFolder?.lastPathComponent ?? "")
        return model.isProjectEdited ? base + String(localized: " — Edited") : base
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

        // The machine panel: connect, jog, zero, probe and send programs.
        ToolbarItem(placement: .primaryAction) {
            Toggle(isOn: $model.showMachineInspector) {
                Label("Machine", systemImage: machineIcon)
                    .labelStyle(.titleAndIcon)
            }
            .toggleStyle(.button)
            .help(model.machine.isConnected
                  ? "Machine panel — connected: \(model.machine.statusSummary)"
                  : "Show the Machine panel: connect to the controller over Wi‑Fi or USB, jog, set zero, probe and send programs.")
        }

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

/// UserDefaults keys for the remembered column widths and sidebar state.
nonisolated enum ColumnWidthKeys {
    static let sidebar = "ui.sidebarWidth"
    static let sidebarVisible = "ui.sidebarVisible"
    static let inspector = "ui.machineInspectorWidth"
    static let sidebarDefault = 360.0
    static let inspectorDefault = 410.0
    static let inspectorMin = 360.0
    static let inspectorMax = 560.0
}

/// Records a column's width in UserDefaults (`key`; debounced, whole points)
/// so the next launch restores it, and reports every measured width at
/// once through `onMeasure` (the window policy). Sits in the column's
/// `.background`, so it measures exactly what the column was given.
private struct ColumnWidthRecorder: View {
    var key: String?
    var name: String
    var onMeasure: (CGFloat) -> Void
    @State private var pending: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .onChange(of: geometry.size.width, initial: true) { _, width in record(width) }
        }
    }

    private func record(_ width: CGFloat) {
        guard width > 0 else { return }
        onMeasure(width)
        guard let key else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let rounded = width.rounded()
            if UserDefaults.standard.double(forKey: key) != rounded {
                UserDefaults.standard.set(rounded, forKey: key)
            }
            if UserDefaults.standard.string(forKey: "debugWindowSize") != nil {
                print("[debug] \(name) width \(Int(rounded))")
            }
        }
    }
}

/// Dev hook (`-debugWindowSize`): prints a view's frame in window
/// coordinates whenever it changes, to check the columns add up.
private struct FrameReporter: View {
    var name: String
    private static let enabled = UserDefaults.standard.string(forKey: "debugWindowSize") != nil

    var body: some View {
        if Self.enabled {
            GeometryReader { geometry in
                let frame = geometry.frame(in: .global)
                Color.clear
                    .onChange(of: frame, initial: true) { _, frame in
                        print("[debug] frame \(name): x=\(Int(frame.minX.rounded())) w=\(Int(frame.width.rounded())) h=\(Int(frame.height.rounded()))")
                    }
            }
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
                    Button(name) {
                        // A preset is a complete set: every drill file takes
                        // its drilling values too (one undo step puts the
                        // files' own values back).
                        params.drillLayerValues = [:]
                        params.apply(presets[name] ?? [:])
                    }
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
        .help("Save and recall complete parameter sets (tools, feeds, depths). Useful per material or per machine. Applying one also puts every drill file on the preset's drilling settings.")
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
