import Foundation

@main
struct QuickExitPolicyTests {
    static func main() {
        var policy = QuickExitPolicy()
        assert(!policy.observe(.ended, at: 0), "Preparation must never auto-restore")
        assert(!policy.observe(.ended, at: 3))
        policy.arm()
        assert(!policy.observe(.ended, at: 4))
        assert(!policy.observe(.ended, at: 4.5), "Ignore a short animation")
        assert(policy.observe(.ended, at: 5), "A confirmed exit ends the session")
        assert(!policy.observe(.ended, at: 6), "Restoration fires only once")

        policy.arm()
        assert(!policy.observe(.ended, at: 10))
        assert(!policy.observe(.unknown, at: 11), "An AX timeout is not an exit")
        assert(!policy.observe(.ended, at: 12))
        assert(!policy.observe(.fullScreen, at: 13), "Returning to full screen resets exit evidence")
        assert(!policy.observe(.ended, at: 14))
        assert(policy.observe(.ended, at: 15))

        policy.arm()
        assert(!policy.observe(.ended, at: 20))
        assert(!policy.observe(.ended, at: 100), "Sleep or a long polling gap invalidates stale evidence")
        assert(policy.observe(.ended, at: 101))

        policy.arm()
        for time in 200...210 { assert(!policy.observe(.fullScreen, at: Double(time))) }
        policy = QuickExitPolicy()
        assert(!policy.observe(.ended, at: 211), "Cancellation disarms the monitor")
        print("QuickExitPolicy: all assertions passed")
    }
}
