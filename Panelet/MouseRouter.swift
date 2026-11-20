import AppKit
import CoreGraphics
import Foundation
import os

/// Keep the pointer on the virtual desktops, with access to controls drawn on the physical panel.
final class MouseRouter {
    struct NativeWindow: Equatable, Sendable {
        let id: CGWindowID
        let frame: CGRect
        var level: Int32 = CGWindowLevelForKey(.mainMenuWindow) + 1
    }

    struct CaptureRouting: Equatable, Sendable {
        var displays: Set<CGDirectDisplayID> = []
        var pixPinDisplays: Set<CGDirectDisplayID> = []
        var controls: [CGDirectDisplayID: [CGRect]] = [:]
        var nativeWindows: [CGDirectDisplayID: [NativeWindow]] = [:]

        func hasSelector(on display: CGDirectDisplayID) -> Bool {
            displays.contains(display) || pixPinDisplays.contains(display)
        }

        func allows(_ display: CGDirectDisplayID?, at point: CGPoint, includeControls: Bool = true,
                    hitTest: (CGPoint) -> CGWindowID? = WindowServerHitTest.window) -> Bool {
            guard let display else { return false }
            if hasSelector(on: display) { return true }
            guard includeControls else { return false }
            if controls[display]?.contains(where: { $0.contains(point) }) == true { return true }
            let candidates = nativeWindows[display]?.filter { $0.frame.contains(point) } ?? []
            guard !candidates.isEmpty, let hit = hitTest(point) else { return false }
            return candidates.contains { $0.id == hit }
        }
    }

    struct Parking: Equatable, Sendable {
        let physical: CGRect
        let desktop: CGRect
        var displayID: CGDirectDisplayID? = nil
        var mirrors: [NativeWindow] = []

        func pointOnPhysical(_ point: CGPoint) -> CGPoint {
            CGPoint(x: physical.minX + point.x - desktop.minX, y: physical.minY + point.y - desktop.minY)
        }

        func pointOnDesktop(_ point: CGPoint) -> CGPoint {
            CGPoint(x: desktop.minX + point.x - physical.minX, y: desktop.minY + point.y - physical.minY)
        }
    }

    struct HoverRequest: Sendable {
        let revision: UInt64
        let started: UInt64
        let source: CGPoint
        let physical: CGPoint
        let desktop: CGPoint
        let mirror: NativeWindow

        func destination(hit: Bool) -> CGPoint {
            hit ? physical : desktop
        }
    }

    struct Route {
        enum ButtonChange { case down(Int64), up(Int64) }

        var parked: [Parking] = []
        var screens: [CGRect] = []
        var capture = CaptureRouting()
        var lastPoint = CGPoint.zero
        var pressedButtons: Set<Int64> = []
        var gesturePanel: CGDirectDisplayID?
        var hitTest: (CGPoint) -> CGWindowID? = WindowServerHitTest.window

        var liveHitTest: ((CGPoint, NativeWindow) -> Bool?)?
        var latestInput: CGEventTimestamp = 0
        var pixPinQueuedUntil: CGEventTimestamp?
        var suppressPixPinGesture = false
        var hoverRevision: UInt64 = 0
        var hoverPending: HoverRequest?
        var hoverScheduled = false
        var hoverNextStart: UInt64 = 0

        mutating func invalidateHover() {
            hoverRevision &+= 1
            hoverPending = nil
        }

        mutating func scheduleHover(at point: CGPoint, now: UInt64) -> UInt64? {
            guard liveHitTest != nil, pressedButtons.isEmpty,
                  let panel = parked.first(where: {
                      $0.displayID != nil && ($0.desktop.contains(point) || $0.physical.contains(point))
                  }), let id = panel.displayID, !capture.hasSelector(on: id) else { return nil }
            let isPhysical = panel.physical.contains(point)
            let physical = isPhysical ? point : panel.pointOnPhysical(point)
            guard capture.controls[id]?.contains(where: { $0.contains(physical) }) != true,
                  let mirror = panel.mirrors.first(where: { $0.frame.contains(physical) }) else { return nil }
            let desktop = isPhysical ? panel.pointOnDesktop(point) : point
            hoverPending = HoverRequest(revision: hoverRevision, started: now, source: point,
                                        physical: physical, desktop: desktop, mirror: mirror)
            guard !hoverScheduled else { return nil }
            hoverScheduled = true
            return hoverNextStart
        }

        func acceptsHover(_ request: HoverRequest) -> Bool {
            liveHitTest != nil && acceptsMove(revision: request.revision) && lastPoint == request.source
        }

        func acceptsMove(revision: UInt64) -> Bool {
            hoverRevision == revision && pressedButtons.isEmpty
        }

        mutating func recordInput(_ timestamp: CGEventTimestamp) {
            latestInput = max(latestInput, timestamp)
        }

        mutating func observeMotion(at point: CGPoint, delta: CGVector = .zero, timestamp: CGEventTimestamp, now: UInt64)
            -> (destination: CGPoint?, revision: UInt64, hoverStart: UInt64?)? {
            // The movement observer and interaction filter can dequeue events in a different order.
            guard pressedButtons.isEmpty, timestamp > latestInput, MouseRouter.isRecent(timestamp, at: now) else { return nil }
            recordInput(timestamp)
            let destination = routePoint(point, delta: delta, hovering: true, timestamp: timestamp)
            invalidateHover()
            if let destination { return (destination, hoverRevision, nil) }
            lastPoint = point
            return (nil, hoverRevision, scheduleHover(at: point, now: now))
        }

        func allows(_ panel: Parking, at point: CGPoint, includeControls: Bool = true,
                    hovering: Bool = false, retainPhysical: Bool = false) -> Bool {
            guard let display = panel.displayID else { return false }
            if capture.hasSelector(on: display) { return true }
            guard includeControls else { return false }
            if capture.controls[display]?.contains(where: { $0.contains(point) }) == true { return true }
            if let liveHitTest, let mirror = panel.mirrors.first(where: { $0.frame.contains(point) }) {
                if hovering { return retainPhysical }
                if let answer = liveHitTest(point, mirror) { return answer }
            }
            return capture.allows(display, at: point, hitTest: hitTest)
        }

        mutating func setCaptureRouting(_ routing: CaptureRouting, cursor: CGPoint, timestamp: CGEventTimestamp = 0) -> CGPoint? {
            guard routing != capture else { return nil }
            let captureModeChanged = capture.displays != routing.displays || capture.pixPinDisplays != routing.pixPinDisplays
                || capture.controls != routing.controls
            capture = routing
            guard pressedButtons.isEmpty else { return nil }
            let destination: CGPoint?
            if liveHitTest != nil && !captureModeChanged { return nil }
            recordInput(timestamp)
            invalidateHover()
            if let panel = parked.first(where: {
                $0.desktop.contains(cursor) && allows($0, at: $0.pointOnPhysical(cursor), hovering: true)
            }) {
                destination = panel.pointOnPhysical(cursor)
            } else if let panel = parked.first(where: {
                $0.physical.contains(cursor) && !allows($0, at: cursor, hovering: true)
            }) {
                destination = panel.pointOnDesktop(cursor)
            } else {
                destination = nil
            }
            lastPoint = destination ?? cursor
            return destination
        }

        mutating func destination(for point: CGPoint, button: ButtonChange? = nil, passiveMotion: Bool = false, delta: CGVector = .zero,
                                  timestamp: CGEventTimestamp = 0) -> CGPoint? {
            recordInput(timestamp)
            invalidateHover()
            let destination = routePoint(point, delta: delta, hovering: passiveMotion, timestamp: timestamp)
            lastPoint = destination ?? point
            switch button {
            case .down(let button):
                if pressedButtons.isEmpty {
                    gesturePanel = parked.first { panel in
                        guard let id = panel.displayID, !capture.displays.contains(id),
                              panel.physical.contains(lastPoint) else { return false }
                        return allows(panel, at: lastPoint)
                    }?.displayID
                }
                pressedButtons.insert(button)
            case .up(let button):
                pressedButtons.remove(button)
                if button == 0 { pixPinQueuedUntil = nil }
                if pressedButtons.isEmpty { gesturePanel = nil }
            case nil:
                break
            }
            return destination
        }

        mutating func reservePixPinPress(on panel: Parking) -> Bool {
            guard liveHitTest != nil, pressedButtons.isEmpty, parked.contains(panel),
                  let display = panel.displayID else { return false }
            invalidateHover()
            pressedButtons.insert(0)
            gesturePanel = display
            return true
        }

        mutating func suppressPixPinPress() {
            gesturePanel = nil
            pixPinQueuedUntil = nil
            suppressPixPinGesture = true
        }

        mutating func discardSuppressedPixPinEvent(_ type: CGEventType, timestamp: CGEventTimestamp = 0) -> Bool {
            guard suppressPixPinGesture else { return false }
            switch type {
            case .leftMouseDragged:
                recordInput(timestamp)
                return true
            case .leftMouseUp:
                recordInput(timestamp)
                suppressPixPinGesture = false
                pressedButtons.remove(0)
                return true
            default: return false
            }
        }

        mutating func resetGesture() {
            invalidateHover()
            pressedButtons.removeAll()
            gesturePanel = nil
            pixPinQueuedUntil = nil
            suppressPixPinGesture = false
        }

        private func routePoint(_ point: CGPoint, delta: CGVector, hovering: Bool, timestamp: CGEventTimestamp) -> CGPoint? {
            // Keep a press and its release on the same surface even if a popup opens,
            // closes, or moves while the button is held.
            if let gesturePanel, let panel = parked.first(where: { $0.displayID == gesturePanel }) {
                if let pixPinQueuedUntil, timestamp <= pixPinQueuedUntil, panel.desktop.contains(point) {
                    // Motion queued during the first press can still have virtual coordinates.
                    return panel.pointOnPhysical(point)
                }
                return panel.physical.contains(point) ? nil : Self.clamp(point, to: panel.physical)
            }
            let destination: CGPoint?
            let mayEnterPanel = pressedButtons.isEmpty
            let previousPanel = parked.first { $0.displayID != nil && $0.physical.contains(lastPoint) }
            if hovering, mayEnterPanel, let previousPanel, let id = previousPanel.displayID, capture.pixPinDisplays.contains(id) {
                if let exit = pixPinExit(from: previousPanel, point: point, delta: delta) {
                    return exit == point ? nil : exit
                }
                return previousPanel.physical.contains(point) ? nil : Self.clamp(point, to: previousPanel.physical)
            }
            if let parking = parked.first(where: {
                $0.physical.contains(point) && !allows($0, at: point, includeControls: mayEnterPanel,
                           hovering: hovering, retainPhysical: previousPanel?.displayID == $0.displayID)
            }) {
                if let id = parking.displayID, previousPanel?.displayID == id {
                    destination = parking.pointOnDesktop(point)
                } else {
                    let previous = previousPanel?.physical ?? screens.first { $0.contains(lastPoint) } ?? parking.desktop
                    destination = Self.clamp(point, to: previous)
                }
            } else if let parking = parked.first(where: {
                $0.desktop.contains(point) && allows($0, at: $0.pointOnPhysical(point), includeControls: mayEnterPanel, hovering: hovering)
            }) {
                // A drag reaching the edge of the physical panel must not jump to the far side
                // when WindowServer crosses into one of its virtual displays.
                if let previousPanel, let id = previousPanel.displayID, capture.hasSelector(on: id) {
                    destination = Self.clamp(point, to: previousPanel.physical)
                } else {
                    destination = parking.pointOnPhysical(point)
                }
            } else {
                destination = nil
            }
            return destination
        }

        private func pixPinExit(from panel: Parking, point: CGPoint, delta: CGVector) -> CGPoint? {
            // WindowServer clamps the cursor at a parked edge, but still reports the movement past it.
            func extend(_ position: CGFloat, last: CGFloat, by movement: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
                if position <= min, movement < 0 { return Swift.min(position, last + movement) }
                if position >= max - 1, movement > 0 { return Swift.max(position, last + movement) }
                return position
            }
            let attempted = CGPoint(x: extend(point.x, last: lastPoint.x, by: delta.dx, min: panel.physical.minX, max: panel.physical.maxX),
                                    y: extend(point.y, last: lastPoint.y, by: delta.dy, min: panel.physical.minY, max: panel.physical.maxY))
            let desktop = panel.pointOnDesktop(attempted)
            guard !panel.desktop.contains(desktop), screens.contains(where: { $0.contains(desktop) }) else { return nil }
            if let neighbor = parked.first(where: { $0.desktop.contains(desktop) && $0.displayID.map(capture.hasSelector(on:)) == true }) {
                return neighbor.pointOnPhysical(desktop)
            }
            return desktop
        }

        private static func clamp(_ point: CGPoint, to frame: CGRect) -> CGPoint {
            CGPoint(x: min(max(point.x, frame.minX), frame.maxX - 1),
                    y: min(max(point.y, frame.minY), frame.maxY - 1))
        }
    }

    private let routing = OSAllocatedUnfairLock(initialState: Route(
        liveHitTest: WindowServerHitTest.supportsLiveRouting ? WindowServerHitTest.aboveMirror : nil
    ))
    private let hoverQueue = DispatchQueue(label: "dev.cmkk.panelet.hover", qos: .userInitiated)
    private let pixPinReadyQueue = DispatchQueue(label: "dev.cmkk.panelet.pixpin-first-press", qos: .userInteractive)
    private static let trackingMoveTag: UInt64 = 0x50414e45_00000000
    static let motionMask = CGEventMask(1) << CGEventType.mouseMoved.rawValue
    private let trackingEventSource: CGEventSource? = {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0
        return source
    }()
    private struct RunLoopState {
        var loop: CFRunLoop?
        var stopped = false
    }

    private let screenshotKeys = OSAllocatedUnfairLock(initialState: PhysicalScreenScreenshot.KeyState())
    private let runLoopState = OSAllocatedUnfairLock(initialState: RunLoopState())
    private let captureApps = CaptureAppMonitor()
    var onPossibleCaptureShortcut: (() -> Void)?
    private var tap: CFMachPort?
    private var motionTap: CFMachPort?

    private static func isRecent(_ timestamp: CGEventTimestamp, at now: UInt64) -> Bool {
        timestamp <= now && now - timestamp <= 45_000_000
    }

    private static let hoverSettleNanoseconds: UInt64 = 40_000_000

    var activeSelectorPIDs: Set<pid_t> {
        captureApps.activeSelectorPIDs
    }

    func routeSnapshot() -> Route {
        routing.withLock { $0 }
    }

    func update(parked: [Parking], screens: [CGRect]) {
        let point = CGEvent(source: nil)?.location ?? .zero
        let anyButtonHeld = Self.isAnyMouseButtonPressed()
        if let destination = updateRoute(parked: parked, screens: screens, cursor: point, anyButtonHeld: anyButtonHeld) {
            CGWarpMouseCursorPosition(destination)
        }
    }

    func updateRoute(parked: [Parking], screens: [CGRect], cursor: CGPoint, anyButtonHeld: Bool) -> CGPoint? {
        routing.withLock { route in
            route.recordInput(DispatchTime.now().uptimeNanoseconds)
            route.invalidateHover()
            route.parked = parked
            route.screens = screens
            let displayIDs = Set(parked.compactMap(\.displayID))
            if parked.isEmpty || !anyButtonHeld {
                route.resetGesture()
            } else if let gesture = route.gesturePanel, !displayIDs.contains(gesture) {
                route.gesturePanel = nil
                route.pixPinQueuedUntil = nil
            }
            route.capture.displays.formIntersection(displayIDs)
            route.capture.pixPinDisplays.formIntersection(displayIDs)
            route.capture.controls = route.capture.controls.filter { displayIDs.contains($0.key) }
            route.capture.nativeWindows = route.capture.nativeWindows.filter { displayIDs.contains($0.key) }
            let parking = parked.first { $0.physical.contains(cursor) && !route.allows($0, at: cursor, hovering: true) }
            let destination = parking?.pointOnDesktop(cursor)
            route.lastPoint = destination ?? cursor
            return destination
        }
    }

    func setCaptureRouting(_ capture: CaptureRouting) {
        let point = CGEvent(source: nil)?.location
        let (destination, work) = routing.withLock { route -> (CGPoint?, UInt64?) in
            let changed = route.capture != capture
            let destination = route.setCaptureRouting(capture, cursor: point ?? route.lastPoint,
                                                      timestamp: DispatchTime.now().uptimeNanoseconds)
            let work = changed && destination == nil && route.hoverPending == nil
                ? route.scheduleHover(at: route.lastPoint, now: DispatchTime.now().uptimeNanoseconds) : nil
            return (destination, work)
        }
        if let destination { CGWarpMouseCursorPosition(destination) }
        if let work { submitHover(at: work) }
    }

    private func submitHover(at earliest: UInt64) {
        let deadline = max(earliest, DispatchTime.now().uptimeNanoseconds + Self.hoverSettleNanoseconds)
        hoverQueue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline)) { [weak self] in
            self?.queryHover()
        }
    }

    private func queryHover() {
        let now = DispatchTime.now().uptimeNanoseconds
        let outcome = routing.withLock { route -> (request: HoverRequest?, rescheduleAt: UInt64?) in
            guard let pending = route.hoverPending else {
                route.hoverScheduled = false
                return (nil, nil)
            }
            // Wait until the pointer has settled so continuous motion does not contend
            // with WindowServer's compositor lock on every 8ms tick.
            let settleDeadline = pending.started + Self.hoverSettleNanoseconds
            if now < settleDeadline {
                return (nil, settleDeadline)
            }
            route.hoverPending = nil
            route.hoverNextStart = now + Self.hoverSettleNanoseconds
            return (pending, nil)
        }
        if let rescheduleAt = outcome.rescheduleAt {
            hoverQueue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: rescheduleAt)) { [weak self] in
                self?.queryHover()
            }
            return
        }
        guard let request = outcome.request else { return }
        let hit = WindowServerHitTest.aboveMirror(at: request.physical, mirror: request.mirror)

        // An ordinary hit on the current surface requires no event-tap wakeup.
        if let hit, request.destination(hit: hit) != request.source,
           routing.withLock({ $0.acceptsHover(request) }),
           let loop = runLoopState.withLock({ $0.stopped ? nil : $0.loop }) {
            CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
                self?.moveCursor(from: request.source, to: request.destination(hit: hit),
                                 revision: request.revision, timestamp: request.started,
                                 enforceSourceProximity: true)
            }
            CFRunLoopWakeUp(loop)
        }
        let next = routing.withLock { route -> UInt64? in
            guard let pending = route.hoverPending else {
                route.hoverScheduled = false
                return nil
            }
            return max(route.hoverNextStart, pending.started + Self.hoverSettleNanoseconds)
        }
        if let next {
            hoverQueue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: next)) { [weak self] in
                self?.queryHover()
            }
        }
    }

    private static func isAnyMouseButtonPressed() -> Bool {
        [CGMouseButton.left, .right, .center].contains {
            CGEventSource.buttonState(.combinedSessionState, button: $0)
        }
    }

    @discardableResult
    private func moveCursor(from source: CGPoint, to destination: CGPoint, revision: UInt64,
                            timestamp: CGEventTimestamp, enforceSourceProximity: Bool) -> Bool {
        guard routing.withLock({ $0.acceptsMove(revision: revision) }),
              Self.isRecent(timestamp, at: DispatchTime.now().uptimeNanoseconds) else { return false }
        if enforceSourceProximity {
            guard let point = CGEvent(source: nil)?.location,
                  abs(point.x - source.x) <= 1, abs(point.y - source.y) <= 1,
                  !Self.isAnyMouseButtonPressed() else { return false }
        } else {
            guard !Self.isAnyMouseButtonPressed() else { return false }
        }
        let applied = routing.withLock { route -> Bool in
            guard route.acceptsMove(revision: revision),
                  Self.isRecent(timestamp, at: DispatchTime.now().uptimeNanoseconds),
                  CGWarpMouseCursorPosition(destination) == .success else { return false }
            route.lastPoint = destination
            return true
        }
        guard applied else { return false }
        // A warp updates the real cursor. Deliver the corresponding movement for native tracking.
        if let event = CGEvent(mouseEventSource: trackingEventSource, mouseType: .mouseMoved,
                               mouseCursorPosition: destination, mouseButton: .left) {
            let stamp = Self.trackingMoveTag | UInt64(UInt32(truncatingIfNeeded: revision))
            event.setIntegerValueField(.eventSourceUserData, value: Int64(bitPattern: stamp))
            event.post(tap: .cgSessionEventTap)
        }
        return true
    }

    private func observeMotion(_ event: CGEvent) {
        guard !Self.isTrackingMove(event) else { return }
        let point = event.location
        let timestamp = event.timestamp
        let now = DispatchTime.now().uptimeNanoseconds
        let motion = routing.withLock { route -> (destination: CGPoint?, revision: UInt64, hoverStart: UInt64?)? in
            if (!route.pressedButtons.isEmpty || route.gesturePanel != nil), !Self.isAnyMouseButtonPressed() {
                route.resetGesture()
            }
            let delta = route.capture.pixPinDisplays.isEmpty ? .zero : Self.mouseDelta(event)
            return route.observeMotion(at: point, delta: delta, timestamp: timestamp, now: now)
        }
        guard let motion else { return }
        if let destination = motion.destination {
            guard moveCursor(from: point, to: destination, revision: motion.revision, timestamp: timestamp,
                             enforceSourceProximity: false) else { return }
            let work = routing.withLock { route -> UInt64? in
                guard route.acceptsMove(revision: motion.revision) else { return nil }
                return route.scheduleHover(at: destination, now: now)
            }
            if let work { submitHover(at: work) }
        } else if let work = motion.hoverStart {
            submitHover(at: work)
        }
    }

    private static func mouseDelta(_ event: CGEvent) -> CGVector {
        CGVector(dx: CGFloat(event.getIntegerValueField(.mouseEventDeltaX)),
                 dy: CGFloat(event.getIntegerValueField(.mouseEventDeltaY)))
    }

    private static func isTrackingMove(_ event: CGEvent) -> Bool {
        UInt64(bitPattern: event.getIntegerValueField(.eventSourceUserData)) & 0xffff_ffff_0000_0000 == trackingMoveTag
    }

    private func acceptsHoverMotion(_ event: CGEvent) -> Bool {
        let stamp = UInt32(truncatingIfNeeded: event.getIntegerValueField(.eventSourceUserData))
        return routing.withLock { route in
            route.liveHitTest != nil && UInt32(truncatingIfNeeded: route.hoverRevision) == stamp &&
                route.pressedButtons.isEmpty && route.lastPoint == event.location
        }
    }

    func configureScreenshots(enabled: Bool? = nil, shortcuts: PhysicalScreenScreenshot.Shortcuts? = nil) {
        screenshotKeys.withLock { state in
            if let enabled { state.enabled = enabled }
            if let shortcuts { state.shortcuts = shortcuts }
        }
    }

    var isEnabled: Bool {
        guard let tap, CFMachPortIsValid(tap), CGEvent.tapIsEnabled(tap: tap) else { return false }
        guard let motionTap else { return true }
        return CFMachPortIsValid(motionTap) && CGEvent.tapIsEnabled(tap: motionTap)
    }

    static func isPassiveRoutingEvent(_ type: CGEventType) -> Bool {
        switch type {
        case .mouseMoved, .scrollWheel:
            return true
        default:
            return false
        }
    }

    static func mouseMask(observingMotion: Bool) -> CGEventMask {
        let types: [CGEventType] = [
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .scrollWheel
        ]
        return types.reduce(observingMotion ? 0 : motionMask) { $0 | (1 << $1.rawValue) }
    }

    func start() -> Bool {
        let keyboardMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, context in
            if let context {
                let router = Unmanaged<MouseRouter>.fromOpaque(context).takeUnretainedValue()
                switch type {
                case .tapDisabledByTimeout, .tapDisabledByUserInput:
                    router.routing.withLock { route in
                        route.resetGesture()
                        route.recordInput(DispatchTime.now().uptimeNanoseconds)
                    }
                    if let tap = router.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                case .keyDown, .keyUp:
                    let timestamp = min(event.timestamp, DispatchTime.now().uptimeNanoseconds)
                    router.routing.withLock { route in
                        route.recordInput(timestamp)
                        if route.liveHitTest != nil { route.invalidateHover() }
                    }
                    if router.handlesScreenshot(type, event) { return nil }
                    router.notifyCaptureShortcutIfNeeded(type: type, event: event)
                default:
                    if type == .mouseMoved && MouseRouter.isTrackingMove(event) {
                        if !router.acceptsHoverMotion(event) { return nil }
                    } else {
                        if !router.route(event, type: type) { return nil }
                    }
                }
            }
            return Unmanaged.passUnretained(event)
        }
        let observeMotion: CGEventTapCallBack = { _, type, event, context in
            if let context {
                let router = Unmanaged<MouseRouter>.fromOpaque(context).takeUnretainedValue()
                switch type {
                case .mouseMoved: router.observeMotion(event)
                case .tapDisabledByTimeout, .tapDisabledByUserInput:
                    if let tap = router.motionTap { CGEvent.tapEnable(tap: tap, enable: true) }
                default: break
                }
            }
            return Unmanaged.passUnretained(event)
        }
        func makeTap(mask: CGEventMask, options: CGEventTapOptions, callback: CGEventTapCallBack)
            -> (port: CFMachPort, source: CFRunLoopSource)? {
            guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: options,
                                               eventsOfInterest: mask, callback: callback,
                                               userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return nil }
            CGEvent.tapEnable(tap: port, enable: false)
            guard let source = CFMachPortCreateRunLoopSource(nil, port, 0) else {
                CFMachPortInvalidate(port)
                return nil
            }
            return (port, source)
        }
        let motion = makeTap(mask: Self.motionMask, options: .listenOnly, callback: observeMotion)
        let mouseMask = Self.mouseMask(observingMotion: motion != nil)
        guard let interaction = makeTap(mask: mouseMask | keyboardMask, options: .defaultTap, callback: callback)
                ?? makeTap(mask: mouseMask, options: .defaultTap, callback: callback) else {
            if let motion { CFMachPortInvalidate(motion.port) }
            return false
        }
        tap = interaction.port
        motionTap = motion?.port
        captureApps.start()
        runLoopState.withLock { state in
            state.loop = nil
            state.stopped = false
        }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, interaction.source, .defaultMode)
            if let motion { CFRunLoopAddSource(loop, motion.source, .defaultMode) }
            let shouldRun = runLoopState.withLock { state -> Bool in
                guard !state.stopped else { return false }
                state.loop = loop
                return true
            }
            ready.signal()
            guard shouldRun else { return }
            withExtendedLifetime(self) {
                while !runLoopState.withLock({ $0.stopped }) {
                    let status = CFRunLoopRunInMode(.defaultMode, 60, false)
                    if status == .finished || status == .stopped { break }
                }
            }
        }
        thread.name = "dev.cmkk.panelet.mouse-router"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        CGEvent.tapEnable(tap: interaction.port, enable: true)
        if let motion { CGEvent.tapEnable(tap: motion.port, enable: true) }
        guard isEnabled else { stop(); return false }
        return true
    }

    func stop() {
        captureApps.stop()
        routing.withLock { route in
            route.liveHitTest = nil
            route.resetGesture()
            route.recordInput(DispatchTime.now().uptimeNanoseconds)
        }
        let activeLoop = runLoopState.withLock { state -> CFRunLoop? in
            state.stopped = true
            let loop = state.loop
            state.loop = nil
            return loop
        }
        for tap in [tap, motionTap].compactMap({ $0 }) {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let activeLoop {
            CFRunLoopStop(activeLoop)
            CFRunLoopWakeUp(activeLoop)
        }
    }

    private func handlesScreenshot(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let result = screenshotKeys.withLock { state in
            state.handle(keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags,
                         down: type == .keyDown, repeated: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        }
        switch result {
        case .pass: return false
        case .consume: return true
        case .capture(let destination):
            PhysicalScreenScreenshot.capture(destination)
            return true
        }
    }

    private func notifyCaptureShortcutIfNeeded(type: CGEventType, event: CGEvent) {
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let modifierMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskSecondaryFn]
        let isEscape = keyCode == 53
        let hasHotkeyModifier = !event.flags.intersection(modifierMask).isEmpty
        guard isEscape || (type == .keyDown && hasHotkeyModifier) else { return }
        guard isEscape || !captureApps.activeSelectorPIDs.isEmpty else { return }
        guard let handler = onPossibleCaptureShortcut else { return }
        DispatchQueue.main.async(execute: handler)
    }

    private func handlePixPinPress(_ event: CGEvent, timestamp: CGEventTimestamp) -> Bool? {
        let runningPIDs = captureApps.activeSelectorPIDs
        guard !runningPIDs.isEmpty else { return nil }
        let deadline = DispatchTime.now() + .milliseconds(100)
        let point = event.location
        guard let panel = routing.withLock({ route -> Parking? in
            route.recordInput(timestamp)
            return route.liveHitTest != nil && route.pressedButtons.isEmpty ? route.parked.first {
                $0.displayID != nil && ($0.desktop.contains(point) || $0.physical.contains(point))
            } : nil
        }), let display = panel.displayID else { return nil }
        let mapped = panel.physical.contains(point) ? point : panel.pointOnPhysical(point)
        guard let selector = WindowServerHitTest.pixPinSelectorWindow(at: mapped, panel: panel, candidatePIDs: runningPIDs),
              routing.withLock({ $0.reservePixPinPress(on: panel) }) else { return nil }

        let ready = DispatchSemaphore(value: 0)
        pixPinReadyQueue.async {
            while DispatchTime.now() < deadline {
                if WindowServerHitTest.window(at: mapped) == selector {
                    if DispatchTime.now() < deadline { ready.signal() }
                    break
                }
                usleep(2_000)
            }
        }
        let hit = ready.wait(timeout: deadline) == .success
        return routing.withLock { route in
            guard route.gesturePanel == display, route.liveHitTest != nil, route.parked.contains(panel), hit else {
                if route.pressedButtons.contains(0) { route.suppressPixPinPress() }
                return false
            }
            if point != mapped {
                guard CGWarpMouseCursorPosition(mapped) == .success else {
                    route.suppressPixPinPress()
                    return false
                }
                event.location = mapped
                route.pixPinQueuedUntil = DispatchTime.now().uptimeNanoseconds
            }
            route.lastPoint = mapped
            return true
        }
    }

    private func route(_ event: CGEvent, type: CGEventType) -> Bool {
        let timestamp = min(event.timestamp, DispatchTime.now().uptimeNanoseconds)
        if (type == .leftMouseDragged || type == .leftMouseUp),
           routing.withLock({ $0.discardSuppressedPixPinEvent(type, timestamp: timestamp) }) { return false }
        if type == .leftMouseDown, let result = handlePixPinPress(event, timestamp: timestamp) { return result }
        let button: Route.ButtonChange?
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            button = .down(event.getIntegerValueField(.mouseEventButtonNumber))
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            button = .up(event.getIntegerValueField(.mouseEventButtonNumber))
        default:
            button = nil
        }
        let (destination, work) = routing.withLock { route -> (CGPoint?, UInt64?) in
            let moving = type == .mouseMoved
            let passive = Self.isPassiveRoutingEvent(type)
            if moving, (!route.pressedButtons.isEmpty || route.gesturePanel != nil), !Self.isAnyMouseButtonPressed() {
                route.resetGesture()
            }
            let delta = moving && !route.capture.pixPinDisplays.isEmpty ? Self.mouseDelta(event) : .zero
            let destination = route.destination(for: event.location, button: button,
                                                passiveMotion: passive, delta: delta, timestamp: timestamp)
            let work = moving
                ? route.scheduleHover(at: route.lastPoint, now: DispatchTime.now().uptimeNanoseconds) : nil
            return (destination, work)
        }
        if let destination {
            event.location = destination
            CGWarpMouseCursorPosition(destination)
        }
        if let work { submitHover(at: work) }
        return true
    }
}

enum CaptureOverlays {
    struct Half: Equatable, Sendable {
        let id: CGDirectDisplayID
        let frame: CGRect
    }

    struct Target: Equatable, Sendable {
        let id: CGDirectDisplayID
        let physical: CGRect
        let halves: [Half]
        var mirrorWindows: Set<CGWindowID> = []
    }

    struct Inspection: Sendable {
        var routing = MouseRouter.CaptureRouting()
        var shieldsByDisplay: [CGDirectDisplayID: Set<CGWindowID>] = [:]
        var screenshotUIVisible = false
    }

    struct ToolProfile: Equatable, Sendable {
        let bundleIdentifier: String
        let minimumLayer: Int
        let maxScreenPadding: CGFloat
    }

    static let pixPinProfile = ToolProfile(
        bundleIdentifier: "com.depthpicture.PixPin",
        minimumLayer: Int(CGWindowLevelForKey(.popUpMenuWindow)),
        maxScreenPadding: 16
    )

    static let toolProfiles: [ToolProfile] = [pixPinProfile]

    fileprivate static let pixPinBundleIdentifier = pixPinProfile.bundleIdentifier
    fileprivate static let pixPinLayer = pixPinProfile.minimumLayer

    private struct PixPinGroup: Hashable {
        let pid: pid_t
        let level: Int
    }

    private struct PanelWindow {
        let id: CGWindowID
        let pid: pid_t
        let layer: Int
        let frame: CGRect
    }

    // Used only on SplitSessions' serial overlay queue.
    final class PopupValidation: @unchecked Sendable {
        private var results: [CGWindowID: (pid: pid_t, accepted: Bool, retryAfter: ContinuousClock.Instant)] = [:]

        fileprivate func retainVisible(_ windows: [[String: Any]]) {
            guard !results.isEmpty else { return }
            let ids = Set(windows.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
            results = results.filter { ids.contains($0.key) }
        }

        fileprivate func accepts(id: CGWindowID, pid: pid_t, verify: () -> Bool) -> Bool {
            let now = ContinuousClock.now
            if let saved = results[id], saved.pid == pid, saved.accepted || now < saved.retryAfter {
                return saved.accepted
            }
            let accepted = verify()
            results[id] = (pid, accepted, now + .seconds(1))
            return accepted
        }
    }

    static func visibleSnapshot(mirrors: Set<CGWindowID>, above anchor: CGWindowID?)
        -> (windows: [[String: Any]], backmostMirror: CGWindowID?)? {
        if let anchor, WindowServerHitTest.supportsLiveRouting, mirrors.contains(anchor),
           let front = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .optionIncludingWindow, .excludeDesktopElements], anchor)
                as? [[String: Any]],
           canUseFrontSnapshot(front, mirrors: mirrors) {
            return (front, anchor)
        }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let backmostMirror = windows.reversed().lazy.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
            .first(where: mirrors.contains)
        return (windows, backmostMirror)
    }

    static func canUseFrontSnapshot(_ windows: [[String: Any]], mirrors: Set<CGWindowID>) -> Bool {
        // Apple's window picker can order its highlight behind the mirrors.
        !windows.contains { $0[kCGWindowOwnerName as String] as? String == "screencapture" }
            && mirrors.isSubset(of: windows.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
    }

    static func inspect(visible: [[String: Any]], on targets: [Target], popupValidation: PopupValidation,
                        selectorPIDs: Set<pid_t>? = nil,
                        canInteract: (pid_t, CGRect) -> Bool) -> Inspection {
        var windows = visible
        popupValidation.retainVisible(visible)
        let pixPinPIDs = selectorPIDs ?? Set(
            toolProfiles.flatMap { profile in
                NSRunningApplication.runningApplications(withBundleIdentifier: profile.bundleIdentifier)
                    .map(\.processIdentifier)
            }
        )
        let apple = windows.filter { $0[kCGWindowOwnerName as String] as? String == "screencapture" }
        if apple.contains(where: { $0[kCGWindowName as String] as? String == "touchshield" }),
           !apple.contains(where: { $0[kCGWindowName as String] as? String == "windowselection" }),
           let all = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            // The picker orders its highlight off screen while the pointer is on the toolbar.
            windows += all.filter { $0[kCGWindowOwnerName as String] as? String == "screencapture"
                && $0[kCGWindowName as String] as? String == "windowselection" }
        }
        let screenshotUI = apple.isEmpty ? [] : Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.screencaptureui")
            .map(\.processIdentifier))
        var inspection = inspect(windows, on: targets, pixPinPIDs: pixPinPIDs, screenshotUIPIDs: screenshotUI,
                                 nativeHitTesting: WindowServerHitTest.isAvailable) { id, pid, frame in
            popupValidation.accepts(id: id, pid: pid) { canInteract(pid, frame) }
        }
        inspection.screenshotUIVisible = !apple.isEmpty || !inspection.routing.pixPinDisplays.isEmpty
        return inspection
    }

    static func inspect(_ windows: [[String: Any]], on targets: [Target], pixPinPIDs: Set<pid_t>,
                        screenshotUIPIDs: Set<pid_t> = [], nativeHitTesting: Bool = false,
                        validatePopup: (CGWindowID, pid_t, CGRect) -> Bool = { _, _, _ in false }) -> Inspection {
        let shieldingLevel = Int(CGWindowLevelForKey(.screenSaverWindow))
        let cursorLevel = Int(CGWindowLevelForKey(.cursorWindow))
        let aboveMenuBar = Int(CGWindowLevelForKey(.mainMenuWindow)) + 1
        var systemWindows: [(id: CGWindowID?, pid: pid_t, frame: CGRect, isTracking: Bool)] = []
        var windowPickerPIDs: Set<pid_t> = []
        var controls: [CGRect] = []
        var panelWindows: [PanelWindow] = []
        var pixPinSelectors: [PixPinGroup: [CGRect]] = [:]
        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer < cursorLevel,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
            let ownerName = window[kCGWindowOwnerName as String] as? String
            if ownerName == "Window Server" { continue }
            let apple = ownerName == "screencapture"
            let name = window[kCGWindowName as String] as? String
            if apple && name == "windowselection" {
                windowPickerPIDs.insert(pid)
                continue
            }
            let system = apple && layer >= shieldingLevel
            let control = layer > shieldingLevel && screenshotUIPIDs.contains(pid)
            let pixPin = layer >= pixPinLayer && pixPinPIDs.contains(pid)
            let panelWindow = layer >= aboveMenuBar && (nativeHitTesting || layer < shieldingLevel)
                && !apple && !screenshotUIPIDs.contains(pid) && !pixPinPIDs.contains(pid)
            guard system || control || pixPin || panelWindow,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            if system { systemWindows.append((window[kCGWindowNumber as String] as? CGWindowID, pid, frame, name == "tracking")) }
            if control { controls.append(frame) }
            if pixPin { pixPinSelectors[PixPinGroup(pid: pid, level: layer), default: []].append(frame) }
            if panelWindow, let id = window[kCGWindowNumber as String] as? CGWindowID, id != kCGNullWindowID {
                panelWindows.append(PanelWindow(id: id, pid: pid, layer: layer, frame: frame))
            }
        }

        var inspection = Inspection()
        for target in targets {
            // Apple's per-display shields belong to the capture UI. Exclude only the
            // shield on each mirror source so the physical selector can draw its own UI.
            for half in target.halves {
                let shields = Set(systemWindows.compactMap { window -> CGWindowID? in
                    guard let id = window.id, id != kCGNullWindowID, !window.isTracking,
                          Self.fits(window.frame, on: half.frame, padding: 1) else { return nil }
                    return id
                })
                if !shields.isEmpty { inspection.shieldsByDisplay[half.id] = shields }
            }

            let screens = [target.physical] + target.halves.map(\.frame)
            let interiors = screens.map { $0.insetBy(dx: 1, dy: 1) }
            if let selector = systemWindows.first(where: { window in interiors.allSatisfy(window.frame.contains) }) {
                if windowPickerPIDs.contains(selector.pid) {
                    let panelControls = controls.map { target.physical.intersection($0) }.filter { !$0.isEmpty }
                    if !panelControls.isEmpty { inspection.routing.controls[target.id] = panelControls }
                } else {
                    inspection.routing.displays.insert(target.id)
                }
                continue
            }

            // PixPin opens an elevated window on each display, with up to 10 points
            // of padding in the tested version. A single full-screen pin cannot match.
            if pixPinSelectors.values.contains(where: { coversPixPinScreens($0, screens: screens) }) {
                inspection.routing.pixPinDisplays.insert(target.id)
            } else {
                let popups = popupRegions(in: panelWindows, on: target, nativeHitTesting: nativeHitTesting,
                                          validate: validatePopup)
                if !popups.isEmpty {
                    if nativeHitTesting {
                        inspection.routing.nativeWindows[target.id] = popups
                    } else {
                        inspection.routing.controls[target.id] = popups.map(\.frame)
                    }
                }
            }
        }
        return inspection
    }

    static func pixPinSelectorWindows(_ windows: [[String: Any]], pid: pid_t, screens: [CGRect]) -> [CGWindowID]? {
        guard screens.count == 3 else { return nil }
        var groups: [Int: [(id: CGWindowID, frame: CGRect)]] = [:]
        for window in windows {
            guard window[kCGWindowOwnerPID as String] as? pid_t == pid,
                  let layer = window[kCGWindowLayer as String] as? Int, layer >= pixPinLayer,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            let id = window[kCGWindowNumber as String] as? CGWindowID ?? kCGNullWindowID
            groups[layer, default: []].append((id, frame))
        }
        for layer in groups.keys.sorted(by: >) {
            let ids = screens.compactMap { screen in
                groups[layer]?.first(where: { fits($0.frame, on: screen, padding: 16) })?.id
            }
            if ids.count == screens.count { return ids }
        }
        return nil
    }

    private static func coversPixPinScreens(_ frames: [CGRect], screens: [CGRect]) -> Bool {
        screens.allSatisfy { screen in frames.contains { fits($0, on: screen, padding: 16) } }
    }

    private static func popupRegions(in windows: [PanelWindow], on target: Target, nativeHitTesting: Bool,
                                     validate: (CGWindowID, pid_t, CGRect) -> Bool) -> [MouseRouter.NativeWindow] {
        let mirrors = windows.enumerated().filter { target.mirrorWindows.contains($0.element.id) }
        guard !mirrors.isEmpty else { return [] }
        var regions: [MouseRouter.NativeWindow] = []
        for (index, window) in windows.enumerated() {
            guard window.pid != getpid(), !target.mirrorWindows.contains(window.id),
                  (nativeHitTesting || !window.frame.contains(target.physical.insetBy(dx: 1, dy: 1))) else { continue }
            // WindowServer supplies a front-to-back list. A window can straddle both mirrors.
            let visible = mirrors.compactMap { order, mirror -> CGRect? in
                guard index < order, window.layer >= mirror.layer else { return nil }
                let overlap = target.physical.intersection(mirror.frame).intersection(window.frame)
                return overlap.isEmpty ? nil : overlap
            }
            if !visible.isEmpty, nativeHitTesting || validate(window.id, window.pid, window.frame) {
                regions.append(contentsOf: visible.map { MouseRouter.NativeWindow(id: window.id, frame: $0) })
            }
        }
        return regions
    }

    private static func fits(_ window: CGRect, on display: CGRect, padding: CGFloat) -> Bool {
        window.contains(display.insetBy(dx: 1, dy: 1)) && display.insetBy(dx: -padding, dy: -padding).contains(window)
    }
}

/// Tracks running third-party screenshot selector apps via KVO on `NSWorkspace.runningApplications`
/// (which covers `LSUIElement=1` accessory apps like PixPin that emit no launch notifications)
/// so the real-time `CGEventTap` callback never queries AppKit or WindowServer on ordinary clicks.
final class CaptureAppMonitor: @unchecked Sendable {
    private struct State {
        var pids: Set<pid_t> = []
        var observation: NSKeyValueObservation?
        var generation: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let monitorQueue = DispatchQueue(label: "dev.cmkk.panelet.capture-app-monitor", qos: .utility)
    private let bundleIDs: Set<String>

    init(bundleIDs: Set<String> = Set(CaptureOverlays.toolProfiles.map(\.bundleIdentifier))) {
        self.bundleIDs = bundleIDs
    }

    var activeSelectorPIDs: Set<pid_t> {
        state.withLock { $0.pids }
    }

    func start() {
        let initial = scanRunningPIDs()
        let generation = state.withLock { state -> UInt64? in
            guard state.observation == nil else { return nil }
            state.generation &+= 1
            state.pids = initial
            return state.generation
        }
        guard let generation else { return }

        let installObserver = { [weak self] in
            guard let self else { return }
            let observation = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { [weak self] _, _ in
                self?.scheduleRefresh(for: generation)
            }
            let staleObservation = self.state.withLock { state -> NSKeyValueObservation? in
                guard state.generation == generation, state.observation == nil else { return observation }
                state.observation = observation
                return nil
            }
            staleObservation?.invalidate()
            if staleObservation == nil {
                self.scheduleRefresh(for: generation)
            }
        }

        if Thread.isMainThread {
            installObserver()
        } else {
            DispatchQueue.main.async(execute: installObserver)
        }
    }

    func stop() {
        let observation = state.withLock { state -> NSKeyValueObservation? in
            state.generation &+= 1
            state.pids.removeAll()
            let active = state.observation
            state.observation = nil
            return active
        }
        observation?.invalidate()
    }

    private func scheduleRefresh(for generation: UInt64) {
        monitorQueue.async { [weak self] in
            self?.refresh(for: generation)
        }
    }

    private func refresh(for generation: UInt64) {
        let latest = scanRunningPIDs()
        state.withLock { state in
            guard state.generation == generation else { return }
            state.pids = latest
        }
    }

    private func scanRunningPIDs() -> Set<pid_t> {
        var pids = Set<pid_t>()
        for id in bundleIDs {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) where !app.isTerminated {
                pids.insert(app.processIdentifier)
            }
        }
        return pids
    }
}

/// Physical overlay hit testing and PixPin selector discovery.
/// Snapshot routing remains available when the native symbols are unavailable.
enum WindowServerHitTest {
    static var supportsLiveRouting: Bool { SystemBridge.SkyLight.supportsLiveRouting }

    static func pixPinSelectorWindow(at point: CGPoint, panel: MouseRouter.Parking,
                                     candidatePIDs: Set<pid_t>? = nil) -> CGWindowID? {
        guard panel.mirrors.count == 2 else { return nil }
        let pids = candidatePIDs ?? Set(
            NSRunningApplication.runningApplications(withBundleIdentifier: CaptureOverlays.pixPinBundleIdentifier)
                .map(\.processIdentifier)
        )
        guard !pids.isEmpty,
              let mirror = panel.mirrors.first(where: { $0.frame.contains(point) }) else { return nil }
        // Fast path: if SkyLight hit-testing already resolves to a non-mirror window that does NOT
        // belong to an ordinary desktop below, we still only query windows ordered above the mirror.
        // Note: When a selector just appeared (<60ms), WindowServer hit-testing may temporarily
        // still return `mirror.id`; querying `.optionOnScreenAboveWindow` only when `pids` is non-empty
        // preserves early first-drag reliability while keeping the common path zero-IPC when idle.
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements], mirror.id)
                as? [[String: Any]], !windows.isEmpty else { return nil }
        // Short-circuit before geometry parsing when none of the windows above the mirror belong to candidatePIDs.
        guard windows.contains(where: { entry in
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t else { return false }
            return pids.contains(pid)
        }) else { return nil }
        let screens = [panel.physical] + panel.mirrors.map {
            CGRect(origin: panel.pointOnDesktop($0.frame.origin), size: $0.frame.size)
        }
        for pid in pids {
            if let window = CaptureOverlays.pixPinSelectorWindows(windows, pid: pid, screens: screens)?.first,
               window != kCGNullWindowID {
                return window
            }
        }
        return nil
    }

    private static let cursorLayer = CGWindowLevelForKey(.cursorWindow)

    static func aboveMirror(at point: CGPoint, mirror: MouseRouter.NativeWindow) -> Bool? {
        guard supportsLiveRouting else { return nil }
        guard let hit = window(at: point), hit != mirror.id else { return false }
        guard let hitLevel = SystemBridge.SkyLight.level(of: hit) else { return nil }
        if hitLevel >= cursorLayer { return false }
        if hitLevel != mirror.level { return hitLevel > mirror.level }
        guard let above = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements], mirror.id)
                as? [[String: Any]] else { return nil }
        return above.contains { ($0[kCGWindowNumber as String] as? CGWindowID) == hit }
    }

    static var isAvailable: Bool { SystemBridge.SkyLight.supportsHitTesting }

    static func window(at point: CGPoint) -> CGWindowID? {
        SystemBridge.SkyLight.window(at: point)
    }
}
