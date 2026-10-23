import Foundation
import Testing
import SharedMarketCore
import ClientSessions
import ProviderBudgets
import StapleScoutKit
@testable import MarketHTTP

@Suite(.serialized)
struct RefreshRunnerTests {
    @Test func runnerDefaultsOffThenRunsKnownProductsOnceGloballyAcrossRestartAndFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("refresh-runner-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("cache.sqlite").path
        let clock = RunnerClock(Date(timeIntervalSince1970: 1_792_238_400))
        let context = try PriceContext(store: .wegmans, storeCode: "133", channel: .inStore)
        let registry = try SourcePolicyRegistry(policies: [SourcePolicy(context: context, fetchApproved: true, publicServingApproved: true, attribution: "Offline fixture", cacheTTL: 172800, displayTTL: 172800)])
        let cache = try SharedPriceCache(databasePath: path, policies: registry, now: { clock.read() })
        let initial = runnerValue(at: clock.read())
        _ = try await cache.price(context: context, productID: "123") { initial }
        _ = try await cache.search(context: context, query: "not-a-private-list") { RetailSearchPage(candidates: [runnerValue(at: clock.read(), id: "456")]) }
        let sessions = try ClientSessionStore(databasePath: ":memory:")
        let firstSession = try await sessions.enroll(invitation: sessions.issueInvitation().invitation)
        let principal = try await sessions.authenticate(accessToken: firstSession.accessToken)
        let policy = try ProviderBudgetPolicy(providerHourly: 10, providerDaily: 10, providerMonthly: 10, clientDaily: 10, clientMonthly: 10, globalMissesDaily: 10, globalMissesMonthly: 10, clientMissesDaily: 10, clientMissesMonthly: 10)
        let ledger = try ProviderBudgetLedger(databasePath: ":memory:", policy: policy, now: { clock.read() })
        let network = RunnerNetwork(); let budgets = ProviderBudgetController(ledger: ledger, network: network)
        let upstream = RunnerUpstream(clock: clock)
        let disabled = try KnownProductRefreshRunner(cache: cache, upstream: upstream, budgets: budgets, operatorPrincipal: principal)
        #expect(try await !disabled.runOnce().claimed)
        #expect(await network.count == 0)
        clock.advance(86400)
        let runner = try KnownProductRefreshRunner(cache: cache, upstream: upstream, budgets: budgets, operatorPrincipal: principal, enabled: true)
        let summary = try await runner.runOnce()
        #expect(summary.claimed && summary.attempted == 1 && summary.succeeded == 1 && summary.failed == 0)
        #expect(await network.count == 1)
        let restartedCache = try SharedPriceCache(databasePath: path, policies: registry, now: { clock.read() })
        let secondSession = try await sessions.enroll(invitation: sessions.issueInvitation().invitation)
        let otherPrincipal = try await sessions.authenticate(accessToken: secondSession.accessToken)
        let restarted = try KnownProductRefreshRunner(cache: restartedCache, upstream: upstream, budgets: budgets, operatorPrincipal: otherPrincipal, enabled: true)
        #expect(try await !restarted.runOnce().claimed)
        #expect(await network.count == 1)
        clock.advance(86400)
        await network.fail()
        let failed = try await restarted.runOnce()
        #expect(failed.claimed && failed.attempted == 1 && failed.failed == 1)
        #expect(try await !runner.runOnce().claimed)
        let usage = try await ledger.usage(for: otherPrincipal).windows[2]
        #expect(usage.reserved == 2 && usage.uncertain == 1)
        clock.advance(-86400)
        #expect(try await !runner.runOnce().claimed)
    }

    @Test func scheduledDayBoundaryStopsBeforeNextKnownProduct() async throws {
        let clock = RunnerClock(Date(timeIntervalSince1970: 1_792_238_400))
        let context = try PriceContext(store: .wegmans, storeCode: "133", channel: .inStore)
        let registry = try SourcePolicyRegistry(policies: [SourcePolicy(context: context, fetchApproved: true, publicServingApproved: true, attribution: "Offline fixture", cacheTTL: 172800, displayTTL: 172800)])
        let cache = try SharedPriceCache(databasePath: ":memory:", policies: registry, now: { clock.read() })
        for id in ["123", "456"] { _ = try await cache.price(context: context, productID: id) { runnerValue(at: clock.read(), id: id) } }
        clock.advance(86400)
        let sessions = try ClientSessionStore(databasePath: ":memory:")
        let session = try await sessions.enroll(invitation: sessions.issueInvitation().invitation)
        let principal = try await sessions.authenticate(accessToken: session.accessToken)
        let policy = try ProviderBudgetPolicy(providerHourly: 10, providerDaily: 10, providerMonthly: 10, clientDaily: 10, clientMonthly: 10, globalMissesDaily: 10, globalMissesMonthly: 10, clientMissesDaily: 10, clientMissesMonthly: 10)
        let ledger = try ProviderBudgetLedger(databasePath: ":memory:", policy: policy, now: { clock.read() })
        let network = RunnerNetwork(); let budgets = ProviderBudgetController(ledger: ledger, network: network)
        let runner = try KnownProductRefreshRunner(cache: cache, upstream: RunnerUpstream(clock: clock, advanceDay: true), budgets: budgets, operatorPrincipal: principal, enabled: true)
        let result = try await runner.runOnce()
        #expect(result.attempted == 1)
        #expect(await network.count == 1)
    }
}
private func runnerValue(at date: Date, id: String = "123") -> FetchedPrice {
    FetchedPrice(productID: id, productName: "Offline fixture", price: 2, quantity: 1, unit: .each, available: nil, observedAt: date.addingTimeInterval(-10), retrievedAt: date, source: .wegmans, sourceURL: "https://www.wegmans.com/api/products/133/\(id)")
}
private final class RunnerClock: @unchecked Sendable {
    let lock = NSLock(); var date: Date
    init(_ date: Date) { self.date = date }
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: Double) { lock.lock(); defer { lock.unlock() }; date += seconds }
}
private actor RunnerNetwork: ProviderHTTPNetwork {
    var count = 0; var shouldFail = false
    func fail() { shouldFail = true }
    func send(_ request: ProviderHTTPRequest) async throws -> ProviderHTTPResponse {
        count += 1
        if shouldFail { throw ProviderBudgetError.networkUnavailable }
        return ProviderHTTPResponse(status: 200, body: Data("{}".utf8))
    }
}
private struct RunnerUpstream: MarketUpstream {
    let clock: RunnerClock
    var advanceDay = false
    func price(context: PriceContext, productID: String, requests: ProviderRequestScope) async throws -> FetchedPrice {
        _ = try await requests.load(ProviderHTTPRequest(engine: .walmart, query: "synthetic fixture", purpose: .search))
        if advanceDay { clock.advance(86400) }
        return runnerValue(at: clock.read(), id: productID)
    }
    func search(context: PriceContext, query: String, requests: ProviderRequestScope) async throws -> RetailSearchPage { throw ProviderBudgetError.invalidRequest }
}
