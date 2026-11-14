import Foundation

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
}
