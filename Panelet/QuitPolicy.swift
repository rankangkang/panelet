/// Recovery is best effort: it must never permanently trap the user in the app.
enum QuitPolicy {
    enum Action: Equatable { case wait, restore, offerExit, terminate }

    static func action(hasSessions: Bool, busy: Bool, needsRecovery: Bool, timedOut: Bool) -> Action {
        if !hasSessions { return .terminate }
        if timedOut { return .offerExit }
        if busy { return .wait }
        return needsRecovery ? .offerExit : .restore
    }
}
