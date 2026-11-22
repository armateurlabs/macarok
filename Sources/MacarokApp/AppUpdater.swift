import AppKit
import Foundation
import Observation
import Sparkle

/// Sparkle's standard updater: a daily check that the user can turn off, a manual check, and native
/// windows that show the release notes and install only on confirmation. The installed update replaces
/// the running app and relaunches it. Outside an installed app bundle (tests, `swift run`) it stays off.
@MainActor @Observable
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
    private(set) var canCheckForUpdates = false
    private(set) var lastUpdateCheckDate: Date?
    /// Mirrors Sparkle's persisted preference so views refresh when it changes.
    private var automaticChecks = false

    var isAvailable: Bool { controller != nil }

    var automaticallyChecksForUpdates: Bool {
        get { automaticChecks }
        set {
            controller?.updater.automaticallyChecksForUpdates = newValue
            automaticChecks = controller?.updater.automaticallyChecksForUpdates ?? false
        }
    }

    init(bundle: Bundle = .main) {
        super.init()
        guard Self.canUpdate(bundle) else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
        automaticChecks = controller.updater.automaticallyChecksForUpdates
        lastUpdateCheckDate = controller.updater.lastUpdateCheckDate
    }

    /// Only an installed application declares a feed and the key that verifies its updates.
    nonisolated static func canUpdate(_ bundle: Bundle) -> Bool {
        bundle.bundleURL.pathExtension == "app"
            && (bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String)?.isEmpty == false
            && (bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?.isEmpty == false
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        MainActor.assumeIsolated { lastUpdateCheckDate = updater.lastUpdateCheckDate }
    }
}
