import AppKit

@MainActor
final class QuickSplitPanel: NSObject, NSWindowDelegate, NSSearchFieldDelegate {
    var onSplit: ((CGDirectDisplayID, WindowPlacement.Pair) -> Void)?
    var onAdvanced: (() -> Void)?
    var onCancel: (() -> Void)?
    var onJoin: (() -> Void)?
    var isVisible: Bool { panel.isVisible }
    var isFocused: Bool { NSApp.isActive && panel.isVisible && panel.isKeyWindow }
    var targetDisplayID: CGDirectDisplayID? { selectedDisplayID }
    var confirmationWindow: NSWindow? { isVisible ? panel : nil }

    private static let minimumContentSize = NSSize(width: 500, height: 430)
    private static let maximumContentSize = NSSize(width: 1160, height: 900)
    private static let horizontalInset: CGFloat = 16
    private static let screenInset: CGFloat = 12
    private let panel = SplitPanelWindow(
        contentRect: NSRect(x: 0, y: 0, width: 540, height: 610),
        styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false
    )
    private let displayMap = DisplayArrangementView()
    private let displayName = NSTextField(labelWithString: "")
    private let selectionTitle = NSTextField(labelWithString: "")
    private let search = NSSearchField()
    private let grid = WindowPreviewGrid(frame: .zero)
    private let resultsArea = NSView()
    private let emptyResults = NSStackView()
    private let emptyMessage = NSTextField(labelWithString: "")
    private let emptyAction = NSButton()
    private lazy var mapHeight = displayMap.heightAnchor.constraint(equalToConstant: 128)
    private let dragPreview = CardDragPreview()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let advanced = NSButton()
    private let join = NSButton()
    private let primary = NSButton()
    private let swap = NSButton(title: L("交换位置"), target: nil, action: nil)
    private let favorites = NSPopUpButton()
    private let saveFavorite = NSButton(title: L("收藏…"), target: nil, action: nil)
    private let deleteFavorite = NSButton(title: L("删除收藏"), target: nil, action: nil)
    private let preferences = ProductPreferences()
    private var favoriteID: UUID?
    private let content = NSStackView()
    private let picker = NSStackView()
    private let footer = NSStackView()
    private let emptySpace = NSView()

    private var screens: [PhysicalScreen] = []
    private var choices: [WindowPlacement.Choice] = []
    private var results: [WindowPlacement.Choice] = []
    private var selected: [WindowPlacement.Choice?] = [nil, nil]
    private var selectedDisplayID: CGDirectDisplayID?
    private var activePairs: [CGDirectDisplayID: [WindowPlacement.Choice]] = [:]
    private var recentPairs: [CGDirectDisplayID: WindowPlacement.Pair] = [:]
    private var excluded: [WindowPlacement.Identity] = []
    private var slot = 0
    private var blocker: String?
    private var busy = false
    private var canCancel = false
    private var sessionMessage: String?
    private var failed = false
    private var replacingWindow = false
    private var draggedChoice: WindowPlacement.Choice?
    private var choiceTask: Task<Void, Never>?
    private var hostFrame: CGRect?
    private let workspaceNotifications = NSWorkspace.shared.notificationCenter
    private var terminationObserver: NSObjectProtocol?

    override init() {
        super.init()
        terminationObserver = workspaceNotifications.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                                object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in self?.applicationTerminated(pid) }
        }
        panel.title = L("Panelet · 快捷窗口分屏")
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .canJoinAllApplications]
        panel.contentMinSize = Self.minimumContentSize
        panel.contentMaxSize = Self.maximumContentSize
        panel.onEscape = { [weak self] in self?.cancel() }
        panel.onReturn = { [weak self] in self?.confirmSelection() }
        panel.searchField = search

        advanced.target = self
        advanced.action = #selector(advancedClicked)
        advanced.bezelStyle = .rounded
        join.target = self
        join.action = #selector(joinClicked)
        join.bezelStyle = .rounded
        join.isHidden = true
        displayName.font = .systemFont(ofSize: 13, weight: .semibold)
        displayName.lineBreakMode = .byTruncatingTail
        displayName.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [displayName, NSView(), join, advanced])
        header.distribution = .fill
        header.alignment = .centerY
        for button in [join, advanced] {
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .vertical)
            button.setContentHuggingPriority(.required, for: .vertical)
        }

        mapHeight.isActive = true
        displayMap.onSelect = { [weak self] displayID, slot in self?.select(displayID: displayID, slot: slot) }
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.placeholderString = L("搜索应用或窗口标题")
        search.setAccessibilityLabel(L("搜索应用或窗口标题"))

        grid.onChoose = { [weak self] index in self?.choose(index) }
        grid.onDrag = { [weak self] choice, point, phase in self?.drag(choice, at: point, phase: phase) }

        emptyMessage.textColor = .secondaryLabelColor
        emptyAction.bezelStyle = .rounded
        emptyAction.target = self
        emptyAction.action = #selector(emptyActionClicked)
        emptyResults.orientation = .vertical
        emptyResults.alignment = .centerX
        emptyResults.spacing = 8
        for view in [emptyMessage, emptyAction] { emptyResults.addArrangedSubview(view) }
        for view in [grid, emptyResults] {
            view.translatesAutoresizingMaskIntoConstraints = false
            resultsArea.addSubview(view)
        }
        let minimumResultsHeight = resultsArea.heightAnchor.constraint(greaterThanOrEqualToConstant: 56)
        minimumResultsHeight.priority = .defaultHigh
        minimumResultsHeight.isActive = true
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: resultsArea.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: resultsArea.trailingAnchor),
            grid.topAnchor.constraint(equalTo: resultsArea.topAnchor),
            grid.bottomAnchor.constraint(equalTo: resultsArea.bottomAnchor),
            emptyResults.centerXAnchor.constraint(equalTo: resultsArea.centerXAnchor),
            emptyResults.centerYAnchor.constraint(equalTo: resultsArea.centerYAnchor),
            emptyResults.leadingAnchor.constraint(greaterThanOrEqualTo: resultsArea.leadingAnchor, constant: 8),
            emptyResults.trailingAnchor.constraint(lessThanOrEqualTo: resultsArea.trailingAnchor, constant: -8),
            emptyResults.topAnchor.constraint(greaterThanOrEqualTo: resultsArea.topAnchor),
            emptyResults.bottomAnchor.constraint(lessThanOrEqualTo: resultsArea.bottomAnchor)
        ])

        favorites.target = self
        favorites.action = #selector(selectFavorite)
        favorites.setAccessibilityLabel(L("收藏组合"))
        favorites.widthAnchor.constraint(equalToConstant: 150).isActive = true
        deleteFavorite.target = self
        deleteFavorite.action = #selector(removeFavorite)
        deleteFavorite.bezelStyle = .rounded
        saveFavorite.target = self
        saveFavorite.action = #selector(storeFavorite)
        saveFavorite.bezelStyle = .rounded
        selectionTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        selectionTitle.lineBreakMode = .byTruncatingTail
        selectionTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let selectionRow = NSStackView(views: [selectionTitle, NSView(), favorites, deleteFavorite])
        selectionRow.distribution = .fill
        selectionRow.alignment = .centerY
        selectionRow.spacing = 8
        refreshFavorites()
        picker.orientation = .vertical
        picker.distribution = .fill
        picker.alignment = .leading
        picker.spacing = 8
        for view in [selectionRow, search, resultsArea] { picker.addArrangedSubview(view) }

        message.textColor = .secondaryLabelColor
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.maximumNumberOfLines = 2
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.setContentCompressionResistancePriority(.required, for: .vertical)
        primary.bezelStyle = .rounded
        primary.bezelColor = .controlAccentColor
        primary.target = self
        primary.action = #selector(primaryClicked)
        swap.target = self
        swap.action = #selector(swapSelection)
        swap.bezelStyle = .rounded
        swap.setAccessibilityLabel(L("交换两个已选窗口的位置"))
        footer.orientation = .horizontal
        footer.distribution = .fill
        footer.alignment = .centerY
        for button in [saveFavorite, swap, primary] {
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .vertical)
            button.setContentHuggingPriority(.required, for: .vertical)
        }
        for view in [hint, NSView(), saveFavorite, swap, primary] { footer.addArrangedSubview(view) }

        content.orientation = .vertical
        content.distribution = .fill
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 14, left: Self.horizontalInset, bottom: 14, right: Self.horizontalInset)
        for view in [header, displayMap, picker, message, footer] { content.addArrangedSubview(view) }
        for view in [selectionRow, search, resultsArea] {
            view.leadingAnchor.constraint(equalTo: picker.leadingAnchor).isActive = true
            view.trailingAnchor.constraint(equalTo: picker.trailingAnchor).isActive = true
        }
        for view in [message, search] {
            view.setContentHuggingPriority(.required, for: .vertical)
        }
        // When window selection is unavailable, spare space belongs below the message.
        emptySpace.isHidden = true
        content.insertArrangedSubview(emptySpace, at: 4)
        content.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.addSubview(content)
        dragPreview.isHidden = true
        dragPreview.imageScaling = .scaleProportionallyUpOrDown
        dragPreview.setAccessibilityElement(false)
        root.addSubview(dragPreview)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        let innerWidth = root.widthAnchor
        for view in [header, displayMap, picker, message, footer, emptySpace] {
            view.widthAnchor.constraint(equalTo: innerWidth, constant: -2 * Self.horizontalInset).isActive = true
        }
        panel.contentView = root
        updateLayoutMetrics()
    }

    deinit {
        if let terminationObserver { workspaceNotifications.removeObserver(terminationObserver) }
    }

    private func applicationTerminated(_ pid: pid_t) {
        guard !busy else { return }
        choices.removeAll { $0.pid == pid }
        let lostSelection = selected.contains { $0?.pid == pid }
        selected = selected.map { $0?.pid == pid ? nil : $0 }
        if lostSelection {
            slot = selected.firstIndex(where: { $0 == nil }) ?? 0
            sessionMessage = L("选中的应用已经退出，请重新选择窗口。")
        }
        if isVisible { updateResults() }
    }

    func show(screens: [PhysicalScreen], displayID: CGDirectDisplayID?, host: NSScreen?,
              activePairs: [CGDirectDisplayID: [WindowPlacement.Choice]], recentPairs: [CGDirectDisplayID: WindowPlacement.Pair],
              excluded: [WindowPlacement.Identity], problem: String?, settingsTitle: String) {
        blocker = problem
        advanced.title = settingsTitle
        favoriteID = nil
        refreshFavorites()
        self.activePairs = activePairs
        self.recentPairs = recentPairs
        self.excluded = excluded
        sessionMessage = nil
        busy = false
        canCancel = false
        failed = false
        replacingWindow = false
        grid.resetPreviews()
        choices = []
        selected = [nil, nil]
        slot = 0
        search.stringValue = ""
        useHost(host)
        updateDisplays(screens, selectedID: displayID)
        loadChoices()
        centerOnHost()
        bringToFront()
    }

    func showFailure(_ problem: String, host: NSScreen?) {
        sessionMessage = problem
        failed = true
        replacingWindow = false
        search.stringValue = ""
        useHost(host)
        retainAvailableSelection()
        updateResults()
        if !isFocused { centerOnHost() }
        bringToFront()
        if blocker == nil { loadChoices(preservingSelection: true) }
        announce(problem)
    }

    private func useHost(_ host: NSScreen?) {
        hostFrame = host?.visibleFrame
        updateWindowSizeLimits(for: hostFrame)
        if let current = panel.contentView?.bounds.size {
            let limit = panel.contentMaxSize
            let size = NSSize(width: min(current.width, limit.width), height: min(current.height, limit.height))
            if current != size { panel.setContentSize(size) }
        }
        updateLayoutMetrics()
    }

    private func updateWindowSizeLimits(for visibleFrame: CGRect?) {
        let inset = Self.screenInset
        let available = visibleFrame.map { panel.contentRect(forFrameRect: $0.insetBy(dx: inset, dy: inset)).size }
            ?? Self.maximumContentSize
        panel.contentMinSize = NSSize(width: min(Self.minimumContentSize.width, available.width),
                                      height: min(Self.minimumContentSize.height, available.height))
        panel.contentMaxSize = NSSize(width: min(Self.maximumContentSize.width, available.width),
                                      height: min(Self.maximumContentSize.height, available.height))
    }

    private func centerOnHost() {
        if let frame = hostFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2,
                                         y: frame.midY - panel.frame.height / 2))
        } else { panel.center() }
    }

    private func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if !picker.isHidden { panel.makeFirstResponder(search) }
    }

    func hide() {
        choiceTask?.cancel()
        choiceTask = nil
        clearDrag()
        grid.setPreviewing(false)
        panel.orderOut(nil)
        grid.resetPreviews()
    }

    func setProblem(_ problem: String?, actionTitle: String) {
        guard blocker != problem || advanced.title != actionTitle else { return }
        blocker = problem
        advanced.title = actionTitle
        if problem == nil { loadChoices(preservingSelection: true) }
        else { updateResults() }
    }

    func setRestoreTitle(_ title: String?, enabled: Bool) {
        guard join.isHidden != (title == nil) || join.title != (title ?? "") || join.isEnabled != enabled else { return }
        join.title = title ?? ""
        join.isHidden = title == nil
        join.isEnabled = enabled
    }

    func updateDisplays(_ screens: [PhysicalScreen], selectedID: CGDirectDisplayID? = nil,
                        activePairs: [CGDirectDisplayID: [WindowPlacement.Choice]]? = nil,
                        excluded: [WindowPlacement.Identity]? = nil) {
        self.screens = screens
        if let activePairs { self.activePairs = activePairs }
        if let excluded { self.excluded = excluded }
        let hadDisplay = selectedDisplayID != nil
        let preferred = selectedID ?? selectedDisplayID
        let available = screens.filter { self.activePairs[$0.id]?.isEmpty != false }
        let next = available.first(where: { $0.id == preferred })?.id ?? available.first?.id
        if next != selectedDisplayID {
            useDisplay(next)
            if !busy {
                sessionMessage = nil
                failed = false
            }
        }
        else if !busy { retainAvailableSelection() }
        displayMap.updateDisplays(screens)
        displayMap.isHidden = screens.isEmpty
        guard isVisible else { return }
        if !hadDisplay && selectedDisplayID != nil && blocker == nil {
            loadChoices()
            panel.makeFirstResponder(search)
        } else { updateResults() }
    }

    func setSessionState(busy: Bool, canCancel: Bool, message: String?) {
        guard self.busy != busy || self.canCancel != canCancel || sessionMessage != message else { return }
        let starting = busy && !self.busy
        self.busy = busy
        self.canCancel = canCancel
        sessionMessage = message
        updateControls()
        if starting && isVisible { panel.displayIfNeeded() }
        if !busy && isVisible && !picker.isHidden { panel.makeFirstResponder(search) }
    }

    private var pair: WindowPlacement.Pair? {
        guard let upper = selected[0], let lower = selected[1] else { return nil }
        return WindowPlacement.Pair(upper: upper, lower: lower)
    }

    private func loadChoices(preservingSelection: Bool = false) {
        choiceTask?.cancel()
        choiceTask = nil
        if blocker == nil, selectedDisplayID != nil {
            let scan = Task.detached(priority: .userInitiated) { WindowPlacement.choices() }
            choiceTask = Task { [weak self] in
                let choices = await withTaskCancellationHandler {
                    await scan.value
                } onCancel: {
                    scan.cancel()
                }
                guard let self, !Task.isCancelled else { return }
                self.choiceTask = nil
                self.choices = choices.filter { NSRunningApplication(processIdentifier: $0.pid)?.isTerminated == false }
                if preservingSelection { self.retainAvailableSelection() }
                else {
                    self.useDisplay(self.selectedDisplayID)
                    if let favoriteID = self.favoriteID { self.applyFavorite(favoriteID) }
                }
                self.updateResults()
            }
        }
        updateResults()
    }

    private func useDisplay(_ displayID: CGDirectDisplayID?) {
        selectedDisplayID = displayID
        replacingWindow = false
        let recent = displayID.flatMap { recentPairs[$0] }
        selected = [recent?.upper, recent?.lower].map { previous in
            guard let previous else { return nil }
            return choices.first { $0.id == previous.id && $0.pid == previous.pid && isAvailable($0) }
        }
        slot = selected.firstIndex(where: { $0 == nil }) ?? 0
    }

    private func retainAvailableSelection() {
        selected = selected.map { previous in
            guard let previous else { return nil }
            return choices.first { $0.id == previous.id && $0.pid == previous.pid && isAvailable($0) }
        }
        if let emptySlot = selected.firstIndex(where: { $0 == nil }) { slot = emptySlot }
    }

    private func isAvailable(_ choice: WindowPlacement.Choice) -> Bool {
        !excluded.contains { $0.matches(number: choice.windowID, element: choice.element) }
    }

    private var query: String { search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canChooseWindow: Bool { !busy && blocker == nil && selectedDisplayID != nil && choiceTask == nil }

    private var canStart: Bool { canChooseWindow && pair != nil }

    private enum ReturnAction { case choose(Int), start }

    private var returnAction: ReturnAction? {
        guard canChooseWindow else { return nil }
        if let index = grid.highlightedIndex { return .choose(index) }
        return canStart && query.isEmpty && !replacingWindow ? .start : nil
    }

    private func updateResults() {
        if draggedChoice != nil { clearDrag() }
        let query = self.query
        let otherID = selected[1 - slot]?.id
        results = choices.filter { item in
            isAvailable(item) && item.id != otherID && (query.isEmpty || item.appName.localizedStandardContains(query)
                                   || item.title.localizedStandardContains(query))
        }
        grid.show(results, highlightFirst: pair == nil || replacingWindow || !query.isEmpty)
        updateControls()
    }

    private func updateControls() {
        let unavailable = blocker ?? (selectedDisplayID == nil
            ? (activePairs.isEmpty ? L("接入一块显示器后即可拆分。") : L("所有显示器均在快捷分屏中，请先结束一个组合。")) : nil)
        picker.isHidden = unavailable != nil
        emptySpace.isHidden = unavailable == nil
        footer.isHidden = unavailable != nil && !busy
        search.isEnabled = !busy
        grid.isEnabled = canChooseWindow
        updatePreviewing()
        let screen = screens.first { $0.id == selectedDisplayID }
        let targetSlot = pair == nil || replacingWindow || !query.isEmpty || grid.highlightedIndex != nil ? slot : nil
        let displayedScreen = screen ?? (screens.count == 1 ? screens.first : nil)
        displayName.stringValue = displayedScreen?.displayName ?? L("目标显示器")
        displayName.toolTip = displayedScreen?.menuTitle
        displayMap.updateSelection(displayID: selectedDisplayID, slot: targetSlot, selected: selected,
                                   activePairs: activePairs, enabled: canChooseWindow)
        let region = screen?.splitLayout.names[slot] ?? L("分区")
        if pair == nil {
            let count = selected.compactMap { $0 }.count
            selectionTitle.stringValue = L("为%@选窗 · %@/2", region, String(count))
        } else if targetSlot != nil {
            selectionTitle.stringValue = L("更换%@的窗口 · 2/2", region)
        } else {
            selectionTitle.stringValue = L("已选窗口 · 2/2")
        }
        search.setAccessibilityHelp(selectionTitle.stringValue)
        updateEmptyResults()
        let status = unavailable ?? sessionMessage
        message.stringValue = status ?? ""
        message.isHidden = status == nil
        updateKeyboardHint()
        favorites.isEnabled = canChooseWindow
        deleteFavorite.isEnabled = canChooseWindow && favoriteID != nil
        deleteFavorite.isHidden = favoriteID == nil
        saveFavorite.isHidden = busy || pair == nil
        saveFavorite.isEnabled = canStart
        swap.isHidden = busy || pair == nil
        swap.isEnabled = canChooseWindow
        primary.title = busy ? (canCancel ? L("取消") : L("正在恢复…")) : (failed ? L("重试分屏") : L("开始分屏"))
        primary.isEnabled = busy ? canCancel : canStart
        primary.bezelColor = canStart ? .controlAccentColor : nil
        updateLayoutMetrics()
    }

    private func updateLayoutMetrics() {
        guard let size = panel.contentView?.bounds.size else { return }
        mapHeight.constant = min(128, max(72, size.height - 340))
        let width = max(1, size.width - 2 * Self.horizontalInset)
        message.preferredMaxLayoutWidth = width
        hint.preferredMaxLayoutWidth = max(120, width - 270)
    }

    private func updateEmptyResults() {
        grid.isHidden = results.isEmpty
        emptyResults.isHidden = !results.isEmpty
        guard results.isEmpty else { return }
        emptyAction.isHidden = choiceTask != nil
        emptyAction.isEnabled = !busy
        if choiceTask != nil {
            emptyMessage.stringValue = L("正在查找打开的窗口…")
        } else if !query.isEmpty {
            emptyMessage.stringValue = L("没有匹配的窗口。")
            emptyAction.title = L("清空搜索")
        } else {
            emptyMessage.stringValue = L("打开至少两个可选窗口后即可拆分。")
            emptyAction.title = L("刷新窗口列表")
        }
    }

    @objc private func emptyActionClicked() {
        guard canChooseWindow else { return }
        if query.isEmpty { loadChoices(preservingSelection: true) }
        else {
            search.stringValue = ""
            updateResults()
        }
        panel.makeFirstResponder(search)
    }

    private func updateKeyboardHint() {
        if busy { hint.stringValue = canCancel ? L("Esc 取消") : ""; return }
        switch returnAction {
        case .choose: hint.stringValue = L("点击或拖放   ↑↓ 移动   ↵ 选中   Esc 关闭")
        case .start: hint.stringValue = failed ? L("↵ 重试分屏   Esc 关闭") : L("↵ 开始分屏   Esc 关闭")
        case nil: hint.stringValue = L("Esc 关闭")
        }
    }

    private func announce(_ message: String) {
        guard panel.isKeyWindow else { return }
        NSAccessibility.post(element: NSApp!, notification: .announcementRequested, userInfo: [
            .announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue
        ])
    }

    func controlTextDidChange(_ notification: Notification) {
        if !busy { updateResults() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            confirmSelection()
            return true
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
            let previous = grid.highlightedIndex
            grid.moveHighlight(by: commandSelector == #selector(NSResponder.moveUp(_:)) ? -1 : 1)
            if previous == nil && grid.highlightedIndex != nil { updateControls() }
            if let index = grid.highlightedIndex, index != previous, results.indices.contains(index) {
                let choice = results[index]
                announce(choice.title.isEmpty ? choice.appName : "\(choice.appName), \(choice.title)")
            }
            return true
        default:
            return false
        }
    }

    private func confirmSelection() {
        switch returnAction {
        case .choose(let index): choose(index)
        case .start: primaryClicked()
        case nil: break
        }
    }

    func windowDidBecomeKey(_ notification: Notification) { updatePreviewing() }

    func windowDidResize(_ notification: Notification) { updateLayoutMetrics() }

    func windowDidEndLiveResize(_ notification: Notification) {
        panel.contentView?.layoutSubtreeIfNeeded()
        grid.revealHighlight()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        if isVisible { updateWindowSizeLimits(for: panel.screen?.visibleFrame) }
    }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
        let inset = Self.screenInset
        let area = window.screen?.visibleFrame.insetBy(dx: inset, dy: inset) ?? defaultFrame
        let maximum = window.frameRect(forContentRect: CGRect(origin: .zero, size: Self.maximumContentSize)).size
        let size = NSSize(width: min(maximum.width, area.width), height: min(maximum.height, area.height))
        return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    func windowDidResignKey(_ notification: Notification) {
        clearDrag()
        grid.setPreviewing(false)
    }

    private func updatePreviewing() {
        grid.setPreviewing(panel.isKeyWindow && canChooseWindow && !results.isEmpty)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onCancel?()
        return false
    }

    private func select(displayID: CGDirectDisplayID, slot: Int) {
        guard !busy, blocker == nil, activePairs[displayID]?.isEmpty != false else { return }
        if selectedDisplayID != displayID {
            useDisplay(displayID)
            sessionMessage = nil
            failed = false
        }
        self.slot = slot
        replacingWindow = pair != nil
        search.stringValue = ""
        updateResults()
        panel.makeFirstResponder(search)
    }

    private func choose(_ row: Int) {
        guard canChooseWindow, results.indices.contains(row) else { return }
        assign(results[row], to: slot)
    }

    private func drag(_ choice: WindowPlacement.Choice, at point: NSPoint, phase: WindowPreviewGrid.DragPhase) {
        switch phase {
        case .began(let image):
            guard canChooseWindow, panel.isKeyWindow else { return }
            draggedChoice = choice
            dragPreview.image = image ?? NSRunningApplication(processIdentifier: choice.pid)?.icon
        case .moved:
            break
        case .ended:
            guard let draggedChoice else { return }
            clearDrag()
            guard !busy, let target = displayMap.target(at: point) else { return }
            if selectedDisplayID != target.displayID { selected = [nil, nil] }
            if selected[1 - target.slot]?.id == draggedChoice.id { selected[1 - target.slot] = nil }
            selectedDisplayID = target.displayID
            assign(draggedChoice, to: target.slot)
            return
        }
        guard draggedChoice != nil, let root = panel.contentView else { return }
        displayMap.highlightDrop(at: point)
        let local = root.convert(point, from: nil)
        dragPreview.isHidden = !root.bounds.contains(local)
        dragPreview.frame = NSRect(x: local.x - 52, y: local.y - 77, width: 104, height: 67)
    }

    private func clearDrag() {
        draggedChoice = nil
        dragPreview.isHidden = true
        dragPreview.image = nil
        displayMap.highlightDrop(at: nil)
    }

    private func cancel() {
        if draggedChoice != nil { clearDrag() }
        else { onCancel?() }
    }

    private func assign(_ choice: WindowPlacement.Choice, to slot: Int) {
        let completing = selected[slot] == nil
        let wasFailed = failed
        selected[slot] = choice
        sessionMessage = nil
        failed = false
        replacingWindow = false
        let next = selected.firstIndex(where: { $0 == nil })
        self.slot = next ?? slot
        search.stringValue = ""
        updateResults()
        if next == nil && completing && !wasFailed && preferences.automaticStart { primaryClicked() }
        if !busy {
            panel.makeFirstResponder(search)
            if let region = screens.first(where: { $0.id == selectedDisplayID })?.splitLayout.names[slot] {
                announce(L("%@已选：%@。%@", region, choice.name, selectionTitle.stringValue))
            }
        }
    }

    @objc private func swapSelection() {
        guard !busy, blocker == nil, pair != nil else { return }
        selected.swapAt(0, 1)
        search.stringValue = ""
        sessionMessage = nil
        failed = false
        replacingWindow = false
        updateResults()
        panel.makeFirstResponder(search)
    }

    private func refreshFavorites() {
        favorites.removeAllItems()
        favorites.addItem(withTitle: L("选择收藏组合…"))
        for workspace in preferences.workspaces {
            favorites.addItem(withTitle: workspace.name)
            favorites.lastItem?.representedObject = workspace.id.uuidString
        }
        if let favoriteID, let index = preferences.workspaces.firstIndex(where: { $0.id == favoriteID }) {
            favorites.selectItem(at: index + 1)
        }
        deleteFavorite.isEnabled = favoriteID != nil
    }

    @objc private func selectFavorite() {
        guard canChooseWindow else { return }
        favoriteID = (favorites.selectedItem?.representedObject as? String).flatMap(UUID.init(uuidString:))
        guard let favoriteID else { updateControls(); return }
        applyFavorite(favoriteID)
        updateResults()
        panel.makeFirstResponder(search)
    }

    private func applyFavorite(_ id: UUID) {
        guard let workspace = preferences.workspaces.first(where: { $0.id == id }) else { return }
        let available = choices.filter(isAvailable)
        let indices = WorkspaceMatcher.match(workspace, candidates: available.map {
            WorkspaceMatcher.Candidate(bundleID: NSRunningApplication(processIdentifier: $0.pid)?.bundleIdentifier ?? "", title: $0.title)
        })
        selected = indices.map { index in index.map { available[$0] } }
        slot = selected.firstIndex(where: { $0 == nil }) ?? 0
        failed = false
        replacingWindow = false
        search.stringValue = ""
        sessionMessage = selected.contains(where: { $0 == nil })
            ? L("部分应用未打开或有多个候选窗口，请重新选择缺少的窗口。")
            : L("已匹配当前窗口，确认后开始分屏。")
    }

    @objc private func storeFavorite() {
        guard !busy, let pair else { return }
        let apps = [pair.upper, pair.lower].compactMap { choice -> SavedWorkspace.App? in
            guard let id = NSRunningApplication(processIdentifier: choice.pid)?.bundleIdentifier else { return nil }
            return SavedWorkspace.App(bundleID: id, name: choice.appName, titleHint: choice.title)
        }
        guard apps.count == 2 else { sessionMessage = L("无法识别应用，请重新选择窗口。"); updateControls(); return }
        guard preferences.workspaces.count < 30 else { sessionMessage = L("最多保存 30 个组合，请先删除不需要的收藏。"); updateControls(); return }
        let alert = NSAlert()
        alert.messageText = L("收藏这个组合")
        alert.informativeText = L("应用标识与窗口标题仅保存在本机，用于下次匹配。")
        let name = NSTextField(string: apps.map(\.name).joined(separator: " + "))
        name.frame = CGRect(x: 0, y: 0, width: 320, height: 24)
        name.setAccessibilityLabel(L("组合名称"))
        alert.accessoryView = name
        alert.addButton(withTitle: L("收藏"))
        alert.addButton(withTitle: L("取消"))
        panel.hidesOnDeactivate = false
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard let self else { return }
            self.panel.hidesOnDeactivate = true
            guard response == .alertFirstButtonReturn else { return }
            let entered = String(name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
            let workspace = SavedWorkspace(name: entered.isEmpty ? apps.map(\.name).joined(separator: " + ") : entered, apps: apps)
            self.preferences.workspaces = self.preferences.workspaces + [workspace]
            self.favoriteID = workspace.id
            self.refreshFavorites()
            self.sessionMessage = L("组合已收藏。")
            self.updateControls()
        }
    }

    @objc private func removeFavorite() {
        guard !busy, let favoriteID else { return }
        let alert = NSAlert()
        alert.messageText = L("删除这个收藏组合？")
        alert.informativeText = L("不会关闭窗口或更改当前分屏。")
        alert.addButton(withTitle: L("取消"))
        alert.addButton(withTitle: L("删除"))
        panel.hidesOnDeactivate = false
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard let self else { return }
            self.panel.hidesOnDeactivate = true
            guard response == .alertSecondButtonReturn else { return }
            self.preferences.workspaces = self.preferences.workspaces.filter { $0.id != favoriteID }
            self.favoriteID = nil
            self.sessionMessage = nil
            self.refreshFavorites()
            self.updateControls()
        }
    }

    @objc private func primaryClicked() {
        if busy {
            if canCancel { onCancel?() }
            return
        }
        guard canStart, let displayID = selectedDisplayID, activePairs[displayID]?.isEmpty != false, let pair else { return }
        onSplit?(displayID, pair)
    }

    @objc private func advancedClicked() {
        onAdvanced?()
    }

    @objc private func joinClicked() {
        onJoin?()
    }
}

@MainActor
private final class DisplayArrangementView: NSView {
    private struct Tile {
        let screen: PhysicalScreen
        let view: NSView
        let halves: [NSButton]
    }

    struct DropTarget: Equatable {
        let displayID: CGDirectDisplayID
        let slot: Int
    }

    var onSelect: ((CGDirectDisplayID, Int) -> Void)?
    override var isFlipped: Bool { true }

    private var tiles: [Tile] = []
    private var selectedDisplayID: CGDirectDisplayID?
    private var selectedSlot: Int?
    private var selected: [WindowPlacement.Choice?] = []
    private var activePairs: [CGDirectDisplayID: [WindowPlacement.Choice]] = [:]
    private var enabled = false
    private var dropTarget: DropTarget? {
        didSet { if dropTarget != oldValue { updateAppearance() } }
    }

    func updateDisplays(_ screens: [PhysicalScreen]) {
        dropTarget = nil
        tiles.forEach { $0.view.removeFromSuperview() }
        tiles = screens.map { screen in
            let card = NSView()
            card.wantsLayer = true
            card.layer?.cornerRadius = 7
            card.layer?.masksToBounds = true
            let halves: [NSButton] = (0..<2).map { _ in
                let button = NSButton(title: "", target: self, action: #selector(halfClicked))
                button.isBordered = false
                button.wantsLayer = true
                button.cell?.usesSingleLineMode = false
                button.cell?.lineBreakMode = .byTruncatingTail
                card.addSubview(button)
                return button
            }
            addSubview(card)
            return Tile(screen: screen, view: card, halves: halves)
        }
        needsLayout = true
        updateAppearance()
    }

    func updateSelection(displayID: CGDirectDisplayID?, slot: Int?, selected: [WindowPlacement.Choice?],
                         activePairs: [CGDirectDisplayID: [WindowPlacement.Choice]], enabled: Bool) {
        selectedDisplayID = displayID
        selectedSlot = slot
        self.selected = selected
        self.activePairs = activePairs
        self.enabled = enabled
        if !enabled { dropTarget = nil }
        updateAppearance()
    }

    override func layout() {
        super.layout()
        let frames = DisplayScanner.arrangementFrames(tiles.map(\.screen.bounds), in: bounds.insetBy(dx: 9, dy: 7))
        for (tile, frame) in zip(tiles, frames) where !frame.isEmpty {
            let screen = tile.screen.bounds
            tile.view.frame = frame.insetBy(dx: min(3, frame.width / 10), dy: min(3, frame.height / 10))
            let size = tile.view.bounds.size
            for (index, button) in tile.halves.enumerated() {
                let region = tile.screen.splitLayout.regions[index]
                let sx = size.width / screen.width
                let sy = size.height / screen.height
                button.frame = CGRect(x: region.minX * sx, y: size.height - region.maxY * sy,
                                      width: region.width * sx, height: region.height * sy).insetBy(dx: 0.5, dy: 0.5)
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = NSColor.controlAccentColor
            let selection = accent.blended(withFraction: 0.80, of: .controlBackgroundColor) ?? .controlBackgroundColor
            let dropFill = accent.blended(withFraction: 0.58, of: .controlBackgroundColor) ?? selection
            let displayIDs = tiles.map(\.screen.id).sorted()
            for tile in tiles {
                let isTarget = tile.screen.id == selectedDisplayID
                let active = activePairs[tile.screen.id]
                let occupied = active?.isEmpty == false
                tile.view.layer?.borderWidth = isTarget ? 2 : 1
                tile.view.layer?.borderColor = (isTarget ? accent : .separatorColor).cgColor
                tile.view.layer?.backgroundColor = NSColor.separatorColor.cgColor
                for (slot, button) in tile.halves.enumerated() {
                    let region = tile.screen.splitLayout.names[slot]
                    let number = displayIDs.firstIndex(of: tile.screen.id).map { $0 + 1 } ?? 1
                    let position = displayIDs.count == 1 ? region : "\(number) · \(region)"
                    let highlighted = isTarget && selectedSlot == slot
                    let receivingDrop = dropTarget == DropTarget(displayID: tile.screen.id, slot: slot)
                    let activeWindow = active.flatMap { $0.indices.contains(slot) ? $0[slot] : nil }
                    let assigned = activeWindow ?? (isTarget && selected.indices.contains(slot) ? selected[slot] : nil)
                    let detail = assigned?.name ?? (isTarget ? L("未选窗口") : (active == nil ? nil : L("桌面已拆分")))
                    button.attributedTitle = Self.caption(position, detail: detail)
                    let fill = highlighted ? selection : NSColor.controlBackgroundColor
                    button.layer?.backgroundColor = (receivingDrop ? dropFill : fill).cgColor
                    button.layer?.borderWidth = receivingDrop ? 2 : 0
                    button.layer?.borderColor = accent.cgColor
                    button.isEnabled = enabled && !occupied
                    button.setAccessibilitySelected(highlighted)
                    button.setAccessibilityLabel([tile.screen.displayName, position, assigned?.appName,
                                                  assigned?.title.isEmpty == false ? assigned?.title : (assigned == nil ? detail : nil)]
                        .compactMap { $0 }.joined(separator: ", "))
                    button.setAccessibilityHelp(occupied ? L("快捷分屏中") : highlighted ? L("当前选窗分区") : L("可选择窗口"))
                    button.toolTip = [tile.screen.menuTitle, position, detail]
                        .compactMap { $0 }.joined(separator: " · ")
                }
            }
        }
    }

    func highlightDrop(at point: NSPoint?) { dropTarget = point.flatMap { target(at: $0) } }

    func target(at windowPoint: NSPoint) -> DropTarget? {
        guard enabled else { return nil }
        for tile in tiles where activePairs[tile.screen.id]?.isEmpty != false {
            for (slot, button) in tile.halves.enumerated() {
                let point = button.convert(windowPoint, from: nil)
                if button.bounds.contains(point) { return DropTarget(displayID: tile.screen.id, slot: slot) }
            }
        }
        return nil
    }

    private static func caption(_ title: String, detail: String?) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let result = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
        if let detail, !detail.isEmpty {
            result.append(NSAttributedString(string: "\n\(detail)", attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph
            ]))
        }
        return result
    }

    @objc private func halfClicked(_ sender: NSButton) {
        guard let tile = tiles.first(where: { $0.halves.contains(sender) }),
              let slot = tile.halves.firstIndex(of: sender) else { return }
        onSelect?(tile.screen.id, slot)
    }
}

@MainActor
private final class CardDragPreview: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class SplitPanelWindow: NSPanel {
    var onEscape: (() -> Void)?
    var onReturn: (() -> Void)?
    weak var searchField: NSSearchField?

    // Keep the panel available in other apps' full-screen Spaces. Its own green
    // button just resizes the picker within the current display.
    override func toggleFullScreen(_ sender: Any?) { zoom(sender) }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty, let editor = firstResponder as? NSTextView, editor === searchField?.currentEditor(),
           !editor.hasMarkedText(), let key = event.charactersIgnoringModifiers, key == "\r" || key == "\u{3}" {
            if !event.isARepeat { onReturn?() }
            return true
        }
        if modifiers == .command, let editor = firstResponder as? NSTextView {
            switch event.charactersIgnoringModifiers {
            case "a": editor.selectAll(nil); return true
            case "c": editor.copy(nil); return true
            case "v": editor.paste(nil); return true
            case "x": editor.cut(nil); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
