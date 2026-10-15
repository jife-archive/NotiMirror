import Foundation

/// 알림 센터는 실제 배너를 띄울 때 "Setting visible banner"라는 시스템 로그를 남긴다.
/// 사용자가 알림 센터 패널을 직접 열 때는 이 로그 없이 같은 창만 켜지므로, 둘을 구분하는 신호로 쓴다.
/// 로그 내용(알림 본문)은 macOS가 가려서 기록하므로 읽을 수도 없고 읽지도 않는다.
@MainActor
final class BannerSignal {
    var onBanner: (() -> Void)?
    private(set) var isAvailable = false
    private var lastBannerAt: Date?
    private var process: Process?
    private var buffer = ""
    private var restarts = 0

    private static let marker = "Setting visible banner"

    func firedRecently(within interval: TimeInterval) -> Bool {
        guard let lastBannerAt else { return false }
        return Date().timeIntervalSince(lastBannerAt) < interval
    }

    func start() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--style", "compact", "--predicate",
                             #"process == "NotificationCenter" AND eventMessage BEGINSWITH "\#(Self.marker)""#]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.consume(text) }
            }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleTermination(status: status) }
            }
        }
        do {
            try process.run()
            self.process = process
            isAvailable = true
            Log.write("배너 신호 감시 시작 (log stream)")
        } catch {
            isAvailable = false
            Log.write("배너 신호 감시 실패, 화면 추정으로 대체: \(error)")
        }
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        isAvailable = false
    }

    private func consume(_ text: String) {
        buffer += text
        while let newline = buffer.firstIndex(of: "\n") {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            // 첫 줄 "Filtering the log data using ..."에도 같은 문구가 들어 있어서 프로세스 이름까지 확인한다.
            if line.contains("NotificationCenter[") && line.contains(Self.marker) {
                lastBannerAt = Date()
                onBanner?()
            }
        }
    }

    private func handleTermination(status: Int32) {
        isAvailable = false
        process = nil
        Log.write("배너 신호 감시 종료 (status \(status))")
        // 관리자가 아닌 계정 등에서 바로 끝나면 몇 번만 다시 시도하고, 그 뒤로는 화면 추정만 쓴다.
        guard restarts < 5 else { return }
        restarts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            MainActor.assumeIsolated { self?.start() }
        }
    }
}
