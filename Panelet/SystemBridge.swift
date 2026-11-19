import ApplicationServices
import CoreGraphics
import Foundation

/// Centralized runtime bindings for private macOS WindowServer (SkyLight),
/// Accessibility, and HIServices symbols. Keeping every dynamic lookup in one
/// place guarantees `EnvironmentCheck` and runtime callers never drift apart.
enum SystemBridge {
    static let requiredSymbols = [
        "SLSMainConnectionID",
        "SLSCopyManagedDisplaySpaces",
        "SLSCopySpacesForWindows",
        "SLSProcessAssignToSpace",
    ]

    static let optionalSymbols = [
        "SLSFindWindowAndOwner",
        "SLSGetWindowLevel",
        "_AXUIElementGetWindow",
        "_AXUIElementCreateWithRemoteToken",
        "GetProcessForPID",
        "_SLPSSetFrontProcessWithOptions",
    ]

    private nonisolated(unsafe) static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)

    static func hasSymbol(_ name: String) -> Bool {
        dlsym(defaultHandle, name) != nil
    }

    fileprivate static func loadSymbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let pointer = dlsym(defaultHandle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    enum SkyLight {
        private typealias MainConnectionFn = @convention(c) () -> Int32
        private typealias FindWindowFn = @convention(c) (
            Int32, Int32, Int32, Int32,
            UnsafePointer<CGPoint>,
            UnsafeMutablePointer<CGPoint>,
            UnsafeMutablePointer<CGWindowID>,
            UnsafeMutablePointer<Int32>
        ) -> Int32
        private typealias GetWindowLevelFn = @convention(c) (
            Int32, CGWindowID, UnsafeMutablePointer<Int32>
        ) -> Int32
        private typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
        private typealias CopySpacesForWindowsFn = @convention(c) (
            Int32, UInt32, CFArray
        ) -> Unmanaged<CFArray>?
        private typealias ProcessAssignToSpaceFn = @convention(c) (Int32, pid_t, UInt64) -> Int32

        static let connectionID: Int32 = {
            SystemBridge.loadSymbol("SLSMainConnectionID", as: MainConnectionFn.self)?() ?? 0
        }()

        private static let findWindow = SystemBridge.loadSymbol("SLSFindWindowAndOwner", as: FindWindowFn.self)
        private static let getWindowLevel = SystemBridge.loadSymbol("SLSGetWindowLevel", as: GetWindowLevelFn.self)
        private static let copySpaces = SystemBridge.loadSymbol(
            "SLSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpacesFn.self
        )
        private static let copyWindowSpaces = SystemBridge.loadSymbol(
            "SLSCopySpacesForWindows", as: CopySpacesForWindowsFn.self
        )
        private static let assignProcessSpace = SystemBridge.loadSymbol(
            "SLSProcessAssignToSpace", as: ProcessAssignToSpaceFn.self
        )

        static var supportsHitTesting: Bool {
            connectionID != 0 && findWindow != nil
        }

        static var supportsLiveRouting: Bool {
            supportsHitTesting && getWindowLevel != nil
        }

        static func window(at point: CGPoint) -> CGWindowID? {
            guard let findWindow, connectionID != 0 else { return nil }
            var screenPoint = point
            var windowPoint = CGPoint.zero
            var windowID: CGWindowID = 0
            var ownerConnection: Int32 = 0
            guard findWindow(connectionID, 0, 1, 0, &screenPoint, &windowPoint, &windowID, &ownerConnection) == 0,
                  windowID != kCGNullWindowID else { return nil }
            return windowID
        }

        static func level(of windowID: CGWindowID) -> Int32? {
            guard let getWindowLevel, connectionID != 0 else { return nil }
            var result: Int32 = 0
            guard getWindowLevel(connectionID, windowID, &result) == 0 else { return nil }
            return result
        }

        static func managedDisplaySpaces() -> [[String: Any]]? {
            guard connectionID != 0 else { return nil }
            return copySpaces?(connectionID)?.takeRetainedValue() as? [[String: Any]]
        }

        static func spaces(for windowID: CGWindowID) -> [UInt64]? {
            guard connectionID != 0,
                  let values = copyWindowSpaces?(connectionID, 7, [NSNumber(value: windowID)] as CFArray)?
                    .takeRetainedValue() as? [NSNumber] else { return nil }
            return values.map(\.uint64Value)
        }

        static func moveApplication(_ pid: pid_t, toSpace spaceID: UInt64) {
            guard connectionID != 0 else { return }
            _ = assignProcessSpace?(connectionID, pid, spaceID)
        }
    }

    enum Accessibility {
        private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
        private typealias CreateWithRemoteTokenFn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
        private typealias GetProcessForPIDFn = @convention(c) (
            pid_t, UnsafeMutablePointer<ProcessSerialNumber>
        ) -> OSStatus
        private typealias SetFrontProcessWithOptionsFn = @convention(c) (
            UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32
        ) -> CGError

        private static let getWindow = SystemBridge.loadSymbol("_AXUIElementGetWindow", as: GetWindowFn.self)
        private static let createWithRemoteToken = SystemBridge.loadSymbol(
            "_AXUIElementCreateWithRemoteToken", as: CreateWithRemoteTokenFn.self
        )
        private static let getProcessForPID = SystemBridge.loadSymbol("GetProcessForPID", as: GetProcessForPIDFn.self)
        private static let setFrontProcessWithOptions = SystemBridge.loadSymbol(
            "_SLPSSetFrontProcessWithOptions", as: SetFrontProcessWithOptionsFn.self
        )

        static var supportsRemoteTokenLookup: Bool {
            createWithRemoteToken != nil && getWindow != nil
        }

        static func windowID(of element: AXUIElement) -> CGWindowID? {
            var id: CGWindowID = 0
            guard getWindow?(element, &id) == .success, id != 0 else { return nil }
            return id
        }

        /// Builds the 20-byte AppKit remote AX token (`pid`, reserved `0`, `"coco"`, `elementID`)
        /// and resolves it into an `AXUIElement` when valid.
        static func element(pid: pid_t, remoteElementID: UInt64, buffer: inout Data) -> AXUIElement? {
            guard let createWithRemoteToken else { return nil }
            if buffer.count != 20 {
                buffer = Data(repeating: 0, count: 20)
                withUnsafeBytes(of: pid.littleEndian) { buffer.replaceSubrange(0..<4, with: $0) }
                withUnsafeBytes(of: UInt32(0x636f636f).littleEndian) { buffer.replaceSubrange(8..<12, with: $0) }
            }
            withUnsafeBytes(of: remoteElementID.littleEndian) { buffer.replaceSubrange(12..<20, with: $0) }
            return createWithRemoteToken(buffer as CFData)?.takeRetainedValue()
        }

        static func focusSpecificWindow(_ windowID: CGWindowID, pid: pid_t) -> Bool {
            guard let getProcessForPID, let setFrontProcessWithOptions else { return false }
            var psn = ProcessSerialNumber()
            guard getProcessForPID(pid, &psn) == noErr else { return false }
            return setFrontProcessWithOptions(&psn, windowID, 0x200) == .success
        }
    }
}
