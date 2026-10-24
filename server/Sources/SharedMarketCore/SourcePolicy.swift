import Foundation
import StapleScoutKit

/// One policy is one provider + retailer + physical-store/channel tuple.
/// Technical capability and permission are deliberately independent.
public struct SourcePolicy: Encodable, Sendable {
    public let provider: String
    public let store: StoreID
    public let storeCode: String?
    public let channel: Channel
    public let technicallySupported: Bool
    public private(set) var fetchApproved: Bool
    public private(set) var publicServingApproved: Bool
    public let attribution: String
    public let referenceOnly: Bool
    public let limitation: String
    public let cacheTTL: TimeInterval
    public let displayTTL: TimeInterval
    public let maximumObservationAge: TimeInterval
    public let retention: TimeInterval

    public init(context: PriceContext, provider: String = "offline_fixture", fetchApproved: Bool,
                publicServingApproved: Bool, attribution: String, referenceOnly: Bool = false,
                limitation: String = "", cacheTTL: TimeInterval = 86_400, displayTTL: TimeInterval = 86_400,
                maximumObservationAge: TimeInterval = 172_800, retention: TimeInterval = 172_800) throws {
        guard !provider.isEmpty, provider.utf8.count <= 100, !attribution.isEmpty, attribution.utf8.count <= 1024,
              limitation.utf8.count <= 4096,
              [cacheTTL, displayTTL, maximumObservationAge, retention].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 172_800 }) else {
            throw CacheError.invalidRequest("The source policy is invalid.")
        }
        self.provider = provider; store = context.store; storeCode = context.storeCode; channel = context.channel
        technicallySupported = true; self.fetchApproved = fetchApproved; self.publicServingApproved = publicServingApproved
        self.attribution = attribution; self.referenceOnly = referenceOnly || context.store == .hmart
        self.limitation = limitation; self.cacheTTL = cacheTTL; self.displayTTL = displayTTL
        self.maximumObservationAge = maximumObservationAge; self.retention = retention
    }

    private init(location: StoreLocation) {
        store = location.store; storeCode = location.code
        channel = location.store == .hmart ? .online : location.store == .walmart ? .pickup : .inStore
        technicallySupported = [.wegmans, .hmart, .lidl].contains(location.store)
        provider = [.target, .walmart].contains(location.store) ? "unselected" : "retailer_website"
        fetchApproved = false; publicServingApproved = false; attribution = "Permission and attribution requirements unresolved."
        referenceOnly = location.store == .hmart
        limitation = location.store == .hmart ? "National online reference; not Centreville shelf pricing."
            : location.store == .lidl ? "Region US1112 offers; local stock is unknown."
            : "Public fetching, display, caching and retention are not approved."
        cacheTTL = 0; displayTTL = 0; maximumObservationAge = 0; retention = 0
    }

    public static var disabledCatalog: [SourcePolicy] { StoreLocation.defaults.map { SourcePolicy(location: $0) } }
    func denied() -> SourcePolicy { var copy = self; copy.fetchApproved = false; copy.publicServingApproved = false; return copy }
    var fingerprint: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try! encoder.encode(self), as: UTF8.self)
    }
    var permitted: Bool { technicallySupported && fetchApproved && publicServingApproved }
    func matches(_ context: PriceContext) -> Bool { store == context.store && storeCode == context.storeCode && channel == context.channel }

    func validateCache(at date: Date, insertedAt: Date) throws {
        guard date >= insertedAt, date.timeIntervalSince(insertedAt) < min(cacheTTL, displayTTL, retention) else {
            throw CacheError.invalidEvidence("The cached page exceeds its approved freshness limits.")
        }
    }
    func validate(_ value: FetchedPrice, at date: Date, insertedAt: Date?) throws {
        let ttl = min(cacheTTL, displayTTL, retention)
        guard date.timeIntervalSince(value.retrievedAt) < ttl,
              date.timeIntervalSince(value.observedAt) < min(172_800, maximumObservationAge),
              insertedAt.map({ date >= $0 && date.timeIntervalSince($0) < min(cacheTTL, retention) }) ?? true else {
            throw CacheError.invalidEvidence("The source evidence exceeds its approved freshness limits.")
        }
        if referenceOnly || store == .lidl {
            guard !(value.sourceExclusion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else {
                throw CacheError.invalidEvidence("Reference evidence must preserve its comparison exclusion.")
            }
        }
    }
}

/// Operator configuration, never populated from a client request or personal
/// capability prose. Replacing a policy immediately withdraws cached serving.
public final class SourcePolicyRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var policies: [SourcePolicy]
    private var revisions: [String: UUID] = [:]
    public init(policies: [SourcePolicy] = SourcePolicy.disabledCatalog) throws {
        guard policies.count <= 5,
              Set(policies.map { "\($0.store.rawValue)|\($0.storeCode ?? "")|\($0.channel.rawValue)" }).count == policies.count else {
            throw CacheError.invalidRequest("Source policies must have unique exact contexts.")
        }
        self.policies = policies
    }
    func replace(_ policy: SourcePolicy) {
        lock.lock(); defer { lock.unlock() }
        policies.removeAll { $0.store == policy.store && $0.storeCode == policy.storeCode && $0.channel == policy.channel }
        policies.append(policy)
        revisions["\(policy.store.rawValue)|\(policy.storeCode ?? "")|\(policy.channel.rawValue)"] = UUID()
    }
    public func snapshot() -> [SourcePolicy] { lock.lock(); defer { lock.unlock() }; return policies }
    public func authorization(context: PriceContext) throws -> @Sendable () throws -> Void {
        _ = try require(context)
        let revision = revisionFor(context)
        return { [self] in
            _ = try require(context)
            guard revisionFor(context) == revision else { throw CacheError.sourceDisabled }
        }
    }
    func revisionFor(_ context: PriceContext) -> UUID? { lock.lock(); defer { lock.unlock() }; return revisions[SharedPriceCache.contextKey(context)] }
    func require(_ context: PriceContext) throws -> SourcePolicy {
        guard let policy = snapshot().first(where: { $0.matches(context) }), policy.permitted else {
            throw CacheError.sourceDisabled
        }
        return policy
    }
}

public enum SourceState: String, Codable, Sendable { case disabled, pending, ready, partial, failed, stale }
public struct SourceEvidenceDates: Codable, Sendable {
    public let observedAt: Date
    public let retrievedAt: Date
    public let validFrom: Date?
    public let validUntil: Date?
}
public struct PublicSourceStatus: Codable, Sendable {
    public let provider: String
    public let store: StoreID
    public let storeCode: String?
    public let channel: Channel
    public let technicallySupported: Bool
    public let channelVerified: Bool
    public let fetchingEnabled: Bool
    public let publicAccessApproved: Bool
    public let attribution: String
    public let referenceOnly: Bool
    public let limitation: String
    public let cacheTTLSeconds: Double
    public let displayTTLSeconds: Double
    public let maximumObservationAgeSeconds: Double
    public let retentionSeconds: Double
    public let state: SourceState
    public let evidence: SourceEvidenceDates?
    /// Operational context dates; never replace source observation/retrieval dates.
    public let lastAttemptedAt: Date?
    public let lastSucceededAt: Date?
    public let pendingMeaning: String?
    init(policy: SourcePolicy, state: SourceState, evidence: SourceEvidenceDates?, transportReady: Bool, lastAttemptedAt: Date? = nil, lastSucceededAt: Date? = nil) {
        provider = policy.provider; store = policy.store; storeCode = policy.storeCode; channel = policy.channel
        technicallySupported = policy.technicallySupported; channelVerified = policy.technicallySupported; fetchingEnabled = policy.permitted && transportReady
        publicAccessApproved = policy.publicServingApproved; attribution = policy.attribution
        referenceOnly = policy.referenceOnly; limitation = policy.limitation; cacheTTLSeconds = policy.cacheTTL
        displayTTLSeconds = policy.displayTTL; maximumObservationAgeSeconds = policy.maximumObservationAge; retentionSeconds = policy.retention
        self.state = state; self.evidence = evidence
        self.lastAttemptedAt = lastAttemptedAt; self.lastSucceededAt = lastSucceededAt
        pendingMeaning = state == .pending ? "A bounded operation is active, or no accepted evidence exists. Polling does not schedule work; retry only after an explicit user action or next scheduled UTC day." : nil
    }
}
public struct SourceStatusResponse: Codable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let sources: [PublicSourceStatus]
    init(at date: Date, sources: [PublicSourceStatus]) { schemaVersion = 1; generatedAt = date; self.sources = sources }
}
