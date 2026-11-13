import AppKit

/// A small atomic checkpoint survives a force quit without retaining window titles or content.
struct RecoveryJournal: Codable {
    struct Display: Codable {
        let uuid: String
        let bounds: CGRect
    }
    struct Window: Codable {
        let number: CGWindowID
        let pid: pid_t
        let launchDate: Date
        let displayUUID: String
        let displayBounds: CGRect
        let frame: CGRect
        let fullScreen: Bool
        let minimized: Bool
        let hidden: Bool
    }
    let displays: [Display]
    let windows: [Window]

    static func uuid(_ id: CGDirectDisplayID) -> String? {
        CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
    }

    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.cmkk.vertical-split-demo/recovery.json")
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
