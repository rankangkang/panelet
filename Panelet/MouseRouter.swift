import AppKit
import CoreGraphics
import Foundation
import os

/// Keep the pointer on the virtual desktops, with access to controls drawn on the physical panel.
final class MouseRouter {
    struct NativeWindow: Equatable, Sendable {
        let id: CGWindowID
        let frame: CGRect
    }

    struct CaptureRouting: Equatable, Sendable {
        var displays: Set<CGDirectDisplayID> = []
        var controls: [CGDirectDisplayID: [CGRect]] = [:]
        var nativeWindows: [CGDirectDisplayID: [NativeWindow]] = [:]

        func allows(_ display: CGDirectDisplayID?, at point: CGPoint, includeControls: Bool = true,
                    hitTest: (CGPoint) -> CGWindowID? = WindowServerHitTest.window) -> Bool {
            guard let display else { return false }
            if displays.contains(display) { return true }
            guard includeControls else { return false }
            if controls[display]?.contains(where: { $0.contains(point) }) == true { return true }
            let candidates = nativeWindows[display]?.filter { $0.frame.contains(point) } ?? []
            guard !candidates.isEmpty, let hit = hitTest(point) else { return false }
            return candidates.contains { $0.id == hit }
        }
    }

    struct Parking {
        let physical: CGRect
        let desktop: CGRect
        var displayID: CGDirectDisplayID? = nil

        func pointOnPhysical(_ point: CGPoint) -> CGPoint {
            CGPoint(x: physical.minX + point.x - desktop.minX, y: physical.minY + point.y - desktop.minY)
        }

        func pointOnDesktop(_ point: CGPoint) -> CGPoint {
            CGPoint(x: desktop.minX + point.x - physical.minX, y: desktop.minY + point.y - physical.minY)
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

        mutating func setCaptureRouting(_ routing: CaptureRouting, cursor: CGPoint) -> CGPoint? {
            guard routing != capture else { return nil }
            capture = routing
            guard pressedButtons.isEmpty else { return nil }
            let destination: CGPoint?
            if let panel = parked.first(where: {
                $0.desktop.contains(cursor) && routing.allows($0.displayID, at: $0.pointOnPhysical(cursor), hitTest: hitTest)
            }) {
                destination = panel.pointOnPhysical(cursor)
            } else if let panel = parked.first(where: {
                $0.physical.contains(cursor) && !routing.allows($0.displayID, at: cursor, hitTest: hitTest)
            }) {
                destination = panel.pointOnDesktop(cursor)
            } else {
                destination = nil
            }
            lastPoint = destination ?? cursor
            return destination
        }

        mutating func destination(for point: CGPoint, button: ButtonChange? = nil) -> CGPoint? {
            let destination = routePoint(point)
            lastPoint = destination ?? point
            switch button {
            case .down(let button):
                if pressedButtons.isEmpty {
                    gesturePanel = parked.first { panel in
                        guard let id = panel.displayID, !capture.displays.contains(id) else { return false }
                        return panel.physical.contains(lastPoint) && capture.allows(id, at: lastPoint, hitTest: hitTest)
                    }?.displayID
                }
                pressedButtons.insert(button)
            case .up(let button):
                pressedButtons.remove(button)
                if pressedButtons.isEmpty { gesturePanel = nil }
            case nil:
                break
            }
            return destination
        }

        mutating func resetGesture() {
            pressedButtons.removeAll()
            gesturePanel = nil
        }

        private func routePoint(_ point: CGPoint) -> CGPoint? {
            // Keep a press and its release on the same surface even if a popup opens,
            // closes, or moves while the button is held.
            if let gesturePanel, let panel = parked.first(where: { $0.displayID == gesturePanel }) {
                return panel.physical.contains(point) ? nil : Self.clamp(point, to: panel.physical)
            }
            let destination: CGPoint?
            let mayEnterPanel = pressedButtons.isEmpty
            let previousPanel = parked.first { $0.displayID != nil && $0.physical.contains(lastPoint) }
            if let parking = parked.first(where: {
                $0.physical.contains(point) && !capture.allows($0.displayID, at: point, includeControls: mayEnterPanel, hitTest: hitTest)
            }) {
                if let id = parking.displayID, previousPanel?.displayID == id {
                    destination = parking.pointOnDesktop(point)
                } else {
                    let previous = previousPanel?.physical ?? screens.first { $0.contains(lastPoint) } ?? parking.desktop
                    destination = Self.clamp(point, to: previous)
                }
            } else if let parking = parked.first(where: {
                $0.desktop.contains(point) && capture.allows($0.displayID, at: $0.pointOnPhysical(point), includeControls: mayEnterPanel, hitTest: hitTest)
            }) {
                // A drag reaching the edge of the physical panel must not jump to the far side
                // when WindowServer crosses into one of its virtual displays.
                if let previousPanel, let id = previousPanel.displayID, capture.displays.contains(id) {
                    destination = Self.clamp(point, to: previousPanel.physical)
                } else {
                    destination = parking.pointOnPhysical(point)
                }
            } else {
                destination = nil
            }
            return destination
        }

        private static func clamp(_ point: CGPoint, to frame: CGRect) -> CGPoint {
            CGPoint(x: min(max(point.x, frame.minX), frame.maxX - 1),
                    y: min(max(point.y, frame.minY), frame.maxY - 1))
        }
    }

    private let routing = OSAllocatedUnfairLock(initialState: Route())
    private let screenshotKeys = OSAllocatedUnfairLock(initialState: PhysicalScreenScreenshot.KeyState())
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?

    func update(parked: [Parking], screens: [CGRect]) {
        let point = CGEvent(source: nil)?.location ?? .zero
        let destination = routing.withLock { route -> CGPoint? in
            route.parked = parked
            route.screens = screens
            let displayIDs = Set(parked.compactMap(\.displayID))
            route.capture.displays.formIntersection(displayIDs)
            route.capture.controls = route.capture.controls.filter { displayIDs.contains($0.key) }
            route.capture.nativeWindows = route.capture.nativeWindows.filter { displayIDs.contains($0.key) }
            let parking = parked.first { $0.physical.contains(point) && !route.capture.allows($0.displayID, at: point) }
            let destination = parking?.pointOnDesktop(point)
            route.lastPoint = destination ?? point
            return destination
        }
        if let destination { CGWarpMouseCursorPosition(destination) }
    }

    func setCaptureRouting(_ capture: CaptureRouting) {
        let point = CGEvent(source: nil)?.location
        let destination = routing.withLock { route in
            route.setCaptureRouting(capture, cursor: point ?? route.lastPoint)
        }
        if let destination { CGWarpMouseCursorPosition(destination) }
    }

    func configureScreenshots(enabled: Bool, shortcuts: PhysicalScreenScreenshot.Shortcuts? = nil) {
        screenshotKeys.withLock { state in
            state.enabled = enabled
            if let shortcuts { state.shortcuts = shortcuts }
        }
    }

    var isEnabled: Bool {
        tap.map { CFMachPortIsValid($0) && CGEvent.tapIsEnabled(tap: $0) } ?? false
    }

    func start() -> Bool {
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .scrollWheel
        ]
        let mouseMask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let keyboardMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, context in
            if let context {
                let router = Unmanaged<MouseRouter>.fromOpaque(context).takeUnretainedValue()
                switch type {
                case .tapDisabledByTimeout, .tapDisabledByUserInput:
                    router.routing.withLock { $0.resetGesture() }
                    if let tap = router.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                case .keyDown, .keyUp:
                    if router.handlesScreenshot(type, event) { return nil }
                default:
                    router.route(event)
                }
            }
            return Unmanaged.passUnretained(event)
        }
        func makeTap(mask: CGEventMask) -> CFMachPort? {
            CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                              eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        }
        guard let tap = makeTap(mask: mouseMask | keyboardMask) ?? makeTap(mask: mouseMask) else { return false }

        CGEvent.tapEnable(tap: tap, enable: false)
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        self.tap = tap
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()
            runLoop = loop
            CFRunLoopAddSource(loop, source, .defaultMode)
            ready.signal()
            withExtendedLifetime(self) { CFRunLoopRun() }
        }
        thread.name = L("竖屏分屏鼠标监听")
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        CGEvent.tapEnable(tap: tap, enable: true)
        return isEnabled
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
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

    private func route(_ event: CGEvent) {
        let button: Route.ButtonChange?
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            button = .down(event.getIntegerValueField(.mouseEventButtonNumber))
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            button = .up(event.getIntegerValueField(.mouseEventButtonNumber))
        default:
            button = nil
        }
        let destination = routing.withLock { $0.destination(for: event.location, button: button) }
        if let destination {
            event.location = destination
            CGWarpMouseCursorPosition(destination)
        }
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
    }

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

        fileprivate func retainVisible(_ ids: Set<CGWindowID>) {
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

    // Preserve the current state if WindowServer cannot provide a window list.
    static func inspect(on targets: [Target], popupValidation: PopupValidation,
                        canInteract: (pid_t, CGRect) -> Bool) -> Inspection? {
        guard var windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        popupValidation.retainVisible(Set(windows.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }))
        let pixPinPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.depthpicture.PixPin")
            .map(\.processIdentifier))
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
        return inspect(windows, on: targets, pixPinPIDs: pixPinPIDs, screenshotUIPIDs: screenshotUI,
                       nativeHitTesting: WindowServerHitTest.isAvailable) { id, pid, frame in
            popupValidation.accepts(id: id, pid: pid) { canInteract(pid, frame) }
        }
    }

    static func inspect(_ windows: [[String: Any]], on targets: [Target], pixPinPIDs: Set<pid_t>,
                        screenshotUIPIDs: Set<pid_t> = [], nativeHitTesting: Bool = false,
                        validatePopup: (CGWindowID, pid_t, CGRect) -> Bool = { _, _, _ in false }) -> Inspection {
        let shieldingLevel = Int(CGWindowLevelForKey(.screenSaverWindow))
        let popupLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let aboveMenuBar = Int(CGWindowLevelForKey(.mainMenuWindow)) + 1
        var systemWindows: [(id: CGWindowID?, pid: pid_t, frame: CGRect, isTracking: Bool)] = []
        var windowPickerPIDs: Set<pid_t> = []
        var controls: [CGRect] = []
        var panelWindows: [PanelWindow] = []
        var pixPinSelectors: [PixPinGroup: [CGRect]] = [:]
        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
            let apple = (window[kCGWindowOwnerName as String] as? String) == "screencapture"
            let name = window[kCGWindowName as String] as? String
            if apple && name == "windowselection" {
                windowPickerPIDs.insert(pid)
                continue
            }
            let system = apple && layer >= shieldingLevel
            let control = layer > shieldingLevel && screenshotUIPIDs.contains(pid)
            let pixPin = layer >= popupLevel && pixPinPIDs.contains(pid)
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
            let pixPinActive = pixPinSelectors.values.contains { frames in
                screens.allSatisfy { screen in
                    frames.contains { Self.fits($0, on: screen, padding: 16) }
                }
            }
            if pixPinActive {
                inspection.routing.displays.insert(target.id)
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

/// Optional private WindowServer hit testing. The window list stays on the background
/// queue. Only points inside candidate overlays incur this small native query.
/// Resolve symbols dynamically so unsupported systems retain AX-based popup routing.
enum WindowServerHitTest {
    private typealias Find = @convention(c) (Int32, Int32, Int32, Int32, UnsafePointer<CGPoint>,
        UnsafeMutablePointer<CGPoint>, UnsafeMutablePointer<CGWindowID>, UnsafeMutablePointer<Int32>) -> Int32
    private static let find: Find? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SLSFindWindowAndOwner") else { return nil }
        return unsafeBitCast(symbol, to: Find.self)
    }()
    private static let connection: Int32 = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SLSMainConnectionID") else { return 0 }
        return unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)()
    }()

    static var isAvailable: Bool { find != nil && connection != 0 }

    static func window(at point: CGPoint) -> CGWindowID? {
        guard let find, connection != 0 else { return nil }
        var screenPoint = point
        var windowPoint = CGPoint.zero
        var window: CGWindowID = 0
        var owner: Int32 = 0
        guard find(connection, 0, 1, 0, &screenPoint, &windowPoint, &window, &owner) == 0,
              window != kCGNullWindowID else { return nil }
        return window
    }
}
