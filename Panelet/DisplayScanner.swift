import AppKit
import ApplicationServices
import CoreGraphics

/// Vendor number stamped on virtual displays this demo creates, so they are
/// never treated as physical screens.
enum DemoDisplay {
    static let vendorID: UInt32 = 0x5653
    static var createdIDs: Set<CGDirectDisplayID> = []
}

struct DemoError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

final class DemoLog {
    static let shared = DemoLog()
    var onLine: ((String) -> Void)?

    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    func line(_ message: String) {
        let text = "\(formatter.string(from: Date()))  \(message)"
        print(text)
        let deliver: () -> Void = {
            self.onLine?(text)
        }
        if Thread.isMainThread {
            deliver()
        } else {
            DispatchQueue.main.async(execute: deliver)
        }
    }
}

struct PhysicalScreen {
    let id: CGDirectDisplayID
    let name: String
    var bounds: CGRect
    let scale: CGFloat
    let refreshRate: Double
    let isBuiltin: Bool
    var configuration = DisplayConfiguration()

    var uuid: String { CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? "display-\(id)" }

    var isPortrait: Bool { bounds.height > bounds.width }

    var splitLayout: SplitLayout { SplitLayout(size: bounds.size, configuration: configuration) }

    var displayName: String { configuration.name.isEmpty ? name : configuration.name }

    var menuTitle: String {
        let kind = isBuiltin ? L("内建") : L("外接")
        return "\(displayName)  \(kind)  \(Int(bounds.width.rounded()))×\(Int(bounds.height.rounded()))"
    }
}

enum DisplayScanner {
    static func physicalScreens() -> [PhysicalScreen] {
        activeDisplayIDs().compactMap { id in
            guard !DemoDisplay.createdIDs.contains(id) else { return nil }
            guard CGDisplayVendorNumber(id) != DemoDisplay.vendorID else { return nil }
            let bounds = CGDisplayBounds(id)
            guard bounds.width > 1, bounds.height > 1 else { return nil }
            var screen = PhysicalScreen(
                id: id,
                name: screenName(for: id),
                bounds: bounds,
                scale: backingScale(for: id),
                refreshRate: refreshRate(for: id),
                isBuiltin: CGDisplayIsBuiltin(id) != 0
            )
            screen.configuration = ProductPreferences().display(screen.uuid)
            return screen
        }
    }

    static func portraitScreens() -> [PhysicalScreen] {
        physicalScreens().filter(\.isPortrait)
    }

    static func printList() {
        let screens = physicalScreens()
        if screens.isEmpty {
            print(L("没有检测到显示器"))
            return
        }
        for screen in screens {
            let orientation = screen.isPortrait ? L("竖屏") : L("横屏")
            print(
                "\(screen.menuTitle)  \(orientation)  id=\(screen.id)  " +
                L("原点(%@,%@)  ", String(describing: Int(screen.bounds.minX)), String(describing: Int(screen.bounds.minY))) +
                L("缩放%@×  %@Hz", String(describing: screen.scale), String(describing: screen.refreshRate))
            )
        }
        print(L("可拆分的显示器：%@", String(describing: screens.map(\.name).joined(separator: "、"))))
    }

    static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private static func screenName(for id: CGDirectDisplayID) -> String {
        let match = NSScreen.screens.first { $0.displayID == id }
        return match?.localizedName ?? L("显示器 %@", String(describing: id))
    }

    private static func backingScale(for id: CGDirectDisplayID) -> CGFloat {
        guard let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 else { return 1 }
        return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
    }

    private static func refreshRate(for id: CGDirectDisplayID) -> Double {
        let rate = CGDisplayCopyDisplayMode(id)?.refreshRate ?? 0
        return rate > 1 ? rate : 60
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

enum Permissions {
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    static var accessibility: Bool { AXIsProcessTrusted() }

    static var separateSpacesEnabled: Bool { NSScreen.screensHaveSeparateSpaces }

    static var splitProblem: String? {
        if !screenRecording && !accessibility {
            return L("请先授权屏幕录制和辅助功能，再重新启动 App。")
        }
        if !screenRecording { return L("请先授权屏幕录制，再重新启动 App。") }
        if !accessibility { return L("请先授权辅助功能，再重新启动 App。") }
        if !separateSpacesEnabled {
            return L("请在「桌面与程序坞」打开「显示器使用不同的空间」，重新登录后再拆分。")
        }
        return nil
    }

    static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        openSettings("Privacy_ScreenCapture")
    }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openSettings("Privacy_Accessibility")
    }

    static func openDesktopSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!
        NSWorkspace.shared.open(url)
    }

    private static func openSettings(_ pane: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
        NSWorkspace.shared.open(url)
    }
}

/// Global CoreGraphics coordinates have their origin at the top-left of the main
/// display and increase downward. AppKit windows use the bottom-left of the main
/// display and increase upward.
func cocoaRect(_ rect: CGRect) -> CGRect {
    let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
    return CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
}

func stableSerial(_ text: String) -> UInt32 {
    var hash: UInt32 = 2166136261
    for byte in text.utf8 {
        hash = (hash ^ UInt32(byte)) &* 16777619
    }
    return hash == 0 ? 1 : hash
}

/// Local coordinates use a top-left origin, matching CoreGraphics and window migration.
struct SplitLayout {
    let size: CGSize
    var configuration = DisplayConfiguration()
    var isPortrait: Bool {
        switch configuration.direction {
        case .automatic: return size.height > size.width
        case .vertical: return true
        case .horizontal: return false
        }
    }
    var smallRegionWarning: String? {
        regions.contains { $0.width < 480 || $0.height < 320 }
            ? L("分区较小，部分应用的最小窗口尺寸可能超出可用空间。") : nil
    }
    var direction: String { isPortrait ? L("上下") : L("左右") }
    var names: [String] { isPortrait ? [L("上半屏"), L("下半屏")] : [L("左半屏"), L("右半屏")] }
    var roles: [String] { isPortrait ? ["top", "bottom"] : ["left", "right"] }
    var regions: [CGRect] {
        if isPortrait {
            let first = floor(size.height * configuration.ratio.fraction)
            return [CGRect(x: 0, y: 0, width: size.width, height: first),
                    CGRect(x: 0, y: first, width: size.width, height: size.height - first)]
        }
        let first = floor(size.width * configuration.ratio.fraction)
        return [CGRect(x: 0, y: 0, width: first, height: size.height),
                CGRect(x: first, y: 0, width: size.width - first, height: size.height)]
    }
}
