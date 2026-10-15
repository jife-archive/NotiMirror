import AppKit
import CoreImage
import CoreVideo
import ScreenCaptureKit

/// 개발용 진단. `defaults write local.notimirror diagnostics -bool true` 일 때만 동작한다.
/// - 프레임 통계(불투명 영역, 색 평균)를 1초마다 로그에 남긴다. 픽셀 내용은 기록하지 않는다.
/// - 테스트 알림을 보낸 직후 10초 동안만, 원본 화면 우측 상단 일부와 캡처한 창을 PNG로 저장한다.
enum Diagnostics {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "diagnostics") }

    /// 진단 모드에서 터미널로 테스트 알림을 보내는 신호
    static let sendTestNotificationName = Notification.Name("local.notimirror.sendTestNotification")

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/NotiMirror-debug")

    /// 배너가 모이는 우측 상단 영역 (pt)
    static var regionSize: CGSize { BannerMirror.region }

    /// 프레임을 성기게 훑어 불투명 영역과 색 분포를 요약한다.
    static func frameStats(_ buffer: CVPixelBuffer, scale: CGFloat) -> String {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return "no base address" }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let step = max(1, Int(4 * scale))

        var buckets = [0, 0, 0, 0]   // alpha 0 / 1-127 / 128-254 / 255
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        var sumR = 0.0, sumG = 0.0, sumB = 0.0, sumSat = 0.0, opaque = 0.0
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let p = base.advanced(by: y * rowBytes + x * 4).assumingMemoryBound(to: UInt8.self)
                let b = Double(p[0]), g = Double(p[1]), r = Double(p[2]), a = Int(p[3])
                buckets[a == 0 ? 0 : a < 128 ? 1 : a < 255 ? 2 : 3] += 1
                guard a >= 128 else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                // BGRA는 premultiplied라 알파로 나눠 원래 색을 구한다.
                let alpha = Double(a) / 255
                let (rr, gg, bb) = (r / alpha, g / alpha, b / alpha)
                sumR += rr; sumG += gg; sumB += bb
                let maxC = max(rr, gg, bb), minC = min(rr, gg, bb)
                sumSat += maxC > 0 ? (maxC - minC) / maxC : 0
                opaque += 1
            }
        }
        let total = Double(buckets.reduce(0, +))
        let pct = buckets.map { String(format: "%.1f%%", Double($0) / total * 100) }
        guard opaque > 0 else { return "alpha[0,~127,~254,255]=\(pct) 불투명 영역 없음" }
        let bbox = String(format: "x=%.0f..%.0f y=%.0f..%.0f pt (창 %.0fx%.0f)",
                          Double(minX) / scale, Double(maxX) / scale, Double(minY) / scale, Double(maxY) / scale,
                          Double(width) / scale, Double(height) / scale)
        return String(format: "alpha[0,~127,~254,255]=%@ 불투명영역 %@ 평균RGB=(%.0f,%.0f,%.0f) 채도=%.2f",
                      pct.description, bbox, sumR / opaque, sumG / opaque, sumB / opaque, sumSat / opaque)
    }

    /// 캡처한 창 프레임의 우측 상단을 PNG로 저장한다.
    static func saveWindowFrame(_ surface: IOSurface, scale: CGFloat, name: String) {
        let image = CIImage(ioSurface: surface)
        let w = regionSize.width * scale, h = regionSize.height * scale
        // CIImage는 왼쪽 아래가 원점이다.
        let crop = CGRect(x: image.extent.maxX - w, y: image.extent.maxY - h, width: w, height: h)
            .intersection(image.extent)
        guard let cgImage = CIContext().createCGImage(image.cropped(to: crop), from: crop) else { return }
        writePNG(cgImage, name: name)
    }

    /// 원본 모니터의 우측 상단을 실제 화면 그대로(뒤 배경 포함) 저장한다.
    static func saveDisplayRegion(displayID: CGDirectDisplayID, name: String) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }),
                  let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { return }
            let scale = screen.backingScaleFactor
            let config = SCStreamConfiguration()
            config.sourceRect = CGRect(x: CGFloat(display.width) - regionSize.width, y: 0,
                                       width: regionSize.width, height: regionSize.height)
            config.width = Int(regionSize.width * scale)
            config.height = Int(regionSize.height * scale)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config)
            writePNG(image, name: name)
        } catch {
            Log.write("진단: 화면 캡처 실패 \(error)")
        }
    }

    private static func writePNG(_ image: CGImage, name: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        Log.write("진단: 저장 \(url.path) (\(image.width)x\(image.height))")
    }
}
