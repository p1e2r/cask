import AppKit
import CaskKit
import SwiftUI

@main
struct CaskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Cask") {
            ContentView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 540)
                .onAppear { delegate.attach(model) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Bottle") {
                Button("Refresh") { model.refresh() }
                    .keyboardShortcut("r")
                Button("Open Data Folder") { NSWorkspace.shared.open(CaskPaths.support) }
                Button("Open Logs Folder") {
                    try? FileManager.default.createDirectory(at: CaskPaths.logs, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(CaskPaths.logs)
                }
            }
        }
    }
}

/// Receives .exe/.msi files opened from Finder ("Open With → Cask" or double-click).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var queued: [URL] = []

    @MainActor
    func attach(_ model: AppModel) {
        self.model = model
        if !queued.isEmpty {
            model.pendingOpen = queued
            queued = []
        }
    }

    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        if let model { model.pendingOpen = urls } else { queued += urls }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
