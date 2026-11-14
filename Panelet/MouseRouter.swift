import CoreGraphics
import Foundation
import os

/// Keep the physical panels carrying the mirrors out of the pointer's path.
final class MouseRouter {
    struct Parking {
        let physical: CGRect
        let desktop: CGRect
    }

    private struct Route {
        var parked: [Parking] = []
        var screens: [CGRect] = []
        var lastPoint = CGPoint.zero
    }

    private let routing = OSAllocatedUnfairLock(initialState: Route())
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?

    func update(parked: [Parking], screens: [CGRect]) {
        let point = CGEvent(source: nil)?.location ?? .zero
        let parking = parked.first { $0.physical.contains(point) }
        let destination = parking.map {
            CGPoint(x: point.x - $0.physical.minX + $0.desktop.minX,
                    y: point.y - $0.physical.minY + $0.desktop.minY)
        }
        routing.withLock { $0 = Route(parked: parked, screens: screens, lastPoint: destination ?? point) }
        if let destination { CGWarpMouseCursorPosition(destination) }
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
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                if let context {
                    let router = Unmanaged<MouseRouter>.fromOpaque(context).takeUnretainedValue()
                    switch type {
                    case .tapDisabledByTimeout, .tapDisabledByUserInput:
                        if let tap = router.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    default:
                        router.route(event)
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

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

    private func route(_ event: CGEvent) {
        let point = event.location
        let clamped = routing.withLock { route -> CGPoint? in
            guard let parking = route.parked.first(where: { $0.physical.contains(point) }) else {
                route.lastPoint = point
                return nil
            }
            let previous = route.screens.first { $0.contains(route.lastPoint) } ?? parking.desktop
            let clamped = CGPoint(x: min(max(point.x, previous.minX), previous.maxX - 1),
                                  y: min(max(point.y, previous.minY), previous.maxY - 1))
            route.lastPoint = clamped
            return clamped
        }
        if let clamped {
            event.location = clamped
            CGWarpMouseCursorPosition(clamped)
        }
    }
}
