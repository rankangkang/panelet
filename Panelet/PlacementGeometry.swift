import CoreGraphics
import Foundation

/// Explicit coordinate-space wrappers so CoreGraphics/Accessibility rects (top-left origin,
/// y downward) and AppKit screen/window rects (bottom-left origin, y upward) never mix silently.
struct QuartzRect: Equatable, Sendable {
    let rawValue: CGRect

    init(_ rawValue: CGRect) {
        self.rawValue = rawValue
    }

    func toCocoa(mainDisplayHeight: CGFloat = CGDisplayBounds(CGMainDisplayID()).height) -> CocoaRect {
        CocoaRect(CGRect(
            x: rawValue.minX,
            y: mainDisplayHeight - rawValue.maxY,
            width: rawValue.width,
            height: rawValue.height
        ))
    }
}

struct CocoaRect: Equatable, Sendable {
    let rawValue: CGRect

    init(_ rawValue: CGRect) {
        self.rawValue = rawValue
    }

    func toQuartz(mainDisplayHeight: CGFloat = CGDisplayBounds(CGMainDisplayID()).height) -> QuartzRect {
        QuartzRect(CGRect(
            x: rawValue.minX,
            y: mainDisplayHeight - rawValue.maxY,
            width: rawValue.width,
            height: rawValue.height
        ))
    }
}

enum ScreenCoordinates {
    static func cocoaFrame(forQuartz rect: CGRect) -> CGRect {
        QuartzRect(rect).toCocoa().rawValue
    }

    static func quartzFrame(forCocoa rect: CGRect) -> CGRect {
        CocoaRect(rect).toQuartz().rawValue
    }
}

enum PlacementGeometry {
    static func centeredOrigin(for frame: CGRect, in target: CGRect) -> CGPoint {
        CGPoint(x: target.midX - frame.width / 2, y: target.midY - frame.height / 2)
    }

    /// A window too large to resize must still unambiguously belong to the intended screen
    /// before requesting native full screen. Ties with another display are not accepted.
    static func belongs(_ frame: CGRect, to target: CGRect, otherDisplays: [CGRect]) -> Bool {
        guard !frame.isEmpty, target.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return false }
        func area(_ rect: CGRect) -> CGFloat { rect.isNull || rect.isEmpty ? 0 : rect.width * rect.height }
        let overlap = area(frame.intersection(target))
        return overlap > 0 && otherDisplays.allSatisfy { overlap > area(frame.intersection($0)) }
    }

    /// Accepts a stable size constraint when the window reaches its intended position or a
    /// larger size forces it away from an edge. An already overhanging position still needs restoring.
    static func settledConstrainedRestore(
        desired: CGRect,
        actual: CGRect,
        previousAttempt: CGRect?,
        displayBounds: CGRect,
        visibleBounds: CGRect
    ) -> Bool {
        guard !actual.isEmpty,
              displayBounds.contains(CGPoint(x: actual.midX, y: actual.midY)),
              let previousAttempt,
              abs(previousAttempt.minX - actual.minX) <= 2,
              abs(previousAttempt.minY - actual.minY) <= 2,
              abs(previousAttempt.width - actual.width) <= 2,
              abs(previousAttempt.height - actual.height) <= 2 else {
            return false
        }
        func positionRestored(origin: CGFloat, length: CGFloat, actualOrigin: CGFloat, actualLength: CGFloat,
                              in ranges: [ClosedRange<CGFloat>]) -> Bool {
            if abs(actualOrigin - origin) <= 2 { return true }
            guard actualLength - length > 2 else { return false }
            return ranges.contains { range in
                let edgeOrigin = max(range.lowerBound, range.upperBound - actualLength)
                return range.contains(origin) && origin + length <= range.upperBound
                    && edgeOrigin < origin && abs(actualOrigin - edgeOrigin) <= 2
            }
        }

        return positionRestored(origin: desired.minX, length: desired.width,
                                actualOrigin: actual.minX, actualLength: actual.width,
                                in: [displayBounds.minX...displayBounds.maxX, visibleBounds.minX...visibleBounds.maxX])
            && positionRestored(origin: desired.minY, length: desired.height,
                                actualOrigin: actual.minY, actualLength: actual.height,
                                in: [displayBounds.minY...displayBounds.maxY, visibleBounds.minY...visibleBounds.maxY])
    }
}
