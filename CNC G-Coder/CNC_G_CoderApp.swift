//
//  CNC_G_CoderApp.swift
//  CNC G-Coder
//

import SwiftUI

@main
struct CNC_G_CoderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SettingsKeys.snapToGrid) private var snapToGrid = false

    var body: some Scene {
        WindowGroup {
            // The column minimums live on the columns; `WindowSizePolicy`
            // (ContentView) keeps the window at least as wide as their sum.
            // `RootSizeIsolator` answers the window's min/ideal size itself
            // (see its doc): a `.frame(minWidth:)` here would make every
            // SwiftUI update re-measure the whole hierarchy.
            RootSizeIsolator(minimum: CGSize(width: WindowSizePolicy.baseMinWidth, height: WindowSizePolicy.minHeight),
                             ideal: CGSize(width: 1440, height: 900)) {
                ContentView()
                    .environmentObject(model)
            }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") { model.newProject() }
                    .keyboardShortcut("n")
                Button("Open Project…") { model.openProject() }
                    .keyboardShortcut("o")
                Menu("Open Recent") {
                    ForEach(model.recentProjects, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) { model.openProject(at: url) }
                    }
                    Divider()
                    Button("Clear Menu") { model.clearRecentProjects() }
                        .disabled(model.recentProjects.isEmpty)
                }
                Divider()
                Button("Open Gerber Folder…") { model.openGerberFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Import Layer…") { model.importLayers() }
                    .keyboardShortcut("i")
                Button("New Custom Layer") { model.addCustomLayer() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Generate Test Board…") { model.showTestBoardDialog = true }
                    .keyboardShortcut("T", modifiers: [.command, .shift])
                Button("Tool Library…") { openWindow(id: "tools") }
                    .keyboardShortcut("L", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Project") { model.saveProject() }
                    .keyboardShortcut("s")
                Button("Save Project As…") { model.saveProjectAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            // One history for the whole app: parameters, layer files, drawing.
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.history.undo() }
                    .keyboardShortcut("z")
                Button("Redo") { model.history.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Select All Shapes") { model.editor.selectAll() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Duplicate Shapes") { model.editor.duplicateSelection() }
                    .keyboardShortcut("d")
                Button("Delete Shapes") { model.editor.deleteSelection() }
                Menu("Align Shapes") {
                    ForEach(ShapeEditor.AlignEdge.allCases) { edge in
                        Button(edge.title) { model.editor.align(edge) }
                    }
                }
                Menu("Distribute Shapes") {
                    ForEach(ShapeEditor.DistributeAxis.allCases) { axis in
                        Button(axis.title) { model.editor.distribute(axis) }
                    }
                }
            }
            CommandGroup(after: .toolbar) {
                Toggle("Snap to Grid", isOn: $snapToGrid)
                    .keyboardShortcut("'", modifiers: .command)
                // ⇧⌘M: plain ⌘M is Minimize.
                Toggle("Machine Panel", isOn: $model.showMachineInspector)
                    .keyboardShortcut("M", modifiers: [.command, .shift])
                // ⇧⌘. — ⌘. is the controlled stop (hold, rest, reset).
                Button("Emergency Stop") { model.machine.emergencyStop() }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                    .disabled(!model.machine.isConnected)
            }
            CommandGroup(replacing: .help) {
                Button("CNC G-Coder Help") { openWindow(id: "help") }
                    .keyboardShortcut("?", modifiers: .command)
            }
        }

        Window("Tool Library", id: "tools") {
            ToolLibraryView()
                .environmentObject(model)
        }

        // Machine control in a window of its own (opened from the inspector's
        // "Open in a window"); the same controls live in the main window's
        // Machine panel. Closing it does not stop a running job.
        Window("Machine", id: "machine") {
            MachineWindow()
                .environmentObject(model)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .defaultSize(width: 1180, height: 860)

        Window("CNC G-Coder Help", id: "help") {
            HelpView()
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

/// Asks to save an edited project before the app quits.
/// (It finds the model through AppModel.current: handing it over from a
/// view's onAppear inside the WindowGroup stopped the main window opening.)
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Double-clicked / dropped-on-Dock .cncproj files.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.pathExtension.lowercased() == ProjectDocument.fileExtension }) else { return }
        MainActor.assumeIsolated { AppModel.current?.openProject(at: url) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = MainActor.assumeIsolated({ AppModel.current }) else { return .terminateNow }
        return MainActor.assumeIsolated { model.confirmDiscardChanges() } ? .terminateNow : .terminateCancel
    }

    /// The built-in simulator is a child process; it must not outlive the app
    /// (an `atexit` handler and the script's own parent watchdog back this up).
    func applicationWillTerminate(_ notification: Notification) {
        SimulatorLauncher.terminateAll()
    }
}
