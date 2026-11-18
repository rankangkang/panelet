import AppKit
import CoreMedia
import CoreVideo
import IOSurface
import IOKit
import os
import ScreenCaptureKit

/// One region of a physical display: a virtual display, plus a borderless window
/// that paints that display onto the matching physical region.
@MainActor
final class HalfScreen: NSObject, SCStreamOutput, SCStreamDelegate {
    private struct Frame {
        let pixels: CVPixelBuffer
        let streamID: ObjectIdentifier
        let receivedAt: TimeInterval
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
    private struct Measurements { var received = 0; var replaced = 0; var presented = 0; var maxQueueDelay = 0.0 }
    private nonisolated let measurements = OSAllocatedUnfairLock(initialState: Measurements())
    var statistics: String {
        let value = measurements.withLock { $0 }
        return L("采集 %@ 帧，呈现 %@ 帧，合并待显示帧 %@；最长提交排队 %@ ms。此值不是端到端延迟或显示器实测帧率。", String(describing: value.received), String(describing: value.presented), String(describing: value.replaced), String(describing: String(format: "%.1f", value.maxQueueDelay * 1000)))
    }
    func matchesConfiguration(_ screen: PhysicalScreen) -> Bool {
        scale == screen.configuration.rendering.scale(native: screen.scale)
            && refreshRate == screen.configuration.rendering.frameRate(native: screen.refreshRate)
    }
    private let captureQueue: DispatchQueue
    private nonisolated let pendingFrame = OSAllocatedUnfairLock<Frame?>(uncheckedState: nil)
    private var display: CGVirtualDisplay?
    private var window: NSWindow?
    private var numberView: NSView?
    private var numberTask: Task<Void, Never>?
    private var stream: SCStream?
    private var streamFilter: (display: SCDisplay, excludedShields: Set<CGWindowID>)?
    private var displayedStream: ObjectIdentifier?
    private var tornDown = false
    var onFailure: ((Error) -> Void)?
    var onFrame: (() -> Void)?

    var hasFrame: Bool { stream.map { ObjectIdentifier($0) == displayedStream } ?? false }

    var mirrorWindowID: CGWindowID? {
        guard let window, window.windowNumber > 0 else { return nil }
        return CGWindowID(window.windowNumber)
    }

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
        if let problem = EnvironmentCheck.inspect().problem { throw DemoError(problem) }
        let pointSize = localRect.size
        let refresh = screen.configuration.rendering.frameRate(native: screen.refreshRate)
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
            throw DemoError(L("系统未能创建“%@”。请在设置的“诊断”页检查环境并复制日志。", String(describing: name)))
        }
        guard display.displayID != 0 else {
            throw DemoError(L("系统未能启用“%@”。请重试；若仍失败，请复制诊断日志。", String(describing: name)))
        }

        let half = HalfScreen(
            name: name,
            physicalID: screen.id,
            localRect: localRect,
            refreshRate: refresh,
            scale: screen.configuration.rendering.scale(native: screen.scale),
            display: display
        )
        try half.applyInitialMode(to: display)
        DemoDisplay.createdIDs.insert(display.displayID)
        DemoLog.shared.line(L("%@ 已创建，displayID=%@，点尺寸 %@×%@", String(describing: name), String(describing: display.displayID), String(describing: Int(pointSize.width.rounded())), String(describing: Int(pointSize.height.rounded()))))
        return half
    }

    func selectMode() throws {
        guard !hasExpectedMode else { return }
        let result = CGDisplaySetDisplayMode(virtualID, try preferredMode(), nil)
        guard result == .success, hasExpectedMode else {
            throw DemoError(L("%@ 未能切换到 %@× 模式（CGError %@）。", String(describing: name), String(describing: scale), String(describing: result.rawValue)))
        }
    }

    func preferredMode() throws -> CGDisplayMode {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        let modes = CGDisplayCopyAllDisplayModes(virtualID, options) as? [CGDisplayMode] ?? []
        guard let match = modes.first(where: matches) else {
            throw DemoError(L("%@ 没有可用的 %@×%@ @%@× 模式。", String(describing: name), String(describing: Int(pointSize.width)), String(describing: Int(pointSize.height)), String(describing: scale)))
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
        guard hasFrame else { throw DemoError(L("%@ 还没有画面。", String(describing: name))) }
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
        guard let host = content.layer else { throw DemoError(L("%@ 无法建立画面窗口。", String(describing: name))) }
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
            throw DemoError(L("%@ 的画面窗口无法定位到显示器。", String(describing: name)))
        }
    }

    func startCapture(on scDisplay: SCDisplay) async throws {
        try Task.checkCancellation()
        guard !hasUnexpectedMode, virtualBounds.size == pointSize else {
            throw DemoError(L("%@ 的显示模式在采集前发生变化。", String(describing: name)))
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(pointSize.width) * scale
        configuration.height = Int(pointSize.height) * scale
        let modeRate = CGDisplayCopyDisplayMode(virtualID)?.refreshRate ?? 0
        let rate = modeRate > 1 ? modeRate : refreshRate
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(rate.rounded()))
        configuration.capturesAudio = false
        configuration.showsCursor = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let stream = SCStream(
            filter: SCContentFilter(display: scDisplay, excludingWindows: []),
            configuration: configuration,
            delegate: self
        )
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        displayedStream = nil
        streamFilter = nil
        self.stream = stream
        try await stream.startCapture()
        if tornDown || Task.isCancelled {
            try? await stream.stopCapture()
            throw CancellationError()
        }
        guard self.stream === stream else { throw DemoError(L("%@ 的采集流在启动时中断。", String(describing: name))) }
        streamFilter = (scDisplay, [])
    }

    func needsShieldUpdate(_ ids: Set<CGWindowID>) -> Bool {
        guard stream != nil, let streamFilter else { return false }
        return streamFilter.excludedShields != ids
    }

    func updateShieldExclusions(_ windows: [SCWindow]) async {
        let ids = Set(windows.map(\.windowID))
        guard let stream, let streamFilter, streamFilter.excludedShields != ids else { return }
        let filter = SCContentFilter(display: streamFilter.display, excludingWindows: windows)
        // A shield can close during the filter update. Reconcile on the next scan.
        guard (try? await stream.updateContentFilter(filter)) != nil, self.stream === stream else { return }
        self.streamFilter?.excludedShields = ids
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
        throw DemoError(L("重新连接后没有收到画面。"))
    }

    func showNumber(_ number: String) {
        numberTask?.cancel()
        numberView?.removeFromSuperview()
        guard let content = window?.contentView else { return }
        let badge = NSTextField(labelWithString: "\(number)\n\(name)")
        badge.alignment = .center
        let text = NSMutableAttributedString(string: "\(number)\n", attributes: [.font: NSFont.systemFont(ofSize: 72, weight: .bold)])
        text.append(NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 16, weight: .medium)]))
        badge.attributedStringValue = text
        badge.textColor = .white
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        badge.layer?.cornerRadius = 18
        badge.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            badge.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, multiplier: 0.9)
        ])
        numberView = badge
        numberTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            self?.numberView?.removeFromSuperview()
            self?.numberView = nil
        }
    }

    func hideWindow() {
        numberTask?.cancel()
        numberView?.removeFromSuperview()
        numberView = nil
        window?.orderOut(nil)
        window = nil
    }

    func park() {
        onFailure = nil
        onFrame = nil
        hideWindow()
        let activeStream = stream
        stream = nil
        streamFilter = nil
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
        guard type == .screen, let pixels = sampleBuffer.imageBuffer, Self.isUsefulFrame(sampleBuffer) else { return }
        let frame = Frame(pixels: pixels, streamID: ObjectIdentifier(stream), receivedAt: ProcessInfo.processInfo.systemUptime)
        // Keep one pending frame, replacing it when the main thread has not displayed it yet.
        let previous = pendingFrame.withLockUnchecked { pending in
            let previous = pending
            pending = frame
            return previous
        }
        measurements.withLock { $0.received += 1; if previous != nil { $0.replaced += 1 } }
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
            DemoLog.shared.line(L("%@ 已收到 %@×%@ 像素首帧（%@×）。", String(describing: name), String(describing: width), String(describing: height), String(describing: scale)))
        }
        measurements.withLock {
            $0.presented += 1
            $0.maxQueueDelay = max($0.maxQueueDelay, ProcessInfo.processInfo.systemUptime - frame.receivedAt)
        }
        withExtendedLifetime(frame.pixels) { mirrorLayer.contents = surface }
        displayedStream = frame.streamID
        onFrame?()
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
        throw DemoError(L("%@ 的分辨率被系统拒绝（%@×%@）。", String(describing: name), String(describing: Int(pointSize.width.rounded())), String(describing: Int(pointSize.height.rounded()))))
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
                    throw DemoError(L("屏幕录制权限被拒绝。到系统设置里打开本 App 后，点“重新启动”。"))
                }
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        if let lastError {
            throw DemoError(L("无法读取两个半屏的画面：%@", String(describing: lastError.localizedDescription)))
        }
        throw DemoError(L("系统超过 8 秒还没有提供两个半屏的画面。"))
    }

    nonisolated private static func isUsefulFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as NSArray?
        guard let frameInfo = attachments?.firstObject as? NSDictionary,
              let raw = frameInfo[SCStreamFrameInfo.status.rawValue] as? Int,
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
