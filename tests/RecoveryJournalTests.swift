import AppKit

@main
struct RecoveryJournalTests {
    static func main() throws {
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
        do {
            _ = try JSONDecoder().decode(RecoveryJournal.self, from: Data("{broken".utf8))
            assertionFailure("A corrupt journal must fail instead of becoming an empty successful recovery")
        } catch {}
        print("RecoveryJournal: all assertions passed (no desktop or saved journal modified)")
    }
}
