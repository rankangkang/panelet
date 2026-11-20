/// Bounded exponential backoff schedule for automatic window/display recovery retries.
struct RecoveryBackoff: Equatable, Sendable {
    let delaysMilliseconds: [Int]
    private(set) var attempt = 0

    init(delaysMilliseconds: [Int] = [800, 1600, 3200, 6400]) {
        self.delaysMilliseconds = delaysMilliseconds
    }

    var maxAttempts: Int { delaysMilliseconds.count }
    var canRetry: Bool { attempt < delaysMilliseconds.count }

    mutating func nextDelayMilliseconds() -> Int? {
        guard attempt < delaysMilliseconds.count else { return nil }
        let delay = delaysMilliseconds[attempt]
        attempt += 1
        return delay
    }

    mutating func reset() {
        attempt = 0
    }
}

/// Recovery is best effort: it must never permanently trap the user in the app.
enum QuitPolicy {
    enum Action: Equatable { case wait, restore, offerExit, terminate }

    static func action(hasSessions: Bool, busy: Bool, needsRecovery: Bool, autoRetrying: Bool = false, timedOut: Bool) -> Action {
        if !hasSessions { return .terminate }
        if timedOut { return .offerExit }
        if busy || (needsRecovery && autoRetrying) { return .wait }
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
