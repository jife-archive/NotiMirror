import AppKit
import CoreGraphics

/// 알림 센터는 배너를 띄울 때만 화면 크기의 투명 창(layer 21)을 화면에 올린다.
/// 그 창이 켜졌는지만 0.2초마다 확인한다. 창 목록 정보만 보고 화면 내용은 보지 않으므로 권한이 필요 없다.
@MainActor
final class NotificationWindowWatcher {
    struct SourceWindow: Equatable {
        let id: CGWindowID
        /// CoreGraphics 전역 좌표 (주 디스플레이 왼쪽 위가 원점)
        let bounds: CGRect
    }

    var onShow: ((SourceWindow) -> Void)?
    var onHide: (() -> Void)?

    private static let bundleID = "com.apple.notificationcenterui"
    private var candidates: [CGWindowID] = []
    private var visible: SourceWindow?
    private var timer: Timer?
    private var rescanCountdown = 0

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if visible != nil {
            visible = nil
            onHide?()
        }
    }

    private func tick() {
        rescanCountdown -= 1
        if candidates.isEmpty || rescanCountdown <= 0 {
            // 알림 센터가 재시작되거나 모니터 구성이 바뀌면 창 ID가 달라질 수 있어 5초마다 다시 찾는다.
            rescanCountdown = 25
            let found = Self.findCandidates()
            if found != candidates { Log.write("알림 센터 창 후보: \(found)") }
            candidates = found
        }
        let current = Self.describe(candidates)
            .first { ($0[kCGWindowIsOnscreen as String] as? Bool) == true }
            .flatMap(Self.sourceWindow)
        guard current != visible else { return }
        visible = current
        if let current { onShow?(current) } else { onHide?() }
    }

    private static func findCandidates() -> [CGWindowID] {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier,
              let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        // 위젯 창은 layer가 음수라서 제외된다.
        return all.filter {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int ?? 0) > 0
        }.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
    }

    /// CGWindowListCreateDescriptionFromArray는 CFNumber가 아니라 창 ID 값을 그대로 담은 CFArray를 받는다.
    private static func describe(_ ids: [CGWindowID]) -> [[String: Any]] {
        guard !ids.isEmpty else { return [] }
        var values = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let array = CFArrayCreate(nil, &values, values.count, nil) else { return [] }
        return CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] ?? []
    }

    private static func sourceWindow(_ description: [String: Any]) -> SourceWindow? {
        guard let id = description[kCGWindowNumber as String] as? CGWindowID,
              let boundsDict = description[kCGWindowBounds as String],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as! CFDictionary) else { return nil }
        return SourceWindow(id: id, bounds: bounds)
    }
}
