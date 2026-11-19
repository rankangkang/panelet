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
        assert(DisplayConfiguration.Rendering.highRefresh.scale(native: 2) == 2)
        assert(DisplayConfiguration.Rendering.highRefresh.scale(native: 1) == 1)
        assert(DisplayConfiguration.Rendering.highRefresh.frameRate(native: 120, lowPower: true) == 120)
        assert(DisplayConfiguration.Rendering.highRefresh.frameRate(native: 240, lowPower: false) == 120)
        assert(DisplayConfiguration.Rendering.highRefresh.frameRate(native: 60, lowPower: false) == 60)

        var logBuffer = BoundedLogBuffer(capacity: 3)
        let m1 = logBuffer.append("第一行")
        assert(m1.prefixUTF16CountToRemove == 0 && m1.appendedText == "第一行" && logBuffer.text == "第一行")
        let m2 = logBuffer.append("Line 2")
        assert(m2.prefixUTF16CountToRemove == 0 && m2.appendedText == "\nLine 2" && logBuffer.text == "第一行\nLine 2")
        let m3 = logBuffer.append("Line 3")
        assert(m3.prefixUTF16CountToRemove == 0 && logBuffer.lines.count == 3)
        let m4 = logBuffer.append("Line 4")
        assert(m4.prefixUTF16CountToRemove == ("第一行".utf16.count + 1) && m4.appendedText == "\nLine 4")
        assert(logBuffer.text == "Line 2\nLine 3\nLine 4")

        // Multi-line messages must enforce a strict 500 physical-line cap and keep incremental UTF-16 edits exact.
        var multiLineBuffer = BoundedLogBuffer(capacity: 500)
        let simulatedStorage = NSMutableString()
        var rawTranscript = ""
        for idx in 0..<500 {
            let entry = "环境检查 #\(idx)\n必要接口检查通过\n权限状态请查看设置"
            rawTranscript = rawTranscript.isEmpty ? entry : (rawTranscript + "\n" + entry)
            let mutation = multiLineBuffer.append(entry)
            if mutation.prefixUTF16CountToRemove > 0 {
                simulatedStorage.deleteCharacters(in: NSRange(location: 0, length: mutation.prefixUTF16CountToRemove))
            }
            simulatedStorage.append(mutation.appendedText)
        }
        let expected500 = rawTranscript.split(separator: "\n", omittingEmptySubsequences: false).suffix(500).joined(separator: "\n")
        assert(multiLineBuffer.lines.count == 500, "Must cap at 500 physical lines, not 500 messages")
        assert(multiLineBuffer.text == expected500)
        assert((simulatedStorage as String) == expected500)

        // Constrained ordinary window restore: unmoved windows must fail, positioned windows with grid/min-size deltas pass.
        let fullDisplay = CGRect(x: 0, y: 0, width: 2048, height: 1152)
        let visibleDisplay = CGRect(x: 0, y: 25, width: 2048, height: 1059)
        let desiredRight = CGRect(x: 1024, y: 30, width: 1024, height: 1054)
        let stuckOnLeft = CGRect(x: 0, y: 30, width: 1024, height: 1054)
        assert(!PlacementGeometry.settledConstrainedRestore(
            desired: desiredRight, actual: stuckOnLeft, previousAttempt: stuckOnLeft,
            displayBounds: fullDisplay, visibleBounds: visibleDisplay
        ), "A window that refused to move to desired.origin must never be marked restored")

        let gridSnapped = CGRect(x: 1024, y: 30, width: 1018, height: 1044)
        assert(!PlacementGeometry.settledConstrainedRestore(
            desired: desiredRight, actual: gridSnapped, previousAttempt: nil,
            displayBounds: fullDisplay, visibleBounds: visibleDisplay
        ), "First constrained observation must retry once to confirm stability")
        assert(PlacementGeometry.settledConstrainedRestore(
            desired: desiredRight, actual: gridSnapped, previousAttempt: gridSnapped,
            displayBounds: fullDisplay, visibleBounds: visibleDisplay
        ), "Positioned window with stable character-grid size delta should be accepted")

        let edgeDesired = CGRect(x: 1548, y: 100, width: 500, height: 600)
        let minWidthPushed = CGRect(x: 1368, y: 100, width: 680, height: 600)
        assert(PlacementGeometry.settledConstrainedRestore(
            desired: edgeDesired, actual: minWidthPushed, previousAttempt: minWidthPushed,
            displayBounds: fullDisplay, visibleBounds: visibleDisplay
        ), "Window pushed left by display right edge due to min-width constraint should be accepted")

        let overhanging = edgeDesired.offsetBy(dx: 180, dy: 0)
        var tallerAtEdge = edgeDesired
        tallerAtEdge.size.height += 20
        for clamped in [edgeDesired, tallerAtEdge, minWidthPushed] {
            assert(!PlacementGeometry.settledConstrainedRestore(
                desired: overhanging, actual: clamped, previousAttempt: clamped,
                displayBounds: fullDisplay, visibleBounds: visibleDisplay
            ), "An already overhanging window that stays clamped must remain pending")
        }

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
        cancelled.record("start", started: ProcessInfo.processInfo.systemUptime, succeeded: false, cancelled: true,
                         stages: [.windowScan: 0.1, .firstFrame: 0.2])
        assert(cancelled.failedCount == 0 && cancelled.cancelledCount == 1)
        assert(cancelled.summary.contains("\(PerformanceLedger.Stage.windowScan.title) 0.10 s"))
        assert(cancelled.summary.contains("\(PerformanceLedger.Stage.firstFrame.title) 0.20 s"))
        assert(!cancelled.summary.contains(PerformanceLedger.Stage.fullScreen.title))
        print("ProductBehavior: persisted preferences, safe workspace matching, 27 layouts, rendering limits, diagnostic privacy and bounded metrics passed")
    }
}
