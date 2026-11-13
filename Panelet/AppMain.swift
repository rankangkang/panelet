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
        if let identifier = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first(where: { $0.processIdentifier != getpid() && !$0.isTerminated }) {
            existing.activate()
            return
        }
        let controller = AppController()
        app.delegate = controller
        withExtendedLifetime(controller) { app.run() }
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private let splits = SplitSessions()
    private let quick = QuickSplitPanel()
    private var window: NSWindow!
    private var popup: NSPopUpButton!
    private var settingsPages: [NSView] = []
    private var settingsNavigation: [NSButton] = []
    private let layoutPreview = SettingsLayoutPreview()
    private var recordPermissionButton: NSButton!
    private var accessPermissionButton: NSButton!
    private var statusLabel: NSTextField!
    private var splitButton: NSButton!
    private var joinButton: NSButton!
    private var screenRecordingLabel: NSTextField!
    private var accessibilityLabel: NSTextField!
    private var spacesLabel: NSTextField!
    private var logView: NSTextView!
    private var displays: [PhysicalScreen] = []
    private var lastScreenKey = ""
    private var closing = false
    private var allowIncompleteExit = false
    private var quitDeadline: Task<Void, Never>?
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
    private let desktopMenu = NSMenu()
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
        if allowIncompleteExit { return .terminateNow }
        if closing {
            if splits.sessions.isEmpty { return .terminateNow }
            offerIncompleteExit()
            return .terminateCancel
        }
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
        let toggle = commands.addItem(withTitle: "快捷窗口分屏…", action: #selector(openQuick), keyEquivalent: "")
        toggle.target = self
        toggleMenuItem = toggle
        let settings = commands.addItem(withTitle: "设置…", action: #selector(showAdvanced), keyEquivalent: ",")
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
        let toggle = menu.addItem(withTitle: "快捷窗口分屏…", action: #selector(openQuick), keyEquivalent: "")
        toggle.target = self
        let desktop = menu.addItem(withTitle: "拆分桌面", action: nil, keyEquivalent: "")
        desktop.submenu = desktopMenu
        menu.delegate = self
        let join = menu.addItem(withTitle: "还原分屏…", action: #selector(chooseJoin), keyEquivalent: "")
        join.target = self
        let settings = menu.addItem(withTitle: "设置…", action: #selector(showAdvanced), keyEquivalent: "")
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

    func menuWillOpen(_ menu: NSMenu) {
        desktopMenu.removeAllItems()
        let screens = splits.screens().sorted { $0.id < $1.id }
        for (index, screen) in screens.enumerated() {
            let session = splits.sessions[screen.id]
            let action = session?.active == true ? "合并" : "\(screen.splitLayout.direction)拆分"
            let item = desktopMenu.addItem(withTitle: "\(index + 1) · \(screen.menuTitle) · \(action)",
                                           action: #selector(desktopMenuClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: screen.id)
            item.isEnabled = !splits.busy && !closing && !confirming &&
                (session?.active == true || (session == nil && splitProblem == nil))
        }
        desktopMenu.autoenablesItems = false
        if screens.isEmpty {
            let item = desktopMenu.addItem(withTitle: "没有可用显示器", action: nil, keyEquivalent: "")
            item.isEnabled = false
        }
    }

    @objc private func desktopMenuClicked(_ sender: NSMenuItem) {
        guard !splits.busy, !closing, !confirming,
              let id = (sender.representedObject as? NSNumber)?.uint32Value else { return }
        if splits.sessions[id]?.active == true { splits.join(id) }
        else if splitProblem == nil { splits.split(id) }
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 560),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Panelet · 设置"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.titlebarAppearsTransparent = true
        let root = SettingsBackgroundView()
        window.contentView = root

        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .active
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebar)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 184)
        ])
        let brand = NSImageView(image: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
        brand.widthAnchor.constraint(equalToConstant: 38).isActive = true
        brand.heightAnchor.constraint(equalToConstant: 38).isActive = true
        let brandRow = NSStackView(views: [brand, settingsText("Panelet", size: 20, weight: .semibold)])
        brandRow.spacing = 10
        let nav = NSStackView(views: [brandRow])
        nav.orientation = .vertical
        nav.alignment = .leading
        nav.spacing = 8
        nav.setCustomSpacing(28, after: brandRow)
        let destinations = [("桌面分屏", "rectangle.split.2x1"), ("快捷键", "keyboard"),
                            ("权限", "lock.shield"), ("诊断", "waveform.path.ecg")]
        for (index, destination) in destinations.enumerated() {
            let item = NSButton(title: "  " + destination.0, target: self, action: #selector(selectSettingsPage(_:)))
            item.image = NSImage(systemSymbolName: destination.1, accessibilityDescription: nil)
            item.imagePosition = .imageLeading
            item.alignment = .left
            item.bezelStyle = .recessed
            item.setButtonType(.pushOnPushOff)
            item.font = .systemFont(ofSize: 13, weight: .medium)
            item.tag = index
            item.widthAnchor.constraint(equalToConstant: 152).isActive = true
            item.heightAnchor.constraint(equalToConstant: 34).isActive = true
            item.setAccessibilityLabel(destination.0)
            settingsNavigation.append(item)
            nav.addArrangedSubview(item)
        }
        nav.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(nav)
        let tagline = settingsText("一块屏幕，更多空间。", size: 11, secondary: true)
        tagline.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(tagline)
        NSLayoutConstraint.activate([
            nav.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            nav.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 24),
            tagline.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            tagline.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -22)
        ])

        popup = NSPopUpButton()
        popup.target = self
        popup.action = #selector(displayChanged)
        popup.setAccessibilityLabel("目标显示器")
        popup.widthAnchor.constraint(equalToConstant: 444).isActive = true
        statusLabel = settingsText("未拆分", size: 12, secondary: true)
        splitButton = button("拆分桌面", action: #selector(splitClicked))
        splitButton.bezelColor = .controlAccentColor
        joinButton = button("合并桌面…", action: #selector(joinClicked))
        let actions = NSStackView(views: [splitButton, joinButton])
        actions.spacing = 10
        layoutPreview.heightAnchor.constraint(equalToConstant: 150).isActive = true
        layoutPreview.widthAnchor.constraint(equalToConstant: 444).isActive = true
        let desktop = settingsPage("桌面分屏", subtitle: "让一块显示器，拥有两个独立的工作空间。", views: [
            settingsCard([settingsText("目标显示器", size: 12, weight: .semibold), popup, layoutPreview, statusLabel, actions]),
            settingsCard([settingsRow("临时组合两个窗口", detail: "选好窗口后分别全屏，退出全屏即可还原。",
                                     control: button("快捷分屏…", action: #selector(openQuick)))])
        ])

        var shortcutRows: [NSView] = []
        for command in GlobalShortcuts.Command.allCases {
            let recorder = button(command.defaultKey.label, action: #selector(recordShortcut(_:)))
            recorder.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
            recorder.widthAnchor.constraint(equalToConstant: 116).isActive = true
            recorder.tag = command.rawValue
            shortcutButtons[command] = recorder
            shortcutRows.append(settingsRow(command.title,
                detail: command == .toggle ? "随时呼出窗口选择面板" : "还原鼠标所在的分屏", control: recorder))
        }
        shortcutInfo.font = .systemFont(ofSize: 12)
        shortcutInfo.textColor = .secondaryLabelColor
        shortcutRows.append(shortcutInfo)
        let keys = settingsPage("快捷键", subtitle: "不用离开当前工作，也能快速切换。", views: [settingsCard(shortcutRows),
            settingsText("点击右侧快捷键，再按下新的组合键。\n使用 Control、Option 或 Command 搭配一个按键。", size: 12, secondary: true)])

        screenRecordingLabel = settingsText("检查中", size: 12)
        accessibilityLabel = settingsText("检查中", size: 12)
        spacesLabel = settingsText("检查中", size: 12)
        recordPermissionButton = button("去授权", action: #selector(askScreenRecording))
        accessPermissionButton = button("去授权", action: #selector(askAccessibility))
        let permissions = settingsPage("权限", subtitle: "只开启分屏所需的系统权限。", views: [
            settingsCard([settingsRow("屏幕录制", detail: "显示分区画面和窗口预览。", control: recordPermissionButton), screenRecordingLabel]),
            settingsCard([settingsRow("辅助功能", detail: "移动窗口，并处理分屏间的鼠标操作。", control: accessPermissionButton), accessibilityLabel]),
            settingsCard([settingsRow("显示器使用不同的空间", detail: "让每个分区拥有独立的全屏空间。", control: button("系统设置…", action: #selector(openDesktopSettings))), spacesLabel]),
            settingsText("更改权限后，请重新启动 Panelet。", size: 12, secondary: true),
            button("重新启动 Panelet", action: #selector(relaunch))
        ])

        logView = NSTextView()
        logView.isEditable = false
        logView.isSelectable = true
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textColor = .labelColor
        logView.backgroundColor = .textBackgroundColor
        logView.textContainerInset = NSSize(width: 12, height: 12)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = logView
        scroll.heightAnchor.constraint(equalToConstant: 250).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 444).isActive = true
        logView.setAccessibilityLabel("运行日志")
        let diagnostics = settingsPage("诊断", subtitle: "查看运行状态，在需要时恢复窗口。", views: [
            settingsCard([settingsRow("运行日志", detail: "本次启动的显示器与分屏记录。", control: button("复制日志", action: #selector(copySettingsLog))), scroll]),
            settingsCard([settingsRow("窗口恢复", detail: "分屏中断或窗口未归位时使用。", control: button("重试恢复…", action: #selector(retryRecovery)))])
        ])
        settingsPages = [desktop, keys, permissions, diagnostics]
        for page in settingsPages {
            page.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(page)
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 30),
                page.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -30),
                page.topAnchor.constraint(equalTo: root.topAnchor, constant: 28)
            ])
        }
        selectSettingsPage(settingsNavigation[0])
    }

    private func settingsText(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                              secondary: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        label.preferredMaxLayoutWidth = 470
        return label
    }

    private func settingsPage(_ title: String, subtitle: String, views: [NSView]) -> NSStackView {
        let heading = settingsText(title, size: 25, weight: .bold)
        let detail = settingsText(subtitle, size: 13, secondary: true)
        let stack = NSStackView(views: [heading, detail] + views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.setCustomSpacing(6, after: heading)
        stack.setCustomSpacing(24, after: detail)
        for view in views where view is NSBox { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    private func settingsCard(_ views: [NSView]) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.cornerRadius = 12
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.contentViewMargins = .zero
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        box.contentView = content
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
        return box
    }

    private func settingsRow(_ title: String, detail: String, control: NSView) -> NSStackView {
        let labels = NSStackView(views: [settingsText(title, weight: .semibold), settingsText(detail, size: 11, secondary: true)])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 5
        let row = NSStackView(views: [labels, NSView(), control])
        row.alignment = .centerY
        row.spacing = 12
        row.widthAnchor.constraint(equalToConstant: 444).isActive = true
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        return row
    }

    @objc private func selectSettingsPage(_ sender: NSButton) {
        stopRecordingShortcut()
        for (index, page) in settingsPages.enumerated() { page.isHidden = index != sender.tag }
        for (index, item) in settingsNavigation.enumerated() {
            let selected = index == sender.tag
            item.state = selected ? .on : .off
            item.showsBorderOnlyWhileMouseInside = !selected
            item.contentTintColor = selected ? .controlAccentColor : .labelColor
        }
    }

    @objc private func copySettingsLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logView.string, forType: .string)
    }

    private func logStartup() {
        DemoLog.shared.line("Panelet 已启动。当前显示器：")
        for screen in DisplayScanner.physicalScreens() {
            let orientation = screen.isPortrait ? "竖屏" : "横屏"
            DemoLog.shared.line("\(screen.menuTitle)  \(orientation)  id=\(screen.id)")
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
        screenRecordingLabel.stringValue = Permissions.screenRecording ? "✓ 已授权" : "未授权 · 请前往系统设置开启"
        accessibilityLabel.stringValue = Permissions.accessibility ? "✓ 已授权" : "未授权 · 请前往系统设置开启"
        if Permissions.separateSpacesEnabled {
            spacesLabel.stringValue = "✓ 已打开"
        } else {
            spacesLabel.stringValue = "未打开 · 开启后需要重新登录 macOS"
        }
        recordPermissionButton.title = Permissions.screenRecording ? "管理权限…" : "去授权…"
        accessPermissionButton.title = Permissions.accessibility ? "管理权限…" : "去授权…"
        applySessionState()
    }

    private func reloadPopup(_ screens: [PhysicalScreen]) {
        let previous = selectedDisplayID()
        displays = screens
        popup.removeAllItems()
        if displays.isEmpty {
            popup.addItem(withTitle: "没有可用显示器")
            return
        }
        for screen in displays {
            let session = splits.sessions[screen.id]
            let mode = session?.hasQuick == true ? "快捷全屏" : "桌面拆分"
            let label = session?.active == true ? "\(screen.menuTitle) · \(mode)" : screen.menuTitle
            popup.addItem(withTitle: label)
            popup.lastItem?.representedObject = NSNumber(value: screen.id)
        }
        if let previous, let index = displays.firstIndex(where: { $0.id == previous }) {
            popup.selectItem(at: index)
        }
    }

    private func applySessionState() {
        let id = selectedDisplayID()
        let session = id.flatMap { splits.sessions[$0] }
        layoutPreview.screen = displays.first { $0.id == id }
        splitButton.title = layoutPreview.screen.map { "\($0.splitLayout.direction)拆分桌面" } ?? "拆分桌面"
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
        let action = "快捷窗口分屏…"
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
        let available = screens.filter { (splits.sessions[$0.id] == nil || splits.sessions[$0.id]?.canStartQuick == true) }
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
        if closing && !splits.busy && !confirming { finishQuit() }
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

    @objc private func displayChanged() { applySessionState() }

    @objc private func splitClicked() {
        guard !confirming, !closing, let id = selectedDisplayID() else {
            DemoLog.shared.line("先接上一块显示器。")
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
        alert.messageText = sessions.count == 1 ? "还原 \(sessions[0].name)？" : "还原哪块显示器？"
        alert.informativeText = endQuick ? "结束快捷组合并还原窗口；进入前已有的桌面拆分会保留。普通桌面拆分会合并。" : "还原所选显示器，结束其快捷组合并迁回窗口。"
        let selection = NSPopUpButton()
        if sessions.count > 1 {
            selection.addItems(withTitles: sessions.map(\.name))
            selection.selectItem(at: sessions.firstIndex(where: { $0.targetID == preferred }) ?? 0)
            selection.setAccessibilityLabel("要合并的显示器")
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
                                     cancelled: (() -> Void)? = nil, confirmed: @escaping () -> Void) {
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
            else {
                cancelled?()
                if NSApp.isActive { previous?.activate() }
            }
        }
    }

    @objc private func quitClicked() { requestQuit(relaunch: false) }

    private func requestQuit(relaunch: Bool) {
        guard !confirming else { return }
        if closing { offerIncompleteExit(); return }
        if splits.sessions.isEmpty {
            shouldRelaunch = relaunch
            NSApp.terminate(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = relaunch ? "合并分屏并重新启动？" : "合并分屏并退出？"
        alert.informativeText = "App 会先还原各块显示器及其窗口。"
        presentConfirmation(alert, action: relaunch ? "合并并重新启动" : "合并并退出") { [weak self] in
            guard let self else { return }
            self.closing = true
            self.shouldRelaunch = relaunch
            self.quick.hide()
            self.quitDeadline?.cancel()
            self.quitDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self, self.closing else { return }
                self.finishQuit(timedOut: true)
            }
            self.splits.cancelPreparation()
            self.finishQuit()
        }
    }

    private func finishQuit(timedOut: Bool = false) {
        guard closing, !confirming else { return }
        switch QuitPolicy.action(hasSessions: !splits.sessions.isEmpty, busy: splits.busy,
                                 needsRecovery: splits.sessions.values.contains(where: \.needsRecovery), timedOut: timedOut) {
        case .wait:
            return
        case .offerExit:
            offerIncompleteExit()
        case .restore:
            if let session = splits.active.first { splits.join(session.targetID) }
            else { offerIncompleteExit() }
        case .terminate:
            quitDeadline?.cancel()
            NSApp.terminate(nil)
        }
    }

    private func offerIncompleteExit() {
        guard closing, !confirming else { return }
        quitDeadline?.cancel()
        let alert = NSAlert()
        alert.messageText = "窗口还没有完全恢复"
        alert.informativeText = "仍然退出会结束分屏，部分窗口的位置或全屏状态可能暂时改变。恢复记录会保留，下次启动时继续尝试恢复。也可以取消退出，稍后重试。"
        let action = shouldRelaunch ? "仍然重新启动" : "仍然退出"
        presentConfirmation(alert, action: action, cancelled: { [weak self] in
            self?.closing = false
            self?.shouldRelaunch = false
            self?.applySessionState()
        }) { [weak self] in
            guard let self else { return }
            // Do not discard sessions or clear the recovery journal on this path.
            self.splits.saveBeforeIncompleteExit()
            self.allowIncompleteExit = true
            NSApp.terminate(nil)
        }
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

@MainActor
private final class SettingsLayoutPreview: NSView {
    var screen: PhysicalScreen? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let screen else { return }
        let portrait = screen.isPortrait
        let size = portrait ? CGSize(width: 68, height: 112) : CGSize(width: 196, height: 112)
        let frame = CGRect(x: bounds.midX - size.width / 2, y: 28, width: size.width, height: size.height)
        NSColor.separatorColor.setStroke()
        let outline = NSBezierPath(roundedRect: frame.insetBy(dx: -5, dy: -5), xRadius: 9, yRadius: 9)
        outline.lineWidth = 2
        outline.stroke()
        for (index, region) in screen.splitLayout.regions.enumerated() {
            let rect = CGRect(x: frame.minX + region.minX / screen.bounds.width * size.width,
                              y: frame.maxY - region.maxY / screen.bounds.height * size.height,
                              width: region.width / screen.bounds.width * size.width,
                              height: region.height / screen.bounds.height * size.height).insetBy(dx: 2, dy: 2)
            NSColor.controlAccentColor.withAlphaComponent(index == 0 ? 0.22 : 0.12).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            let text = screen.splitLayout.names[index] as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor]
            let textSize = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2), withAttributes: attrs)
        }
        let caption = "\(screen.splitLayout.direction)等分 · 两个独立桌面" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        caption.draw(at: CGPoint(x: bounds.midX - caption.size(withAttributes: attrs).width / 2, y: 2), withAttributes: attrs)
        setAccessibilityLabel("\(screen.name)，\(screen.splitLayout.direction)等分为两个独立桌面")
    }
}

@MainActor
private final class SettingsBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
