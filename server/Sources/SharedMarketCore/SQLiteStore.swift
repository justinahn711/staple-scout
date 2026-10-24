import Foundation
import CSQLite
import CryptoKit
import Security
import Darwin

/// Used only by its owning SharedPriceCache actor. Separate actors/processes may
/// open the same file; BEGIN IMMEDIATE serializes the durable budget claim.
final class SQLiteStore {
    private var database: OpaquePointer?
    private let maximumEntries = 5_000
    private var lookupSecret: SymmetricKey!
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
            let retained = current.union(["cache_metadata"])
            guard (objects.isEmpty && version == 0 && appID == 0)
                || (version == 1 && appID == 0 && objects == legacy)
                || (version == 3 && appID == 1_414_354_243 && objects == current)
                || (version == 4 && appID == 1_414_354_243 && objects == retained) else { throw CacheError.storage("Unsupported shared cache schema.") }
            if physical != ":memory:" { try execute("PRAGMA journal_mode = WAL") }
            try execute("PRAGMA synchronous = FULL; PRAGMA secure_delete = ON; BEGIN IMMEDIATE")
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
                    guard try integer("SELECT COUNT(*) FROM attempt_claims") <= 100_000 else { throw CacheError.storage("Legacy claims require an offline reviewed migration.") }
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
                if version < 4 {
                    try execute("CREATE TABLE cache_metadata (name TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)")
                    var bytes = [UInt8](repeating: 0, count: 32)
                    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw failure() }
                    let secret = Data(bytes)
                    try run("INSERT INTO cache_metadata VALUES ('lookup_secret', ?)", values: [secret.base64EncodedString()])
                    lookupSecret = SymmetricKey(data: secret)
                    try run("INSERT INTO cache_metadata VALUES ('lookup_check', ?)", values: [keyedDigest("key-integrity-check")])
                    // Legacy claims already hold SHA256(canonical raw key).
                    // HMAC that digest, exactly as new requests do, so neither
                    // migration nor query minimization permits a fresh attempt.
                    guard try integer("SELECT COUNT(*) FROM attempt_claims") <= 100_000 else { throw CacheError.storage("Legacy claims require an offline reviewed migration.") }
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
                    try execute("DELETE FROM attempt_claims; DELETE FROM cache_entries")
                    for (digest, day) in claims { try run("INSERT OR IGNORE INTO attempt_claims VALUES (?, ?)", values: [keyedDigest(digest), day]) }
                    try execute("ALTER TABLE source_runs ADD COLUMN attempted_at REAL; ALTER TABLE source_runs ADD COLUMN succeeded_at REAL")
                } else {
                    let statement = try prepare("SELECT value FROM cache_metadata WHERE name = 'lookup_secret'")
                    defer { sqlite3_finalize(statement) }
                    guard sqlite3_step(statement) == SQLITE_ROW,
                          let secret = Data(base64Encoded: String(cString: sqlite3_column_text(statement, 0))), secret.count == 32 else { throw failure() }
                    lookupSecret = SymmetricKey(data: secret)
                    let check = try prepare("SELECT value FROM cache_metadata WHERE name = 'lookup_check'")
                    defer { sqlite3_finalize(check) }
                    guard sqlite3_step(check) == SQLITE_ROW,
                          String(cString: sqlite3_column_text(check, 0)) == keyedDigest("key-integrity-check") else { throw failure() }
                }
                if version < 4 {
                    let statement = try prepare("SELECT COALESCE(MAX(CAST(strftime('%s', utc_day) AS REAL)), 0) FROM (SELECT utc_day FROM attempt_claims UNION ALL SELECT utc_day FROM scheduled_runs UNION ALL SELECT utc_day FROM source_runs)")
                    defer { sqlite3_finalize(statement) }
                    guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
                    try run("INSERT INTO cache_metadata VALUES ('last_seen', ?)", values: [String(sqlite3_column_double(statement, 0))])
                }
                try bootstrapCheckpoint?()
                try execute("PRAGMA application_id = 1414354243; PRAGMA user_version = 4; COMMIT")
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
        let key = keyedDigest(Self.digest(key))
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

    struct SourceRun { let state: SourceState; let attemptedAt: Date?; let succeededAt: Date? }
    func record(state: SourceState, context: String, day: String, at date: Date) throws {
        try run("""
        INSERT INTO source_runs (context, state, utc_day, attempted_at, succeeded_at)
        VALUES (?, ?, ?, ?, CASE WHEN ? = 'ready' THEN ? ELSE NULL END)
        ON CONFLICT(context) DO UPDATE SET state = excluded.state, utc_day = excluded.utc_day,
        attempted_at = CASE WHEN excluded.state = 'pending' THEN excluded.attempted_at ELSE source_runs.attempted_at END,
        succeeded_at = CASE WHEN excluded.state = 'ready' THEN excluded.succeeded_at ELSE source_runs.succeeded_at END
        WHERE excluded.utc_day >= source_runs.utc_day
        """, values: [context, state.rawValue, day, String(date.timeIntervalSince1970), state.rawValue, String(date.timeIntervalSince1970)])
    }
    func recorded(context: String) throws -> SourceRun? {
        let statement = try prepare("SELECT state, attempted_at, succeeded_at FROM source_runs WHERE context = ?")
        defer { sqlite3_finalize(statement) }; try bind(context, at: 1, to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_DONE: return nil
        case SQLITE_ROW:
            guard let state = SourceState(rawValue: String(cString: sqlite3_column_text(statement, 0))) else { throw failure() }
            func date(_ index: Int32) -> Date? { sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, index)) }
            return SourceRun(state: state, attemptedAt: date(1), succeededAt: date(2))
        default: throw failure()
        }
    }
    func purgeRecorded(context: String, before date: Date) throws {
        let time = String(date.timeIntervalSince1970)
        try run("UPDATE source_runs SET attempted_at = CASE WHEN attempted_at <= CAST(? AS REAL) THEN NULL ELSE attempted_at END, succeeded_at = CASE WHEN succeeded_at <= CAST(? AS REAL) THEN NULL ELSE succeeded_at END WHERE context = ?", values: [time, time, context])
        try run("DELETE FROM source_runs WHERE context = ? AND attempted_at IS NULL AND succeeded_at IS NULL", values: [context])
    }
    /// The key is database-scoped pseudonymous lookup, not anonymization. An
    /// operator with this private database also possesses the lookup secret.
    func lookupKey(_ canonical: String) throws -> String {
        guard var parts = try? JSONDecoder().decode([String].self, from: Data(canonical.utf8)), parts.count == 5 else { throw failure() }
        if parts[0] == "search" { parts[4] = keyedDigest(Self.digest(canonical)) }
        return String(decoding: try JSONEncoder().encode(parts), as: UTF8.self)
    }
    private func keyedDigest(_ digest: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(("thrifty-cache-lookup-v1:" + digest).utf8), using: lookupSecret).map { String(format: "%02x", $0) }.joined()
    }
    func clampedDate(_ proposed: Date) throws -> Date {
        try execute("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("SELECT value FROM cache_metadata WHERE name = 'last_seen'")
            let status = sqlite3_step(statement)
            guard status == SQLITE_ROW else { sqlite3_finalize(statement); throw failure() }
            let previous = Double(String(cString: sqlite3_column_text(statement, 0)))
            sqlite3_finalize(statement)
            guard let previous, previous.isFinite, (0..<253_402_300_800).contains(previous) else { throw failure() }
            let sampled = proposed.timeIntervalSince1970
            guard sampled.isFinite, (0..<253_402_300_800).contains(sampled) else { throw failure() }
            let time = max(previous, sampled)
            try run("INSERT INTO cache_metadata VALUES ('last_seen', ?) ON CONFLICT(name) DO UPDATE SET value = excluded.value", values: [String(time)])
            try execute("COMMIT"); return Date(timeIntervalSince1970: time)
        } catch { try? execute("ROLLBACK"); throw error }
    }
    func pruneClaims(at date: Date) throws {
        // Retain 62 days: beyond every daily/monthly allowance. The persisted
        // maximum clock means deleting expired buckets cannot reopen old days.
        let cutoff = date.addingTimeInterval(-62 * 86_400)
        let day = try SharedPriceCache.utcDay(cutoff)
        try execute("BEGIN IMMEDIATE")
        do {
            try run("DELETE FROM attempt_claims WHERE rowid IN (SELECT rowid FROM attempt_claims WHERE utc_day < ? LIMIT 5000)", values: [day])
            try run("DELETE FROM attempt_budgets WHERE rowid IN (SELECT rowid FROM attempt_budgets WHERE (bucket = 'day' AND period < ?) OR (bucket = 'month' AND period < ?) LIMIT 5000)", values: [day, String(day.prefix(7))])
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    func checkpoint() throws { try execute("PRAGMA wal_checkpoint(TRUNCATE)") }
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
