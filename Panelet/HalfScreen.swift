import AppKit
import CoreMedia
import CoreVideo
import IOSurface
import IOKit
import os
import ScreenCaptureKit

/// One half of a portrait display: a virtual display, plus a borderless window
/// that paints that display onto the matching physical region.
@MainActor
final class HalfScreen: NSObject, SCStreamOutput, SCStreamDelegate {
    private struct Frame {
        let pixels: CVPixelBuffer
        let streamID: ObjectIdentifier
    }

    let name: String
    let physicalID: CGDirectDisplayID
    /// Region inside the physical display, origin at the display's top-left, y down.
    let localRect: CGRect
    let pointSize: CGSize
    let refreshRate: Double
    let virtualID: CGDirectDisplayID
    private let scale: Int

    private let mirrorLayer = CALayer()
    private let captureQueue: DispatchQueue
    private nonisolated let pendingFrame = OSAllocatedUnfairLock<Frame?>(uncheckedState: nil)
    private var display: CGVirtualDisplay?
    private var window: NSWindow?
    private var stream: SCStream?
    private var displayedStream: ObjectIdentifier?
    private var tornDown = false
    var onFailure: ((Error) -> Void)?

    var hasFrame: Bool { stream.map { ObjectIdentifier($0) == displayedStream } ?? false }

    var virtualBounds: CGRect { CGDisplayBounds(virtualID) }

    var physicalRect: CGRect {
        let bounds = CGDisplayBounds(physicalID)
        return CGRect(
            x: bounds.minX + localRect.minX,
            y: bounds.minY + localRect.minY,
            width: localRect.width,
            height: localRect.height
        )
    }

    private init(
        name: String,
        physicalID: CGDirectDisplayID,
        localRect: CGRect,
        refreshRate: Double,
        scale: Int,
        display: CGVirtualDisplay
    ) {
        self.name = name
        self.physicalID = physicalID
        self.localRect = localRect
        self.pointSize = localRect.size
        self.refreshRate = refreshRate
        self.scale = scale
        self.display = display
        self.virtualID = display.displayID
        self.captureQueue = DispatchQueue(label: "dev.cmkk.vertical-split.capture.\(name)")
        super.init()
        mirrorLayer.actions = ["contents": NSNull()]
    }

    static func make(
        name: String,
        screen: PhysicalScreen,
        localRect: CGRect,
        role: String
    ) throws -> HalfScreen {
        let pointSize = localRect.size
        let refresh = screen.refreshRate > 1 ? screen.refreshRate : 60
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue.main
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32((pointSize.width * 2).rounded())
        descriptor.maxPixelsHigh = UInt32((pointSize.height * 2).rounded())
        descriptor.sizeInMillimeters = millimeters(for: screen, localRect: localRect)
        descriptor.vendorID = DemoDisplay.vendorID
        let product = UInt32((Int(pointSize.width.rounded()) * 31 + Int(pointSize.height.rounded())) & 0xFFFF)
        descriptor.productID = product == 0 ? 1 : product
        let identity = CGDisplayCreateUUIDFromDisplayID(screen.id)
            .map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? String(screen.id)
        descriptor.serialNum = stableSerial("\(identity)-\(role)")
        descriptor.terminationHandler = { _, _ in }
        CGVirtualDisplayDescriptorApplyStandardPrimaries(descriptor)

        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            throw DemoError("创建“\(name)”失败。CGVirtualDisplay 返回了空对象。确认这个程序是 .app、没有打开 App Sandbox，并且不是从裸二进制直接跑的。")
        }
        guard display.displayID != 0 else {
            throw DemoError("创建“\(name)”失败。虚拟显示器没有拿到 displayID。")
        }

        let half = HalfScreen(
            name: name,
            physicalID: screen.id,
            localRect: localRect,
            refreshRate: refresh,
            scale: screen.scale >= 1.5 ? 2 : 1,
            display: display
        )
        try half.applyInitialMode(to: display)
        DemoDisplay.createdIDs.insert(display.displayID)
        DemoLog.shared.line("\(name) 已创建，displayID=\(display.displayID)，点尺寸 \(Int(pointSize.width.rounded()))×\(Int(pointSize.height.rounded()))")
        return half
    }

    func selectMode() throws {
        guard !hasExpectedMode else { return }
        let result = CGDisplaySetDisplayMode(virtualID, try preferredMode(), nil)
        guard result == .success, hasExpectedMode else {
            throw DemoError("\(name) 未能切换到 \(scale)× 模式（CGError \(result.rawValue)）。")
        }
    }

    func preferredMode() throws -> CGDisplayMode {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        let modes = CGDisplayCopyAllDisplayModes(virtualID, options) as? [CGDisplayMode] ?? []
        guard let match = modes.first(where: matches) else {
            throw DemoError("\(name) 没有可用的 \(Int(pointSize.width))×\(Int(pointSize.height)) @\(scale)× 模式。")
        }
        return match
    }

    var hasExpectedMode: Bool {
        CGDisplayCopyDisplayMode(virtualID).map(matches) ?? false
    }

    var hasUnexpectedMode: Bool {
        CGDisplayCopyDisplayMode(virtualID).map { !matches($0) } ?? false
    }

    func placeWindow() throws {
        guard hasFrame else { throw DemoError("\(name) 还没有画面。") }
        let frame = cocoaRect(physicalRect)
        let mirror = MirrorWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        mirror.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        mirror.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        mirror.ignoresMouseEvents = true
        mirror.isOpaque = true
        mirror.hasShadow = false
        mirror.backgroundColor = .black
        mirror.isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        mirror.contentView = content
        guard let host = content.layer else { throw DemoError("\(name) 无法建立画面窗口。") }
        mirrorLayer.frame = content.bounds
        mirrorLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        mirrorLayer.contentsGravity = .resize
        mirrorLayer.contentsScale = CGFloat(scale)
        host.addSublayer(mirrorLayer)
        window = mirror
        try updateWindowPosition()
        mirror.orderFrontRegardless()
    }

    func updateWindowPosition() throws {
        guard let mirror = window else { return }
        let frame = cocoaRect(physicalRect)
        if mirror.frame != frame { mirror.setFrame(frame, display: true) }
        guard mirror.screen?.displayID == physicalID, mirror.frame == frame else {
            throw DemoError("\(name) 的画面窗口无法定位到竖屏。")
        }
    }

    func startCapture(on scDisplay: SCDisplay) async throws {
        try Task.checkCancellation()
        guard !hasUnexpectedMode, virtualBounds.size == pointSize else {
            throw DemoError("\(name) 的显示模式在采集前发生变化。")
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(pointSize.width) * scale
        configuration.height = Int(pointSize.height) * scale
        let modeRate = CGDisplayCopyDisplayMode(virtualID)?.refreshRate ?? 0
        let rate = modeRate > 1 ? modeRate : refreshRate
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(rate.rounded()))
        configuration.showsCursor = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let stream = SCStream(
            filter: SCContentFilter(display: scDisplay, excludingWindows: []),
            configuration: configuration,
            delegate: self
        )
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        displayedStream = nil
        self.stream = stream
        try await stream.startCapture()
        if tornDown || Task.isCancelled {
            try? await stream.stopCapture()
            throw CancellationError()
        }
        guard self.stream === stream else { throw DemoError("\(name) 的采集流在启动时中断。") }
    }

    func recoverCapture() async throws {
        let activeStream = stream
        stream = nil
        if let activeStream { try? await activeStream.stopCapture() }
        let displays = try await Self.waitForDisplays(ids: [virtualID])
        guard !tornDown, let display = displays.first else { throw CancellationError() }
        try await startCapture(on: display)
        for _ in 0..<16 {
            try Task.checkCancellation()
            if hasFrame { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw DemoError("重新连接后没有收到画面。")
    }

    func hideWindow() {
        window?.orderOut(nil)
        window = nil
    }

    func park() {
        onFailure = nil
        hideWindow()
        let activeStream = stream
        stream = nil
        activeStream?.stopCapture { _ in }
        pendingFrame.withLockUnchecked { $0 = nil }
        mirrorLayer.contents = nil
    }

    func teardown() {
        tornDown = true
        park()
        display = nil
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let streamID = ObjectIdentifier(stream)
        DispatchQueue.main.async { [weak self] in
            guard let self, let stream = self.stream, ObjectIdentifier(stream) == streamID, !self.tornDown else { return }
            self.stream = nil
            self.onFailure?(error)
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, Self.isUsefulFrame(sampleBuffer), let pixels = sampleBuffer.imageBuffer else { return }
        let frame = Frame(pixels: pixels, streamID: ObjectIdentifier(stream))
        // Keep one pending frame, replacing it when the main thread has not displayed it yet.
        let previous = pendingFrame.withLockUnchecked { pending in
            let previous = pending
            pending = frame
            return previous
        }
        guard previous == nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.displayPendingFrame()
        }
    }

    private func displayPendingFrame() {
        let frame = pendingFrame.withLockUnchecked { pending in
            let frame = pending
            pending = nil
            return frame
        }
        guard let frame, let stream, ObjectIdentifier(stream) == frame.streamID, !tornDown,
              let surface = Self.surface(from: frame.pixels) else { return }
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        guard width == Int(pointSize.width) * scale, height == Int(pointSize.height) * scale else { return }
        if !hasFrame {
            DemoLog.shared.line("\(name) 已收到 \(width)×\(height) 像素首帧（\(scale)×）。")
        }
        withExtendedLifetime(frame.pixels) { mirrorLayer.contents = surface }
        displayedStream = frame.streamID
    }

    private func applyInitialMode(to display: CGVirtualDisplay) throws {
        for rate in refreshRate == 60 ? [60] : [refreshRate, 60] {
            let settings = CGVirtualDisplaySettings()
            settings.hiDPI = scale == 2 ? 1 : 0
            settings.modes = [
                CGVirtualDisplayMode(
                    width: UInt32(pointSize.width.rounded()),
                    height: UInt32(pointSize.height.rounded()),
                    refreshRate: rate
                )
            ]
            if display.applySettings(settings) { return }
        }
        throw DemoError("\(name) 的分辨率被系统拒绝（\(Int(pointSize.width.rounded()))×\(Int(pointSize.height.rounded()))）。")
    }

    private func matches(_ mode: CGDisplayMode) -> Bool {
        mode.width == Int(pointSize.width) && mode.height == Int(pointSize.height)
            && mode.pixelWidth == mode.width * scale && mode.pixelHeight == mode.height * scale
    }

    nonisolated static func waitForDisplays(ids: [CGDirectDisplayID]) async throws -> [SCDisplay] {
        var lastError: Error?
        for _ in 0..<40 {
            try Task.checkCancellation()
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let displays = ids.compactMap { id in
                    content.displays.first { $0.displayID == id }
                }
                if displays.count == ids.count {
                    return displays
                }
            } catch {
                lastError = error
                if (error as NSError).code == SCStreamError.userDeclined.rawValue {
                    throw DemoError("屏幕录制权限被拒绝。到系统设置里打开本 App 后，点“重新启动”。")
                }
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        if let lastError {
            throw DemoError("无法读取两个半屏的画面：\(lastError.localizedDescription)")
        }
        throw DemoError("系统超过 8 秒还没有提供两个半屏的画面。")
    }

    nonisolated private static func isUsefulFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else {
            return false
        }
        return status == .complete || status == .started
    }

    nonisolated private static func surface(from pixelBuffer: CVPixelBuffer) -> IOSurface? {
        guard let unmanaged = CVPixelBufferGetIOSurface(pixelBuffer) else { return nil }
        return unmanaged.takeUnretainedValue() as IOSurface
    }

    private static func millimeters(for screen: PhysicalScreen, localRect: CGRect) -> CGSize {
        let full = CGDisplayScreenSize(screen.id)
        let width = full.width * (localRect.width / max(screen.bounds.width, 1))
        let height = full.height * (localRect.height / max(screen.bounds.height, 1))
        if width > 1, height > 1 {
            return CGSize(width: width, height: height)
        }
        return CGSize(width: localRect.width / 96 * 25.4, height: localRect.height / 96 * 25.4)
    }
}

/// Borderless overlay. It must not become key, or it steals the keyboard from the control window.
final class MirrorWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
