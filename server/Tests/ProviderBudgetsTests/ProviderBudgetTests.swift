import Foundation
import XCTest
import ClientSessions
import SharedMarketCore
import StapleScoutKit
@testable import ProviderBudgets

final class ProviderBudgetTests: XCTestCase, @unchecked Sendable {
    let instant = Date(timeIntervalSince1970: 1_792_382_400)

    func testDefaultPolicyIsDisabledAndMetricsNeverClaimProviderBilling() async throws {
        let ledger = try ProviderBudgetLedger(databasePath: ":memory:")
        let principal = try await client()
        await expect(.disabled) { _ = try await ledger.beginMiss(principal: principal) }
        let snapshot = try await ledger.usage(for: principal)
        XCTAssertFalse(snapshot.enabled)
        XCTAssertTrue(snapshot.windows.allSatisfy { $0.reserved == 0 && $0.remaining == 0 })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        XCTAssertTrue(json["providerReportedUnits"] is NSNull)
        XCTAssertEqual(json["accounting"] as? String, "conservative_local_reservations")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self).contains(principal.clientID))
    }

    func testEachSearchCandidatePageAndExplicitRetryNeedsItsOwnReservation() async throws {
        let principal = try await client()
        let ledger = try ProviderBudgetLedger(databasePath: ":memory:", policy: policy(), now: { self.instant })
        let network = FakeProviderNetwork()
        let controller = ProviderBudgetController(ledger: ledger, network: network)
        try await controller.withMiss(principal: principal) { scope in
            _ = try await scope.load(self.searchRequest())
            for identity in ["123", "456"] { _ = try await scope.load(ProviderHTTPRequest(engine: .walmartProduct, productID: identity, purpose: .candidate)) }
            _ = try await scope.load(ProviderHTTPRequest(engine: .walmart, query: "synthetic query", page: 2, purpose: .pagination))
            _ = try await scope.load(ProviderHTTPRequest(engine: .walmartProduct, productID: "123", purpose: .retry))
        }
        let sent = await network.count
        XCTAssertEqual(sent, 5)
        let usage = try await ledger.usage(for: principal).windows[0]
        XCTAssertEqual(usage.reserved, 5); XCTAssertEqual(usage.attempted, 5)
        XCTAssertEqual(usage.consumedUpperBound, 5); XCTAssertEqual(usage.uncertain, 0)
        XCTAssertEqual(usage.remaining, 45)
    }

    func testEmptyCachedAndAppRejectedSuccessStillConsumeConservativeUnits() async throws {
        let principal = try await client()
        let ledger = try ProviderBudgetLedger(databasePath: ":memory:", policy: policy(), now: { self.instant })
        let controller = ProviderBudgetController(ledger: ledger, network: FakeProviderNetwork(body: Data(#"{"results":[],"cached":true}"#.utf8)))
        do {
            try await controller.withMiss(principal: principal) { scope in
                _ = try await scope.load(self.searchRequest())
                throw ProviderBudgetError.networkUnavailable // adapter rejects the returned evidence
            }
            XCTFail("The adapter should reject this result")
        } catch ProviderBudgetError.networkUnavailable {}
        let usage = try await ledger.usage(for: principal).windows[0]
        XCTAssertEqual(usage.reserved, 1); XCTAssertEqual(usage.consumedUpperBound, 1)
        let observedValue1 = try await ledger.usage(for: principal).providerReportedUnits
        XCTAssertNil(observedValue1)
    }

    func testErrorsAndAmbiguousFailuresNeverRefundAndNoAutomaticRetryOccurs() async throws {
        for mode in [FakeProviderNetwork.Mode.status(500), .failure] {
            let principal = try await client()
            let ledger = try ProviderBudgetLedger(databasePath: ":memory:", policy: policy(globalUnits: 1), now: { self.instant })
            let network = FakeProviderNetwork(mode: mode)
            let controller = ProviderBudgetController(ledger: ledger, network: network)
            await expect(.networkUnavailable) { try await controller.withMiss(principal: principal) { _ = try await $0.load(self.searchRequest()) } }
            await expect(.providerLimit) { try await controller.withMiss(principal: principal) { _ = try await $0.load(self.searchRequest()) } }
            let sent = await network.count
            XCTAssertEqual(sent, 1)
            let usage = try await ledger.usage(for: principal).windows[0]
            XCTAssertEqual(usage.reserved, 1); XCTAssertEqual(usage.uncertain, 1); XCTAssertEqual(usage.pending, 0)
        }
    }

    func testConcurrentConnectionsCannotExceedTheSharedUnitCap() async throws {
        let path = try databasePath(); defer { cleanup(path) }
        let configuration = try policy(globalUnits: 3)
        let first = try ProviderBudgetLedger(databasePath: path, policy: configuration, now: { self.instant })
        let second = try ProviderBudgetLedger(databasePath: path, policy: configuration, now: { self.instant })
        let principal = try await client()
        let lease = try await first.beginMiss(principal: principal)
        let total = await withTaskGroup(of: Int.self) { group in
            for index in 0..<20 {
                group.addTask {
                    do {
                        let store = index.isMultiple(of: 2) ? first : second
                        let reservation = try await store.reserve(lease: lease, purpose: .detail)
                        try await store.dispatched(reservation)
                        try await store.complete(reservation, receivedSuccess: true)
                        return 1
                    } catch ProviderBudgetError.providerLimit { return 0 }
                    catch { XCTFail("Unexpected reservation error: \(error)"); return 0 }
                }
            }
            var total = 0; for await value in group { total += value }; return total
        }
        XCTAssertEqual(total, 3)
        try await first.endMiss(lease)
        let reopened = try ProviderBudgetLedger(databasePath: path, policy: configuration, now: { self.instant })
        let observedValue2 = try await reopened.usage(for: principal).windows[0].reserved
        XCTAssertEqual(observedValue2, 3)
    }

    func testDeniedClientReservationRollsBackAllGlobalCapacityAndCompletionIsIdempotent() async throws {
        let principal = try await client()
        let other = try await client()
        let ledger = try ProviderBudgetLedger(databasePath: ":memory:", policy: policy(clientUnits: 1), now: { self.instant })
        let first = try await ledger.beginMiss(principal: principal)
        let reservation = try await ledger.reserve(lease: first, purpose: .search)
        try await ledger.dispatched(reservation)
        try await ledger.complete(reservation, receivedSuccess: true)
        try await ledger.complete(reservation, receivedSuccess: false)
        await expect(.clientLimit) { _ = try await ledger.reserve(lease: first, purpose: .detail) }
        try await ledger.endMiss(first)
        let second = try await ledger.beginMiss(principal: other)
        let secondReservation = try await ledger.reserve(lease: second, purpose: .search)
        try await ledger.complete(secondReservation, receivedSuccess: false)
        try await ledger.endMiss(second)
        let usage = try await ledger.usage(for: principal).windows[0]
        XCTAssertEqual(usage.reserved, 2); XCTAssertEqual(usage.attempted, 1); XCTAssertEqual(usage.consumedUpperBound, 1)
    }

    func testRollingProviderHourDoesNotResetAtUTCClockHour() async throws {
        let start = ISO8601DateFormatter().date(from: "2026-10-31T23:59:59Z")!
        let clock = BudgetClock(start)
        let principal = try await client()
        let ledger = try ProviderBudgetLedger(databasePath: ":memory:", policy: policy(globalUnits: 1), now: { clock.read() })
        let controller = ProviderBudgetController(ledger: ledger, network: FakeProviderNetwork())
        try await controller.withMiss(principal: principal) { _ = try await $0.load(self.searchRequest()) }
        clock.advance(2)
        await expect(.providerLimit) { try await controller.withMiss(principal: principal) { _ = try await $0.load(self.searchRequest()) } }
        let observedValue3 = try await ledger.usage(for: principal).windows[0].remaining
        XCTAssertEqual(observedValue3, 0)
    }

    func testRolling31DayProviderPoolDoesNotResetWithClientUTCMonthOrRestart() async throws {
        let path = try databasePath(); defer { cleanup(path) }
        let start = ISO8601DateFormatter().date(from: "2026-10-31T23:59:59Z")!
        let clock = BudgetClock(start)
        let principal = try await client()
        let configuration = try policy(globalUnits: 1)
        let first = try ProviderBudgetLedger(databasePath: path, policy: configuration, now: { clock.read() })
        let controller = ProviderBudgetController(ledger: first, network: FakeProviderNetwork())
        try await controller.withMiss(principal: principal) { _ = try await $0.load(self.searchRequest()) }
        clock.advance(86_401)
        let restarted = try ProviderBudgetLedger(databasePath: path, policy: configuration, now: { clock.read() })
        let second = ProviderBudgetController(ledger: restarted, network: FakeProviderNetwork())
        await expect(.providerLimit) { try await second.withMiss(principal: principal) { _ = try await $0.load(self.searchRequest()) } }
        let usage = try await restarted.usage(for: principal)
        XCTAssertEqual(usage.windows[0].reserved, 0)
        XCTAssertEqual(usage.windows[2].reserved, 1)
        XCTAssertEqual(usage.windows[4].reserved, 0)
        clock.advance(30 * 86_400)
        try await second.withMiss(principal: principal) { _ = try await $0.load(self.searchRequest()) }
    }

    func testClientDayAndMonthCountersRollOverIndependentlyOfProviderEnvelope() async throws {
        let clock = BudgetClock(ISO8601DateFormatter().date(from: "2026-10-30T23:59:59Z")!)
        let principal = try await client()
        let policy = try ProviderBudgetPolicy(providerHourly: 50, providerDaily: 50, providerMonthly: 250,
            clientDaily: 1, clientMonthly: 2, globalMissesDaily: 50, globalMissesMonthly: 250, clientMissesDaily: 10, clientMissesMonthly: 50)
        let ledger = try ProviderBudgetLedger(databasePath: ":memory:", policy: policy, now: { clock.read() })
        let controller = ProviderBudgetController(ledger: ledger, network: FakeProviderNetwork())
        try await controller.withMiss(principal: principal) { _ = try await $0.load(self.searchRequest()) }
        clock.advance(2)
        try await controller.withMiss(principal: principal) { _ = try await $0.load(self.searchRequest()) }
        await expect(.clientLimit) { try await controller.withMiss(principal: principal) { _ = try await $0.load(self.searchRequest()) } }
        clock.advance(86_400)
        try await controller.withMiss(principal: principal) { _ = try await $0.load(self.searchRequest()) }
        let observedValue4 = try await ledger.usage(for: principal).windows[2].reserved
        XCTAssertEqual(observedValue4, 3)
    }

    func testCrashReservationAndMissRemainPendingAfterRestartWithoutRefundOrStealingLiveWork() async throws {
        let path = try databasePath(); defer { cleanup(path) }
        let principal = try await client()
        let configuration = try policy(globalUnits: 1, concurrent: 1)
        let first = try ProviderBudgetLedger(databasePath: path, policy: configuration, now: { self.instant })
        let lease = try await first.beginMiss(principal: principal)
        _ = try await first.reserve(lease: lease, purpose: .search)
        // Simulate a process disappearing between durable reserve and dispatch.
        let restarted = try ProviderBudgetLedger(databasePath: path, policy: configuration, now: { self.instant })
        let usage = try await restarted.usage(for: principal).windows[0]
        XCTAssertEqual(usage.reserved, 1); XCTAssertEqual(usage.attempted, 0); XCTAssertEqual(usage.pending, 1)
        await expect(.workPending) { _ = try await restarted.beginMiss(principal: principal) }
        let other = try await client()
        await expect(.workPending) { _ = try await restarted.beginMiss(principal: other) }
        try await restarted.endMiss(lease)
        await expect(.workPending) { _ = try await first.beginMiss(principal: other) }
    }

    func testCancellationBeforeReservationSpendsNothingAndAfterDispatchKeepsTheHold() async throws {
        let principal = try await client()
        let ledger = try ProviderBudgetLedger(databasePath: ":memory:", policy: policy(), now: { self.instant })
        let gate = BudgetGate()
        let network = FakeProviderNetwork(gate: gate)
        let controller = ProviderBudgetController(ledger: ledger, network: network)
        let before = Task { await gate.wait(); try Task.checkCancellation(); try await controller.withMiss(principal: principal) { _ = try await $0.load(self.searchRequest()) } }
        before.cancel(); await gate.open()
        do { try await before.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        let observedValue5 = try await ledger.usage(for: principal).windows[0].reserved
        XCTAssertEqual(observedValue5, 0)
        let secondGate = BudgetGate()
        let second = ProviderBudgetController(ledger: ledger, network: FakeProviderNetwork(gate: secondGate))
        let task = Task { try await second.withMiss(principal: principal) { _ = try await $0.load(self.searchRequest()) } }
        await secondGate.waitUntilEntered()
        task.cancel(); await secondGate.open()
        do { try await task.value; XCTFail("Expected cancelled transport") } catch is CancellationError {}
        let usage = try await ledger.usage(for: principal).windows[0]
        XCTAssertEqual(usage.reserved, 1); XCTAssertEqual(usage.uncertain, 1); XCTAssertEqual(usage.pending, 0)
    }

    func testPerMissFanoutAndHighCardinalityMissesAreBounded() async throws {
        let principal = try await client()
        let configuration = try ProviderBudgetPolicy(providerHourly: 50, providerDaily: 50, providerMonthly: 250,
            clientDaily: 50, clientMonthly: 250, globalMissesDaily: 50, globalMissesMonthly: 250,
            clientMissesDaily: 2, clientMissesMonthly: 2, maximumRequestsPerMiss: 2)
        let ledger = try ProviderBudgetLedger(databasePath: ":memory:", policy: configuration, now: { self.instant })
        let controller = ProviderBudgetController(ledger: ledger, network: FakeProviderNetwork())
        await expect(.operationLimit) {
            try await controller.withMiss(principal: principal) { scope in
                for _ in 0..<3 { _ = try await scope.load(self.searchRequest()) }
            }
        }
        try await controller.withMiss(principal: principal) { _ in } // unused admission is conservatively charged
        await expect(.clientLimit) { try await controller.withMiss(principal: principal) { _ in XCTFail("Miss limit must stop expansion") } }
        let observedValue6 = try await ledger.usage(for: principal).windows[0].reserved
        XCTAssertEqual(observedValue6, 3)
    }

    func testPinnedPolicyAndClockRollbackCannotReopenAllowancesAcrossConnections() async throws {
        let path = try databasePath(); defer { cleanup(path) }
        let clock = BudgetClock(instant)
        let principal = try await client()
        let configuration = try policy(clientUnits: 1)
        let first = try ProviderBudgetLedger(databasePath: path, policy: configuration, now: { clock.read() })
        let controller = ProviderBudgetController(ledger: first, network: FakeProviderNetwork())
        try await controller.withMiss(principal: principal) { _ = try await $0.load(self.searchRequest()) }
        clock.advance(-86_400)
        let restarted = try ProviderBudgetLedger(databasePath: path, policy: configuration, now: { clock.read() })
        await expect(.clientLimit) { try await ProviderBudgetController(ledger: restarted, network: FakeProviderNetwork()).withMiss(principal: principal) { _ = try await $0.load(self.searchRequest()) } }
        XCTAssertThrowsError(try ProviderBudgetLedger(databasePath: path, policy: policy(clientUnits: 2)))
    }

    func testDelayedDispatchAndCompletionKeepCapacityInEveryCurrentWindow() async throws {
        for gap: TimeInterval in [3_601, 86_401, 31 * 86_400 + 1] {
            let clock = BudgetClock(instant)
            let principal = try await client()
            let other = try await client()
            let ledger = try ProviderBudgetLedger(databasePath: ":memory:", policy: policy(globalUnits: 1), now: { clock.read() })
            let dispatchGate = BudgetGate()
            let completionGate = BudgetGate()
            let network = FakeProviderNetwork(gate: completionGate)
            let delayed = ProviderBudgetController(ledger: ledger, network: network, dispatchCheckpoint: { await dispatchGate.enterAndWait() })
            let first = Task { try await delayed.withMiss(principal: principal) { _ = try await $0.load(self.searchRequest()) } }
            await dispatchGate.waitUntilEntered()
            clock.advance(gap)
            let normal = ProviderBudgetController(ledger: ledger, network: network)
            await expect(.providerLimit) { try await normal.withMiss(principal: other) { _ = try await $0.load(self.searchRequest()) } }
            let pending = try await ledger.usage(for: principal)
            XCTAssertTrue(pending.windows.allSatisfy { $0.reserved == 1 && $0.pending == 1 })
            await dispatchGate.open()
            await completionGate.waitUntilEntered()
            clock.advance(gap)
            await expect(.providerLimit) { try await normal.withMiss(principal: other) { _ = try await $0.load(self.searchRequest()) } }
            await completionGate.open()
            try await first.value
            // Completing the old request must not make it disappear from the
            // new hour/day/month immediately after its actual HTTP response.
            await expect(.providerLimit) { try await normal.withMiss(principal: other) { _ = try await $0.load(self.searchRequest()) } }
            let count = await network.count
            XCTAssertEqual(count, 1)
            let finished = try await ledger.usage(for: principal)
            XCTAssertTrue(finished.windows.allSatisfy { $0.reserved == 1 && $0.pending == 0 })
        }
    }

    func testInterruptedProviderBootstrapRollsBackAndRecoversWithoutChangingPolicy() async throws {
        let path = try databasePath(); defer { cleanup(path) }
        XCTAssertThrowsError(try BudgetSQLite(path: path, bootstrapCheckpoint: { throw ProviderBudgetError.storageUnavailable }))
        let reopened = try ProviderBudgetLedger(databasePath: path, policy: policy(), now: { self.instant })
        let principal = try await client()
        try await ProviderBudgetController(ledger: reopened, network: FakeProviderNetwork()).withMiss(principal: principal) { _ = try await $0.load(self.searchRequest()) }
        let usage = try await reopened.usage(for: principal)
        XCTAssertEqual(usage.windows[0].reserved, 1)
        for suffix in ["", "-wal", "-shm"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: path + suffix)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testHighCardinalityCacheMissesAreBoundedBeforeAdmission() async throws {
        let principal = try await client()
        let ledger = try ProviderBudgetLedger(databasePath: ":memory:", policy: policy(), now: { self.instant })
        let gate = BudgetGate()
        let network = FakeProviderNetwork(gate: gate)
        let controller = ProviderBudgetController(ledger: ledger, network: network)
        let cache = try SharedPriceCache(databasePath: ":memory:", maximumInFlight: 1, policies: try fixturePolicies(), now: { self.instant })
        let context = try PriceContext(store: .wegmans, storeCode: "133", channel: .inStore)
        let first = Task {
            try await cache.admittedSearch(context: context, query: "first query", admit: {
                let admitted = try await controller.admit(principal: principal)
                return CacheFetchOperation(run: { _ = try await admitted.requests.load(self.searchRequest()); return RetailSearchPage(candidates: []) }, finish: { try await admitted.finish() })
            })
        }
        await gate.waitUntilEntered()
        for index in 0..<20 {
            do {
                _ = try await cache.admittedSearch(context: context, query: "different query \(index)", admit: {
                    XCTFail("The cache bound must precede provider admission")
                    return CacheFetchOperation(run: { RetailSearchPage(candidates: []) })
                })
                XCTFail("Expected pending work bound")
            } catch CacheError.pending {}
        }
        await gate.open(); _ = try await first.value
        let usage = try await ledger.usage(for: principal)
        XCTAssertEqual(usage.windows[0].reserved, 1)
        let count = await network.count
        XCTAssertEqual(count, 1)
    }

    func testScopedRequestsRejectUnknownEnginesHostsSecretsAndUnboundedFieldsByConstruction() throws {
        XCTAssertThrowsError(try ProviderHTTPRequest(engine: .target, query: String(repeating: "x", count: 101), purpose: .search))
        XCTAssertThrowsError(try ProviderHTTPRequest(engine: .target, query: "milk\nsecret", purpose: .search))
        XCTAssertThrowsError(try ProviderHTTPRequest(engine: .walmart, query: "milk", page: 4, purpose: .pagination))
        XCTAssertThrowsError(try ProviderHTTPRequest(engine: .walmartProduct, productID: "https://evil.invalid", purpose: .detail))
        XCTAssertThrowsError(try ProviderHTTPRequest(engine: .walmartProduct, query: "x", productID: "123", purpose: .detail))
        let request = try searchRequest()
        XCTAssertEqual(request.url.host, "serpapi.com"); XCTAssertEqual(request.url.path, "/search.json")
        XCTAssertNil(request.url.user); XCTAssertNil(request.url.password)
        XCTAssertFalse(request.url.absoluteString.contains("api_key"))
    }

    func policy(globalUnits: Int = 50, clientUnits: Int = 50, concurrent: Int = 4) throws -> ProviderBudgetPolicy {
        try ProviderBudgetPolicy(providerHourly: globalUnits, providerDaily: globalUnits, providerMonthly: globalUnits,
            clientDaily: clientUnits, clientMonthly: clientUnits, globalMissesDaily: 50, globalMissesMonthly: 250,
            clientMissesDaily: 50, clientMissesMonthly: 250, maximumConcurrentMisses: concurrent, maximumConcurrentRequests: 4)
    }
    func searchRequest() throws -> ProviderHTTPRequest { try ProviderHTTPRequest(engine: .walmart, query: "synthetic query", purpose: .search) }
    func client() async throws -> ClientPrincipal {
        let store = try ClientSessionStore(databasePath: ":memory:")
        let tokens = try await store.enroll(invitation: store.issueInvitation().invitation)
        return try await store.authenticate(accessToken: tokens.accessToken)
    }
    func databasePath() throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("provider-budget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory.appendingPathComponent("ledger.sqlite").path
    }
    func cleanup(_ path: String) { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
    func expect(_ expected: ProviderBudgetError, file: StaticString = #filePath, line: UInt = #line, action: () async throws -> Void) async {
        do { try await action(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch let error as ProviderBudgetError { XCTAssertEqual(error, expected, file: file, line: line) }
        catch { XCTFail("Unexpected error", file: file, line: line) }
    }
}

actor FakeProviderNetwork: ProviderHTTPNetwork {
    enum Mode: Sendable { case status(Int), failure }
    var count = 0
    let mode: Mode
    let body: Data
    let gate: BudgetGate?
    init(mode: Mode = .status(200), body: Data = Data("{}".utf8), gate: BudgetGate? = nil) { self.mode = mode; self.body = body; self.gate = gate }
    func send(_ request: ProviderHTTPRequest) async throws -> ProviderHTTPResponse {
        count += 1
        if let gate { await gate.enterAndWait() }
        try Task.checkCancellation()
        switch mode { case .status(let code): return ProviderHTTPResponse(status: code, body: body); case .failure: throw URLError(.networkConnectionLost) }
    }
}
actor BudgetGate {
    var openFlag = false
    var entered = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    var entrants: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !openFlag { await withCheckedContinuation { waiters.append($0) } } }
    func enterAndWait() async { entered = true; for waiter in entrants { waiter.resume() }; entrants.removeAll(); await wait() }
    func waitUntilEntered() async { if !entered { await withCheckedContinuation { entrants.append($0) } } }
    func open() { openFlag = true; for waiter in waiters { waiter.resume() }; waiters.removeAll() }
}
final class BudgetClock: @unchecked Sendable {
    private let lock = NSLock(); private var value: Date
    init(_ value: Date) { self.value = value }
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value = value.addingTimeInterval(seconds) }
}

private func fixturePolicies() throws -> SourcePolicyRegistry {
    try SourcePolicyRegistry(policies: [
        try SourcePolicy(context: PriceContext(store: .wegmans, storeCode: "133", channel: .inStore), fetchApproved: true, publicServingApproved: true, attribution: "Offline fixture", cacheTTL: 172800, displayTTL: 172800),
        try SourcePolicy(context: PriceContext(store: .hmart, storeCode: nil, channel: .online), fetchApproved: true, publicServingApproved: true, attribution: "Offline fixture", cacheTTL: 172800, displayTTL: 172800),
        try SourcePolicy(context: PriceContext(store: .lidl, storeCode: "US01112", channel: .inStore), fetchApproved: true, publicServingApproved: true, attribution: "Offline fixture", cacheTTL: 172800, displayTTL: 172800)
    ])
}
