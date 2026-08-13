import SwiftUI

/// The append-only process log (pcb2gcode/gerbv command echoes and output).
struct LogView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        MonoTextView(text: model.log,
                     contentVersion: model.log.count,
                     autoScrollToBottom: true)
    }
}
