import Foundation
import CSQLite
import CryptoKit
import Darwin

/// Used only by its owning SharedPriceCache actor. Separate actors/processes may
/// open the same file; BEGIN IMMEDIATE serializes the durable budget claim.
final class SQLiteStore {
    private var database: OpaquePointer?
    private let maximumEntries = 5_000
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String, bootstrapCheckpoint: (() throws -> Void)? = nil) throws {
        guard !path.isEmpty, !path.utf8.contains(0) else { throw CacheError.invalidRequest("A SQLite database path is required.") }
        let physical: String
        if path == ":memory:" { physical = path }
        else {
            let url = URL(fileURLWithPath: path)
            guard let parent = realpath(url.deletingLastPathComponent().path, nil) else { throw CacheError.storage("Shared storage is unavailable.") }
            physical = String(cString: parent) + "/" + url.lastPathComponent; free(parent)
            try Self.secureFile(physical)
        }
        guard sqlite3_open_v2(physical, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }; database = nil
            throw CacheError.storage("Shared storage is unavailable.")
        }
        do {
            guard sqlite3_busy_timeout(database, 5_000) == SQLITE_OK else { throw failure() }
            let objects = try names()
            let version = try integer("PRAGMA user_version")
            let appID = try integer("PRAGMA application_id")
            let legacy = Set(["cache_entries", "attempt_claims", "attempt_budgets"])
            let current = legacy.union(["scheduled_runs", "source_runs"])
            guard (objects.isEmpty && version == 0 && appID == 0)
                || (version == 1 && appID == 0 && objects == legacy)
                || (version == 3 && appID == 1_414_354_243 && objects == current) else { throw CacheError.storage("Unsupported shared cache schema.") }
            if physical != ":memory:" { try execute("PRAGMA journal_mode = WAL") }
            try execute("PRAGMA synchronous = FULL; BEGIN IMMEDIATE")
            do {
                try execute("""
                CREATE TABLE IF NOT EXISTS cache_entries (
                    cache_key TEXT PRIMARY KEY NOT NULL, utc_day TEXT NOT NULL,
                    payload BLOB NOT NULL, inserted_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS attempt_claims (
                    cache_key TEXT NOT NULL, utc_day TEXT NOT NULL, PRIMARY KEY(cache_key, utc_day)
                );
                CREATE TABLE IF NOT EXISTS attempt_budgets (
                    bucket TEXT NOT NULL, period TEXT NOT NULL, attempts INTEGER NOT NULL CHECK(attempts >= 0), PRIMARY KEY(bucket, period)
                );
                CREATE TABLE IF NOT EXISTS scheduled_runs (utc_day TEXT PRIMARY KEY NOT NULL);
                CREATE TABLE IF NOT EXISTS source_runs (context TEXT PRIMARY KEY NOT NULL, state TEXT NOT NULL, utc_day TEXT NOT NULL);
                """)
                if version < 3 {
                    try execute("ALTER TABLE cache_entries ADD COLUMN policy TEXT NOT NULL DEFAULT ''")
                    // Preserve all prior daily dedupe claims, but erase their raw
                    // product/search identities. Hashes are not usable evidence.
                    let statement = try prepare("SELECT cache_key, utc_day FROM attempt_claims")
                    var claims: [(String, String)] = []
                    do {
                        while true {
                            let status = sqlite3_step(statement)
                            if status == SQLITE_DONE { break }
                            guard status == SQLITE_ROW else { throw failure() }
                            claims.append((String(cString: sqlite3_column_text(statement, 0)), String(cString: sqlite3_column_text(statement, 1))))
                        }
                        sqlite3_finalize(statement)
                    } catch { sqlite3_finalize(statement); throw error }
                    try execute("DELETE FROM attempt_claims")
                    for (key, day) in claims { try run("INSERT OR IGNORE INTO attempt_claims (cache_key, utc_day) VALUES (?, ?)", values: [Self.digest(key), day]) }
                }
                try bootstrapCheckpoint?()
                try execute("PRAGMA application_id = 1414354243; PRAGMA user_version = 3; COMMIT")
            } catch { try? execute("ROLLBACK"); throw error }
            if physical != ":memory:" {
                for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: physical + suffix) { try Self.secureFile(physical + suffix) }
            }
        } catch { sqlite3_close(database); database = nil; throw error }
    }
    private static func secureFile(_ path: String) throws {
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT else { throw CacheError.storage("Shared storage is unavailable.") }
            let descriptor = open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
            if descriptor >= 0 { close(descriptor) }
            else if errno != EEXIST { throw CacheError.storage("Shared storage is unavailable.") }
            guard lstat(path, &info) == 0 else { throw CacheError.storage("Shared storage is unavailable.") }
        }
        guard info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG, (info.st_mode & 0o777) == 0o600 else { throw CacheError.storage("Shared storage must be private.") }
    }
    private func names() throws -> Set<String> {
        let statement = try prepare("SELECT name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'")
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_DONE: return names
            case SQLITE_ROW: names.insert(String(cString: sqlite3_column_text(statement, 0)))
            default: throw failure()
            }
        }
    }
    private static func digest(_ key: String) -> String { SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() }

    deinit { if let database { sqlite3_close(database) } }

    struct Entry { let data: Data; let insertedAt: Date; let policy: String; let day: String }
    func cached(key: String, day: String) throws -> Entry? {
        let statement = try prepare("SELECT payload, inserted_at, policy, utc_day FROM cache_entries WHERE cache_key = ? AND utc_day = ?")
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
            return Entry(data: Data(bytes: bytes, count: length), insertedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)), policy: String(cString: sqlite3_column_text(statement, 2)), day: String(cString: sqlite3_column_text(statement, 3)))
        default: throw failure()
        }
    }

    /// A claim survives failed fetches and process termination. Limits count
    /// logical fetch closures, which may use multiple retailer HTTP operations.
    func claim(key: String, day: String, month: String, dailyLimit: Int, monthlyLimit: Int) throws {
        try execute("BEGIN IMMEDIATE")
        var committed = false
        defer { if !committed { try? execute("ROLLBACK") } }
        let key = Self.digest(key)
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

    func save(_ payload: Data, key: String, day: String, now: Date, policy: String) throws {
        guard payload.count <= 1_000_000 else { throw CacheError.invalidEvidence("The shared evidence exceeds the payload limit.") }
        try execute("BEGIN IMMEDIATE")
        var committed = false
        defer { if !committed { try? execute("ROLLBACK") } }
        let statement = try prepare("INSERT INTO cache_entries (cache_key, utc_day, payload, inserted_at, policy) VALUES (?, ?, ?, ?, ?) ON CONFLICT(cache_key) DO UPDATE SET utc_day = excluded.utc_day, payload = excluded.payload, inserted_at = excluded.inserted_at, policy = excluded.policy WHERE excluded.utc_day >= cache_entries.utc_day")
        defer { sqlite3_finalize(statement) }
        try bind(key, at: 1, to: statement)
        try bind(day, at: 2, to: statement)
        try bind(policy, at: 5, to: statement)
        let blobStatus = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(payload.count), transient) }
        guard blobStatus == SQLITE_OK, sqlite3_bind_double(statement, 4, now.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
        try execute("DELETE FROM cache_entries WHERE cache_key IN (SELECT cache_key FROM cache_entries ORDER BY inserted_at DESC, cache_key DESC LIMIT -1 OFFSET \(maximumEntries))")
        try execute("COMMIT")
        committed = true
    }

    func record(state: SourceState, context: String, day: String) throws {
        try run("INSERT INTO source_runs (context, state, utc_day) VALUES (?, ?, ?) ON CONFLICT(context) DO UPDATE SET state = excluded.state, utc_day = excluded.utc_day WHERE excluded.utc_day >= source_runs.utc_day", values: [context, state.rawValue, day])
    }
    func recorded(context: String) throws -> SourceState? {
        let statement = try prepare("SELECT state FROM source_runs WHERE context = ?")
        defer { sqlite3_finalize(statement) }; try bind(context, at: 1, to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_DONE: return nil
        case SQLITE_ROW: return SourceState(rawValue: String(cString: sqlite3_column_text(statement, 0)))
        default: throw failure()
        }
    }
    func clearRecorded(context: String) throws { try run("DELETE FROM source_runs WHERE context = ?", values: [context]) }
    func recoverPending() throws { try execute("UPDATE source_runs SET state = 'failed' WHERE state = 'pending'") }
    func delete(key: String) throws { try run("DELETE FROM cache_entries WHERE cache_key = ?", values: [key]) }
    func purge(prefix: String, before: Date? = nil, exceptPolicy: String? = nil) throws {
        var sql = "DELETE FROM cache_entries WHERE substr(cache_key, 1, length(?)) = ?"
        var values = [prefix, prefix]
        if let before { sql += " AND inserted_at <= ?"; values.append(String(before.timeIntervalSince1970)) }
        if let exceptPolicy { sql += " AND policy != ?"; values.append(exceptPolicy) }
        try run(sql, values: values)
    }
    func entryKeys() throws -> [String] {
        let statement = try prepare("SELECT cache_key FROM cache_entries ORDER BY cache_key LIMIT 5000")
        defer { sqlite3_finalize(statement) }
        var keys: [String] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_DONE: return keys
            case SQLITE_ROW:
                guard sqlite3_column_bytes(statement, 0) <= 2048 else { throw failure() }
                keys.append(String(cString: sqlite3_column_text(statement, 0)))
            default: throw failure()
            }
        }
    }
    func entry(key: String) throws -> Entry? {
        let statement = try prepare("SELECT payload, inserted_at, policy, utc_day FROM cache_entries WHERE cache_key = ?")
        defer { sqlite3_finalize(statement) }; try bind(key, at: 1, to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_DONE: return nil
        case SQLITE_ROW:
            let length = Int(sqlite3_column_bytes(statement, 0))
            guard length > 0, length <= 1_000_000, let bytes = sqlite3_column_blob(statement, 0) else { throw failure() }
            return Entry(data: Data(bytes: bytes, count: length), insertedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)), policy: String(cString: sqlite3_column_text(statement, 2)), day: String(cString: sqlite3_column_text(statement, 3)))
        default: throw failure()
        }
    }
    func claimScheduled(day: String) throws -> Bool {
        try execute("BEGIN IMMEDIATE")
        do {
            let exists = try integer("SELECT COUNT(*) FROM scheduled_runs WHERE utc_day >= ?", values: [day])
            if exists > 0 { try execute("COMMIT"); return false }
            try run("INSERT INTO scheduled_runs (utc_day) VALUES (?)", values: [day])
            // Old daily tombstones do not permit current-day replay. A durable
            // maximum day prevents clock rollback from scheduling an old day.
            try run("DELETE FROM scheduled_runs WHERE utc_day < ?", values: [day])
            try execute("COMMIT"); return true
        } catch { try? execute("ROLLBACK"); throw error }
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
