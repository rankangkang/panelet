import AppKit

@MainActor
final class PerformanceLedger {
    static let shared = PerformanceLedger()
    struct Entry { let operation: String; let seconds: Double; let succeeded: Bool; let cancelled: Bool }
    private(set) var entries: [Entry] = []
    func record(_ operation: String, started: TimeInterval, succeeded: Bool, cancelled: Bool = false) {
        entries.append(Entry(operation: operation, seconds: max(0, ProcessInfo.processInfo.systemUptime - started), succeeded: succeeded, cancelled: cancelled))
        if entries.count > 100 { entries.removeFirst(entries.count - 100) }
    }
    var failedCount: Int { entries.filter { !$0.succeeded && !$0.cancelled }.count }
    var cancelledCount: Int { entries.filter(\.cancelled).count }
    var summary: String {
        guard !entries.isEmpty else { return L("本次运行尚无分屏性能记录。") }
        return [L("本次运行最近 %@ 次操作，失败或恢复未完成 %@ 次，主动取消 %@ 次。", String(describing: entries.count), String(describing: failedCount), String(describing: cancelledCount))]
            .adding(entries.suffix(10).map { "\($0.operation)：\(String(format: "%.2f", $0.seconds)) s · \($0.cancelled ? L("已取消分屏") : ($0.succeeded ? L("完成") : L("未完成")))" })
            .joined(separator: "\n")
    }
}

private extension Array {
    func adding(_ other: [Element]) -> [Element] { self + other }
}

/// Deliberately built from an allowlist. Raw logs may contain document/window names.
enum DiagnosticReport {
    static func make(environment: EnvironmentCheck.Report, displays: [PhysicalScreen],
                     recording: Bool, accessibility: Bool, separateSpaces: Bool,
                     performance: String, capture: [String]) -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let displayLines = displays.enumerated().map { index, screen in
            L("显示器 %@：%@×%@ 点，%@×，%@ Hz；%@ / %@ / %@", String(describing: index + 1), String(describing: Int(screen.bounds.width)), String(describing: Int(screen.bounds.height)), String(describing: screen.scale), String(describing: Int(screen.refreshRate)), String(describing: screen.configuration.direction.rawValue), String(describing: screen.configuration.ratio.title), String(describing: screen.configuration.rendering.rawValue))
        }
        return (["Panelet \(version)", environment.details,
                 L("屏幕录制：%@；辅助功能：%@；独立空间：%@", String(describing: recording), String(describing: accessibility), String(describing: separateSpaces)),
                 L("报告不包含窗口标题、画面、应用列表、显示器名称或序列号、许可证、文件路径。")]
                + displayLines + [performance] + capture).joined(separator: "\n\n")
    }
}

@MainActor
final class DisplayIdentifiers {
    private var windows: [NSWindow] = []
    private var dismissal: Task<Void, Never>?
    func show(_ screens: [PhysicalScreen]) {
        dismissal?.cancel()
        windows.forEach { $0.orderOut(nil) }
        windows = screens.sorted { $0.id < $1.id }.enumerated().map { index, screen in
            let frame = cocoaRect(screen.bounds)
            let badge = NSPanel(contentRect: CGRect(x: frame.midX - 180, y: frame.midY - 70, width: 360, height: 140),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            badge.isReleasedWhenClosed = false
            badge.level = .screenSaver
            badge.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            badge.ignoresMouseEvents = true
            badge.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95)
            let label = NSTextField(wrappingLabelWithString: "\(index + 1)\n\(screen.displayName)")
            label.font = .systemFont(ofSize: 28, weight: .semibold)
            label.alignment = .center
            label.frame = CGRect(x: 15, y: 20, width: 330, height: 100)
            badge.contentView?.addSubview(label)
            badge.orderFrontRegardless()
            return badge
        }
        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            self?.windows.forEach { $0.orderOut(nil) }
            self?.windows.removeAll()
        }
    }
}
