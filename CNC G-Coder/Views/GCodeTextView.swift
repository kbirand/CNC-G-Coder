import SwiftUI
import Combine

/// Loads one generated .ngc file for display, with line-offset indexing so the
/// playback slider can highlight the current source line.
@MainActor
final class GCodeTextModel: ObservableObject {
    nonisolated static let maxBytes = 8 * 1024 * 1024

    @Published var selectedLayer: LayerKind?
    @Published private(set) var text = ""
    @Published private(set) var version = 0
    @Published private(set) var truncated = false

    private(set) var lineStarts: [Int] = []   // UTF-16 offset of each line start
    private(set) var utf16Length = 0
    private var loadedURL: URL?
    private var loadTask: Task<Void, Never>?

    func reload(from document: PreviewDocument?) {
        guard let document, let selectedLayer,
              let layer = document.layers.first(where: { $0.id == selectedLayer }) else {
            loadedURL = nil
            setContent("", lineStarts: [], utf16Length: 0, truncated: false)
            return
        }
        let url = layer.fileURL
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { () -> (String, [Int], Int, Bool) in
                guard var data = try? Data(contentsOf: url) else { return ("", [], 0, false) }
                var truncated = false
                if data.count > GCodeTextModel.maxBytes {
                    data = data.prefix(GCodeTextModel.maxBytes)
                    if let lastNewline = data.lastIndex(of: 0x0A) {
                        data = data.prefix(upTo: lastNewline)
                    }
                    truncated = true
                }
                let string = String(decoding: data, as: UTF8.self)
                var starts = [0]
                var offset = 0
                for unit in string.utf16 {
                    offset += 1
                    if unit == 10 { starts.append(offset) }
                }
                return (string, starts, offset, truncated)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.loadedURL = url
            self.setContent(loaded.0, lineStarts: loaded.1, utf16Length: loaded.2, truncated: loaded.3)
        }
    }

    private func setContent(_ text: String, lineStarts: [Int], utf16Length: Int, truncated: Bool) {
        self.text = text
        self.lineStarts = lineStarts
        self.utf16Length = utf16Length
        self.truncated = truncated
        self.version += 1
    }

    /// UTF-16 range of a 1-based line number, or nil if out of range (e.g. truncated away).
    func rangeOfLine(_ line: Int) -> NSRange? {
        guard line >= 1, line <= lineStarts.count else { return nil }
        let start = lineStarts[line - 1]
        let end = line < lineStarts.count ? lineStarts[line] : utf16Length
        guard end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }
}

/// The "G-code" preview tab: output-file picker + raw text with playback sync.
struct GCodeTextTab: View {
    @ObservedObject var preview: PreviewController
    @ObservedObject var playback: PlaybackState
    @StateObject private var textModel = GCodeTextModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("File", selection: $textModel.selectedLayer) {
                    ForEach(preview.document?.layers ?? []) { layer in
                        Text(layer.fileURL.lastPathComponent).tag(Optional(layer.id))
                    }
                }
                .frame(maxWidth: 340)
                .disabled(preview.document == nil)

                if textModel.truncated {
                    Label("Large file — first 8 MB shown", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
            .padding(8)

            Divider()

            if preview.document == nil {
                ContentUnavailableView("No G-code yet",
                                       systemImage: "doc.text.magnifyingglass",
                                       description: Text("Choose a project folder and refresh the preview."))
            } else {
                MonoTextView(text: textModel.text,
                             contentVersion: textModel.version,
                             highlightRange: highlightRange)
            }
        }
        .onAppear {
            syncSelection()
            textModel.reload(from: preview.document)
        }
        .onChange(of: preview.document?.token) {
            syncSelection()
            textModel.reload(from: preview.document)
        }
        .onChange(of: textModel.selectedLayer) {
            textModel.reload(from: preview.document)
        }
    }

    /// Follow the playback layer selection by default; keep valid otherwise.
    private func syncSelection() {
        guard let document = preview.document else {
            textModel.selectedLayer = nil
            return
        }
        if let playbackLayer = playback.selectedLayer,
           document.layers.contains(where: { $0.id == playbackLayer }),
           textModel.selectedLayer == nil {
            textModel.selectedLayer = playbackLayer
        } else if textModel.selectedLayer == nil || !document.layers.contains(where: { $0.id == textModel.selectedLayer }) {
            textModel.selectedLayer = document.layers.first?.id
        }
    }

    private var highlightRange: NSRange? {
        guard textModel.selectedLayer == playback.selectedLayer,
              let move = playback.currentMove else { return nil }
        return textModel.rangeOfLine(move.sourceLine)
    }
}
