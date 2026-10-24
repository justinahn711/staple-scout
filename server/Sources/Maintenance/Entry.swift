import Foundation
import Darwin
import ServiceOwnership
import ClientSessions
import SharedMarketCore
import ProviderBudgets

/// One-shot, stopped-service operator maintenance. No remote route or scheduler.
@main
enum Maintenance {
    static func main() async {
        do { try await run() }
        catch {
            // Never echo arguments, database paths or arbitrary SQLite errors.
            FileHandle.standardError.write(Data("Maintenance failed. Stop the service and check the documented command and private database paths. No completed deletion is claimed.\n".utf8))
            exit(1)
        }
    }
    private static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments == ["purge"] || (arguments.count == 2 && arguments[0] == "delete-client") else { throw SessionError.invalidRequest }
        let environment = ProcessInfo.processInfo.environment
        let auth = environment["THRIFTY_AUTH_DATABASE_PATH"] ?? "data/client-sessions.sqlite"
        let cachePath = environment["THRIFTY_DATABASE_PATH"] ?? "data/shared-prices.sqlite"
        let provider = environment["THRIFTY_PROVIDER_DATABASE_PATH"] ?? "data/provider-budgets.sqlite"
        umask(0o077)
        // Locks validate existing stable file identities and reject any running
        // service before an actor opens SQLite or performs deletion/recovery.
        let ownership = try ServiceOwnership(databasePaths: [auth, cachePath, provider])
        let sessions = try ClientSessionStore(databasePath: auth, ownership: ownership)
        let cache = try SharedPriceCache(databasePath: cachePath, ownership: ownership)
        let ledger = try ProviderBudgetLedger(databasePath: provider, ownership: ownership)
        try await sessions.purgeRetainedData(deleting: arguments.count == 2 ? arguments[1] : nil)
        try await cache.purgeRetainedData()
        try await ledger.purgeRetainedData()
        try ownership.validate()
        print("Logical maintenance completed. Protected quota and lifetime tombstones remain. Backups and previously copied files are not erased.")
    }
}
