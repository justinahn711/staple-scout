import Foundation
import XCTest
import StapleScoutKit
@testable import SharedMarketCore

final class SharedPriceCacheTests: XCTestCase, @unchecked Sendable {
    private let instant = Date(timeIntervalSince1970: 1_792_238_400) // 2026-10-17 12:00 UTC
    private func wegmans() throws -> PriceContext { try PriceContext(store: .wegmans, storeCode: "133", channel: .inStore) }
    private func hmart() throws -> PriceContext { try PriceContext(store: .hmart, storeCode: nil, channel: .online) }

    func testContextRejectsUnsupportedAndDecodedContexts() throws {
        XCTAssertEqual(try wegmans().location.id, StoreLocation.defaults.first { $0.store == .wegmans }?.id)
        XCTAssertThrowsError(try PriceContext(store: .wegmans, storeCode: "133", channel: .online))
        XCTAssertThrowsError(try PriceContext(store: .wegmans, storeCode: "0133", channel: .inStore))
        XCTAssertThrowsError(try PriceContext(store: .hmart, storeCode: "", channel: .online))
        XCTAssertThrowsError(try PriceContext(store: .lidl, storeCode: "US01112", channel: .pickup))
        XCTAssertThrowsError(try PriceContext(store: .target, storeCode: "1827", channel: .inStore))
        XCTAssertThrowsError(try PriceContext(store: .walmart, storeCode: "5969", channel: .inStore))
        let invalid = Data(#"{"store":"wegmans","storeCode":"134","channel":"in_store"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(PriceContext.self, from: invalid))
        XCTAssertEqual(try JSONDecoder().decode(PriceContext.self, from: JSONEncoder().encode(hmart())), try hmart())
    }

    func testTwentyConcurrentIdenticalRequestsCoalesce() async throws {
        let clock = TestClock(instant)
        let cache = try SharedPriceCache(databasePath: ":memory:", now: { clock.read() })
        let counter = Counter()
        let gate = Gate()
        let context = try wegmans()
        let value = fixture(at: instant)
        let requests = Task {
            try await withThrowingTaskGroup(of: CachedPrice.self) { group in
                for _ in 0..<20 {
                    group.addTask {
                        try await cache.price(context: context, productID: "123") {
                            await counter.increment()
                            await gate.enterAndWait()
                            return value
                        }
                    }
                }
                var results: [CachedPrice] = []
                for try await result in group { results.append(result) }
                return results
            }
        }
        await gate.waitUntilEntered()
        await gate.open()
        let results = try await requests.value
        XCTAssertEqual(results.count, 20)
        await assertCount(counter, 1)
        XCTAssertEqual(results.filter { !$0.cacheHit }.count, 1)
        XCTAssertTrue(results.allSatisfy { $0.value.observedAt == value.observedAt })
    }

    func testStoreChannelKeysAndSearchNormalizationDoNotShareEvidence() async throws {
        let cache = try SharedPriceCache(databasePath: ":memory:", now: { self.instant })
        let counter = Counter()
        let first = fixture(at: instant)
        let second = fixture(id: "123:456", store: .hmart, at: instant)
        _ = try await cache.price(context: wegmans(), productID: "123") { await counter.increment(); return first }
        _ = try await cache.price(context: hmart(), productID: "123:456") { await counter.increment(); return second }
        var regional = fixture(store: .lidl, at: instant)
        regional.validFrom = instant.addingTimeInterval(-3_600)
        regional.validUntil = instant.addingTimeInterval(3_600)
        regional.sourceExclusion = "Lidl local stock is unknown."
        let third = regional
        let lidl = try PriceContext(store: .lidl, storeCode: "US01112", channel: .inStore)
        let separateStore = try await cache.price(context: lidl, productID: "123") { await counter.increment(); return third }
        XCTAssertFalse(separateStore.cacheHit)
        XCTAssertEqual(separateStore.value.source, .lidl)
        let search = try await cache.search(context: wegmans(), query: "  Whole   MILK ") {
            await counter.increment(); return RetailSearchPage(candidates: [first])
        }
        XCTAssertFalse(search.cacheHit)
        let normalized = try await cache.search(context: wegmans(), query: "whole milk") { XCTFail("Normalized query should share the page"); return RetailSearchPage(candidates: []) }
        XCTAssertTrue(normalized.cacheHit)
        await assertCount(counter, 4)
    }

    func testRestartPreservesEveryFieldAndOriginalDates() async throws {
        let path = temporaryDatabase()
        defer { removeDatabase(path) }
        let clock = TestClock(instant)
        var original = fixture(at: instant.addingTimeInterval(-600))
        original.price = nil
        original.quantity = nil
        original.unit = nil
        original.available = nil
        original.quantityKind = .variable
        original.barcode = "0000123"
        original.packCount = 3
        original.conditions = "Club pricing; unknown local stock."
        original.sourceExclusion = "Package size is unknown."
        original.validFrom = instant.addingTimeInterval(-3_600)
        original.validUntil = instant.addingTimeInterval(3_600)
        let payload = original
        let first = try SharedPriceCache(databasePath: path, now: { clock.read() })
        let initial = try await first.price(context: wegmans(), productID: "123") { payload }
        XCTAssertFalse(initial.cacheHit)
        clock.advance(300)
        let restarted = try SharedPriceCache(databasePath: path, now: { clock.read() })
        let saved = try await restarted.price(context: wegmans(), productID: "123") { XCTFail("Restart should use persisted evidence"); return payload }
        XCTAssertTrue(saved.cacheHit)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(saved.value), try encoder.encode(payload))
        XCTAssertEqual(saved.value.retrievedAt, payload.retrievedAt)
        XCTAssertEqual(saved.value.observedAt, payload.observedAt)
        XCTAssertNil(saved.value.available)
        XCTAssertNil(saved.value.price)
    }

    func testRestartFailureCannotReplayUntilNextUTCDay() async throws {
        let path = temporaryDatabase()
        defer { removeDatabase(path) }
        let clock = TestClock(instant)
        let counter = Counter()
        let context = try wegmans()
        let first = try SharedPriceCache(databasePath: path, now: { clock.read() })
        do {
            _ = try await first.price(context: context, productID: "123") { await counter.increment(); throw SampleFailure.upstream }
            XCTFail("Fetch should fail")
        } catch SampleFailure.upstream {} catch { XCTFail("Unexpected error: \(error)") }
        let restarted = try SharedPriceCache(databasePath: path, now: { clock.read() })
        do {
            _ = try await restarted.price(context: context, productID: "123") { await counter.increment(); return self.fixture(at: clock.read()) }
            XCTFail("A failed claim must survive restart")
        } catch CacheError.alreadyAttempted {} catch { XCTFail("Unexpected error: \(error)") }
        await assertCount(counter, 1)
        clock.advance(86_400)
        let nextDay = try await restarted.price(context: context, productID: "123") { await counter.increment(); return self.fixture(at: clock.read()) }
        XCTAssertFalse(nextDay.cacheHit)
        await assertCount(counter, 2)
    }

    func testSuccessfulEvidenceRefreshesOnNextUTCDay() async throws {
        let clock = TestClock(instant)
        let cache = try SharedPriceCache(databasePath: ":memory:", now: { clock.read() })
        let counter = Counter()
        let context = try wegmans()
        _ = try await cache.price(context: context, productID: "123") { await counter.increment(); return self.fixture(at: clock.read()) }
        clock.advance(86_400)
        let refreshed = try await cache.price(context: context, productID: "123") { await counter.increment(); return self.fixture(at: clock.read()) }
        XCTAssertFalse(refreshed.cacheHit)
        XCTAssertEqual(refreshed.value.observedAt, clock.read().addingTimeInterval(-60))
        await assertCount(counter, 2)
    }

    func testExpiredCachedWindowCannotRefetchOrRenewTimestampOnSameDay() async throws {
        let clock = TestClock(instant)
        let cache = try SharedPriceCache(databasePath: ":memory:", now: { clock.read() })
        var value = fixture(at: instant)
        value.validUntil = instant.addingTimeInterval(100)
        let original = value
        _ = try await cache.price(context: wegmans(), productID: "123") { original }
        clock.advance(100)
        do {
            _ = try await cache.price(context: wegmans(), productID: "123") { XCTFail("Expired evidence cannot cause another same-day attempt"); return original }
            XCTFail("Expired evidence must not appear fresh")
        } catch CacheError.alreadyAttempted {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testInvalidReturnedEvidenceIsNeverCachedAndClaimIsConsumed() async throws {
        var invalid: [FetchedPrice] = []
        var value = fixture(at: instant)
        value.productID = "999"; invalid.append(value)
        value = fixture(at: instant); value.source = .hmart; invalid.append(value)
        value = fixture(at: instant); value.sourceURL = "https://www.wegmans.com/api/products/134/123"; invalid.append(value)
        value = fixture(at: instant); value.observedAt = instant.addingTimeInterval(-172_800); invalid.append(value)
        value = fixture(at: instant); value.retrievedAt = instant.addingTimeInterval(1); invalid.append(value)
        value = fixture(at: instant); value.observedAt = instant.addingTimeInterval(1); invalid.append(value)
        value = fixture(at: instant); value.validFrom = instant.addingTimeInterval(100); invalid.append(value)
        value = fixture(at: instant); value.validUntil = instant; invalid.append(value)
        value = fixture(at: instant); value.price = -1; invalid.append(value)
        value = fixture(at: instant); value.quantity = Decimal.nan; invalid.append(value)
        for bad in invalid {
            let cache = try SharedPriceCache(databasePath: ":memory:", now: { self.instant })
            do {
                _ = try await cache.price(context: wegmans(), productID: "123") { bad }
                XCTFail("Invalid source evidence should fail")
            } catch CacheError.invalidEvidence {} catch { XCTFail("Unexpected error: \(error)") }
            do {
                _ = try await cache.price(context: wegmans(), productID: "123") { XCTFail("Invalid evidence must not replay the upstream operation"); return bad }
                XCTFail("Invalid evidence should not be cached")
            } catch CacheError.alreadyAttempted {} catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testTwoConnectionsEnforceSharedDailyBudgetTransactionally() async throws {
        let path = temporaryDatabase()
        defer { removeDatabase(path) }
        let first = try SharedPriceCache(databasePath: path, dailyLimit: 3, monthlyLimit: 100, now: { self.instant })
        let second = try SharedPriceCache(databasePath: path, dailyLimit: 3, monthlyLimit: 100, now: { self.instant })
        let counter = Counter()
        let context = try wegmans()
        let successes = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<20 {
                group.addTask {
                    do {
                        _ = try await (index.isMultiple(of: 2) ? first : second).price(context: context, productID: String(index + 1)) {
                            await counter.increment()
                            return self.fixture(id: String(index + 1), at: self.instant)
                        }
                        return true
                    } catch CacheError.budgetExceeded { return false }
                    catch { XCTFail("Unexpected error: \(error)"); return false }
                }
            }
            var successes = 0
            for await result in group { if result { successes += 1 } }
            return successes
        }
        XCTAssertEqual(successes, 3)
        await assertCount(counter, 3)
    }

    func testFailureAndPartialSearchConsumeTheSamePersistentAttemptBudget() async throws {
        let path = temporaryDatabase()
        defer { removeDatabase(path) }
        let cache = try SharedPriceCache(databasePath: path, dailyLimit: 2, monthlyLimit: 2, now: { self.instant })
        let context = try wegmans()
        let counter = Counter()
        do {
            _ = try await cache.price(context: context, productID: "123") { await counter.increment(); throw SampleFailure.upstream }
            XCTFail("The source should fail")
        } catch SampleFailure.upstream {} catch { XCTFail("Unexpected error: \(error)") }
        let partial = try await cache.search(context: context, query: "milk") {
            await counter.increment()
            return RetailSearchPage(candidates: [], message: "The source did not complete the search.")
        }
        XCTAssertNotNil(partial.page.message)
        let restarted = try SharedPriceCache(databasePath: path, dailyLimit: 2, monthlyLimit: 2, now: { self.instant })
        do {
            _ = try await restarted.price(context: context, productID: "456") { await counter.increment(); return self.fixture(id: "456", at: self.instant) }
            XCTFail("Failed and partial closures both consume an attempt")
        } catch CacheError.budgetExceeded {} catch { XCTFail("Unexpected error: \(error)") }
        await assertCount(counter, 2)
    }

    func testTwoConnectionsEnforceSharedMonthlyBudgetTransactionally() async throws {
        let path = temporaryDatabase()
        defer { removeDatabase(path) }
        let first = try SharedPriceCache(databasePath: path, dailyLimit: 100, monthlyLimit: 2, now: { self.instant })
        let second = try SharedPriceCache(databasePath: path, dailyLimit: 100, monthlyLimit: 2, now: { self.instant })
        let counter = Counter()
        let context = try wegmans()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<10 {
                group.addTask {
                    do {
                        _ = try await (index.isMultiple(of: 2) ? first : second).price(context: context, productID: String(index + 1)) {
                            await counter.increment()
                            return self.fixture(id: String(index + 1), at: self.instant)
                        }
                    } catch CacheError.budgetExceeded {} catch { XCTFail("Unexpected error: \(error)") }
                }
            }
        }
        await assertCount(counter, 2)
    }

    func testSecondConnectionCannotDuplicateInFlightClaim() async throws {
        let path = temporaryDatabase()
        defer { removeDatabase(path) }
        let first = try SharedPriceCache(databasePath: path, now: { self.instant })
        let second = try SharedPriceCache(databasePath: path, now: { self.instant })
        let gate = Gate()
        let context = try wegmans()
        let task = Task { try await first.price(context: context, productID: "123") { await gate.enterAndWait(); return self.fixture(at: self.instant) } }
        await gate.waitUntilEntered()
        do {
            _ = try await second.price(context: context, productID: "123") { XCTFail("The second connection cannot repeat a durable claim"); return self.fixture(at: self.instant) }
            XCTFail("The active claim should be reported")
        } catch CacheError.alreadyAttempted {} catch { XCTFail("Unexpected error: \(error)") }
        await gate.open()
        _ = try await task.value
        let cached = try await second.price(context: context, productID: "123") { XCTFail("Persisted result should be visible to second connection"); return self.fixture(at: self.instant) }
        XCTAssertTrue(cached.cacheHit)
    }

    func testMonthlyBudgetSurvivesDailyRolloverAndResetsInNextUTCMonth() async throws {
        let endOfMonth = ISO8601DateFormatter().date(from: "2026-10-30T12:00:00Z")!
        let clock = TestClock(endOfMonth)
        let path = temporaryDatabase()
        defer { removeDatabase(path) }
        let cache = try SharedPriceCache(databasePath: path, dailyLimit: 5, monthlyLimit: 1, now: { clock.read() })
        let context = try wegmans()
        _ = try await cache.price(context: context, productID: "123") { self.fixture(at: clock.read()) }
        clock.advance(86_400)
        let restarted = try SharedPriceCache(databasePath: path, dailyLimit: 5, monthlyLimit: 1, now: { clock.read() })
        do {
            _ = try await restarted.price(context: context, productID: "123") { XCTFail("October's monthly budget is consumed"); return self.fixture(at: clock.read()) }
            XCTFail("Monthly budget should persist after daily rollover")
        } catch CacheError.budgetExceeded {} catch { XCTFail("Unexpected error: \(error)") }
        clock.advance(86_400)
        let nextMonth = try await restarted.price(context: context, productID: "123") { self.fixture(at: clock.read()) }
        XCTAssertFalse(nextMonth.cacheHit)
    }

    func testPartialSearchIsReturnedButNotCachedAcrossRestart() async throws {
        let path = temporaryDatabase()
        defer { removeDatabase(path) }
        let cache = try SharedPriceCache(databasePath: path, now: { self.instant })
        let page = RetailSearchPage(candidates: [fixture(at: instant)], message: "One product could not be checked.")
        let result = try await cache.search(context: wegmans(), query: "milk") { page }
        XCTAssertEqual(result.page.message, page.message)
        XCTAssertFalse(result.cacheHit)
        let restarted = try SharedPriceCache(databasePath: path, now: { self.instant })
        do {
            _ = try await restarted.search(context: wegmans(), query: " MILK ") { XCTFail("Partial search cannot be repeated today"); return page }
            XCTFail("Partial search must not become a complete cached result")
        } catch CacheError.alreadyAttempted {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testSearchRejectsDuplicatesOversizedAndMismatchedSource() async throws {
        let original = fixture(at: instant)
        let pages = [RetailSearchPage(candidates: [original, original]),
                     RetailSearchPage(candidates: (1...6).map { fixture(id: String($0), at: instant) }),
                     RetailSearchPage(candidates: [fixture(id: "123:456", store: .hmart, at: instant)])]
        for page in pages {
            let cache = try SharedPriceCache(databasePath: ":memory:", now: { self.instant })
            do {
                _ = try await cache.search(context: wegmans(), query: "milk") { page }
                XCTFail("Invalid search evidence must fail")
            } catch CacheError.invalidEvidence {} catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testLidlKeepsUnknownStockAndSourceWindow() async throws {
        let cache = try SharedPriceCache(databasePath: ":memory:", now: { self.instant })
        let context = try PriceContext(store: .lidl, storeCode: "US01112", channel: .inStore)
        var value = fixture(store: .lidl, at: instant)
        value.available = nil
        value.validFrom = instant.addingTimeInterval(-3_600)
        value.validUntil = instant.addingTimeInterval(3_600)
        value.sourceExclusion = "Lidl local stock is unknown."
        let expected = value
        let result = try await cache.price(context: context, productID: "123") { expected }
        XCTAssertNil(result.value.available)
        XCTAssertEqual(result.value.validUntil, expected.validUntil)
        XCTAssertEqual(result.value.sourceExclusion, expected.sourceExclusion)
    }

    private func fixture(id: String = "123", store: StoreID = .wegmans, at date: Date) -> FetchedPrice {
        let source: SourceID
        let url: String
        switch store {
        case .wegmans: source = .wegmans; url = "https://www.wegmans.com/api/products/133/\(id)"
        case .hmart: source = .hmart; url = "https://www.hmart.com/api/catalog_system/pub/products/search/?fq=productId:\(id.split(separator: ":")[0])"
        case .lidl: source = .lidl; url = "https://www.lidl.com/p/milk/p\(id)"
        default: source = .manual; url = "https://example.invalid"
        }
        return FetchedPrice(productID: id, productName: "Whole milk", price: Decimal(string: "3.49"), quantity: 64,
                            unit: .flOz, available: nil, observedAt: date.addingTimeInterval(-60), retrievedAt: date,
                            conditions: "Source conditions", source: source, sourceURL: url,
                            sourceExclusion: store == .hmart ? "Online catalog cannot represent local shelf prices." : nil)
    }

    private func assertCount(_ counter: Counter, _ expected: Int, file: StaticString = #filePath, line: UInt = #line) async {
        let actual = await counter.value
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func temporaryDatabase() -> String { FileManager.default.temporaryDirectory.appendingPathComponent("shared-market-\(UUID().uuidString).sqlite").path }
    private func removeDatabase(_ path: String) { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
}

private enum SampleFailure: Error { case upstream }

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; date = date.addingTimeInterval(seconds) }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor Gate {
    private var entered = false
    private var opened = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    func enterAndWait() async {
        entered = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters.removeAll()
        if !opened { await withCheckedContinuation { releaseWaiters.append($0) } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
    }
    func open() {
        opened = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
    }
}
