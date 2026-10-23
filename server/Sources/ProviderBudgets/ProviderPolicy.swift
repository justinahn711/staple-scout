import Foundation

public enum ProviderBudgetError: Error, Sendable, Equatable {
    case disabled, providerLimit, clientLimit, workPending, operationLimit, invalidRequest, storageUnavailable, networkUnavailable
}

/// A single pooled SerpApi account. Positive policies are injectable for offline
/// fixtures only; the executable has no provider activation/key/cap override.
public struct ProviderBudgetPolicy: Sendable {
    public let providerHourly: Int
    public let providerDaily: Int
    public let providerMonthly: Int
    public let clientDaily: Int
    public let clientMonthly: Int
    public let globalMissesDaily: Int
    public let globalMissesMonthly: Int
    public let clientMissesDaily: Int
    public let clientMissesMonthly: Int
    public let maximumConcurrentMisses: Int
    public let maximumConcurrentRequests: Int
    public let maximumRequestsPerMiss: Int

    public init(providerHourly: Int = 0, providerDaily: Int = 0, providerMonthly: Int = 0,
                clientDaily: Int = 0, clientMonthly: Int = 0, globalMissesDaily: Int = 0,
                globalMissesMonthly: Int = 0, clientMissesDaily: Int = 0, clientMissesMonthly: Int = 0,
                maximumConcurrentMisses: Int = 4, maximumConcurrentRequests: Int = 4, maximumRequestsPerMiss: Int = 8) throws {
        guard (0...50).contains(providerHourly), (0...250).contains(providerDaily), (0...250).contains(providerMonthly),
              (0...250).contains(clientDaily), (0...250).contains(clientMonthly),
              (0...50).contains(globalMissesDaily), (0...250).contains(globalMissesMonthly),
              (0...50).contains(clientMissesDaily), (0...250).contains(clientMissesMonthly),
              (1...8).contains(maximumConcurrentMisses), (1...8).contains(maximumConcurrentRequests),
              (1...8).contains(maximumRequestsPerMiss) else { throw ProviderBudgetError.invalidRequest }
        self.providerHourly = providerHourly; self.providerDaily = providerDaily; self.providerMonthly = providerMonthly
        self.clientDaily = clientDaily; self.clientMonthly = clientMonthly
        self.globalMissesDaily = globalMissesDaily; self.globalMissesMonthly = globalMissesMonthly
        self.clientMissesDaily = clientMissesDaily; self.clientMissesMonthly = clientMissesMonthly
        self.maximumConcurrentMisses = maximumConcurrentMisses; self.maximumConcurrentRequests = maximumConcurrentRequests
        self.maximumRequestsPerMiss = maximumRequestsPerMiss
    }
    public var enabled: Bool {
        [providerHourly, providerDaily, providerMonthly, clientDaily, clientMonthly, globalMissesDaily,
         globalMissesMonthly, clientMissesDaily, clientMissesMonthly].allSatisfy { $0 > 0 }
    }
}

public enum ProviderPurpose: String, Codable, Sendable { case search, pagination, candidate, detail, retry }
public enum SerpAPIEngine: String, Codable, Sendable { case target, walmart, walmartProduct = "walmart_product" }

/// Rebuild pagination/detail requests from validated fields; never follow an
/// upstream-supplied URL. No arbitrary host, path, headers, key or URL is accepted.
public struct ProviderHTTPRequest: Sendable {
    public let engine: SerpAPIEngine
    public let purpose: ProviderPurpose
    public let url: URL
    public init(engine: SerpAPIEngine, query: String? = nil, productID: String? = nil,
                page: Int = 1, purpose: ProviderPurpose) throws {
        guard (1...3).contains(page) else { throw ProviderBudgetError.invalidRequest }
        var items = [URLQueryItem(name: "engine", value: engine.rawValue),
                     URLQueryItem(name: "store_id", value: engine == .target ? "1827" : "5969")]
        if engine == .walmartProduct {
            guard page == 1, query == nil, let identity = productID,
                  identity.range(of: #"^[0-9A-Za-z]{1,20}$"#, options: .regularExpression) != nil,
                  [.candidate, .detail, .retry].contains(purpose) else { throw ProviderBudgetError.invalidRequest }
            items.append(URLQueryItem(name: "product_id", value: identity))
        } else {
            guard productID == nil, let query, (2...100).contains(query.count), query.utf8.count <= 400,
                  !query.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  [.search, .pagination, .retry].contains(purpose) else { throw ProviderBudgetError.invalidRequest }
            items.append(URLQueryItem(name: engine == .walmart ? "query" : "q", value: query))
            items.append(URLQueryItem(name: "page", value: String(page)))
        }
        var components = URLComponents()
        components.scheme = "https"; components.host = "serpapi.com"; components.path = "/search.json"; components.queryItems = items
        guard let url = components.url else { throw ProviderBudgetError.invalidRequest }
        self.engine = engine; self.purpose = purpose; self.url = url
    }
}

public struct ProviderUsageWindow: Codable, Sendable {
    public let scope: String
    public let cap: Int
    public let reserved: Int
    public let attempted: Int
    /// Completed HTTP 2xx reservations: a local upper bound, NOT billed usage.
    public let consumedUpperBound: Int
    public let uncertain: Int
    public let pending: Int
    public var remaining: Int { max(0, cap - reserved) }
    private enum CodingKeys: String, CodingKey { case scope, cap, reserved, attempted, consumedUpperBound, uncertain, pending, remaining }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        scope = try values.decode(String.self, forKey: .scope); cap = try values.decode(Int.self, forKey: .cap)
        reserved = try values.decode(Int.self, forKey: .reserved); attempted = try values.decode(Int.self, forKey: .attempted)
        consumedUpperBound = try values.decode(Int.self, forKey: .consumedUpperBound)
        uncertain = try values.decode(Int.self, forKey: .uncertain); pending = try values.decode(Int.self, forKey: .pending)
    }
    init(scope: String, cap: Int, reserved: Int, attempted: Int, consumedUpperBound: Int, pending: Int) {
        self.scope = scope; self.cap = cap; self.reserved = reserved; self.attempted = attempted
        self.consumedUpperBound = consumedUpperBound; self.uncertain = reserved - consumedUpperBound; self.pending = pending
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(scope, forKey: .scope); try values.encode(cap, forKey: .cap)
        try values.encode(reserved, forKey: .reserved); try values.encode(attempted, forKey: .attempted)
        try values.encode(consumedUpperBound, forKey: .consumedUpperBound); try values.encode(uncertain, forKey: .uncertain)
        try values.encode(pending, forKey: .pending); try values.encode(remaining, forKey: .remaining)
    }
}

public struct ProviderUsageSnapshot: Encodable, Sendable {
    public let schemaVersion = 1
    public let provider = "serpapi"
    public let accounting = "conservative_local_reservations"
    public let sourceApproved = false
    public let enabled: Bool
    public let providerReportedUnits: Int? = nil
    public let windows: [ProviderUsageWindow]
    private enum CodingKeys: String, CodingKey { case schemaVersion, provider, accounting, sourceApproved, enabled, providerReportedUnits, windows }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion); try values.encode(provider, forKey: .provider)
        try values.encode(accounting, forKey: .accounting); try values.encode(sourceApproved, forKey: .sourceApproved)
        try values.encode(enabled, forKey: .enabled); try values.encodeNil(forKey: .providerReportedUnits)
        try values.encode(windows, forKey: .windows)
    }
}
