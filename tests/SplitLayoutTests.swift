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
        let displays = [CGRect(x: -1000, y: -400, width: 1000, height: 2000),
                        CGRect(x: 0, y: 0, width: 2000, height: 1000),
                        CGRect(x: 0, y: 1000, width: 1000, height: 2000)]
        let diagram = DisplayScanner.arrangementFrames(displays, in: CGRect(x: 0, y: 0, width: 300, height: 340))
        assert(diagram.count == 3 && diagram[0].maxX == diagram[1].minX)
        assert(diagram[1].maxY == diagram[2].minY && diagram[0].minY < diagram[1].minY)
        assert(diagram[0].height == diagram[0].width * 2 && diagram[1].width == diagram[1].height * 2)
        assert(DisplayScanner.arrangementFrames([], in: .zero).isEmpty)
        assert(DisplayScanner.arrangementFrames(displays, in: .zero).allSatisfy { $0 == .zero })

        // Coordinate-space wrapper round-trip tests (including negative secondary monitor offsets).
        let mainHeight: CGFloat = 1440
        for sample in [
            CGRect(x: 0, y: 0, width: 2560, height: 1440),
            CGRect(x: -1920, y: -320, width: 1920, height: 1080),
            CGRect(x: 2560, y: 600, width: 1280, height: 1440),
        ] {
            let cocoa = QuartzRect(sample).toCocoa(mainDisplayHeight: mainHeight)
            assert(cocoa.toQuartz(mainDisplayHeight: mainHeight).rawValue == sample)
        }
        assert(QuartzRect(CGRect(x: 100, y: 40, width: 800, height: 600)).toCocoa(mainDisplayHeight: 1440).rawValue
            == CGRect(x: 100, y: 800, width: 800, height: 600))

        // DisplayTopology multi-monitor baseline, recovery mapping, and standby parking tests.
        var topology = DisplayTopology()
        let screenA = PhysicalScreen(id: 1, name: "Main", bounds: primary, scale: 2, refreshRate: 60, isBuiltin: true)
        let screenB = PhysicalScreen(id: 2, name: "Side", bounds: right, scale: 2, refreshRate: 120, isBuiltin: false)
        topology.recordBaseline(from: [screenA, screenB]) { id in "uuid-\(id)" }
        assert(!topology.isEmpty)
        assert(topology.checkpointDisplays().map(\.uuid) == ["uuid-1", "uuid-2"])
        topology.recordVirtualRegion(virtualID: 4, physicalID: 1, offset: CGPoint(x: 1280, y: 0))
        let target = topology.recoveryTarget(for: 4)
        assert(target?.display.uuid == "uuid-1" && target?.origin == CGPoint(x: 1280, y: 0))
        assert(topology.recoveryTarget(for: 2)?.origin == right.origin)

        let arranged = topology.arrangedFrames(
            currentPhysical: [screenA, screenB],
            mainID: 1,
            activeHalves: [1: halves],
            standbyHalves: [
                .init(physicalID: 2, virtualID: 7, pointSize: CGSize(width: 960, height: 1080)),
                .init(physicalID: 2, virtualID: 8, pointSize: CGSize(width: 960, height: 1080)),
            ]
        )
        assert(arranged[7] != nil && arranged[8] != nil)
        assert(arranged[7]!.intersection(arranged[8]!).isEmpty, "Standby virtual displays must never overlap")
        for activeID: CGDirectDisplayID in [1, 2, 3, 4] {
            assert(arranged[activeID]!.intersection(arranged[7]!).isEmpty)
            assert(arranged[activeID]!.intersection(arranged[8]!).isEmpty)
        }
        topology.reset()
        assert(topology.isEmpty)

        print("SplitLayout: split geometry, coordinate wrappers, topology parking and restoration passed")
    }
}
