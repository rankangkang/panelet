import AppKit
import ObjectiveC

/// Read-only capability checks. Presence is not proof of private API behavior.
enum EnvironmentCheck {
    enum Status { case available, limited, unavailable }

    struct Report {
        let missing: [String]
        let optionalMissing: [String]
        var canSplit: Bool { missing.isEmpty }
        var status: Status {
            if !canSplit { return .unavailable }
            return optionalMissing.isEmpty ? .available : .limited
        }
        var statusTitle: String {
            switch status {
            case .available: return L("必要接口检测通过")
            case .limited: return L("部分窗口兼容能力受限")
            case .unavailable: return L("无法新建分屏")
            }
        }
        var statusDetail: String {
            switch status {
            case .available: return L("仅确认接口存在，实际兼容性以分屏运行为准。权限请查看“权限”页。")
            case .limited: return L("必要接口已找到，部分窗口兼容功能可能不可用。可预览诊断报告查看详情。")
            case .unavailable: return L("系统缺少必要接口，已有分屏仍可还原。可预览诊断报告查看详情。")
            }
        }
        var problem: String? {
            canSplit ? nil : L("当前系统缺少分屏所需的能力，已暂停新建分屏。请在设置的“诊断”页查看环境检测；已有分屏仍可还原。")
        }
        var summary: String {
            if !canSplit { return L("当前环境不支持新建分屏") }
            return optionalMissing.isEmpty ? L("必要接口检查通过，实际兼容性以分屏运行为准") : L("必要接口检查通过，部分窗口兼容能力受限")
        }
        var details: String {
            ([L("系统：%@", String(describing: ProcessInfo.processInfo.operatingSystemVersionString)), summary,
              L("此检查不创建显示器、不移动窗口。接口存在不代表其行为兼容；权限状态请查看“权限”页。")]
             + missing.map { L("缺少必要接口：%@", String(describing: $0)) }
             + optionalMissing.map { L("缺少可选接口：%@", String(describing: $0)) }).joined(separator: "\n")
        }
    }

    static let methods: [(String, [String])] = [
        ("CGVirtualDisplayDescriptor", ["init", "setQueue:", "setName:", "setMaxPixelsWide:",
            "setMaxPixelsHigh:", "setSizeInMillimeters:", "setVendorID:", "setProductID:",
            "setSerialNum:", "setTerminationHandler:"]),
        ("CGVirtualDisplay", ["initWithDescriptor:", "displayID", "applySettings:"]),
        ("CGVirtualDisplaySettings", ["init", "setHiDPI:", "setModes:"]),
        ("CGVirtualDisplayMode", ["initWithWidth:height:refreshRate:"])
    ]
    static let requiredSymbols = SystemBridge.requiredSymbols
    static let optionalSymbols = SystemBridge.optionalSymbols

    static func inspect(
        hasClass: (String) -> Bool = { NSClassFromString($0) != nil },
        hasMethod: (String, String) -> Bool = { name, selector in
            guard let type = NSClassFromString(name) else { return false }
            return class_getInstanceMethod(type, NSSelectorFromString(selector)) != nil
        },
        hasSymbol: (String) -> Bool = SystemBridge.hasSymbol
    ) -> Report {
        var missing: [String] = []
        for (name, selectors) in methods {
            guard hasClass(name) else { missing.append(name); continue }
            missing += selectors.filter { !hasMethod(name, $0) }.map { "\(name).\($0)" }
        }
        missing += requiredSymbols.filter { !hasSymbol($0) }
        return Report(missing: missing, optionalMissing: optionalSymbols.filter { !hasSymbol($0) })
    }
}
