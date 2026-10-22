import Foundation
import MarketHTTP
import SharedMarketCore
import ClientSessions
import Darwin
import Vapor

@main
enum Entry {
    static func main() async throws {
        // Prevent Vapor's CLI hostname option from changing the local-only boundary.
        guard CommandLine.arguments.count == 1 else { throw ConfigurationError.invalid("Configure this local prototype through THRIFTY_* environment variables, without CLI arguments.") }
        let environment = ProcessInfo.processInfo.environment
        guard environment["THRIFTY_ACCESS_TOKEN"] == nil else { throw ConfigurationError.invalid("The global developer token is no longer supported. Use an operator-issued client invitation.") }
        umask(0o077)
        let mode = environment["THRIFTY_SOURCE_MODE"] ?? "disabled"
        guard ["disabled", "local-research"].contains(mode) else { throw ConfigurationError.invalid("THRIFTY_SOURCE_MODE must be disabled or local-research.") }
        func integer(_ key: String, fallback: Int, range: ClosedRange<Int>) throws -> Int {
            guard let value = environment[key] else { return fallback }
            guard let number = Int(value), range.contains(number) else { throw ConfigurationError.invalid("Invalid \(key).") }
            return number
        }
        let port = try integer("THRIFTY_PORT", fallback: 8878, range: 1024...65535)
        let daily = try integer("THRIFTY_DAILY_LIMIT", fallback: 50, range: 0...50)
        let monthly = try integer("THRIFTY_MONTHLY_LIMIT", fallback: 250, range: 0...250)
        let path = environment["THRIFTY_DATABASE_PATH"] ?? "data/shared-prices.sqlite"
        let authPath = environment["THRIFTY_AUTH_DATABASE_PATH"] ?? "data/client-sessions.sqlite"
        guard path != ":memory:" else { throw ConfigurationError.invalid("The running service requires a persistent database path.") }
        try SessionDatabasePaths.validate(authPath: authPath, cachePath: path)
        for database in [path, authPath] {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: database).deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let sessions = try ClientSessionStore(databasePath: authPath)
        let cache = try SharedPriceCache(databasePath: path, dailyLimit: daily, monthlyLimit: monthly)
        let service = MarketService(cache: cache, sessions: sessions, upstream: mode == "local-research" ? LocalResearchUpstream() : nil)
        let app = try await Application.make(.development)
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = port
        service.configure(app)
        do { try await app.execute() }
        catch { try? await app.asyncShutdown(); throw error }
        try await app.asyncShutdown()
    }
    private enum ConfigurationError: Error { case invalid(String) }
}
