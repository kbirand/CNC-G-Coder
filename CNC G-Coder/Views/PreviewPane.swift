import SwiftUI

/// Right pane: preview tabs (Toolpath / G-code / Log) with a status header,
/// the side view, and a floating glass playback bar over the canvas.
struct PreviewPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preview: PreviewController
    @ObservedObject var playback: PlaybackState

    @AppStorage("sideViewVisible") private var showSideView = true
    @AppStorage("layout.sideViewHeight") private var sideViewHeight = 180.0
    @AppStorage("previewShowAllLayers") private var showAllLayers = false
    @AppStorage("previewShowToolWidth") private var showToolWidth = true
    @AppStorage("previewFlipBackView") private var flipBackView = false
    @AppStorage("previewShowRulers") private var showRulers = true
    @AppStorage("previewShowGuides") private var showGuides = true
    @AppStorage("preview3D") private var show3D = false
    @AppStorage(SettingsKeys.snapToGrid) private var snapToGrid = false
    @AppStorage("previewGuidesX") private var guidesXRaw = ""
    @AppStorage("previewGuidesY") private var guidesYRaw = ""

    private enum Tab: String, CaseIterable {
        case toolpath = "Toolpath"
        case gcode = "G-code"
        case log = "Log"
    }
    /// A failure the user closed; its card stays hidden until the next failure.
    @State private var dismissedFailure: String?
    // Dev hook: launch with `-debugTab gcode|log` to open a specific tab.
    @State private var tab: Tab = {
        switch UserDefaults.standard.string(forKey: "debugTab") {
        case "gcode": .gcode
        case "log": .log
        default: .toolpath
        }
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch tab {
            case .toolpath: toolpathTab
            case .gcode: GCodeTextTab(preview: preview, playback: playback)
            case .log: LogView(model: model)
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
        guard fraction > 0 || layerName != nil else { return }
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
        // `-debugPlay 1` also starts playback (e.g. to profile it).
        if UserDefaults.standard.bool(forKey: "debugPlay") { playback.isPlaying = true }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            .help("Toolpath: graphical preview with playback. G-code: the raw .ngc text, synced to playback. Log: pcb2gcode output with per-step timings.")

            statusView

            Spacer()

            if preview.isStale, case .ready = preview.phase {
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
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
                Text("Running pcb2gcode…")
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
        VStack(spacing: 0) {
            Group {
                if show3D {
                    Toolpath3DView(preview: preview, playback: playback,
                                   tool: playback.selectedLayer.flatMap { model.toolGeometry(for: $0) })
                } else {
                    ToolpathCanvasView(preview: preview, playback: playback, params: model.parameters)
                }
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The last result stays visible while it is being replaced,
                // dimmed so it reads as "about to change".
                .opacity(isRegenerating ? 0.45 : 1)
                .saturation(isRegenerating ? 0.3 : 1)
                .animation(.easeInOut(duration: 0.25), value: isRegenerating)
                .overlay { statusCard }
                .overlay(alignment: .topLeading) {
                    if !show3D {
                        canvasNotes
                            .padding(.leading, showRulers ? ToolpathCanvasView.leftGutter : 0)
                            .padding(.top, showRulers ? ToolpathCanvasView.topGutter : 0)
                    }
                }
                .overlay(alignment: .bottom) {
                    PlaybackControls(preview: preview, playback: playback)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
            if showSideView {
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
        preview.document != nil && preview.phase == .running
    }

    /// One card in the middle of the canvas for every generation state —
    /// first load and updates alike. Its content changes in place (waiting →
    /// progress → gone), so it never jumps around.
    @ViewBuilder
    private var statusCard: some View {
        let hasPreview = preview.document != nil
        Group {
            switch preview.phase {
            case .debouncing:
                cardBody {
                    Label(hasPreview ? "Preview updates after your edits…" : "Preview starts after your edits…",
                          systemImage: "clock")
                        .font(.headline)
                    Text("Waiting a moment in case you are still typing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .running:
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
            Text(progress?.label ?? "Starting pcb2gcode")
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
