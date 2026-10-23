import Foundation
import StapleScoutKit

/// The public pilot accepts only the native client's verified Chantilly contexts.
/// UUIDs belong to an individual library and never participate in a shared key.
public struct PriceContext: Codable, Hashable, Sendable {
    public let store: StoreID
    public let storeCode: String?
    public let channel: Channel

    public init(store: StoreID, storeCode: String?, channel: Channel) throws {
        let supported: Bool
        switch (store, storeCode, channel) {
        case (.wegmans, "133", .inStore), (.hmart, nil, .online), (.lidl, "US01112", .inStore): supported = true
        default: supported = false
        }
        guard supported else {
            throw CacheError.invalidRequest("This store, location, and channel are not supported by the Chantilly pilot.")
        }
        self.store = store
        self.storeCode = storeCode
        self.channel = channel
    }

    public var location: StoreLocation {
        // Construction and decoding both establish this invariant.
        StoreLocation.defaults.first { $0.store == store && $0.code == storeCode }!
    }

    private enum CodingKeys: String, CodingKey { case store, storeCode, channel }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(store: values.decode(StoreID.self, forKey: .store),
                      storeCode: values.decodeIfPresent(String.self, forKey: .storeCode),
                      channel: values.decode(Channel.self, forKey: .channel))
    }
}

public struct CachedPrice: Sendable {
    public let value: FetchedPrice
    public let cacheHit: Bool
    public init(value: FetchedPrice, cacheHit: Bool) { self.value = value; self.cacheHit = cacheHit }
}

public struct CachedSearch: Sendable {
    public let page: RetailSearchPage
    public let cacheHit: Bool
    public init(page: RetailSearchPage, cacheHit: Bool) { self.page = page; self.cacheHit = cacheHit }
}

public enum CacheError: Error, LocalizedError, Sendable {
    case invalidRequest(String)
    case invalidEvidence(String)
    case budgetExceeded(String)
    case alreadyAttempted(String)
    case storage(String)
    case pending(String)
    case sourceDisabled
    case shuttingDown

    public var errorDescription: String? {
        switch self {
        case .sourceDisabled: return "Public access to this exact source context is disabled."
        case .shuttingDown: return "The shared service is shutting down."
        case .invalidRequest(let message), .invalidEvidence(let message), .budgetExceeded(let message),
             .alreadyAttempted(let message), .storage(let message), .pending(let message): return message
        }
    }
}
