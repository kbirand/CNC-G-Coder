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
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1180, minHeight: 720)
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
            CommandGroup(after: .toolbar) {
                Toggle("Snap to Grid", isOn: $snapToGrid)
                    .keyboardShortcut("'", modifiers: .command)
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
}
