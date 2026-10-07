import SwiftUI

/// App settings: General (display units, preview refresh) and Machine (the
/// `machine.*` connection, jog, probe and motion defaults).
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    /// Dev hook `-debugSettingsTab machine` opens on that tab.
    @State private var tab = UserDefaults.standard.string(forKey: "debugSettingsTab") ?? "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsPane()
                .environmentObject(model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            MachineSettingsPane()
                .environmentObject(model)
                .tabItem { Label("Machine", systemImage: "cpu") }
                .tag("machine")
        }
        .frame(width: 520)
        .background(SettingsSnapshotHook())
    }
}

/// Dev hook `-debugSettingsSnapshot /path.png`: renders the Settings window's
/// content offscreen 2 s after it appears (no screen capture involved).
private struct SettingsSnapshotHook: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        guard let path = UserDefaults.standard.string(forKey: "debugSettingsSnapshot") else { return view }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak view] in
            // `-debugSettingsScroll bottom` scrolls the form to its end first.
            func scrollView(_ v: NSView) -> NSScrollView? {
                if let scroll = v as? NSScrollView { return scroll }
                for sub in v.subviews { if let found = scrollView(sub) { return found } }
                return nil
            }
            guard let content = view?.window?.contentView else { print("[debug] settings snapshot: no window"); return }
            if UserDefaults.standard.string(forKey: "debugSettingsScroll") == "bottom", let scroll = scrollView(content), let doc = scroll.documentView {
                let y = max(0, doc.bounds.height - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? y : 0))
                scroll.reflectScrolledClipView(scroll.contentView)
                content.layoutSubtreeIfNeeded()
                content.displayIfNeeded()
            }
            guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
            content.cacheDisplay(in: content.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
                print("[debug] settings snapshot written to \(path) (\(Int(content.bounds.width))×\(Int(content.bounds.height)))")
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Display units and how the preview refreshes when parameters change.
private struct GeneralSettingsPane: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(SettingsKeys.refreshMode) private var refreshMode = PreviewRefreshMode.auto.rawValue
    @AppStorage(SettingsKeys.debounceSeconds) private var debounceSeconds = 1.0
    @AppStorage(SettingsKeys.unitSystem) private var unitSystem = UnitSystem.metric.rawValue

    var body: some View {
        Form {
            Picker("Units:", selection: $unitSystem) {
                ForEach(UnitSystem.allCases) { unit in
                    Text(unit.title).tag(unit.rawValue)
                }
            }
            .pickerStyle(.radioGroup)

            Text("Changes the numbers you read and type — parameter fields, rulers, guides and the playback readout. The generated programs stay metric (G21), which is what the mm-based Gerber and drill files describe.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
                .padding(.vertical, 4)

            Picker("Preview refresh:", selection: $refreshMode) {
                Text("Automatic — after parameter edits").tag(PreviewRefreshMode.auto.rawValue)
                Text("Manual — Refresh button only").tag(PreviewRefreshMode.manual.rawValue)
            }
            .pickerStyle(.radioGroup)

            if refreshMode == PreviewRefreshMode.auto.rawValue {
                HStack {
                    Slider(value: $debounceSeconds, in: 0.3...3.0, step: 0.1) {
                        Text("Delay after last edit:")
                    }
                    Text("\(debounceSeconds, specifier: "%.1f") s")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                Text("The preview regenerates this long after you stop typing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .onChange(of: refreshMode) {
            // Switching to automatic with a stale preview kicks one refresh.
            if refreshMode == PreviewRefreshMode.auto.rawValue, model.preview.isStale {
                model.preview.refreshNow()
            }
        }
    }
}
