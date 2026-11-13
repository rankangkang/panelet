import AppKit
import Carbon.HIToolbox

@main
@MainActor
enum DemoMain {
    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--list") {
            DisplayScanner.printList()
            return
        }
        let controller = AppController()
        app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let splits = SplitSessions()
    private let quick = QuickSplitPanel()
    private var window: NSWindow!
    private var popup: NSPopUpButton!
    private var statusLabel: NSTextField!
    private var splitButton: NSButton!
    private var joinButton: NSButton!
    private var screenRecordingLabel: NSTextField!
    private var accessibilityLabel: NSTextField!
    private var spacesLabel: NSTextField!
    private var logView: NSTextView!
    private var portraits: [PhysicalScreen] = []
    private var lastScreenKey = ""
    private var closing = false
    private var confirming = false
    private var confirmationPanel: NSPanel?
    private var shouldRelaunch = false
    private let shortcuts = GlobalShortcuts()
    private var shortcutButtons: [GlobalShortcuts.Command: NSButton] = [:]
    private let shortcutInfo = NSTextField(wrappingLabelWithString: "")
    private var recordingShortcut: GlobalShortcuts.Command?
    private var shortcutMonitor: Any?
    private var toggleMenuItem: NSMenuItem?
    private var joinMenuItem: NSMenuItem?
    private var statusItem: NSStatusItem?
    private var statusAction: NSMenuItem?
    private var statusJoin: NSMenuItem?
    private var pendingQuick: (displayID: CGDirectDisplayID, pair: WindowPlacement.Pair)?
    private var recentPairs: [CGDirectDisplayID: WindowPlacement.Pair] = [:]
    private var recentDisplayID: CGDirectDisplayID?
    private var displayMessages: [CGDirectDisplayID: String] = [:]
    private var previousApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        buildMenu()
        buildStatusItem()
        quick.onAdvanced = { [weak self] in self?.showAdvanced() }
        quick.onCancel = { [weak self] in self?.dismissQuick() }
        quick.onJoin = { [weak self] in self?.chooseJoin() }
        quick.onSplit = { [weak self] id, pair in self?.splitQuick(displayID: id, pair: pair) }
        DemoLog.shared.onLine = { [weak self] line in
            self?.appendLog(line)
        }
        splits.onChange = { [weak self] session in self?.sessionChanged(session) }
        shortcuts.onPress = { [weak self] command in self?.shortcutPressed(command) }
        let unavailableShortcuts = shortcuts.start()
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return handleShortcutKeyDown(event)
        }
        updateShortcutControls()
        shortcutInfo.stringValue = shortcutInstructions
        if !unavailableShortcuts.isEmpty { DemoLog.shared.line(shortcutInstructions) }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
        logStartup()
        Task {
            await splits.recoverPreviousSession()
            refresh()
            if splits.recoveryProblem != nil { showAdvanced() }
            else { showQuick() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if closing { return splits.sessions.isEmpty ? .terminateNow : .terminateCancel }
        guard !splits.sessions.isEmpty else { return .terminateNow }
        requestQuit(relaunch: false)
        return .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !splits.busy && !confirming { showQuick() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
        shortcuts.stop()
        guard shouldRelaunch else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "/bin/sleep 0.6; /usr/bin/open \"$1\"", "relaunch", Bundle.main.bundlePath]
        try? task.run()
    }

    private func buildMenu() {
        let menu = NSMenu()
        let app = NSMenuItem()
        menu.addItem(app)
        let commands = NSMenu()
        app.submenu = commands
        let toggle = commands.addItem(withTitle: "快捷上下分屏…", action: #selector(openQuick), keyEquivalent: "")
        toggle.target = self
        toggleMenuItem = toggle
        let settings = commands.addItem(withTitle: "拆分桌面与设置…", action: #selector(showAdvanced), keyEquivalent: ",")
        settings.target = self
        let join = commands.addItem(withTitle: "还原分屏…", action: #selector(chooseJoin), keyEquivalent: "")
        join.target = self
        joinMenuItem = join
        let retry = commands.addItem(withTitle: "重试恢复窗口…", action: #selector(retryRecovery), keyEquivalent: "")
        retry.target = self
        let quit = commands.addItem(withTitle: "退出 Panelet", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        NSApp.mainMenu = menu
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(named: "MenuBarTemplate")
        image?.size = NSSize(width: 18, height: 18)
        image?.isTemplate = true
        item.button?.image = image
        item.button?.setAccessibilityLabel("Panelet")
        if image == nil { item.button?.title = "Panelet" }
        let menu = NSMenu()
        let toggle = menu.addItem(withTitle: "快捷上下分屏…", action: #selector(openQuick), keyEquivalent: "")
        toggle.target = self
        let join = menu.addItem(withTitle: "还原分屏…", action: #selector(chooseJoin), keyEquivalent: "")
        join.target = self
        let settings = menu.addItem(withTitle: "拆分桌面与设置…", action: #selector(showAdvanced), keyEquivalent: "")
        settings.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出 Panelet", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        item.menu = menu
        statusItem = item
        statusAction = toggle
        statusJoin = join
        let retry = menu.addItem(withTitle: "重试恢复窗口…", action: #selector(retryRecovery), keyEquivalent: "")
        retry.target = self
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Panelet · 拆分桌面与设置"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let title = NSTextField(labelWithString: "拆分桌面")
        title.font = .systemFont(ofSize: 20, weight: .semibold)

        let subtitle = NSTextField(wrappingLabelWithString: "长期使用上下两个独立桌面，退出应用全屏不会合并。临时组合两个窗口，请使用“快捷上下分屏”。")
        subtitle.preferredMaxLayoutWidth = 490
        subtitle.textColor = .secondaryLabelColor

        popup = NSPopUpButton()
        popup.target = self
        popup.action = #selector(displayChanged)

        statusLabel = NSTextField(wrappingLabelWithString: "未拆分")
        statusLabel.preferredMaxLayoutWidth = 490
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)

        splitButton = button("拆分桌面", action: #selector(splitClicked))
        joinButton = button("还原桌面…", action: #selector(joinClicked))
        let relaunchButton = button("重新启动", action: #selector(relaunch))
        let quickButton = button("快捷上下分屏…", action: #selector(openQuick))
        let buttonRow = NSStackView(views: [splitButton, joinButton, quickButton, relaunchButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let shortcutRow = NSStackView(views: GlobalShortcuts.Command.allCases.map { command in
            let recorder = button(command.defaultKey.label, action: #selector(recordShortcut(_:)))
            recorder.tag = command.rawValue
            shortcutButtons[command] = recorder
            return labeled(command.title, recorder)
        })
        shortcutRow.alignment = .centerY
        shortcutRow.spacing = 14
        shortcutInfo.preferredMaxLayoutWidth = 490
        shortcutInfo.textColor = .secondaryLabelColor
        shortcutInfo.font = .systemFont(ofSize: 11)

        screenRecordingLabel = NSTextField(labelWithString: "屏幕录制：检查中")
        accessibilityLabel = NSTextField(labelWithString: "辅助功能：检查中")
        let recordButton = button("授权屏幕录制", action: #selector(askScreenRecording))
        let accessButton = button("授权辅助功能", action: #selector(askAccessibility))
        let spacesButton = button("打开桌面设置", action: #selector(openDesktopSettings))

        spacesLabel = NSTextField(wrappingLabelWithString: "")
        spacesLabel.preferredMaxLayoutWidth = 490
        spacesLabel.textColor = .secondaryLabelColor

        logView = NSTextView()
        logView.isEditable = false
        logView.isSelectable = true
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textColor = .labelColor
        logView.drawsBackground = false
        logView.textContainerInset = NSSize(width: 6, height: 6)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = logView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 164).isActive = true

        let stack = NSStackView(views: [
            title,
            subtitle,
            labeled("竖屏", popup),
            statusLabel,
            buttonRow,
            shortcutRow,
            shortcutInfo,
            labeled("权限", screenRecordingLabel),
            recordButton,
            accessibilityLabel,
            accessButton,
            spacesLabel,
            spacesButton,
            NSTextField(labelWithString: "日志"),
            scroll
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 490).isActive = true
        popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        window.contentView = container
    }

    private func logStartup() {
        DemoLog.shared.line("Demo 启动。下面是当前的物理显示器：")
        for screen in DisplayScanner.physicalScreens() {
            let orientation = screen.isPortrait ? "竖屏" : "横屏"
            DemoLog.shared.line("\(screen.menuTitle)  \(orientation)  id=\(screen.id)")
        }
        if DisplayScanner.portraitScreens().isEmpty {
            DemoLog.shared.line("没有竖屏。到“系统设置 → 显示器”把一块屏幕旋转 90° 或 270°。")
        }
        if !Permissions.separateSpacesEnabled {
            DemoLog.shared.line("“显示器使用不同的空间”是关闭的。打开后，两个半屏才会各自拥有菜单栏、全屏空间和调度中心。")
        }
    }

    private func refresh() {
        splits.checkActive()
        if !splits.busy {
            if quick.isVisible { quick.setProblem(splitProblem) }
            let screens = splits.screens()
            let key = screens.map { "\($0.id):\($0.bounds):\(splits.sessions[$0.id]?.active == true):\(splits.sessions[$0.id]?.hasQuick == true):\(splits.sessions[$0.id]?.needsRecovery == true)" }.joined(separator: "|")
            if key != lastScreenKey {
                lastScreenKey = key
                reloadPopup(screens)
                if quick.isVisible {
                    quick.updateDisplays(screens, activePairs: activePairs, excluded: managedWindows)
                }
            }
        }
        screenRecordingLabel.stringValue = Permissions.screenRecording ? "屏幕录制：已授权" : "屏幕录制：未授权"
        accessibilityLabel.stringValue = Permissions.accessibility ? "辅助功能：已授权" : "辅助功能：未授权"
        if Permissions.separateSpacesEnabled {
            spacesLabel.stringValue = "显示器使用不同的空间：已打开"
        } else {
            spacesLabel.stringValue = "显示器使用不同的空间：关闭。打开后请重新登录。"
        }
        applySessionState()
    }

    private func reloadPopup(_ screens: [PhysicalScreen]) {
        let previous = selectedDisplayID()
        portraits = screens.filter(\.isPortrait)
        popup.removeAllItems()
        if portraits.isEmpty {
            popup.addItem(withTitle: "没有竖屏显示器")
            return
        }
        for screen in portraits {
            let session = splits.sessions[screen.id]
            let mode = session?.hasQuick == true ? "快捷全屏" : "桌面拆分"
            let label = session?.active == true ? "\(screen.menuTitle) · \(mode)" : screen.menuTitle
            popup.addItem(withTitle: label)
            popup.lastItem?.representedObject = NSNumber(value: screen.id)
        }
        if let previous, let index = portraits.firstIndex(where: { $0.id == previous }) {
            popup.selectItem(at: index)
        }
    }

    private func applySessionState() {
        let id = selectedDisplayID()
        let session = id.flatMap { splits.sessions[$0] }
        let problem = splitProblem
        if let transition = splits.transition {
            statusLabel.stringValue = "\(transition.name) · \(transition.status)"
        } else {
            statusLabel.stringValue = session?.status ?? id.flatMap { displayMessages[$0] } ?? problem ?? "未拆分"
        }
        let available = !splits.busy && !closing && !confirming
        splitButton.isEnabled = id != nil && problem == nil && available && session == nil
        popup.isEnabled = id != nil && available
        joinButton.isEnabled = available && session?.active == true
        let action = "快捷上下分屏…"
        statusAction?.title = shortcuts.isRegistered(.toggle) ? "\(action)  \(shortcuts.key(for: .toggle).label)" : action
        statusAction?.isEnabled = available
        statusJoin?.isEnabled = available && !splits.active.isEmpty
        joinMenuItem?.isEnabled = statusJoin?.isEnabled == true
    }

    private var activePairs: [CGDirectDisplayID: [WindowPlacement.Choice]] {
        Dictionary(uniqueKeysWithValues: splits.active.map { ($0.targetID, $0.selectedChoices) })
    }

    private var splitProblem: String? {
        splits.recoveryProblem ?? (splits.sessions.values.contains(where: \.needsRecovery)
            ? "有分屏尚未完全恢复，请先从菜单选择“重试恢复窗口…”。" : Permissions.splitProblem)
    }

    private var managedWindows: [WindowPlacement.Identity] {
        splits.active.flatMap(\.managedWindows)
    }

    private func selectedDisplayID() -> CGDirectDisplayID? {
        (popup.selectedItem?.representedObject as? NSNumber)?.uint32Value
    }

    private func showQuick() {
        guard !splits.busy, !closing, !confirming else { return }
        let screens = splits.screens()
        let pointer = CGEvent(source: nil)?.location
        let pointedScreen = pointer.flatMap { point in screens.first { $0.bounds.contains(point) } }
        let host = splits.hostScreen(at: pointer)
        let available = screens.filter { $0.isPortrait && (splits.sessions[$0.id] == nil || splits.sessions[$0.id]?.canStartQuick == true) }
        let preferred = [pointedScreen?.id, recentDisplayID, selectedDisplayID()].compactMap { $0 }
            .first { id in available.contains { $0.id == id } }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() {
            previousApp = front
        }
        window.orderOut(nil)
        quick.show(screens: screens, displayID: preferred, host: host,
                   activePairs: activePairs, recentPairs: recentPairs, excluded: managedWindows, problem: splitProblem)
    }

    private func dismissQuick() {
        if splits.busy {
            if pendingQuick != nil { splits.cancelPreparation() }
            return
        }
        quick.hide()
        if NSApp.isActive { previousApp?.activate() }
        previousApp = nil
    }

    @objc private func toggleQuick() {
        guard !splits.busy, !confirming, !closing else { return }
        if quick.isFocused { dismissQuick() }
        else { showQuick() }
    }

    @objc private func openQuick() { showQuick() }

    @objc private func showAdvanced() {
        guard !confirming else { return }
        quick.hide()
        if let screen = splits.hostScreen(at: nil), !window.isVisible || window.screen != screen {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                          y: visible.midY - window.frame.height / 2))
        }
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .canJoinAllApplications]
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func splitQuick(displayID: CGDirectDisplayID, pair: WindowPlacement.Pair) {
        guard !splits.busy, splitProblem == nil, !confirming, !closing, (splits.sessions[displayID] == nil || splits.sessions[displayID]?.canStartQuick == true) else { return }
        pendingQuick = (displayID, pair)
        splits.split(displayID, pair: pair)
    }

    private func sessionChanged(_ session: Session) {
        if session.idle || session.active { displayMessages[session.targetID] = session.status }
        applySessionState()
        if let request = pendingQuick, request.displayID == session.targetID {
            if session.active && session.hasQuick && !session.failed && !session.needsRecovery {
                recentPairs[request.displayID] = request.pair
                recentDisplayID = request.displayID
                previousApp = nil
                pendingQuick = nil
                quick.hide()
            } else {
                quick.setSessionState(busy: !session.idle && !session.active, canCancel: session.preparing, message: session.status)
                if session.idle || session.active {
                    pendingQuick = nil
                    if session.failed && !quick.isVisible && !window.isVisible && !closing { quick.showFailure() }
                }
            }
        }
        if !splits.busy { refresh() }
        if closing && !splits.busy { finishQuit() }
    }

    private var shortcutInstructions: String {
        let unavailable = GlobalShortcuts.Command.allCases.filter { !shortcuts.isRegistered($0) }
        let labels = unavailable.map { shortcuts.key(for: $0).label }.joined(separator: "、")
        return labels.isEmpty ? "点击快捷键可修改。" : "无法注册 \(labels)，点击快捷键可修改。"
    }

    private func updateShortcutControls() {
        for (command, menuItem) in [(GlobalShortcuts.Command.toggle, toggleMenuItem), (.join, joinMenuItem)] {
            let key = shortcuts.key(for: command)
            menuItem?.keyEquivalent = key.equivalent
            menuItem?.keyEquivalentModifierMask = key.menuModifiers
            let title = recordingShortcut == command ? "按下组合键…" : key.label
            shortcutButtons[command]?.title = title
            shortcutButtons[command]?.setAccessibilityLabel("\(command.title)快捷键，\(title)")
        }
        let title = "Panelet"
        statusItem?.button?.toolTip = shortcuts.isRegistered(.toggle) ? "\(title) · \(shortcuts.key(for: .toggle).label)" : title
    }

    @objc private func recordShortcut(_ sender: NSButton) {
        guard let command = GlobalShortcuts.Command(rawValue: sender.tag) else { return }
        if recordingShortcut == command {
            stopRecordingShortcut()
            return
        }
        recordingShortcut = command
        shortcutInfo.stringValue = "按下新的组合键，Esc 取消。"
        updateShortcutControls()
    }

    private func handleShortcutKeyDown(_ event: NSEvent) -> NSEvent? {
        if recordingShortcut != nil && event.window === window {
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecordingShortcut()
            } else if !event.isARepeat {
                if let key = GlobalShortcuts.Key(event: event) {
                    saveShortcut(key)
                } else {
                    shortcutInfo.stringValue = "请按住 Control、Option 或 Command，再按一个键。Esc 取消。"
                }
            }
            return nil
        }
        guard let command = shortcuts.command(for: event) else { return event }
        if !event.isARepeat { shortcutPressed(command) }
        return nil
    }

    func windowDidResignKey(_ notification: Notification) { stopRecordingShortcut() }

    private func stopRecordingShortcut() {
        guard recordingShortcut != nil else { return }
        recordingShortcut = nil
        shortcutInfo.stringValue = shortcutInstructions
        updateShortcutControls()
    }

    private func saveShortcut(_ key: GlobalShortcuts.Key) {
        guard let command = recordingShortcut else { return }
        if let error = shortcuts.set(key, for: command) {
            shortcutInfo.stringValue = error
            return
        }
        stopRecordingShortcut()
        applySessionState()
    }

    private func shortcutPressed(_ command: GlobalShortcuts.Command) {
        if recordingShortcut != nil {
            saveShortcut(shortcuts.key(for: command))
            return
        }
        switch command {
        case .toggle: toggleQuick()
        case .join: restoreShortcut()
        }
    }

    private func appendLog(_ line: String) {
        let current = logView.string
        logView.string = current.isEmpty ? line : current + "\n" + line
        logView.scrollToEndOfDocument(nil)
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func labeled(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    @objc private func displayChanged() { applySessionState() }

    @objc private func splitClicked() {
        guard !confirming, !closing, let id = selectedDisplayID() else {
            DemoLog.shared.line("先接上或旋转出一块竖屏。")
            return
        }
        splits.split(id)
    }

    @objc private func joinClicked() {
        guard let id = selectedDisplayID(), splits.sessions[id]?.active == true else { return }
        requestJoin(preferred: id)
    }

    private func restoreShortcut() {
        guard !closing, !confirming, !splits.busy else { return }
        let pointer = CGEvent(source: nil)?.location
        let pointed = pointer.flatMap { splits.splitDisplay(at: $0) }
        let target = pointed.flatMap { splits.sessions[$0] } ?? (splits.active.count == 1 ? splits.active.first : nil)
        if let target {
            quick.hide()
            if target.hasQuick { splits.endQuick(target.targetID) }
            else { splits.join(target.targetID) }
        } else { chooseJoin() }
    }

    @objc private func chooseJoin() {
        let pointer = CGEvent(source: nil)?.location
        requestJoin(preferred: pointer.flatMap { splits.splitDisplay(at: $0) }, endQuick: true)
    }

    private func requestJoin(preferred: CGDirectDisplayID?, endQuick: Bool = false) {
        guard !closing, !confirming, !splits.busy, !splits.active.isEmpty else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let previous = front?.processIdentifier == getpid() ? previousApp : front
        let focusedDisplay = previous.flatMap(WindowPlacement.focusedWindowFrame).flatMap { frame in
            splits.splitDisplay(at: CGPoint(x: frame.midX, y: frame.midY))
        }
        let sessions = splits.active.sorted { $0.targetID < $1.targetID }
        let alert = NSAlert()
        alert.messageText = sessions.count == 1 ? "还原 \(sessions[0].name)？" : "还原哪块竖屏？"
        alert.informativeText = endQuick ? "结束快捷组合并还原窗口；进入前已有的桌面拆分会保留。普通桌面拆分会合并。" : "还原所选竖屏，结束其快捷组合并迁回窗口。"
        let selection = NSPopUpButton()
        if sessions.count > 1 {
            selection.addItems(withTitles: sessions.map(\.name))
            selection.selectItem(at: sessions.firstIndex(where: { $0.targetID == preferred }) ?? 0)
            selection.setAccessibilityLabel("要合并的竖屏")
            selection.sizeToFit()
            alert.accessoryView = selection
        }
        presentConfirmation(alert, action: "确认还原", preserving: previous) { [weak self] in
            guard let self else { return }
            let index = sessions.count == 1 ? 0 : selection.indexOfSelectedItem
            guard sessions.indices.contains(index) else { return }
            self.quick.hide()
            if let focusedDisplay, focusedDisplay != sessions[index].targetID, NSApp.isActive { previous?.activate() }
            if endQuick && sessions[index].hasQuick { self.splits.endQuick(sessions[index].targetID) }
            else { self.splits.join(sessions[index].targetID) }
        }
    }

    private func presentConfirmation(_ alert: NSAlert, action: String, preserving previous: NSRunningApplication? = nil,
                                     confirmed: @escaping () -> Void) {
        guard !confirming else { return }
        confirming = true
        applySessionState()
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        let confirm = alert.addButton(withTitle: action)
        confirm.hasDestructiveAction = true
        confirm.keyEquivalent = ""

        let host: NSWindow
        if window.isVisible && window.isKeyWindow {
            host = window
        } else {
            let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 380, height: 70), styleMask: [.titled, .utilityWindow],
                                backing: .buffered, defer: false)
            panel.title = "Panelet"
            panel.isReleasedWhenClosed = false
            panel.isFloatingPanel = true
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .canJoinAllApplications]
            if let screen = splits.hostScreen(at: nil) {
                let visible = screen.visibleFrame
                panel.setFrameOrigin(CGPoint(x: visible.midX - panel.frame.width / 2, y: visible.midY - 38))
            } else { panel.center() }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            confirmationPanel = panel
            host = panel
        }
        alert.beginSheetModal(for: host) { [weak self] response in
            guard let self else { return }
            self.confirmationPanel?.orderOut(nil)
            self.confirmationPanel = nil
            self.confirming = false
            self.applySessionState()
            if response == .alertSecondButtonReturn { confirmed() }
            else if NSApp.isActive { previous?.activate() }
        }
    }

    @objc private func quitClicked() { requestQuit(relaunch: false) }

    private func requestQuit(relaunch: Bool) {
        guard !closing, !confirming else { return }
        if splits.sessions.isEmpty {
            shouldRelaunch = relaunch
            NSApp.terminate(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = relaunch ? "合并分屏并重新启动？" : "合并分屏并退出？"
        alert.informativeText = "App 会先还原各块竖屏及其窗口。"
        presentConfirmation(alert, action: relaunch ? "合并并重新启动" : "合并并退出") { [weak self] in
            guard let self else { return }
            self.closing = true
            self.shouldRelaunch = relaunch
            self.quick.hide()
            self.splits.cancelPreparation()
            self.finishQuit()
        }
    }

    private func finishQuit() {
        guard !splits.busy else { return }
        if splits.sessions.values.contains(where: \.needsRecovery) {
            closing = false
            shouldRelaunch = false
            showAdvanced()
            return
        }
        if let session = splits.active.first { splits.join(session.targetID) }
        else { NSApp.terminate(nil) }
    }

    @objc private func retryRecovery() {
        if splits.recoveryProblem != nil {
            Task { await splits.recoverPreviousSession(); refresh() }
            return
        }
        guard !splits.busy, let session = splits.sessions.values.first(where: \.needsRecovery) else { return }
        if session.mode == .desktop && session.hasQuick { splits.endQuick(session.targetID) }
        else { splits.join(session.targetID) }
    }

    @objc private func askScreenRecording() {
        Permissions.requestScreenRecording()
        DemoLog.shared.line("如果系统设置里还没有本 App，用 + 号把 Panelet.app 加进去，勾选后点“重新启动”。")
    }

    @objc private func askAccessibility() {
        Permissions.requestAccessibility()
        DemoLog.shared.line("请在辅助功能中勾选正在运行的这份 App，然后点“重新启动”。")
    }

    @objc private func openDesktopSettings() {
        Permissions.openDesktopSettings()
    }

    @objc private func relaunch() {
        requestQuit(relaunch: true)
    }
}
