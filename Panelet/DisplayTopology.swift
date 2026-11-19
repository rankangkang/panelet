import CoreGraphics
import Foundation

/// Pure-value display topology state and coordinate planner for multi-monitor splits,
/// standby virtual display parking, and crash-recovery coordinate translation.
struct DisplayTopology: Equatable {
    struct VirtualRegion: Equatable {
        let physicalID: CGDirectDisplayID
        let offset: CGPoint
    }

    struct StandbyHalf: Equatable {
        let physicalID: CGDirectDisplayID
        let virtualID: CGDirectDisplayID
        let pointSize: CGSize
    }

    private(set) var originalScreens: [CGDirectDisplayID: PhysicalScreen] = [:]
    private(set) var originalDisplayUUIDs: [CGDirectDisplayID: String] = [:]
    private(set) var recoveryRegions: [CGDirectDisplayID: VirtualRegion] = [:]

    var isEmpty: Bool {
        originalScreens.isEmpty && originalDisplayUUIDs.isEmpty && recoveryRegions.isEmpty
    }

    mutating func reset() {
        originalScreens.removeAll()
        originalDisplayUUIDs.removeAll()
        recoveryRegions.removeAll()
    }

    mutating func recordBaseline(
        from physicalScreens: [PhysicalScreen],
        uuidProvider: (CGDirectDisplayID) -> String? = RecoveryJournal.uuid
    ) {
        for screen in physicalScreens where originalScreens[screen.id] == nil {
            originalScreens[screen.id] = screen
            if let uuid = uuidProvider(screen.id) {
                originalDisplayUUIDs[screen.id] = uuid
            }
        }
    }

    mutating func recordVirtualRegion(
        virtualID: CGDirectDisplayID,
        physicalID: CGDirectDisplayID,
        offset: CGPoint
    ) {
        recoveryRegions[virtualID] = VirtualRegion(physicalID: physicalID, offset: offset)
    }

    func logicalBounds(for id: CGDirectDisplayID, mainID: CGDirectDisplayID) -> CGRect? {
        guard let screen = originalScreens[id] else { return nil }
        guard let anchor = originalScreens[mainID] else { return screen.bounds }
        return screen.bounds.offsetBy(dx: -anchor.bounds.minX, dy: -anchor.bounds.minY)
    }

    func checkpointDisplays() -> [RecoveryJournal.Display] {
        originalDisplayUUIDs.compactMap { id, uuid in
            originalScreens[id].map { RecoveryJournal.Display(uuid: uuid, bounds: $0.bounds) }
        }.sorted { $0.uuid < $1.uuid }
    }

    func recoveryTarget(for savedDisplayID: CGDirectDisplayID) -> (display: RecoveryJournal.Display, origin: CGPoint)? {
        let region = recoveryRegions[savedDisplayID]
        let physicalID = region?.physicalID ?? savedDisplayID
        guard let uuid = originalDisplayUUIDs[physicalID],
              let original = originalScreens[physicalID] else { return nil }
        let offset = region?.offset ?? .zero
        let origin = CGPoint(x: original.bounds.minX + offset.x, y: original.bounds.minY + offset.y)
        return (RecoveryJournal.Display(uuid: uuid, bounds: original.bounds), origin)
    }

    func arrangedFrames(
        currentPhysical: [PhysicalScreen],
        mainID: CGDirectDisplayID,
        activeHalves: [CGDirectDisplayID: [CGDirectDisplayID: CGRect]],
        standbyHalves: [StandbyHalf]
    ) -> [CGDirectDisplayID: CGRect] {
        let physical = Dictionary(uniqueKeysWithValues: currentPhysical.map { screen in
            (screen.id, logicalBounds(for: screen.id, mainID: mainID) ?? screen.bounds)
        })
        var layout = DisplayScanner.splitDisplayFrames(physical: physical, main: mainID, halves: activeHalves)
        let rightmost = layout.values.max {
            if $0.maxX != $1.maxX { return $0.maxX < $1.maxX }
            return $0.minY < $1.minY
        }
        var occupied = Array(layout.values)
        let groupedStandby = Dictionary(grouping: standbyHalves, by: \.physicalID)
        for id in groupedStandby.keys.sorted() {
            guard let halves = groupedStandby[id] else { continue }
            var anchor = layout[id] ?? rightmost ?? .zero
            for half in halves {
                anchor = DisplayScanner.parkingFrame(size: half.pointSize, beside: anchor, avoiding: occupied)
                layout[half.virtualID] = anchor
                occupied.append(anchor)
            }
        }
        return layout
    }
}

extension PhysicalScreen: Equatable {
    static func == (lhs: PhysicalScreen, rhs: PhysicalScreen) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.bounds == rhs.bounds
            && lhs.scale == rhs.scale
            && lhs.refreshRate == rhs.refreshRate
            && lhs.isBuiltin == rhs.isBuiltin
            && lhs.configuration == rhs.configuration
    }
}
