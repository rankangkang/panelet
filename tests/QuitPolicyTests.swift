@main
struct QuitPolicyTests {
    static func main() {
        assert(QuitPolicy.action(hasSessions: false, busy: false, needsRecovery: false, timedOut: false) == .terminate)
        assert(QuitPolicy.action(hasSessions: true, busy: false, needsRecovery: false, timedOut: false) == .restore)
        assert(QuitPolicy.action(hasSessions: true, busy: true, needsRecovery: false, timedOut: false) == .wait)
        assert(QuitPolicy.action(hasSessions: true, busy: false, needsRecovery: true, timedOut: false) == .offerExit,
               "An unrecoverable window must not cancel the user's quit request")
        assert(QuitPolicy.action(hasSessions: true, busy: true, needsRecovery: false, timedOut: true) == .offerExit,
               "A hung recovery must still allow exit")
        assert(QuitPolicy.action(hasSessions: false, busy: false, needsRecovery: false, timedOut: true) == .terminate,
               "Completion wins over a concurrent timeout")
        assert(RestoreAction(hasPair: false, wasDesktop: true) == .mergeDesktop(endsPair: false))
        assert(RestoreAction(hasPair: true, wasDesktop: true) == .endPair,
               "Restoring a pair on existing desktops keeps those desktops")
        assert(RestoreAction(hasPair: true, wasDesktop: true, mergeDesktop: true) == .mergeDesktop(endsPair: true))
        assert(RestoreAction(hasPair: true, wasDesktop: false) == .endPairAndRestore)
        assert(RestoreAction(hasPair: false, wasDesktop: false) == .endPairAndRestore,
               "An incomplete recovery of a temporary pair still has to restore the display")
        print("QuitPolicy: normal exit, recovery failure, timeout and completion race passed")
        print("RestoreAction: single-display actions distinguish desktop splits and window pairs")
    }
}
