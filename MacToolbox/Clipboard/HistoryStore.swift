import Foundation
import SQLite3

public struct HistoryStorageError: Error, Equatable, Sendable {
    public let code: Int32
    // Never include SQLite error text: it may quote persisted content or paths.
    public init(code: Int32) { self.code = code }
}

/// Actor-owned resource. Its deinit closes SQLite even if the client forgets close().
private final class SQLiteConnection {
    var pointer: OpaquePointer?
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    deinit { if let pointer { sqlite3_close_v2(pointer) } }
}

public actor HistoryStore {
    private var db: SQLiteConnection?
    private var lastSequence: Int64 = 0
    private static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

    private struct StoredPayload: Codable {
        let schemaVersion: Int
        let snapshot: ClipboardSnapshot
    }

    public init(url: URL) throws {
        guard url.isFileURL else { throw CoreError.invalidContent }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw HistoryStorageError(code: result)
        }
        do {
            try Self.execute(handle, "PRAGMA busy_timeout=1000")
            let version = try Self.integer(handle, "PRAGMA user_version")
            guard version == 0 || version == 1 else { throw CoreError.unsupportedVersion }
            try Self.execute(handle, "PRAGMA journal_mode=DELETE")
            try Self.execute(handle, "PRAGMA synchronous=FULL")
            try Self.execute(handle, "BEGIN IMMEDIATE")
            do {
                try Self.execute(handle, """
                    CREATE TABLE IF NOT EXISTS entries (
                      sequence INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE,
                      kind TEXT NOT NULL CHECK(kind IN ('text','image','files','unavailable')),
                      observed_at REAL NOT NULL, fingerprint BLOB NOT NULL,
                      summary TEXT NOT NULL, payload BLOB NOT NULL,
                      thumbnail BLOB, payload_bytes INTEGER NOT NULL,
                      frontmost_app_hint TEXT, status TEXT NOT NULL
                    )
                    """)
                try Self.execute(handle, "PRAGMA user_version=1")
                try Self.execute(handle, "COMMIT")
            } catch {
                try? Self.execute(handle, "ROLLBACK")
                throw error
            }
            lastSequence = try Self.integer(handle, "SELECT COALESCE(MAX(sequence),0) FROM entries")
            db = SQLiteConnection(handle)
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    // Explicit close keeps non-Sendable C pointers inside the actor in Swift 6.
    public func close() throws {
        guard let resource = db, let handle = resource.pointer else { return }
        let result = sqlite3_close(handle)
        guard result == SQLITE_OK else { throw HistoryStorageError(code: result) }
        resource.pointer = nil
        db = nil
    }

    public func maximumSequence() -> Int64 { lastSequence }

    // Mutations stay inside the core queue; the App target gets only read APIs.
    func append(_ snapshot: ClipboardSnapshot) throws {
        guard snapshot.observedSequence > lastSequence else { throw CoreError.sequenceOutOfOrder }
        try snapshot.content.validate()
        guard snapshot.observedAt.timeIntervalSince1970.isFinite else { throw CoreError.invalidContent }
        let handle = try connection()
        let payload = try JSONEncoder().encode(StoredPayload(schemaVersion: 1, snapshot: snapshot))
        try Self.execute(handle, "BEGIN IMMEDIATE")
        do {
            let latest = try Self.prepare(handle, "SELECT fingerprint FROM entries ORDER BY sequence DESC LIMIT 1")
            let step = sqlite3_step(latest)
            let same: Bool
            do { same = try step == SQLITE_ROW && Self.data(latest, 0, limit: 64) == Data(snapshot.fingerprint.hex.utf8) }
            catch { sqlite3_finalize(latest); throw error }
            if step != SQLITE_ROW && step != SQLITE_DONE {
                sqlite3_finalize(latest)
                throw HistoryStorageError(code: step)
            }
            sqlite3_finalize(latest)
            if same {
                // Keep the existing UUID/sequence/payload; only the last observation changes.
                let update = try Self.prepare(handle, "UPDATE entries SET observed_at=?, frontmost_app_hint=? WHERE sequence=(SELECT MAX(sequence) FROM entries)")
                defer { sqlite3_finalize(update) }
                try Self.check(sqlite3_bind_double(update, 1, snapshot.observedAt.timeIntervalSince1970))
                try Self.bind(snapshot.frontmostAppHint, at: 2, to: update)
                try Self.stepDone(update)
            } else {
                let insert = try Self.prepare(handle, "INSERT INTO entries(sequence,id,kind,observed_at,fingerprint,summary,payload,thumbnail,payload_bytes,frontmost_app_hint,status) VALUES(?,?,?,?,?,?,?,?,?,?,?)")
                defer { sqlite3_finalize(insert) }
                try Self.check(sqlite3_bind_int64(insert, 1, snapshot.observedSequence))
                try Self.bind(snapshot.id.uuidString, at: 2, to: insert)
                try Self.bind(snapshot.content.kind, at: 3, to: insert)
                try Self.check(sqlite3_bind_double(insert, 4, snapshot.observedAt.timeIntervalSince1970))
                try Self.bind(Data(snapshot.fingerprint.hex.utf8), at: 5, to: insert)
                try Self.bind(snapshot.content.summary, at: 6, to: insert)
                try Self.bind(payload, at: 7, to: insert)
                if case .image(let image) = snapshot.content {
                    try Self.bind(image.thumbnail, at: 8, to: insert)
                } else {
                    try Self.check(sqlite3_bind_null(insert, 8))
                }
                try Self.check(sqlite3_bind_int64(insert, 9, Int64(snapshot.content.byteCount)))
                try Self.bind(snapshot.frontmostAppHint, at: 10, to: insert)
                try Self.bind(snapshot.content.kind == "unavailable" ? "unavailable" : "available", at: 11, to: insert)
                try Self.stepDone(insert)
            }
            try Self.execute(handle, "DELETE FROM entries WHERE sequence NOT IN (SELECT sequence FROM entries ORDER BY sequence DESC LIMIT 20)")
            try Self.execute(handle, "COMMIT")
            lastSequence = snapshot.observedSequence
        } catch {
            try? Self.execute(handle, "ROLLBACK")
            throw error
        }
    }

    // Bulk payload loading is for core tests; the App list uses summaries().
    func entries() throws -> [HistoryEntry] {
        let statement = try Self.prepare(connection(), "SELECT payload,observed_at,frontmost_app_hint FROM entries ORDER BY sequence DESC")
        defer { sqlite3_finalize(statement) }
        var entries: [HistoryEntry] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw HistoryStorageError(code: result) }
            entries.append(try Self.decodeEntry(statement))
        }
        return entries
    }

    /// The history list uses this, never loading twenty full-sized image payloads.
    public func summaries() throws -> [HistorySummary] {
        let statement = try Self.prepare(connection(), "SELECT id,sequence,kind,observed_at,summary,thumbnail,payload_bytes,status FROM entries ORDER BY sequence DESC")
        defer { sqlite3_finalize(statement) }
        var values: [HistorySummary] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw HistoryStorageError(code: result) }
            guard let idText = Self.string(statement, 0), let id = UUID(uuidString: idText),
                  let kind = Self.string(statement, 2), let summary = Self.string(statement, 4),
                  let status = Self.string(statement, 7) else { throw CoreError.invalidContent }
            let thumbnail = sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : try Self.data(statement, 5, limit: AppLimits.textBytes)
            values.append(HistorySummary(id: id, sequence: sqlite3_column_int64(statement, 1), kind: kind,
                observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)), summary: summary,
                thumbnail: thumbnail, payloadBytes: Int(sqlite3_column_int64(statement, 6)), status: status))
        }
        return values
    }

    public func entry(id: UUID) throws -> HistoryEntry? {
        let statement = try Self.prepare(connection(), "SELECT payload,observed_at,frontmost_app_hint FROM entries WHERE id=?")
        defer { sqlite3_finalize(statement) }
        try Self.bind(id.uuidString, at: 1, to: statement)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw HistoryStorageError(code: result) }
        return try Self.decodeEntry(statement)
    }

    func removeText(matching digests: Set<ContentDigest>) throws {
        guard !digests.isEmpty else { return }
        let handle = try connection()
        try Self.execute(handle, "BEGIN IMMEDIATE")
        do {
            let textEntries = try Self.prepare(handle, "SELECT payload,observed_at,frontmost_app_hint FROM entries WHERE kind='text'")
            let ids: [UUID]
            do {
                var matches: [UUID] = []
                while true {
                    let result = sqlite3_step(textEntries)
                    if result == SQLITE_DONE { break }
                    guard result == SQLITE_ROW else { throw HistoryStorageError(code: result) }
                    let entry = try Self.decodeEntry(textEntries)
                    if case .text(let value) = entry.snapshot.content, digests.contains(value.plainDigest) {
                        matches.append(entry.snapshot.id)
                    }
                }
                ids = matches
                sqlite3_finalize(textEntries)
            } catch { sqlite3_finalize(textEntries); throw error }
            for id in ids {
                let statement = try Self.prepare(handle, "DELETE FROM entries WHERE id=?")
                defer { sqlite3_finalize(statement) }
                try Self.bind(id.uuidString, at: 1, to: statement)
                try Self.stepDone(statement)
            }
            try Self.execute(handle, "COMMIT")
        } catch {
            try? Self.execute(handle, "ROLLBACK")
            throw error
        }
    }

    private func connection() throws -> OpaquePointer {
        guard let handle = db?.pointer else { throw HistoryStorageError(code: SQLITE_MISUSE) }
        return handle
    }

    private static func decodeEntry(_ statement: OpaquePointer) throws -> HistoryEntry {
        let data = try data(statement, 0, limit: 36 * 1_048_576)
        let payload = try JSONDecoder().decode(StoredPayload.self, from: data)
        guard payload.schemaVersion == 1 else { throw CoreError.unsupportedVersion }
        let original = payload.snapshot
        return HistoryEntry(snapshot: try ClipboardSnapshot(id: original.id, sequence: original.observedSequence,
            changeCount: original.observedChangeCount, observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            frontmostAppHint: string(statement, 2), content: original.content))
    }

    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        try check(sqlite3_exec(db, sql, nil, nil, nil))
    }

    private static func check(_ result: Int32) throws {
        guard result == SQLITE_OK else { throw HistoryStorageError(code: result) }
    }

    private static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil))
        guard let statement else { throw HistoryStorageError(code: SQLITE_MISUSE) }
        return statement
    }

    private static func integer(_ db: OpaquePointer, _ sql: String) throws -> Int64 {
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else { throw HistoryStorageError(code: result) }
        return sqlite3_column_int64(statement, 0)
    }

    private static func bind(_ text: String?, at index: Int32, to statement: OpaquePointer) throws {
        guard let text else { return try check(sqlite3_bind_null(statement, index)) }
        guard text.utf8.count <= Int32.max else { throw CoreError.contentTooLarge }
        try text.withCString { try check(sqlite3_bind_text(statement, index, $0, Int32(text.utf8.count), transient)) }
    }

    private static func bind(_ data: Data?, at index: Int32, to statement: OpaquePointer) throws {
        guard let data else { return try check(sqlite3_bind_null(statement, index)) }
        if data.isEmpty { return try check(sqlite3_bind_zeroblob(statement, index, 0)) }
        try data.withUnsafeBytes { bytes in
            try check(sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient))
        }
    }

    private static func stepDone(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw HistoryStorageError(code: result) }
    }

    private static func data(_ statement: OpaquePointer, _ column: Int32, limit: Int) throws -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count <= limit else { throw CoreError.contentTooLarge }
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private static func string(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, column) else { return nil }
        return String(bytes: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), encoding: .utf8)
    }
}
