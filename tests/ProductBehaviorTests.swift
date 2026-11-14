import AppKit

@main
struct ProductBehaviorTests {
    @MainActor static func main() {
        let domain = "dev.cmkk.panelet.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = ProductPreferences(defaults: defaults)
        assert(!preferences.automaticStart && !preferences.showPanelOnLaunch)
        preferences.prepareGuide(permissionsReady: false, hasExistingPreferences: false)
        assert(preferences.guideStep == .welcome)
        preferences.guideStep = .permissions
        preferences.guideDeferred = true
        preferences.guideRestartPending = true
        let relaunched = ProductPreferences(defaults: defaults)
        relaunched.prepareGuide(permissionsReady: true, hasExistingPreferences: true)
        assert(relaunched.guideStep == .ready && !relaunched.guideDeferred && !relaunched.guideRestartPending)
        relaunched.guideRestartPending = true
        relaunched.prepareGuide(permissionsReady: false, hasExistingPreferences: true)
        assert(relaunched.guideStep == .permissions, "A restart must not assume permission was granted")
        assert(!relaunched.finishGuide(permissionsReady: false), "Missing permissions must keep setup open")
        assert(relaunched.guideStep == .permissions)
        assert(relaunched.finishGuide(permissionsReady: true), "Setup can finish as soon as permissions are ready")
        relaunched.prepareGuide(permissionsReady: true, hasExistingPreferences: true)
        assert(relaunched.guideStep == .complete)
        relaunched.prepareGuide(permissionsReady: false, hasExistingPreferences: true)
        assert(relaunched.guideStep == .permissions, "Revoked permissions must return to setup")
        defaults.removeObject(forKey: "guide.step")
        relaunched.prepareGuide(permissionsReady: true, hasExistingPreferences: true)
        assert(relaunched.guideStep == .complete, "Authorized existing users should not repeat onboarding")
        defaults.removeObject(forKey: "guide.step")
        relaunched.prepareGuide(permissionsReady: false, hasExistingPreferences: true)
        assert(relaunched.guideStep == .permissions)
        defaults.set("layout", forKey: "guide.step")
        relaunched.prepareGuide(permissionsReady: true, hasExistingPreferences: true)
        assert(relaunched.guideStep == .ready, "An unfinished guide upgrades to the optional trial")
        defaults.set("layout", forKey: "guide.step")
        relaunched.prepareGuide(permissionsReady: false, hasExistingPreferences: true)
        assert(relaunched.guideStep == .permissions, "Migrating old progress must recheck permissions")
        var configuration = DisplayConfiguration()
        configuration.direction = .vertical
        configuration.ratio = .firstLarger
        configuration.rendering = .smooth
        configuration.name = "private-monitor-name"
        preferences.save(configuration, for: "test-display")
        assert(ProductPreferences(defaults: defaults).display("test-display") == configuration)
        assert(preferences.display("unseen") == DisplayConfiguration())
        defaults.set(Data("corrupted".utf8), forKey: "display.corrupt")
        assert(preferences.display("corrupt") == DisplayConfiguration())
        let app = SavedWorkspace.App(bundleID: "test.editor", name: "Editor", titleHint: "Document A")
        let second = SavedWorkspace.App(bundleID: "test.editor", name: "Editor", titleHint: "Document B")
        let saved = SavedWorkspace(name: "Work", apps: [app, second])
        preferences.workspaces = [saved]
        assert(ProductPreferences(defaults: defaults).workspaces == [saved])
        let candidates = [WorkspaceMatcher.Candidate(bundleID: "test.editor", title: "Document A"),
                          WorkspaceMatcher.Candidate(bundleID: "test.editor", title: "Document B")]
        assert(WorkspaceMatcher.match(saved, candidates: candidates) == [0, 1])
        assert(WorkspaceMatcher.match(saved, candidates: Array(candidates.reversed())) == [1, 0])
        assert(WorkspaceMatcher.match(saved, candidates: [candidates[0]]) == [0, nil], "Never reuse a window for both slots")
        let ambiguous = [WorkspaceMatcher.Candidate(bundleID: "test.editor", title: "X"),
                         WorkspaceMatcher.Candidate(bundleID: "test.editor", title: "Y")]
        assert(WorkspaceMatcher.match(saved, candidates: ambiguous) == [nil, nil], "Ambiguous windows must require a user choice")
        assert(WorkspaceMatcher.match(saved, candidates: []) == [nil, nil])
        assert(WorkspaceMatcher.match(saved, candidates: [.init(bundleID: "other.app", title: "Document A")]) == [nil, nil])
        defaults.set(Data("bad data".utf8), forKey: "workspaces.v1")
        assert(preferences.workspaces.isEmpty)
        preferences.workspaces = [SavedWorkspace(name: "invalid", apps: [])]
        assert(preferences.workspaces.isEmpty)

        for size in [CGSize(width: 2560, height: 1440), CGSize(width: 1297, height: 2305), CGSize(width: 1000, height: 1000)] {
            for direction in DisplayConfiguration.Direction.allCases {
                for ratio in DisplayConfiguration.Ratio.allCases {
                    var config = DisplayConfiguration()
                    config.direction = direction
                    config.ratio = ratio
                    let layout = SplitLayout(size: size, configuration: config)
                    let parts = layout.regions
                    assert(parts[0].intersection(parts[1]).isEmpty)
                    assert(parts[0].union(parts[1]) == CGRect(origin: .zero, size: size))
                    assert(parts.allSatisfy { $0.minX.rounded() == $0.minX && $0.minY.rounded() == $0.minY && $0.width > 0 && $0.height > 0 })
                    if direction == .vertical { assert(layout.isPortrait) }
                    if direction == .horizontal { assert(!layout.isPortrait) }
                    let length = layout.isPortrait ? size.height : size.width
                    let first = layout.isPortrait ? parts[0].height : parts[0].width
                    assert(abs(first / length - ratio.fraction) <= 1 / length)
                }
            }
        }
        assert(SplitLayout(size: CGSize(width: 800, height: 600)).smallRegionWarning != nil)
        assert(DisplayConfiguration.Rendering.automatic.frameRate(native: 120, lowPower: true) == 30)
        assert(DisplayConfiguration.Rendering.automatic.frameRate(native: 120, lowPower: false) == 60)
        assert(DisplayConfiguration.Rendering.smooth.scale(native: 2) == 1)
        assert(DisplayConfiguration.Rendering.clarity.scale(native: 2) == 2)
        assert(DisplayConfiguration.Rendering.smooth.frameRate(native: 240) == 120)
        assert(DisplayConfiguration.Rendering.clarity.frameRate(native: 0) == 60)

        let target = CGRect(x: 2560, y: 30, width: 1280, height: 1410)
        let others = [CGRect(x: 0, y: 0, width: 2560, height: 1440), CGRect(x: 3840, y: 0, width: 1280, height: 1440)]
        let wide = CGRect(x: 2560, y: 198, width: 2560, height: 408)
        assert(!PlacementGeometry.belongs(wide, to: target, otherDisplays: others), "A window spanning two regions equally is ambiguous")
        let centered = CGRect(origin: PlacementGeometry.centeredOrigin(for: wide, in: target), size: wide.size)
        assert(PlacementGeometry.belongs(centered, to: target, otherDisplays: others))
        assert(!PlacementGeometry.belongs(CGRect(x: 0, y: 0, width: 2560, height: 1440), to: target, otherDisplays: others))
        assert(!PlacementGeometry.belongs(CGRect(x: 0, y: 0, width: 10000, height: 10000), to: target, otherDisplays: others))
        let screen = PhysicalScreen(id: 123, name: "SECRET-monitor-serial", bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                                    scale: 2, refreshRate: 60, isBuiltin: false, configuration: configuration)
        let report = DiagnosticReport.make(environment: .init(missing: [], optionalMissing: []), displays: [screen],
            recording: true, accessibility: true, separateSpaces: true, performance: "no operations", capture: [])
        assert(!report.contains("SECRET-monitor-serial") && !report.contains("private-monitor-name"))
        assert(!report.contains(NSHomeDirectory()))
        assert(report.contains("2560×1440"))
        let ledger = PerformanceLedger()
        for _ in 0..<105 { ledger.record("test", started: ProcessInfo.processInfo.systemUptime - 0.5, succeeded: true) }
        assert(ledger.entries.count == 100 && ledger.entries.allSatisfy { $0.seconds >= 0.5 })
        let cancelled = PerformanceLedger()
        cancelled.record("start", started: ProcessInfo.processInfo.systemUptime, succeeded: false, cancelled: true)
        assert(cancelled.failedCount == 0 && cancelled.cancelledCount == 1)
        print("ProductBehavior: persisted preferences, safe workspace matching, 27 layouts, rendering limits, diagnostic privacy and bounded metrics passed")
    }
}
