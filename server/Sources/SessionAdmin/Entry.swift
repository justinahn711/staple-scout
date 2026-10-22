import Foundation
import ClientSessions
import Darwin

/// Local operator capability. No admin credential or mint/revoke HTTP route.
@main
enum SessionAdmin {
    static func main() async {
        do { try await run() }
        catch {
            // Never stringify arbitrary errors or arguments: a misplaced secret
            // must not turn into a diagnostic or shell-history example.
            FileHandle.standardError.write(Data("Session administration failed. Check the documented command, private paths, and client capacity.\n".utf8))
            exit(1)
        }
    }
    private static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2, ["invite", "revoke"].contains(arguments[0]) else { throw SessionError.invalidRequest }
        let environment = ProcessInfo.processInfo.environment
        let authPath = environment["THRIFTY_AUTH_DATABASE_PATH"] ?? "data/client-sessions.sqlite"
        let cachePath = environment["THRIFTY_DATABASE_PATH"] ?? "data/shared-prices.sqlite"
        try SessionDatabasePaths.validate(authPath: authPath, cachePath: cachePath)
        umask(0o077)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: authPath).deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let sessions = try ClientSessionStore(databasePath: authPath)
        if arguments[0] == "revoke" {
            try await sessions.revoke(clientID: arguments[1])
            print("Client revoked.")
            return
        }
        // Never print an invitation in terminal/server logs. The destination
        // must be new; no symlink following or accidental overwrite is allowed.
        let descriptor = open(arguments[1], O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SessionError.invalidRequest }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var finished = false
        defer { try? handle.close(); if !finished { try? FileManager.default.removeItem(atPath: arguments[1]) } }
        let invitation = try await sessions.issueInvitation()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try handle.write(contentsOf: encoder.encode(invitation))
        try handle.synchronize()
        finished = true
        print("Invitation file created. Transfer it privately; its credential expires after one day and can be redeemed once.")
    }
}
