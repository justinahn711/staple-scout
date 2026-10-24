import Foundation
import XCTest
import CSQLite
import CryptoKit
import ServiceOwnership
import StapleScoutKit
@testable import ClientSessions
@testable import SharedMarketCore
@testable import ProviderBudgets

final class RetentionTests: XCTestCase, @unchecked Sendable {
    let instant = Date(timeIntervalSince1970: 1_792_238_400)
    func context() throws -> PriceContext { try PriceContext(store: .wegmans, storeCode: "133", channel: .inStore) }
    func policy(retention: Double = 172800) throws -> SourcePolicy {
        try SourcePolicy(context: context(), fetchApproved: true, publicServingApproved: true, attribution: "Offline fixture", retention: retention)
    }
    func testKeyedSearchLookupSurvivesReopenAndDoesNotPersistQueryOrProviderMessage() async throws {
        let fixture = try PrivateFixture(); defer { fixture.remove() }
        let clock = RetentionClock(instant)
        let cache = try SharedPriceCache(databasePath: fixture.cache, policies: SourcePolicyRegistry(policies: [policy()]), now: { clock.read() })
        let query = "sensitive-query-marker-46"
        _ = try await cache.search(context: context(), query: query) { RetailSearchPage(candidates: []) }
        _ = try await cache.search(context: context(), query: "partial-private-marker") { RetailSearchPage(candidates: [], message: "partial-private-marker") }
        let storage = try SQLiteStore(path: fixture.cache)
        let keys = try storage.entryKeys()
        XCTAssertEqual(keys.count, 1); XCTAssertFalse(keys.joined().contains(query))
        let payload = try XCTUnwrap(try storage.entry(key: keys[0]))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: payload.data) as? [String: [String]], ["candidates": []])
        let reopened = try SharedPriceCache(databasePath: fixture.cache, policies: SourcePolicyRegistry(policies: [policy()]), now: { clock.read() })
        let hit = try await reopened.search(context: context(), query: "  SENSITIVE-QUERY-MARKER-46  ") { XCTFail("Stable lookup must hit"); return RetailSearchPage(candidates: []) }
        XCTAssertTrue(hit.cacheHit)
        clock.advance(172800)
        _ = try await reopened.sourceStatuses(transportReady: true)
        XCTAssertTrue(try storage.entryKeys().isEmpty)
    }
    func testMissingSchema4SecretFailsClosedWithoutRekeyingClaims() throws {
        let fixture = try PrivateFixture(); defer { fixture.remove() }
        do { _ = try SQLiteStore(path: fixture.cache) }
        try sql(fixture.cache, "DELETE FROM cache_metadata WHERE name = 'lookup_secret'")
        XCTAssertThrowsError(try SQLiteStore(path: fixture.cache))
        XCTAssertEqual(try scalar(fixture.cache, "SELECT COUNT(*) FROM cache_metadata WHERE name = 'lookup_secret'"), 0)
    }
    func testChangedValidFormatLookupKeyFailsClosedWithoutClaimReset() throws {
        let fixture = try PrivateFixture(); defer { fixture.remove() }
        do { _ = try SQLiteStore(path: fixture.cache) }
        let replacement = Data(repeating: 0x44, count: 32).base64EncodedString()
        try sql(fixture.cache, "UPDATE cache_metadata SET value = '" + replacement + "' WHERE name = 'lookup_secret'")
        XCTAssertThrowsError(try SQLiteStore(path: fixture.cache))
    }
    func testMissingCacheClockFailsClosedAfterClaimsWerePruned() async throws {
        let fixture = try PrivateFixture(); defer { fixture.remove() }
        do { _ = try SharedPriceCache(databasePath: fixture.cache, now: { self.instant }) }
        try sql(fixture.cache, "DELETE FROM cache_metadata WHERE name = 'last_seen'")
        XCTAssertThrowsError(try SharedPriceCache(databasePath: fixture.cache, now: { self.instant }))
        XCTAssertEqual(try scalar(fixture.cache, "SELECT COUNT(*) FROM cache_metadata WHERE name = 'last_seen'"), 0)
    }
    func testVersion3MigrationTransformsClaimsAtomicallyWithoutSameDayReplay() async throws {
        let fixture = try PrivateFixture(); defer { fixture.remove() }
        XCTAssertTrue(FileManager.default.createFile(atPath: fixture.cache, contents: nil, attributes: [.posixPermissions: 0o600]))
        let day = try SharedPriceCache.utcDay(instant)
        let raw = String(decoding: try JSONEncoder().encode(["search", "wegmans", "133", "in_store", "legacy-sensitive-46"]), as: UTF8.self)
        let digest = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        try sql(fixture.cache, """
        CREATE TABLE cache_entries (cache_key TEXT PRIMARY KEY NOT NULL, utc_day TEXT NOT NULL, payload BLOB NOT NULL, inserted_at REAL NOT NULL, policy TEXT NOT NULL DEFAULT '');
        CREATE TABLE attempt_claims (cache_key TEXT NOT NULL, utc_day TEXT NOT NULL, PRIMARY KEY(cache_key,utc_day));
        CREATE TABLE attempt_budgets (bucket TEXT NOT NULL, period TEXT NOT NULL, attempts INTEGER NOT NULL, PRIMARY KEY(bucket,period));
        CREATE TABLE scheduled_runs (utc_day TEXT PRIMARY KEY NOT NULL);
        CREATE TABLE source_runs (context TEXT PRIMARY KEY NOT NULL,state TEXT NOT NULL,utc_day TEXT NOT NULL);
        INSERT INTO attempt_claims VALUES ('\(digest)', '\(day)');
        INSERT INTO attempt_budgets VALUES ('day', '\(day)', 1);
        INSERT INTO scheduled_runs VALUES ('\(day)');
        PRAGMA application_id = 1414354243; PRAGMA user_version = 3;
        """)
        XCTAssertThrowsError(try SQLiteStore(path: fixture.cache, bootstrapCheckpoint: { throw RetentionFailure.outage }))
        XCTAssertEqual(try scalar(fixture.cache, "PRAGMA user_version"), 3)
        XCTAssertEqual(try scalar(fixture.cache, "SELECT COUNT(*) FROM attempt_claims WHERE cache_key = '" + digest + "'"), 1)
        let cache = try SharedPriceCache(databasePath: fixture.cache, policies: SourcePolicyRegistry(policies: [policy()]), now: { self.instant })
        do { _ = try await cache.search(context: context(), query: "legacy-sensitive-46") { XCTFail("Atomic rekey must preserve denial"); return RetailSearchPage(candidates: []) }; XCTFail() } catch CacheError.alreadyAttempted {}
        XCTAssertEqual(try scalar(fixture.cache, "PRAGMA user_version"), 4)
        XCTAssertEqual(try scalar(fixture.cache, "SELECT COUNT(*) FROM attempt_claims WHERE cache_key = '" + digest + "'"), 0)
        XCTAssertEqual(try scalar(fixture.cache, "SELECT SUM(attempts) FROM attempt_budgets"), 1)
        let scheduled = try await cache.beginScheduledRun(enabled: true)
        XCTAssertNil(scheduled)
    }
    func testSourceOperationalDatesDoNotRenewOnCacheHitsAndPurgeAtRetention() async throws {
        let clock = RetentionClock(instant)
        let cache = try SharedPriceCache(databasePath: ":memory:", policies: SourcePolicyRegistry(policies: [policy(retention: 60)]), now: { clock.read() })
        _ = try await cache.search(context: context(), query: "empty") { RetailSearchPage(candidates: []) }
        clock.advance(10)
        _ = try await cache.search(context: context(), query: "empty") { XCTFail(); return RetailSearchPage(candidates: []) }
        let ready = try await cache.sourceStatuses(transportReady: true).sources[0]
        XCTAssertEqual(ready.lastAttemptedAt, instant); XCTAssertEqual(ready.lastSucceededAt, instant)
        XCTAssertNil(ready.evidence)
        clock.advance(10)
        do { _ = try await cache.search(context: context(), query: "outage") { throw RetentionFailure.outage }; XCTFail() } catch RetentionFailure.outage {}
        let failed = try await cache.sourceStatuses(transportReady: true).sources[0]
        XCTAssertEqual(failed.lastAttemptedAt, instant.addingTimeInterval(20)); XCTAssertEqual(failed.lastSucceededAt, instant)
        clock.advance(60)
        let expired = try await cache.sourceStatuses(transportReady: true).sources[0]
        XCTAssertNil(expired.lastAttemptedAt); XCTAssertNil(expired.lastSucceededAt)
    }
    func testOldSuccessDateExpiresEvenWhenNewFailuresKeepContextActive() async throws {
        let clock = RetentionClock(instant)
        let cache = try SharedPriceCache(databasePath: ":memory:", policies: SourcePolicyRegistry(policies: [policy(retention: 60)]), now: { clock.read() })
        _ = try await cache.search(context: context(), query: "success") { RetailSearchPage(candidates: []) }
        clock.advance(59)
        do { _ = try await cache.search(context: context(), query: "failure") { throw RetentionFailure.outage }; XCTFail() } catch RetentionFailure.outage {}
        clock.advance(1)
        let status = try await cache.sourceStatuses(transportReady: true).sources[0]
        XCTAssertEqual(status.state, .failed); XCTAssertEqual(status.lastAttemptedAt, instant.addingTimeInterval(59)); XCTAssertNil(status.lastSucceededAt)
    }
    func testExpiredReplayBacklogCannotRevokeCurrentFamily() async throws {
        let fixture = try PrivateFixture(); defer { fixture.remove() }
        let clock = RetentionClock(instant)
        let sessions = try ClientSessionStore(databasePath: fixture.auth, now: { clock.read() })
        let original = try await sessions.enroll(invitation: sessions.issueInvitation().invitation)
        let rotated = try await sessions.rotate(refreshToken: original.refreshToken)
        let db = try SessionSQLite(path: fixture.auth)
        let sessionID = try XCTUnwrap(try db.rows("SELECT session_id FROM auth_sessions").first?["session_id"])
        try db.run("UPDATE auth_refresh_history SET expires_at = ?", [String(instant.timeIntervalSince1970 - 1)])
        // More expired rows than one pruning batch, with the original hash last
        // in rowid order, so it deliberately remains after bounded pruning.
        try db.execute("DELETE FROM auth_refresh_history")
        for index in 0..<5001 {
            try db.run("INSERT INTO auth_refresh_history VALUES (?, ?, ?)", ["expired-fixture-" + String(index), sessionID, String(instant.timeIntervalSince1970 - 1)])
        }
        try db.run("INSERT INTO auth_refresh_history VALUES (?, ?, ?)", [SessionCrypto.hash(original.refreshToken), sessionID, String(instant.timeIntervalSince1970 - 1)])
        do { _ = try await sessions.rotate(refreshToken: original.refreshToken); XCTFail() } catch SessionError.invalidCredential {}
        _ = try await sessions.authenticate(accessToken: rotated.accessToken)
    }
    func testExplicitMaintenanceRequiresOwnerAndPreservesClaimsAcrossPurgeAndRollback() async throws {
        let fixture = try PrivateFixture(); defer { fixture.remove() }
        let clock = RetentionClock(instant)
        let owner = try fixture.owner()
        let cache = try SharedPriceCache(databasePath: fixture.cache, dailyLimit: 1, policies: SourcePolicyRegistry(policies: [policy(retention: 60)]), ownership: owner, now: { clock.read() })
        _ = try await cache.search(context: context(), query: "sensitive") { RetailSearchPage(candidates: []) }
        clock.advance(60); try await cache.purgeRetainedData()
        do { _ = try await cache.search(context: context(), query: "sensitive") { XCTFail(); return RetailSearchPage(candidates: []) }; XCTFail() } catch CacheError.alreadyAttempted {}
        clock.advance(63 * 86400); try await cache.purgeRetainedData()
        _ = try await cache.search(context: context(), query: "today") { RetailSearchPage(candidates: []) }
        clock.advance(-63 * 86400)
        do { _ = try await cache.search(context: context(), query: "rollback") { XCTFail("Purge cannot reopen old daily budgets"); return RetailSearchPage(candidates: []) }; XCTFail() } catch CacheError.budgetExceeded {}
        try owner.validate()
        let unowned = try SharedPriceCache(databasePath: ":memory:")
        do { try await unowned.purgeRetainedData(); XCTFail() } catch CacheError.storage {}
    }
    func testDeleteClientRemovesCredentialsRetainsLifetimeAndCurrentQuotas() async throws {
        let fixture = try PrivateFixture(); defer { fixture.remove() }
        let clock = RetentionClock(instant); let owner = try fixture.owner()
        let sessions = try ClientSessionStore(databasePath: fixture.auth, policy: SessionPolicy(maximumClients: 1), ownership: owner, now: { clock.read() })
        let invite = try await sessions.issueInvitation()
        let original = try await sessions.enroll(invitation: invite.invitation)
        _ = try await sessions.authenticate(accessToken: original.accessToken)
        let rotated = try await sessions.rotate(refreshToken: original.refreshToken)
        try await sessions.purgeRetainedData(deleting: invite.clientID)
        let db = try SessionSQLite(path: fixture.auth)
        XCTAssertEqual(try db.scalar("SELECT COUNT(*) FROM auth_clients WHERE deleted_at IS NOT NULL AND enrolled_at IS NULL"), 1)
        for table in ["auth_invitations", "auth_sessions", "auth_refresh_history"] { XCTAssertEqual(try db.scalar("SELECT COUNT(*) FROM " + table), 0) }
        XCTAssertEqual(try db.scalar("SELECT SUM(attempts) FROM auth_attempts WHERE scope = ?", ["day:requests:" + invite.clientID]), 1)
        for token in [original.accessToken, rotated.accessToken] {
            do { _ = try await sessions.authenticate(accessToken: token); XCTFail() } catch SessionError.invalidCredential {}
        }
        for token in [original.refreshToken, rotated.refreshToken] {
            do { _ = try await sessions.rotate(refreshToken: token); XCTFail() } catch SessionError.invalidCredential {}
        }
        do { _ = try await sessions.enroll(invitation: invite.invitation); XCTFail() } catch SessionError.invitationInvalid {}
        do { _ = try await sessions.issueInvitation(); XCTFail("Deletion cannot recycle a pilot slot") } catch SessionError.clientLimitReached {}
        try await sessions.purgeRetainedData(deleting: invite.clientID)
        try owner.validate()
    }
    func testAuthClockPreventsRollbackRevivalAndRateBucketResetAfterPurge() async throws {
        let fixture = try PrivateFixture(); defer { fixture.remove() }
        let clock = RetentionClock(instant); let owner = try fixture.owner()
        let sessions = try ClientSessionStore(databasePath: fixture.auth, policy: SessionPolicy(clientDailyRequests: 1), ownership: owner, now: { clock.read() })
        let tokens = try await sessions.enroll(invitation: sessions.issueInvitation().invitation)
        _ = try await sessions.authenticate(accessToken: tokens.accessToken)
        clock.advance(86400)
        let fresh = try await sessions.rotate(refreshToken: tokens.refreshToken)
        _ = try await sessions.authenticate(accessToken: fresh.accessToken)
        try await sessions.purgeRetainedData()
        clock.advance(-86400)
        do { _ = try await sessions.authenticate(accessToken: fresh.accessToken); XCTFail() } catch SessionError.rateLimited {}
        do { _ = try await sessions.authenticate(accessToken: tokens.accessToken); XCTFail() } catch SessionError.invalidCredential {}
        clock.advance(32 * 86400); try await sessions.purgeRetainedData()
        let db = try SessionSQLite(path: fixture.auth)
        XCTAssertEqual(try db.scalar("SELECT COUNT(*) FROM auth_sessions"), 0)
        XCTAssertEqual(try db.scalar("SELECT COUNT(*) FROM auth_refresh_history"), 0)
        XCTAssertEqual(try db.scalar("SELECT COUNT(*) FROM auth_clients"), 1)
    }
    func testProviderPurgeRetainsPendingAndUncertainChargesAndLifetimeClient() async throws {
        let fixture = try PrivateFixture(); defer { fixture.remove() }
        let clock = RetentionClock(instant); let owner = try fixture.owner()
        let sessions = try ClientSessionStore(databasePath: fixture.auth, ownership: owner, now: { clock.read() })
        let tokens = try await sessions.enroll(invitation: sessions.issueInvitation().invitation)
        let principal = try await sessions.authenticate(accessToken: tokens.accessToken)
        let limits = try ProviderBudgetPolicy(providerHourly: 10, providerDaily: 10, providerMonthly: 10, clientDaily: 10, clientMonthly: 10, globalMissesDaily: 10, globalMissesMonthly: 10, clientMissesDaily: 10, clientMissesMonthly: 10)
        let ledger = try ProviderBudgetLedger(databasePath: fixture.provider, policy: limits, ownership: owner, now: { clock.read() })
        let (lease, unit) = try await ledger.admit(principal: principal)
        try await sessions.purgeRetainedData(deleting: tokens.clientID)
        let retainedAfterDeletion = try await ledger.usage(for: principal)
        XCTAssertTrue(retainedAfterDeletion.windows.allSatisfy { $0.reserved == 1 && $0.pending == 1 })
        clock.advance(63 * 86400); try await ledger.purgeRetainedData()
        var usage = try await ledger.usage(for: principal)
        XCTAssertTrue(usage.windows.allSatisfy { $0.reserved == 1 && $0.pending == 1 })
        try await ledger.complete(unit, receivedSuccess: false); try await ledger.endMiss(lease)
        try await ledger.purgeRetainedData()
        usage = try await ledger.usage(for: principal)
        XCTAssertTrue(usage.windows.allSatisfy { $0.reserved == 1 && $0.pending == 0 })
        clock.advance(63 * 86400); try await ledger.purgeRetainedData()
        let db = try BudgetSQLite(path: fixture.provider)
        XCTAssertEqual(try db.scalar("SELECT COUNT(*) FROM budget_reservations"), 0)
        XCTAssertEqual(try db.scalar("SELECT COUNT(*) FROM budget_misses"), 0)
        XCTAssertEqual(try db.scalar("SELECT COUNT(*) FROM budget_clients"), 1)
        try owner.validate()
    }
    func testActualMaintenanceCLIDeletesExistingClientWithoutResettingSlot() async throws {
        let fixture = try PrivateFixture(); defer { fixture.remove() }
        let sessions = try ClientSessionStore(databasePath: fixture.auth, policy: SessionPolicy(maximumClients: 1))
        let invite = try await sessions.issueInvitation()
        let tokens = try await sessions.enroll(invitation: invite.invitation)
        let process = Process(); process.executableURL = try maintenanceBinary()
        process.arguments = ["delete-client", invite.clientID]
        var environment = ProcessInfo.processInfo.environment
        environment["THRIFTY_AUTH_DATABASE_PATH"] = fixture.auth
        environment["THRIFTY_DATABASE_PATH"] = fixture.cache
        environment["THRIFTY_PROVIDER_DATABASE_PATH"] = fixture.provider
        process.environment = environment
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run(); process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0); XCTAssertTrue(output.contains("Logical maintenance completed"))
        for secret in [invite.invitation, tokens.accessToken, tokens.refreshToken, invite.clientID, fixture.directory.path] { XCTAssertFalse(output.contains(secret)) }
        do { _ = try await sessions.authenticate(accessToken: tokens.accessToken); XCTFail() } catch SessionError.invalidCredential {}
        do { _ = try await sessions.issueInvitation(); XCTFail() } catch SessionError.clientLimitReached {}
        let db = try SessionSQLite(path: fixture.auth)
        XCTAssertEqual(try db.scalar("SELECT COUNT(*) FROM auth_clients"), 1)
        XCTAssertEqual(try db.scalar("SELECT COUNT(*) FROM auth_sessions"), 0)
    }
    func testActualMaintenanceCLIRejectsActiveOwnerAndRedactsArguments() async throws {
        let fixture = try PrivateFixture(); defer { fixture.remove() }
        let owner = try fixture.owner()
        let process = Process(); process.executableURL = try maintenanceBinary()
        process.arguments = ["delete-client", "synthetic-sensitive-marker-46"]
        var environment = ProcessInfo.processInfo.environment
        environment["THRIFTY_AUTH_DATABASE_PATH"] = fixture.auth
        environment["THRIFTY_DATABASE_PATH"] = fixture.cache
        environment["THRIFTY_PROVIDER_DATABASE_PATH"] = fixture.provider
        process.environment = environment
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run(); process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertFalse(output.contains("synthetic-sensitive-marker-46")); XCTAssertFalse(output.contains(fixture.directory.path))
        try owner.validate()
    }
    private func maintenanceBinary() throws -> URL {
        var directory = Bundle(for: RetentionTests.self).bundleURL
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("ThriftyMarketMaintenance")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        return try XCTUnwrap(nil as URL?, "swift test must build the maintenance product")
    }
    private func sql(_ path: String, _ sql: String) throws {
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK); defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }
    private func scalar(_ path: String, _ sql: String) throws -> Int {
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK); defer { sqlite3_close(db) }
        var statement: OpaquePointer?; XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK); defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW); return Int(sqlite3_column_int64(statement, 0))
    }
}
private enum RetentionFailure: Error { case outage }
private final class RetentionClock: @unchecked Sendable {
    let lock = NSLock(); var date: Date
    init(_ date: Date) { self.date = date }
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ amount: Double) { lock.lock(); defer { lock.unlock() }; date += amount }
}
private struct PrivateFixture {
    let directory: URL
    var auth: String { directory.appendingPathComponent("auth.sqlite").path }
    var cache: String { directory.appendingPathComponent("cache.sqlite").path }
    var provider: String { directory.appendingPathComponent("provider.sqlite").path }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("retention-46-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func owner() throws -> ServiceOwnership { try ServiceOwnership(databasePaths: [auth, cache, provider]) }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
