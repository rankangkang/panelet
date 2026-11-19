import AppKit

@MainActor
enum SettingsUI {
    static func text(
        _ text: String,
        size: CGFloat = 13,
        weight: NSFont.Weight = .regular,
        secondary: Bool = false,
        maxWidth: CGFloat = 470
    ) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        label.preferredMaxLayoutWidth = maxWidth
        return label
    }

    static func sectionHeading(_ title: String, detail: String) -> NSStackView {
        let stack = NSStackView(views: [text(title, size: 25, weight: .bold), text(detail, secondary: true)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    static func page(_ title: String, subtitle: String, views: [NSView]) -> NSView {
        let page = NSView()
        let header = sectionHeading(title, detail: subtitle)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        for view in views where view is NSBox {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let scroll = topAlignedScroll(stack)
        for view in [header, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            page.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: page.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: page.topAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 24),
            scroll.bottomAnchor.constraint(equalTo: page.bottomAnchor),
        ])
        return page
    }

    static func topAlignedScroll(
        _ body: NSView,
        insets: NSEdgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 12, right: 0)
    ) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        body.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(body)
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            body.topAnchor.constraint(equalTo: document.topAnchor, constant: insets.top),
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: insets.left),
            body.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -insets.right),
            body.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -insets.bottom),
        ])
        return scroll
    }

    static func layoutEditor(
        preview: SettingsLayoutPreview,
        direction: NSPopUpButton,
        ratio: NSPopUpButton
    ) -> NSStackView {
        let directionTitle = L("分屏方向")
        let ratioTitle = L("分区比例")
        direction.addItems(withTitles: DisplayConfiguration.Direction.allCases.map(\.title))
        direction.setAccessibilityLabel(directionTitle)
        ratio.addItems(withTitles: DisplayConfiguration.Ratio.allCases.map(\.title))
        ratio.setAccessibilityLabel(ratioTitle)
        let fields = NSStackView(views: [
            text(directionTitle, size: 12, weight: .semibold), direction,
            text(ratioTitle, size: 12, weight: .semibold), ratio,
        ])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 6
        fields.setCustomSpacing(12, after: direction)
        NSLayoutConstraint.activate([
            fields.widthAnchor.constraint(equalToConstant: 136),
            direction.widthAnchor.constraint(equalTo: fields.widthAnchor),
            ratio.widthAnchor.constraint(equalTo: fields.widthAnchor),
            preview.heightAnchor.constraint(equalToConstant: 136),
        ])
        let row = NSStackView(views: [fields, preview])
        row.alignment = .centerY
        row.spacing = 18
        return row
    }

    static func card(_ views: [NSView]) -> NSBox {
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
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        for view in views where view is NSPopUpButton || view is NSScrollView || view is EnvironmentStatusView || view is SettingsDisplayArrangement || (view as? NSStackView)?.orientation == .horizontal {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return box
    }

    static func row(_ title: String, detail: String, control: NSView) -> NSStackView {
        let labels = NSStackView(views: [text(title, weight: .semibold), text(detail, size: 11, secondary: true)])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 5
        let row = NSStackView(views: [labels, NSView(), control])
        row.alignment = .centerY
        row.spacing = 12
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        return row
    }

    static func button(_ title: String, target: AnyObject?, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        return button
    }
}

extension RestoreAction {
    @MainActor init(session: Session, mergeDesktop: Bool = false) {
        self.init(hasPair: session.hasQuick, wasDesktop: session.mode == .desktop, mergeDesktop: mergeDesktop)
    }

    var title: String {
        switch self {
        case .mergeDesktop: return L("合并桌面")
        case .endPair: return L("结束组合，保留桌面")
        case .endPairAndRestore: return L("结束组合并恢复整屏")
        }
    }

    var menuTitle: String { "\(title)…" }

    func prompt(for display: String) -> String {
        switch self {
        case .mergeDesktop: return L("合并 %@ 的桌面？", display)
        case .endPair: return L("结束 %@ 的窗口组合？", display)
        case .endPairAndRestore: return L("将 %@ 恢复为整屏？", display)
        }
    }

    var detail: String {
        switch self {
        case .mergeDesktop(endsPair: false): return L("两个独立桌面将合并为一块显示器，Panelet 会尝试迁回窗口。")
        case .mergeDesktop(endsPair: true): return L("Panelet 会结束窗口组合，合并两个桌面，并尝试迁回窗口。")
        case .endPair: return L("Panelet 会结束全屏组合并尝试还原窗口。两个独立桌面会保留。")
        case .endPairAndRestore: return L("Panelet 会结束全屏组合，将显示器恢复为整屏，并尝试还原窗口。")
        }
    }
}

@MainActor
final class RestoreDisplayPicker: NSPopUpButton {
    var onSelect: ((Int) -> Void)?
    @objc func selectionChanged() { onSelect?(indexOfSelectedItem) }
}

@MainActor
final class SettingsStatusLine: NSStackView {
    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private var lastReady: Bool?

    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .horizontal
        alignment = .centerY
        spacing = 7
        icon.setAccessibilityElement(false)
        icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 14).isActive = true
        label.font = .systemFont(ofSize: 12, weight: .medium)
        addArrangedSubview(icon)
        addArrangedSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ text: String, ready: Bool) {
        guard label.stringValue != text || lastReady != ready else { return }
        label.stringValue = text
        icon.image = NSImage(
            systemSymbolName: ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            accessibilityDescription: nil
        )
        icon.contentTintColor = ready ? .systemGreen : .systemOrange
        lastReady = ready
    }
}

@MainActor
final class EnvironmentStatusView: NSBox {
    private let icon = NSImageView()
    private let heading = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let checked = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        boxType = .custom
        titlePosition = .noTitle
        cornerRadius = 9
        borderWidth = 0
        contentViewMargins = .zero
        icon.setAccessibilityElement(false)
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        detail.font = .systemFont(ofSize: 12)
        detail.preferredMaxLayoutWidth = 370
        checked.font = .systemFont(ofSize: 11)
        checked.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [heading, detail, checked])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 5
        let row = NSStackView(views: [icon, labels])
        row.alignment = .top
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        contentView = content
        content.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ report: EnvironmentCheck.Report, checkedAt: Date) {
        let symbol: String
        let color: NSColor
        switch report.status {
        case .available: (symbol, color) = ("checkmark.circle.fill", .systemGreen)
        case .limited: (symbol, color) = ("exclamationmark.triangle.fill", .systemOrange)
        case .unavailable: (symbol, color) = ("xmark.octagon.fill", .systemRed)
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = color
        fillColor = color.withAlphaComponent(0.10)
        heading.stringValue = report.statusTitle
        detail.stringValue = report.statusDetail
        checked.stringValue = L(
            "上次检测：%@",
            DateFormatter.localizedString(from: checkedAt, dateStyle: .none, timeStyle: .medium)
        )
    }
}

@MainActor
final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class SettingsDisplayArrangement: NSView {
    private struct Tile {
        let screen: PhysicalScreen
        let button: NSButton
    }

    var onSelect: ((CGDirectDisplayID) -> Void)?
    override var isFlipped: Bool { true }
    private var tiles: [Tile] = []
    private var selectedID: CGDirectDisplayID?
    private var enabled = false

    func updateDisplays(_ screens: [PhysicalScreen]) {
        tiles.forEach { $0.button.removeFromSuperview() }
        tiles = screens.enumerated().map { index, screen in
            let number = String(index + 1)
            let button = NSButton(title: number, target: self, action: #selector(displayClicked(_:)))
            button.setButtonType(.pushOnPushOff)
            button.isBordered = false
            button.contentTintColor = .labelColor
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.setAccessibilityLabel(L("显示器 %@：%@", number, screen.displayName))
            button.toolTip = "\(number) · \(screen.menuTitle)"
            addSubview(button)
            return Tile(screen: screen, button: button)
        }
        needsLayout = true
        updateAppearance()
    }

    func updateSelection(_ id: CGDirectDisplayID?, enabled: Bool) {
        guard selectedID != id || self.enabled != enabled else { return }
        selectedID = id
        self.enabled = enabled
        updateAppearance()
    }

    override func layout() {
        super.layout()
        let frames = DisplayScanner.arrangementFrames(tiles.map(\.screen.bounds), in: bounds.insetBy(dx: 8, dy: 5))
        for (tile, frame) in zip(tiles, frames) {
            tile.button.frame = frame.insetBy(dx: min(3, frame.width / 10), dy: min(3, frame.height / 10))
            let size = min(tile.button.bounds.width, tile.button.bounds.height)
            tile.button.font = .systemFont(ofSize: min(16, max(9, size * 0.3)), weight: .semibold)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = NSColor.controlAccentColor
            let selection = accent.blended(withFraction: 0.82, of: .controlBackgroundColor) ?? .controlBackgroundColor
            for tile in tiles {
                let selected = tile.screen.id == selectedID
                tile.button.state = selected ? .on : .off
                tile.button.isEnabled = enabled
                tile.button.layer?.backgroundColor = (selected ? selection : .controlBackgroundColor).cgColor
                tile.button.layer?.borderColor = (selected ? accent : .separatorColor).cgColor
                tile.button.layer?.borderWidth = selected ? 2 : 1
                tile.button.setAccessibilitySelected(selected)
                tile.button.setAccessibilityHelp(selected ? L("当前选中") : L("选择此显示器"))
            }
        }
    }

    @objc private func displayClicked(_ sender: NSButton) {
        guard let tile = tiles.first(where: { $0.button === sender }) else { return }
        onSelect?(tile.screen.id)
    }
}

@MainActor
final class SettingsLayoutPreview: NSView {
    var screen: PhysicalScreen? {
        didSet {
            let label = screen.map { screen in
                L("%@，%@ %@，两个独立桌面", screen.displayName, screen.splitLayout.direction, screen.configuration.ratio.title)
            }
            setAccessibilityElement(screen != nil)
            setAccessibilityRole(.image)
            setAccessibilityLabel(label)
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let screen, screen.bounds.width > 0, screen.bounds.height > 0 else { return }
        let captionArea: CGFloat = 22
        let availableWidth = min(bounds.width - 16, 232)
        let availableHeight = bounds.height - captionArea - 16
        guard availableWidth > 0, availableHeight > 0 else { return }
        let scale = min(availableWidth / screen.bounds.width, availableHeight / screen.bounds.height)
        let size = CGSize(width: screen.bounds.width * scale, height: screen.bounds.height * scale)
        let frame = CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.minY + captionArea + (bounds.height - captionArea - size.height) / 2,
            width: size.width,
            height: size.height
        )
        NSColor.separatorColor.setStroke()
        let outline = NSBezierPath(roundedRect: frame.insetBy(dx: -5, dy: -5), xRadius: 9, yRadius: 9)
        outline.lineWidth = 2
        outline.stroke()
        for (index, region) in screen.splitLayout.regions.enumerated() {
            let rect = CGRect(
                x: frame.minX + region.minX / screen.bounds.width * size.width,
                y: frame.maxY - region.maxY / screen.bounds.height * size.height,
                width: region.width / screen.bounds.width * size.width,
                height: region.height / screen.bounds.height * size.height
            ).insetBy(dx: 2, dy: 2)
            NSColor.controlAccentColor.withAlphaComponent(index == 0 ? 0.22 : 0.12).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            if rect.width >= 10, rect.height >= 14 {
                drawLabel(screen.splitLayout.names[index], in: rect.insetBy(dx: 2, dy: 0), color: .labelColor)
            }
        }
        let caption = L("%@ %@ · 两个独立桌面", screen.splitLayout.direction, screen.configuration.ratio.title)
        drawLabel(caption, in: CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: captionArea), color: .secondaryLabelColor)
    }

    private func drawLabel(_ title: String, in rect: CGRect, color: NSColor) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        let font = NSFont.systemFont(ofSize: 11)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        let title = title as NSString
        let height = ceil(title.size(withAttributes: attributes).height)
        title.draw(
            in: CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height),
            withAttributes: attributes
        )
    }
}

@MainActor
final class SettingsBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
