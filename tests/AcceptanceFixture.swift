import AppKit

@main @MainActor enum Main {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = Fixture()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
@MainActor final class Fixture: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var windows: [NSWindow] = []
    var ticks = 0
    var events: [String] = []
    let name = Bundle.main.object(forInfoDictionaryKey: "FixtureName") as? String ?? "One"
    let directory = Bundle.main.bundleURL.deletingLastPathComponent()
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem(title: "QA", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit QA", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(appItem)
        let windowsItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window"); windowsItem.submenu = windowMenu
        menu.addItem(windowsItem); NSApp.mainMenu = menu; NSApp.windowsMenu = windowMenu
        for slot in 0..<2 {
            let w = NSWindow(contentRect: CGRect(x: 180 + slot * 480, y: 240, width: 440, height: 420), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "QA \(name) \(slot == 0 ? "Top" : "Bottom")"
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.fullScreenPrimary, .canJoinAllApplications]
            w.delegate = self
            let label = NSTextField(labelWithString: w.title)
            label.font = .systemFont(ofSize: 28, weight: .bold)
            let field = NSTextField(string: "可输入文字，验证输入是否独立")
            field.setAccessibilityLabel("验收输入框")
            field.widthAnchor.constraint(equalToConstant: 360).isActive = true
            let button = NSButton(title: "切换全屏", target: self, action: #selector(toggle(_:)))
            button.tag = slot
            let stack = NSStackView(views: [label, field, button]); stack.orientation = .vertical; stack.spacing = 24
            stack.translatesAutoresizingMaskIntoConstraints = false
            w.contentView!.addSubview(stack)
            NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: w.contentView!.centerXAnchor), stack.centerYAnchor.constraint(equalTo: w.contentView!.centerYAnchor)])
            w.backgroundColor = slot == 0 ? .systemTeal : .systemOrange
            windows.append(w); w.makeKeyAndOrderFront(nil)
        }
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.record() }
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func toggle(_ sender: NSButton) { windows[sender.tag].toggleFullScreen(nil) }
    func windowDidEnterFullScreen(_ n: Notification) { event("entered", n) }
    func windowDidExitFullScreen(_ n: Notification) { event("exited", n) }
    func event(_ name: String, _ n: Notification) { events.append("\(Date().timeIntervalSince1970) \(name) \((n.object as? NSWindow)?.title ?? "")") }
    func record() {
        ticks += 1
        let data: [String: Any] = ["ticks": ticks, "events": events, "windows": windows.map { w -> [String: Any] in
            let id = (w.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return ["title": w.title, "display": id, "fullScreen": w.styleMask.contains(.fullScreen), "visible": w.isVisible, "frame": [w.frame.minX, w.frame.minY, w.frame.width, w.frame.height]]
        }]
        if let json = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: directory.appendingPathComponent("fixture-\(name).json"), options: .atomic)
        }
    }
}
