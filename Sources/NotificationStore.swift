import Foundation
import SQLite3

struct NotificationRecord {
    let recordID: Int64
    let bundleID: String
    let title: String
    let subtitle: String
    let body: String
}

struct StoreError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// usernoted가 알림마다 한 줄씩 쌓는 SQLite DB를 읽기 전용으로 감시한다.
/// macOS 15부터 이 경로는 TCC로 보호되므로 앱에 전체 디스크 접근 권한이 있어야 열린다.
final class NotificationStore {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")

    private struct Row {
        let recordID: Int64
        let bundleID: String?
        let data: Data
        let presented: Int?
        let style: Int?
        let delivered: Double?
        let key: String
    }

    private struct Payload {
        let app: String?
        let title: String
        let subtitle: String
        let body: String
        let keys: [String]
        let requestKeys: [String]
    }

    private var db: OpaquePointer?
    private var columns: Set<String> = []
    private var hasAppTable = false
    // rec_id는 마지막 행이 지워지면 재사용될 수 있어서, id 대신 (id, uuid, 전달 시각) 조합으로 본 행을 기억한다.
    private var seen: Set<String> = []

    private(set) var schemaSummary = ""
    var isOpen: Bool { db != nil }

    func open() throws {
        close()
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(Self.url.path, &handle, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            sqlite3_close(handle)
            throw StoreError("DB 열기 실패 (\(rc)): \(message)")
        }
        db = handle
        sqlite3_busy_timeout(handle, 250)
        do {
            try loadSchema()
            // 실행 전부터 있던 알림은 다시 띄우지 않는다.
            seen = Set(try fetchRows(limit: nil).map(\.key))
        } catch {
            close()
            throw error
        }
    }

    func close() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    func fetchNew() throws -> [NotificationRecord] {
        var result: [NotificationRecord] = []
        for row in try fetchRows(limit: 50).reversed() where !seen.contains(row.key) {
            seen.insert(row.key)
            let age = row.delivered.map { String(format: "%.1f", Date().timeIntervalSinceReferenceDate - $0) } ?? "-"
            guard let payload = Self.parse(row.data) else {
                let magic = String(decoding: row.data.prefix(8), as: UTF8.self)
                Log.write("rec \(row.recordID) app=\(row.bundleID ?? "?") 파싱 실패 bytes=\(row.data.count) magic=\(magic)")
                continue
            }
            let bundleID = Self.normalize(row.bundleID ?? payload.app ?? "")
            Log.write("rec \(row.recordID) app=\(bundleID) presented=\(row.presented.map(String.init) ?? "-") style=\(row.style.map(String.init) ?? "-") age=\(age)s keys=\(payload.keys) req=\(payload.requestKeys) len=\(payload.title.count)/\(payload.subtitle.count)/\(payload.body.count)")
            guard !(payload.title.isEmpty && payload.subtitle.isEmpty && payload.body.isEmpty) else { continue }
            result.append(NotificationRecord(recordID: row.recordID, bundleID: bundleID,
                                             title: payload.title, subtitle: payload.subtitle, body: payload.body))
        }
        if seen.count > 20_000 {
            seen = Set(try fetchRows(limit: nil).map(\.key))
        }
        return result
    }

    // MARK: - SQLite

    private func loadSchema() throws {
        let tables = try strings("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        guard tables.contains("record") else {
            throw StoreError("record 테이블이 없음 (tables=\(tables))")
        }
        columns = Set(try strings("SELECT name FROM pragma_table_info('record')"))
        hasAppTable = try tables.contains("app")
            && strings("SELECT name FROM pragma_table_info('app')").contains("identifier")
        schemaSummary = "tables=\(tables) record=\(columns.sorted())"
    }

    private func fetchRows(limit: Int?) throws -> [Row] {
        func column(_ name: String) -> String { columns.contains(name) ? "r.\(name)" : "NULL" }
        let app = hasAppTable && columns.contains("app_id")
            ? "(SELECT a.identifier FROM app a WHERE a.app_id = r.app_id)" : "NULL"
        var sql = """
            SELECT r.rec_id, \(app), r.data, \(column("presented")), \(column("style")), \
            \(column("uuid")), \(column("delivered_date"))
            FROM record r ORDER BY r.rec_id DESC
            """
        if let limit { sql += " LIMIT \(limit)" }

        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw StoreError("조회 실패 (\(rc)): \(lastError)") }
            let recordID = sqlite3_column_int64(stmt, 0)
            let uuid = blob(stmt, 5).map { String(format: "%02x", $0) }.joined()
            let delivered = double(stmt, 6)
            rows.append(Row(recordID: recordID,
                            bundleID: text(stmt, 1),
                            data: blob(stmt, 2),
                            presented: int(stmt, 3),
                            style: int(stmt, 4),
                            delivered: delivered,
                            key: "\(recordID)|\(uuid)|\(delivered ?? 0)"))
        }
        return rows
    }

    private func strings(_ sql: String) throws -> [String] {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var values: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let value = text(stmt, 0) { values.append(value) }
        }
        return values
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let db else { throw StoreError("DB가 열려 있지 않음") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError("쿼리 준비 실패: \(lastError)")
        }
        return stmt
    }

    private var lastError: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "no db"
    }

    private func text(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: pointer)
    }

    private func blob(_ stmt: OpaquePointer, _ index: Int32) -> Data {
        guard let pointer = sqlite3_column_blob(stmt, index) else { return Data() }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(stmt, index)))
    }

    private func int(_ stmt: OpaquePointer, _ index: Int32) -> Int? {
        sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, index))
    }

    private func double(_ stmt: OpaquePointer, _ index: Int32) -> Double? {
        sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, index)
    }

    // MARK: - Payload

    /// data 컬럼은 binary plist: { app, req: { titl, subt, body, ... }, date, ... }
    private static func parse(_ data: Data) -> Payload? {
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            return nil
        }
        let request = plist["req"] as? [String: Any] ?? [:]
        func field(_ key: String) -> String {
            (request[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return Payload(app: plist["app"] as? String,
                       title: field("titl"),
                       subtitle: field("subt"),
                       body: field("body"),
                       keys: plist.keys.sorted(),
                       requestKeys: request.keys.sorted())
    }

    /// "_SYSTEM_CENTER_:com.apple.xxx" 같은 접두어를 떼어 번들 ID만 남긴다.
    private static func normalize(_ identifier: String) -> String {
        identifier.split(separator: ":").last.map(String.init) ?? identifier
    }
}
