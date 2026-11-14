import Foundation

struct DisplayConfiguration: Codable, Equatable {
    enum Direction: String, Codable, CaseIterable {
        case automatic, vertical, horizontal
        var title: String { switch self { case .automatic: return L("自动"); case .vertical: return L("上下"); case .horizontal: return L("左右") } }
    }
    enum Ratio: String, Codable, CaseIterable {
        case equal, firstLarger, secondLarger
        var title: String { switch self { case .equal: return "1:1"; case .firstLarger: return "2:1"; case .secondLarger: return "1:2" } }
        var fraction: Double { switch self { case .equal: return 0.5; case .firstLarger: return 2.0 / 3; case .secondLarger: return 1.0 / 3 } }
    }
    enum Rendering: String, Codable, CaseIterable {
        case automatic, clarity, smooth
        var title: String { switch self { case .automatic: return L("自动"); case .clarity: return L("清晰优先"); case .smooth: return L("流畅优先") } }
        func scale(native: CGFloat) -> Int { self == .smooth ? 1 : (native >= 1.5 ? 2 : 1) }
        func frameRate(native: Double, lowPower: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled) -> Double {
            let limit: Double = self == .smooth ? 120 : (self == .automatic && lowPower ? 30 : 60)
            return min(native > 1 ? native : 60, limit)
        }
    }
    var name = ""
    var direction: Direction = .automatic
    var ratio: Ratio = .equal
    var rendering: Rendering = .automatic
}

struct SavedWorkspace: Codable, Identifiable, Equatable {
    struct App: Codable, Equatable {
        let bundleID: String
        let name: String
        let titleHint: String
    }
    var id = UUID()
    var name: String
    let apps: [App]
}

/// Match fresh window candidates, never persist or replay process/window IDs.
enum WorkspaceMatcher {
    struct Candidate {
        let bundleID: String
        let title: String
    }
    static func match(_ workspace: SavedWorkspace, candidates: [Candidate]) -> [Int?] {
        var used = Set<Int>()
        return workspace.apps.prefix(2).map { app in
            let matching = candidates.indices.filter { !used.contains($0) && candidates[$0].bundleID == app.bundleID }
            let exact = matching.filter { !app.titleHint.isEmpty && candidates[$0].title == app.titleHint }
            let index = exact.count == 1 ? exact.first : (matching.count == 1 ? matching.first : nil)
            if let index { used.insert(index) }
            return index
        }
    }
}

struct ProductPreferences {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    enum GuideStep: String { case welcome, permissions, layout, complete }
    var guideStep: GuideStep {
        get { GuideStep(rawValue: defaults.string(forKey: "guide.step") ?? "") ?? .welcome }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "guide.step") }
    }
    var guideDeferred: Bool {
        get { defaults.bool(forKey: "guide.deferred") }
        nonmutating set { defaults.set(newValue, forKey: "guide.deferred") }
    }
    var guideRestartPending: Bool {
        get { defaults.bool(forKey: "guide.restart") }
        nonmutating set { defaults.set(newValue, forKey: "guide.restart") }
    }
    /// Migrate established installations without making them repeat setup.
    func prepareGuide(permissionsReady: Bool, hasExistingPreferences: Bool) {
        if defaults.string(forKey: "guide.step") == nil {
            guideStep = permissionsReady ? .complete : (hasExistingPreferences ? .permissions : .welcome)
        }
        if guideRestartPending {
            guideStep = permissionsReady ? .layout : .permissions
            guideDeferred = false
            guideRestartPending = false
        } else if !permissionsReady && (guideStep == .complete || guideStep == .layout) {
            guideStep = .permissions
        }
    }

    func display(_ uuid: String) -> DisplayConfiguration {
        guard let data = defaults.data(forKey: "display.\(uuid)"),
              let value = try? JSONDecoder().decode(DisplayConfiguration.self, from: data) else { return DisplayConfiguration() }
        return value
    }
    func save(_ configuration: DisplayConfiguration, for uuid: String) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: "display.\(uuid)")
    }
    var workspaces: [SavedWorkspace] {
        get {
            guard let data = defaults.data(forKey: "workspaces.v1"),
                  let values = try? JSONDecoder().decode([SavedWorkspace].self, from: data) else { return [] }
            return Array(values.filter { $0.apps.count == 2 && $0.apps.allSatisfy { !$0.bundleID.isEmpty } }.prefix(30))
        }
        nonmutating set {
            guard let data = try? JSONEncoder().encode(Array(newValue.prefix(30))) else { return }
            defaults.set(data, forKey: "workspaces.v1")
        }
    }
    var showPanelOnLaunch: Bool {
        get { defaults.bool(forKey: "showPanelOnLaunch") }
        nonmutating set { defaults.set(newValue, forKey: "showPanelOnLaunch") }
    }
    var automaticStart: Bool {
        get { defaults.bool(forKey: "automaticStart") }
        nonmutating set { defaults.set(newValue, forKey: "automaticStart") }
    }
}
