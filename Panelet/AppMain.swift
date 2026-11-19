import AppKit
import Carbon.HIToolbox
import ServiceManagement
import UniformTypeIdentifiers

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
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, NSMenuItemValidation {
    private let splits = SplitSessions()
    private var environment = EnvironmentCheck.inspect()
    private let environmentResult = EnvironmentStatusView(frame: .zero)
    private let quick = QuickSplitPanel()
    private let preferences = ProductPreferences()
    private let identifiers = DisplayIdentifiers()
    private let directionPicker = NSPopUpButton()
    private let ratioPicker = NSPopUpButton()
    private let renderingPicker = NSPopUpButton()
    private let displayAlias = NSTextField(string: "")
    private var aliasDisplayID: CGDirectDisplayID?
    private let layoutDetail = NSTextField(wrappingLabelWithString: "")
    private let launchPanel = NSButton(checkboxWithTitle: L("启动时打开窗口选择面板"), target: nil, action: nil)
    private let automaticStart = NSButton(checkboxWithTitle: L("选好两个窗口后立即开始"), target: nil, action: nil)
    private let loginItem = NSButton(checkboxWithTitle: L("登录时启动 Panelet"), target: nil, action: nil)
    private let loginStatus = NSTextField(wrappingLabelWithString: "")
    private let languagePicker = NSPopUpButton()
    private var restoringAll = false
    private var restoreAttempts = Set<CGDirectDisplayID>()
    private var reportWindow: NSWindow?
    private var reportText = ""
    private var helpWindow: NSWindow?
    private var window: NSWindow!
    private var popup: NSPopUpButton!
    private var settingsPages: [NSView] = []
    private var settingsNavigation: [NSButton] = []
    private let displayArrangement = SettingsDisplayArrangement(frame: .zero)
    private let layoutPreview = SettingsLayoutPreview()
    private let layoutLock = NSTextField(wrappingLabelWithString: L("合并桌面后可更改布局"))
    private var recordPermissionButton: NSButton!
    private var accessPermissionButton: NSButton!
    private var statusLabel: NSTextField!
    private var splitButton: NSButton!
    private var restoreButton: NSButton!
    private var mergeButton: NSButton!
    private var retryRecoveryButton: NSButton!
    private var restoreAllButton: NSButton!
    private let recoveryStatus = NSTextField(wrappingLabelWithString: "")
    private let screenRecordingStatus = SettingsStatusLine(frame: .zero)
    private let accessibilityStatus = SettingsStatusLine(frame: .zero)
    private let spacesStatus = SettingsStatusLine(frame: .zero)
    private var logView: NSTextView!
    private var displays: [PhysicalScreen] = []
    private var lastScreenKey = ""
    private var refreshTimer: Timer?
    private var closing = false
    private var allowIncompleteExit = false
    private var quitDeadline: Task<Void, Never>?
    private var confirmationAlert: NSAlert?
    private var confirming: Bool { confirmationAlert != nil }
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
    private var logBuffer = BoundedLogBuffer(capacity: 500)
    private lazy var guide = makeGuideController()

    private func makeGuideController() -> OnboardingGuideController {
        let controller = OnboardingGuideController(splits: splits, preferences: preferences)
        controller.snapshotProvider = { [weak self] in
            guard let self else {
                return .init(operationsAvailable: false, closing: false, confirming: false,
                             restoringAll: false, splitProblem: nil, hasPendingRecovery: false)
            }
            return .init(
                operationsAvailable: self.operationsAvailable,
                closing: self.closing,
                confirming: self.confirming,
                restoringAll: self.restoringAll,
                splitProblem: self.splitProblem,
                hasPendingRecovery: self.hasPendingRecovery
            )
        }
        controller.onShowSettings = { [weak self] in self?.showAdvanced() }
        controller.onRelaunchRequested = { [weak self] in self?.requestQuit(relaunch: true) }
        controller.onRetryRecovery = { [weak self] in self?.retryRecovery() }
        controller.onCheckEnvironment = { [weak self] in self?.checkEnvironment() }
        controller.onDraftSaved = { [weak self] in self?.lastScreenKey = "" }
        return controller
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        buildMenu()
        buildStatusItem()
        quick.onAdvanced = { [weak self] in self?.showQuickSettings() }
        quick.onCancel = { [weak self] in self?.dismissQuick() }
        quick.onJoin = { [weak self] in self?.chooseRestore() }
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
        NotificationCenter.default.addObserver(self, selector: #selector(startRefreshing(_:)),
                                               name: NSWindow.didBecomeKeyNotification, object: nil)
        refresh()
        logStartup()
        Task {
            await splits.recoverPreviousSession()
            refresh()
            if !environment.canSplit { showEnvironment() }
            else if splits.recoveryProblem != nil { showAdvanced() }
            else {
                let existing = UserDefaults.standard.persistentDomain(forName: "dev.cmkk.panelet") ?? [:]
                preferences.prepareGuide(permissionsReady: Permissions.splitProblem == nil,
                    hasExistingPreferences: existing.keys.contains { $0.hasPrefix("display.") || $0 == "showPanelOnLaunch" || $0 == "workspaces.v1" })
                if preferences.guideStep != .complete && !preferences.guideDeferred { showGuide(resume: true) }
                else if preferences.showPanelOnLaunch { showQuick() }
            }
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
        if confirming {
            revealActiveConfirmation()
            return false
        }
        if !splits.busy {
            if preferences.guideStep != .complete { showGuide(resume: true) }
            else { showQuick() }
        }
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
        let toggle = commands.addItem(withTitle: L("快捷窗口分屏…"), action: #selector(openQuick), keyEquivalent: "")
        toggle.target = self
        toggleMenuItem = toggle
        let about = commands.addItem(withTitle: L("关于 Panelet…"), action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        let help = commands.addItem(withTitle: L("Panelet 帮助…"), action: #selector(showHelp), keyEquivalent: "?")
        help.target = self
        let restore = commands.addItem(withTitle: L("恢复所有显示器…"), action: #selector(restoreAll), keyEquivalent: "")
        restore.target = self
        let settings = commands.addItem(withTitle: L("设置…"), action: #selector(showAdvanced), keyEquivalent: ",")
        settings.target = self
        let join = commands.addItem(withTitle: L("还原分屏…"), action: #selector(chooseRestore), keyEquivalent: "")
        join.target = self
        joinMenuItem = join
        let retry = commands.addItem(withTitle: L("重试恢复窗口…"), action: #selector(retryRecovery), keyEquivalent: "")
        retry.target = self
        let restart = commands.addItem(withTitle: L("重新启动 Panelet"), action: #selector(relaunch), keyEquivalent: "")
        restart.target = self
        let quit = commands.addItem(withTitle: L("退出 Panelet"), action: #selector(quitClicked), keyEquivalent: "q")
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
        let toggle = menu.addItem(withTitle: L("快捷窗口分屏…"), action: #selector(openQuick), keyEquivalent: "")
        toggle.target = self
        let desktop = menu.addItem(withTitle: L("拆分桌面"), action: nil, keyEquivalent: "")
        desktop.submenu = desktopMenu
        menu.delegate = self
        let join = menu.addItem(withTitle: L("还原分屏…"), action: #selector(chooseRestore), keyEquivalent: "")
        join.target = self
        let settings = menu.addItem(withTitle: L("设置…"), action: #selector(showAdvanced), keyEquivalent: "")
        settings.target = self
        let check = menu.addItem(withTitle: L("检查运行环境…"), action: #selector(showEnvironment), keyEquivalent: "")
        check.target = self
        let restore = menu.addItem(withTitle: L("恢复所有显示器…"), action: #selector(restoreAll), keyEquivalent: "")
        restore.target = self
        let help = menu.addItem(withTitle: L("帮助与隐私…"), action: #selector(showHelp), keyEquivalent: "")
        help.target = self
        let guide = menu.addItem(withTitle: L("使用导引…"), action: #selector(openGuide), keyEquivalent: "")
        guide.target = self
        let about = menu.addItem(withTitle: L("关于 Panelet…"), action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(.separator())
        let restart = menu.addItem(withTitle: L("重新启动 Panelet"), action: #selector(relaunch), keyEquivalent: "")
        restart.target = self
        let quit = menu.addItem(withTitle: L("退出 Panelet"), action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        item.menu = menu
        statusItem = item
        statusAction = toggle
        statusJoin = join
        let retry = menu.addItem(withTitle: L("重试恢复窗口…"), action: #selector(retryRecovery), keyEquivalent: "")
        retry.target = self
    }

    func menuWillOpen(_ menu: NSMenu) {
        desktopMenu.removeAllItems()
        let screens = splits.screens().sorted { $0.id < $1.id }
        for (index, screen) in screens.enumerated() {
            guard splits.sessions[screen.id] == nil else { continue }
            let action = L("%@拆分", String(describing: screen.splitLayout.direction))
            let item = desktopMenu.addItem(withTitle: "\(index + 1) · \(screen.menuTitle) · \(action)",
                                           action: #selector(desktopMenuClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: screen.id)
            item.isEnabled = operationsAvailable && splitProblem == nil
        }
        desktopMenu.autoenablesItems = false
        if desktopMenu.items.isEmpty {
            let title = screens.isEmpty ? L("没有可用显示器") : L("没有可拆分的显示器")
            let item = desktopMenu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
        }
    }

    @objc private func desktopMenuClicked(_ sender: NSMenuItem) {
        guard operationsAvailable, splitProblem == nil,
              let id = (sender.representedObject as? NSNumber)?.uint32Value,
              splits.sessions[id] == nil else { return }
        splits.split(id)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(openQuick): return operationsAvailable
        case #selector(chooseRestore): return operationsAvailable && !splits.active.isEmpty
        case #selector(retryRecovery): return operationsAvailable && hasPendingRecovery
        case #selector(restoreAll): return canRestoreAll
        default: return true
        }
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 560),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = L("Panelet · 设置")
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
        let destinations = [(L("桌面分屏"), "rectangle.split.2x1"), (L("快捷键"), "keyboard"),
                            (L("权限"), "lock.shield"), (L("诊断"), "waveform.path.ecg"), (L("通用"), "gearshape")]
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
        let tagline = settingsText(L("一块屏幕，更多空间。"), size: 11, secondary: true)
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
        popup.setAccessibilityLabel(L("目标显示器"))
        displayArrangement.heightAnchor.constraint(equalToConstant: 90).isActive = true
        displayArrangement.onSelect = { [weak self] id in
            guard let self, self.operationsAvailable,
                  let index = self.displays.firstIndex(where: { $0.id == id }) else { return }
            self.popup.selectItem(at: index)
            self.displayChanged()
        }
        statusLabel = settingsText(L("未拆分"), size: 12, secondary: true)
        splitButton = button(L("拆分桌面"), action: #selector(splitClicked))
        splitButton.bezelColor = .controlAccentColor
        restoreButton = button(L("合并桌面…"), action: #selector(restoreSelectedDisplay))
        restoreButton.bezelColor = .controlAccentColor
        mergeButton = button(L("合并桌面…"), action: #selector(mergeSelectedDisplay))
        let actions = NSStackView(views: [splitButton, restoreButton, mergeButton, NSView()])
        actions.spacing = 10
        let layout = layoutEditor(preview: layoutPreview, direction: directionPicker, ratio: ratioPicker)
        renderingPicker.addItems(withTitles: DisplayConfiguration.Rendering.allCases.map(\.title))
        for picker in [directionPicker, ratioPicker, renderingPicker] {
            picker.target = self
            picker.action = #selector(saveDisplayPreferences)
        }
        renderingPicker.widthAnchor.constraint(equalToConstant: 148).isActive = true
        renderingPicker.setAccessibilityLabel(L("画面模式"))
        displayAlias.placeholderString = L("使用系统名称")
        displayAlias.widthAnchor.constraint(equalToConstant: 180).isActive = true
        displayAlias.target = self
        displayAlias.action = #selector(saveDisplayPreferences)
        displayAlias.setAccessibilityLabel(L("显示器名称"))
        layoutDetail.font = .systemFont(ofSize: 11)
        layoutDetail.textColor = .secondaryLabelColor
        layoutDetail.preferredMaxLayoutWidth = 408
        layoutLock.font = .systemFont(ofSize: 11)
        layoutLock.textColor = .secondaryLabelColor
        let desktop = settingsPage(L("桌面分屏"), subtitle: L("让一块显示器，拥有两个独立的工作空间。"), views: [
            settingsCard([settingsRow(L("目标显示器"), detail: L("点击屏幕选择；编号与“识别显示器”一致。"),
                                      control: button(L("识别显示器"), action: #selector(identifyDisplays))),
                          displayArrangement, popup, layout, layoutDetail, layoutLock, statusLabel, actions]),
            settingsCard([
                settingsRow(L("画面模式"), detail: L("清晰优先保留原生缩放；高清高刷兼顾原生清晰度与 120 Hz；流畅优先降低分辨率"), control: renderingPicker),
                settingsRow(L("显示器名称"), detail: L("仅保存在本机，按回车保存"), control: displayAlias)]),
            settingsCard([settingsRow(L("临时组合两个窗口"), detail: L("选好窗口后分别全屏，退出全屏即可还原。"),
                                     control: button(L("快捷分屏…"), action: #selector(openQuick)))])
        ])

        var shortcutRows: [NSView] = []
        for command in GlobalShortcuts.Command.allCases {
            let recorder = button(command.defaultKey.label, action: #selector(recordShortcut(_:)))
            recorder.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
            recorder.widthAnchor.constraint(equalToConstant: 116).isActive = true
            recorder.tag = command.rawValue
            shortcutButtons[command] = recorder
            shortcutRows.append(settingsRow(command.title,
                detail: command == .toggle ? L("随时呼出窗口选择面板") : L("结束窗口组合，或合并鼠标所在的拆分桌面"), control: recorder))
        }
        shortcutInfo.font = .systemFont(ofSize: 12)
        shortcutInfo.textColor = .secondaryLabelColor
        shortcutRows.append(shortcutInfo)
        let keys = settingsPage(L("快捷键"), subtitle: L("不用离开当前工作，也能快速切换。"), views: [settingsCard(shortcutRows),
            settingsText(L("点击右侧快捷键，再按下新的组合键。\n使用 Control、Option 或 Command 搭配一个按键。"), size: 12, secondary: true)])

        recordPermissionButton = button(L("去授权"), action: #selector(askScreenRecording))
        accessPermissionButton = button(L("去授权"), action: #selector(askAccessibility))
        let permissions = settingsPage(L("权限"), subtitle: L("只开启分屏所需的系统权限。"), views: [
            settingsCard([settingsRow(L("屏幕录制"), detail: L("显示分区画面和窗口预览。"), control: recordPermissionButton), screenRecordingStatus]),
            settingsCard([settingsRow(L("辅助功能"), detail: L("移动窗口，并处理分屏间的鼠标操作。"), control: accessPermissionButton), accessibilityStatus]),
            settingsCard([settingsRow(L("显示器使用不同的空间"), detail: L("让每个分区拥有独立的全屏空间。"), control: button(L("系统设置…"), action: #selector(openDesktopSettings))), spacesStatus]),
            settingsText(L("更改权限后，请重新启动 Panelet。"), size: 12, secondary: true),
            button(L("重新启动 Panelet"), action: #selector(relaunch))
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
        scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        logView.setAccessibilityLabel(L("运行日志"))
        environmentResult.update(environment, checkedAt: Date())
        retryRecoveryButton = button(L("重试恢复窗口…"), action: #selector(retryRecovery))
        restoreAllButton = button(L("恢复所有显示器…"), action: #selector(restoreAll))
        recoveryStatus.textColor = .secondaryLabelColor
        recoveryStatus.font = .systemFont(ofSize: 12)
        recoveryStatus.preferredMaxLayoutWidth = 408
        let diagnostics = settingsPage(L("诊断"), subtitle: L("查看运行状态，在需要时恢复窗口。"), views: [
            settingsCard([settingsRow(L("运行环境"), detail: L("只读检测，不会开始分屏或移动窗口。"), control: button(L("重新检测"), action: #selector(checkEnvironment))), environmentResult]),
            settingsCard([settingsRow(L("窗口恢复"), detail: L("分屏中断或窗口未归位时使用。"), control: retryRecoveryButton), recoveryStatus, restoreAllButton]),
            settingsCard([settingsRow(L("运行日志"), detail: L("本次启动的显示器与分屏记录。"), control: button(L("预览诊断报告…"), action: #selector(copySettingsLog))), scroll])
        ])
        launchPanel.target = self
        launchPanel.action = #selector(saveGeneralPreferences)
        automaticStart.target = self
        automaticStart.action = #selector(saveGeneralPreferences)
        launchPanel.state = preferences.showPanelOnLaunch ? .on : .off
        automaticStart.state = preferences.automaticStart ? .on : .off
        loginItem.target = self
        loginItem.action = #selector(changeLoginItem)
        updateLoginStatus()
        loginStatus.font = .systemFont(ofSize: 11)
        loginStatus.textColor = .secondaryLabelColor
        languagePicker.addItems(withTitles: [L("跟随系统"), "简体中文", "English"])
        languagePicker.selectItem(at: ["system", "zh-Hans", "en"].firstIndex(of: UserDefaults.standard.string(forKey: "interfaceLanguage") ?? "system") ?? 0)
        languagePicker.target = self
        languagePicker.action = #selector(changeLanguage)
        languagePicker.setAccessibilityLabel(L("界面语言"))
        let general = settingsPage(L("通用"), subtitle: L("按你的习惯工作，默认安静驻留菜单栏。"), views: [
            settingsCard([settingsRow(L("界面语言"), detail: L("更改后重新启动生效"), control: languagePicker), launchPanel, automaticStart, loginItem, loginStatus,
                          button(L("登录项设置…"), action: #selector(openLoginSettings))]),
            settingsCard([settingsText(L("使用方式"), weight: .semibold),
                          settingsText(L("独立桌面会持续保留，直到你主动合并。临时双窗口全屏在任一窗口退出全屏后结束，进入前已有的独立桌面会保留。"), size: 12),
                          button(L("帮助、隐私与兼容性…"), action: #selector(showHelp)),
                          button(L("重新查看导引…"), action: #selector(restartGuide)),
                          button(L("关于 Panelet…"), action: #selector(showAbout))])
        ])
        settingsPages = [desktop, keys, permissions, diagnostics, general]
        for page in settingsPages {
            page.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(page)
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 30),
                page.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -30),
                page.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
                page.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20)
            ])
        }
        selectSettingsPage(settingsNavigation[0])
    }

    private func settingsText(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                              secondary: Bool = false) -> NSTextField {
        SettingsUI.text(text, size: size, weight: weight, secondary: secondary)
    }

    private func settingsPage(_ title: String, subtitle: String, views: [NSView]) -> NSView {
        SettingsUI.page(title, subtitle: subtitle, views: views)
    }

    private func layoutEditor(preview: SettingsLayoutPreview, direction: NSPopUpButton, ratio: NSPopUpButton) -> NSStackView {
        SettingsUI.layoutEditor(preview: preview, direction: direction, ratio: ratio)
    }

    private func settingsCard(_ views: [NSView]) -> NSBox {
        SettingsUI.card(views)
    }

    private func settingsRow(_ title: String, detail: String, control: NSView) -> NSStackView {
        SettingsUI.row(title, detail: detail, control: control)
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
        if reportWindow?.attachedSheet != nil { reportWindow?.makeKeyAndOrderFront(nil); return }
        reportWindow?.close()
        reportText = DiagnosticReport.make(environment: environment, displays: splits.screens(),
            recording: Permissions.screenRecording, accessibility: Permissions.accessibility,
            separateSpaces: Permissions.separateSpacesEnabled, performance: PerformanceLedger.shared.summary,
            capture: splits.active.enumerated().flatMap { index, session in
                session.captureStatistics.enumerated().map { L("分屏 %@.%@：%@", String(describing: index + 1), String(describing: $0.offset + 1), String(describing: $0.element)) }
            })
        reportWindow = documentWindow(title: L("诊断报告预览"), text: reportText, report: true)
    }

    @objc func checkEnvironment() {
        environment = EnvironmentCheck.inspect()
        environmentResult.update(environment, checkedAt: Date())
        if window.isVisible && !settingsPages[3].isHidden {
            NSAccessibility.post(element: window!, notification: .announcementRequested,
                                 userInfo: [.announcement: environment.statusTitle, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
        DemoLog.shared.line(environment.details)
        refresh()
    }

    @objc private func showEnvironment() {
        checkEnvironment()
        showAdvanced()
        selectSettingsPage(settingsNavigation[3])
    }

    private func logStartup() {
        DemoLog.shared.line(environment.details)
        DemoLog.shared.line(L("Panelet 已启动。当前显示器："))
        for screen in DisplayScanner.physicalScreens() {
            let orientation = screen.isPortrait ? L("竖屏") : L("横屏")
            DemoLog.shared.line("\(screen.menuTitle)  \(orientation)  id=\(screen.id)")
        }
        if !Permissions.separateSpacesEnabled {
            DemoLog.shared.line(L("“显示器使用不同的空间”是关闭的。打开后，两个半屏才会各自拥有菜单栏、全屏空间和调度中心。"))
        }
    }

    @objc private func startRefreshing(_ notification: Notification? = nil) {
        guard refreshTimer == nil, hasVisibleInspectorWindow else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                if let self, self.hasVisibleInspectorWindow {
                    self.refresh()
                } else {
                    timer.invalidate()
                    self?.refreshTimer = nil
                }
            }
        }
    }

    private var hasVisibleInspectorWindow: Bool {
        window.isVisible || quick.isVisible || guide.isVisible
    }

    private func refresh() {
        startRefreshing()
        if !splits.busy {
            if quick.isVisible { quick.setProblem(splitProblem, actionTitle: quickSettingsTitle) }
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
        screenRecordingStatus.update(Permissions.screenRecording ? L("已授权") : L("未授权 · 请前往系统设置开启"), ready: Permissions.screenRecording)
        accessibilityStatus.update(Permissions.accessibility ? L("已授权") : L("未授权 · 请前往系统设置开启"), ready: Permissions.accessibility)
        spacesStatus.update(Permissions.separateSpacesEnabled ? L("已打开") : L("未打开 · 开启后需要重新登录 macOS"), ready: Permissions.separateSpacesEnabled)
        recordPermissionButton.title = Permissions.screenRecording ? L("管理权限…") : L("去授权…")
        accessPermissionButton.title = Permissions.accessibility ? L("管理权限…") : L("去授权…")
        applySessionState()
        guide.refreshIfVisible()
    }

    private func reloadPopup(_ screens: [PhysicalScreen]) {
        let previous = selectedDisplayID()
        displays = screens.sorted { $0.id < $1.id }
        displayArrangement.updateDisplays(displays)
        popup.removeAllItems()
        if displays.isEmpty {
            popup.addItem(withTitle: L("没有可用显示器"))
            return
        }
        for (index, screen) in displays.enumerated() {
            let session = splits.sessions[screen.id]
            let mode = session?.hasQuick == true ? L("快捷全屏") : L("桌面拆分")
            let displayTitle = "\(index + 1) · \(screen.menuTitle)"
            let label = session?.active == true ? "\(displayTitle) · \(mode)" : displayTitle
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
        layoutDetail.isHidden = id == nil
        layoutLock.isHidden = session?.active != true
        if let screen = layoutPreview.screen {
            let configuration = session?.configuration ?? screen.configuration
            directionPicker.selectItem(at: DisplayConfiguration.Direction.allCases.firstIndex(of: configuration.direction) ?? 0)
            ratioPicker.selectItem(at: DisplayConfiguration.Ratio.allCases.firstIndex(of: configuration.ratio) ?? 0)
            renderingPicker.selectItem(at: DisplayConfiguration.Rendering.allCases.firstIndex(of: configuration.rendering) ?? 0)
            if aliasDisplayID != id || window.firstResponder !== displayAlias.currentEditor() {
                displayAlias.stringValue = configuration.name
                aliasDisplayID = id
            }
            let sizes = screen.splitLayout.regions.map { "\(Int($0.width))×\(Int($0.height))" }.joined(separator: " / ")
            layoutDetail.stringValue = [L("分区尺寸：%@ 点。", sizes), screen.splitLayout.smallRegionWarning]
                .compactMap { $0 }.joined(separator: "\n")
        }
        for control in [directionPicker, ratioPicker, renderingPicker, displayAlias] as [NSControl] {
            control.isEnabled = id != nil && session == nil && !splits.busy && !restoringAll
        }
        let canCancelDesktopSplit = session?.preparing == true && session?.hasQuick == false && !closing && !restoringAll
        splitButton.title = canCancelDesktopSplit ? L("取消分屏")
            : layoutPreview.screen.map { L("%@拆分桌面", String(describing: $0.splitLayout.direction)) } ?? L("拆分桌面")
        let hasRecovery = hasPendingRecovery
        let problem = splitProblem
        if let transition = splits.transition {
            statusLabel.stringValue = "\(transition.name) · \(transition.status)"
        } else {
            statusLabel.stringValue = session?.status ?? id.flatMap { displayMessages[$0] } ?? problem ?? L("未拆分")
        }
        let activeSession = session.flatMap { $0.active ? $0 : nil }
        let restore = activeSession.map { RestoreAction(session: $0) }
        splitButton.isHidden = session != nil && !canCancelDesktopSplit
        splitButton.isEnabled = canCancelDesktopSplit || (id != nil && problem == nil && operationsAvailable && session == nil)
        popup.isEnabled = id != nil && operationsAvailable
        displayArrangement.updateSelection(id, enabled: popup.isEnabled)
        restoreButton.isHidden = restore == nil
        restoreButton.isEnabled = operationsAvailable && restore != nil
        if let restore { restoreButton.title = restore.menuTitle }
        mergeButton.isHidden = restore != .endPair
        mergeButton.isEnabled = operationsAvailable && restore == .endPair
        retryRecoveryButton.isEnabled = operationsAvailable && hasRecovery
        restoreAllButton.isEnabled = canRestoreAll
        recoveryStatus.textColor = hasRecovery ? .labelColor : .secondaryLabelColor
        recoveryStatus.font = .systemFont(ofSize: 12, weight: hasRecovery ? .medium : .regular)
        if splits.recovering { recoveryStatus.stringValue = L("正在恢复显示器和窗口…") }
        else if let transition = splits.transition, restoringAll || transition.joining { recoveryStatus.stringValue = transition.status }
        else {
            recoveryStatus.stringValue = splits.recoveryProblem ?? splits.sessions.values.first(where: \.needsRecovery)?.status ?? L("没有待恢复的窗口。")
        }

        let restoreActions = splits.active.map { RestoreAction(session: $0) }
        let restoreTitle = restoreActions.first.map { first in
            restoreActions.allSatisfy { $0 == first } ? first.menuTitle : L("还原分屏…")
        }
        let action = L("快捷窗口分屏…")
        statusAction?.title = shortcuts.isRegistered(.toggle) ? "\(action)  \(shortcuts.key(for: .toggle).label)" : action
        statusAction?.isEnabled = operationsAvailable
        for item in [statusJoin, joinMenuItem] {
            item?.title = restoreTitle ?? L("还原分屏…")
            item?.isEnabled = operationsAvailable && restoreTitle != nil
        }
        quick.setRestoreTitle(restoreTitle, enabled: operationsAvailable)
    }

    private var activePairs: [CGDirectDisplayID: [WindowPlacement.Choice]] {
        Dictionary(uniqueKeysWithValues: splits.active.map { ($0.targetID, $0.selectedChoices) })
    }

    private var operationsAvailable: Bool { !splits.busy && !closing && !confirming && !restoringAll }

    private var hasPendingRecovery: Bool { splits.recoveryProblem != nil || splits.sessions.values.contains(where: \.needsRecovery) }

    private var canRestoreAll: Bool { !closing && !confirming && !restoringAll && (!splits.sessions.isEmpty || hasPendingRecovery) }

    private var splitProblem: String? {
        splits.recoveryProblem ?? (hasPendingRecovery
            ? L("有分屏尚未完全恢复，请先从菜单选择“重试恢复窗口…”。") : environment.problem ?? Permissions.splitProblem)
    }

    private var managedWindows: [WindowPlacement.Identity] {
        splits.active.flatMap(\.managedWindows)
    }

    private func selectedDisplayID() -> CGDirectDisplayID? {
        (popup.selectedItem?.representedObject as? NSNumber)?.uint32Value
    }

    private func showQuick() {
        guard operationsAvailable else { return }
        if Permissions.splitProblem != nil {
            preferences.guideStep = .permissions
            showGuide(resume: true)
            return
        }
        guide.hide()
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
                   activePairs: activePairs, recentPairs: recentPairs, excluded: managedWindows,
                   problem: splitProblem, settingsTitle: quickSettingsTitle)
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

    private var quickSettingsTitle: String {
        if hasPendingRecovery { return L("查看恢复…") }
        if environment.problem != nil { return L("查看诊断…") }
        if Permissions.splitProblem != nil { return L("检查权限…") }
        return L("设置…")
    }

    private func showQuickSettings() {
        showAdvanced()
        if hasPendingRecovery || environment.problem != nil { selectSettingsPage(settingsNavigation[3]) }
        else if Permissions.splitProblem != nil { selectSettingsPage(settingsNavigation[2]) }
    }

    @objc private func showAdvanced() {
        if confirming { revealActiveConfirmation(); return }
        guide.hide()
        quick.hide()
        if let screen = splits.hostScreen(at: nil), !window.isVisible || window.screen != screen {
            let visible = screen.visibleFrame
            let desired = window.frameRect(forContentRect: CGRect(x: 0, y: 0, width: 740, height: 560)).size
            window.setFrame(CGRect(origin: window.frame.origin, size: CGSize(width: desired.width, height: min(desired.height, visible.height))), display: false)
            window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                          y: visible.midY - window.frame.height / 2))
        }
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .canJoinAllApplications]
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        refresh()
    }

    private func splitQuick(displayID: CGDirectDisplayID, pair: WindowPlacement.Pair) {
        guard operationsAvailable, splitProblem == nil, (splits.sessions[displayID] == nil || splits.sessions[displayID]?.canStartQuick == true) else { return }
        pendingQuick = (displayID, pair)
        splits.split(displayID, pair: pair)
        if pendingQuick != nil && !splits.busy {
            pendingQuick = nil
            checkEnvironment()
            quick.showFailure(L("未能开始分屏，请检查运行环境或重新选择显示器。"), host: splits.hostScreen(at: nil))
        }
    }

    private func sessionChanged(_ session: Session) {
        let wasGuideRequest = guide.handleSessionChanged(session)
        if session.idle || session.active { displayMessages[session.targetID] = session.status }
        applySessionState()
        let wasQuickRequest = pendingQuick?.displayID == session.targetID
        var quickFailed = false
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
                    quickFailed = session.failed || session.needsRecovery
                }
            }
        }
        if !splits.busy { refresh() }
        if quickFailed && operationsAvailable && !window.isVisible {
            quick.updateDisplays(splits.screens(), activePairs: activePairs, excluded: managedWindows)
            quick.setProblem(splitProblem, actionTitle: quickSettingsTitle)
            quick.showFailure(session.status, host: splits.hostScreen(at: nil))
        } else if session.failed && pendingQuick == nil && !wasQuickRequest && !wasGuideRequest && operationsAvailable {
            showAdvanced()
        }
        if restoringAll && !splits.busy { continueRestoringAll() }
        if closing && !splits.busy && !confirming { finishQuit() }
    }

    private var shortcutInstructions: String {
        let unavailable = GlobalShortcuts.Command.allCases.filter { !shortcuts.isRegistered($0) }
        let labels = unavailable.map { shortcuts.key(for: $0).label }.joined(separator: "、")
        return labels.isEmpty ? L("点击快捷键可修改。") : L("无法注册 %@，点击快捷键可修改。", String(describing: labels))
    }

    private func updateShortcutControls() {
        for (command, menuItem) in [(GlobalShortcuts.Command.toggle, toggleMenuItem), (.join, joinMenuItem)] {
            let key = shortcuts.key(for: command)
            menuItem?.keyEquivalent = key.equivalent
            menuItem?.keyEquivalentModifierMask = key.menuModifiers
            let title = recordingShortcut == command ? L("按下组合键…") : key.label
            shortcutButtons[command]?.title = title
            shortcutButtons[command]?.setAccessibilityLabel(L("%@快捷键，%@", String(describing: command.title), String(describing: title)))
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
        shortcutInfo.stringValue = L("按下新的组合键，Esc 取消。")
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
                    shortcutInfo.stringValue = L("请按住 Control、Option 或 Command，再按一个键。Esc 取消。")
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
        let mutation = logBuffer.append(line)
        if let storage = logView.textStorage {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: logView.font ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: logView.textColor ?? NSColor.labelColor,
            ]
            storage.beginEditing()
            if mutation.prefixUTF16CountToRemove > 0, mutation.prefixUTF16CountToRemove <= storage.length {
                storage.deleteCharacters(in: NSRange(location: 0, length: mutation.prefixUTF16CountToRemove))
            }
            storage.append(NSAttributedString(string: mutation.appendedText, attributes: attributes))
            storage.endEditing()
        } else {
            logView.string = logBuffer.text
        }
        logView.scrollToEndOfDocument(nil)
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        SettingsUI.button(title, target: self, action: action)
    }

    @objc private func displayChanged() { applySessionState() }

    @objc private func splitClicked() {
        guard let id = selectedDisplayID() else { return }
        if let session = splits.sessions[id], session.preparing && !session.hasQuick && !closing && !restoringAll {
            splits.cancelPreparation()
            return
        }
        guard operationsAvailable, splitProblem == nil, splits.sessions[id] == nil else { return }
        splits.split(id)
    }

    @objc private func restoreSelectedDisplay() {
        guard let id = selectedDisplayID(), let session = splits.sessions[id], session.active else { return }
        requestRestore([session])
    }

    @objc private func mergeSelectedDisplay() {
        guard let id = selectedDisplayID(), let session = splits.sessions[id], session.active else { return }
        requestRestore([session], mergeDesktop: true)
    }

    private func restoreShortcut() {
        guard operationsAvailable else { return }
        let pointer = CGEvent(source: nil)?.location
        let pointed = pointer.flatMap { splits.splitDisplay(at: $0) }
        if let pointed, let target = splits.sessions[pointed] { restore(pointed, action: RestoreAction(session: target)) }
        else { chooseRestore() }
    }

    @objc private func chooseRestore() {
        let pointer = CGEvent(source: nil)?.location
        let preferred = (quick.isVisible ? quick.targetDisplayID : nil) ?? pointer.flatMap { splits.splitDisplay(at: $0) }
        requestRestore(splits.active.sorted { $0.targetID < $1.targetID }, preferredID: preferred)
    }

    private func requestRestore(_ sessions: [Session], preferredID: CGDirectDisplayID? = nil, mergeDesktop: Bool = false) {
        guard operationsAvailable, !sessions.isEmpty else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let previous = front?.processIdentifier == getpid() ? previousApp : front
        let focusedDisplay = previous.flatMap(WindowPlacement.focusedWindowFrame).flatMap { frame in
            splits.splitDisplay(at: CGPoint(x: frame.midX, y: frame.midY))
        }
        let actions = sessions.map { RestoreAction(session: $0, mergeDesktop: mergeDesktop) }
        let initialIndex = sessions.firstIndex(where: { $0.targetID == preferredID }) ?? 0
        let initialAction = actions[initialIndex]
        let alert = NSAlert()
        alert.messageText = sessions.count == 1 ? initialAction.prompt(for: sessions[0].name) : L("还原哪块显示器？")
        alert.informativeText = initialAction.detail
        let selection = RestoreDisplayPicker()
        if sessions.count > 1 {
            let displayIDs = splits.screens().map(\.id).sorted()
            selection.addItems(withTitles: sessions.map { session in
                guard let index = displayIDs.firstIndex(of: session.targetID) else { return session.name }
                return "\(index + 1) · \(session.name)"
            })
            selection.selectItem(at: initialIndex)
            selection.setAccessibilityLabel(L("要还原的显示器"))
            selection.target = selection
            selection.action = #selector(RestoreDisplayPicker.selectionChanged)
            selection.sizeToFit()
            alert.accessoryView = selection
        }
        presentConfirmation(alert, action: initialAction.title, destructive: false, preserving: previous, configureAction: { alert, confirm in
            selection.onSelect = { [weak alert, weak confirm] index in
                guard actions.indices.contains(index), let alert, let confirm else { return }
                alert.informativeText = actions[index].detail
                confirm.title = actions[index].title
                alert.layout()
            }
        }) { [weak self] in
            guard let self, self.operationsAvailable else { return }
            let index = sessions.count == 1 ? 0 : selection.indexOfSelectedItem
            guard sessions.indices.contains(index) else { return }
            let target = sessions[index]
            let action = actions[index]
            guard let current = self.splits.sessions[target.targetID], current.active else { return }
            let currentAction = RestoreAction(session: current, mergeDesktop: mergeDesktop)
            guard current === target, currentAction == action else {
                self.requestRestore([current], mergeDesktop: mergeDesktop)
                return
            }
            if let focusedDisplay, focusedDisplay != target.targetID, NSApp.isActive { previous?.activate() }
            self.restore(target.targetID, action: action)
        }
    }

    private func restore(_ id: CGDirectDisplayID, action: RestoreAction) {
        quick.hide()
        switch action {
        case .mergeDesktop, .endPairAndRestore: splits.join(id)
        case .endPair: splits.endQuick(id)
        }
    }

    private func revealActiveConfirmation() {
        let host = confirmationPanel ?? (quick.confirmationWindow?.attachedSheet != nil ? quick.confirmationWindow : nil) ?? window
        if let host {
            if host.windowNumber > 0 {
                _ = SystemBridge.Accessibility.focusSpecificWindow(CGWindowID(host.windowNumber), pid: getpid())
            }
            NSApp.activate()
            host.makeKeyAndOrderFront(nil)
        }
    }

    private func presentConfirmation(_ alert: NSAlert, action: String, destructive: Bool = true,
                                     preserving previous: NSRunningApplication? = nil, configureAction: ((NSAlert, NSButton) -> Void)? = nil,
                                     cancelled: (() -> Void)? = nil, confirmed: @escaping () -> Void) {
        if confirming { revealActiveConfirmation(); return }
        confirmationAlert = alert
        applySessionState()
        alert.addButton(withTitle: L("取消")).keyEquivalent = "\u{1b}"
        let confirm = alert.addButton(withTitle: action)
        confirm.hasDestructiveAction = destructive
        confirm.keyEquivalent = ""
        configureAction?(alert, confirm)

        let host: NSWindow
        let restoreQuickHideOnDeactivate: NSPanel?
        if window.isVisible {
            if !window.isKeyWindow {
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
            }
            host = window
            restoreQuickHideOnDeactivate = nil
        } else if let panel = quick.confirmationWindow as? NSPanel {
            panel.hidesOnDeactivate = false
            host = panel
            restoreQuickHideOnDeactivate = panel
        } else {
            let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 380, height: 70), styleMask: [.titled, .utilityWindow],
                                backing: .buffered, defer: false)
            panel.title = "Panelet"
            panel.isReleasedWhenClosed = false
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .canJoinAllApplications]
            if let screen = splits.hostScreen(at: nil) {
                let visible = screen.visibleFrame
                panel.setFrameOrigin(CGPoint(x: visible.midX - panel.frame.width / 2, y: visible.midY - 38))
            } else { panel.center() }
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
            if panel.windowNumber > 0 {
                _ = SystemBridge.Accessibility.focusSpecificWindow(CGWindowID(panel.windowNumber), pid: getpid())
            }
            confirmationPanel = panel
            host = panel
            restoreQuickHideOnDeactivate = nil
        }
        alert.beginSheetModal(for: host) { [weak self] response in
            guard let self else { return }
            restoreQuickHideOnDeactivate?.hidesOnDeactivate = true
            let hadTemporaryHost = self.confirmationPanel != nil
            self.confirmationPanel?.orderOut(nil)
            self.confirmationPanel = nil
            self.confirmationAlert = nil
            self.applySessionState()
            if response == .alertSecondButtonReturn { confirmed() }
            else {
                cancelled?()
                if hadTemporaryHost && NSApp.isActive { previous?.activate() }
            }
        }
    }

    @objc private func quitClicked() { requestQuit(relaunch: false) }

    private func requestQuit(relaunch: Bool) {
        if confirming { revealActiveConfirmation(); return }
        if closing { offerIncompleteExit(); return }
        if splits.sessions.isEmpty {
            shouldRelaunch = relaunch
            NSApp.terminate(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = relaunch ? L("合并分屏并重新启动？") : L("合并分屏并退出？")
        alert.informativeText = L("App 会先还原各块显示器及其窗口。")
        presentConfirmation(alert, action: relaunch ? L("合并并重新启动") : L("合并并退出")) { [weak self] in
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
        alert.messageText = L("窗口还没有完全恢复")
        alert.informativeText = L("仍然退出会结束分屏，部分窗口的位置或全屏状态可能暂时改变。恢复记录会保留，下次启动时继续尝试恢复。也可以取消退出，稍后重试。")
        let action = shouldRelaunch ? L("仍然重新启动") : L("仍然退出")
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

    @objc func retryRecovery() {
        guard operationsAvailable else { return }
        if splits.recoveryProblem != nil {
            Task { await splits.recoverPreviousSession(); refresh() }
            return
        }
        guard let session = splits.sessions.values.first(where: \.needsRecovery) else { return }
        if session.active && session.mode == .desktop && session.hasQuick { splits.endQuick(session.targetID) }
        else { splits.join(session.targetID) }
    }

    @objc private func askScreenRecording() {
        Permissions.requestScreenRecording()
        DemoLog.shared.line(L("如果系统设置里还没有本 App，用 + 号把 Panelet.app 加进去，勾选后点“重新启动”。"))
    }

    @objc private func askAccessibility() {
        Permissions.requestAccessibility()
        DemoLog.shared.line(L("请在辅助功能中勾选正在运行的这份 App，然后点“重新启动”。"))
    }

    @objc private func openDesktopSettings() {
        Permissions.openDesktopSettings()
    }

    @objc private func relaunch() {
        requestQuit(relaunch: true)
    }
}

private extension AppController {
    @objc func saveDisplayPreferences() {
        guard let id = selectedDisplayID(), splits.sessions[id] == nil, !splits.busy,
              let screen = displays.first(where: { $0.id == id }) else { return }
        var configuration = screen.configuration
        configuration.name = String(displayAlias.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        configuration.direction = DisplayConfiguration.Direction.allCases[max(0, directionPicker.indexOfSelectedItem)]
        configuration.ratio = DisplayConfiguration.Ratio.allCases[max(0, ratioPicker.indexOfSelectedItem)]
        configuration.rendering = DisplayConfiguration.Rendering.allCases[max(0, renderingPicker.indexOfSelectedItem)]
        preferences.save(configuration, for: screen.uuid)
        lastScreenKey = ""
        refresh()
    }

    @objc func identifyDisplays() { identifiers.show(splits.screens()) }

    @objc func changeLanguage() {
        UserDefaults.standard.set(["system", "zh-Hans", "en"][max(0, languagePicker.indexOfSelectedItem)], forKey: "interfaceLanguage")
        let alert = NSAlert()
        alert.messageText = L("重新启动以应用语言更改？")
        alert.informativeText = L("你也可以稍后从菜单重新启动，当前分屏不会立即改变。")
        alert.addButton(withTitle: L("稍后"))
        alert.addButton(withTitle: L("重新启动 Panelet"))
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn { self?.requestQuit(relaunch: true) }
        }
    }

    @objc func saveGeneralPreferences() {
        preferences.showPanelOnLaunch = launchPanel.state == .on
        preferences.automaticStart = automaticStart.state == .on
    }

    func updateLoginStatus() {
        let status = SMAppService.mainApp.status
        loginItem.state = status == .enabled || status == .requiresApproval ? .on : .off
        loginStatus.stringValue = status == .requiresApproval
            ? L("请在系统登录项设置中允许 Panelet。")
            : (status == .enabled ? L("已开启；登录后不会自动拆分桌面。") : L("未开启；仅在你主动打开时运行。"))
    }

    @objc func changeLoginItem() {
        do {
            if loginItem.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            updateLoginStatus()
        } catch {
            updateLoginStatus()
            loginStatus.stringValue = L("未能更改登录启动，请在系统登录项设置中检查。")
            DemoLog.shared.line(error.localizedDescription)
        }
    }

    @objc func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    @objc func restoreAll() {
        guard canRestoreAll else { return }
        let alert = NSAlert()
        alert.messageText = L("恢复所有显示器？")
        alert.informativeText = L("结束所有窗口组合，将独立桌面合并为整块显示器，并尝试恢复窗口。应用会继续运行。")
        presentConfirmation(alert, action: L("恢复所有显示器"), destructive: false) { [weak self] in
            guard let self else { return }
            self.quick.hide()
            self.restoringAll = true
            self.restoreAttempts.removeAll()
            self.splits.cancelPreparation()
            self.continueRestoringAll()
        }
    }

    func continueRestoringAll() {
        guard restoringAll, !splits.busy else { return }
        if let session = splits.sessions.values.sorted(by: { $0.targetID < $1.targetID })
            .first(where: { !restoreAttempts.contains($0.targetID) && ($0.active || $0.needsRecovery) }) {
            restoreAttempts.insert(session.targetID)
            splits.join(session.targetID)
            return
        }
        if splits.recoveryProblem != nil {
            Task {
                await splits.recoverPreviousSession()
                finishRestoringAll()
            }
        } else { finishRestoringAll() }
    }

    func finishRestoringAll() {
        restoringAll = false
        let remaining = splits.sessions.values.filter(\.needsRecovery).count
        DemoLog.shared.line(remaining == 0 && splits.recoveryProblem == nil
            ? L("已完成全部显示器恢复。")
            : L("仍有恢复项目未完成。已保留恢复记录，请在诊断页重试。"))
        refresh()
        showAdvanced()
        selectSettingsPage(settingsNavigation[3])
    }

    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Panelet",
            .credits: NSAttributedString(string: L("一块屏幕，两个独立工作空间。"))
        ])
    }

    @objc func showHelp() {
        helpWindow?.close()
        helpWindow = documentWindow(title: L("Panelet 帮助、隐私与兼容性"), text: L("独立桌面与双窗口全屏\n独立桌面长期保留，每个分区可单独使用原生全屏；临时双窗口组合在任一窗口退出全屏后结束，保留进入前已有的桌面拆分。\n\n日常操作\n默认 Control–Shift–S 打开选窗面板，Control–Shift–J 还原当前分屏。快捷键可在设置中修改。选窗时可搜索、使用方向键和回车，也可拖放窗口。选好两个窗口后可交换位置，再按回车或点击开始。\n\n收藏组合\n选好两个窗口后点击收藏。收藏只在本机保存应用标识与用于匹配的窗口标题，不保存窗口画面。使用收藏时重新查找当前窗口，不会自动启动应用；无法确定窗口时需要重新选择。删除收藏会移除该条本地记录。\n\n布局与画面\n在桌面分屏设置中选择显示器，可改为上下或左右布局，比例支持 1:1、2:1、1:2。必须先合并该屏幕才能修改。自动和清晰优先保留原生缩放并将目标帧率限制为 60 Hz；流畅优先使用 1× 画面，目标帧率最高 120 Hz，文字清晰度可能降低。实际帧率取决于系统和负载。\n\n隐私\n屏幕录制用于本机桌面合成与窗口预览，不录制音频，不上传画面。辅助功能用于选窗、移动和恢复窗口及鼠标处理。应用不包含统计上报；偏好和收藏保存在本机。恢复记录不含窗口标题或画面，正常恢复完成后删除。诊断报告由你预览、复制或导出，不会自动发送，报告排除了窗口标题、应用列表、显示器名称和文件路径。\n\n兼容性\n需要 macOS 14 或以上，以及屏幕录制、辅助功能权限和“显示器使用不同的空间”。虚拟显示器依赖系统私有接口：环境检测只能确认接口是否存在，系统更新后仍可能改变行为。受保护视频或禁止采集的窗口可能显示黑屏；HDR、广色域和高刷新率显示效果需在目标设备上验证，当前不承诺色彩校准用途。\n\n遇到问题\n菜单栏“恢复所有显示器”会结束分屏并恢复桌面，不会退出应用。部分窗口无法恢复时，可在诊断页重试。不要强制结束进程；正常退出会先合并桌面。提交问题前，可在诊断页预览脱敏报告，再自行附到问题反馈中。"), report: false)
    }

    func documentWindow(title: String, text: String, report: Bool) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 520),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 480, height: 320)
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 13)
        textView.string = text
        textView.textContainerInset = CGSize(width: 16, height: 16)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel(title)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = textView
        let actions = report
            ? [button(L("复制报告"), action: #selector(copyReport)), button(L("导出文本…"), action: #selector(exportReport))]
            : [button(L("问题反馈…"), action: #selector(openFeedback))]
        let footer = NSStackView(views: actions)
        footer.spacing = 10
        let root = NSView()
        window.contentView = root
        for view in [scroll, footer] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16), footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14)
        ])
        if let screen = splits.hostScreen(at: nil) {
            window.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - 320, y: screen.visibleFrame.midY - 260))
        } else { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    @objc func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reportText, forType: .string)
    }

    @objc func exportReport() {
        guard let reportWindow else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Panelet-diagnostics.txt"
        panel.beginSheetModal(for: reportWindow) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do { try self.reportText.write(to: url, atomically: true, encoding: .utf8) }
            catch { let alert = NSAlert(error: error); alert.beginSheetModal(for: reportWindow) }
        }
    }

    @objc func openFeedback() {
        NSWorkspace.shared.open(URL(string: "https://github.com/rankangkang/panelet/issues")!)
    }
}

// The guide deliberately shares the settings typography, cards and layout renderer.
private extension AppController {
    @objc func openGuide() { showGuide(resume: preferences.guideStep != .complete) }
    @objc func restartGuide() { showGuide(resume: false) }

    func showGuide(resume: Bool) {
        guard operationsAvailable else { return }
        quick.hide()
        window.orderOut(nil)
        guide.show(resume: resume)
        startRefreshing()
    }
}
