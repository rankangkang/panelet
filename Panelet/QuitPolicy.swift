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

/// Match the effect described in the UI before acting on an individual display.
enum RestoreAction: Equatable {
    case mergeDesktop(endsPair: Bool), endPair, endPairAndRestore

    init(hasPair: Bool, wasDesktop: Bool, mergeDesktop: Bool = false) {
        if !wasDesktop { self = .endPairAndRestore }
        else if mergeDesktop || !hasPair { self = .mergeDesktop(endsPair: hasPair) }
        else { self = .endPair }
    }
}
