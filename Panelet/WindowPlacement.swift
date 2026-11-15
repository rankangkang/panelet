import AppKit
import ApplicationServices
import Carbon

/// The windows and presentation states to restore when the display is joined.
@MainActor
final class WindowPlacement {
    struct Choice: Identifiable, @unchecked Sendable {
        enum ID: Hashable {
            case window(CGWindowID)
            case accessibility(AXUIElement)
        }

        let id: ID
        let element: AXUIElement?
        let pid: pid_t
        let appName: String
        let title: String
        let frame: CGRect?
        let status: String?

        var name: String { title.isEmpty ? appName : title }

        var windowID: CGWindowID? {
            if case let .window(number) = id { return number }
            return nil
        }
    }

    struct Pair {
        let upper: Choice
        let lower: Choice
    }

    struct Identity: @unchecked Sendable {
        let number: CGWindowID?
        let element: AXUIElement?
        var pid: pid_t? {
            guard let element else { return nil }
            var pid: pid_t = 0
            return AXUIElementGetPid(element, &pid) == .success ? pid : nil
        }

        func matches(number: CGWindowID?, element: AXUIElement?) -> Bool {
            (number != nil && self.number == number) || (element != nil && self.element == element)
        }
    }

    private let source: PhysicalScreen
    private let displays: [PhysicalScreen]
    private let pair: Pair?
    private let reserved: [Identity]
    private let selectedOnly: Bool
    private var windows: [SavedWindow]
    var onCheckpoint: (() throws -> Void)?
    private var unhiddenApps: [pid_t: NSRunningApplication] = [:]

    nonisolated static func choices() -> [Choice] {
        let visible = windowList([.optionOnScreenOnly, .excludeDesktopElements])
        let all = Dictionary(grouping: windowList([.excludeDesktopElements]), by: \.pid)
        var appOrder: [pid_t: Int] = [:]
        for entry in visible where appOrder[entry.pid] == nil { appOrder[entry.pid] = appOrder.count }
        let apps = NSWorkspace.shared.runningApplications
            .filter { app in
                let pid = app.processIdentifier
                return pid != getpid() && app.activationPolicy == .regular
            }
            .sorted { lhs, rhs in
                let a = appOrder[lhs.processIdentifier, default: Int.max]
                let b = appOrder[rhs.processIdentifier, default: Int.max]
                if a != b { return a < b }
                return (lhs.localizedName ?? "").localizedStandardCompare(rhs.localizedName ?? "") == .orderedAscending
            }
        return apps.flatMap { app in
            if Task.isCancelled { return [] as [Choice] }
            let pid = app.processIdentifier
            let name = app.localizedName ?? L("窗口")
            let hidden = app.isHidden
            let records = all[pid] ?? []
            var seen = Set<Choice.ID>()
            let accessible = Window.accessibleWindows(for: pid).compactMap { window -> Choice? in
                guard window.isStandard, let details = window.pickerDetails else { return nil }
                let matching = records.filter { record in
                    details.frame.map { near($0, record.frame) } == true
                        && (details.title.isEmpty || record.title.isEmpty || record.title == details.title)
                }
                let number = window.number ?? (matching.count == 1 ? matching.first?.id : nil)
                guard number != nil || details.frame != nil || !details.title.isEmpty else { return nil }
                let record = records.first { $0.id == number }
                let id = number.map(Choice.ID.window) ?? .accessibility(window.element)
                guard seen.insert(id).inserted else { return nil }
                let status = details.minimized ? L("已最小化") : (details.fullScreen ? L("全屏中") : (hidden ? L("已隐藏") : nil))
                return Choice(id: id, element: window.element, pid: pid, appName: name,
                              title: details.title.isEmpty ? record?.title ?? "" : details.title,
                              frame: details.frame ?? record?.frame, status: status)
            }
            // The per-app AX list can omit windows on an inactive desktop or Stage Manager group.
            return accessible + records.compactMap { record in
                let id = Choice.ID.window(record.id)
                guard !record.title.isEmpty, record.frame.height >= 50,
                      DesktopSpaces.spaces(for: record.id)?.isEmpty != true,
                      seen.insert(id).inserted else { return nil }
                return Choice(id: id, element: nil, pid: pid, appName: name, title: record.title,
                              frame: record.frame, status: hidden ? L("已隐藏") : nil)
            }
        }
    }

    static func focusedWindowFrame(of app: NSRunningApplication) -> CGRect? {
        windowFrame(for: app.processIdentifier, attribute: kAXFocusedWindowAttribute)
    }

    private nonisolated static func windowFrame(for pid: pid_t, attribute: String) -> CGRect? {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.1)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return Window(element: window as! AXUIElement).frame
    }

    nonisolated static func isInteractivePopup(pid: pid_t, frame: CGRect) -> Bool {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.05)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(application, Float(frame.midX), Float(frame.midY), &hit) == .success,
              let hit else { return false }
        let role = Window.attribute(kAXRoleAttribute, of: hit) as? String
        let element: AXUIElement
        if role == kAXWindowRole {
            element = hit
        } else {
            guard let value = Window.attribute(kAXWindowAttribute, of: hit),
                  CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
            element = value as! AXUIElement
        }
        guard let actual = Window(element: element).frame, near(actual, frame) else { return false }
        if let close = Window.attribute(kAXCloseButtonAttribute, of: element),
           CFGetTypeID(close) == AXUIElementGetTypeID(),
           Window.attribute(kAXEnabledAttribute, of: close as! AXUIElement) as? Bool == true { return true }

        // Some popovers have actionable content but no title-bar controls.
        var actions: CFArray?
        return Window.attribute(kAXEnabledAttribute, of: hit) as? Bool != false
            && AXUIElementCopyActionNames(hit, &actions) == .success
            && (actions as? [String])?.contains(kAXPressAction) == true
    }

    init(source: PhysicalScreen, displays: [PhysicalScreen], pair: Pair? = nil, reserved: [Identity] = [], selectedOnly: Bool = false) throws {
        self.source = source
        self.displays = displays
        self.pair = pair
        self.reserved = reserved
        self.selectedOnly = selectedOnly
        let selected = pair.map { [$0.upper, $0.lower] } ?? []
        if let pair, pair.upper.id == pair.lower.id {
            throw DemoError(L("请选择两个不同的窗口。"))
        }
        if selected.contains(where: { choice in reserved.contains { $0.matches(number: choice.windowID, element: choice.element) } }) {
            throw DemoError(L("有窗口正在另一块屏幕分屏，请换一个窗口。"))
        }
        let visible = (selectedOnly ? [] : Self.windowList([.optionOnScreenOnly, .excludeDesktopElements])).filter { entry in
            let overlap = Self.overlap(of: entry.frame, with: source.bounds)
            return overlap > 0 && displays.allSatisfy { Self.overlap(of: entry.frame, with: $0.bounds) <= overlap }
        }
        windows = Self.movableWindows(from: visible).compactMap { match in
            guard !selected.contains(where: { $0.windowID == match.info.id || $0.element == match.window.element }),
                  !reserved.contains(where: { $0.matches(number: match.info.id, element: match.window.element) }) else { return nil }
            return SavedWindow(window: match.window, id: match.info.id, pid: match.info.pid,
                               original: match.frame, display: source, slot: nil)
        }
    }

    var count: Int { windows.count }
    var identities: [Identity] {
        windows.filter { $0.slot != nil }.map { Identity(number: $0.id, element: $0.window.element) }
    }


    func release(_ identities: [Identity]) {
        windows.removeAll { saved in
            saved.slot == nil && identities.contains { $0.matches(number: saved.id, element: saved.window.element) }
        }
    }

    func prepareSelection() async throws {
        guard let pair else { try await prepareOtherFullScreenWindows(); return }
        let originalWindows = Self.liveWindows()
        for (slot, choice) in [pair.upper, pair.lower].enumerated() {
            try Task.checkCancellation()
            let stageFrame = choice.windowID.flatMap { originalWindows[$0]?.frame }
            guard let app = NSRunningApplication(processIdentifier: choice.pid), !app.isTerminated else {
                throw DemoError(L("「%@」已经退出，请重新选择窗口。", String(describing: choice.appName)))
            }
            if app.isHidden {
                unhiddenApps[choice.pid] = app
                app.unhide()
            }
            let window = try await Self.openWindow(choice, in: app)
            let number = choice.windowID ?? window.number
            if reserved.contains(where: { $0.matches(number: number, element: window.element) }) {
                throw DemoError(L("「%@」正在另一块屏幕分屏，请换一个窗口。", String(describing: choice.name)))
            }
            if windows.contains(where: { $0.slot != nil && ($0.window.element == window.element || (number != nil && $0.id == number)) }) {
                throw DemoError(L("请选择两个不同的窗口。"))
            }
            let state = window.pickerDetails
            let fullScreen = state?.fullScreen == true
            let minimized = state?.minimized == true
            guard fullScreen || minimized || window.supportsFullScreen else {
                throw DemoError(L("「%@」无法进入原生全屏，请换一个窗口。", String(describing: choice.name)))
            }
            let display = originalDisplay(for: state?.frame ?? choice.frame)
            let staged = !minimized && !fullScreen && unhiddenApps[choice.pid] == nil
                && Self.isInStageStrip(stageFrame ?? choice.frame, original: state?.frame, on: display.bounds)
            windows.append(SavedWindow(window: window, id: number, pid: choice.pid,
                                       original: fullScreen ? nil : state?.frame, display: display, slot: slot,
                                       wasMinimized: minimized, wasInStageStrip: staged, fullScreenDisplay: fullScreen ? display : nil))
            let index = windows.count - 1
            try onCheckpoint?()

            if minimized || fullScreen {
                // Finish an in-flight AppKit transition before cancellation restores the saved state.
                let ready = await Task {
                    if minimized {
                        window.setMinimized(false)
                        for _ in 0..<16 {
                            if !window.isMinimized, window.frame != nil { return true }
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                        return false
                    }
                    return await Self.exitFullScreen(window)
                }.value
                guard ready else {
                    let action = minimized ? L("从程序坞恢复") : L("退出原来的全屏")
                    throw DemoError(L("「%@」暂时无法%@。", String(describing: choice.name), String(describing: action)))
                }
            }
            guard !window.isMinimized, let frame = window.frame, window.positionIsSettable else {
                throw DemoError(L("「%@」暂时无法移动。请先打开该窗口再试。", String(describing: choice.name)))
            }
            if windows[index].original == nil {
                windows[index].original = frame
                windows[index].display = originalDisplay(for: frame)
            }
            try onCheckpoint?()
            try Task.checkCancellation()
        }
        if !selectedOnly { try await prepareOtherFullScreenWindows() }
    }

    private func prepareOtherFullScreenWindows() async throws {
        let selected = pair.map { [$0.upper, $0.lower] } ?? []
        let bounds = source.bounds
        let fullSpaces = Set(DesktopSpaces()?.spaceIDs(in: source.id, fullScreenOnly: true) ?? [])
        let records = Self.windowList([.excludeDesktopElements]).filter {
            $0.frame.height >= 50 && (bounds.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
                || !fullSpaces.isDisjoint(with: DesktopSpaces.spaces(for: $0.id) ?? []))
        }
        var appWindows: [pid_t: [Window]] = [:]
        for record in records {
            try Task.checkCancellation()
            guard NSRunningApplication(processIdentifier: record.pid)?.activationPolicy == .regular,
                  !selected.contains(where: { $0.windowID == record.id }),
                  !reserved.contains(where: { $0.matches(number: record.id, element: nil) }) else { continue }
            if appWindows[record.pid] == nil {
                appWindows[record.pid] = await Task.detached { Window.accessibleWindows(for: record.pid) }.value
            }
            let cached = appWindows[record.pid] ?? []
            let window = await Task.detached(priority: .userInitiated) {
                cached.first { $0.number == record.id } ?? Window.findUnlistedWindow(record)
            }.value
            if window == nil, !record.title.isEmpty,
               !fullSpaces.isDisjoint(with: DesktopSpaces.spaces(for: record.id) ?? []) {
                throw DemoError(L("无法控制原屏上的全屏窗口「%@」，已停止拆分。请先打开该窗口后重试。", String(describing: record.title)))
            }
            guard let window, window.isFullScreen,
                  !selected.contains(where: { $0.element == window.element }),
                  !reserved.contains(where: { $0.matches(number: record.id, element: window.element) }) else { continue }
            windows.append(SavedWindow(window: window, id: record.id, pid: record.pid,
                                       original: nil, display: source, slot: nil, fullScreenDisplay: source))
            let index = windows.count - 1
            guard await Self.exitFullScreen(window), let frame = window.frame else {
                throw DemoError(L("原显示器上的「%@」暂时无法退出全屏，已取消拆分以保留原桌面。", String(describing: record.title)))
            }
            windows[index].original = frame
            try Task.checkCancellation()
        }
    }

    private func originalDisplay(for frame: CGRect?) -> PhysicalScreen {
        guard let frame else { return source }
        return displays.max { Self.overlap(of: frame, with: $0.bounds) < Self.overlap(of: frame, with: $1.bounds) } ?? source
    }

    private static func openWindow(_ choice: Choice, in app: NSRunningApplication) async throws -> Window {
        if let element = choice.element {
            let window = Window(element: element)
            if window.pickerDetails != nil { return window }
        }
        if let id = choice.windowID {
            guard let record = liveWindows()[id], record.pid == choice.pid else { throw DemoError(L("选中的窗口已关闭，请重新选择。")) }
            if let window = Window.find(record) { return window }
            let lookup = Task.detached(priority: .userInitiated) { Window.findUnlistedWindow(record) }
            let unlisted = await withTaskCancellationHandler {
                await lookup.value
            } onCancel: {
                lookup.cancel()
            }
            try Task.checkCancellation()
            if let unlisted {
                if !unlisted.isMinimized && !unlisted.isFullScreen {
                    Window.reveal(id, in: app)
                    AXUIElementPerformAction(unlisted.element, kAXRaiseAction as CFString)
                }
                return unlisted
            }
            // Activate before looking up an app that has not published its AX windows yet.
            NSApp.yieldActivation(to: app)
            app.activate(options: [.activateAllWindows])
            Window.reveal(id, in: app)
            for attempt in 0..<16 {
                try Task.checkCancellation()
                if let window = Window.find(record) { return window }
                if attempt == 4, !app.isActive { app.activate() }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        throw DemoError(L("macOS 暂时无法控制「%@」。请先切到这个窗口再试。", String(describing: choice.name)))
    }

    func migrate(to halves: [HalfScreen]) async throws -> Int {
        try Task.checkCancellation()
        var moved = await placeOrdinary(on: halves[0], protecting: reserved)
        for saved in windows where pair == nil && saved.slot == nil && saved.fullScreenDisplay != nil {
            try Task.checkCancellation()
            guard let window = Self.resolve(saved, in: Self.liveWindows()),
                  await Self.restoreFullScreen(window, on: halves[0].virtualID) else {
                DemoLog.shared.line(L("迁移全屏失败 pid=%@ title=%@ id=%@ frame=%@ target=%@ full=%@", String(describing: saved.pid), String(describing: saved.id.flatMap { Self.liveWindows()[$0]?.title } ?? L("未知")), String(describing: saved.id ?? 0), String(describing: String(describing: saved.window.frame)), String(describing: halves[0].virtualBounds), String(describing: String(describing: saved.window.fullScreen))))
                throw DemoError(L("原来的全屏窗口未能在第一个分区恢复全屏，已取消本次拆分。"))
            }
            try Task.checkCancellation()
        }
        for savedIndex in windows.indices {
            let saved = windows[savedIndex]
            guard let index = saved.slot, let original = saved.original else { continue }
            let half = halves[index]
            guard let screen = NSScreen.screens.first(where: { $0.displayID == half.virtualID }) else {
                throw DemoError(L("%@ 的显示器不可用。", String(describing: half.name)))
            }
            let usable = cocoaRect(screen.visibleFrame)
            var window = saved.window
            if let id = saved.id, let app = NSRunningApplication(processIdentifier: saved.pid) {
                guard let info = Self.liveWindows()[id], info.pid == saved.pid else {
                    throw DemoError(L("选中的窗口已关闭，请重新选择。"))
                }
                // Reconfiguration can invalidate Chromium's AX handles without closing the window.
                // Activate the exact selected window and refresh its handle before changing geometry.
                NSApp.yieldActivation(to: app)
                app.activate(options: [.activateAllWindows])
                Window.reveal(id, in: app)
                let choice = Choice(id: .window(id), element: nil, pid: saved.pid,
                                    appName: app.localizedName ?? L("窗口"), title: info.title, frame: info.frame, status: nil)
                window = try await Self.openWindow(choice, in: app)
                AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
                windows[savedIndex].window = window
                try await Task.sleep(for: .milliseconds(150))
            }
            let desired = window.canResize ? usable : Self.fit(original, inside: usable)
            if let frame = window.frame, frame.width > usable.width || frame.height > usable.height {
                window.setSize(desired.size)
            }
            for _ in 0..<6 {
                try Task.checkCancellation()
                window.place(desired)
                if let actual = window.frame, Self.near(actual, desired) { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            if let actual = window.frame, !usable.insetBy(dx: -2, dy: -2).contains(actual) {
                // Some apps reject AXSize while still supporting native full screen. Position
                // their center on the target instead of rejecting them before the OS can size them.
                let otherDisplays = NSScreen.screens.filter { $0.displayID != half.virtualID }.map { cocoaRect($0.frame) }
                for _ in 0..<4 {
                    try Task.checkCancellation()
                    if let frame = window.frame, PlacementGeometry.belongs(frame, to: usable, otherDisplays: otherDisplays) { break }
                    if let frame = window.frame { window.setPosition(PlacementGeometry.centeredOrigin(for: frame, in: usable)) }
                    try await Task.sleep(for: .milliseconds(150))
                }
                guard let frame = window.frame, PlacementGeometry.belongs(frame, to: usable, otherDisplays: otherDisplays) else {
                    throw DemoError(L("%@ 的窗口无法放入，请换一个窗口。", String(describing: half.name)))
                }
            } else if window.frame == nil {
                throw DemoError(L("%@ 的窗口无法放入，请换一个窗口。", String(describing: half.name)))
            }
            moved += 1
        }
        return moved
    }

    func ordinaryWindows(on half: HalfScreen) async -> Set<CGWindowID> {
        let bounds = half.virtualBounds
        return await Task.detached(priority: .userInitiated) { [windows] in
            let records = Self.liveWindows()
            return Set(windows.compactMap { saved -> CGWindowID? in
                guard saved.slot == nil, let id = saved.id, let record = records[id], record.pid == saved.pid,
                      bounds.contains(CGPoint(x: record.frame.midX, y: record.frame.midY)) else { return nil }
                return id
            })
        }.value
    }

    func placeOrdinary(on half: HalfScreen, protecting: [Identity] = [], only: Set<CGWindowID>? = nil) async -> Int {
        guard windows.contains(where: { $0.slot == nil }),
              let screen = NSScreen.screens.first(where: { $0.displayID == half.virtualID }) else { return 0 }
        let result = await restore(for: .milliseconds(500), destination: { _ in screen }, ordinary: screen, ordinaryOnly: true, only: only)
        let targets = windows.filter { $0.slot == nil && (only == nil || $0.id.map { only?.contains($0) == true } == true) }
        await Self.moveWindowsToDesktop(targets, on: half.virtualID, protecting: protecting + identities)
        return result.restored
    }

    private typealias FullScreenTarget = (saved: SavedWindow, half: HalfScreen)

    func enterSelectedFullScreen(on halves: [HalfScreen]) async throws {
        let targets: [FullScreenTarget] = windows.reversed().compactMap { saved in
            guard let slot = saved.slot else { return nil }
            return (saved, halves[slot])
        }
        guard targets.count == 2 else { throw DemoError(L("请选择两个可全屏的窗口。")) }
        let clock = ContinuousClock()
        var parallelRequests: [FullScreenTarget] = []
        var requestDeadline: ContinuousClock.Instant?
        do {
            if targets[0].saved.pid != targets[1].saved.pid {
                try Task.checkCancellation()
                requestDeadline = clock.now + .seconds(5)
                parallelRequests = targets.filter(Self.requestFullScreen)
                if !parallelRequests.isEmpty {
                    let requests = parallelRequests
                    let ready = await Task {
                        await Self.waitForFullScreen(requests, stableFor: .milliseconds(180), timeout: .milliseconds(900))
                    }.value
                    try Task.checkCancellation()
                    if ready && requests.count == targets.count { return }
                }
            }

            // AppKit serializes Space transitions for windows of the same app.
            for (index, target) in targets.enumerated() {
                try Task.checkCancellation()
                let stableFor: Duration = index == targets.count - 1 ? .milliseconds(180) : .milliseconds(450)
                // An in-flight transition must finish before a cancelled split restores the window.
                if Self.isFullScreen(target.saved, on: target.half) || Self.requestFullScreen(target) {
                    let entered = await Task {
                        await Self.waitForFullScreen([target], stableFor: stableFor, timeout: .milliseconds(1700))
                    }.value
                    try Task.checkCancellation()
                    if entered { continue }
                }
                let error = DemoError(L("%@的窗口无法进入原生全屏，请换一个窗口。", String(describing: target.half.name)))
                if let app = NSRunningApplication(processIdentifier: target.saved.pid), let id = target.saved.id {
                    Window.reveal(id, in: app)
                }
                guard Self.isFullScreen(target.saved, on: target.half) || Self.requestFullScreen(target) else { throw error }
                let entered = await Task {
                    await Self.waitForFullScreen([target], stableFor: stableFor, timeout: .milliseconds(2400))
                }.value
                try Task.checkCancellation()
                guard entered else { throw error }
            }
            for target in targets where !Self.isFullScreen(target.saved, on: target.half) {
                throw DemoError(L("%@的窗口未保持全屏，请重试。", String(describing: target.half.name)))
            }
        } catch {
            if let requestDeadline, clock.now < requestDeadline, !parallelRequests.isEmpty {
                let requests = parallelRequests
                let remaining = clock.now.duration(to: requestDeadline)
                _ = await Task {
                    await Self.waitForFullScreen(requests, stableFor: .milliseconds(180), timeout: remaining)
                }.value
            }
            throw error
        }
    }

    private static func requestFullScreen(_ target: FullScreenTarget) -> Bool {
        let window = target.saved.window
        var result = window.setFullScreen(true)
        if result == .invalidUIElement, let replacement = resolve(target.saved, in: liveWindows()) {
            result = replacement.setFullScreen(true)
        }
        return result == .success || result == .cannotComplete
    }

    private static func waitForFullScreen(_ targets: [FullScreenTarget], stableFor: Duration,
                                          timeout: Duration = .seconds(5)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var readySince: ContinuousClock.Instant?
        while clock.now < deadline {
            if targets.allSatisfy({ isFullScreen($0.saved, on: $0.half) }) {
                if let readySince, clock.now - readySince >= stableFor { return true }
                readySince = readySince ?? clock.now
            } else {
                readySince = nil
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private static func isFullScreen(_ saved: SavedWindow, on half: HalfScreen) -> Bool {
        let frame: CGRect
        if let original = saved.window.frame {
            guard saved.window.isFullScreen else { return false }
            frame = original
        } else {
            guard let window = resolve(saved, in: liveWindows()), window.isFullScreen,
                  let recovered = window.frame else { return false }
            frame = recovered
        }
        guard !frame.isEmpty else { return false }
        return half.virtualBounds.insetBy(dx: -2, dy: -2).contains(frame)
    }

    func recoveryWindows(mapDisplay: (PhysicalScreen) -> (screen: PhysicalScreen, origin: CGPoint)) -> [RecoveryJournal.Window] {
        windows.compactMap { saved in
            guard saved.slot != nil, let number = saved.id, let frame = saved.original ?? saved.window.frame,
                  let app = NSRunningApplication(processIdentifier: saved.pid), let launchDate = app.launchDate else { return nil }
            let mapped = mapDisplay(saved.display)
            let display = mapped.screen
            guard let uuid = RecoveryJournal.uuid(display.id) else { return nil }
            let translated = frame.offsetBy(dx: mapped.origin.x - saved.display.bounds.minX,
                                             dy: mapped.origin.y - saved.display.bounds.minY)
            return RecoveryJournal.Window(number: number, pid: saved.pid, launchDate: launchDate,
                                          displayUUID: uuid, displayBounds: display.bounds, frame: translated,
                                          fullScreen: saved.fullScreenDisplay != nil, minimized: saved.wasMinimized,
                                          hidden: unhiddenApps[saved.pid] != nil)
        }
    }

    static func recoverWindows(_ records: [RecoveryJournal.Window]) async -> Bool {
        var success = true
        for record in records {
            guard let app = NSRunningApplication(processIdentifier: record.pid), app.launchDate == record.launchDate,
                  let info = liveWindows()[record.number], info.pid == record.pid else { continue }
            // Background apps may omit windows from AXWindows after launch or a Space change.
            // Use the same bounded exact-window lookup/activation fallback as split preparation.
            let choice = Choice(id: .window(record.number), element: nil, pid: record.pid,
                                appName: app.localizedName ?? L("窗口"), title: info.title, frame: info.frame, status: nil)
            let window: Window
            do { window = try await openWindow(choice, in: app) }
            catch {
                success = false
                DemoLog.shared.line(L("恢复窗口 %@ 时无法取得控制权限，请重试。", String(record.number)))
                continue
            }
            guard let target = NSScreen.screens.first(where: { $0.displayID.flatMap(RecoveryJournal.uuid) == record.displayUUID })
                    ?? NSScreen.screens.first else { success = false; continue }
            if app.isHidden { app.unhide() }
            if window.isMinimized { window.setMinimized(false) }
            if window.isFullScreen, !(await exitFullScreen(window)) { success = false; continue }
            let bounds = cocoaRect(target.frame)
            let desired = fit(record.frame.offsetBy(dx: bounds.minX - record.displayBounds.minX,
                                                    dy: bounds.minY - record.displayBounds.minY), inside: cocoaRect(target.visibleFrame))
            var placed = false
            for _ in 0..<10 {
                window.place(desired)
                try? await Task.sleep(for: .milliseconds(100))
                if let frame = window.frame, near(frame, desired) { placed = true; break }
            }
            if !placed { success = false }
            if record.fullScreen, let id = target.displayID {
                if !(await restoreFullScreen(window, on: id)) { success = false }
            } else if record.minimized { window.setMinimized(true) }
            if record.hidden { app.hide() }
        }
        return success
    }

    // Read AX off the main thread; a busy app must not freeze the display mirrors.
    func selectedFullScreenState() async -> QuickExitPolicy.Sample {
        let selected = windows.filter { $0.slot != nil }
        return await Task.detached(priority: .utility) {
            guard selected.count == 2 else { return .unknown }
            let live = Self.liveWindows()
            var unknown = false
            for saved in selected {
                guard NSRunningApplication(processIdentifier: saved.pid)?.isTerminated == false else { return .ended }
                if let window = Self.resolve(saved, in: live), let fullScreen = window.fullScreen {
                    if !fullScreen { return .ended }
                } else {
                    // A failed AX query alone is not evidence of a closed window.
                    if saved.window.exists == false,
                       saved.id.map({ live[$0]?.pid != saved.pid }) ?? true { return .ended }
                    unknown = true
                }
            }
            return unknown ? .unknown : .fullScreen
        }.value
    }

    func leaveFullScreen(on halves: [HalfScreen], includeSelected: Bool) async -> Bool {
        let bounds = halves.map { $0.virtualBounds.insetBy(dx: -2, dy: -2) }
        return await Task.detached(priority: .userInitiated) { [windows] in
            let live = Self.liveWindows()
            var unresolved = false
            let targets = windows.compactMap { saved -> (pid_t, Window)? in
                if saved.fullScreenDisplay != nil && saved.original == nil { return nil }
                guard let window = Self.resolve(saved, in: live) else {
                    if let id = saved.id, live[id]?.pid == saved.pid { unresolved = true }
                    return nil
                }
                guard let fullScreen = window.fullScreen else { unresolved = true; return nil }
                guard fullScreen else { return nil }
                guard let frame = window.frame else { unresolved = true; return nil }
                guard
                      (includeSelected && saved.slot != nil) || bounds.contains(where: { $0.contains(frame) }) else { return nil }
                return (saved.pid, window)
            }
            return await withTaskGroup(of: Bool.self) { group in
                for appWindows in Dictionary(grouping: targets, by: { $0.0 }).values {
                    group.addTask {
                        var success = true
                        for (_, window) in appWindows { if !(await Self.exitFullScreen(window)) { success = false } }
                        return success
                    }
                }
                var success = !unresolved
                for await result in group { success = result && success }
                return success
            }
        }.value
    }

    nonisolated private static func exitFullScreen(_ window: Window) async -> Bool {
        // AppKit serializes Space transitions within each application.
        var readySince: ContinuousClock.Instant?
        var lastFrame: CGRect?
        for attempt in 0..<24 {
            let isFullScreen = window.fullScreen
            if isFullScreen == false, let frame = window.frame {
                let now = ContinuousClock.now
                if let lastFrame, near(frame, lastFrame), let readySince {
                    if now - readySince >= .milliseconds(400) { return true }
                } else {
                    readySince = now
                }
                lastFrame = frame
            } else {
                readySince = nil
                lastFrame = nil
            }
            if isFullScreen == true && attempt.isMultiple(of: 12) {
                window.setFullScreen(false)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// Move app windows and floating panels out from behind the physical mirrors.
    func rescueHiddenWindows(to halves: [HalfScreen], protecting: [Identity], shouldContinue: () -> Bool) async {
        let hidden = CGDisplayBounds(source.id)
        let excluded = protecting + identities
        let scan = Task.detached(priority: .utility) {
            let levels = Set([0, Int(CGWindowLevelForKey(.floatingWindow)), Int(CGWindowLevelForKey(.modalPanelWindow))])
            let records = Self.windowList([.optionOnScreenOnly, .excludeDesktopElements], levels: levels).filter { record in
                hidden.contains(CGPoint(x: record.frame.midX, y: record.frame.midY)) &&
                    !excluded.contains { identity in identity.matches(number: record.id, element: nil) }
            }
            let candidates = Self.movableWindows(from: records, includePanels: true).filter { match in
                !match.window.isMinimized && NSRunningApplication(processIdentifier: match.info.pid)?.isHidden == false &&
                    !excluded.contains { $0.matches(number: match.info.id, element: match.window.element) }
            }
            let panels = candidates.filter { $0.info.layer != 0 || $0.window.isMovablePanel }
            let panelOwners = Set(panels.map { $0.info.pid })
            let parents = Dictionary(uniqueKeysWithValues: panelOwners.compactMap { pid in
                Self.windowFrame(for: pid, attribute: kAXMainWindowAttribute).map { (pid, $0) }
            })
            return (candidates, Set(panels.map { $0.info.id }), parents)
        }
        let (candidates, panels, parents) = await scan.value
        guard !Task.isCancelled, shouldContinue(), CGDisplayBounds(source.id) == hidden else { return }
        var moves: [(window: Window, frame: CGRect, panel: Bool)] = []
        for match in candidates {
            guard let current = match.window.frame, Self.near(current, match.frame),
                  !match.window.isFullScreen, !match.window.isMinimized else { continue }
            let local = CGPoint(x: current.midX - hidden.minX, y: current.midY - hidden.minY)
            let panel = panels.contains(match.info.id)
            let parent = panel ? parents[match.info.pid] : nil
            let parentHalf = parent.flatMap { frame in
                halves.first { $0.virtualBounds.contains(CGPoint(x: frame.midX, y: frame.midY)) }
            }
            guard let half = parentHalf ?? halves.first(where: { $0.localRect.contains(local) }),
                  let screen = NSScreen.screens.first(where: { $0.displayID == half.virtualID }) else { continue }
            // A transient panel follows its app while visible. It does not own a desktop position to restore.
            if !panel && !windows.contains(where: { $0.id == match.info.id && $0.pid == match.info.pid }) {
                let original = current.offsetBy(dx: source.bounds.minX - hidden.minX, dy: source.bounds.minY - hidden.minY)
                windows.append(SavedWindow(window: match.window, id: match.info.id, pid: match.info.pid,
                                           original: original, display: source, slot: nil))
            }
            let translated: CGRect
            if let parent, parentHalf != nil, !half.localRect.contains(local) {
                translated = CGRect(x: parent.midX - current.width / 2, y: parent.midY - current.height / 2,
                                    width: current.width, height: current.height)
            } else {
                translated = current.offsetBy(dx: half.virtualBounds.minX - hidden.minX - half.localRect.minX,
                                              dy: half.virtualBounds.minY - hidden.minY - half.localRect.minY)
            }
            moves.append((match.window, Self.fit(translated, inside: cocoaRect(screen.visibleFrame)), panel))
        }
        guard !moves.isEmpty else { return }
        do {
            if moves.contains(where: { !$0.panel }) { try onCheckpoint?() }
        } catch {
            DemoLog.shared.line(L("窗口补位暂缓：%@", String(describing: error.localizedDescription)))
            return
        }
        // Keep the short AX writes on the main actor so a join cannot start between validation and placement.
        for (window, frame, panel) in moves {
            if panel { window.setPosition(frame.origin) }
            else { window.place(frame) }
        }
    }

    func collectRemainingWindows(on halves: [HalfScreen], reserved: [Identity]) async {
        let displayIDs = [source.id] + halves.map(\.virtualID)
        let sourceBounds = displayIDs.map { CGDisplayBounds($0) }
        let tracked = windows.map { Identity(number: $0.id, element: $0.window.element) }
        let inventory = Task.detached(priority: .userInitiated) {
            let excluded = tracked + reserved
            let retiring = DesktopSpaces().map { desktops in Set(displayIDs.flatMap { desktops.spaceIDs(in: $0) }) }
            let remaining = Self.windowList([.excludeDesktopElements]).filter { info in
                guard info.frame.height >= 50, !excluded.contains(where: { $0.matches(number: info.id, element: nil) }) else { return false }
                if let retiring, !retiring.isEmpty, let membership = DesktopSpaces.spaces(for: info.id), !membership.isEmpty {
                    return !retiring.isDisjoint(with: membership)
                }
                return sourceBounds.contains { $0.contains(CGPoint(x: info.frame.midX, y: info.frame.midY)) }
            }
            return Self.movableWindows(from: remaining, allowOffscreen: true, includeFullScreen: true).filter { match in
                !excluded.contains { $0.matches(number: match.info.id, element: match.window.element) }
            }
        }
        for match in await inventory.value {
            var desktop = source
            let center = CGPoint(x: match.frame.midX, y: match.frame.midY)
            desktop.bounds = sourceBounds.first { $0.contains(center) } ?? source.bounds
            windows.append(SavedWindow(window: match.window, id: match.info.id, pid: match.info.pid,
                                       original: match.frame, display: desktop, slot: nil,
                                       fullScreenDisplay: match.window.isFullScreen ? source : nil))
        }
    }

    /// A long-lived desktop keeps the user's latest window arrangement when merged.
    func preserveDesktopChanges(on halves: [HalfScreen]) async {
        let bounds = halves.map(\.virtualBounds)
        guard bounds.count == 2, bounds.allSatisfy({ !$0.isEmpty }) else { return }
        let snapshot = windows
        let offsets = halves.map(\.localRect.origin)
        let source = self.source
        let updated = await Task.detached(priority: .utility) {
            let live = Self.liveWindows()
            return snapshot.compactMap { saved -> SavedWindow? in
                guard saved.slot == nil else { return saved }
                guard NSRunningApplication(processIdentifier: saved.pid)?.isTerminated == false else { return nil }
                guard let window = Self.resolve(saved, in: live), let frame = window.frame else {
                    // Preserve recovery data when an app is temporarily unresponsive.
                    if saved.window.exists == false, saved.id.map({ live[$0]?.pid != saved.pid }) ?? true { return nil }
                    return saved
                }
                let center = CGPoint(x: frame.midX, y: frame.midY)
                // Windows deliberately moved to another monitor are no longer ours to restore.
                guard let index = bounds.firstIndex(where: { $0.contains(center) }) else { return nil }
                var current = saved
                let origin = source.bounds.origin
                current.original = frame.offsetBy(dx: origin.x + offsets[index].x - bounds[index].minX,
                                                   dy: origin.y + offsets[index].y - bounds[index].minY)
                current.display = source
                current.wasMinimized = window.isMinimized
                current.wasInStageStrip = false
                current.fullScreenDisplay = window.isFullScreen ? source : nil
                return current
            }
        }.value
        windows = updated
    }

    func moveToDesktops(destination: (CGDirectDisplayID?) -> NSScreen?, ordinary: NSScreen?,
                        protecting: [Identity]) async {
        let targets = windows.compactMap { saved -> (CGDirectDisplayID, SavedWindow)? in
            let preferred = saved.slot == nil ? ordinary : nil
            guard let id = (preferred ?? destination(saved.display.id))?.displayID else { return nil }
            return (id, saved)
        }
        for (display, targets) in Dictionary(grouping: targets, by: { $0.0 }) {
            await Self.moveWindowsToDesktop(targets.map(\.1), on: display, protecting: protecting)
        }
    }

    private nonisolated static func moveWindowsToDesktop(_ targets: [SavedWindow], on destination: CGDirectDisplayID,
                                                          protecting: [Identity]) async {
        guard !targets.isEmpty else { return }
        await Task.detached(priority: .userInitiated) {
            guard let desktops = DesktopSpaces(), let target = desktops.desktop(on: destination) else { return }
            let protected = Set(protecting.compactMap(\.pid))
            let candidates = Set(targets.map(\.pid)).subtracting(protected)
            let tracked = Set(targets.compactMap(\.id))
            guard !candidates.isEmpty else { return }
            let records = Dictionary(grouping: Self.windowList([.excludeDesktopElements]).filter { candidates.contains($0.pid) }, by: \.pid)
            for (pid, windows) in records {
                let memberships = windows.compactMap { record in DesktopSpaces.spaces(for: record.id).map { (record, Set($0)) } }
                // The window server can move a whole app without switching focus. Do that
                // only when none of its windows would be pulled off another desktop.
                guard memberships.count == windows.count,
                      memberships.contains(where: { tracked.contains($0.0.id) && !$0.1.isEmpty && !$0.1.contains(target) }),
                      memberships.allSatisfy({ record, spaces in
                          spaces.isEmpty || tracked.contains(record.id) || spaces == [target]
                      }) else { continue }
                DesktopSpaces.moveApp(pid, to: target)
            }
        }.value
    }

    func restore(for timeout: Duration, destination: (CGDirectDisplayID?) -> NSScreen?,
                 ordinary: NSScreen? = nil, ordinaryOnly: Bool = false, only: Set<CGWindowID>? = nil) async -> (restored: Int, failed: Int, retry: Set<CGWindowID>) {
        let targets = windows.filter { saved in
            guard saved.original != nil, !ordinaryOnly || saved.slot == nil else { return false }
            guard let only else { return true }
            return saved.id.map { only.contains($0) } == true
        }
        let work = targets.compactMap { saved -> (Int, SavedWindow, CGRect, CGRect)? in
            let preferred = saved.slot == nil ? ordinary : nil
            guard let original = saved.original,
                  let target = preferred ?? destination(saved.display.id) ?? destination(nil) else { return nil }
            let bounds = cocoaRect(target.frame)
            let originalBounds = saved.display.bounds
            let translated = original.offsetBy(dx: bounds.minX - originalBounds.minX, dy: bounds.minY - originalBounds.minY)
            let desired = preferred == nil && target.displayID == saved.display.id && bounds.size == originalBounds.size
                ? translated : Self.fit(translated, inside: cocoaRect(target.visibleFrame))
            return (saved.slot ?? -1, saved, bounds, desired)
        }
        // AX calls can wait for another app to respond; keep the mirrors drawing during that wait.
        return await Task.detached(priority: .userInitiated) {
            var pending = work
            var restored = 0
            var settled: [Int: ContinuousClock.Instant] = [:]
            let deadline = ContinuousClock.now + timeout
            repeat {
                var live: [CGWindowID: WindowInfo]?
                pending = pending.filter { slot, saved, bounds, desired in
                    guard NSRunningApplication(processIdentifier: saved.pid)?.isTerminated == false else { return false }
                    var window = saved.window
                    if window.frame == nil {
                        if live == nil { live = Self.liveWindows() }
                        if let id = saved.id, live?[id]?.pid != saved.pid { return false }
                        guard let replacement = live.flatMap({ Self.resolve(saved, in: $0) }) else { return true }
                        window = replacement
                    }
                    guard let frame = window.frame else { return true }
                    if saved.slot == nil && window.isFullScreen { return false }
                    if !Self.near(desired, frame) {
                        settled[slot] = nil
                        if frame.width > bounds.width || frame.height > bounds.height { window.setSize(desired.size) }
                        window.place(desired)
                        guard let actual = window.frame, Self.near(desired, actual) else { return true }
                    }
                    if slot >= 0 {
                        let now = ContinuousClock.now
                        let since = settled[slot] ?? now
                        settled[slot] = since
                        if now - since < .milliseconds(300) { return true }
                    }
                    restored += 1
                    return false
                }
                if !pending.isEmpty, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            } while !pending.isEmpty && ContinuousClock.now < deadline
            return (restored, pending.count + targets.count - work.count, Set(pending.compactMap { $0.1.id }))
        }.value
    }

    func recoverFrames(_ ids: Set<CGWindowID>, destination: (CGDirectDisplayID?) -> NSScreen?, ordinary: NSScreen?,
                       protecting: [Identity]) async -> (restored: Int, failed: Int, retry: Set<CGWindowID>) {
        let previous = NSWorkspace.shared.frontmostApplication
        let protected = Set(protecting.compactMap(\.pid))
        var revealed: NSRunningApplication?
        for saved in windows {
            guard let id = saved.id, ids.contains(id), !protected.contains(saved.pid),
                  let app = NSRunningApplication(processIdentifier: saved.pid), !app.isHidden else { continue }
            Window.reveal(id, in: app)
            revealed = app
        }
        let result = await restore(for: .seconds(2), destination: destination, ordinary: ordinary, only: ids)
        if revealed?.isActive == true, let previous, previous.processIdentifier != getpid(), !previous.isTerminated { previous.activate() }
        return result
    }

    func restorePresentation(destination: (CGDirectDisplayID?) -> NSScreen?) async -> (failed: Int, minimizedToStage: Int) {
        var failures = 0
        var minimizedToStage = 0
        for saved in windows where saved.wasMinimized || saved.wasInStageStrip || saved.fullScreenDisplay != nil {
            guard let window = Self.resolve(saved, in: Self.liveWindows()) else { continue }
            if let display = saved.fullScreenDisplay {
                guard let target = destination(display.id)?.displayID ?? destination(nil)?.displayID else { failures += 1; continue }
                if !(await Self.restoreFullScreen(window, on: target)) { failures += 1 }
            } else {
                if !window.isMinimized && !Self.hasStageThumbnail(saved) {
                    if saved.wasInStageStrip { window.pressMinimizeButton() }
                    else { window.setMinimized(true) }
                }
                for _ in 0..<12 {
                    if window.isMinimized || Self.hasStageThumbnail(saved) { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if Self.hasStageThumbnail(saved) {
                    if saved.wasMinimized { minimizedToStage += 1 }
                } else if !window.isMinimized || saved.wasInStageStrip {
                    failures += 1
                }
            }
        }
        for app in unhiddenApps.values where !app.isTerminated && !app.isHidden {
            app.hide()
            for _ in 0..<10 {
                if app.isHidden || app.isTerminated { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if !app.isHidden && !app.isTerminated { failures += 1 }
        }
        return (failures, minimizedToStage)
    }

    private static func hasStageThumbnail(_ saved: SavedWindow) -> Bool {
        guard let id = saved.id, let record = liveWindows()[id], record.pid == saved.pid else { return false }
        return isInStageStrip(record.frame, original: saved.original, on: CGDisplayBounds(saved.display.id))
    }

    private static func isInStageStrip(_ frame: CGRect?, original: CGRect?, on display: CGRect) -> Bool {
        // shortcut: Stage Manager exposes sidebar thumbnails as scaled WindowServer frames. Use the strip bounds until there is a window-state API.
        guard UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") == true,
              let frame, let original, frame.width < min(150, original.width / 2), frame.height < min(180, original.height / 2),
              frame.midY > display.minY, frame.midY < display.maxY else { return false }
        return abs(frame.minX - display.minX) < 40 || abs(frame.maxX - display.maxX) < 40
    }

    private nonisolated static func restoreFullScreen(_ original: Window, on display: CGDirectDisplayID) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            var window = original
            var pid: pid_t = 0
            guard AXUIElementGetPid(window.element, &pid) == .success else { return false }
            let number = window.number
            if let app = NSRunningApplication(processIdentifier: pid) {
                await MainActor.run {
                    NSApp.yieldActivation(to: app)
                    app.activate(options: [.activateAllWindows])
                }
                if let number { Window.reveal(number, in: app) }
                AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
            }
            let bounds = CGDisplayBounds(display)
            guard !bounds.isEmpty else { return false }
            let deadline = ContinuousClock.now + .seconds(7)
            var requestedAt: ContinuousClock.Instant?
            var readySince: ContinuousClock.Instant?
            while ContinuousClock.now < deadline, !Task.isCancelled {
                if window.frame == nil, let number, let record = liveWindows()[number], record.pid == pid,
                   let replacement = Window.find(record) ?? Window.findUnlistedWindow(record) { window = replacement }
                let fullScreen = window.fullScreen
                let frame = window.frame
                let onTarget = frame.map { bounds.contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? false
                if fullScreen == true && onTarget {
                    let now = ContinuousClock.now
                    if let readySince, now - readySince >= .milliseconds(300) { return true }
                    if readySince == nil { readySince = now }
                } else {
                    readySince = nil
                    if fullScreen == true {
                        guard await exitFullScreen(window) else { return false }
                    } else if fullScreen == false, let frame {
                        window.place(Self.fit(frame, inside: bounds))
                        let now = ContinuousClock.now
                        if requestedAt == nil || now - requestedAt! >= .seconds(1) {
                            window.setFullScreen(true)
                            requestedAt = now
                        }
                    }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return false
        }.value
    }

    private struct WindowInfo: Sendable {
        let id: CGWindowID
        let pid: pid_t
        let layer: Int
        let frame: CGRect
        let title: String
        let onScreen: Bool
    }

    nonisolated private static func movableWindows(from visible: [WindowInfo], allowOffscreen: Bool = false,
                                                  includeFullScreen: Bool = false, includePanels: Bool = false) -> [(info: WindowInfo, window: Window, frame: CGRect)] {
        var matches: [CGWindowID: (window: Window, frame: CGRect)] = [:]
        for (pid, candidates) in Dictionary(grouping: visible, by: \.pid) {
            if allowOffscreen, NSRunningApplication(processIdentifier: pid)?.activationPolicy != .regular { continue }
            var remaining = candidates
            for window in Window.accessibleWindows(for: pid) {
                guard !remaining.isEmpty, (includeFullScreen && window.isFullScreen) || window.canMove || (includePanels && window.isMovablePanel),
                      includeFullScreen || !window.isFullScreen, let frame = window.frame else { continue }
                let index: Int?
                if let id = window.number { index = remaining.firstIndex { $0.id == id && (allowOffscreen || near(frame, $0.frame)) } }
                else { index = remaining.firstIndex { near(frame, $0.frame) } }
                guard let index else { continue }
                let info = remaining.remove(at: index)
                matches[info.id] = (window, frame)
            }
            if allowOffscreen {
                for info in remaining where !info.title.isEmpty && !info.onScreen {
                    guard let window = Window.findUnlistedWindow(info), (includeFullScreen && window.isFullScreen) || window.canMove,
                          includeFullScreen || !window.isFullScreen,
                          let frame = window.frame else { continue }
                    matches[info.id] = (window, frame)
                }
            }
        }
        return visible.compactMap { info in
            matches[info.id].map { (info, $0.window, $0.frame) }
        }
    }

    nonisolated private static func liveWindows() -> [CGWindowID: WindowInfo] {
        Dictionary(uniqueKeysWithValues: windowList([.excludeDesktopElements]).map { ($0.id, $0) })
    }

    nonisolated private static func resolve(_ saved: SavedWindow, in live: [CGWindowID: WindowInfo]) -> Window? {
        if saved.window.frame != nil { return saved.window }
        guard let id = saved.id, let info = live[id], info.pid == saved.pid else { return nil }
        return Window.find(info) ?? Window.findUnlistedWindow(info)
    }

    nonisolated private static func windowList(_ options: CGWindowListOption, levels: Set<Int> = [0]) -> [WindowInfo] {
        let entries = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            guard let layer = entry[kCGWindowLayer as String] as? Int, levels.contains(layer),
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(),
                  let dictionary = entry[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  frame.width > 1, frame.height > 1 else { return nil }
            return WindowInfo(id: id, pid: pid, layer: layer, frame: frame, title: entry[kCGWindowName as String] as? String ?? "",
                              onScreen: entry[kCGWindowIsOnscreen as String] as? Bool == true)
        }
    }

    private static func overlap(of frame: CGRect, with bounds: CGRect) -> CGFloat {
        let intersection = frame.intersection(bounds)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    nonisolated private static func fit(_ frame: CGRect, inside bounds: CGRect) -> CGRect {
        let width = min(frame.width, bounds.width)
        let height = min(frame.height, bounds.height)
        return CGRect(x: min(max(frame.minX, bounds.minX), bounds.maxX - width),
                      y: min(max(frame.minY, bounds.minY), bounds.maxY - height),
                      width: width, height: height)
    }

    nonisolated static func near(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 2 && abs(lhs.minY - rhs.minY) <= 2
            && abs(lhs.width - rhs.width) <= 2 && abs(lhs.height - rhs.height) <= 2
    }

    private struct SavedWindow: Sendable {
        var window: Window
        let id: CGWindowID?
        let pid: pid_t
        var original: CGRect?
        var display: PhysicalScreen
        let slot: Int?
        var wasMinimized = false
        var wasInStageStrip = false
        var fullScreenDisplay: PhysicalScreen?
    }

    private struct Window: @unchecked Sendable {
        let element: AXUIElement
        private static let fullScreenAttribute = "AXFullScreen"
        private static let frameAttributes = [kAXPositionAttribute, kAXSizeAttribute]
        private static let pickerAttributes = [kAXRoleAttribute, kAXMinimizedAttribute, fullScreenAttribute,
                                               kAXPositionAttribute, kAXSizeAttribute, kAXTitleAttribute]
        private static let getWindowNumber = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow").map {
            unsafeBitCast($0, to: (@convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError).self)
        }
        private static let windowFromToken = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementCreateWithRemoteToken").map {
            unsafeBitCast($0, to: (@convention(c) (CFData) -> Unmanaged<AXUIElement>?).self)
        }

        static func accessibleWindows(for pid: pid_t) -> [Window] {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            let names = [kAXWindowsAttribute, kAXFocusedWindowAttribute, kAXMainWindowAttribute]
            guard let values = Window(element: app).attributes(names) else { return [] }
            var elements = values[0] as? [AXUIElement] ?? []
            for value in values.dropFirst() where CFGetTypeID(value) == AXUIElementGetTypeID() {
                let window = value as! AXUIElement
                if !elements.contains(window) { elements.append(window) }
            }
            return elements.map {
                AXUIElementSetMessagingTimeout($0, 0.25)
                return Window(element: $0)
            }
        }

        var number: CGWindowID? {
            var id: CGWindowID = 0
            guard Self.getWindowNumber?(element, &id) == .success, id != 0 else { return nil }
            return id
        }

        static func find(_ record: WindowInfo) -> Window? {
            let windows = accessibleWindows(for: record.pid)
            if let exact = windows.first(where: { $0.number == record.id && $0.pickerDetails != nil }) { return exact }
            let nearby = windows.filter { window in
                guard window.number == nil, let details = window.pickerDetails, let frame = details.frame else { return false }
                return near(frame, record.frame) && (record.title.isEmpty || record.title == details.title)
            }
            return nearby.count == 1 ? nearby.first : nil
        }

        static func findUnlistedWindow(_ record: WindowInfo) -> Window? {
            guard let windowFromToken, getWindowNumber != nil else { return nil }
            // shortcut: A bounded AX lookup for the exact selected window, used when macOS omits it from AXWindows.
            // The AppKit token contains the PID, a reserved word, the "coco" tag, and an element ID.
            var token = Data(repeating: 0, count: 20)
            withUnsafeBytes(of: record.pid.littleEndian) { token.replaceSubrange(0..<4, with: $0) }
            withUnsafeBytes(of: UInt32(0x636f636f).littleEndian) { token.replaceSubrange(8..<12, with: $0) }
            let clock = ContinuousClock()
            let deadline = clock.now + .milliseconds(250)
            for id in UInt64(0)..<8192 {
                guard !Task.isCancelled, clock.now < deadline else { break }
                withUnsafeBytes(of: id.littleEndian) { token.replaceSubrange(12..<20, with: $0) }
                guard let element = windowFromToken(token as CFData)?.takeRetainedValue() else { continue }
                AXUIElementSetMessagingTimeout(element, 0.05)
                let window = Window(element: element)
                guard window.number == record.id, window.pickerDetails != nil else { continue }
                AXUIElementSetMessagingTimeout(element, 0.25)
                return window
            }
            return nil
        }

        static func reveal(_ number: CGWindowID, in app: NSRunningApplication) {
            let symbols = UnsafeMutableRawPointer(bitPattern: -2)
            if let pidSymbol = dlsym(symbols, "GetProcessForPID"),
               let frontSymbol = dlsym(symbols, "_SLPSSetFrontProcessWithOptions") {
                let getProcess = unsafeBitCast(pidSymbol, to: (@convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus).self)
                let setFront = unsafeBitCast(frontSymbol, to: (@convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError).self)
                var process = ProcessSerialNumber()
                if getProcess(app.processIdentifier, &process) == noErr, setFront(&process, number, 0x200) == .success { return }
            }
            app.activate()
        }

        var canMove: Bool {
            guard Self.attribute(kAXSubroleAttribute as String, of: element) as? String == kAXStandardWindowSubrole as String,
                  Self.attribute(kAXMinimizedAttribute as String, of: element) as? Bool != true else { return false }
            return positionIsSettable
        }

        var isStandard: Bool {
            Self.attribute(kAXSubroleAttribute as String, of: element) as? String == kAXStandardWindowSubrole as String
        }

        var isMovablePanel: Bool {
            guard let subrole = Self.attribute(kAXSubroleAttribute, of: element) as? String,
                  subrole == kAXFloatingWindowSubrole || subrole == kAXDialogSubrole else { return false }
            return positionIsSettable
        }

        var positionIsSettable: Bool {
            var settable = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &settable) == .success && settable.boolValue
        }

        var canResize: Bool {
            var settable = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable) == .success && settable.boolValue
        }

        var pickerDetails: (frame: CGRect?, title: String, minimized: Bool, fullScreen: Bool)? {
            guard let values = attributes(Self.pickerAttributes),
                  values[0] as? String == kAXWindowRole as String else { return nil }
            return (Self.frame(position: values[3], size: values[4]), values[5] as? String ?? "",
                    values[1] as? Bool == true, values[2] as? Bool == true)
        }

        var isMinimized: Bool { Self.attribute(kAXMinimizedAttribute, of: element) as? Bool == true }

        func setMinimized(_ minimized: Bool) {
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, minimized ? kCFBooleanTrue : kCFBooleanFalse)
        }

        func pressMinimizeButton() {
            if let button = Self.attribute(kAXMinimizeButtonAttribute, of: element), CFGetTypeID(button) == AXUIElementGetTypeID() {
                AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
            }
        }

        var exists: Bool? {
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
            if result == .invalidUIElement { return false }
            return result == .success ? true : nil
        }

        var isFullScreen: Bool { fullScreen == true }
        var fullScreen: Bool? { Self.attribute(Self.fullScreenAttribute, of: element) as? Bool }
        var supportsFullScreen: Bool {
            guard canSetFullScreen else { return false }
            if let button = Self.attribute(kAXFullScreenButtonAttribute, of: element), CFGetTypeID(button) == AXUIElementGetTypeID(),
               let enabled = Self.attribute(kAXEnabledAttribute, of: button as! AXUIElement) as? Bool {
                return enabled
            }
            return canResize
        }

        var canSetFullScreen: Bool {
            var settable = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(element, Self.fullScreenAttribute as CFString, &settable) == .success
                && settable.boolValue
        }

        @discardableResult
        func setFullScreen(_ enabled: Bool) -> AXError {
            AXUIElementSetAttributeValue(element, Self.fullScreenAttribute as CFString, enabled ? kCFBooleanTrue : kCFBooleanFalse)
        }

        var frame: CGRect? {
            guard let values = attributes(Self.frameAttributes) else { return nil }
            return Self.frame(position: values[0], size: values[1])
        }

        private static func frame(position: CFTypeRef, size: CFTypeRef) -> CGRect? {
            guard CFGetTypeID(position) == AXValueGetTypeID(),
                  CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
            var origin = CGPoint.zero
            var dimensions = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
                  AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
                  dimensions.width > 0, dimensions.height > 0 else { return nil }
            return CGRect(origin: origin, size: dimensions)
        }

        private func attributes(_ names: [String]) -> [CFTypeRef]? {
            var values: CFArray?
            let error = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &values)
            if error == .notImplemented {
                return names.map { Self.attribute($0, of: element) ?? kCFNull }
            }
            guard error == .success, let values = values as? [CFTypeRef], values.count == names.count else { return nil }
            return values
        }

        func place(_ desired: CGRect) {
            guard let before = frame else { return }
            if before.origin != desired.origin {
                setPosition(desired.origin)
            }
            if before.size != desired.size {
                setSize(desired.size)
                setPosition(desired.origin)
            }
        }

        func setSize(_ size: CGSize) {
            var size = size
            if let value = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
            }
        }

        func setPosition(_ position: CGPoint) {
            var position = position
            if let value = AXValueCreate(.cgPoint, &position) {
                AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
            }
        }

        static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }
    }
}

/// AX frame changes alone may leave a background window on its old Space.
private struct DesktopSpaces {
    private static let symbols = UnsafeMutableRawPointer(bitPattern: -2)
    private static let connection = load("SLSMainConnectionID", as: (@convention(c) () -> Int32).self)?() ?? 0
    private static let readDisplays = load("SLSCopyManagedDisplaySpaces", as: (@convention(c) (Int32) -> Unmanaged<CFArray>?).self)
    private static let readWindow = load("SLSCopySpacesForWindows", as: (@convention(c) (Int32, UInt32, CFArray) -> Unmanaged<CFArray>?).self)
    private static let moveProcess = load("SLSProcessAssignToSpace", as: (@convention(c) (Int32, pid_t, UInt64) -> Int32).self)
    private let displays: [[String: Any]]

    init?() {
        guard Self.connection != 0, let displays = Self.readDisplays?(Self.connection)?.takeRetainedValue() as? [[String: Any]] else { return nil }
        self.displays = displays
    }

    func desktopSpaceIDs(in displayID: CGDirectDisplayID) -> [UInt64] {
        spaces(on: displayID).map(\.id)
    }

    func spaceIDs(in displayID: CGDirectDisplayID, fullScreenOnly: Bool = false) -> [UInt64] {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return [] }
        let identifier = CFUUIDCreateString(nil, uuid) as String
        guard let display = displays.first(where: { $0["Display Identifier"] as? String == identifier }) else { return [] }
        return (display["Spaces"] as? [[String: Any]] ?? []).compactMap {
            guard !fullScreenOnly || ($0["type"] as? NSNumber)?.intValue == 4 else { return nil }
            return ($0["id64"] as? NSNumber)?.uint64Value
        }
    }

    func desktop(on displayID: CGDirectDisplayID) -> UInt64? {
        let spaces = spaces(on: displayID)
        return spaces.first(where: \.current)?.id ?? spaces.first?.id
    }

    private func spaces(on displayID: CGDirectDisplayID) -> [(id: UInt64, current: Bool)] {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return [] }
        let identifier = CFUUIDCreateString(nil, uuid) as String
        guard let display = displays.first(where: {
            let name = $0["Display Identifier"] as? String
            return name == identifier || (name == "Main" && displayID == CGMainDisplayID())
        }) else { return [] }
        let current = (display["Current Space"] as? [String: Any])?["id64"] as? NSNumber
        return (display["Spaces"] as? [[String: Any]] ?? []).compactMap { space in
            guard (space["type"] as? NSNumber)?.intValue == 0, let id = space["id64"] as? NSNumber else { return nil }
            return (id.uint64Value, id == current)
        }
    }

    static func spaces(for window: CGWindowID) -> [UInt64]? {
        guard connection != 0, let values = readWindow?(connection, 7, [NSNumber(value: window)] as CFArray)?.takeRetainedValue() as? [NSNumber] else { return nil }
        return values.map(\.uint64Value)
    }

    static func moveApp(_ pid: pid_t, to space: UInt64) {
        _ = moveProcess?(connection, pid, space)
    }

    private static func load<T>(_ name: String, as type: T.Type) -> T? {
        dlsym(symbols, name).map { unsafeBitCast($0, to: type) }
    }
}
