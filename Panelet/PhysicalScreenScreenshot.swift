import Carbon.HIToolbox
import CoreGraphics
import Foundation

enum PhysicalScreenScreenshot {
    enum Destination: Equatable { case file, clipboard }

    struct Shortcut {
        static let modifiers: CGEventFlags = [.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]

        let keyCode: Int64
        let flags: CGEventFlags

        func matches(keyCode: Int64, flags: CGEventFlags) -> Bool {
            self.keyCode == keyCode && self.flags == flags.intersection(Self.modifiers)
        }
    }

    struct Shortcuts {
        let file: Shortcut?
        let clipboard: Shortcut?

        static func current() -> Shortcuts {
            let domain = "com.apple.symbolichotkeys" as CFString
            CFPreferencesAppSynchronize(domain)
            let entries = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any] ?? [:]
            return Shortcuts(entries: entries)
        }

        init(entries: [String: Any]) {
            func shortcut(_ id: String, defaultFlags: CGEventFlags) -> Shortcut? {
                guard let entry = entries[id] else { return Shortcut(keyCode: Int64(kVK_ANSI_3), flags: defaultFlags) }
                guard let entry = entry as? [String: Any], entry["enabled"] as? Bool == true,
                      let value = entry["value"] as? [String: Any],
                      let parameters = value["parameters"] as? [NSNumber], parameters.count == 3,
                      parameters[1].int64Value >= 0 else { return nil }
                let flags = CGEventFlags(rawValue: parameters[2].uint64Value).intersection(Shortcut.modifiers)
                return Shortcut(keyCode: parameters[1].int64Value, flags: flags)
            }
            // macOS symbolic hotkeys for full-screen capture and full-screen capture to Clipboard.
            file = shortcut("28", defaultFlags: [.maskCommand, .maskShift])
            clipboard = shortcut("29", defaultFlags: [.maskCommand, .maskShift, .maskControl])
        }
    }

    enum KeyResult: Equatable { case pass, consume, capture(Destination) }

    struct KeyState {
        var enabled = false
        var shortcuts = Shortcuts(entries: [:])
        private var consumed: Set<Int64> = []

        mutating func handle(keyCode: Int64, flags: CGEventFlags, down: Bool, repeated: Bool) -> KeyResult {
            guard down else { return consumed.remove(keyCode) == nil ? .pass : .consume }
            if consumed.contains(keyCode) { return .consume }
            guard enabled, !repeated else { return .pass }

            let destination: Destination
            if shortcuts.clipboard?.matches(keyCode: keyCode, flags: flags) == true {
                destination = .clipboard
            } else if shortcuts.file?.matches(keyCode: keyCode, flags: flags) == true {
                destination = .file
            } else {
                return .pass
            }
            consumed.insert(keyCode)
            return .capture(destination)
        }
    }

    private static let queue = DispatchQueue(label: "dev.cmkk.panelet.full-screen-screenshot", qos: .userInitiated)

    static func capture(_ destination: Destination) {
        queue.async {
            // Keep Apple's capture format, destination, and presentation settings.
            // The Clipboard variant takes the main physical panel.
            let physical = DisplayScanner.activeDisplayIDs().filter { CGDisplayVendorNumber($0) != DemoDisplay.vendorID }
            for (index, display) in physical.enumerated() {
                guard let screen = DisplayScanner.activeDisplayIDs().firstIndex(of: display) else { continue }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                var arguments = ["-p", "-D", "\(screen + 1)"]
                if destination == .clipboard { arguments.append("-c") }
                if index > 0 { arguments.append("-x") }
                process.arguments = arguments
                if (try? process.run()) != nil { process.waitUntilExit() }
                if destination == .clipboard { break }
            }
        }
    }
}
