import AppKit

@main
struct RecoveryJournalTests {
    static func main() async throws {
        let bounds = CGRect(x: -1296, y: -400, width: 1296, height: 2304)
        let frame = CGRect(x: -1200, y: 900, width: 1000, height: 700)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let journal = RecoveryJournal(displays: [.init(uuid: "display-A", bounds: bounds)], windows: [
            .init(number: 42, pid: 123, launchDate: date, displayUUID: "display-A", displayBounds: bounds,
                  frame: frame, fullScreen: true, minimized: false, hidden: true)
        ])
        let data = try JSONEncoder().encode(journal)
        let decoded = try JSONDecoder().decode(RecoveryJournal.self, from: data)
        assert(decoded.displays.count == 1 && decoded.displays[0].bounds == bounds)
        assert(decoded.windows.count == 1)
        let saved = decoded.windows[0]
        assert(saved.number == 42 && saved.pid == 123 && saved.launchDate == date)
        assert(saved.displayBounds == bounds && saved.frame == frame)
        assert(saved.fullScreen && !saved.minimized && saved.hidden)
        assert(saved.frame(on: bounds.offsetBy(dx: 500, dy: -100)) == frame.offsetBy(dx: 500, dy: -100))

        let main = RecoveryJournal.Display(uuid: "main", bounds: CGRect(x: 0, y: 0, width: 2048, height: 1152))
        let layout = RecoveryJournal(displays: [main, decoded.displays[0]], windows: [])
        let parked = RecoveryJournal.Display(uuid: "display-A", bounds: bounds.offsetBy(dx: 0, dy: 2304))
        let current: [CGDirectDisplayID: RecoveryJournal.Display] = [12: main, 87: parked]
        assert(layout.originalLayout(on: current, main: 12) == [12: main.bounds, 87: bounds])
        assert(layout.originalLayout(on: current, main: 87) == nil)
        assert(layout.originalLayout(on: [12: main], main: 12) == nil)
        let resized = RecoveryJournal.Display(uuid: parked.uuid, bounds: parked.bounds.insetBy(dx: 10, dy: 10))
        assert(layout.originalLayout(on: [12: main, 87: resized], main: 12) == nil)

        func ordinary(_ id: CGWindowID) -> RecoveryJournal.Window {
            .init(number: id, pid: saved.pid, launchDate: date, displayUUID: saved.displayUUID, displayBounds: bounds,
                  frame: frame, fullScreen: false, minimized: false, hidden: false)
        }
        let mixed = RecoveryJournal(displays: layout.displays, windows: [saved, ordinary(43), ordinary(44), ordinary(45)])
        let result = await mixed.recoverWindows { record in
            switch record.number {
            case 42: .restored
            case 43: .waitingForDisplay
            case 44: .retry
            default: .closed
            }
        }
        assert(result.restored == 1 && result.waitingForDisplay == 1 && result.failed == 1)
        let pending = RecoveryJournal(displays: [], windows: result.pending)
        let retry = try JSONDecoder().decode(RecoveryJournal.self, from: JSONEncoder().encode(pending))
        assert(retry.windows == [ordinary(43), ordinary(44)])
        let finished = await retry.recoverWindows { _ in .restored }
        assert(finished.restored == 2 && finished.pending.isEmpty)

        do {
            _ = try JSONDecoder().decode(RecoveryJournal.self, from: Data("{broken".utf8))
            assertionFailure("A corrupt journal must fail instead of becoming an empty successful recovery")
        } catch {}
        print("RecoveryJournal: all assertions passed (no desktop or saved journal modified)")
    }
}
