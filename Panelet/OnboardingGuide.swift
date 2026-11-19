import AppKit

/// Self-contained controller for the first-launch Onboarding Guide and optional trial split.
@MainActor
final class OnboardingGuideController: NSObject, NSWindowDelegate {
    struct EnvironmentSnapshot {
        let operationsAvailable: Bool
        let closing: Bool
        let confirming: Bool
        let restoringAll: Bool
        let splitProblem: String?
        let hasPendingRecovery: Bool
    }

    private let splits: SplitSessions
    private let preferences: ProductPreferences

    var snapshotProvider: (() -> EnvironmentSnapshot)?
    var onShowSettings: (() -> Void)?
    var onRelaunchRequested: (() -> Void)?
    var onRetryRecovery: (() -> Void)?
    var onCheckEnvironment: (() -> Void)?
    var onDraftSaved: (() -> Void)?

    private var guideWindow: NSWindow?
    private var guideBody: NSStackView?
    private var guideScroll: NSScrollView?
    private var guidePrimary: NSButton?
    private var guideBack: NSButton?
    private var guideProgress: NSTextField?
    private var guideDisplayID: CGDirectDisplayID?
    private var guideDrafts: [String: DisplayConfiguration] = [:]
    private var guideTrialConfiguration: (uuid: String, configuration: DisplayConfiguration)?
    private(set) var pendingDisplayID: CGDirectDisplayID?
    private var guideMessage: String?
    private var guideSignature = ""
    private var guideRequestedPermission = false
    private var guideShowingTrial = false
    private var guideTrialPreview: SettingsLayoutPreview?
    private var guideTrialWarning: NSTextField?

    var isVisible: Bool { guideWindow?.isVisible == true }

    init(splits: SplitSessions, preferences: ProductPreferences) {
        self.splits = splits
        self.preferences = preferences
        super.init()
    }

    func hide() {
        guideWindow?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard pendingDisplayID == nil else { return false }
        preferences.guideDeferred = preferences.guideStep != .complete
        return true
    }

    func show(resume: Bool) {
        let env = currentSnapshot()
        guard env.operationsAvailable else { return }
        if !resume {
            preferences.guideStep = .welcome
            guideMessage = nil
            guideDisplayID = nil
            guideDrafts.removeAll()
        }
        guideShowingTrial = false
        preferences.guideDeferred = false
        guideSignature = ""
        ensureWindowCreated()
        render()
        if let screen = splits.hostScreen(at: nil), let guideWindow {
            let visible = screen.visibleFrame
            let size = guideWindow.frame.size
            guideWindow.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        } else {
            guideWindow?.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        guideWindow?.makeKeyAndOrderFront(nil)
    }

    func refreshIfVisible() {
        guard isVisible else { return }
        let env = currentSnapshot()
        let screens = splits.screens()
        let signature = "\(Permissions.screenRecording):\(Permissions.accessibility):\(Permissions.separateSpacesEnabled):\(splits.busy):\(env.closing):\(env.confirming):\(env.restoringAll):\(env.splitProblem ?? ""):\(screens.map { "\($0.id):\($0.bounds):\(splits.sessions[$0.id]?.active == true)" })"
        if guideSignature != signature {
            guideSignature = signature
            render()
        }
    }

    /// Returns `true` if `session` belonged to an in-flight guide trial request.
    func handleSessionChanged(_ session: Session) -> Bool {
        let wasGuideRequest = pendingDisplayID == session.targetID
        guard wasGuideRequest else { return false }
        if session.idle || session.active {
            let succeeded = session.active && !session.failed && !session.needsRecovery
            if succeeded {
                if let draft = guideTrialConfiguration {
                    preferences.save(draft.configuration, for: draft.uuid)
                    guideDrafts[draft.uuid] = nil
                    onDraftSaved?()
                }
                pendingDisplayID = nil
                guideMessage = nil
                guideShowingTrial = false
                preferences.finishGuide(permissionsReady: Permissions.splitProblem == nil)
            } else {
                pendingDisplayID = nil
                guideMessage = session.status
            }
            guideTrialConfiguration = nil
            render()
        }
        return true
    }

    private func currentSnapshot() -> EnvironmentSnapshot {
        snapshotProvider?() ?? EnvironmentSnapshot(
            operationsAvailable: !splits.busy,
            closing: false,
            confirming: false,
            restoringAll: false,
            splitProblem: Permissions.splitProblem,
            hasPendingRecovery: false
        )
    }

    private func ensureWindowCreated() {
        guard guideWindow == nil else { return }
        let panel = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 552, height: 438),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = L("Panelet · 使用导引")
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.titlebarAppearsTransparent = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .canJoinAllApplications]
        let root = SettingsBackgroundView()
        panel.contentView = root
        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 16
        let scroll = SettingsUI.topAlignedScroll(body, insets: NSEdgeInsets(top: 0, left: 10, bottom: 18, right: 10))
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        let back = SettingsUI.button(L("稍后设置"), target: self, action: #selector(backClicked))
        let primary = SettingsUI.button(L("开始设置"), target: self, action: #selector(nextClicked))
        primary.bezelColor = .controlAccentColor
        primary.keyEquivalent = "\r"
        let progress = SettingsUI.text("", size: 11, secondary: true)
        let footer = NSStackView(views: [back, NSView(), progress, NSView(), primary])
        footer.spacing = 12
        footer.alignment = .centerY
        footer.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(footer)
        root.addSubview(line)
        NSLayoutConstraint.activate([
            progress.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            scroll.bottomAnchor.constraint(equalTo: line.topAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            line.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),
        ])
        guideBody = body
        guideScroll = scroll
        guidePrimary = primary
        guideBack = back
        guideProgress = progress
        guideWindow = panel
    }

    private func render() {
        guard let body = guideBody, let primary = guidePrimary, let back = guideBack else { return }
        if preferences.guideStep == .ready && Permissions.splitProblem != nil && pendingDisplayID == nil {
            preferences.guideStep = .permissions
            guideShowingTrial = false
        }
        for view in body.arrangedSubviews {
            body.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guideTrialPreview = nil
        guideTrialWarning = nil
        let step = preferences.guideStep
        let env = currentSnapshot()
        let available = env.operationsAvailable
        back.isEnabled = available
        primary.isEnabled = available
        primary.keyEquivalent = "\r"
        back.title = step == .welcome ? L("稍后设置") : L("上一步")
        switch step {
        case .welcome:
            guideProgress?.stringValue = "1 / 2"
            let icon = NSImageView(image: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
            icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 48).isActive = true
            icon.setAccessibilityElement(false)
            body.addArrangedSubview(icon)
            body.addArrangedSubview(
                SettingsUI.sectionHeading(
                    L("一块屏幕，多个专注空间"),
                    detail: L("把显示器拆成独立分区，让工作与参考各就各位。")
                )
            )
            let preview = SettingsLayoutPreview()
            var config = DisplayConfiguration()
            config.direction = .horizontal
            preview.screen = PhysicalScreen(
                id: 0, name: "Panelet", bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                scale: 1, refreshRate: 60, isBuiltin: false, configuration: config
            )
            preview.heightAnchor.constraint(equalToConstant: 150).isActive = true
            body.addArrangedSubview(preview)
            primary.title = L("开始设置")
        case .permissions, .ready:
            if guideShowingTrial {
                renderTrial(in: body, primary: primary, env: env)
                break
            }
            guideProgress?.stringValue = "2 / 2"
            let permissionsReady = Permissions.splitProblem == nil
            let needsRestart = guideRequestedPermission && !permissionsReady
            let detail = permissionsReady ? L("可以从菜单栏随时开始分屏。") : L("分屏需要以下权限，点击后前往系统设置开启。")
            body.addArrangedSubview(
                SettingsUI.sectionHeading(permissionsReady ? L("权限已就绪") : L("让 Panelet 帮你安排桌面"), detail: detail)
            )
            let record: NSView = Permissions.screenRecording
                ? SettingsUI.text(L("✓ 已授权"), size: 12)
                : SettingsUI.button(L("去授权…"), target: self, action: #selector(askRecording))
            let access: NSView = Permissions.accessibility
                ? SettingsUI.text(L("✓ 已授权"), size: 12)
                : SettingsUI.button(L("去授权…"), target: self, action: #selector(askAccessibility))
            (record as? NSButton)?.isEnabled = available
            (access as? NSButton)?.isEnabled = available
            body.addArrangedSubview(SettingsUI.card([
                SettingsUI.row(L("屏幕录制"), detail: L("显示分区画面和窗口预览。"), control: record),
                SettingsUI.row(L("辅助功能"), detail: L("移动窗口，并处理分屏间的鼠标操作。"), control: access),
            ]))
            if Permissions.separateSpacesEnabled {
                body.addArrangedSubview(SettingsUI.text(L("✓ 显示器使用不同的空间已开启"), size: 12, secondary: true))
            } else {
                body.addArrangedSubview(SettingsUI.card([
                    SettingsUI.text(L("请在「桌面与程序坞」打开「显示器使用不同的空间」，重新登录后再拆分。"), size: 12),
                    SettingsUI.button(L("系统设置…"), target: self, action: #selector(openDesktopSettings)),
                ]))
            }
            if permissionsReady {
                let trial = SettingsUI.button(L("试一次分屏…"), target: self, action: #selector(showTrial))
                trial.isEnabled = available
                body.addArrangedSubview(trial)
            } else {
                body.addArrangedSubview(SettingsUI.text(
                    needsRestart
                        ? L("已在系统设置开启？请重新启动 Panelet，导引会继续检查权限。")
                        : L("从系统设置返回后，会自动检查权限状态。"),
                    size: 12,
                    secondary: true
                ))
            }
            primary.title = needsRestart ? L("重新启动并继续") : L("完成设置")
            primary.isEnabled = available && (permissionsReady || needsRestart)
        case .complete:
            guideProgress?.stringValue = ""
            let hasSplit = !splits.active.isEmpty
            let detail = hasSplit ? L("分屏已就绪，可以开始工作了。") : L("从菜单栏的 Panelet 图标选择「拆分桌面」或「快捷窗口分屏」。")
            body.addArrangedSubview(SettingsUI.sectionHeading(L("设置完成"), detail: detail))
            if hasSplit {
                body.addArrangedSubview(SettingsUI.card([
                    SettingsUI.text(L("随时回到完整屏幕"), weight: .semibold),
                    SettingsUI.text(L("在菜单中选择「恢复所有显示器…」。"), size: 12, secondary: true),
                ]))
            }
            back.title = L("查看设置")
            primary.title = L("完成")
        }
        for view in body.arrangedSubviews where !(view is NSImageView) && !(view is NSButton) {
            view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        guideWindow?.contentView?.layoutSubtreeIfNeeded()
        if let scroll = guideScroll {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private func renderTrial(in body: NSStackView, primary: NSButton, env: EnvironmentSnapshot) {
        let available = env.operationsAvailable
        guideProgress?.stringValue = L("可选")
        primary.keyEquivalent = ""
        body.addArrangedSubview(
            SettingsUI.sectionHeading(
                L("试一次分屏"),
                detail: L("选择一个显示器和布局，开始后会把这块显示器拆成两个桌面。")
            )
        )
        let screens = splits.screens()
        if !screens.contains(where: { $0.id == guideDisplayID }) {
            guideDisplayID = (screens.first { splits.sessions[$0.id] == nil } ?? screens.first)?.id
        }
        let picker = NSPopUpButton()
        picker.target = self
        picker.action = #selector(displayChanged(_:))
        picker.setAccessibilityLabel(L("目标显示器"))
        for screen in screens {
            picker.addItem(withTitle: screen.menuTitle)
            picker.lastItem?.representedObject = NSNumber(value: screen.id)
        }
        if let index = screens.firstIndex(where: { $0.id == guideDisplayID }) { picker.selectItem(at: index) }
        if screens.isEmpty { picker.addItem(withTitle: L("没有可用显示器")) }
        picker.isEnabled = available && screens.count > 1
        var controls: [NSView] = [SettingsUI.text(L("目标显示器"), size: 12, weight: .semibold), picker]
        var hasActiveDesktop = false
        if var screen = screens.first(where: { $0.id == guideDisplayID }) {
            let session = splits.sessions[screen.id]
            hasActiveDesktop = session?.active == true
            screen.configuration = session?.configuration ?? guideDrafts[screen.uuid] ?? screen.configuration
            let preview = SettingsLayoutPreview()
            preview.screen = screen
            let direction = NSPopUpButton()
            let ratio = NSPopUpButton()
            controls.append(SettingsUI.layoutEditor(preview: preview, direction: direction, ratio: ratio))
            let warning = SettingsUI.text(screen.splitLayout.smallRegionWarning ?? "", size: 12, secondary: true)
            warning.isHidden = screen.splitLayout.smallRegionWarning == nil
            controls.append(warning)
            guideTrialPreview = preview
            guideTrialWarning = warning
            direction.selectItem(at: DisplayConfiguration.Direction.allCases.firstIndex(of: screen.configuration.direction) ?? 0)
            direction.target = self
            direction.action = #selector(directionChanged(_:))
            ratio.selectItem(at: DisplayConfiguration.Ratio.allCases.firstIndex(of: screen.configuration.ratio) ?? 0)
            ratio.target = self
            ratio.action = #selector(ratioChanged(_:))
            direction.isEnabled = available && session == nil
            ratio.isEnabled = direction.isEnabled
            if hasActiveDesktop {
                controls.append(SettingsUI.text(L("这块显示器已在分屏。合并后可以更改布局。"), size: 12, secondary: true))
            }
        }
        if let message = guideMessage ?? env.splitProblem {
            controls.append(SettingsUI.text(message, size: 12, secondary: true))
        }
        if env.hasPendingRecovery {
            let retry = SettingsUI.button(L("重试恢复…"), target: self, action: #selector(retryRecoveryClicked))
            retry.isEnabled = available
            controls.append(retry)
        }
        body.addArrangedSubview(SettingsUI.card(controls))
        if pendingDisplayID != nil {
            primary.title = splits.transition?.preparing == true ? L("正在分屏…") : L("正在恢复…")
            primary.isEnabled = false
        } else {
            primary.title = hasActiveDesktop ? L("完成设置") : L("开始分屏")
            primary.isEnabled = available && (hasActiveDesktop || (guideDisplayID != nil && env.splitProblem == nil))
        }
    }

    @objc private func backClicked() {
        guard currentSnapshot().operationsAvailable, pendingDisplayID == nil else { return }
        if guideShowingTrial {
            guideShowingTrial = false
            guideMessage = nil
            render()
            return
        }
        switch preferences.guideStep {
        case .welcome:
            preferences.guideDeferred = true
            hide()
        case .permissions, .ready:
            preferences.guideStep = .welcome
            render()
        case .complete:
            hide()
            onShowSettings?()
        }
    }

    @objc private func nextClicked() {
        guard currentSnapshot().operationsAvailable, pendingDisplayID == nil else { return }
        switch preferences.guideStep {
        case .welcome:
            preferences.guideStep = Permissions.splitProblem == nil ? .ready : .permissions
            render()
        case .permissions, .ready:
            if guideShowingTrial {
                startTrial()
            } else if Permissions.splitProblem != nil && guideRequestedPermission {
                preferences.guideRestartPending = true
                preferences.guideDeferred = false
                onRelaunchRequested?()
            } else {
                preferences.finishGuide(permissionsReady: Permissions.splitProblem == nil)
                render()
            }
        case .complete:
            hide()
        }
    }

    @objc private func showTrial() {
        guard currentSnapshot().operationsAvailable, Permissions.splitProblem == nil else { return }
        guideShowingTrial = true
        guideMessage = nil
        render()
    }

    private func startTrial() {
        let env = currentSnapshot()
        guard let id = guideDisplayID, let screen = splits.screens().first(where: { $0.id == id }) else {
            render()
            return
        }
        if splits.sessions[id]?.active == true {
            guideShowingTrial = false
            preferences.finishGuide(permissionsReady: Permissions.splitProblem == nil)
            render()
            return
        }
        guard splits.sessions[id] == nil, env.splitProblem == nil else { return }
        let uuid = screen.uuid
        let draft = guideDrafts[uuid]
        guideTrialConfiguration = draft.map { (uuid, $0) }
        guideMessage = nil
        pendingDisplayID = id
        splits.split(id, configuration: draft)
        if pendingDisplayID != nil && splits.sessions[id] == nil {
            onCheckEnvironment?()
            guideTrialConfiguration = nil
            pendingDisplayID = nil
            guideMessage = L("未能开始分屏，请检查运行环境或重新选择显示器。")
        }
        render()
    }

    @objc private func askRecording() {
        guideRequestedPermission = true
        Permissions.requestScreenRecording()
        render()
    }

    @objc private func askAccessibility() {
        guideRequestedPermission = true
        Permissions.requestAccessibility()
        render()
    }

    @objc private func openDesktopSettings() {
        Permissions.openDesktopSettings()
    }

    @objc private func retryRecoveryClicked() {
        onRetryRecovery?()
    }

    @objc private func displayChanged(_ sender: NSPopUpButton) {
        guideDisplayID = (sender.selectedItem?.representedObject as? NSNumber)?.uint32Value
        guideMessage = nil
        render()
    }

    private func changeLayout(_ update: (inout DisplayConfiguration) -> Void) {
        guard currentSnapshot().operationsAvailable, guideShowingTrial,
              var screen = splits.screens().first(where: { $0.id == guideDisplayID }),
              splits.sessions[screen.id] == nil else { return }
        let uuid = screen.uuid
        var draft = guideDrafts[uuid] ?? screen.configuration
        update(&draft)
        guideDrafts[uuid] = draft
        screen.configuration = draft
        guideTrialPreview?.screen = screen
        let warning = screen.splitLayout.smallRegionWarning
        guideTrialWarning?.stringValue = warning ?? ""
        guideTrialWarning?.isHidden = warning == nil
    }

    @objc private func directionChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard DisplayConfiguration.Direction.allCases.indices.contains(index) else { return }
        changeLayout { $0.direction = DisplayConfiguration.Direction.allCases[index] }
    }

    @objc private func ratioChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard DisplayConfiguration.Ratio.allCases.indices.contains(index) else { return }
        changeLayout { $0.ratio = DisplayConfiguration.Ratio.allCases[index] }
    }
}
