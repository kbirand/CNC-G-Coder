import SwiftUI

/// App settings: how the preview refreshes when parameters change.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(SettingsKeys.refreshMode) private var refreshMode = PreviewRefreshMode.auto.rawValue
    @AppStorage(SettingsKeys.debounceSeconds) private var debounceSeconds = 1.0

    var body: some View {
        Form {
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
        .frame(width: 430)
        .onChange(of: refreshMode) {
            // Switching to automatic with a stale preview kicks one refresh.
            if refreshMode == PreviewRefreshMode.auto.rawValue, model.preview.isStale {
                model.preview.refreshNow()
            }
        }
    }
}
