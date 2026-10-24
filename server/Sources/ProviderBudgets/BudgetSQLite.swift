import Foundation
import CSQLite
import Darwin

/// Private to the owning actor. Each connection serializes mutations with
/// BEGIN IMMEDIATE; denied reservations roll back every bucket together.
final class BudgetSQLite {
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String, bootstrapCheckpoint: (() throws -> Void)? = nil) throws {
        guard !path.isEmpty, !path.utf8.contains(0) else { throw ProviderBudgetError.invalidRequest }
        // Resolve parent aliases such as macOS /var -> /private/var, while
        // leaving the final component for O_NOFOLLOW/SQLITE_OPEN_NOFOLLOW.
        let url = URL(fileURLWithPath: path)
        let physicalPath: String
        if path == ":memory:" { physicalPath = path }
        else {
            // Foundation deliberately reports /private/var as /var on macOS;
            // SQLite NOFOLLOW needs the actual POSIX physical parent path.
            guard let parent = realpath(url.deletingLastPathComponent().path, nil) else { throw ProviderBudgetError.storageUnavailable }
            physicalPath = String(cString: parent) + "/" + url.lastPathComponent
            free(parent)
        }
        let path = physicalPath
        if path != ":memory:" { try Self.secureFile(path) }
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }; database = nil
            throw ProviderBudgetError.storageUnavailable
        }
        do {
            guard sqlite3_busy_timeout(database, 5_000) == SQLITE_OK else { throw ProviderBudgetError.storageUnavailable }
            // An empty SQLite file or this application's identified schema is
            // accepted. No unrelated database is migrated or overwritten.
            let objects = try rows("SELECT name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'")
            let applicationID = try scalar("PRAGMA application_id")
            let version = try scalar("PRAGMA user_version")
            let allowed = Set(["budget_clock", "budget_configuration", "budget_clients", "budget_misses", "budget_reservations", "budget_misses_time", "budget_reservations_time"])
            guard (objects.isEmpty && applicationID == 0 && version == 0)
                    || (applicationID == 1_414_354_242 && version == 1 && objects.allSatisfy({ allowed.contains($0["name"] ?? "") })) else {
                throw ProviderBudgetError.invalidRequest
            }
            if path != ":memory:" { try execute("PRAGMA journal_mode = WAL") }
            try execute("PRAGMA synchronous = FULL; PRAGMA foreign_keys = ON; PRAGMA secure_delete = ON")
            try execute("BEGIN IMMEDIATE")
            do {
                try execute("""
                CREATE TABLE IF NOT EXISTS budget_clock (id INTEGER PRIMARY KEY CHECK(id = 1), last_seen REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS budget_configuration (id INTEGER PRIMARY KEY CHECK(id = 1), policy TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS budget_clients (client_id TEXT PRIMARY KEY NOT NULL);
                CREATE TABLE IF NOT EXISTS budget_misses (
                    miss_id TEXT PRIMARY KEY NOT NULL, client_id TEXT NOT NULL REFERENCES budget_clients(client_id),
                    created_at REAL NOT NULL, active INTEGER NOT NULL, operations INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX IF NOT EXISTS budget_misses_time ON budget_misses(created_at);
                CREATE TABLE IF NOT EXISTS budget_reservations (
                    reservation_id TEXT PRIMARY KEY NOT NULL, miss_id TEXT NOT NULL REFERENCES budget_misses(miss_id),
                    created_at REAL NOT NULL, client_id TEXT NOT NULL, purpose TEXT NOT NULL,
                    dispatched INTEGER NOT NULL DEFAULT 0, state TEXT NOT NULL DEFAULT 'reserved'
                );
                CREATE INDEX IF NOT EXISTS budget_reservations_time ON budget_reservations(created_at);
                PRAGMA application_id = 1414354242;
                PRAGMA user_version = 1;
                """)
                try bootstrapCheckpoint?()
                try execute("COMMIT")
            } catch { try? execute("ROLLBACK"); throw error }
            if path != ":memory:" {
                for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
                    try Self.secureFile(path + suffix)
                }
            }
        } catch { sqlite3_close(database); database = nil; throw error }
    }
    deinit { if let database { sqlite3_close(database) } }

    private static func secureFile(_ path: String) throws {
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT else { throw ProviderBudgetError.storageUnavailable }
            // Only create a genuinely new file. Never open/close an existing
            // SQLite file merely to check permissions: POSIX close releases
            // the process's advisory locks, including SQLite's WAL/SHM locks.
            let descriptor = open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
            if descriptor >= 0 { close(descriptor) }
            else if errno != EEXIST { throw ProviderBudgetError.storageUnavailable }
            guard lstat(path, &info) == 0 else { throw ProviderBudgetError.storageUnavailable }
        }
        // Reject permissive existing files rather than chmod a potentially
        // unrelated operator-supplied file before its identity is established.
        guard info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG,
              (info.st_mode & 0o777) == (S_IRUSR | S_IWUSR) else { throw ProviderBudgetError.storageUnavailable }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let value = try body(); try execute("COMMIT"); return value }
        catch { try? execute("ROLLBACK"); throw error }
    }

    func checkpoint() throws { try execute("PRAGMA wal_checkpoint(TRUNCATE)") }
    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &error)
        defer { if let error { sqlite3_free(error) } }
        guard status == SQLITE_OK else { throw ProviderBudgetError.storageUnavailable }
    }
    func run(_ sql: String, _ values: [String] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ProviderBudgetError.storageUnavailable }
    }
    func rows(_ sql: String, _ values: [String] = []) throws -> [[String: String]] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var output: [[String: String]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return output }
            guard status == SQLITE_ROW else { throw ProviderBudgetError.storageUnavailable }
            var row: [String: String] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                if sqlite3_column_type(statement, index) != SQLITE_NULL, let value = sqlite3_column_text(statement, index) {
                    row[String(cString: sqlite3_column_name(statement, index))] = String(cString: value)
                }
            }
            output.append(row)
        }
    }
    func scalar(_ sql: String, _ values: [String] = []) throws -> Int {
        guard let row = try rows(sql, values).first, let text = row.values.first, let value = Int(text) else { throw ProviderBudgetError.storageUnavailable }
        return value
    }
    private func prepare(_ sql: String, _ values: [String]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw ProviderBudgetError.storageUnavailable }
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) == SQLITE_OK else {
                sqlite3_finalize(statement); throw ProviderBudgetError.storageUnavailable
            }
        }
        return statement
    }
}
