/// Presentation intent is independent of decoder state, which also changes during preparation,
/// resumption, and automatic handoff.
enum PlaybackStartOrigin: Equatable {
    case manual, automatic, resumption
}

/// Session-only eligibility; the selected mode is persisted separately in AppPreferences.
struct PlayingAutoSwitchPolicy {
    private var startedThisLaunch = false
    private var startedThisSession = false
    private var navigatedThisLaunch = false
    private var navigatedThisSession = false

    mutating func recordUserNavigation() {
        navigatedThisLaunch = true
        navigatedThisSession = true
    }

    mutating func endPlaybackSession() {
        startedThisSession = false
        navigatedThisSession = false
    }

    mutating func acceptStart(mode: PlayingAutoSwitchMode, origin: PlaybackStartOrigin,
                              editing: Bool) -> Bool {
        guard origin == .manual else { return false }
        let eligible: Bool
        switch mode {
        case .manualTrackStart: eligible = true
        case .oncePerLaunch: eligible = !startedThisLaunch && !navigatedThisLaunch
        case .playbackSessionStart: eligible = !startedThisSession && !navigatedThisSession
        }
        // Consume before preparation starts, even if navigation or an editor protects the view.
        // Changing modes or receiving a late decoder callback must not revive an old opportunity.
        startedThisLaunch = true
        startedThisSession = true
        return eligible && !editing
    }
}
