import Foundation

/// ~/Library/Logs/NotiMirror.log 에 진단용 로그를 남긴다.
/// 알림 본문은 절대 기록하지 않고, 앱 ID·키 이름·길이 같은 메타데이터만 남긴다.
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/NotiMirror.log")

    private static let queue = DispatchQueue(label: "notimirror.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
