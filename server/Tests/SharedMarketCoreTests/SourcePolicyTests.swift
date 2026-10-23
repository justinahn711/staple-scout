import Foundation
import XCTest
import StapleScoutKit
import CSQLite
@testable import SharedMarketCore

final class SourcePolicyTests: XCTestCase, @unchecked Sendable {
    let instant = Date(timeIntervalSince1970: 1_792_238_400)
    func context() throws -> PriceContext { try PriceContext(store: .wegmans, storeCode: "133", channel: .inStore) }
    func policy(approved: Bool = true, cache: Double = 172800, display: Double = 172800, age: Double = 172800, retention: Double = 172800) throws -> SourcePolicy {
        try SourcePolicy(context: context(), fetchApproved: approved, publicServingApproved: approved, attribution: "Offline fixture only", cacheTTL: cache, displayTTL: display, maximumObservationAge: age, retention: retention)
    }
    func value(at date: Date, id: String = "123") -> FetchedPrice {
        FetchedPrice(productID: id, productName: "Fixture", price: 2, quantity: 1, unit: .each, available: nil,
                     observedAt: date.addingTimeInterval(-10), retrievedAt: date, conditions: "Fixture condition",
                     source: .wegmans, sourceURL: "https://www.wegmans.com/api/products/133/\(id)")
    }
    func testDefaultDeniesEvenInjectedFetchAndStatusIsNotPersonalCapability() async throws {
        let cache = try SharedPriceCache(databasePath: ":memory:", now: { self.instant })
        do { _ = try await cache.price(context: context(), productID: "123") { XCTFail("Unapproved fetch"); return self.value(at: self.instant) }; XCTFail() }
        catch CacheError.sourceDisabled {}
        let status = try await cache.sourceStatuses(transportReady: true)
        XCTAssertEqual(status.schemaVersion, 1); XCTAssertEqual(status.sources.count, 5)
        XCTAssertTrue(status.sources.allSatisfy { $0.state == .disabled && !$0.fetchingEnabled && !$0.publicAccessApproved })
        XCTAssertEqual(status.sources.first { $0.store == .walmart }?.channel, .pickup)
        XCTAssertEqual(status.sources.first { $0.store == .target }?.channelVerified, false)
        XCTAssertEqual(status.sources.first { $0.store == .hmart }?.referenceOnly, true)
    }
    func testWithdrawalPurgesHitAndReapprovalCannotResurrectOrReplay() async throws {
        let registry = try SourcePolicyRegistry(policies: [policy()])
        let cache = try SharedPriceCache(databasePath: ":memory:", policies: registry, now: { self.instant })
        _ = try await cache.price(context: context(), productID: "123") { self.value(at: self.instant) }
        try await cache.replacePolicy(policy(approved: false))
        do { _ = try await cache.price(context: context(), productID: "123") { XCTFail(); return self.value(at: self.instant) }; XCTFail() }
        catch CacheError.sourceDisabled {}
        try await cache.replacePolicy(policy())
        do { _ = try await cache.price(context: context(), productID: "123") { XCTFail("Daily tombstone survives purge"); return self.value(at: self.instant) }; XCTFail() }
        catch CacheError.alreadyAttempted {}
    }
    func testWithdrawAndReapproveInvalidatesAnOldLeaderAndFollower() async throws {
        let cache = try SharedPriceCache(databasePath: ":memory:", policies: SourcePolicyRegistry(policies: [policy()]), now: { self.instant })
        let gate = PolicyGate()
        let first = Task { try await cache.price(context: self.context(), productID: "123") { await gate.wait(); return self.value(at: self.instant) } }
        await gate.entered()
        let follower = Task { try await cache.price(context: self.context(), productID: "123") { XCTFail(); return self.value(at: self.instant) } }
        await Task.yield()
        try await cache.replacePolicy(policy(approved: false)); try await cache.replacePolicy(policy())
        await gate.release()
        for task in [first, follower] {
            do { _ = try await task.value; XCTFail("Prior approval cannot publish") }
            catch CacheError.sourceDisabled {} catch CacheError.alreadyAttempted {}
        }
    }
    func testFailedPolicyPurgeLeavesServingDeniedAndInvalidatesPausedWork() async throws {
        let cache = try SharedPriceCache(databasePath: ":memory:", policies: SourcePolicyRegistry(policies: [policy()]), now: { self.instant })
        _ = try await cache.price(context: context(), productID: "123") { self.value(at: self.instant) }
        let gate = PolicyGate()
        let paused = Task { try await cache.price(context: self.context(), productID: "456") { await gate.wait(); return self.value(at: self.instant, id: "456") } }
        await gate.entered()
        do { try await cache.replacePolicy(policy(approved: false), purgeCheckpoint: { throw CacheError.storage("Injected failure") }); XCTFail() }
        catch CacheError.storage {}
        do { _ = try await cache.price(context: context(), productID: "123") { XCTFail(); return self.value(at: self.instant) }; XCTFail() }
        catch CacheError.sourceDisabled {}
        await gate.release()
        do { _ = try await paused.value; XCTFail() } catch CacheError.sourceDisabled {}
        let deniedStatus = try await cache.sourceStatuses(transportReady: true).sources[0]
        XCTAssertEqual(deniedStatus.state, .disabled)
    }
    func testLateOldApprovalFailureDoesNotOverwriteNewApprovalReadyState() async throws {
        let cache = try SharedPriceCache(databasePath: ":memory:", policies: SourcePolicyRegistry(policies: [policy()]), now: { self.instant })
        let gate = PolicyGate()
        let paused = Task { try await cache.price(context: self.context(), productID: "123") { await gate.wait(); throw PolicyFailure.outage } }
        await gate.entered()
        try await cache.replacePolicy(policy())
        _ = try await cache.price(context: context(), productID: "456") { self.value(at: self.instant, id: "456") }
        await gate.release(); _ = try? await paused.value
        let status = try await cache.sourceStatuses(transportReady: true).sources[0]
        XCTAssertEqual(status.state, .ready)
    }
    func testEmptySearchPageExpiresAtStrictCacheTTLAndPartialOutagePersistStates() async throws {
        let clock = PolicyClock(instant)
        let cache = try SharedPriceCache(databasePath: ":memory:", policies: SourcePolicyRegistry(policies: [policy(cache: 60)]), now: { clock.read() })
        _ = try await cache.search(context: context(), query: "empty") { RetailSearchPage(candidates: []) }
        clock.advance(60)
        do { _ = try await cache.search(context: context(), query: "empty") { XCTFail(); return RetailSearchPage(candidates: []) }; XCTFail() }
        catch CacheError.alreadyAttempted {}
        _ = try await cache.search(context: context(), query: "partial") { RetailSearchPage(candidates: [], message: "Fixture incomplete") }
        let partial = try await cache.sourceStatuses(transportReady: true).sources[0]
        XCTAssertEqual(partial.state, .partial)
        do { _ = try await cache.search(context: context(), query: "outage") { throw PolicyFailure.outage }; XCTFail() } catch PolicyFailure.outage {}
        let failed = try await cache.sourceStatuses(transportReady: true).sources[0]
        XCTAssertEqual(failed.state, .failed)
    }
    func testEachFreshnessLimitAndOfferBoundaryIsStrictWithoutTimestampRenewal() async throws {
        for limit in 0..<4 {
            let clock = PolicyClock(instant)
            let p = try policy(cache: limit == 0 ? 100 : 172800, display: limit == 1 ? 100 : 172800, age: limit == 2 ? 110 : 172800)
            let cache = try SharedPriceCache(databasePath: ":memory:", policies: SourcePolicyRegistry(policies: [p]), now: { clock.read() })
            var evidence = value(at: instant)
            if limit == 3 { evidence.validUntil = instant.addingTimeInterval(100) }
            let original = evidence
            _ = try await cache.price(context: context(), productID: "123") { original }
            clock.advance(99)
            let hit = try await cache.price(context: context(), productID: "123") { XCTFail(); return original }
            XCTAssertTrue(hit.cacheHit); XCTAssertEqual(hit.value.observedAt, original.observedAt)
            clock.advance(1)
            do { _ = try await cache.price(context: context(), productID: "123") { XCTFail(); return original }; XCTFail("Boundary is exclusive") }
            catch CacheError.alreadyAttempted {}
            let status = try await cache.sourceStatuses(transportReady: true)
            XCTAssertEqual(status.sources.first?.state, .stale)
        }
    }
    func testSuccessfulSearchOnlyReportsOriginalDatesAndTransportReadiness() async throws {
        let cache = try SharedPriceCache(databasePath: ":memory:", policies: SourcePolicyRegistry(policies: [policy()]), now: { self.instant })
        let original = value(at: instant)
        _ = try await cache.search(context: context(), query: "fixture") { RetailSearchPage(candidates: [original]) }
        let ready = try await cache.sourceStatuses(transportReady: true).sources[0]
        XCTAssertEqual(ready.state, .ready); XCTAssertEqual(ready.evidence?.observedAt, original.observedAt)
        let disconnected = try await cache.sourceStatuses(transportReady: false).sources[0]
        XCTAssertEqual(disconnected.state, .disabled); XCTAssertFalse(disconnected.fetchingEnabled)
    }
    func testLateYesterdayFailureAndPartialCannotReplaceTodayReadyStatus() async throws {
        for partial in [false, true] {
            let clock = PolicyClock(instant)
            let cache = try SharedPriceCache(databasePath: ":memory:", policies: SourcePolicyRegistry(policies: [policy()]), now: { clock.read() })
            let gate = PolicyGate()
            let old = Task {
                try await cache.search(context: self.context(), query: "fixture") {
                    await gate.wait()
                    if !partial { throw PolicyFailure.outage }
                    return RetailSearchPage(candidates: [], message: "Incomplete fixture")
                }
            }
            await gate.entered(); clock.advance(86400)
            let current = value(at: clock.read())
            _ = try await cache.search(context: context(), query: "fixture") { RetailSearchPage(candidates: [current]) }
            await gate.release(); _ = try? await old.value
            let status = try await cache.sourceStatuses(transportReady: true).sources[0]
            XCTAssertEqual(status.state, .ready); XCTAssertEqual(status.evidence?.observedAt, current.observedAt)
        }
    }
    func testRetentionPurgesSearchKeysButKeepsOpaqueDailyTombstone() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("policy-retention-\(UUID()).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let clock = PolicyClock(instant)
        let cache = try SharedPriceCache(databasePath: path, policies: SourcePolicyRegistry(policies: [policy(retention: 60)]), now: { clock.read() })
        _ = try await cache.search(context: context(), query: "private-looking-query") { RetailSearchPage(candidates: [self.value(at: self.instant)]) }
        clock.advance(60); _ = try await cache.sourceStatuses(transportReady: true)
        let storage = try SQLiteStore(path: path)
        XCTAssertTrue(try storage.entryKeys().isEmpty)
        do { _ = try await cache.search(context: context(), query: "private-looking-query") { XCTFail("Hash claim must persist"); return RetailSearchPage(candidates: []) }; XCTFail() }
        catch CacheError.alreadyAttempted {}
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK); defer { sqlite3_close(db) }
        var statement: OpaquePointer?; XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT cache_key FROM attempt_claims", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }; XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        let key = String(cString: sqlite3_column_text(statement, 0)); XCTAssertEqual(key.count, 64); XCTAssertFalse(key.contains("private"))
    }
    func testInterruptedAtomicBootstrapReopensAndRejectsUnrelatedSchema() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("policy-bootstrap-\(UUID()).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        XCTAssertThrowsError(try SQLiteStore(path: path, bootstrapCheckpoint: { throw PolicyFailure.outage }))
        let reopened = try SQLiteStore(path: path)
        XCTAssertTrue(try reopened.entryKeys().isEmpty)
        let unrelated = path + ".unrelated"
        defer { try? FileManager.default.removeItem(atPath: unrelated) }
        XCTAssertTrue(FileManager.default.createFile(atPath: unrelated, contents: nil, attributes: [.posixPermissions: 0o600]))
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(unrelated, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE unrelated (secret TEXT); INSERT INTO unrelated VALUES ('untouched')", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        XCTAssertThrowsError(try SQLiteStore(path: unrelated))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unrelated + "-wal"))
        XCTAssertEqual(sqlite3_open(unrelated, &db), SQLITE_OK)
        var statement: OpaquePointer?; XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT secret FROM unrelated", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "untouched")
        sqlite3_finalize(statement); sqlite3_close(db)
    }
    func testLegacySchemaMigrationRollsBackThenPreservesHashedDailyClaimsAndBudgets() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("policy-legacy-\(UUID()).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]))
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        let day = try SharedPriceCache.utcDay(instant)
        let rawKey = String(decoding: try JSONEncoder().encode(["search", "wegmans", "133", "in_store", "legacy private query"]), as: UTF8.self)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE cache_entries (cache_key TEXT PRIMARY KEY NOT NULL, utc_day TEXT NOT NULL, payload BLOB NOT NULL, inserted_at REAL NOT NULL); CREATE TABLE attempt_claims (cache_key TEXT NOT NULL, utc_day TEXT NOT NULL, PRIMARY KEY(cache_key, utc_day)); CREATE TABLE attempt_budgets (bucket TEXT NOT NULL, period TEXT NOT NULL, attempts INTEGER NOT NULL CHECK(attempts >= 0), PRIMARY KEY(bucket, period)); PRAGMA user_version = 1", nil, nil, nil), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO attempt_claims VALUES (?, ?)", -1, &statement, nil), SQLITE_OK)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, rawKey, -1, transient); sqlite3_bind_text(statement, 2, day, -1, transient)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE); sqlite3_finalize(statement)
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO attempt_budgets VALUES ('day', '\(day)', 1); INSERT INTO cache_entries VALUES ('raw-old-query', '\(day)', X'7B7D', \(instant.timeIntervalSince1970))", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        XCTAssertThrowsError(try SQLiteStore(path: path, bootstrapCheckpoint: { throw PolicyFailure.outage }))
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT cache_key FROM attempt_claims", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), rawKey)
        sqlite3_finalize(statement); sqlite3_close(db)
        let cache = try SharedPriceCache(databasePath: path, policies: SourcePolicyRegistry(policies: [policy()]), now: { self.instant })
        do { _ = try await cache.search(context: context(), query: "legacy private query") { XCTFail("Migrated claims cannot replay"); return RetailSearchPage(candidates: []) }; XCTFail() }
        catch CacheError.alreadyAttempted {}
        let storage = try SQLiteStore(path: path); XCTAssertTrue(try storage.entryKeys().isEmpty)
        do { try storage.claim(key: "different", day: day, month: String(day.prefix(7)), dailyLimit: 1, monthlyLimit: 250); XCTFail("Prior budget survives") }
        catch CacheError.budgetExceeded {}
    }

    func testShutdownCancelsLeaderAndRejectsSubsequentHitsOrMisses() async throws {
        let cache = try SharedPriceCache(databasePath: ":memory:", policies: SourcePolicyRegistry(policies: [policy()]), now: { self.instant })
        let gate = PolicyGate()
        let task = Task { try await cache.price(context: self.context(), productID: "123") { await gate.wait(); try Task.checkCancellation(); return self.value(at: self.instant) } }
        await gate.entered()
        let shutdown = Task { await cache.shutdown() }
        await Task.yield(); await gate.release(); await shutdown.value
        _ = try? await task.value
        do { _ = try await cache.price(context: context(), productID: "123") { XCTFail(); return self.value(at: self.instant) }; XCTFail() }
        catch CacheError.shuttingDown {}
    }
    func testHMartRejectsCredentialOrUnknownQueryMember() async throws {
        let context = try PriceContext(store: .hmart, storeCode: nil, channel: .online)
        let policy = try SourcePolicy(context: context, fetchApproved: true, publicServingApproved: true, attribution: "Offline fixture")
        let cache = try SharedPriceCache(databasePath: ":memory:", policies: SourcePolicyRegistry(policies: [policy]), now: { self.instant })
        var value = value(at: instant, id: "123:456"); value.source = .hmart
        value.sourceURL = "https://www.hmart.com/api/catalog_system/pub/products/search/?fq=productId:123&token=private"
        value.sourceExclusion = "Online only"; let bad = value
        do { _ = try await cache.price(context: context, productID: "123:456") { bad }; XCTFail() }
        catch CacheError.invalidEvidence {}
    }
}
private enum PolicyFailure: Error { case outage }
private final class PolicyClock: @unchecked Sendable {
    let lock = NSLock(); var date: Date
    init(_ date: Date) { self.date = date }
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ amount: Double) { lock.lock(); defer { lock.unlock() }; date += amount }
}
private actor PolicyGate {
    var waiting = false; var open = false
    var enterWaiters: [CheckedContinuation<Void, Never>] = []; var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { waiting = true; for c in enterWaiters { c.resume() }; enterWaiters.removeAll(); if !open { await withCheckedContinuation { waiters.append($0) } } }
    func entered() async { if !waiting { await withCheckedContinuation { enterWaiters.append($0) } } }
    func release() { open = true; for c in waiters { c.resume() }; waiters.removeAll() }
}
