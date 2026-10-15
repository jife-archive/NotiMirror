import AppKit
import CoreImage
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

/// 원본 배너를 다른 모든 모니터의 같은 자리(우측 상단)에 그대로 그린다.
///
/// macOS 26부터 배너는 뒤 화면을 비춰 색을 내는 유리 효과로 그려져서, 알림 센터 창만 캡처하면 회색이 된다.
/// 그래서 원본 모니터 우측 상단을 두 번 캡처한다.
/// - 화면 캡처: 실제로 보이는 그대로의 색 (배너 뒤 배경까지 포함)
/// - 창 캡처: 알림 센터 창만. 이 알파값을 마스크로 써서 화면 캡처에서 배너 모양만 오려 낸다.
/// 캡처는 배너가 떠 있는 동안 우측 상단 영역에만 걸리고, 프레임은 메모리에서 바로 화면으로만 간다.
@MainActor
final class BannerMirror: NSObject, SCStreamDelegate {
    /// 배너가 쌓이는 우측 상단 영역 (pt)
    nonisolated static let region = CGSize(width: 480, height: 720)

    private var source: NotificationWindowWatcher.SourceWindow?
    private var streams: [SCStream] = []
    private var outputs: [FrameOutput] = []
    private var panels: [MirrorPanel] = []
    /// show/hide가 빠르게 반복될 때 늦게 끝난 비동기 작업과 프레임을 버리기 위한 세대 번호
    private var generation = 0
    private var hasColorFrame = false
    private var hasMaskFrame = false
    private var loggedPanelOpen = false

    // 진단용 (Diagnostics.isEnabled 일 때만 사용)
    private var dumpArmedUntil: Date?
    private var dumpScheduled = false
    private var latestMask: IOSurface?
    private var captureScale: CGFloat = 1
    private var sourceDisplayID: CGDirectDisplayID?
    private var targetDisplayIDs: [CGDirectDisplayID] = []

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
        hasColorFrame = false
        hasMaskFrame = false
        loggedPanelOpen = false
        dumpScheduled = false
        latestMask = nil
        panels.forEach { $0.orderOut(nil) }
        panels = []
        for stream in streams {
            Task { try? await stream.stopCapture() }
        }
        streams = []
        outputs = []
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
        guard let scWindow = content.windows.first(where: { $0.windowID == window.id }),
              let scDisplay = content.displays.first(where: { $0.displayID == sourceScreen?.displayID }) else {
            Log.write("캡처할 알림 센터 창 #\(window.id) 또는 원본 모니터를 찾지 못함")
            return
        }

        // 두 캡처가 같은 영역을 보도록, 창 좌표와 모니터 좌표에서 각각 우측 상단 영역을 계산한다.
        let size = CGSize(width: min(Self.region.width, scWindow.frame.width),
                          height: min(Self.region.height, scWindow.frame.height))
        let windowRect = CGRect(x: scWindow.frame.width - size.width, y: 0, width: size.width, height: size.height)
        let displayRect = windowRect.offsetBy(dx: scWindow.frame.minX - scDisplay.frame.minX,
                                              dy: scWindow.frame.minY - scDisplay.frame.minY)
        // 대상 모니터 중 가장 선명한 배율로 캡처한다 (외장 1080p만 있으면 1배로 충분).
        let scale = targets.map(\.backingScaleFactor).max() ?? 1
        Log.write("캡처 대상 #\(scWindow.windowID) frame=\(scWindow.frame) 원본 모니터=\(scDisplay.displayID) "
                  + "\(scDisplay.frame) 대상=\(targets.map { "\($0.displayID ?? 0)" }) 배율=\(scale)")

        // 캡처를 시작하자마자 첫 프레임이 오는데, 배너가 멈춰 있으면 그 뒤로 새 프레임이 오지 않는다.
        // 그래서 복제 창을 먼저 만들어 두고 첫 프레임부터 받는다 (보여 주는 건 색·모양이 다 온 뒤).
        let sourceMenuBar = sourceScreen.map(Self.menuBarHeight) ?? 0
        panels = targets.map {
            // 메뉴 막대 높이가 다르면 그만큼 올리거나 내려서 배너가 메뉴 막대 아래 같은 거리에 오게 한다.
            MirrorPanel(screen: $0, contentsScale: scale, regionSize: size,
                        verticalShift: sourceMenuBar - Self.menuBarHeight(of: $0))
        }
        captureScale = scale
        sourceDisplayID = scDisplay.displayID
        targetDisplayIDs = targets.compactMap(\.displayID)

        let defaults = UserDefaults.standard
        let maskOutput = FrameOutput(role: .mask, scale: scale, diagnostics: Diagnostics.isEnabled,
                                     maskGain: defaults.object(forKey: "maskGain") as? Double ?? 2.5,
                                     maskBias: defaults.object(forKey: "maskBias") as? Double ?? -0.25) { [weak self] surface, panelOpen in
            Task { @MainActor in self?.present(mask: surface, panelOpen: panelOpen, generation: current) }
        }
        let colorOutput = FrameOutput(role: .color, scale: scale, diagnostics: false) { [weak self] surface, _ in
            Task { @MainActor in self?.present(color: surface, generation: current) }
        }
        let windowStream = SCStream(filter: SCContentFilter(desktopIndependentWindow: scWindow),
                                    configuration: Self.configuration(windowRect, scale: scale), delegate: self)
        let displayStream = SCStream(filter: SCContentFilter(display: scDisplay, excludingWindows: []),
                                     configuration: Self.configuration(displayRect, scale: scale), delegate: self)
        try windowStream.addStreamOutput(maskOutput, type: .screen, sampleHandlerQueue: maskOutput.queue)
        try displayStream.addStreamOutput(colorOutput, type: .screen, sampleHandlerQueue: colorOutput.queue)
        async let windowStarted: Void = windowStream.startCapture()
        async let displayStarted: Void = displayStream.startCapture()
        _ = try await (windowStarted, displayStarted)
        guard current == generation else {
            try? await windowStream.stopCapture()
            try? await displayStream.stopCapture()
            return
        }
        streams = [windowStream, displayStream]
        outputs = [maskOutput, colorOutput]
        Log.write("배너 감지 #\(window.id) → \(targets.count)개 모니터에 복제")
    }

    /// 보조 모니터는 메뉴 막대가 보여도 visibleFrame에서 빠지지 않아 0으로 나올 때가 있다.
    /// 그럴 땐 시스템 메뉴 막대 두께를 쓴다.
    private static func menuBarHeight(of screen: NSScreen) -> CGFloat {
        let height = screen.menuBarHeight
        return height > 0 ? height : NSStatusBar.system.thickness
    }

    private static func configuration(_ rect: CGRect, scale: CGFloat) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = Int(rect.width * scale)
        config.height = Int(rect.height * scale)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.backgroundColor = .clear
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 5
        return config
    }

    private func present(mask: IOSurface, panelOpen: Bool, generation current: Int) {
        guard current == generation else { return }
        if panelOpen {
            // 배너 신호를 못 받는 환경에서 사용자가 알림 센터 패널을 연 경우의 안전장치
            if !loggedPanelOpen {
                loggedPanelOpen = true
                Log.write("알림 센터 패널이 열린 것으로 보여 복제를 숨김")
            }
            panels.forEach { $0.orderOut(nil) }
            return
        }
        panels.forEach { $0.setMask(mask) }
        hasMaskFrame = true
        latestMask = mask
        revealIfReady()
    }

    private func present(color: IOSurface, generation current: Int) {
        guard current == generation else { return }
        panels.forEach { $0.setColor(color) }
        hasColorFrame = true
        revealIfReady()
    }

    /// 색과 모양이 둘 다 도착해야 보여 준다. 하나만 있으면 회색 상자나 빈 화면이 잠깐 비친다.
    private func revealIfReady() {
        guard hasColorFrame && hasMaskFrame, !loggedPanelOpen else { return }
        panels.forEach { $0.reveal() }
        scheduleDiagnosticDumpIfArmed()
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Log.write("캡처 중단: \(error)")
    }

    // MARK: - Diagnostics

    /// 테스트 알림을 보낸 직후 10초 동안 감지된 배너만 저장 대상으로 삼는다.
    func armDiagnosticDump() {
        guard Diagnostics.isEnabled else { return }
        dumpArmedUntil = Date().addingTimeInterval(10)
        Log.write("진단: 다음 배너를 저장하도록 대기")
    }

    private func scheduleDiagnosticDumpIfArmed() {
        guard let until = dumpArmedUntil, until > Date(), !dumpScheduled else { return }
        dumpScheduled = true
        dumpArmedUntil = nil
        let current = generation
        // 배너가 미끄러져 들어오는 애니메이션이 끝난 뒤에 원본과 복제본을 함께 저장한다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, current == self.generation else { return }
                let stamp = Int(Date().timeIntervalSince1970)
                if let mask = self.latestMask {
                    Diagnostics.saveWindowFrame(mask, scale: self.captureScale, name: "\(stamp)-mask.png")
                }
                let source = self.sourceDisplayID
                let target = self.targetDisplayIDs.first
                Task {
                    if let source { await Diagnostics.saveDisplayRegion(displayID: source, name: "\(stamp)-original.png") }
                    if let target { await Diagnostics.saveDisplayRegion(displayID: target, name: "\(stamp)-mirror.png") }
                }
            }
        }
    }
}

/// SCStream이 보내는 프레임에서 IOSurface를 꺼내 넘긴다.
private final class FrameOutput: NSObject, SCStreamOutput {
    enum Role { case color, mask }

    let queue = DispatchQueue(label: "notimirror.frames")
    private let role: Role
    private let scale: CGFloat
    private let diagnostics: Bool
    private let alphaBoost: AlphaBoost?
    private var frameCount = 0
    private let handler: (IOSurface, Bool) -> Void

    init(role: Role, scale: CGFloat, diagnostics: Bool, maskGain: Double = 1, maskBias: Double = 0,
         handler: @escaping (IOSurface, Bool) -> Void) {
        self.role = role
        self.scale = scale
        self.diagnostics = diagnostics
        self.alphaBoost = role == .mask && (maskGain != 1 || maskBias != 0)
            ? AlphaBoost(gain: maskGain, bias: maskBias) : nil
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
        guard role == .mask else {
            handler(surface, false)
            return
        }
        frameCount += 1
        if diagnostics, frameCount % 30 == 1 {
            Log.write("진단: 마스크 프레임 \(frameCount) \(Diagnostics.frameStats(pixelBuffer, scale: scale))")
        }
        handler(alphaBoost?.apply(to: surface) ?? surface, looksLikeOpenPanel(pixelBuffer))
    }

    /// 배너는 영역 위쪽에만 그려진다. 아래쪽까지 불투명하면 알림 센터 패널이 열린 것으로 본다.
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

/// 창 캡처의 반투명한 유리 부분까지 마스크가 꽉 차도록 알파를 키운다 (GPU에서 처리).
/// 알파 = clamp(원래 알파 × gain + bias). 기본값은 그림자처럼 옅은 부분은 그대로 두고 배너 면은 불투명하게 만든다.
private final class AlphaBoost {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let gain: Double
    private let bias: Double
    private var surfaces: [IOSurface] = []
    private var next = 0

    init(gain: Double, bias: Double) {
        self.gain = gain
        self.bias = bias
    }

    func apply(to source: IOSurface) -> IOSurface {
        let width = IOSurfaceGetWidth(source)
        let height = IOSurfaceGetHeight(source)
        if surfaces.first.map({ IOSurfaceGetWidth($0) != width || IOSurfaceGetHeight($0) != height }) ?? true {
            // 화면에 표시 중인 표면에 덮어쓰지 않도록 세 장을 돌려 쓴다.
            surfaces = (0..<3).compactMap { _ in
                IOSurface(properties: [.width: width, .height: height, .bytesPerElement: 4,
                                       .pixelFormat: kCVPixelFormatType_32BGRA])
            }
        }
        guard !surfaces.isEmpty else { return source }
        let target = surfaces[next % surfaces.count]
        next += 1
        let image = CIImage(ioSurface: source).applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: gain),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: bias),
        ])
        context.render(image, to: target, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: nil)
        return target
    }
}

/// 대상 모니터 전체를 덮는 투명·클릭 통과 창. 화면 캡처(색)를 창 캡처(모양)로 오려 우측 상단에 그린다.
private final class MirrorPanel: NSPanel {
    private let colorLayer = CALayer()
    private let maskLayer = CALayer()

    init(screen: NSScreen, contentsScale: CGFloat, regionSize: CGSize, verticalShift: CGFloat) {
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
        let noAnimation: [String: any CAAction] = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        colorLayer.frame = CGRect(x: view.bounds.maxX - regionSize.width,
                                  y: view.bounds.maxY - regionSize.height + verticalShift,
                                  width: regionSize.width, height: regionSize.height)
        maskLayer.frame = colorLayer.bounds
        for layer in [colorLayer, maskLayer] {
            layer.contentsScale = contentsScale
            layer.contentsGravity = .resize
            layer.actions = noAnimation
        }
        colorLayer.mask = maskLayer
        view.layer?.addSublayer(colorLayer)
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setColor(_ surface: IOSurface) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        colorLayer.contents = surface
        CATransaction.commit()
    }

    func setMask(_ surface: IOSurface) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.contents = surface
        CATransaction.commit()
    }

    func reveal() {
        if !isVisible { orderFrontRegardless() }
    }
}
