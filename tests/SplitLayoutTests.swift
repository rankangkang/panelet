import CoreGraphics
import Foundation

@main
struct SplitLayoutTests {
    static func main() {
        for size in [CGSize(width: 1296, height: 2304), CGSize(width: 2305, height: 1296),
                     CGSize(width: 1296, height: 2305), CGSize(width: 1000, height: 1000)] {
            let layout = SplitLayout(size: size)
            let parts = layout.regions
            assert(parts.count == 2)
            assert(parts[0].intersection(parts[1]).isEmpty)
            assert(parts[0].union(parts[1]) == CGRect(origin: .zero, size: size))
            assert(parts.allSatisfy { $0.width > 0 && $0.height > 0 })
            if size.height > size.width {
                assert(parts[1].minX == 0 && parts[1].minY == floor(size.height / 2))
                assert(layout.roles == ["top", "bottom"])
            } else {
                assert(parts[1].minY == 0 && parts[1].minX == floor(size.width / 2))
                assert(layout.roles == ["left", "right"])
            }
            // The second partition survives migration and merge even at a negative desktop origin.
            let physical = CGPoint(x: -2305, y: -600)
            let virtual = CGPoint(x: 9000, y: 1000)
            let local = parts[1].origin
            let original = CGRect(x: physical.x + local.x + 10, y: physical.y + local.y + 20, width: 300, height: 200)
            let moved = original.offsetBy(dx: virtual.x - physical.x - local.x, dy: virtual.y - physical.y - local.y)
            assert(moved.offsetBy(dx: physical.x + local.x - virtual.x, dy: physical.y + local.y - virtual.y) == original)
        }
        let primary = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let right = CGRect(x: 2560, y: 310, width: 1920, height: 1080)
        let left = CGRect(x: -1920, y: -320, width: 1920, height: 1080)
        let halves: [CGDirectDisplayID: CGRect] = [3: CGRect(x: 0, y: 0, width: 1280, height: 1440),
                                                   4: CGRect(x: 1280, y: 0, width: 1280, height: 1440)]
        let original: [CGDirectDisplayID: CGRect] = [1: primary, 2: right, 5: left]
        let split = DisplayScanner.splitDisplayFrames(physical: original, main: 1, halves: [1: halves])
        assert(split[1] == primary)
        assert(split[5]?.maxX == split[3]?.minX && split[4]?.maxX == split[2]?.minX)
        assert(split[3]?.minY == 0 && split[2]?.minY == 310 && split[5]?.minY == -320)
        assert(DisplayScanner.splitDisplayFrames(physical: original, main: 1, halves: [:]) == original)
        print("SplitLayout: split geometry, adjacent monitors and restoration of original positions passed")
    }
}
