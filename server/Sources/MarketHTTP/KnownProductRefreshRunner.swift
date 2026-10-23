import Foundation
import SharedMarketCore
import ProviderBudgets
import ClientSessions

public struct RefreshRunSummary: Sendable {
    public let claimed: Bool
    public let attempted: Int
    public let succeeded: Int
    public let failed: Int
}

/// An explicit one-shot worker, never a timer or automatically started task.
/// The only catalog is previously accepted exact public product cache entries.
/// It accepts no personal list, search term, product array or caller identity.
public actor KnownProductRefreshRunner {
    private let cache: SharedPriceCache
    private let upstream: any MarketUpstream
    private let budgets: ProviderBudgetController
    private let principal: ClientPrincipal
    private let enabled: Bool
    private let maximumProducts: Int
    private let maximumDurationSeconds: Double
    private var stopping = false
    private var active: Task<RefreshRunSummary, Error>?

    public init(cache: SharedPriceCache, upstream: any MarketUpstream, budgets: ProviderBudgetController,
                operatorPrincipal: ClientPrincipal, enabled: Bool = false, maximumProducts: Int = 50, maximumDurationSeconds: Double = 300) throws {
        guard (1...50).contains(maximumProducts), maximumDurationSeconds.isFinite, (1...900).contains(maximumDurationSeconds) else { throw CacheError.invalidRequest("The worker limit is invalid.") }
        self.cache = cache; self.upstream = upstream; self.budgets = budgets; self.principal = operatorPrincipal
        self.enabled = enabled; self.maximumProducts = maximumProducts; self.maximumDurationSeconds = maximumDurationSeconds
    }
    public func runOnce() async throws -> RefreshRunSummary {
        guard !stopping else { throw CacheError.shuttingDown }
        if let active { return try await active.value }
        let task = Task<RefreshRunSummary, Error> {
            guard let run = try await cache.beginScheduledRun(enabled: enabled, maximumProducts: maximumProducts) else {
                return RefreshRunSummary(claimed: false, attempted: 0, succeeded: 0, failed: 0)
            }
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(maximumDurationSeconds * 1000)))
            var attempted = 0; var succeeded = 0; var failed = 0
            for product in run.products {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline, try await cache.scheduledDayIsCurrent(run.day) else { break }
                attempted += 1
                do {
                    _ = try await cache.admittedPrice(context: product.context, productID: product.productID, admit: {
                        let policyAuthorization = try self.cache.authorization(context: product.context)
                        let authorization: @Sendable () throws -> Void = {
                            try policyAuthorization()
                            guard ContinuousClock.now < deadline else { throw CancellationError() }
                        }
                        let admitted = try await self.budgets.admit(principal: self.principal, beforeRequest: authorization)
                        return CacheFetchOperation(run: { try await self.upstream.price(context: product.context, productID: product.productID, requests: admitted.requests) }, finish: { try await admitted.finish() })
                    })
                    succeeded += 1
                } catch is CancellationError { throw CancellationError() }
                catch { failed += 1 }
            }
            return RefreshRunSummary(claimed: true, attempted: attempted, succeeded: succeeded, failed: failed)
        }
        active = task
        defer { active = nil }
        return try await task.value
    }
    public func shutdown() async {
        stopping = true
        active?.cancel()
        await cache.shutdown()
        if let active { _ = await active.result }
    }
}
