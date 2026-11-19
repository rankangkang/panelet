import AppKit
import ScreenCaptureKit

@MainActor
final class WindowPreviewGrid: NSScrollView, NSCollectionViewDataSource {
    enum DragPhase {
        case began(NSImage?)
        case moved
        case ended
    }

    var onChoose: ((Int) -> Void)?
    var onDrag: ((WindowPlacement.Choice, NSPoint, DragPhase) -> Void)?
    private(set) var highlightedIndex: Int?
    var isEnabled = true {
        didSet {
            guard oldValue != isEnabled else { return }
            collection.setAccessibilityEnabled(isEnabled)
            visibleCards.forEach { $0.button.isEnabled = isEnabled }
        }
    }

    private struct Preview {
        let image: NSImage?
        let refreshAfter: ContinuousClock.Instant
    }

    private static let maxConcurrentCaptures = 4
    private let collection = NSCollectionView()
    private let clock = ContinuousClock()
    private var choices: [WindowPlacement.Choice] = []
    private var previews: [WindowPlacement.Choice.ID: Preview] = [:]
    private var cachedWindows: (byPID: [pid_t: [SCWindow]], expiresAt: ContinuousClock.Instant)?
    private var refreshTask: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let layout = NSCollectionViewGridLayout()
        layout.minimumLineSpacing = 8
        layout.minimumInteritemSpacing = 8
        layout.margins = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 6)
        layout.minimumItemSize = NSSize(width: 208, height: 150)
        layout.maximumItemSize = NSSize(width: 312, height: 150)
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.backgroundColors = [.clear]
        collection.register(WindowPreviewCard.self, forItemWithIdentifier: WindowPreviewCard.reuseID)
        collection.setAccessibilityLabel(L("可分屏的窗口"))
        collection.setAccessibilityEnabled(true)
        collection.autoresizingMask = [.width]
        documentView = collection
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .legacy
    }

    required init?(coder: NSCoder) { nil }

    func show(_ choices: [WindowPlacement.Choice], highlightFirst: Bool) {
        self.choices = choices
        highlightedIndex = highlightFirst && !choices.isEmpty ? 0 : nil
        collection.reloadData()
        contentView.scroll(to: .zero)
        reflectScrolledClipView(contentView)
    }

    func moveHighlight(by direction: Int) {
        guard isEnabled, !choices.isEmpty else { return }
        let next = highlightedIndex.map { min(max(0, $0 + direction), choices.count - 1) } ?? 0
        highlightedIndex = next
        revealHighlight()
        for card in visibleCards { card.button.isCurrent = card.button.tag == next }
    }

    func revealHighlight() {
        guard let index = highlightedIndex else { return }
        let path = IndexPath(item: index, section: 0)
        if let frame = collection.layoutAttributesForItem(at: path)?.frame, !collection.visibleRect.contains(frame) {
            collection.scrollToItems(at: [path], scrollPosition: .nearestVerticalEdge)
        }
    }

    func setPreviewing(_ enabled: Bool) {
        if enabled {
            guard refreshTask == nil else { return }
            refreshTask = Task { [weak self] in
                while !Task.isCancelled, self != nil {
                    await self?.refreshVisiblePreviews()
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        } else {
            refreshTask?.cancel()
            refreshTask = nil
        }
    }

    func resetPreviews() {
        previews.removeAll()
        cachedWindows = nil
        for card in visibleCards { card.showPreview(nil) }
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        choices.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt path: IndexPath) -> NSCollectionViewItem {
        let card = collectionView.makeItem(withIdentifier: WindowPreviewCard.reuseID, for: path) as! WindowPreviewCard
        let choice = choices[path.item]
        card.configure(choice, preview: previews[choice.id]?.image)
        card.button.target = self
        card.button.action = #selector(choose(_:))
        card.button.tag = path.item
        card.button.isCurrent = highlightedIndex == path.item
        card.button.isEnabled = isEnabled
        card.button.onDrag = { [weak self] point, phase in self?.onDrag?(choice, point, phase) }
        return card
    }

    @objc private func choose(_ sender: NSButton) { onChoose?(sender.tag) }

    private var visibleCards: [WindowPreviewCard] {
        collection.visibleItems().compactMap { $0 as? WindowPreviewCard }
    }

    private func shareableWindowsByPID() async -> [pid_t: [SCWindow]] {
        let now = clock.now
        if let cachedWindows, cachedWindows.expiresAt > now {
            return cachedWindows.byPID
        }
        let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let grouped = Dictionary(grouping: content?.windows.filter { $0.windowLayer == 0 } ?? []) {
            $0.owningApplication?.processID ?? 0
        }
        cachedWindows = (grouped, clock.now.advanced(by: .milliseconds(1500)))
        return grouped
    }

    private func refreshVisiblePreviews() async {
        let now = clock.now
        let visible = collection.visibleRect
        let targets = visibleCards.filter { $0.view.convert($0.view.bounds, to: collection).intersects(visible) }
            .compactMap(\.choice)
            .filter { previews[$0.id].map { $0.refreshAfter <= now } ?? true }
        guard !targets.isEmpty else { return }
        // Keep recent thumbnails when searching or switching halves, then let them expire.
        previews = previews.filter { $0.value.refreshAfter.advanced(by: .seconds(12)) > now }
        let windows = await shareableWindowsByPID()
        let activeTargets = targets.filter { target in
            visibleCards.contains { $0.choice?.id == target.id }
        }
        guard !activeTargets.isEmpty, !Task.isCancelled else { return }

        // Capture CGImage (Sendable) off the main actor, then construct NSImage on MainActor.
        await withTaskGroup(of: (WindowPlacement.Choice.ID, CGImage?).self) { group in
            var index = 0
            let initial = min(Self.maxConcurrentCaptures, activeTargets.count)
            for _ in 0..<initial {
                let choice = activeTargets[index]
                index += 1
                let matched = Self.match(choice, in: windows[choice.pid] ?? [])
                let id = choice.id
                group.addTask {
                    guard !Task.isCancelled, let matched else { return (id, nil) }
                    return (id, await Self.thumbnailCGImage(of: matched))
                }
            }
            for await (id, cgImage) in group {
                guard !Task.isCancelled else { break }
                let image = cgImage.map { NSImage(cgImage: $0, size: .zero) }
                previews[id] = Preview(image: image, refreshAfter: clock.now.advanced(by: .seconds(3)))
                visibleCards.first { $0.choice?.id == id }?.showPreview(image)
                if index < activeTargets.count, !Task.isCancelled {
                    let choice = activeTargets[index]
                    index += 1
                    let matched = Self.match(choice, in: windows[choice.pid] ?? [])
                    let nextID = choice.id
                    group.addTask {
                        guard !Task.isCancelled, let matched else { return (nextID, nil) }
                        return (nextID, await Self.thumbnailCGImage(of: matched))
                    }
                }
            }
        }
    }

    nonisolated private static func match(_ choice: WindowPlacement.Choice, in windows: [SCWindow]) -> SCWindow? {
        if let id = choice.windowID { return windows.first { $0.windowID == id } }
        guard let frame = choice.frame else { return nil }
        // Accessibility and ScreenCaptureKit enumerate windows separately. Avoid guessing when windows overlap.
        let nearby = windows.filter { WindowPlacement.near($0.frame, frame) }
        let named = choice.title.isEmpty ? [] : nearby.filter { $0.title == choice.title }
        if named.count == 1 { return named[0] }
        guard nearby.count == 1, let only = nearby.first,
              choice.title.isEmpty || only.title?.isEmpty != false else { return nil }
        return only
    }

    nonisolated private static func thumbnailCGImage(of window: SCWindow) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let size = filter.contentRect.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(480 / size.width, 210 / size.height)
        let config = SCStreamConfiguration()
        config.width = max(2, Int((size.width * scale).rounded()))
        config.height = max(2, Int((size.height * scale).rounded()))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.ignoreGlobalClipSingleWindow = true
        config.scalesToFit = true
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

@MainActor
private final class WindowPreviewCard: NSCollectionViewItem {
    static let reuseID = NSUserInterfaceItemIdentifier("WindowPreviewCard")
    private(set) var choice: WindowPlacement.Choice?
    let button = PreviewButton(frame: .zero)
    private let preview = NSImageView()
    private let fallback = NSImageView()
    private let icon = NSImageView()
    private let appLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")

    override func loadView() {
        button.isBordered = false
        button.title = ""
        button.refusesFirstResponder = true
        let well = NSBox()
        well.boxType = .custom
        well.borderWidth = 0
        well.cornerRadius = 6
        well.fillColor = NSColor.labelColor.withAlphaComponent(0.055)
        well.contentViewMargins = .zero
        well.setAccessibilityElement(false)
        for image in [preview, fallback, icon] {
            image.imageScaling = .scaleProportionallyUpOrDown
            image.setAccessibilityElement(false)
        }
        let surface = well.contentView!
        surface.addSubview(preview)
        surface.addSubview(fallback)

        appLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.textColor = .secondaryLabelColor
        for label in [appLabel, titleLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setAccessibilityElement(false)
        }
        let labels = NSStackView(views: [appLabel, titleLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        let caption = NSStackView(views: [icon, labels])
        caption.alignment = .centerY
        caption.spacing = 6

        button.addSubview(well)
        button.addSubview(caption)
        for child in [well, preview, fallback, caption] { child.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            well.topAnchor.constraint(equalTo: button.topAnchor, constant: 6),
            well.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 6),
            well.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -6),
            well.heightAnchor.constraint(equalToConstant: 106),
            preview.topAnchor.constraint(equalTo: surface.topAnchor, constant: 4),
            preview.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -4),
            preview.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 4),
            preview.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -4),
            fallback.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            fallback.centerYAnchor.constraint(equalTo: surface.centerYAnchor),
            fallback.widthAnchor.constraint(equalToConstant: 38),
            fallback.heightAnchor.constraint(equalTo: fallback.widthAnchor),
            caption.topAnchor.constraint(equalTo: well.bottomAnchor, constant: 5),
            caption.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 10),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: button.trailingAnchor, constant: -10),
            icon.widthAnchor.constraint(equalToConstant: 19),
            icon.heightAnchor.constraint(equalTo: icon.widthAnchor),
        ])
        view = button
    }

    func configure(_ choice: WindowPlacement.Choice, preview: NSImage?) {
        self.choice = choice
        let appIcon = NSRunningApplication(processIdentifier: choice.pid)?.icon
            ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        icon.image = appIcon
        fallback.image = appIcon
        appLabel.stringValue = choice.appName
        let details = [choice.title, choice.status ?? ""].filter { !$0.isEmpty }
        titleLabel.stringValue = details.joined(separator: " · ")
        titleLabel.isHidden = details.isEmpty
        let label = ([choice.appName] + details).joined(separator: "，")
        button.toolTip = label
        button.setAccessibilityLabel(label)
        showPreview(preview)
    }

    func showPreview(_ image: NSImage?) {
        preview.image = image
        preview.isHidden = image == nil
        fallback.isHidden = image != nil
    }
}

@MainActor
private final class PreviewButton: NSButton {
    var onDrag: ((NSPoint, WindowPreviewGrid.DragPhase) -> Void)?
    private var pressPoint: NSPoint?
    private var hasStartedDrag = false
    var isCurrent = false {
        didSet {
            guard oldValue != isCurrent else { return }
            setAccessibilitySelected(isCurrent)
            setAccessibilityHelp(isCurrent ? L("按回车选择此窗口") : nil)
            needsDisplay = true
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressPoint = event.locationInWindow
        hasStartedDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, let pressPoint else { return }
        let point = event.locationInWindow
        if hasStartedDrag {
            onDrag?(point, .moved)
        } else if hypot(point.x - pressPoint.x, point.y - pressPoint.y) >= 4 {
            hasStartedDrag = true
            onDrag?(point, .began(dragImage()))
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard pressPoint != nil else { return }
        pressPoint = nil
        let point = event.locationInWindow
        if hasStartedDrag {
            hasStartedDrag = false
            onDrag?(point, .ended)
        } else if isEnabled && bounds.contains(convert(point, from: nil)) {
            performClick(nil)
        }
    }

    private func dragImage() -> NSImage? {
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: bitmap)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
        let selected = isCurrent && isEnabled
        (selected ? accent.withAlphaComponent(0.10) : NSColor.controlBackgroundColor).setFill()
        border.fill()
        (selected ? accent : NSColor.separatorColor).setStroke()
        border.lineWidth = selected ? 2 : 1
        border.stroke()
    }
}
