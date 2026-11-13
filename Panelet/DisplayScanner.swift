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

    var isPortrait: Bool { bounds.height > bounds.width }

    var menuTitle: String {
        let kind = isBuiltin ? "内建" : "外接"
        return "\(name)  \(kind)  \(Int(bounds.width.rounded()))×\(Int(bounds.height.rounded()))"
    }
}

enum DisplayScanner {
    static func physicalScreens() -> [PhysicalScreen] {
        activeDisplayIDs().compactMap { id in
            guard !DemoDisplay.createdIDs.contains(id) else { return nil }
            guard CGDisplayVendorNumber(id) != DemoDisplay.vendorID else { return nil }
            let bounds = CGDisplayBounds(id)
            guard bounds.width > 1, bounds.height > 1 else { return nil }
            return PhysicalScreen(
                id: id,
                name: screenName(for: id),
                bounds: bounds,
                scale: backingScale(for: id),
                refreshRate: refreshRate(for: id),
                isBuiltin: CGDisplayIsBuiltin(id) != 0
            )
        }
    }

    static func portraitScreens() -> [PhysicalScreen] {
        physicalScreens().filter(\.isPortrait)
    }

    static func printList() {
        let screens = physicalScreens()
        if screens.isEmpty {
            print("没有检测到显示器")
            return
        }
        for screen in screens {
            let orientation = screen.isPortrait ? "竖屏" : "横屏"
            print(
                "\(screen.menuTitle)  \(orientation)  id=\(screen.id)  " +
                "原点(\(Int(screen.bounds.minX)),\(Int(screen.bounds.minY)))  " +
                "缩放\(screen.scale)×  \(screen.refreshRate)Hz"
            )
        }
        let portraits = screens.filter(\.isPortrait)
        if portraits.isEmpty {
            print("没有竖屏。把一块显示器在“系统设置 → 显示器”里旋转 90° 或 270° 后再运行。")
        } else {
            print("可拆分的竖屏：\(portraits.map(\.name).joined(separator: "、"))")
        }
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
        return match?.localizedName ?? "显示器 \(id)"
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
            return "请先授权屏幕录制和辅助功能，再重新启动 App。"
        }
        if !screenRecording { return "请先授权屏幕录制，再重新启动 App。" }
        if !accessibility { return "请先授权辅助功能，再重新启动 App。" }
        if !separateSpacesEnabled {
            return "请在「桌面与程序坞」打开「显示器使用不同的空间」，重新登录后再拆分。"
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
