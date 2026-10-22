import Foundation
import CSQLite
import Darwin

public enum SessionDatabasePaths {
    public static func validate(authPath: String, cachePath: String) throws {
        guard authPath != ":memory:", cachePath != ":memory:" else { throw SessionError.invalidRequest }
        let auth = URL(fileURLWithPath: authPath).standardizedFileURL.resolvingSymlinksInPath()
        let cache = URL(fileURLWithPath: cachePath).standardizedFileURL.resolvingSymlinksInPath()
        guard auth.path != cache.path else { throw SessionError.invalidRequest }
        if let left = try? FileManager.default.attributesOfItem(atPath: auth.path),
           let right = try? FileManager.default.attributesOfItem(atPath: cache.path),
           let leftInode = left[.systemFileNumber] as? NSNumber, let rightInode = right[.systemFileNumber] as? NSNumber,
           leftInode == rightInode, (left[.systemNumber] as? NSNumber) == (right[.systemNumber] as? NSNumber) {
            throw SessionError.invalidRequest
        }
    }
}

/// Private to the owning actor. Each connection serializes mutations with
/// BEGIN IMMEDIATE; safe failures commit rate reservations/replay revocation.
final class SessionSQLite {
    private var database: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String, bootstrapCheckpoint: (() throws -> Void)? = nil) throws {
        guard !path.isEmpty, !path.utf8.contains(0) else { throw SessionError.invalidRequest }
        // Resolve parent aliases such as macOS /var -> /private/var, while
        // leaving the final component for O_NOFOLLOW/SQLITE_OPEN_NOFOLLOW.
        let url = URL(fileURLWithPath: path)
        let physicalPath: String
        if path == ":memory:" { physicalPath = path }
        else {
            // Foundation deliberately reports /private/var as /var on macOS;
            // SQLite NOFOLLOW needs the actual POSIX physical parent path.
            guard let parent = realpath(url.deletingLastPathComponent().path, nil) else { throw SessionError.storageUnavailable }
            physicalPath = String(cString: parent) + "/" + url.lastPathComponent
            free(parent)
        }
        let path = physicalPath
        if path != ":memory:" { try Self.secureFile(path) }
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }; database = nil
            throw SessionError.storageUnavailable
        }
        do {
            guard sqlite3_busy_timeout(database, 5_000) == SQLITE_OK else { throw SessionError.storageUnavailable }
            // An empty SQLite file or this application's identified schema is
            // accepted. No unrelated database is migrated or overwritten.
            let objects = try rows("SELECT name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'")
            let applicationID = try scalar("PRAGMA application_id")
            let version = try scalar("PRAGMA user_version")
            let allowed = Set(["auth_clients", "auth_invitations", "auth_sessions", "auth_refresh_history", "auth_refresh_history_expiry", "auth_attempts"])
            guard (objects.isEmpty && applicationID == 0 && version == 0)
                    || (applicationID == 1_414_353_729 && version == 1 && objects.allSatisfy({ allowed.contains($0["name"] ?? "") })) else {
                throw SessionError.invalidRequest
            }
            if path != ":memory:" { try execute("PRAGMA journal_mode = WAL") }
            try execute("PRAGMA synchronous = FULL; PRAGMA foreign_keys = ON")
            try execute("BEGIN IMMEDIATE")
            do {
                try execute("""
                CREATE TABLE IF NOT EXISTS auth_clients (
                    client_id TEXT PRIMARY KEY, created_at REAL NOT NULL, enrolled_at REAL, revoked_at REAL
                );
                """)
                // Internal test checkpoint proves partial bootstrap rolls back;
                // no public enrollment/credential API exposes this hook.
                try bootstrapCheckpoint?()
                try execute("""
                CREATE TABLE IF NOT EXISTS auth_invitations (
                    invitation_hash TEXT PRIMARY KEY, client_id TEXT NOT NULL UNIQUE REFERENCES auth_clients(client_id),
                    expires_at REAL NOT NULL, used_at REAL
                );
                CREATE TABLE IF NOT EXISTS auth_sessions (
                    session_id TEXT PRIMARY KEY, client_id TEXT NOT NULL UNIQUE REFERENCES auth_clients(client_id),
                    access_hash TEXT NOT NULL UNIQUE, refresh_hash TEXT NOT NULL UNIQUE,
                    access_expires REAL NOT NULL, refresh_expires REAL NOT NULL, revoked_at REAL,
                    generation INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE IF NOT EXISTS auth_refresh_history (
                    refresh_hash TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES auth_sessions(session_id),
                    expires_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS auth_refresh_history_expiry ON auth_refresh_history(expires_at);
                CREATE TABLE IF NOT EXISTS auth_attempts (
                    scope TEXT NOT NULL, period INTEGER NOT NULL, attempts INTEGER NOT NULL,
                    PRIMARY KEY(scope, period)
                );
                PRAGMA application_id = 1414353729;
                PRAGMA user_version = 1;
                """)
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
            guard errno == ENOENT else { throw SessionError.storageUnavailable }
            // Only create a genuinely new file. Never open/close an existing
            // SQLite file merely to check permissions: POSIX close releases
            // the process's advisory locks, including SQLite's WAL/SHM locks.
            let descriptor = open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
            if descriptor >= 0 { close(descriptor) }
            else if errno != EEXIST { throw SessionError.storageUnavailable }
            guard lstat(path, &info) == 0 else { throw SessionError.storageUnavailable }
        }
        // Reject permissive existing files rather than chmod a potentially
        // unrelated operator-supplied file before its identity is established.
        guard info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG,
              (info.st_mode & 0o777) == (S_IRUSR | S_IWUSR) else { throw SessionError.storageUnavailable }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let value = try body(); try execute("COMMIT"); return value }
        catch let error as SessionError {
            switch error {
            case .storageUnavailable, .entropyUnavailable:
                try? execute("ROLLBACK")
            default:
                do { try execute("COMMIT") } catch { try? execute("ROLLBACK"); throw SessionError.storageUnavailable }
            }
            throw error
        } catch { try? execute("ROLLBACK"); throw SessionError.storageUnavailable }
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &error)
        defer { if let error { sqlite3_free(error) } }
        guard status == SQLITE_OK else { throw SessionError.storageUnavailable }
    }
    func run(_ sql: String, _ values: [String] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SessionError.storageUnavailable }
    }
    func rows(_ sql: String, _ values: [String] = []) throws -> [[String: String]] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var output: [[String: String]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return output }
            guard status == SQLITE_ROW else { throw SessionError.storageUnavailable }
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
        guard let row = try rows(sql, values).first, let text = row.values.first, let value = Int(text) else { throw SessionError.storageUnavailable }
        return value
    }
    private func prepare(_ sql: String, _ values: [String]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw SessionError.storageUnavailable }
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) == SQLITE_OK else {
                sqlite3_finalize(statement); throw SessionError.storageUnavailable
            }
        }
        return statement
    }
}
