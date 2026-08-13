//
//  CNC_G_CoderApp.swift
//  CNC G-Coder
//

import SwiftUI

@main
struct CNC_G_CoderApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1180, minHeight: 720)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Generate Test Board…") { model.showTestBoardDialog = true }
                    .keyboardShortcut("T", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("CNC G-Coder Help") { openWindow(id: "help") }
                    .keyboardShortcut("?", modifiers: .command)
            }
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
