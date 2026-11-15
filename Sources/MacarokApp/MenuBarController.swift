import AppKit
import Combine
import Foundation
import MacarokAudio
import Observation

@MainActor
protocol MenuBarHosting: AnyObject {
    /// Repeated updates must reuse the same native status item.
    func show(menu: NSMenu)
    func hide()
}

/// A status item observes playback state and selected queue metadata, never the high-frequency clock.
@MainActor
final class MenuBarController: NSObject {
    private weak var model: AppModel?
    private let host: MenuBarHosting
    private let menu = NSMenu(title: "Macarok")
    private var stateObservation: AnyCancellable?
    private var playbackState: PlaybackState
    private var observationGeneration = UUID()
    private var stopped = false
    private var lastSnapshot: Snapshot?

    init(model: AppModel, host: MenuBarHosting? = nil) {
        self.model = model; self.host = host ?? NativeMenuBarHost()
        playbackState = model.player.state
        super.init()
        buildMenu()
        stateObservation = model.player.$state.dropFirst().removeDuplicates().sink { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                self.playbackState = state
                self.render(self.snapshot())
            }
        }
        observeModel()
    }

    deinit {
        stateObservation?.cancel()
        let host = self.host
        Task { @MainActor in host.hide() }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true; observationGeneration = UUID()
        stateObservation?.cancel(); stateObservation = nil
        host.hide(); lastSnapshot = nil
    }

    private func observeModel() {
        guard !stopped else { return }
        let generation = observationGeneration
        let value = withObservationTracking { snapshot() } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.stopped, self.observationGeneration == generation else { return }
                self.observeModel()
            }
        }
        render(value)
    }

    private func snapshot() -> Snapshot {
        guard !stopped, let model, model.settings.showMenuBar else { return .disabled }
        let track = model.currentTrack
        let radio = model.currentIsRadio
        let artist = radio ? model.radioBroadcastTitle ?? track?.artist ?? "" : track?.artist ?? ""
        return Snapshot(enabled: true, title: track?.title ?? "Nothing playing", artist: artist,
                        active: [.playing, .opening, .buffering].contains(playbackState) || model.playbackIntentQueueID != nil,
                        canPlay: !model.queue.isEmpty || model.selectedTrack != nil,
                        hasQueue: !model.queue.isEmpty, reconnect: radio && model.radioDisconnected)
    }

    private func buildMenu() {
        menu.autoenablesItems = false
        let title = NSMenuItem(title: "Nothing playing", action: nil, keyEquivalent: "")
        title.identifier = NSUserInterfaceItemIdentifier("menuBarTrackTitle"); title.isEnabled = false
        menu.addItem(title)
        let artist = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        artist.identifier = NSUserInterfaceItemIdentifier("menuBarTrackArtist"); artist.isEnabled = false
        menu.addItem(artist)
        menu.addItem(.separator())
        addAction("Play", identifier: "menuBarPlayPause", action: #selector(playPause(_:)))
        addAction("Previous", identifier: "menuBarPrevious", action: #selector(previous(_:)))
        addAction("Next", identifier: "menuBarNext", action: #selector(next(_:)))
        menu.addItem(.separator())
        addAction("Show Macarok", identifier: "menuBarShowWindow", action: #selector(showWindow(_:)))
        addAction("Quit Macarok", identifier: "menuBarQuit", action: #selector(quit(_:)))
    }

    private func addAction(_ title: String, identifier: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier(identifier); item.target = self
        menu.addItem(item)
    }

    private func render(_ value: Snapshot) {
        guard lastSnapshot != value else { return }
        lastSnapshot = value
        guard value.enabled else { host.hide(); return }
        item("menuBarTrackTitle")?.title = value.title
        item("menuBarTrackArtist")?.title = value.artist
        item("menuBarTrackArtist")?.isHidden = value.artist.isEmpty
        item("menuBarPlayPause")?.title = value.active ? "Pause" : value.reconnect ? "Reconnect" : "Play"
        item("menuBarPlayPause")?.isEnabled = value.canPlay
        item("menuBarPrevious")?.isEnabled = value.hasQueue
        item("menuBarNext")?.isEnabled = value.hasQueue
        host.show(menu: menu)
    }

    private func item(_ identifier: String) -> NSMenuItem? {
        menu.items.first { $0.identifier?.rawValue == identifier }
    }

    private var enabledModel: AppModel? {
        guard !stopped, let model, model.settings.showMenuBar else { return nil }
        return model
    }

    // Resolve the model at action time: a menu can remain open while the playing entry changes.
    @objc private func playPause(_ sender: NSMenuItem) { enabledModel?.togglePlayback() }
    @objc private func previous(_ sender: NSMenuItem) { enabledModel?.previous() }
    @objc private func next(_ sender: NSMenuItem) { enabledModel?.advance() }
    @objc private func showWindow(_ sender: NSMenuItem) { enabledModel?.showMainWindow() }
    @objc private func quit(_ sender: NSMenuItem) {
        guard enabledModel != nil else { return }
        NSApp.terminate(sender)
    }

    private struct Snapshot: Equatable {
        let enabled: Bool
        let title: String
        let artist: String
        let active: Bool
        let canPlay: Bool
        let hasQueue: Bool
        let reconnect: Bool
        static let disabled = Snapshot(enabled: false, title: "", artist: "", active: false, canPlay: false, hasQueue: false, reconnect: false)
    }
}

@MainActor
private final class NativeMenuBarHost: MenuBarHosting {
    private var statusItem: NSStatusItem?

    func show(menu: NSMenu) {
        let item: NSStatusItem
        if let existing = statusItem { item = existing }
        else {
            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            statusItem = item
            let image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Macarok")
            image?.isTemplate = true
            item.button?.image = image
            item.button?.imagePosition = .imageOnly
            item.button?.toolTip = "Macarok"
            item.button?.setAccessibilityLabel("Macarok")
        }
        item.menu = menu
    }

    func hide() {
        guard let item = statusItem else { return }
        item.menu = nil
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }
}
