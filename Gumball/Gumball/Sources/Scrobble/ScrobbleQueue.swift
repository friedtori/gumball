import Foundation
import SQLite3
import os

/// Minimal SQLite-backed queue for scrobble candidates.
///
/// No GRDB yet; this is intentionally tiny and self-contained.
actor ScrobbleQueue {
    struct Row: Sendable, Identifiable {
        var id: Int64
        var status: String
        var artist: String
        var track: String
        var album: String?
        var duration: Double?
        var startedAt: Date
        var playedSeconds: Double
        var attempts: Int
        var lastError: String?
        var createdAt: Date
    }

    private let log = Logger(subsystem: "com.gumball.Gumball", category: "ScrobbleQueue")
    private var db: OpaquePointer?

    init() async throws {
        let url = try Self.defaultDatabaseURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try open(url: url)
        try migrate()
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func enqueue(_ candidate: ScrobbleStateMachine.ScrobbleCandidate) throws -> Int64 {
        let sql = """
        INSERT INTO scrobble_queue
        (artist, track, album, duration, started_at, played_seconds, attempts, last_error, created_at)
        VALUES (?, ?, ?, ?, ?, ?, 0, NULL, ?);
        """
        guard let db else { throw DBError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.sqlite(message: lastError(db))
        }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, index: 1, candidate.artist)
        bindText(stmt, index: 2, candidate.track)
        bindOptionalText(stmt, index: 3, candidate.album)
        bindOptionalDouble(stmt, index: 4, candidate.duration)
        bindDouble(stmt, index: 5, candidate.startedAt.timeIntervalSince1970)
        bindDouble(stmt, index: 6, candidate.playedSeconds)
        bindDouble(stmt, index: 7, Date().timeIntervalSince1970)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DBError.sqlite(message: lastError(db))
        }

        let id = sqlite3_last_insert_rowid(db)
        log.info("Enqueued scrobble id=\(id, privacy: .public) \(candidate.artist, privacy: .public) — \(candidate.track, privacy: .public)")
        return id
    }

    func fetchPending(limit: Int = 50) throws -> [Row] {
        let sql = """
        SELECT id, artist, track, album, duration, started_at, played_seconds, attempts, last_error, created_at
        FROM scrobble_queue
        WHERE status = 'pending'
        ORDER BY id ASC
        LIMIT ?;
        """
        guard let db else { throw DBError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.sqlite(message: lastError(db))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(limit))

        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let artist = columnText(stmt, 1) ?? ""
            let track = columnText(stmt, 2) ?? ""
            let album = columnText(stmt, 3)
            let duration = columnDouble(stmt, 4)
            let startedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
            let playedSeconds = sqlite3_column_double(stmt, 6)
            let attempts = Int(sqlite3_column_int(stmt, 7))
            let lastError = columnText(stmt, 8)
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))

            rows.append(Row(
                id: id,
                status: "pending",
                artist: artist,
                track: track,
                album: album,
                duration: duration,
                startedAt: startedAt,
                playedSeconds: playedSeconds,
                attempts: attempts,
                lastError: lastError,
                createdAt: createdAt
            ))
        }
        return rows
    }

    /// Recent rows of any status, newest first.
    func fetchRecent(limit: Int = 150) throws -> [Row] {
        let sql = """
        SELECT id, status, artist, track, album, duration, started_at, played_seconds, attempts, last_error, created_at
        FROM scrobble_queue
        ORDER BY id DESC
        LIMIT ?;
        """
        guard let db else { throw DBError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.sqlite(message: lastError(db))
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(limit))

        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let status = columnText(stmt, 1) ?? "?"
            let artist = columnText(stmt, 2) ?? ""
            let track = columnText(stmt, 3) ?? ""
            let album = columnText(stmt, 4)
            let duration = columnDouble(stmt, 5)
            let startedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
            let playedSeconds = sqlite3_column_double(stmt, 7)
            let attempts = Int(sqlite3_column_int(stmt, 8))
            let lastError = columnText(stmt, 9)
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))

            rows.append(Row(
                id: id,
                status: status,
                artist: artist,
                track: track,
                album: album,
                duration: duration,
                startedAt: startedAt,
                playedSeconds: playedSeconds,
                attempts: attempts,
                lastError: lastError,
                createdAt: createdAt
            ))
        }
        return rows
    }

    func countPending() throws -> Int {
        let sql = "SELECT COUNT(1) FROM scrobble_queue WHERE status = 'pending';"
        guard let db else { throw DBError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.sqlite(message: lastError(db))
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw DBError.sqlite(message: lastError(db))
        }
        return Int(sqlite3_column_int(stmt, 0))
    }

    func markSent(id: Int64) throws {
        try updateStatus(id: id, status: "sent", lastError: nil)
    }

    func markPermanentlyFailed(id: Int64, lastError: String) throws {
        try updateStatus(id: id, status: "permanently_failed", lastError: lastError)
    }

    func incrementAttempts(id: Int64, lastError: String) throws {
        let sql = """
        UPDATE scrobble_queue
        SET attempts = attempts + 1, last_error = ?
        WHERE id = ?;
        """
        guard let db else { throw DBError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.sqlite(message: self.lastError(db))
        }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, index: 1, lastError)
        sqlite3_bind_int64(stmt, 2, id)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DBError.sqlite(message: self.lastError(db))
        }
    }

    // MARK: - Setup

    private func open(url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            throw DBError.sqlite(message: "open failed rc=\(rc)")
        }
        self.db = handle
        sqlite3_busy_timeout(handle, 1_000)
    }

    private func migrate() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS scrobble_queue (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          status TEXT NOT NULL DEFAULT 'pending', -- pending/sent/permanently_failed
          artist TEXT NOT NULL,
          track TEXT NOT NULL,
          album TEXT NULL,
          duration REAL NULL,
          started_at REAL NOT NULL, -- epoch seconds
          played_seconds REAL NOT NULL,
          attempts INTEGER NOT NULL DEFAULT 0,
          last_error TEXT NULL,
          created_at REAL NOT NULL
        );
        """
        try exec(sql)
    }

    private func exec(_ sql: String) throws {
        guard let db else { throw DBError.notOpen }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? lastError(db)
            sqlite3_free(errMsg)
            throw DBError.sqlite(message: msg)
        }
    }

    // MARK: - Helpers

    private func updateStatus(id: Int64, status: String, lastError: String?) throws {
        let sql = """
        UPDATE scrobble_queue
        SET status = ?, last_error = ?
        WHERE id = ?;
        """
        guard let db else { throw DBError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DBError.sqlite(message: self.lastError(db))
        }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, index: 1, status)
        bindOptionalText(stmt, index: 2, lastError)
        sqlite3_bind_int64(stmt, 3, id)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DBError.sqlite(message: self.lastError(db))
        }
    }

    private static func defaultDatabaseURL() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("Gumball", isDirectory: true).appendingPathComponent("gumball.sqlite3")
    }

    private func lastError(_ db: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(db))
    }

    /// sqlite3_bind_text destructor for "make SQLite copy this buffer".
    /// Swift's SQLite3 module does not always export `SQLITE_TRANSIENT` directly.
    private static let sqliteTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bindText(_ stmt: OpaquePointer?, index: Int32, _ value: String) {
        _ = value.withCString { cstr in
            sqlite3_bind_text(stmt, index, cstr, -1, Self.sqliteTransientDestructor)
        }
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, index: Int32, _ value: String?) {
        if let value {
            bindText(stmt, index: index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindDouble(_ stmt: OpaquePointer?, index: Int32, _ value: Double) {
        sqlite3_bind_double(stmt, index, value)
    }

    private func bindOptionalDouble(_ stmt: OpaquePointer?, index: Int32, _ value: Double?) {
        if let value {
            bindDouble(stmt, index: index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func columnText(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: c)
    }

    private func columnDouble(_ stmt: OpaquePointer?, _ idx: Int32) -> Double? {
        if sqlite3_column_type(stmt, idx) == SQLITE_NULL { return nil }
        return sqlite3_column_double(stmt, idx)
    }

    enum DBError: Error {
        case notOpen
        case sqlite(message: String)
    }
}

