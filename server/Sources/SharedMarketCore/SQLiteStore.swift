import Foundation
import CSQLite

/// Used only by its owning SharedPriceCache actor. Separate actors/processes may
/// open the same file; BEGIN IMMEDIATE serializes the durable budget claim.
final class SQLiteStore {
    private var database: OpaquePointer?
    private let maximumEntries = 5_000
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        guard !path.isEmpty, !path.utf8.contains(0) else { throw CacheError.invalidRequest("A SQLite database path is required.") }
        let status = sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open SQLite database."
            if let database { sqlite3_close(database) }
            database = nil
            throw CacheError.storage(message)
        }
        do {
            guard sqlite3_busy_timeout(database, 5_000) == SQLITE_OK else { throw failure() }
            if path != ":memory:" { try execute("PRAGMA journal_mode = WAL") }
            try execute("PRAGMA synchronous = FULL")
            guard try integer("PRAGMA user_version") <= 1 else { throw CacheError.storage("Unsupported shared cache schema version.") }
            try execute("""
                CREATE TABLE IF NOT EXISTS cache_entries (
                    cache_key TEXT PRIMARY KEY NOT NULL,
                    utc_day TEXT NOT NULL,
                    payload BLOB NOT NULL,
                    inserted_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS attempt_claims (
                    cache_key TEXT NOT NULL,
                    utc_day TEXT NOT NULL,
                    PRIMARY KEY (cache_key, utc_day)
                );
                CREATE TABLE IF NOT EXISTS attempt_budgets (
                    bucket TEXT NOT NULL,
                    period TEXT NOT NULL,
                    attempts INTEGER NOT NULL CHECK(attempts >= 0),
                    PRIMARY KEY (bucket, period)
                );
                PRAGMA user_version = 1;
                """)
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit { if let database { sqlite3_close(database) } }

    func cached(key: String, day: String) throws -> Data? {
        let statement = try prepare("SELECT payload FROM cache_entries WHERE cache_key = ? AND utc_day = ?")
        defer { sqlite3_finalize(statement) }
        try bind(key, at: 1, to: statement)
        try bind(day, at: 2, to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_DONE: return nil
        case SQLITE_ROW:
            let length = Int(sqlite3_column_bytes(statement, 0))
            guard length > 0, length <= 1_000_000, let bytes = sqlite3_column_blob(statement, 0) else {
                throw CacheError.storage("The shared cache contains an invalid payload.")
            }
            return Data(bytes: bytes, count: length)
        default: throw failure()
        }
    }

    /// A claim survives failed fetches and process termination. Limits count
    /// logical fetch closures, which may use multiple retailer HTTP operations.
    func claim(key: String, day: String, month: String, dailyLimit: Int, monthlyLimit: Int) throws {
        try execute("BEGIN IMMEDIATE")
        var committed = false
        defer { if !committed { try? execute("ROLLBACK") } }
        let previous = try integer("SELECT COUNT(*) FROM attempt_claims WHERE cache_key = ? AND utc_day = ?", values: [key, day])
        guard previous == 0 else {
            throw CacheError.alreadyAttempted("This operation was already attempted today; its evidence is unavailable or has expired. Try again on the next UTC day.")
        }
        let daily = try integer("SELECT COALESCE(MAX(attempts), 0) FROM attempt_budgets WHERE bucket = 'day' AND period = ?", values: [day])
        let monthly = try integer("SELECT COALESCE(MAX(attempts), 0) FROM attempt_budgets WHERE bucket = 'month' AND period = ?", values: [month])
        guard daily < dailyLimit, monthly < monthlyLimit else {
            throw CacheError.budgetExceeded("The shared upstream attempt budget has been reached.")
        }
        try run("INSERT INTO attempt_claims (cache_key, utc_day) VALUES (?, ?)", values: [key, day])
        try run("INSERT INTO attempt_budgets (bucket, period, attempts) VALUES ('day', ?, 1) ON CONFLICT(bucket, period) DO UPDATE SET attempts = attempts + 1", values: [day])
        try run("INSERT INTO attempt_budgets (bucket, period, attempts) VALUES ('month', ?, 1) ON CONFLICT(bucket, period) DO UPDATE SET attempts = attempts + 1", values: [month])
        try execute("COMMIT")
        committed = true
    }

    func save(_ payload: Data, key: String, day: String, now: Date) throws {
        guard payload.count <= 1_000_000 else { throw CacheError.invalidEvidence("The shared evidence exceeds the payload limit.") }
        try execute("BEGIN IMMEDIATE")
        var committed = false
        defer { if !committed { try? execute("ROLLBACK") } }
        let statement = try prepare("INSERT INTO cache_entries (cache_key, utc_day, payload, inserted_at) VALUES (?, ?, ?, ?) ON CONFLICT(cache_key) DO UPDATE SET utc_day = excluded.utc_day, payload = excluded.payload, inserted_at = excluded.inserted_at WHERE excluded.utc_day >= cache_entries.utc_day")
        defer { sqlite3_finalize(statement) }
        try bind(key, at: 1, to: statement)
        try bind(day, at: 2, to: statement)
        let blobStatus = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(payload.count), transient) }
        guard blobStatus == SQLITE_OK, sqlite3_bind_double(statement, 4, now.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        try execute("DELETE FROM cache_entries WHERE cache_key IN (SELECT cache_key FROM cache_entries ORDER BY inserted_at DESC, cache_key DESC LIMIT -1 OFFSET \(maximumEntries))")
        try execute("COMMIT")
        committed = true
    }

    private func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &message)
        defer { if let message { sqlite3_free(message) } }
        guard status == SQLITE_OK else { throw CacheError.storage(message.map { String(cString: $0) } ?? "SQLite operation failed.") }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, value, -1, transient) == SQLITE_OK else { throw failure() }
    }

    private func integer(_ sql: String, values: [String] = []) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() { try bind(value, at: Int32(index + 1), to: statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func run(_ sql: String, values: [String]) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() { try bind(value, at: Int32(index + 1), to: statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    private func failure() -> CacheError {
        .storage(database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite is closed.")
    }
}
