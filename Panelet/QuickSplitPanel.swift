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

    private static let width: CGFloat = 540
    private let panel = SplitPanelWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: 560),
        styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false
    )
    private let displayMap = DisplayArrangementView()
    private let search = NSSearchField()
    private let grid = WindowPreviewGrid(width: width - 32)
    private let dragPreview = CardDragPreview()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private let advanced = NSButton()
    private let join = NSButton()
    private let primary = NSButton()
    private let content = NSStackView()
    private let picker = NSStackView()
    private let footer = NSStackView()

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
    private var draggedChoice: WindowPlacement.Choice?
    private var choiceTask: Task<Void, Never>?
    private var submitWhenReady = false

    override init() {
        super.init()
        let width = Self.width
        panel.title = "Panelet · 快捷窗口分屏"
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .canJoinAllApplications]
        panel.onEscape = { [weak self] in self?.cancel() }
        panel.onReturn = { [weak self] in self?.confirmSelection() }

        advanced.target = self
        advanced.action = #selector(advancedClicked)
        advanced.bezelStyle = .rounded
        join.title = "还原…"
        join.target = self
        join.action = #selector(joinClicked)
        join.bezelStyle = .rounded
        let header = NSStackView(views: [NSTextField(labelWithString: "把窗口拖到目标分区"), NSView(), join, advanced])
        header.alignment = .centerY

        displayMap.heightAnchor.constraint(equalToConstant: 154).isActive = true
        displayMap.onSelect = { [weak self] displayID, slot in self?.select(displayID: displayID, slot: slot) }
        search.delegate = self
        search.sendsSearchStringImmediately = true

        grid.onChoose = { [weak self] index in self?.choose(index) }
        grid.onDrag = { [weak self] choice, point, phase in self?.drag(choice, at: point, phase: phase) }

        picker.orientation = .vertical
        picker.alignment = .leading
        picker.spacing = 8
        for view in [search, grid] { picker.addArrangedSubview(view) }

        message.textColor = .secondaryLabelColor
        message.preferredMaxLayoutWidth = width - 32
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        primary.bezelStyle = .rounded
        primary.target = self
        primary.action = #selector(primaryClicked)
        footer.orientation = .horizontal
        footer.alignment = .centerY
        for view in [hint, NSView(), primary] { footer.addArrangedSubview(view) }

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        for view in [header, displayMap, picker, message, footer] { content.addArrangedSubview(view) }
        for view in [header, displayMap, picker, search, grid, message, footer] {
            view.widthAnchor.constraint(equalToConstant: width - 32).isActive = true
        }
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
        ])
        panel.contentView = root
    }

    func show(screens: [PhysicalScreen], displayID: CGDirectDisplayID?, host: NSScreen?,
              activePairs: [CGDirectDisplayID: [WindowPlacement.Choice]], recentPairs: [CGDirectDisplayID: WindowPlacement.Pair],
              excluded: [WindowPlacement.Identity], problem: String?) {
        blocker = problem
        self.activePairs = activePairs
        self.recentPairs = recentPairs
        self.excluded = excluded
        sessionMessage = nil
        busy = false
        canCancel = false
        grid.resetPreviews()
        choices = []
        selected = [nil, nil]
        slot = 0
        search.stringValue = ""
        updateDisplays(screens, selectedID: displayID)
        loadChoices()
        if let host {
            let frame = host.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2,
                                         y: frame.midY - panel.frame.height / 2))
        } else {
            panel.center()
        }
        bringToFront()
    }

    func showFailure() {
        panel.center()
        bringToFront()
    }

    private func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if !picker.isHidden { panel.makeFirstResponder(search) }
    }

    func hide() {
        choiceTask?.cancel()
        choiceTask = nil
        submitWhenReady = false
        clearDrag()
        grid.setPreviewing(false)
        panel.orderOut(nil)
        grid.resetPreviews()
    }

    func setProblem(_ problem: String?) {
        guard blocker != problem else { return }
        blocker = problem
        if problem == nil { loadChoices() }
        else { updateResults() }
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
        if next != selectedDisplayID { useDisplay(next) }
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

    private func loadChoices() {
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
                self.choices = choices
                let submit = self.submitWhenReady
                self.useDisplay(self.selectedDisplayID)
                if submit { self.sessionMessage = nil }
                self.updateResults()
                if submit && self.search.stringValue.isEmpty { self.primaryClicked() }
            }
        }
        updateResults()
    }

    private func useDisplay(_ displayID: CGDirectDisplayID?) {
        submitWhenReady = false
        selectedDisplayID = displayID
        let recent = displayID.flatMap { recentPairs[$0] }
        selected = [recent?.upper.id, recent?.lower.id].map { id in choices.first { $0.id == id && isAvailable($0) } }
        slot = selected.firstIndex(where: { $0 == nil }) ?? 0
    }

    private func isAvailable(_ choice: WindowPlacement.Choice) -> Bool {
        !excluded.contains { $0.matches(number: choice.windowID, element: choice.element) }
    }

    private func updateResults() {
        if draggedChoice != nil { clearDrag() }
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let otherID = selected[1 - slot]?.id
        results = choices.filter { item in
            isAvailable(item) && item.id != otherID && (query.isEmpty || item.appName.localizedStandardContains(query)
                                   || item.title.localizedStandardContains(query))
        }
        grid.show(results, highlightFirst: pair == nil || !query.isEmpty, loading: choiceTask != nil)
        updateControls()
    }

    private func updateControls() {
        let unavailable = blocker ?? (selectedDisplayID == nil
            ? (activePairs.isEmpty ? "接入一块显示器后即可拆分。" : "所有显示器均在快捷分屏中，请先还原一个组合。") : nil)
        picker.isHidden = unavailable != nil
        footer.isHidden = unavailable != nil && !busy
        advanced.title = blocker == nil ? "设置…" : "打开设置…"
        join.isHidden = activePairs.isEmpty
        join.isEnabled = !busy
        search.isEnabled = !busy
        grid.isEnabled = !busy
        updatePreviewing()
        let names = selected.enumerated().map { index, choice in
            choice.map { choice in
                choice.appName == selected[1 - index]?.appName && !choice.title.isEmpty ? choice.title : choice.appName
            }
        }
        displayMap.updateSelection(displayID: selectedDisplayID, slot: slot, names: names,
                                   titles: selected.map { $0?.title }, activePairs: activePairs, enabled: !busy && unavailable == nil)
        let layout = screens.first { $0.id == selectedDisplayID }?.splitLayout
        let direction = layout?.direction ?? "两区"
        search.placeholderString = "搜索\(layout?.names[slot] ?? "分区")窗口"
        let empty = choiceTask != nil ? "正在查找打开的窗口…" :
            (results.isEmpty && !search.stringValue.isEmpty ? "没有匹配的窗口。" :
                (choices.lazy.filter(isAvailable).prefix(2).count < 2 ? "打开至少两个可选窗口后即可拆分。" : nil))
        let status = sessionMessage ?? unavailable ?? empty
        message.stringValue = status ?? ""
        message.isHidden = status == nil
        hint.stringValue = busy ? (canCancel ? "Esc 取消" : "")
            : (pair != nil && grid.highlightedIndex == nil ? "↵ \(direction)全屏   Esc 关闭" : "↑↓ 选择   ↵ 确认   Esc 关闭")
        primary.title = busy ? "取消" : "\(direction)全屏"
        primary.isEnabled = busy ? canCancel : (pair != nil && unavailable == nil)
        panel.contentView?.layoutSubtreeIfNeeded()
        let height = ceil(content.fittingSize.height)
        if height > 0 && abs((panel.contentView?.bounds.height ?? 0) - height) > 1 {
            let previous = panel.frame
            panel.setContentSize(NSSize(width: Self.width, height: height))
            if isVisible { panel.setFrameTopLeftPoint(NSPoint(x: previous.minX, y: previous.maxY)) }
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        if submitWhenReady { sessionMessage = nil }
        submitWhenReady = false
        if !busy { updateResults() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            confirmSelection()
            return true
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
            grid.moveHighlight(by: commandSelector == #selector(NSResponder.moveUp(_:)) ? -1 : 1)
            return true
        default:
            return false
        }
    }

    private func confirmSelection() {
        guard !busy else { return }
        if choiceTask != nil {
            submitWhenReady = search.stringValue.isEmpty && selectedDisplayID.flatMap { recentPairs[$0] } != nil
            if submitWhenReady {
                sessionMessage = "正在核对上次的窗口…"
                updateControls()
            }
            return
        }
        if let index = grid.highlightedIndex { choose(index) }
        else if search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { primaryClicked() }
    }

    func windowDidBecomeKey(_ notification: Notification) { updatePreviewing() }
    func windowDidResignKey(_ notification: Notification) {
        clearDrag()
        grid.setPreviewing(false)
    }

    private func updatePreviewing() {
        grid.setPreviewing(panel.isKeyWindow && !picker.isHidden && !busy && !results.isEmpty)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onCancel?()
        return false
    }

    private func select(displayID: CGDirectDisplayID, slot: Int) {
        guard !busy, activePairs[displayID]?.isEmpty != false else { return }
        submitWhenReady = false
        if selectedDisplayID != displayID { useDisplay(displayID) }
        self.slot = slot
        sessionMessage = nil
        search.stringValue = ""
        updateResults()
        panel.makeFirstResponder(search)
    }

    private func choose(_ row: Int) {
        guard !busy, results.indices.contains(row) else { return }
        assign(results[row], to: slot)
    }

    private func drag(_ choice: WindowPlacement.Choice, at point: NSPoint, phase: WindowPreviewGrid.DragPhase) {
        switch phase {
        case .began(let image):
            guard !busy, blocker == nil, panel.isKeyWindow else { return }
            draggedChoice = choice
            dragPreview.image = image ?? NSRunningApplication(processIdentifier: choice.pid)?.icon
        case .moved:
            break
        case .ended:
            guard let draggedChoice else { return }
            clearDrag()
            guard !busy, let target = displayMap.target(at: point) else { return }
            if selectedDisplayID != target.displayID || pair != nil { selected = [nil, nil] }
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
        let wasEmpty = selected[slot] == nil
        selected[slot] = choice
        sessionMessage = nil
        let next = selected.firstIndex(where: { $0 == nil })
        self.slot = next ?? slot
        search.stringValue = ""
        updateResults()
        if next == nil && wasEmpty { primaryClicked() }
        if !busy { panel.makeFirstResponder(search) }
    }

    @objc private func primaryClicked() {
        if busy {
            if canCancel { onCancel?() }
            return
        }
        guard blocker == nil, choiceTask == nil, let displayID = selectedDisplayID, activePairs[displayID]?.isEmpty != false, let pair else { return }
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
    private var selectedSlot = 0
    private var names: [String?] = []
    private var titles: [String?] = []
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

    func updateSelection(displayID: CGDirectDisplayID?, slot: Int, names: [String?], titles: [String?],
                         activePairs: [CGDirectDisplayID: [WindowPlacement.Choice]], enabled: Bool) {
        selectedDisplayID = displayID
        selectedSlot = slot
        self.names = names
        self.titles = titles
        self.activePairs = activePairs
        self.enabled = enabled
        if !enabled { dropTarget = nil }
        updateAppearance()
    }

    override func layout() {
        super.layout()
        let desktop = tiles.reduce(CGRect.null) { $0.union($1.screen.bounds) }
        let area = bounds.insetBy(dx: 9, dy: 7)
        guard desktop.width > 0, desktop.height > 0, area.width > 0, area.height > 0 else { return }
        let scale = min(area.width / desktop.width, area.height / desktop.height)
        let origin = CGPoint(x: area.midX - desktop.width * scale / 2, y: area.midY - desktop.height * scale / 2)
        for tile in tiles {
            let screen = tile.screen.bounds
            let frame = CGRect(x: origin.x + (screen.minX - desktop.minX) * scale,
                               y: origin.y + (screen.minY - desktop.minY) * scale,
                               width: screen.width * scale, height: screen.height * scale)
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
            for tile in tiles {
                let isTarget = tile.screen.id == selectedDisplayID
                let active = activePairs[tile.screen.id]
                let occupied = active?.isEmpty == false
                tile.view.layer?.borderWidth = isTarget ? 2 : 1
                tile.view.layer?.borderColor = (isTarget ? accent : .separatorColor).cgColor
                tile.view.layer?.backgroundColor = NSColor.separatorColor.cgColor
                for (slot, button) in tile.halves.enumerated() {
                    let number = tiles.map(\.screen.id).sorted().firstIndex(of: tile.screen.id).map { $0 + 1 } ?? 1
                    let position = "\(number).\(slot + 1) \(tile.screen.splitLayout.names[slot])"
                    let highlighted = isTarget && selectedSlot == slot
                    let receivingDrop = dropTarget == DropTarget(displayID: tile.screen.id, slot: slot)
                    let assigned = active.flatMap { $0.indices.contains(slot) ? $0[slot] : nil }
                    let detail = !occupied ? (isTarget && names.indices.contains(slot) ? names[slot] : (active == nil ? nil : "桌面已拆分")) : (assigned?.appName ?? "分屏中")
                    let title = assigned?.title ?? (isTarget && titles.indices.contains(slot) ? titles[slot] : nil)
                    button.attributedTitle = Self.caption(position, detail: detail)
                    let fill = highlighted ? selection : NSColor.controlBackgroundColor
                    button.layer?.backgroundColor = (receivingDrop ? dropFill : fill).cgColor
                    button.layer?.borderWidth = receivingDrop ? 2 : 0
                    button.layer?.borderColor = accent.cgColor
                    button.isEnabled = enabled && !occupied
                    button.setAccessibilityLabel([tile.screen.name, position, detail].compactMap { $0 }.joined(separator: "，"))
                    button.setAccessibilityHelp(!occupied ? (highlighted ? "当前选中" : "可选择窗口") : "快捷分屏中")
                    button.toolTip = [tile.screen.menuTitle, position, title?.isEmpty == false ? title : detail]
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

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty, let key = event.charactersIgnoringModifiers, key == "\r" || key == "\u{3}" {
            if (firstResponder as? NSTextView)?.hasMarkedText() == true { return super.performKeyEquivalent(with: event) }
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
