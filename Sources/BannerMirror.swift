import AppKit
import CoreMedia
import CoreVideo
import QuartzCore
import ScreenCaptureKit

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    var menuBarHeight: CGFloat { frame.maxY - visibleFrame.maxY }
}

/// 알림 센터 창을 ScreenCaptureKit으로 캡처해서, 원본이 없는 모든 모니터의 같은 자리(우측 상단)에 그대로 그린다.
/// 캡처는 배너가 떠 있는 동안 그 창 하나에만 걸리고, 프레임은 메모리에서 바로 화면으로만 간다.
@MainActor
final class BannerMirror: NSObject, SCStreamDelegate {
    private var source: NotificationWindowWatcher.SourceWindow?
    private var stream: SCStream?
    private var output: FrameOutput?
    private var panels: [MirrorPanel] = []
    /// show/hide가 빠르게 반복될 때 늦게 끝난 비동기 작업과 프레임을 버리기 위한 세대 번호
    private var generation = 0
    private var loggedPanelOpen = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let source = self.source else { return }
                self.show(source)
            }
        }
    }

    func show(_ window: NotificationWindowWatcher.SourceWindow) {
        hide()
        source = window
        let current = generation
        Task { @MainActor in
            do {
                try await self.startCapture(window, generation: current)
            } catch {
                Log.write("캡처 시작 실패: \(error)")
            }
        }
    }

    func hide() {
        generation += 1
        source = nil
        loggedPanelOpen = false
        panels.forEach { $0.orderOut(nil) }
        panels = []
        if let stream {
            Task { try? await stream.stopCapture() }
        }
        stream = nil
        output = nil
    }

    // MARK: - Capture

    private func startCapture(_ window: NotificationWindowWatcher.SourceWindow, generation current: Int) async throws {
        let sourceScreen = NSScreen.screens.first {
            guard let id = $0.displayID else { return false }
            return CGDisplayBounds(id).contains(CGPoint(x: window.bounds.midX, y: window.bounds.midY))
        }
        // 원본이 뜬 화면은 항상 제외한다. 맥북만 쓸 때는 복제할 곳이 없다.
        let targets = NSScreen.screens.filter { $0 !== sourceScreen }
        guard !targets.isEmpty else {
            Log.write("배너 감지 #\(window.id) → 복제할 다른 모니터가 없음")
            return
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard current == generation else { return }
        guard let scWindow = content.windows.first(where: { $0.windowID == window.id }) else {
            Log.write("캡처할 알림 센터 창 #\(window.id)을 찾지 못함")
            return
        }

        // 대상 모니터 중 가장 선명한 배율로 캡처한다 (외장 1080p만 있으면 1배로 충분).
        let scale = targets.map(\.backingScaleFactor).max() ?? 1
        let config = SCStreamConfiguration()
        config.width = Int(scWindow.frame.width * scale)
        config.height = Int(scWindow.frame.height * scale)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.backgroundColor = .clear
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 4

        let output = FrameOutput(scale: scale) { [weak self] surface, panelOpen in
            Task { @MainActor in self?.present(surface, panelOpen: panelOpen, generation: current) }
        }
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: scWindow),
                              configuration: config, delegate: self)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        try await stream.startCapture()
        guard current == generation else {
            try? await stream.stopCapture()
            return
        }
        self.stream = stream
        self.output = output

        let sourceMenuBar = sourceScreen?.menuBarHeight ?? 0
        panels = targets.map {
            // 메뉴 막대 높이가 다르면 그만큼 올리거나 내려서 배너가 메뉴 막대 바로 아래에 붙게 한다.
            MirrorPanel(screen: $0, contentsScale: scale, verticalShift: sourceMenuBar - $0.menuBarHeight)
        }
        Log.write("배너 감지 #\(window.id) → \(targets.count)개 모니터에 복제 (배율 \(scale))")
    }

    private func present(_ surface: IOSurface, panelOpen: Bool, generation current: Int) {
        guard current == generation else { return }
        if panelOpen {
            // 사용자가 알림 센터 패널을 직접 연 경우에는 복제하지 않는다.
            if !loggedPanelOpen {
                loggedPanelOpen = true
                Log.write("알림 센터 패널이 열린 것으로 보여 복제를 숨김")
            }
            panels.forEach { $0.orderOut(nil) }
            return
        }
        panels.forEach { $0.show(surface) }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Log.write("캡처 중단: \(error)")
    }
}

/// SCStream이 보내는 프레임에서 IOSurface를 꺼내 넘긴다.
private final class FrameOutput: NSObject, SCStreamOutput {
    let queue = DispatchQueue(label: "notimirror.frames")
    private let scale: CGFloat
    private let handler: (IOSurface, Bool) -> Void

    init(scale: CGFloat, handler: @escaping (IOSurface, Bool) -> Void) {
        self.scale = scale
        self.handler = handler
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        handler(surface, looksLikeOpenPanel(pixelBuffer))
    }

    /// 배너는 화면 위쪽에만 그려진다. 오른쪽 열의 아래쪽까지 불투명하면 알림 센터 패널이 열린 것으로 본다.
    private func looksLikeOpenPanel(_ buffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let x = max(0, width - Int(194 * scale))
        let opaque = [0.6, 0.7, 0.8, 0.9].filter { fraction in
            let y = min(height - 1, Int(Double(height) * fraction))
            let alpha = base.load(fromByteOffset: y * rowBytes + x * 4 + 3, as: UInt8.self)
            return alpha > 160
        }
        return opaque.count >= 2
    }
}

/// 대상 모니터 전체를 덮는 투명·클릭 통과 창. 캡처한 프레임을 우측 상단에 원본 크기 그대로 그린다.
private final class MirrorPanel: NSPanel {
    private let imageLayer = CALayer()
    private let contentsScaleFactor: CGFloat
    private let verticalShift: CGFloat

    init(screen: NSScreen, contentsScale: CGFloat, verticalShift: CGFloat) {
        self.contentsScaleFactor = contentsScale
        self.verticalShift = verticalShift
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        setFrame(screen.frame, display: false)

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        imageLayer.contentsScale = contentsScale
        imageLayer.contentsGravity = .resize
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        view.layer?.addSublayer(imageLayer)
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(_ surface: IOSurface) {
        guard let bounds = contentView?.bounds else { return }
        let size = CGSize(width: CGFloat(IOSurfaceGetWidth(surface)) / contentsScaleFactor,
                          height: CGFloat(IOSurfaceGetHeight(surface)) / contentsScaleFactor)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = CGRect(x: bounds.maxX - size.width, y: bounds.maxY - size.height + verticalShift,
                                  width: size.width, height: size.height)
        imageLayer.contents = surface
        CATransaction.commit()
        if !isVisible { orderFrontRegardless() }
    }
}
