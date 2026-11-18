import AppKit
@preconcurrency import CoreGraphics
import ScreenCaptureKit

@MainActor
final class SplitSessions {
    private(set) var sessions: [CGDirectDisplayID: Session] = [:]
    private(set) var transition: Session?
    private var originalScreens: [CGDirectDisplayID: PhysicalScreen] = [:]
    private var standby: [CGDirectDisplayID: [HalfScreen]] = [:]
    private var router: MouseRouter?
    private let captureOverlayQueue = DispatchQueue(label: "dev.cmkk.panelet.capture-overlays", qos: .userInitiated)
    private let popupValidation = CaptureOverlays.PopupValidation()
    private var captureOverlayTimer: Timer?
    private var captureOverlayQueryInFlight = false
    private var captureOverlayRevision: UInt64 = 0
    private var captureOverlayAnchor: CGWindowID?
    private var captureRouting = MouseRouter.CaptureRouting()
    private var nextScreenshotShortcutRead = ContinuousClock.now
    private var mirrorShields: [CGDirectDisplayID: Set<CGWindowID>] = [:]
    private var updatingMirrorShields = false
    private var routedLayout: [CGDirectDisplayID: CGRect] = [:]
    private var routedParking: [MouseRouter.Parking] = []
    private var layoutChangedAt: [CGDirectDisplayID: ContinuousClock.Instant] = [:]
    private var failedSessions: [CGDirectDisplayID: Error] = [:]
    private var captureRecovery: [CGDirectDisplayID: Task<Void, Never>] = [:]
    private var changingDisplays = false
    private var screenObserver: NSObjectProtocol?
    private var powerObservers: [NSObjectProtocol] = []
    private var sleeping = false
    private var screensSleeping = false
    private var sessionInactive = false
    private var wakeReadyAt = ContinuousClock.now
    fileprivate var monitoringAllowed: Bool { !sleeping && !screensSleeping && !sessionInactive && ContinuousClock.now >= wakeReadyAt }
    var onChange: ((Session) -> Void)?

    var active: [Session] { sessions.values.filter(\.active) }
    private(set) var recovering = false
    private(set) var recoveryProblem: String?
    var busy: Bool { transition != nil || recovering }
    fileprivate var parkedIDs: Set<CGDirectDisplayID> { Set(sessions.values.filter { $0.hasHalves && $0.isParkingPhysical }.map(\.targetID)) }

    init() {
        let notifications = NSWorkspace.shared.notificationCenter
        powerObservers.append(notifications.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = true
                self.captureOverlayRevision &+= 1
                for session in self.active { session.resetQuickMonitoring() }
            }
        })
        powerObservers.append(notifications.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = false
                self.captureOverlayRevision &+= 1
                self.wakeReadyAt = .now + .seconds(2)
                self.layoutChangedAt.removeAll()
                for session in self.active { session.resetQuickMonitoring() }
            }
        })
        for (name, inactive, screenEvent) in [
            (NSWorkspace.screensDidSleepNotification, true, true),
            (NSWorkspace.screensDidWakeNotification, false, true),
            (NSWorkspace.sessionDidResignActiveNotification, true, false),
            (NSWorkspace.sessionDidBecomeActiveNotification, false, false)
        ] {
            powerObservers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if screenEvent { self.screensSleeping = inactive }
                    else { self.sessionInactive = inactive }
                    self.captureOverlayRevision &+= 1
                    self.wakeReadyAt = .now + .seconds(2)
                    self.layoutChangedAt.removeAll()
                    for session in self.active { session.resetQuickMonitoring() }
                }
            })
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.busy { try? self.updateRoutes() }
                else { self.checkActive() }
            }
        }
    }

    func recoverPreviousSession() async {
        guard sessions.isEmpty, !recovering else { return }
        recovering = true
        defer {
            recovering = false
            if let recoveryProblem { DemoLog.shared.line(recoveryProblem) }
        }
        do {
            guard let journal = try RecoveryJournal.load() else { recoveryProblem = nil; return }
            guard Permissions.splitProblem == nil else {
                recoveryProblem = L("上次分屏未正常结束。请完成授权，再点“重试恢复窗口…”。")
                return
            }
            let physical = DisplayScanner.physicalScreens()
            var layout: [CGDirectDisplayID: CGRect] = [:]
            for record in journal.displays {
                guard let screen = physical.first(where: { RecoveryJournal.uuid($0.id) == record.uuid }),
                      screen.bounds.size == record.bounds.size else { continue }
                layout[screen.id] = record.bounds
            }
            // Restore topology only when all original displays are present and unchanged.
            if layout.count == journal.displays.count, layout.count == physical.count {
                try await Session.setOrigins(layout)
                try await Task.sleep(for: .milliseconds(500))
                guard layout.allSatisfy({ CGDisplayBounds($0.key) == $0.value }) else {
                    throw DemoError(L("系统尚未恢复原显示器排列，请重试。"))
                }
            }
            guard await WindowPlacement.recoverWindows(journal.windows) else {
                recoveryProblem = L("上次分屏的部分窗口尚未恢复，请点“重试恢复窗口…”。")
                return
            }
            try RecoveryJournal.clear()
            recoveryProblem = nil
            DemoLog.shared.line(L("已恢复上次异常退出的显示器排列和可用的组合窗口。"))
        } catch {
            recoveryProblem = L("恢复上次分屏失败：%@", String(describing: error.localizedDescription))
        }
    }

    func saveBeforeIncompleteExit() {
        do { try checkpointRecovery() }
        catch { DemoLog.shared.line(L("无法更新退出恢复记录，将保留此前记录：%@", String(describing: error.localizedDescription))) }
    }

    fileprivate func checkpointRecovery() throws {
        if sessions.isEmpty { try RecoveryJournal.clear(); return }
        let displays = originalScreens.values.compactMap { screen -> RecoveryJournal.Display? in
            guard let uuid = RecoveryJournal.uuid(screen.id) else { return nil }
            return RecoveryJournal.Display(uuid: uuid, bounds: screen.bounds)
        }
        let windows = sessions.values.flatMap { session in
            session.recoveryWindows { saved in
                for owner in self.sessions.values {
                    if let half = owner.halves.first(where: { $0.virtualID == saved.id }),
                       let original = self.originalScreens[owner.targetID] {
                        return (original, CGPoint(x: original.bounds.minX + half.localRect.minX,
                                                  y: original.bounds.minY + half.localRect.minY))
                    }
                }
                let physical = self.originalScreens[saved.id] ?? saved
                return (physical, physical.bounds.origin)
            }
        }
        try RecoveryJournal(displays: displays, windows: windows).save()
    }

    func screens() -> [PhysicalScreen] {
        let current = DisplayScanner.physicalScreens()
        return current.map { screen in
            var result = screen
            if let logical = logicalBounds(for: screen.id) { result.bounds = logical }
            if let session = sessions[screen.id], session.hasHalves { result.configuration = session.configuration }
            return result
        }
    }

    func logicalBounds(for id: CGDirectDisplayID) -> CGRect? {
        guard let screen = originalScreens[id] else { return nil }
        guard let anchor = originalScreens[CGMainDisplayID()] else { return screen.bounds }
        return screen.bounds.offsetBy(dx: -anchor.bounds.minX, dy: -anchor.bounds.minY)
    }

    func hostScreen(at point: CGPoint?) -> NSScreen? {
        let parked = parkedIDs.union(standby.values.flatMap { $0.map(\.virtualID) })
        let usable = NSScreen.screens.filter { screen in screen.displayID.map { !parked.contains($0) } ?? false }
        return usable.first { screen in point.map { cocoaRect(screen.frame).contains($0) } ?? false }
            ?? usable.first { $0.displayID == CGMainDisplayID() }
            ?? usable.max { $0.visibleFrame.width * $0.visibleFrame.height < $1.visibleFrame.width * $1.visibleFrame.height }
    }

    func splitDisplay(at point: CGPoint) -> CGDirectDisplayID? {
        active.first { session in
            session.halves.contains { $0.virtualBounds.contains(point) }
                || (captureRouting.allows(session.targetID, at: point) && routedLayout[session.targetID]?.contains(point) == true)
        }?.targetID
    }

    func split(_ id: CGDirectDisplayID, pair: WindowPlacement.Pair? = nil, configuration: DisplayConfiguration? = nil) {
        guard !busy, recoveryProblem == nil, !sessions.values.contains(where: \.needsRecovery) else { return }
        if let problem = EnvironmentCheck.inspect().problem {
            DemoLog.shared.line(problem)
            return
        }
        if let existing = sessions[id] {
            guard let pair, existing.canStartQuick else { return }
            transition = existing
            existing.startQuick(pair, displays: windowDisplays(), reserved: active.flatMap(\.managedWindows))
            return
        }
        let physical = DisplayScanner.physicalScreens()
        if sessions.isEmpty {
            originalScreens = Dictionary(uniqueKeysWithValues: physical.map { ($0.id, $0) })
        } else {
            for screen in physical where originalScreens[screen.id] == nil { originalScreens[screen.id] = screen }
        }
        guard var screen = physical.first(where: { $0.id == id }) else { return }
        if let configuration { screen.configuration = configuration }
        let reserved = sessions.values.flatMap(\.managedWindows)
        let session = Session(screen: screen, pair: pair, coordinator: self)
        sessions[id] = session
        transition = session
        session.split(displays: windowDisplays(), reserved: reserved)
    }

    private func windowDisplays() -> [PhysicalScreen] {
        DisplayScanner.physicalScreens().flatMap { screen -> [PhysicalScreen] in
            guard let session = sessions[screen.id], session.hasHalves else { return [screen] }
            return session.halves.map { half in
                PhysicalScreen(id: half.virtualID, name: half.name, bounds: half.virtualBounds,
                               scale: screen.scale, refreshRate: screen.refreshRate, isBuiltin: false)
            }
        }
    }

    func endQuick(_ id: CGDirectDisplayID) {
        guard !busy, let session = sessions[id], session.active, session.hasQuick else { return }
        transition = session
        session.endQuick()
    }

    func join(_ id: CGDirectDisplayID) {
        guard !busy, let session = sessions[id], session.active || session.needsRecovery else { return }
        transition = session
        session.join()
    }

    func cancelPreparation() { transition?.cancelPreparation() }

    fileprivate func beginDisplayChange() {
        changingDisplays = true
        captureOverlayRevision &+= 1
    }

    fileprivate func endDisplayChange() {
        changingDisplays = false
    }

    func checkActive() {
        guard !busy, monitoringAllowed, let first = active.first(where: { !$0.needsRecovery }) else { return }
        if let id = failedSessions.keys.first, let error = failedSessions.removeValue(forKey: id), let session = sessions[id] {
            fail(session, error: error)
            return
        }
        if let problem = Permissions.splitProblem {
            fail(first, error: DemoError(problem))
            return
        }
        guard router?.isEnabled == true else {
            fail(first, error: DemoError(L("鼠标事件监听已停止。")))
            return
        }
        let current = Dictionary(uniqueKeysWithValues: DisplayScanner.activeDisplayIDs().map { ($0, CGDisplayBounds($0)) })
        // Screen capture can keep delivering valid frames while an active virtual display reports no mode.
        for session in active where !session.needsRecovery {
            guard let problem = session.layoutProblem(in: current) else {
                layoutChangedAt[session.targetID] = nil
                continue
            }
            let now = ContinuousClock.now
            let changed = layoutChangedAt[session.targetID] ?? now
            layoutChangedAt[session.targetID] = changed
            if now - changed >= .milliseconds(800) {
                fail(session, error: DemoError(problem))
                return
            }
        }
        guard layoutChangedAt.isEmpty else { return }
        for session in active {
            session.checkQuickExit()
        }
        if current != routedLayout {
            do { try updateRoutes() }
            catch { DemoLog.shared.line(L("正在等待显示器排列稳定。%@", String(describing: error.localizedDescription))) }
        }
    }

    fileprivate func fail(_ session: Session, error: Error) {
        guard sessions[session.targetID] === session, session.canJoin else { return }
        if !monitoringAllowed || (transition != nil && transition !== session) {
            failedSessions[session.targetID] = error
            return
        }
        transition = session
        session.fail(error)
    }

    fileprivate func recoverCapture(_ half: HalfScreen, in session: Session, error: Error) {
        guard session.active else {
            fail(session, error: error)
            return
        }
        guard captureRecovery[half.virtualID] == nil else { return }
        let interruptedAt = ContinuousClock.now
        captureRecovery[half.virtualID] = Task { [weak self, weak session, weak half] in
            guard let self, let session, let half else { return }
            defer { self.captureRecovery[half.virtualID] = nil }
            var lastError = error
            for _ in 0..<2 {
                do {
                    while self.changingDisplays || !self.monitoringAllowed { try await Task.sleep(for: .milliseconds(100)) }
                    guard session.active, self.sessions[session.targetID] === session else { return }
                    try await half.recoverCapture()
                    DemoLog.shared.line(L("%@ 已恢复画面采集（%@）。", String(describing: half.name), String(describing: interruptedAt.duration(to: .now).formatted(.units(allowed: [.seconds, .milliseconds], width: .abbreviated)))))
                    return
                } catch {
                    if Task.isCancelled { return }
                    lastError = error
                }
            }
            self.fail(session, error: DemoError(L("%@ 未能恢复画面采集。%@", String(describing: half.name), String(describing: lastError.localizedDescription))))
        }
    }

    fileprivate func changed(_ session: Session) {
        if session.active {
            let owned = session.managedWindows
            for other in active where other !== session { other.releaseWindows(owned) }
        }
        if session.idle && !session.needsRecovery { sessions[session.targetID] = nil }
        if session.idle || session.active { transition = nil }
        layoutChangedAt.removeAll()
        if sessions.isEmpty {
            stopRouting()
            routedLayout.removeAll()
            routedParking.removeAll()
            originalScreens.removeAll()
        }
        do { try checkpointRecovery() }
        catch { DemoLog.shared.line(L("无法更新恢复记录：%@", String(describing: error.localizedDescription))) }
        onChange?(session)
        if !busy, monitoringAllowed, let id = failedSessions.keys.first, let error = failedSessions.removeValue(forKey: id),
           let affected = sessions[id] { fail(affected, error: error) }
    }

    fileprivate func stopRecovering(_ halves: [HalfScreen]) -> [Task<Void, Never>] {
        let tasks = halves.compactMap { captureRecovery[$0.virtualID] }
        for task in tasks { task.cancel() }
        return tasks
    }

    fileprivate func takeStandby(for id: CGDirectDisplayID) -> [HalfScreen] {
        standby.removeValue(forKey: id) ?? []
    }

    fileprivate func park(_ halves: [HalfScreen], for id: CGDirectDisplayID) {
        for half in halves { half.park() }
        standby[id] = halves
    }

    fileprivate func drainStandby() -> [HalfScreen] {
        let retired = standby.values.flatMap { $0 }
        standby.removeAll()
        return retired
    }

    fileprivate func layout() -> [CGDirectDisplayID: CGRect] {
        let physical = Dictionary(uniqueKeysWithValues: DisplayScanner.physicalScreens().map { ($0.id, logicalBounds(for: $0.id) ?? $0.bounds) })
        let halves = Dictionary(uniqueKeysWithValues: sessions.values.filter { $0.isParkingPhysical && $0.hasHalves }.map { session in
            (session.targetID, Dictionary(uniqueKeysWithValues: session.halves.map { ($0.virtualID, $0.localRect) }))
        })
        var layout = DisplayScanner.splitDisplayFrames(physical: physical, main: CGMainDisplayID(), halves: halves)
        let rightmost = layout.values.max {
            if $0.maxX != $1.maxX { return $0.maxX < $1.maxX }
            return $0.minY < $1.minY
        }
        var occupied = Array(layout.values)
        for (id, halves) in standby.sorted(by: { $0.key < $1.key }) {
            var anchor = layout[id] ?? rightmost ?? .zero
            for half in halves {
                anchor = DisplayScanner.parkingFrame(size: half.pointSize, beside: anchor, avoiding: occupied)
                layout[half.virtualID] = anchor
                occupied.append(anchor)
            }
        }
        return layout
    }

    fileprivate func windowDestination(for id: CGDirectDisplayID?, joining: Session?, beforeJoin: Bool = false) -> NSScreen? {
        let screens = NSScreen.screens
        if let id {
            if let split = sessions[id], split !== joining, split.hasHalves,
               let upper = split.halves.first.flatMap({ half in screens.first { $0.displayID == half.virtualID } }) {
                return upper
            }
            if (beforeJoin && id == joining?.targetID) || !parkedIDs.contains(id),
               let physical = screens.first(where: { $0.displayID == id }) { return physical }
        }
        if let survivor = active.filter({ $0 !== joining }).min(by: { $0.targetID < $1.targetID }),
           let upper = survivor.halves.first, let screen = screens.first(where: { $0.displayID == upper.virtualID }) {
            return screen
        }
        return screens.first { $0.displayID == CGMainDisplayID() && $0.displayID.map { !parkedIDs.contains($0) } == true }
            ?? screens.first { $0.displayID.map { !parkedIDs.contains($0) && !DemoDisplay.createdIDs.contains($0) } == true }
    }

    fileprivate func remainingWindowDestination(from screen: PhysicalScreen, joining: Session) -> NSScreen? {
        if let target = NSScreen.screens.first(where: { $0.displayID == joining.targetID }) { return target }
        let available = screens().filter { $0.id != joining.targetID && !parkedIDs.contains($0.id) }
        let nearest = available.min { lhs, rhs in
            func distance(_ target: PhysicalScreen) -> CGFloat {
                hypot(target.bounds.midX - screen.bounds.midX, target.bounds.midY - screen.bounds.midY)
            }
            return distance(lhs) < distance(rhs)
        }
        return windowDestination(for: nearest?.id, joining: joining)
    }

    fileprivate func updateRoutes() throws {
        let layout = Dictionary(uniqueKeysWithValues: DisplayScanner.activeDisplayIDs().compactMap { id -> (CGDirectDisplayID, CGRect)? in
            let bounds = CGDisplayBounds(id)
            return bounds.isEmpty ? nil : (id, bounds)
        })
        let split = sessions.values.filter { session in
            session.isParkingPhysical && session.hasHalves && layout[session.targetID] != nil
                && session.halves.allSatisfy { layout[$0.virtualID] != nil }
        }
        guard !split.isEmpty else {
            if !busy { stopRouting() }
            routedLayout.removeAll()
            routedParking.removeAll()
            return
        }
        let hidden = standby.values.flatMap { $0 }.sorted { $0.virtualID < $1.virtualID }.compactMap { half -> MouseRouter.Parking? in
            guard let physical = layout[half.virtualID], let desktop = layout[half.physicalID] else { return nil }
            return MouseRouter.Parking(physical: physical, desktop: desktop)
        }
        let parked = Set(split.map(\.targetID)).union(standby.values.flatMap { $0.map(\.virtualID) })
        // Keep routing current during the display handoff, but only adopt the
        // finished geometry as the baseline for detecting unexpected changes.
        if !changingDisplays {
            for session in split { try session.updateLayout(layout) }
        }
        let parking = split.sorted { $0.targetID < $1.targetID }.compactMap { session -> MouseRouter.Parking? in
            guard session.isParkingPhysical, let physical = layout[session.targetID],
                  let first = session.halves.first, let upper = layout[first.virtualID] else { return nil }
            let desktop = CGRect(origin: upper.origin, size: physical.size)
            let mirrors = session.halves.compactMap { half in
                half.mirrorWindowID.map { MouseRouter.NativeWindow(id: $0, frame: half.physicalRect) }
            }
            return MouseRouter.Parking(physical: physical, desktop: desktop, displayID: session.targetID, mirrors: mirrors)
        } + hidden
        guard layout != routedLayout || parking != routedParking || router?.isEnabled != true else { return }
        captureOverlayRevision &+= 1
        let input = router ?? MouseRouter()
        input.update(parked: parking, screens: layout.filter { !parked.contains($0.key) }.map(\.value))
        if router == nil {
            guard input.start() else { throw DemoError(L("鼠标事件监听启动失败。请检查辅助功能权限并重新启动。")) }
            router = input
            let interval: TimeInterval = WindowServerHitTest.supportsLiveRouting ? 0.5 : 0.12
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateCaptureOverlays() }
            }
            captureOverlayTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        routedLayout = layout
        routedParking = parking
    }

    private func updateCaptureOverlays() {
        guard router != nil, !changingDisplays else { return }
        let targets = monitoringAllowed ? captureTargets() : []
        guard !targets.isEmpty else {
            setCaptureRouting(.init())
            router?.configureScreenshots(enabled: false)
            return
        }
        guard !captureOverlayQueryInFlight else { return }
        captureOverlayQueryInFlight = true
        let revision = captureOverlayRevision
        let rescueDue = !busy && layoutChangedAt.isEmpty && active.contains(where: \.hiddenWindowCheckDue)
        // Rescue needs windows behind the mirrors as well.
        let anchor = rescueDue ? nil : captureOverlayAnchor
        let readShortcuts = ContinuousClock.now >= nextScreenshotShortcutRead
        if readShortcuts { nextScreenshotShortcutRead = .now + .seconds(1) }
        captureOverlayQueue.async { [weak self, popupValidation] in
            let mirrors = Set(targets.flatMap(\.mirrorWindows))
            let snapshot = CaptureOverlays.visibleSnapshot(mirrors: mirrors, above: anchor)
            let visible = snapshot?.windows
            let inspection = visible.map {
                CaptureOverlays.inspect(visible: $0, on: targets, popupValidation: popupValidation,
                                        canInteract: WindowPlacement.isInteractivePopup)
            }
            let nextAnchor = snapshot?.backmostMirror
            let rescueWindows = rescueDue ? visible.map(WindowPlacement.rescuableWindows(in:)) : nil
            let shortcuts = readShortcuts ? PhysicalScreenScreenshot.Shortcuts.current() : nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.captureOverlayQueryInFlight = false
                guard self.captureOverlayRevision == revision,
                      self.monitoringAllowed, !self.changingDisplays, self.captureTargets() == targets else { return }
                self.captureOverlayAnchor = nextAnchor
                self.router?.configureScreenshots(enabled: true, shortcuts: shortcuts)
                guard let inspection else { return }
                self.setCaptureRouting(inspection.routing)
                self.updateMirrorShields(inspection.shieldsByDisplay)
                if let rescueWindows, !self.busy, self.layoutChangedAt.isEmpty {
                    for session in self.active { session.checkHiddenWindows(rescueWindows) }
                }
            }
        }
    }

    private func captureTargets() -> [CaptureOverlays.Target] {
        active.compactMap { session -> CaptureOverlays.Target? in
            guard session.isParkingPhysical, let panel = routedLayout[session.targetID] else { return nil }
            let halves = session.halves.compactMap { half in
                routedLayout[half.virtualID].map { CaptureOverlays.Half(id: half.virtualID, frame: $0) }
            }
            guard halves.count == 2 else { return nil }
            return CaptureOverlays.Target(id: session.targetID, physical: panel, halves: halves,
                                          mirrorWindows: Set(session.halves.compactMap(\.mirrorWindowID)))
        }.sorted { $0.id < $1.id }
    }

    private func updateMirrorShields(_ shields: [CGDirectDisplayID: Set<CGWindowID>]) {
        mirrorShields = shields
        guard !updatingMirrorShields else { return }
        let changes = active.flatMap(\.halves).compactMap { half -> (half: HalfScreen, ids: Set<CGWindowID>)? in
            let ids = shields[half.virtualID, default: []]
            return half.needsShieldUpdate(ids) ? (half, ids) : nil
        }
        guard !changes.isEmpty else { return }

        updatingMirrorShields = true
        let revision = captureOverlayRevision
        let requestedIDs = Set(changes.flatMap(\.ids))
        Task { [weak self] in
            defer { self?.updatingMirrorShields = false }
            var availableShields: [SCWindow] = []
            if !requestedIDs.isEmpty {
                guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
                availableShields = content.windows.filter { requestedIDs.contains($0.windowID) }
            }
            guard let self, self.captureOverlayRevision == revision,
                  self.monitoringAllowed, !self.changingDisplays else { return }

            await withTaskGroup(of: Void.self) { group in
                for (half, ids) in changes {
                    let windows = availableShields.filter { ids.contains($0.windowID) }
                    guard windows.count == ids.count, self.mirrorShields[half.virtualID, default: []] == ids else { continue }
                    group.addTask { await half.updateShieldExclusions(windows) }
                }
            }
        }
    }

    private func setCaptureRouting(_ routing: MouseRouter.CaptureRouting) {
        guard routing != captureRouting else { return }
        captureRouting = routing
        router?.setCaptureRouting(routing)
    }

    private func stopRouting() {
        captureOverlayTimer?.invalidate()
        captureOverlayTimer = nil
        captureOverlayRevision &+= 1
        captureOverlayAnchor = nil
        captureRouting = .init()
        nextScreenshotShortcutRead = .now
        mirrorShields.removeAll()
        router?.stop()
        router = nil
    }
}

@MainActor
final class Session {
    private enum Phase { case idle, preparing, split, joining }

    private(set) var status = L("未拆分")
    private let screen: PhysicalScreen
    enum Mode { case desktop, quick }
    let mode: Mode
    private var pair: WindowPlacement.Pair?
    private var quickPlacement: WindowPlacement?
    private var exitPolicy = QuickExitPolicy()
    private var exitCheck: Task<Void, Never>?
    private var rescueTask: Task<Void, Never>?
    private var lastRescue = ContinuousClock.now
    var hasQuick: Bool { pair != nil }
    var canStartQuick: Bool { active && mode == .desktop && !hasQuick && !needsRecovery }
    private unowned let coordinator: SplitSessions
    var targetID: CGDirectDisplayID { screen.id }
    var name: String { screen.displayName }
    var configuration: DisplayConfiguration { screen.configuration }
    var captureStatistics: [String] { halves.map(\.statistics) }
    private(set) var failed = false
    private(set) var needsRecovery = false
    var idle: Bool { phase == .idle }
    var active: Bool { phase == .split }
    var preparing: Bool { phase == .preparing }
    var joining: Bool { phase == .joining }
    var canJoin: Bool { preparing || active || needsRecovery }
    var hasHalves: Bool { !halves.isEmpty }
    fileprivate var isParkingPhysical = true
    var selectedChoices: [WindowPlacement.Choice] { pair.map { [$0.upper, $0.lower] } ?? [] }
    var managedWindows: [WindowPlacement.Identity] { (placement?.identities ?? []) + (quickPlacement?.identities ?? []) }
    fileprivate func recoveryWindows(mapDisplay: (PhysicalScreen) -> (screen: PhysicalScreen, origin: CGPoint)) -> [RecoveryJournal.Window] {
        (quickPlacement ?? placement)?.recoveryWindows(mapDisplay: mapDisplay) ?? []
    }
    fileprivate func releaseWindows(_ identities: [WindowPlacement.Identity]) { placement?.release(identities) }
    func layoutProblem(in layout: [CGDirectDisplayID: CGRect]) -> String? {
        guard let physical = layout[targetID], physical.size == expectedLayout[targetID]?.size else {
            return L("物理显示器已断开或分辨率发生变化。")
        }
        for half in halves {
            guard let bounds = layout[half.virtualID], bounds == expectedLayout[half.virtualID] else {
                return L("%@ 的桌面位置或点尺寸发生变化。", String(describing: half.name))
            }
            if half.hasUnexpectedMode { return L("%@ 的像素尺寸发生变化。", String(describing: half.name)) }
        }
        return nil
    }

    private var operationStarted: TimeInterval?
    private var operationName = ""
    private var operationIsRecovery = false
    private var cancelledByUser = false
    private var phase = Phase.idle
    fileprivate private(set) var halves: [HalfScreen] = []
    private var placement: WindowPlacement?
    private var expectedLayout: [CGDirectDisplayID: CGRect] = [:]
    private var setup: Task<Void, Never>?
    private var windowPreparation: Task<Void, Error>?
    private var fullScreenTask: Task<Void, Error>?
    private var deadline: Task<Void, Never>?
    private var touchedLayout = false

    init(screen: PhysicalScreen, pair: WindowPlacement.Pair?, coordinator: SplitSessions) {
        self.screen = screen
        self.pair = pair
        self.mode = pair == nil ? .desktop : .quick
        self.coordinator = coordinator
    }

    fileprivate func split(displays: [PhysicalScreen], reserved: [WindowPlacement.Identity]) {
        guard phase == .idle else { return }
        failed = false
        cancelledByUser = false
        if let problem = Permissions.splitProblem {
            DemoLog.shared.line(problem)
            publish(problem, phase: .idle)
            return
        }

        guard CGDisplayIsInMirrorSet(targetID) == 0 else {
            publish(L("请先把目标显示器设为扩展显示器。"), phase: .idle)
            return
        }

        do {
            placement = try WindowPlacement(source: screen, displays: displays, pair: pair, reserved: reserved)
            placement?.onCheckpoint = { [weak self] in try self?.coordinator.checkpointRecovery() }
        } catch {
            publish(error.localizedDescription, phase: .idle)
            return
        }
        publish(L("正在准备分屏…"), phase: .preparing)

        deadline = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(45))
                if let self { self.coordinator.fail(self, error: DemoError(L("准备分屏超时。"))) }
            } catch {}
        }
        setup = Task {
            do {
                try Task.checkCancellation()
                if let placement {
                    let task = Task { try await placement.prepareSelection() }
                    windowPreparation = task
                    try await task.value
                    try Task.checkCancellation()
                    windowPreparation = nil
                }
                try coordinator.checkpointRecovery()
                var ordinary: [(Session, Set<CGWindowID>)] = []
                for other in coordinator.active {
                    if let placement = other.placement, let upper = other.halves.first {
                        ordinary.append((other, await placement.ordinaryWindows(on: upper)))
                    }
                }
                publish(L("正在创建%@两个虚拟显示器…", String(describing: screen.splitLayout.direction)), phase: .preparing)
                DemoLog.shared.line(L("拆分 %@，已记录 %@ 个可迁移窗口的位置和尺寸。", String(describing: screen.menuTitle), String(describing: placement?.count ?? 0)))
                try await prepare()
                try Task.checkCancellation()
                let owned = managedWindows
                let protected = owned + coordinator.active.flatMap(\.managedWindows)
                for (other, windows) in ordinary {
                    other.releaseWindows(owned)
                    if !windows.isEmpty { await other.placeOrdinaryWindows(protecting: protected, only: windows) }
                    try Task.checkCancellation()
                }
                deadline?.cancel()
                deadline = nil
                setup = nil
                if pair != nil { exitPolicy.arm() }
                let status = pair == nil ? L("已拆分，%@半屏可各自全屏", String(describing: screen.splitLayout.direction)) : L("已拆分，%@半屏已分别全屏", String(describing: screen.splitLayout.direction))
                publish(status, phase: .split)
                showRegionNumbers()
                DemoLog.shared.line(L("%@ 的两个半屏已就绪。", String(describing: name)))
            } catch {
                if !Task.isCancelled { coordinator.fail(self, error: error) }
            }
        }
    }

    private func showRegionNumbers() {
        let number = coordinator.screens().sorted { $0.id < $1.id }.firstIndex { $0.id == targetID }.map { $0 + 1 } ?? 1
        for (index, half) in halves.enumerated() { half.showNumber("\(number).\(index + 1)") }
    }

    fileprivate var hiddenWindowCheckDue: Bool {
        active && !needsRecovery && placement != nil && rescueTask == nil && ContinuousClock.now - lastRescue >= .seconds(1)
    }

    fileprivate func checkHiddenWindows(_ windows: [WindowPlacement.WindowInfo]) {
        guard hiddenWindowCheckDue, let placement else { return }
        lastRescue = .now
        let protected = coordinator.active.flatMap(\.managedWindows)
        rescueTask = Task { [weak self] in
            guard let self else { return }
            defer { self.rescueTask = nil }
            await placement.rescueHiddenWindows(windows, to: self.halves, protecting: protected) {
                self.active && !self.needsRecovery && !self.coordinator.busy && self.coordinator.monitoringAllowed &&
                    self.layoutProblem(in: Dictionary(uniqueKeysWithValues: DisplayScanner.activeDisplayIDs().map { ($0, CGDisplayBounds($0)) })) == nil
            }
        }
    }

    fileprivate func resetQuickMonitoring() {
        rescueTask?.cancel()
        exitCheck?.cancel()
        // Keep the task reference until the pending AX request finishes; never overlap probes.
        if hasQuick && active && !needsRecovery { exitPolicy.arm() }
    }

    fileprivate func checkQuickExit() {
        guard active, hasQuick, !needsRecovery, exitCheck == nil,
              let selected = quickPlacement ?? placement else { return }
        exitCheck = Task { [weak self] in
            let sample = await selected.selectedFullScreenState()
            guard let self else { return }
            defer { self.exitCheck = nil }
            guard !Task.isCancelled, self.active, !self.coordinator.busy, self.coordinator.monitoringAllowed else { return }
            if self.exitPolicy.observe(sample, at: ProcessInfo.processInfo.systemUptime) {
                self.coordinator.endQuick(self.targetID)
            }
        }
    }

    fileprivate func startQuick(_ pair: WindowPlacement.Pair, displays: [PhysicalScreen], reserved: [WindowPlacement.Identity]) {
        guard canStartQuick else { return }
        failed = false
        cancelledByUser = false
        do {
            quickPlacement = try WindowPlacement(source: screen, displays: displays, pair: pair,
                                                 reserved: reserved, selectedOnly: true)
            quickPlacement?.onCheckpoint = { [weak self] in try self?.coordinator.checkpointRecovery() }
        } catch {
            failed = true
            publish(error.localizedDescription, phase: .split)
            return
        }
        self.pair = pair
        publish(L("正在准备快捷%@分屏…", String(describing: screen.splitLayout.direction)), phase: .preparing)
        deadline = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(20))
                guard let self, self.preparing else { return }
                self.failed = true
                self.finish(status: L("快捷分屏超时，已还原窗口"), quickOnly: true)
            } catch {}
        }
        setup = Task {
            do {
                guard let quickPlacement else { return }
                try await quickPlacement.prepareSelection()
                try coordinator.checkpointRecovery()
                try Task.checkCancellation()
                _ = try await quickPlacement.migrate(to: halves)
                try await quickPlacement.enterSelectedFullScreen(on: halves)
                try Task.checkCancellation()
                deadline?.cancel()
                deadline = nil
                setup = nil
                exitPolicy.arm()
                publish(L("快捷%@分屏中 · 退出任一全屏即还原", String(describing: screen.splitLayout.direction)), phase: .split)
                showRegionNumbers()
            } catch {
                if !Task.isCancelled {
                    failed = true
                    finish(status: L("快捷分屏失败，已还原窗口。%@", String(describing: error.localizedDescription)), quickOnly: true)
                }
            }
        }
    }

    fileprivate func endQuick() {
        if mode == .desktop { finish(status: L("已结束快捷分屏，保留桌面拆分"), quickOnly: true) }
        else { finish(status: L("已结束快捷分屏并还原"), joining: true) }
    }

    fileprivate func join() {
        finish(status: L("已合并"), joining: true)
    }

    private func placeOrdinaryWindows(protecting: [WindowPlacement.Identity], only: Set<CGWindowID>? = nil) async {
        if let placement, let upper = halves.first { _ = await placement.placeOrdinary(on: upper, protecting: protecting, only: only) }
    }

    fileprivate func cancelPreparation() {
        if preparing {
            cancelledByUser = true
            finish(status: L("已取消分屏"), quickOnly: mode == .desktop && quickPlacement != nil)
        }
    }

    private func prepare() async throws {
        coordinator.beginDisplayChange()
        defer { coordinator.endDisplayChange() }
        halves = coordinator.takeStandby(for: targetID)
        touchedLayout = !halves.isEmpty
        let splitLayout = screen.splitLayout
        if !halves.isEmpty && (halves.map(\.localRect) != splitLayout.regions || !halves.allSatisfy { $0.matchesConfiguration(screen) }) {
            for half in halves { half.teardown() }
            halves.removeAll()
        }
        if halves.isEmpty {
            for index in 0..<2 {
                try Task.checkCancellation()
                touchedLayout = true
                halves.append(try HalfScreen.make(name: "\(screen.displayName) · \(splitLayout.names[index])",
                                                  screen: screen, localRect: splitLayout.regions[index], role: splitLayout.roles[index]))
            }
        }
        for half in halves {
            half.onFailure = { [weak self, weak half] error in
                guard let self, let half else { return }
                self.coordinator.recoverCapture(half, in: self,
                    error: DemoError(L("%@ 的画面采集已停止。%@", String(describing: half.name), String(describing: error.localizedDescription))))
            }
        }
        let activeHalves = halves
        let displayIDs = activeHalves.map(\.virtualID)
        async let captureDisplays = HalfScreen.waitForDisplays(ids: displayIDs)

        try await Self.wait(steps: 45, error: L("虚拟显示器没有就绪。")) {
            let appKitIDs = NSScreen.screens.compactMap(\.displayID)
            return halves.allSatisfy { appKitIDs.contains($0.virtualID) }
        }
        // Keep the visible desktop coordinates so pointer motion, clicks, drags and
        // focus across both halves follow the WindowServer's normal display layout.
        let layout = coordinator.layout()
        try await configureSplitLayout(layout)
        coordinator.endDisplayChange()
        try coordinator.updateRoutes()

        publish(L("正在等待%@半屏的画面…", String(describing: screen.splitLayout.direction)), phase: .preparing)
        let displays = try await captureDisplays
        let placement = self.placement
        async let capturing: Void = Self.startCaptures(activeHalves, displays: displays)
        if let placement {
            let moved = try await placement.migrate(to: activeHalves)
            DemoLog.shared.line(L("已迁移 %@/%@ 个窗口。", String(describing: moved), String(describing: placement.count)))
            if pair != nil {
                try Task.checkCancellation()
                publish(L("正在让%@半屏的窗口进入全屏…", String(describing: screen.splitLayout.direction)), phase: .preparing)
                fullScreenTask = Task { try await placement.enterSelectedFullScreen(on: activeHalves) }
            }
        }
        try await capturing
        try await Self.wait(steps: 50, error: L("有半屏未收到符合分辨率的画面。")) {
            halves.allSatisfy(\.hasFrame)
        }

        if let task = fullScreenTask {
            try await task.value
            try Task.checkCancellation()
            fullScreenTask = nil
        }
        await placeOrdinaryWindows(protecting: coordinator.active.flatMap(\.managedWindows))
        try await Self.wait(steps: 9, error: L("全屏切换后显示器排列发生变化。")) {
            Self.layoutMatches(layout, ignoringParked: coordinator.parkedIDs) && halves.allSatisfy(\.hasExpectedMode)
        }
        try coordinator.updateRoutes()
        for half in halves { try half.placeWindow() }
        try coordinator.updateRoutes()
    }

    private static func startCaptures(_ halves: [HalfScreen], displays: [SCDisplay]) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (half, display) in zip(halves, displays) {
                group.addTask { try await half.startCapture(on: display) }
            }
            for try await _ in group {}
        }
    }

    private func configureSplitLayout(_ layout: [CGDirectDisplayID: CGRect]) async throws {
        let modeProblem = L("显示模式切换后，半屏位置不正确。")
        do {
            let modes = try Dictionary(uniqueKeysWithValues: halves.filter { !$0.hasExpectedMode }.map {
                ($0.virtualID, try $0.preferredMode())
            })
            try await Self.setOrigins(layout, modes: modes)
            try await Self.wait(steps: 5, error: modeProblem) {
                Self.layoutMatches(layout, ignoringParked: coordinator.parkedIDs) && halves.allSatisfy(\.hasExpectedMode)
            }
        } catch {
            try Task.checkCancellation()
            DemoLog.shared.line(L("系统未能同时设置显示模式和位置，正在分步设置。%@", String(describing: error.localizedDescription)))
            for half in halves where half.virtualBounds.size != half.pointSize { try half.selectMode() }
            try await Self.setOrigins(layout)
            try await Self.wait(steps: 30, error: L("macOS 未能按原来的显示器位置排列两个半屏。")) {
                Self.layoutMatches(layout, ignoringParked: coordinator.parkedIDs)
            }
            for half in halves { try half.selectMode() }
            try await Self.wait(steps: 30, error: modeProblem) {
                Self.layoutMatches(layout, ignoringParked: coordinator.parkedIDs) && halves.allSatisfy(\.hasExpectedMode)
            }
        }
    }

    fileprivate func updateLayout(_ layout: [CGDirectDisplayID: CGRect]) throws {
        let ids = [targetID] + halves.map(\.virtualID)
        expectedLayout = layout.filter { ids.contains($0.key) }
        for half in halves { try half.updateWindowPosition() }
    }

    fileprivate func fail(_ error: Error) {
        guard canJoin else { return }
        failed = true
        DemoLog.shared.line(L("%@ 分屏中止。%@", String(describing: name), String(describing: error.localizedDescription)))
        finish(status: L("已恢复。%@", String(describing: error.localizedDescription)), joining: active)
    }

    private func finish(status: String, joining: Bool = false, quickOnly: Bool = false) {
        guard canJoin else { return }
        needsRecovery = false
        let rescuing = rescueTask
        rescuing?.cancel()
        exitCheck?.cancel()
        exitCheck = nil
        exitPolicy = QuickExitPolicy()
        let preparingWindows = windowPreparation
        preparingWindows?.cancel()
        windowPreparation = nil
        let transition = fullScreenTask
        transition?.cancel()
        fullScreenTask = nil
        let preparing = setup
        preparing?.cancel()
        deadline?.cancel()
        setup = nil
        deadline = nil
        let recoveries = quickOnly ? [] : coordinator.stopRecovering(halves)
        publish(L("正在恢复显示器和窗口…"), phase: .joining)
        DemoLog.shared.line(quickOnly ? L("正在结束 %@ 的快捷组合，保留桌面拆分。", String(describing: name)) : L("正在合并 %@。", String(describing: name)))

        Task {
            if let rescuing { await rescuing.value }
            for recovery in recoveries { await recovery.value }
            if let preparingWindows { _ = await preparingWindows.result }
            if let transition { _ = await transition.result }
            if let preparing { await preparing.value }
            if let quickPlacement {
                let destination: (CGDirectDisplayID?) -> NSScreen? = { [self] id in
                    if let id, let existing = NSScreen.screens.first(where: { $0.displayID == id }) { return existing }
                    return coordinator.windowDestination(for: id, joining: nil)
                }
                guard await quickPlacement.leaveFullScreen(on: [], includeSelected: true) else {
                    needsRecovery = true
                    publish(L("窗口尚未退出全屏，已保留拆分。请重试恢复窗口。"), phase: .split)
                    return
                }
                await quickPlacement.moveToDesktops(destination: destination, ordinary: nil,
                                                    protecting: coordinator.active.filter { $0 !== self }.flatMap(\.managedWindows))
                let restored = await quickPlacement.restore(for: .milliseconds(1750), destination: destination)
                let presentation = await quickPlacement.restorePresentation(destination: destination)
                guard restored.failed == 0, presentation.failed == 0 else {
                    needsRecovery = true
                    publish(L("已保留桌面拆分，仍有 %@ 个窗口的位置或尺寸、%@ 项状态待恢复。", String(describing: restored.failed), String(describing: presentation.failed)), phase: .split)
                    return
                }
                self.quickPlacement = nil
                pair = nil
                if quickOnly {
                    publish(status, phase: .split)
                    return
                }
            }
            if let placement {
                let protected = coordinator.active.flatMap(\.managedWindows)
                if joining {
                    await placement.collectRemainingWindows(on: halves, reserved: protected)
                    if mode == .desktop { await placement.preserveDesktopChanges(on: halves) }
                }
                guard await placement.leaveFullScreen(on: halves, includeSelected: transition != nil || !halves.isEmpty) else {
                    needsRecovery = true
                    publish(L("窗口尚未退出全屏，已保留桌面。请从菜单选择“重试恢复窗口…”。"), phase: .idle)
                    return
                }
                if joining {
                    // Move the windows while their source desktops are still reachable.
                    let destination: (CGDirectDisplayID?) -> NSScreen? = { [self] in
                        coordinator.windowDestination(for: $0, joining: self, beforeJoin: true)
                    }
                    let ordinary = coordinator.remainingWindowDestination(from: screen, joining: self)
                    await placement.moveToDesktops(destination: destination, ordinary: ordinary, protecting: protected)
                    _ = await placement.restore(for: .milliseconds(650), destination: destination, ordinary: ordinary)
                }
            }
            var retiring = halves
            var finalStatus = status
            if touchedLayout {
                coordinator.beginDisplayChange()
                defer { coordinator.endDisplayChange() }
                let parked = coordinator.parkedIDs.subtracting([targetID])
                if !coordinator.active.isEmpty, halves.count == 2,
                   !CGDisplayBounds(targetID).isEmpty, halves.allSatisfy({ !$0.virtualBounds.isEmpty }) {
                    // Removing a display can pause WindowServer on every monitor.
                    // Keep only the idle virtual desktops until the last join.
                    coordinator.park(halves, for: targetID)
                    isParkingPhysical = false
                    let parkedLayout = coordinator.layout()
                    do {
                        try await Self.setOrigins(parkedLayout)
                        try await Self.wait(steps: 12, error: L("系统没有移开闲置的半屏。")) {
                            Self.layoutMatches(parkedLayout, ignoringParked: parked)
                        }
                        retiring.removeAll()
                    } catch {
                        retiring = coordinator.takeStandby(for: targetID)
                        DemoLog.shared.line(L("将直接移除闲置半屏。%@", String(describing: error.localizedDescription)))
                    }
                }
                halves.removeAll()
                if coordinator.active.isEmpty { retiring += coordinator.drainStandby() }
                let virtualIDs = Set(retiring.map(\.virtualID))
                for half in retiring.reversed() { half.teardown() }
                DemoDisplay.createdIDs.subtract(virtualIDs)
                do {
                    try await Self.wait(steps: 20, error: L("系统还没有移除虚拟显示器。")) {
                        DisplayScanner.activeDisplayIDs().allSatisfy { !virtualIDs.contains($0) }
                    }
                    let layout = coordinator.layout()
                    if !Self.layoutMatches(layout, ignoringParked: parked) { try await Self.setOrigins(layout) }
                    try await Self.wait(steps: 15, error: L("macOS 调整了部分显示器的位置。")) {
                        Self.layoutMatches(layout, ignoringParked: parked)
                    }
                    coordinator.endDisplayChange()
                    try coordinator.updateRoutes()
                    // AppKit can lag behind WindowServer after a display is removed.
                    for _ in 0..<10 {
                        let screens = NSScreen.screens
                        if Set(screens.compactMap(\.displayID)) == Set(layout.keys), screens.allSatisfy({ screen in
                            screen.displayID.map { CGDisplayBounds($0) } == cocoaRect(screen.frame)
                        }) { break }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                } catch {
                    needsRecovery = true
                    finalStatus = L("恢复显示器排列时遇到问题。%@", String(describing: error.localizedDescription))
                    DemoLog.shared.line(finalStatus)
                }
            }
            if let placement {
                let destination: (CGDirectDisplayID?) -> NSScreen? = { [self] in coordinator.windowDestination(for: $0, joining: self) }
                let ordinary = joining ? coordinator.remainingWindowDestination(from: screen, joining: self) : nil
                let protected = coordinator.active.flatMap(\.managedWindows)
                if joining { await placement.moveToDesktops(destination: destination, ordinary: ordinary, protecting: protected) }
                let result = await placement.restore(for: .milliseconds(1750), destination: destination, ordinary: ordinary)
                var restored = result.restored
                var failed = result.failed
                if !result.retry.isEmpty, coordinator.active.isEmpty {
                    let retried = await placement.recoverFrames(result.retry, destination: destination, ordinary: ordinary, protecting: protected)
                    restored += retried.restored
                    failed = failed - result.retry.count + retried.failed
                }
                let presentation = await placement.restorePresentation(destination: destination)
                DemoLog.shared.line(L("已还原 %@ 个窗口的位置和尺寸。", String(describing: restored)))
                if presentation.minimizedToStage > 0 {
                    let detail = L("台前调度将 %@ 个原先在程序坞的窗口收进了侧栏。", String(describing: presentation.minimizedToStage))
                    DemoLog.shared.line(detail)
                    finalStatus += " \(detail)"
                }
                if failed > 0 || presentation.failed > 0 {
                    needsRecovery = true
                    DemoLog.shared.line(L("有 %@ 个窗口的位置或尺寸、%@ 项窗口状态未能完全还原。", String(describing: failed), String(describing: presentation.failed)))
                    finalStatus += L(" 已恢复显示器，仍有 %@ 个窗口的位置或尺寸、%@ 项状态待恢复。", String(describing: failed), String(describing: presentation.failed))
                }
            }
            if !needsRecovery { placement = nil }
            expectedLayout.removeAll()
            publish(finalStatus, phase: .idle)
        }
    }

    private static func layoutMatches(_ layout: [CGDirectDisplayID: CGRect], ignoringParked: Set<CGDirectDisplayID>) -> Bool {
        Set(DisplayScanner.activeDisplayIDs()) == Set(layout.keys)
            && layout.allSatisfy { id, bounds in
                let actual = CGDisplayBounds(id)
                return ignoringParked.contains(id) ? actual.size == bounds.size : actual == bounds
            }
    }

    fileprivate nonisolated static func setOrigins(_ layout: [CGDirectDisplayID: CGRect], modes: [CGDirectDisplayID: CGDisplayMode] = [:]) async throws {
        try await Task.detached(priority: .userInitiated) { try applyOrigins(layout, modes: modes) }.value
    }

    private nonisolated static func applyOrigins(_ layout: [CGDirectDisplayID: CGRect], modes: [CGDirectDisplayID: CGDisplayMode]) throws {
        let origins = layout.filter { CGDisplayBounds($0.key).origin != $0.value.origin }
        guard !origins.isEmpty || !modes.isEmpty else { return }
        var configuration: CGDisplayConfigRef?
        let began = CGBeginDisplayConfiguration(&configuration)
        guard began == .success else {
            throw DemoError(L("无法开始排列显示器（CGError %@）。", String(describing: began.rawValue)))
        }
        for (id, mode) in modes {
            let result = CGConfigureDisplayWithDisplayMode(configuration, id, mode, nil)
            if result != .success {
                CGCancelDisplayConfiguration(configuration)
                throw DemoError(L("无法设置显示器 %@ 的分辨率（CGError %@）。", String(describing: id), String(describing: result.rawValue)))
            }
        }
        for (id, bounds) in origins {
            let result = CGConfigureDisplayOrigin(configuration, id, Int32(bounds.minX), Int32(bounds.minY))
            if result != .success {
                CGCancelDisplayConfiguration(configuration)
                throw DemoError(L("无法设置显示器 %@ 的位置（CGError %@）。", String(describing: id), String(describing: result.rawValue)))
            }
        }
        let result = CGCompleteDisplayConfiguration(configuration, .forSession)
        guard result == .success else {
            throw DemoError(L("无法完成显示器排列（CGError %@）。", String(describing: result.rawValue)))
        }
    }

    private static func wait(steps: Int, error: String, until ready: () -> Bool) async throws {
        for _ in 0..<steps {
            try Task.checkCancellation()
            if ready() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw DemoError(error)
    }

    private func publish(_ status: String, phase: Phase) {
        if (phase == .preparing || phase == .joining), phase != self.phase {
            if let started = operationStarted {
                PerformanceLedger.shared.record(operationName, started: started, succeeded: false, cancelled: cancelledByUser && !operationIsRecovery)
            }
            operationStarted = ProcessInfo.processInfo.systemUptime
            operationIsRecovery = phase == .joining
            operationName = phase == .preparing ? L("开始分屏") : L("恢复桌面")
        } else if phase == .split || phase == .idle, let started = operationStarted {
            PerformanceLedger.shared.record(operationName, started: started, succeeded: !needsRecovery && (operationIsRecovery || !failed))
            operationStarted = nil
        }
        self.status = status
        self.phase = phase
        coordinator.changed(self)
    }
}
