import Foundation

/// Only an armed session with repeated, explicit exit evidence may restore itself.
struct QuickExitPolicy {
    enum Sample { case fullScreen, ended, unknown }
    private var armed = false
    private var endedAt: TimeInterval?
    private var lastSampleAt: TimeInterval?

    mutating func arm() {
        armed = true
        endedAt = nil
        lastSampleAt = nil
    }

    mutating func observe(_ sample: Sample, at now: TimeInterval) -> Bool {
        guard armed else { return false }
        // Sleep, a stalled app, or a display transition invalidates earlier evidence.
        if let previous = lastSampleAt, now - previous > 3 { endedAt = nil }
        lastSampleAt = now
        guard sample == .ended else { endedAt = nil; return false }
        guard let start = endedAt else { endedAt = now; return false }
        guard now - start >= 1 else { return false }
        armed = false
        return true
    }
}
