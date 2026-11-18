import CoreGraphics
import Foundation

@main
struct CaptureRoutingTests {
    static func main() {
        let physical = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let left = CGRect(x: 2560, y: 0, width: 1280, height: 1440)
        let right = CGRect(x: 3840, y: 0, width: 1280, height: 1440)
        let other = CGRect(x: 0, y: -900, width: 1440, height: 900)
        let hidden = CGRect(x: 5120, y: 0, width: 1280, height: 1440)
        var route = MouseRouter.Route(
            parked: [.init(physical: physical, desktop: left.union(right), displayID: 1),
                     .init(physical: hidden, desktop: physical)],
            screens: [left, right, other], lastPoint: CGPoint(x: 4300, y: 500)
        )

        assert(route.destination(for: CGPoint(x: 100, y: 500)) == CGPoint(x: 3840, y: 500))
        let start = CGPoint(x: 4300, y: 500)
        assert(route.setCaptureRouting(.init(displays: [1]), cursor: start) == CGPoint(x: 1740, y: 500))
        assert(route.destination(for: CGPoint(x: 1200, y: 500)) == nil)
        assert(route.destination(for: CGPoint(x: 1500, y: 600)) == nil)
        assert(route.destination(for: CGPoint(x: 2561, y: 650)) == CGPoint(x: 2559, y: 650))
        assert(route.setCaptureRouting(.init(displays: []), cursor: CGPoint(x: 1500, y: 600)) == CGPoint(x: 4060, y: 600))
        assert(route.destination(for: CGPoint(x: 5121, y: 600)) == CGPoint(x: 5119, y: 600))

        let verticalPanel = CGRect(x: -900, y: -30, width: 900, height: 1600)
        let verticalDesktop = CGRect(x: 0, y: 1440, width: 900, height: 1600)
        let upper = CGRect(x: 0, y: 1440, width: 900, height: 535)
        let lower = CGRect(x: 0, y: 1975, width: 900, height: 1065)
        route.parked.append(.init(physical: verticalPanel, desktop: verticalDesktop, displayID: 2))
        route.screens += [upper, lower]
        assert(route.setCaptureRouting(.init(displays: [2]), cursor: CGPoint(x: 300, y: 2250)) == CGPoint(x: -600, y: 780))
        assert(route.destination(for: CGPoint(x: -400, y: 100)) == nil)
        assert(route.setCaptureRouting(.init(displays: [1]), cursor: CGPoint(x: -400, y: 100)) == CGPoint(x: 500, y: 1570))
        assert(route.destination(for: CGPoint(x: 3500, y: 220)) == CGPoint(x: 940, y: 220))

        let untouched = CGPoint(x: 200, y: -500)
        assert(route.setCaptureRouting(.init(displays: [1, 2]), cursor: untouched) == nil)
        assert(route.destination(for: CGPoint(x: 210, y: -490)) == nil)

        func window(_ owner: String, _ pid: pid_t, _ level: Int, _ frame: CGRect, id: CGWindowID = 0,
                    alpha: Double = 1, name: String = "") -> [String: Any] {
            [kCGWindowOwnerName as String: owner, kCGWindowOwnerPID as String: pid,
             kCGWindowLayer as String: level, kCGWindowBounds as String: frame.dictionaryRepresentation,
             kCGWindowNumber as String: id, kCGWindowAlpha as String: alpha, kCGWindowName as String: name]
        }
        let shielding = Int(CGWindowLevelForKey(.screenSaverWindow)) + 498
        let pixPinLevel = Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1
        let toolbar = CGRect(x: 1260, y: 1289, width: 800, height: 90)
        let regionSelector = window("screencapture", 10, shielding, physical.union(left).union(right), id: 20)
        let appleToolbar = window("截屏", 11, shielding + 1, toolbar)
        let recordingShields = [physical, left, right].enumerated().map { index, frame in
            window("screencapture", 10, shielding, frame, id: CGWindowID(21 + index))
        }
        let fullScreenPin = window("PixPin", 12, pixPinLevel, physical)
        let magnifier = window("PixPin", 12, shielding, CGRect(x: 1480, y: 798, width: 165, height: 172))
        let unrelated = window("Other", 14, 1800, physical)
        let mainTarget = CaptureOverlays.Target(id: 1, physical: physical,
            halves: [.init(id: 3, frame: left), .init(id: 4, frame: right)])
        let verticalTarget = CaptureOverlays.Target(id: 2, physical: verticalPanel,
            halves: [.init(id: 5, frame: upper), .init(id: 6, frame: lower)])
        let targets = [mainTarget, verticalTarget]

        // Reproduce the physical selector and its two slightly padded virtual windows observed in PixPin.
        let pixPinWindows = [
            window("PixPin", 12, pixPinLevel, CGRect(x: -10, y: -10, width: 2580, height: 1460)),
            window("PixPin", 12, pixPinLevel, CGRect(x: 2550, y: -10, width: 1290, height: 1450)),
            window("PixPin", 12, pixPinLevel, CGRect(x: 3830, y: -10, width: 1290, height: 1450)),
        ]
        let verticalSelectors = [verticalPanel, upper, lower].map {
            window("PixPin", 12, pixPinLevel, $0.insetBy(dx: -10, dy: -10))
        }
        func inspect(_ windows: [[String: Any]], pixPinPIDs: Set<pid_t> = [12]) -> CaptureOverlays.Inspection {
            CaptureOverlays.inspect(windows, on: targets, pixPinPIDs: pixPinPIDs, screenshotUIPIDs: [11])
        }
        func detected(_ windows: [[String: Any]], pixPinPIDs: Set<pid_t> = [12]) -> Set<CGDirectDisplayID> {
            inspect(windows, pixPinPIDs: pixPinPIDs).routing.displays
        }
        assert(detected(pixPinWindows + [magnifier]) == [1])
        assert(detected(pixPinWindows, pixPinPIDs: []).isEmpty)
        assert(detected([regionSelector, appleToolbar] + verticalSelectors) == [1, 2])
        assert(detected(recordingShields + [appleToolbar, fullScreenPin, magnifier, unrelated]).isEmpty)
        assert(detected(Array(pixPinWindows.dropLast())).isEmpty)
        assert(detected([window("PixPin", 12, pixPinLevel, physical.union(left).union(right))]).isEmpty)
        assert(detected(Array(pixPinWindows.prefix(2)) + [window("PixPin", 12, pixPinLevel, right, alpha: 0)]).isEmpty)
        assert(detected(Array(pixPinWindows.prefix(2)) + [window("PixPin", 12, pixPinLevel + 1, right)]).isEmpty)
        assert(detected(Array(pixPinWindows.prefix(2)) + [window("PixPin", 13, pixPinLevel, right)],
                        pixPinPIDs: [12, 13]).isEmpty)

        let selection = inspect(recordingShields + [regionSelector, appleToolbar])
        assert(selection.routing.displays == [1] && selection.shieldsByDisplay == [3: [22], 4: [23]])
        let recording = inspect(recordingShields)
        assert(recording.routing.displays.isEmpty && recording.shieldsByDisplay == [3: [22], 4: [23]])
        let windowSelection = window("screencapture", 10, 25, CGRect(x: 2600, y: 100, width: 500, height: 400), name: "windowselection")
        let picker = inspect([regionSelector, windowSelection, appleToolbar])
        assert(picker.routing.displays.isEmpty && picker.routing.controls == [1: [toolbar]])
        let tracking = window("screencapture", 10, shielding, left, id: 50, name: "tracking")
        assert(inspect([regionSelector, tracking]).shieldsByDisplay.isEmpty)
        assert(inspect([windowSelection, appleToolbar]).routing == .init())
        assert(inspect([regionSelector, window("screencapture", 99, 25, left, name: "windowselection")]).routing.displays == [1])

        var pickerRoute = MouseRouter.Route(parked: [route.parked[0]], screens: [left, right], capture: selection.routing)
        assert(pickerRoute.setCaptureRouting(picker.routing, cursor: CGPoint(x: 500, y: 100)) == CGPoint(x: 3060, y: 100))
        assert(pickerRoute.destination(for: CGPoint(x: 3900, y: 1334)) == CGPoint(x: 1340, y: 1334))
        assert(pickerRoute.destination(for: CGPoint(x: 1340, y: 1336)) == nil)
        assert(pickerRoute.destination(for: CGPoint(x: 1340, y: 1280)) == CGPoint(x: 3900, y: 1280))

        let popup = CGRect(x: 910, y: 30, width: 370, height: 250)
        var popupTarget = mainTarget
        popupTarget.mirrorWindows = [60, 61]
        let mirrorLevel = Int(CGWindowLevelForKey(.mainMenuWindow)) + 1
        let mirrors = [window("Panelet", 15, mirrorLevel, CGRect(x: 0, y: 0, width: 1280, height: 1440), id: 60),
                       window("Panelet", 15, mirrorLevel, CGRect(x: 1280, y: 0, width: 1280, height: 1440), id: 61)]
        let front = window("App", 21, pixPinLevel, popup, id: 62)
        assert(CaptureOverlays.canUseFrontSnapshot([front] + mirrors, mirrors: popupTarget.mirrorWindows))
        assert(!CaptureOverlays.canUseFrontSnapshot([front, mirrors[1]], mirrors: popupTarget.mirrorWindows),
               "An anchor that is no longer the backmost mirror must trigger a full snapshot")
        assert(!CaptureOverlays.canUseFrontSnapshot([regionSelector] + mirrors, mirrors: popupTarget.mirrorWindows),
               "Apple's screenshot UI may have a picker window behind the mirrors")
        func popups(_ windows: [[String: Any]], accessible: Bool = true) -> MouseRouter.CaptureRouting {
            CaptureOverlays.inspect(windows, on: [popupTarget], pixPinPIDs: [12], screenshotUIPIDs: [11]) { id, pid, _ in
                accessible && id == 62 && pid == 21
            }.routing
        }
        assert(popups([front] + mirrors).controls == [1: [popup]])
        assert(popups(mirrors + [front]).controls.isEmpty)
        assert(popups([front] + mirrors, accessible: false).controls.isEmpty)
        assert(popups([window("App", 21, pixPinLevel, popup.offsetBy(dx: 2560, dy: 0), id: 62)] + mirrors).controls.isEmpty)
        assert(popups([window("App", 21, pixPinLevel, physical, id: 62)] + mirrors).controls.isEmpty)
        assert(popups([front, regionSelector, windowSelection, appleToolbar] + mirrors).controls == [1: [toolbar]])

        var popupRoute = MouseRouter.Route(parked: [route.parked[0]], screens: [left, right], capture: popups([front] + mirrors))
        let popupPoint = CGPoint(x: 926, y: 44)
        let projectedPoint = CGPoint(x: 3486, y: 44)
        let desktopPoint = CGPoint(x: 3000, y: 50)
        assert(popupRoute.destination(for: desktopPoint, button: .down(0)) == nil)
        assert(popupRoute.destination(for: projectedPoint) == nil)
        assert(popupRoute.destination(for: projectedPoint, button: .up(0)) == nil)
        assert(popupRoute.destination(for: projectedPoint, button: .down(0)) == popupPoint)
        assert(popupRoute.setCaptureRouting(.init(), cursor: popupPoint) == nil)
        assert(popupRoute.destination(for: CGPoint(x: 850, y: 45)) == nil)
        assert(popupRoute.destination(for: CGPoint(x: 800, y: 45), button: .up(0)) == nil)
        assert(popupRoute.destination(for: CGPoint(x: 790, y: 45)) == CGPoint(x: 3350, y: 45))
        // Native hit tests must distinguish an interactive overlay from a visually
        // identical click-through window without consulting its accessibility tree.
        let native = CaptureOverlays.inspect([front] + mirrors, on: [popupTarget], pixPinPIDs: [],
                                             nativeHitTesting: true).routing
        assert(native.controls.isEmpty && native.nativeWindows[1]?.first?.id == 62)
        var nativeRoute = MouseRouter.Route(parked: [route.parked[0]], screens: [left, right],
                                            capture: native, hitTest: { _ in 62 })
        assert(nativeRoute.destination(for: projectedPoint) == popupPoint)
        nativeRoute.hitTest = { _ in 999 } // WindowServer passes through to a window below the mirrors.
        assert(nativeRoute.destination(for: popupPoint) == projectedPoint)
        nativeRoute.hitTest = { _ in nil } // An unavailable result must not grant the whole rectangle input.
        assert(nativeRoute.destination(for: projectedPoint) == nil)
        nativeRoute.hitTest = { _ in 62 }
        assert(nativeRoute.destination(for: projectedPoint, button: .down(0)) == popupPoint)
        nativeRoute.hitTest = { _ in nil } // Popup disappears during the press.
        assert(nativeRoute.setCaptureRouting(.init(), cursor: popupPoint) == nil)
        assert(nativeRoute.destination(for: popupPoint, button: .up(0)) == nil)
        assert(nativeRoute.destination(for: popupPoint) == projectedPoint)
        nativeRoute.capture = native
        nativeRoute.hitTest = { _ in 62 }
        assert(nativeRoute.destination(for: desktopPoint, button: .down(0)) == nil)
        assert(nativeRoute.destination(for: projectedPoint, button: .up(0)) == nil)
        let highPopup = window("Custom", 22, shielding + 50, popup, id: 63)
        assert(CaptureOverlays.inspect([highPopup] + mirrors, on: [popupTarget], pixPinPIDs: [],
                                     nativeHitTesting: true).routing.nativeWindows[1]?.first?.id == 63)
        let fullOverlay = window("Custom", 22, pixPinLevel, physical, id: 64)
        let fullNative = CaptureOverlays.inspect([fullOverlay] + mirrors, on: [popupTarget], pixPinPIDs: [],
                                                nativeHitTesting: true).routing
        assert(fullNative.allows(1, at: popupPoint, hitTest: { _ in 64 }))
        assert(!fullNative.allows(1, at: popupPoint, hitTest: { _ in 999 }))
        assert(CaptureOverlays.inspect(mirrors + [front], on: [popupTarget], pixPinPIDs: [],
                                      nativeHitTesting: true).routing.nativeWindows.isEmpty)
        assert(inspect(pixPinWindows + [regionSelector, appleToolbar]).shieldsByDisplay.isEmpty)
        let otherWindows = [
            window("Other", 14, shielding, left, id: 24),
            window("screencapture", 10, pixPinLevel, left, id: 25),
            window("screencapture", 10, shielding, right, id: 26, alpha: 0),
            window("screencapture", 10, shielding, left.union(right), id: 27),
            window("screencapture", 10, shielding, left.insetBy(dx: 12, dy: 12), id: 28),
        ]
        assert(inspect(otherWindows).shieldsByDisplay.isEmpty)
        let tallShield = window("screencapture", 10, shielding, lower.insetBy(dx: -1, dy: -1), id: 29)
        assert(inspect([tallShield]).shieldsByDisplay == [6: [29]])
        assert(inspect([]).shieldsByDisplay.isEmpty)

        var keys = PhysicalScreenScreenshot.KeyState()
        let standard: CGEventFlags = [.maskCommand, .maskShift]
        assert(keys.handle(keyCode: 20, flags: standard, down: true, repeated: false) == .pass)
        keys.enabled = true
        assert(keys.handle(keyCode: 20, flags: standard, down: true, repeated: false) == .capture(.file))
        assert(keys.handle(keyCode: 20, flags: standard, down: true, repeated: true) == .consume)
        assert(keys.handle(keyCode: 20, flags: [], down: false, repeated: false) == .consume)
        assert(keys.handle(keyCode: 20, flags: standard.union(.maskControl), down: true, repeated: false) == .capture(.clipboard))
        assert(keys.handle(keyCode: 20, flags: [], down: false, repeated: false) == .consume)
        keys.shortcuts = .init(entries: ["28": ["enabled": false], "29": ["enabled": true,
            "value": ["parameters": [51, 21, standard.rawValue]]]])
        assert(keys.handle(keyCode: 20, flags: standard, down: true, repeated: false) == .pass)
        assert(keys.handle(keyCode: 21, flags: standard, down: true, repeated: false) == .capture(.clipboard))
        let parked = MouseRouter.Parking(physical: physical, desktop: left.union(right), displayID: 1,
                                         mirrors: [.init(id: 60, frame: physical)])
        var synchronousHits = 0
        var hover = MouseRouter.Route(parked: [parked], screens: [left, right],
                                      liveHitTest: { _, _ in synchronousHits += 1; return true })
        let nextPoint = CGPoint(x: 3510, y: 50)
        assert(hover.destination(for: projectedPoint, passiveMotion: true) == nil)
        assert(hover.scheduleHover(at: projectedPoint, now: 100) == 0)
        guard let first = hover.hoverPending else { fatalError("Missing hover request") }
        assert(hover.destination(for: nextPoint, passiveMotion: true) == nil)
        assert(hover.scheduleHover(at: nextPoint, now: 200) == nil)
        guard let latest = hover.hoverPending else { fatalError("Missing replacement hover request") }
        assert(latest.source == nextPoint && !hover.acceptsHover(first) && hover.acceptsHover(latest))
        assert(synchronousHits == 0)
        assert(hover.destination(for: nextPoint, button: .down(0)) == CGPoint(x: 950, y: 50))
        assert(synchronousHits > 0 && !hover.acceptsHover(latest))
        assert(hover.scheduleHover(at: CGPoint(x: 950, y: 50), now: 300) == nil)

        let interactions = MouseRouter.mouseMask(observingMotion: true)
        assert(interactions & MouseRouter.motionMask == 0)
        assert(MouseRouter.mouseMask(observingMotion: false) == interactions | MouseRouter.motionMask)
        for type: CGEventType in [.leftMouseDown, .leftMouseDragged, .leftMouseUp,
                                  .rightMouseDown, .rightMouseDragged, .rightMouseUp,
                                  .otherMouseDown, .otherMouseDragged, .otherMouseUp, .scrollWheel] {
            assert(interactions & (1 << type.rawValue) != 0)
        }

        var observed = MouseRouter.Route(parked: [parked], screens: [left, right, other],
                                         liveHitTest: { _, _ in fatalError("Motion queried the window server") })
        let ordinaryPoint = CGPoint(x: 550, y: -10)
        let parkedPoint = CGPoint(x: 550, y: 15)
        let stamp: UInt64 = 100_000_000
        guard let ordinary = observed.observeMotion(at: ordinaryPoint, timestamp: stamp, now: stamp + 1) else {
            fatalError("Missing normal motion")
        }
        assert(ordinary.destination == nil && ordinary.hoverStart == nil)
        guard let boundary = observed.observeMotion(at: parkedPoint, timestamp: stamp + 2, now: stamp + 3) else {
            fatalError("Missing parking edge correction")
        }
        assert(boundary.destination == CGPoint(x: 550, y: -1) && observed.lastPoint == ordinaryPoint)
        assert(observed.observeMotion(at: parkedPoint, timestamp: stamp + 4, now: stamp + 5)?.destination == boundary.destination)
        assert(!observed.acceptsMove(revision: boundary.revision))
        assert(observed.destination(for: ordinaryPoint, button: .down(0), timestamp: stamp + 8) == nil)
        assert(observed.observeMotion(at: projectedPoint, timestamp: stamp + 9, now: stamp + 10) == nil)
        assert(observed.destination(for: ordinaryPoint, button: .up(0), timestamp: stamp + 12) == nil)
        assert(observed.observeMotion(at: projectedPoint, timestamp: stamp + 11, now: stamp + 13) == nil)
        assert(observed.observeMotion(at: projectedPoint, timestamp: stamp + 14, now: stamp + 50_000_000) == nil)
        assert(observed.observeMotion(at: projectedPoint, timestamp: stamp + 16, now: stamp + 15) == nil)
        guard let splitMotion = observed.observeMotion(at: projectedPoint, timestamp: stamp + 16, now: stamp + 17),
              let splitHover = observed.hoverPending else {
            fatalError("Missing hover after returning to the split")
        }
        assert(splitMotion.destination == nil && splitMotion.hoverStart != nil && observed.acceptsHover(splitHover))
        assert(observed.observeMotion(at: ordinaryPoint, timestamp: stamp + 18, now: stamp + 19)?.hoverStart == nil)
        assert(!observed.acceptsHover(splitHover))

        let selectorWindows = [
            window("PixPin", 12, pixPinLevel, physical, id: 70),
            window("PixPin", 12, pixPinLevel, left, id: 71),
            window("PixPin", 12, pixPinLevel, right, id: 72)
        ]
        let selectorScreens = [physical, left, right]
        assert(CaptureOverlays.pixPinSelectorWindows(selectorWindows, pid: 12, screens: selectorScreens) == [70, 71, 72])
        assert(CaptureOverlays.pixPinSelectorWindows(selectorWindows, pid: 13, screens: selectorScreens) == nil)
        assert(CaptureOverlays.pixPinSelectorWindows(Array(selectorWindows.dropLast()), pid: 12, screens: selectorScreens) == nil)

        var waiting = MouseRouter.Route(parked: [parked], screens: [left, right], liveHitTest: { _, _ in false })
        assert(waiting.reservePixPinPress(on: parked))
        assert(waiting.setCaptureRouting(.init(displays: [1]), cursor: projectedPoint) == nil)
        waiting.pixPinQueuedUntil = 120
        let queuedPoint = CGPoint(x: 4200, y: 90)
        assert(waiting.destination(for: queuedPoint, timestamp: 119) == CGPoint(x: 1640, y: 90))
        assert(waiting.destination(for: queuedPoint, timestamp: 121) == CGPoint(x: 2559, y: 90))
        assert(waiting.destination(for: queuedPoint, button: .up(0), timestamp: 122) == CGPoint(x: 2559, y: 90))
        assert(waiting.pixPinQueuedUntil == nil && waiting.gesturePanel == nil)
        assert(waiting.reservePixPinPress(on: parked))
        waiting.suppressPixPinPress()
        assert(waiting.discardSuppressedPixPinEvent(.leftMouseDragged))
        assert(!waiting.discardSuppressedPixPinEvent(.mouseMoved))
        assert(waiting.discardSuppressedPixPinEvent(.leftMouseUp))
        assert(waiting.pressedButtons.isEmpty && waiting.gesturePanel == nil)
        print("CaptureRouting: real-window picking, capture controls, recording shields and whole-screen shortcuts passed")
    }
}
