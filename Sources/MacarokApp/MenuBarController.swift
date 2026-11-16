import AppKit
import Combine
import Foundation
import MacarokAudio
import MacarokCore
import Observation
import SwiftUI

@MainActor
protocol MenuBarHosting: AnyObject {
    /// Repeated updates must reuse the same native status item and player presentation.
    func show(player: MenuBarPlayerPresentation)
    func hide()
}

/// Observes queue metadata and transport state. The visible mini player's clock has its own observer.
@MainActor
final class MenuBarController {
    private weak var model: AppModel?
    private let host: MenuBarHosting
    private let presentation: MenuBarPlayerPresentation
    private var stateObservation: AnyCancellable?
    private var playbackState: PlaybackState
    private var observationGeneration = UUID()
    private var stopped = false
    private var lastSnapshot: MenuBarPlayerPresentation.State?

    init(model: AppModel, host: MenuBarHosting? = nil) {
        self.model = model; self.host = host ?? NativeMenuBarHost()
        playbackState = model.player.state
        presentation = MenuBarPlayerPresentation(timeline: model.player.timeline)
        presentation.action = { [weak self] in self?.perform($0) }
        presentation.prepareArtwork = { [weak self] in
            guard !Task.isCancelled, let model = self?.enabledModel, let track = model.currentTrack else { return }
            await model.ensureArtwork(track)
        }
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
        presentation.action = nil; presentation.prepareArtwork = nil
        presentation.state = .disabled
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

    private func snapshot() -> MenuBarPlayerPresentation.State {
        guard !stopped, let model, model.settings.showMenuBar else { return .disabled }
        let track = model.currentTrack
        let radio = model.currentIsRadio
        return .init(enabled: true, track: track,
            artist: radio ? model.radioBroadcastTitle ?? track?.artist ?? "" : track?.artist ?? "",
            phase: playbackState,
            active: [.playing, .opening, .buffering].contains(playbackState) || model.playbackIntentQueueID != nil,
            canPlay: !model.queue.isEmpty || model.selectedTrack != nil,
            hasQueue: !model.queue.isEmpty, isRadio: radio, reconnect: radio && model.radioDisconnected,
            appearance: model.settings.appearance, artworkRevision: model.artworkRevision)
    }

    private func render(_ value: MenuBarPlayerPresentation.State) {
        guard lastSnapshot != value else { return }
        lastSnapshot = value
        presentation.state = value
        guard value.enabled else { host.hide(); return }
        host.show(player: presentation)
    }

    private var enabledModel: AppModel? {
        guard !stopped, let model, model.settings.showMenuBar else { return nil }
        return model
    }

    /// Resolve the model at action time: the popover can stay open through queue transitions.
    private func perform(_ action: MenuBarPlayerPresentation.Action) {
        guard let model = enabledModel else { return }
        switch action {
        case .playPause: model.togglePlayback()
        case .previous: model.previous()
        case .next: model.advance()
        case .showWindow: model.showMainWindow()
        case .quit: NSApp.terminate(nil)
        }
    }
}

@MainActor
private final class NativeMenuBarHost: NSObject, MenuBarHosting, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var presentation: MenuBarPlayerPresentation?
    private let popover = NSPopover()

    override init() {
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    func show(player: MenuBarPlayerPresentation) {
        presentation = player
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            statusItem = item
            let image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Macarok")
            image?.isTemplate = true
            item.button?.image = image
            item.button?.imagePosition = .imageOnly
            item.button?.setAccessibilityLabel("Macarok mini player")
            item.button?.target = self
            item.button?.action = #selector(togglePopover(_:))
            item.button?.setAccessibilityIdentifier("menuBarMiniPlayerButton")
        }
        statusItem?.button?.toolTip = player.state.track.map { "Macarok — \($0.title)" } ?? "Macarok"
        applyAppearance(player.state.appearance)
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown { popover.performClose(sender); return }
        guard let presentation, presentation.state.enabled, let button = statusItem?.button else { return }
        // Construct only while visible: closing releases artwork tasks and the high-frequency clock observer.
        let controller = NSHostingController(rootView: MenuBarMiniPlayerView(player: presentation) { [weak self] in self?.popover.performClose(nil) })
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        popover.contentSize = controller.view.fittingSize
        applyAppearance(presentation.state.appearance)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func applyAppearance(_ appearance: Appearance) {
        popover.appearance = appearance == .system ? nil : NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
    }

    func popoverDidClose(_ notification: Notification) { popover.contentViewController = nil }

    func hide() {
        popover.performClose(nil); popover.contentViewController = nil; presentation = nil
        guard let item = statusItem else { return }
        item.button?.target = nil; item.button?.action = nil
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }
}
