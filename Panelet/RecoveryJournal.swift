import AppKit

/// A small atomic checkpoint survives a force quit without retaining window titles or content.
struct RecoveryJournal: Codable, Equatable {
    struct Display: Codable, Equatable {
        let uuid: String
        let bounds: CGRect
    }
    struct Window: Codable, Equatable {
        let number: CGWindowID
        let pid: pid_t
        let launchDate: Date
        let displayUUID: String
        let displayBounds: CGRect
        let frame: CGRect
        let fullScreen: Bool
        let minimized: Bool
        let hidden: Bool

        func frame(on bounds: CGRect) -> CGRect {
            frame.offsetBy(dx: bounds.minX - displayBounds.minX, dy: bounds.minY - displayBounds.minY)
        }
    }
    let displays: [Display]
    let windows: [Window]

    enum WindowDisposition {
        case restored, closed, waitingForDisplay, retry
    }

    struct WindowResult {
        var restored = 0
        var waitingForDisplay = 0
        var failed = 0
        var pending: [Window] = []
    }

    func recoverWindows(using recover: (Window) async -> WindowDisposition) async -> WindowResult {
        var result = WindowResult()
        for window in windows {
            switch await recover(window) {
            case .restored: result.restored += 1
            case .closed: break
            case .waitingForDisplay:
                result.waitingForDisplay += 1
                result.pending.append(window)
            case .retry:
                result.failed += 1
                result.pending.append(window)
            }
        }
        return result
    }

    func originalLayout(on current: [CGDirectDisplayID: Display], main: CGDirectDisplayID) -> [CGDirectDisplayID: CGRect]? {
        guard !displays.isEmpty, displays.count == current.count,
              let mainUUID = current[main]?.uuid,
              displays.contains(where: { $0.uuid == mainUUID && $0.bounds.origin == .zero }) else { return nil }
        var layout: [CGDirectDisplayID: CGRect] = [:]
        for display in displays {
            guard let (id, screen) = current.first(where: { $0.value.uuid == display.uuid }),
                  layout[id] == nil, !display.bounds.isEmpty, screen.bounds.size == display.bounds.size else { return nil }
            layout[id] = display.bounds
        }
        return layout
    }

    static func uuid(_ id: CGDirectDisplayID) -> String? {
        CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
    }

    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.cmkk.panelet/recovery.json")
    }

    static func load() throws -> RecoveryJournal? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
    }

    static func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
