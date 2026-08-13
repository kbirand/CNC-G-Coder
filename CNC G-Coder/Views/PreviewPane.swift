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

    private enum Tab: String, CaseIterable {
        case toolpath = "Toolpath"
        case gcode = "G-code"
        case log = "Log"
    }
    // Dev hook: launch with `-debugTab gcode|log` to open a specific tab.
    @State private var tab: Tab = switch UserDefaults.standard.string(forKey: "debugTab") {
    case "gcode": .gcode
    case "log": .log
    default: .toolpath
    }

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
            Toggle(isOn: $showAllLayers) {
                Label("All Layers Overlay", systemImage: "square.3.layers.3d")
            }
            .help("Overlay every program behind the selected one. Programs share one origin per side, so copper, drills and masks align — enable Flip Back View to overlay the mirrored back side aligned too.")
            if preview.document?.layers.contains(where: { $0.id == .back || $0.id == .maskBottom }) == true {
                Toggle(isOn: $flipBackView) {
                    Label("Flip Back View", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .help("Un-mirror back-side programs on screen to check alignment against the front. Display only — the generated G-code stays mirrored, ready for the CNC.")
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
            ToolpathCanvasView(preview: preview, playback: playback, params: model.parameters)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) { canvasNotes }
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

    @ViewBuilder
    private var canvasNotes: some View {
        VStack(alignment: .leading, spacing: 3) {
            if flipBackView {
                Text("Back flipped for viewing — G-code stays mirrored for the CNC")
            } else if showAllLayers,
                      preview.document?.layers.contains(where: { $0.id == .back || $0.id == .maskBottom }) == true {
                Text("Back-side programs are mirrored — enable Flip Back View to overlay them aligned")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(10)
    }
}
