import AppKit

/// Seeds only disposable QA windows for a normal-launch recovery test.
/// Refuses to overwrite an existing journal or run while virtual displays exist.
@main
struct SeedRecoveryFixture {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Pass a QA fixture snapshot") }
        guard try RecoveryJournal.load() == nil else { fatalError("An existing recovery journal must not be replaced") }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let snapshot = try JSONSerialization.jsonObject(with: Data(contentsOf: source)) as! [String: Any]
        let pid = (snapshot["pid"] as! NSNumber).int32Value
        guard let app = NSRunningApplication(processIdentifier: pid),
              app.bundleIdentifier?.hasPrefix("dev.cmkk.panelet.qa.") == true,
              let launchDate = app.launchDate,
              abs(launchDate.timeIntervalSinceReferenceDate - (snapshot["launchDate"] as! Double)) < 0.001 else {
            fatalError("Snapshot does not belong to a currently running QA fixture")
        }
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        guard ids.allSatisfy({ CGDisplayVendorNumber($0) != 0x5653 }) else { fatalError("Restore all splits before this test") }
        let displays = ids.map { RecoveryJournal.Display(uuid: RecoveryJournal.uuid($0)!, bounds: CGDisplayBounds($0)) }
        let height = CGDisplayBounds(CGMainDisplayID()).height
        let windows = (snapshot["windows"] as! [[String: Any]]).map { value -> RecoveryJournal.Window in
            precondition(value["fullScreen"] as? Bool == false)
            let display = (value["display"] as! NSNumber).uint32Value
            precondition(ids.contains(display))
            let frame = value["frame"] as! [Double]
            return RecoveryJournal.Window(number: (value["windowID"] as! NSNumber).uint32Value,
                pid: pid, launchDate: launchDate, displayUUID: RecoveryJournal.uuid(display)!,
                displayBounds: CGDisplayBounds(display),
                frame: CGRect(x: frame[0], y: height - frame[1] - frame[3], width: frame[2], height: frame[3]),
                fullScreen: false, minimized: false, hidden: false)
        }
        try RecoveryJournal(displays: displays, windows: windows).save()
        print("Seeded a recovery record for \(windows.count) disposable QA windows only")
    }
}
