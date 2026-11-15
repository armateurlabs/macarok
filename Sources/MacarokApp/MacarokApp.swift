import SwiftUI

@main
struct MacarokApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Macarok", id: "main") {
            MainWindow(model: model)
                .frame(minWidth: 1050, minHeight: 680)
                .preferredColorScheme(model.settings.appearance.colorScheme)
                .task { delegate.model = model; await model.start() }
                .onOpenURL { model.openURL($0) }
        }
        .defaultSize(width: 1380, height: 860)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands { MacarokCommands(model: model) }

        Settings {
            SettingsView(model: model)
                .preferredColorScheme(model.settings.appearance.colorScheme)
        }
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        model.pausePlayback()
        model.scrobbling?.end()
        model.cancelRefresh()
        model.podcastDownloads?.cancelAll()
        Task { @MainActor in
            await model.flushQueue()
            await model.scrobbling?.flush()
            await model.finishPlaybackAccess()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
