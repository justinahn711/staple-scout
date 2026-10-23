import Foundation
import Darwin

public enum ServiceOwnershipError: Error { case unsafeTopology, alreadyRunning }

/// The supported model is one service process owning all three databases.
/// Locks never expire and lock files are never unlinked by this implementation.
/// SQLite DB/WAL/SHM files are not raw-opened/closed after SQLite starts.
public final class ServiceOwnership: @unchecked Sendable {
    private struct Held {
        let database: String; let lockPath: String; let descriptor: Int32
        let databaseDevice: dev_t; let databaseInode: ino_t
        let lockDevice: dev_t; let lockInode: ino_t
    }
    private var held: [Held] = []
    private let capabilityLock = NSLock()
    private var consumed: Set<String> = []

    public init(databasePaths: [String]) throws {
        guard databasePaths.count == 3 else { throw ServiceOwnershipError.unsafeTopology }
        do {
            let paths = try databasePaths.map(Self.physicalPath).sorted()
            guard Set(paths).count == 3 else { throw ServiceOwnershipError.unsafeTopology }
            let reserved = paths.flatMap { [$0, $0 + ".owner.lock", $0 + "-wal", $0 + "-shm"] }
            guard Set(reserved).count == reserved.count else { throw ServiceOwnershipError.unsafeTopology }
            for path in paths {
                try Self.createPrivateIfAbsent(path)
                let info = try Self.privateInfo(path)
                let lockPath = path + ".owner.lock"
                try Self.createPrivateIfAbsent(lockPath)
                let descriptor = open(lockPath, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else { throw ServiceOwnershipError.unsafeTopology }
                var lockInfo = stat()
                guard fstat(descriptor, &lockInfo) == 0 else { close(descriptor); throw ServiceOwnershipError.unsafeTopology }
                if flock(descriptor, LOCK_EX | LOCK_NB) != 0 { close(descriptor); throw ServiceOwnershipError.alreadyRunning }
                held.append(Held(database: path, lockPath: lockPath, descriptor: descriptor,
                                 databaseDevice: info.st_dev, databaseInode: info.st_ino,
                                 lockDevice: lockInfo.st_dev, lockInode: lockInfo.st_ino))
            }
            try validate()
        } catch { release(); throw error }
    }
    deinit { release() }
    private func release() {
        for item in held.reversed() { _ = flock(item.descriptor, LOCK_UN); close(item.descriptor) }
        held.removeAll()
    }
    /// Only one actor may recover/use each database under this ownership.
    public func claimDatabase(_ path: String) throws {
        capabilityLock.lock(); defer { capabilityLock.unlock() }
        try validate(databasePath: path)
        let physical = try Self.physicalPath(path)
        guard consumed.insert(physical).inserted else { throw ServiceOwnershipError.alreadyRunning }
    }
    public func validate(databasePath: String? = nil) throws {
        guard held.count == 3 else { throw ServiceOwnershipError.unsafeTopology }
        if let databasePath {
            let path = try Self.physicalPath(databasePath)
            guard held.contains(where: { $0.database == path }) else { throw ServiceOwnershipError.unsafeTopology }
        }
        for item in held {
            let database = try Self.privateInfo(item.database)
            let lock = try Self.privateInfo(item.lockPath)
            guard database.st_dev == item.databaseDevice, database.st_ino == item.databaseInode,
                  lock.st_dev == item.lockDevice, lock.st_ino == item.lockInode else { throw ServiceOwnershipError.unsafeTopology }
        }
    }
    private static func physicalPath(_ value: String) throws -> String {
        guard value != ":memory:", !value.isEmpty, !value.utf8.contains(0) else { throw ServiceOwnershipError.unsafeTopology }
        let url = URL(fileURLWithPath: value)
        guard let physical = realpath(url.deletingLastPathComponent().path, nil) else { throw ServiceOwnershipError.unsafeTopology }
        defer { free(physical) }
        return String(cString: physical) + "/" + url.lastPathComponent
    }
    private static func createPrivateIfAbsent(_ path: String) throws {
        var info = stat()
        if lstat(path, &info) == 0 { _ = try privateInfo(path); return }
        guard errno == ENOENT else { throw ServiceOwnershipError.unsafeTopology }
        let descriptor = open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        if descriptor >= 0 { close(descriptor) }
        else if errno != EEXIST { throw ServiceOwnershipError.unsafeTopology }
        _ = try privateInfo(path)
    }
    private static func privateInfo(_ path: String) throws -> stat {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1, (info.st_mode & 0o777) == 0o600 else { throw ServiceOwnershipError.unsafeTopology }
        return info
    }
}
