import SwiftUI

/// Right pane: preview tabs (Toolpath / G-code / Log) with a status header,
/// the side view, and a floating glass playback bar over the canvas.
struct PreviewPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preview: PreviewController
    @ObservedObject var playback: PlaybackState
    @ObservedObject var layerEditor: LayerFileEditor

    @AppStorage("sideViewVisible") private var showSideView = true
    @AppStorage("layout.sideViewHeight") private var sideViewHeight = 180.0
    @AppStorage("previewShowAllLayers") private var showAllLayers = false
    @AppStorage("previewShowToolWidth") private var showToolWidth = true
    @AppStorage("previewFlipBackView") private var flipBackView = false
    @AppStorage("previewShowRulers") private var showRulers = true
    @AppStorage("previewShowGuides") private var showGuides = true
    @AppStorage("preview3D") private var show3D = false
    @AppStorage("previewShowHeightMap") private var showHeightMap = true
    @AppStorage("preview3DHeightMapExaggeration") private var heightMapExaggeration = 10.0
    @AppStorage("previewShowMachineTravel") private var showMachineTravel = true
    @AppStorage("preview3DShowHoles") private var showHoles = true
    @AppStorage("preview3DShowPaths") private var showPaths = true
    @AppStorage("preview3DShowCuts") private var showCuts = true
    @AppStorage("machine.inspectorTab") private var inspectorTab = MachineInspectorTab.control.rawValue
    @AppStorage(SettingsKeys.snapToGrid) private var snapToGrid = false
    @AppStorage("previewGuidesX") private var guidesXRaw = ""
    @AppStorage("previewGuidesY") private var guidesYRaw = ""
    @AppStorage("ui.sectionOverride") private var sectionOverride = ""

    /// A drawn layer is being edited: the canvas is a drawing board, so the
    /// regeneration cards and dimming that follow every edit stay out of the way.
    private var editorActive: Bool {
        (sectionOverride.isEmpty && playback.selectedLayer?.isCustom == true) || layerEditor.target != nil
    }

    private enum Tab: String, CaseIterable {
        case toolpath = "Toolpath"
        case gcode = "G-code"
        case log = "Log"
        case console = "Console"
    }
    /// A failure the user closed; its card stays hidden until the next failure.
    @State private var dismissedFailure: String?
    // Dev hook: launch with `-debugTab gcode|log|console` to open a specific tab.
    @State private var tab: Tab = {
        switch UserDefaults.standard.string(forKey: "debugTab") {
        case "gcode": .gcode
        case "log": .log
        case "console": .console
        default: .toolpath
        }
    }()

    var body: some View {
        let _ = DebugFlags.renderLog ? Self._printChanges() : ()
        VStack(spacing: 0) {
            header
            Divider()
            switch tab {
            case .toolpath: toolpathTab
            case .gcode: GCodeTextTab(preview: preview, playback: playback)
            case .log: LogView(model: model)
            case .console: ConsoleTab(machine: model.machine)
            }
        }
        .onAppear {
            playback.preview = preview
            playback.syncToDocument()
        }
        .onChange(of: preview.document?.token) {
            playback.syncToDocument()
            applyDebugScrub()
        }
    }

    /// Dev hook: launch with `-debugScrub 0.5` to scrub the last layer to 50%.
    /// Applies to the FIRST generated document only — later refreshes must not
    /// steal the user's layer selection or timeline position.
    @State private var didApplyDebugScrub = false
    private func applyDebugScrub() {
        guard !didApplyDebugScrub, let doc = preview.document else { return }
        let fraction = UserDefaults.standard.double(forKey: "debugScrub")
        let layerName = UserDefaults.standard.string(forKey: "debugLayer")
        let play = UserDefaults.standard.bool(forKey: "debugPlay")
        guard fraction > 0 || layerName != nil || play else { return }
        didApplyDebugScrub = true
        if let layerName {
            playback.selectedLayer = doc.layers.first {
                $0.displayName.localizedCaseInsensitiveContains(layerName)
            }?.id ?? playback.selectedLayer
        } else {
            playback.selectedLayer = doc.layers.last?.id
        }
        if fraction > 0 {
            playback.currentTime = playback.totalTime * min(fraction, 1)
        }
        // `-debugPlay 1` also starts playback (e.g. to profile it), of the
        // selected layer or — alone — the first one.
        if play {
            if playback.selectedLayer == nil { playback.selectedLayer = doc.layers.first?.id }
            playback.isPlaying = true
        }
    }

    // MARK: - Header

    /// One row when it fits; two rows (tabs + status, then the view
    /// controls) when the preview column is squeezed between a wide sidebar
    /// and a wide Machine panel — the row's intrinsic width must never force
    /// the window wider than the screen.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                tabPicker
                statusView
                Spacer(minLength: 8)
                headerControls
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    tabPicker
                    statusView
                    Spacer(minLength: 0)
                }
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    headerControls
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var tabPicker: some View {
        Picker("", selection: $tab) {
            ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 340)
        .help("Toolpath: graphical preview with playback. G-code: the raw .ngc text, synced to playback. Log: the generator's output with per-step timings. Console: the conversation with the machine controller.")
    }

    @ViewBuilder
    private var headerControls: some View {
        if preview.showsExternalFile, case .ready = preview.phase {
            WarningPill(text: "Test file", color: .blue, icon: "doc.text",
                        help: "Showing a test file exactly as it was written to disk — it is not built from the project settings. Open or refresh a project to preview its programs again.")
        } else if preview.isStale, case .ready = preview.phase {
            WarningPill(text: "Out of date", color: .orange, icon: "clock.arrow.circlepath",
                        help: "Parameters changed since this preview was generated")
        }

        if tab == .toolpath {
            Picker("", selection: $show3D) {
                Text("2D").tag(false)
                Text("3D").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("2D: the flat toolpath view with rulers and guides. 3D: orbit around the board — drag to orbit, right- or middle-drag to pan, scroll or pinch to zoom; the gizmo at the top right jumps to top, front, side or isometric views.")

            viewOptionsMenu

            Toggle(isOn: $showSideView) {
                Image(systemName: "rectangle.split.1x2")
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help("Show side (Z) view")
        }

        Button {
            preview.refreshNow()
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .controlSize(.small)
        .disabled(!preview.canPreview || preview.phase == .running)
        .help("Regenerate the preview with the current parameters")
    }

    private var viewOptionsMenu: some View {
        Menu {
            Toggle(isOn: $showToolWidth) {
                Label("Tool Width", systemImage: "circle.circle")
            }
            .help("Show cutting moves at the real cutter diameter (material removed), not just the tool centerline")
            Toggle(isOn: $showRulers) {
                Label("Rulers", systemImage: "ruler")
            }
            .help("Rulers along the top (X) and left (Y) edges, with a crosshair readout of the cursor position. Coordinates are the ones in the G-code — with 'Un-mirror Back Side' on, back-side programs read in their un-mirrored screen position instead.")
            Toggle(isOn: $showGuides) {
                Label("Guides", systemImage: "ruler.fill")
            }
            .help("Drag out of a ruler to place a guide, drag a guide to move it, and drop it back outside the drawing area to remove it. Guides snap to ruler ticks and hold machine positions, so they stay put through zoom, pan and layer changes.")
            Button {
                guidesXRaw = ""
                guidesYRaw = ""
            } label: {
                Label("Clear Guides", systemImage: "trash")
            }
            .disabled(guidesXRaw.isEmpty && guidesYRaw.isEmpty)
            Toggle(isOn: $snapToGrid) {
                Label("Snap to Grid", systemImage: "squareshape.split.3x3")
            }
            .help("Moving the origin (dragging the X0 Y0 marker, or Set Origin) lands on the grid lines shown in the view, so it moves in whole grid steps. Project corners, centre and drill holes still take precedence when you are close to one. Zoom in for a finer grid.")
            Toggle(isOn: $showAllLayers) {
                Label("All Layers Overlay", systemImage: "square.3.layers.3d")
            }
            .help("Overlay every program behind the selected one. Programs share one origin per side, so copper, drills and masks align — enable Un-mirror Back Side to overlay the mirrored back side aligned too.")
            if preview.document?.layers.contains(where: { $0.id == .back || $0.id == .maskBottom }) == true {
                Toggle(isOn: $flipBackView) {
                    Label("Un-mirror Back Side", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .help("DISPLAY ONLY. Back-side programs are genuinely mirrored — they have to be, to machine correctly once you turn the board over — so on screen they sit mirrored against the front. This un-mirrors them for viewing so the two sides overlay and you can check registration. It changes nothing in the generated G-code, and it is unrelated to \"Board flips\" in Machine setup, which chooses the axis the machining actually uses.")
            }
            Divider()
            Toggle(isOn: $showHeightMap) {
                Label("Height Map", systemImage: "square.grid.3x3.topleft.filled")
            }
            .help("Show the probed height map (autolevel grid) of the shown side under the programs: the interpolation grid and every point coloured from blue (lowest) to red (highest), labelled with its height when zoomed in. The map is shown regardless while it is being probed, while the Machine panel is on its Height Map tab, and when the loaded machine program uses it. Probe one in the Machine panel's Height Map tab.")
            Picker(selection: $heightMapExaggeration) {
                Text("×1").tag(1.0)
                Text("×10").tag(10.0)
                Text("×20").tag(20.0)
                Text("×50").tag(50.0)
            } label: {
                Label("Height map exaggeration", systemImage: "arrow.up.and.down")
            }
            .help("How much the 3D view stretches the height map's Z, so a warp of a tenth of a millimetre is visible")
            Toggle(isOn: $showPaths) {
                Label("Toolpath Lines", systemImage: "scribble")
            }
            .help("3D: show the programs' toolpath lines. Off, only the board, the holes, the material removal and the tool are drawn — the clearest view of what happens to the board")
            Toggle(isOn: $showHoles) {
                Label("Drill Holes", systemImage: "circle.dotted")
            }
            .help("3D: drill programs as holes of the bit's diameter and the drilling depth, appearing as the bit plunges during playback or live machining")
            Toggle(isOn: $showCuts) {
                Label("Material Removal", systemImage: "paintbrush.pointed")
            }
            .help("3D: paint what the programs take off the board onto its faces — isolation cuts bare the substrate, deep cuts are dark, drills are black discs — as far as playback or the live job has come")
            Divider()
            Toggle(isOn: $showMachineTravel) {
                Label("Machine Travel", systemImage: "rectangle.dashed")
            }
            .help("While connected: the machine's travel area (its axis ranges, from the controller's settings) as a dashed outline around the work, with the home corner marked. It is never part of the default framing — use Fit Machine Travel to see it whole.")
            Button {
                model.travelFitRequest += 1
            } label: {
                Label("Fit Machine Travel", systemImage: "arrow.down.left.and.arrow.up.right.rectangle")
            }
            .disabled(!(model.machine.isConnected && model.machine.workTravelRect != nil))
            .help("Frame the whole travel area once (double-click or Fit returns to the board)")
        } label: {
            Label("View Options", systemImage: "eye")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Display options: tool-width swath, all-layer overlay, back-side flip")
    }

    @ViewBuilder
    private var statusView: some View {
        switch preview.phase {
        case .idle:
            Text("Preview idle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .debouncing:
            Text("Waiting for edits…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Generating toolpaths…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .ready:
            Label("Preview ready", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
                .help(message)
        }
    }

    // MARK: - Toolpath tab

    private var toolpathTab: some View {
        BodyCounter.count("PreviewPane.toolpathTab")
        return VStack(spacing: 0) {
            Group {
                if show3D {
                    Toolpath3DView(preview: preview, playback: playback,
                                   tool: playback.displayedKind.flatMap { model.toolGeometry(for: $0) },
                                   machine: model.machine,
                                   heightMap: model.heightMapOverlay(toggle: showHeightMap, inspectorTab: inspectorTab),
                                   heightMapExaggeration: heightMapExaggeration,
                                   showHoles: showHoles, showPaths: showPaths, showCuts: showCuts)
                } else {
                    ToolpathCanvasView(preview: preview, playback: playback, params: model.parameters,
                                       model: model, editor: model.editor, layerEditor: model.layerEditor)
                }
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The last result stays visible while it is being replaced,
                // dimmed so it reads as "about to change".
                .opacity(isRegenerating ? 0.45 : 1)
                .saturation(isRegenerating ? 0.3 : 1)
                .animation(.easeInOut(duration: 0.25), value: isRegenerating)
                .overlay { statusCard }
                .overlay(alignment: .top) {
                    if show3D, editorActive {
                        HStack(spacing: 10) {
                            Image(systemName: "pencil.and.outline")
                            Text(layerEditor.target != nil ? "Layer editing is in the 2D view" : "Drawing tools are in the 2D view")
                            Button("Edit in 2D") { show3D = false }
                        }
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .glassEffect()
                        .padding(.top, 10)
                    }
                }
                // The notes sit at the top right, clear of the tool strip and
                // editor bars at the top left.
                .overlay(alignment: .topTrailing) {
                    if !show3D {
                        canvasNotes
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 420, alignment: .trailing)
                            .padding(.top, showRulers ? ToolpathCanvasView.topGutter : 0)
                    }
                }
                .overlay(alignment: .bottom) {
                    if playback.job != nil {
                        // A program is being sent: the machine drives the
                        // clock, so the job bar replaces the player — even
                        // mid layer-edit, the job must stay controllable.
                        JobBar(machine: model.machine, compact: true)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    } else if layerEditor.target == nil {
                        // Editing a layer file: no program to play until editing ends.
                        PlaybackControls(preview: preview, playback: playback)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                    }
                }
            if showSideView, layerEditor.target == nil {
                SplitDragHandle(axisVertical: false) { delta in
                    sideViewHeight = min(500, max(90, sideViewHeight - Double(delta)))
                }
                SideViewCanvas(model: model, preview: preview, playback: playback)
                    .frame(height: sideViewHeight)
            }
        }
    }

    // MARK: - Generation status on the canvas

    /// A run is replacing a preview that is still on screen.
    private var isRegenerating: Bool {
        preview.document != nil && preview.phase == .running && !editorActive
    }

    /// One card in the middle of the canvas for every generation state —
    /// first load and updates alike. Its content changes in place (waiting →
    /// progress → gone), so it never jumps around.
    @ViewBuilder
    private var statusCard: some View {
        let hasPreview = preview.document != nil
        Group {
            switch preview.phase {
            case .debouncing where !editorActive:
                cardBody {
                    Label(hasPreview ? "Preview updates after your edits…" : "Preview starts after your edits…",
                          systemImage: "clock")
                        .font(.headline)
                    Text("Waiting a moment in case you are still typing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .running where !editorActive:
                cardBody {
                    progressBlock(title: hasPreview ? "Updating preview" : "Generating preview")
                    HStack {
                        if hasPreview {
                            Text("The previous result stays visible until the new one is ready.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Stop") { Task { await preview.cancelActiveRun() } }
                            .controlSize(.small)
                            .help(hasPreview ? "Stop — keep showing the previous result" : "Stop generating")
                    }
                }
            case .failed(let message) where dismissedFailure != message:
                cardBody {
                    failureBlock(message, hasPreview: hasPreview)
                }
            default:
                EmptyView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: preview.phase)
    }

    private func cardBody<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .frame(width: 340, alignment: .leading)
            .padding(18)
            .glassEffect(in: .rect(cornerRadius: 16))
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    private func progressBlock(title: String) -> some View {
        let progress = preview.progress
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let progress {
                    Text("\(min(progress.step + 1, progress.total)) of \(progress.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: progress?.fraction ?? 0)
                .progressViewStyle(.linear)
                .animation(.easeOut(duration: 0.3), value: progress?.fraction)
            Text(progress?.label ?? "Starting")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func failureBlock(_ message: String, hasPreview: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(hasPreview ? "Update failed" : "Preview failed", systemImage: "xmark.octagon.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(4)
            if hasPreview {
                Text("Showing the last good preview.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Show Log") { tab = .log }
                Button("Try Again") { preview.refreshNow() }
                Spacer()
                if hasPreview {
                    Button("Close") { dismissedFailure = message }
                }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var canvasNotes: some View {
        VStack(alignment: .leading, spacing: 3) {
            if flipBackView {
                Text("Back side un-mirrored for viewing only — the G-code stays mirrored for the CNC")
            } else if showAllLayers,
                      preview.document?.layers.contains(where: { $0.id == .back || $0.id == .maskBottom }) == true {
                Text("Back-side programs are mirrored, so they sit mirrored against the front — enable \"Un-mirror Back Side\" in View Options to overlay them aligned")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(10)
    }
}


/// `-debugDumpViews`: how often a view body is evaluated (printed per 5 s).
@MainActor
enum BodyCounter {
    private static let enabled = UserDefaults.standard.bool(forKey: "debugDumpViews")
    private static var counts: [String: Int] = [:]
    private static var since: TimeInterval = 0

    private static var times: [String: (total: Double, max: Double, count: Int)] = [:]

    static func count(_ name: String) {
        guard enabled else { return }
        counts[name, default: 0] += 1
        report()
    }

    /// Accumulates a drawing time (seconds) under `name`.
    static func time(_ name: String, _ seconds: Double) {
        guard enabled else { return }
        var e = times[name] ?? (0, 0, 0)
        e.total += seconds * 1000; e.max = max(e.max, seconds * 1000); e.count += 1
        times[name] = e
        report()
    }

    private static func report() {
        let now = CACurrentMediaTime()
        if since == 0 { since = now; return }
        guard now - since >= 5 else { return }
        var parts = counts.sorted { $0.key < $1.key }.map { String(format: "%@ %.1f/s", $0.key as NSString, Double($0.value) / (now - since)) }
        parts += times.sorted { $0.key < $1.key }.map {
            String(format: "%@ %.1f/s avg %.2f ms max %.1f ms", $0.key as NSString, Double($0.value.count) / (now - since),
                   $0.value.total / Double(max($0.value.count, 1)), $0.value.max)
        }
        print("[debug] body evaluations: " + parts.joined(separator: ", "))
        counts = [:]
        times = [:]
        since = now
    }
}
