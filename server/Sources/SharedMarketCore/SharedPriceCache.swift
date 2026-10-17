import Foundation
import StapleScoutKit

/// Shared public evidence only. Neither keys nor payloads contain a user's
/// library, list, substitutions, or library UUIDs.
public actor SharedPriceCache {
    private let storage: SQLiteStore
    private let dailyLimit: Int
    private let monthlyLimit: Int
    private let now: @Sendable () -> Date
    private var pricesInFlight: [String: Task<FetchedPrice, Error>] = [:]
    private var searchesInFlight: [String: Task<RetailSearchPage, Error>] = [:]

    public init(databasePath: String, dailyLimit: Int = 50, monthlyLimit: Int = 250,
                now: @escaping @Sendable () -> Date = { Date() }) throws {
        guard dailyLimit >= 0, monthlyLimit >= 0 else { throw CacheError.invalidRequest("Attempt budgets cannot be negative.") }
        self.storage = try SQLiteStore(path: databasePath)
        self.dailyLimit = dailyLimit
        self.monthlyLimit = monthlyLimit
        self.now = now
    }

    public func price(context: PriceContext, productID: String,
                      fetch: @escaping @Sendable () async throws -> FetchedPrice) async throws -> CachedPrice {
        try Self.validateIdentity(productID, context: context)
        try Task.checkCancellation()
        let checkedAt = now()
        let day = try Self.utcDay(checkedAt)
        let key = try Self.key(kind: "price", context: context, identity: productID)
        if let data = try storage.cached(key: key, day: day) {
            let saved: FetchedPrice = try decode(data)
            if (try? Self.validate(saved, context: context, productID: productID, at: checkedAt)) != nil {
                return CachedPrice(value: saved, cacheHit: true)
            }
        }
        let operation = day + key
        if let task = pricesInFlight[operation] {
            return CachedPrice(value: try await task.value, cacheHit: true)
        }
        // Claim before starting the closure. A second process returns
        // alreadyAttempted while this process works, rather than duplicating it.
        try storage.claim(key: key, day: day, month: String(day.prefix(7)), dailyLimit: dailyLimit, monthlyLimit: monthlyLimit)
        let task = Task<FetchedPrice, Error> {
            let value = try await fetch()
            try self.finishPrice(value, context: context, productID: productID, key: key, day: day)
            return value
        }
        pricesInFlight[operation] = task
        defer { pricesInFlight.removeValue(forKey: operation) }
        return CachedPrice(value: try await task.value, cacheHit: false)
    }

    public func search(context: PriceContext, query: String,
                       fetch: @escaping @Sendable () async throws -> RetailSearchPage) async throws -> CachedSearch {
        let normalized = try Self.normalize(query)
        try Task.checkCancellation()
        let checkedAt = now()
        let day = try Self.utcDay(checkedAt)
        let key = try Self.key(kind: "search", context: context, identity: normalized)
        if let data = try storage.cached(key: key, day: day) {
            let saved: SearchPayload = try decode(data)
            let page = RetailSearchPage(candidates: saved.candidates, message: saved.message)
            if saved.message == nil, (try? Self.validate(page, context: context, at: checkedAt)) != nil {
                return CachedSearch(page: page, cacheHit: true)
            }
        }
        let operation = day + key
        if let task = searchesInFlight[operation] {
            return CachedSearch(page: try await task.value, cacheHit: true)
        }
        try storage.claim(key: key, day: day, month: String(day.prefix(7)), dailyLimit: dailyLimit, monthlyLimit: monthlyLimit)
        let task = Task<RetailSearchPage, Error> {
            let page = try await fetch()
            try self.finishSearch(page, context: context, key: key, day: day)
            return page
        }
        searchesInFlight[operation] = task
        defer { searchesInFlight.removeValue(forKey: operation) }
        return CachedSearch(page: try await task.value, cacheHit: false)
    }

    private func finishPrice(_ value: FetchedPrice, context: PriceContext, productID: String, key: String, day: String) throws {
        let finishedAt = now()
        try Self.validate(value, context: context, productID: productID, at: finishedAt)
        try storage.save(JSONEncoder().encode(value), key: key, day: day, now: finishedAt)
    }

    private func finishSearch(_ page: RetailSearchPage, context: PriceContext, key: String, day: String) throws {
        let finishedAt = now()
        try Self.validate(page, context: context, at: finishedAt)
        // A partial page can be displayed, but its durable claim prevents a
        // retry being silently promoted to a complete result on the same day.
        if page.message == nil {
            try storage.save(JSONEncoder().encode(SearchPayload(candidates: page.candidates, message: page.message)), key: key, day: day, now: finishedAt)
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw CacheError.storage("The persisted shared evidence could not be decoded.") }
    }

    private struct SearchPayload: Codable {
        let candidates: [FetchedPrice]
        let message: String?
    }

    private static func key(kind: String, context: PriceContext, identity: String) throws -> String {
        let values = [kind, context.store.rawValue, context.storeCode ?? "", context.channel.rawValue, identity]
        return String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
    }

    private static func utcDay(_ date: Date) throws -> String {
        guard date.timeIntervalSince1970.isFinite else { throw CacheError.invalidRequest("The cache clock is invalid.") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }

    private static func normalize(_ query: String) throws -> String {
        guard !query.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CacheError.invalidRequest("Search queries cannot contain control characters.")
        }
        let normalized = query.precomposedStringWithCanonicalMapping
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased(with: Locale(identifier: "en_US_POSIX"))
        guard (2...100).contains(normalized.count) else { throw CacheError.invalidRequest("Enter a search query between 2 and 100 characters.") }
        return normalized
    }

    private static func validateIdentity(_ identity: String, context: PriceContext) throws {
        func numeric(_ text: Substring) -> Bool { (1...20).contains(text.utf8.count) && text.utf8.allSatisfy { (48...57).contains($0) } }
        let pieces = identity.split(separator: ":", omittingEmptySubsequences: false)
        let valid = context.store == .hmart ? pieces.count == 2 && pieces.allSatisfy(numeric) : pieces.count == 1 && pieces.allSatisfy(numeric)
        guard valid else { throw CacheError.invalidRequest("The retailer product identity is invalid.") }
    }

    private static func validate(_ page: RetailSearchPage, context: PriceContext, at date: Date) throws {
        guard page.candidates.count <= 5, page.message.map({ $0.utf8.count <= 4_096 }) ?? true else {
            throw CacheError.invalidEvidence("The source returned an oversized search page.")
        }
        var identities = Set<String>()
        for value in page.candidates {
            guard identities.insert(value.productID).inserted else { throw CacheError.invalidEvidence("The source returned duplicate search identities.") }
            try validate(value, context: context, productID: value.productID, at: date)
        }
    }

    private static func validate(_ value: FetchedPrice, context: PriceContext, productID: String, at date: Date) throws {
        guard value.productID == productID else { throw CacheError.invalidEvidence("The source returned a different product identity.") }
        do { try validateIdentity(value.productID, context: context) }
        catch { throw CacheError.invalidEvidence("The source returned an invalid product identity.") }
        guard value.source.rawValue == context.store.rawValue,
              !value.productName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.productName.utf8.count <= 4_096, value.conditions.utf8.count <= 32_768,
              value.barcode.map({ $0.utf8.count <= 256 }) ?? true,
              value.sourceExclusion.map({ $0.utf8.count <= 8_192 }) ?? true,
              value.packCount > 0,
              value.price.map({ !$0.isNaN && $0 >= 0 }) ?? true,
              value.quantity.map({ !$0.isNaN && $0 > 0 }) ?? true,
              (value.quantity == nil) == (value.unit == nil) else {
            throw CacheError.invalidEvidence("The source returned inconsistent price or package metadata.")
        }
        let observed = value.observedAt.timeIntervalSince1970
        let retrieved = value.retrievedAt.timeIntervalSince1970
        let current = date.timeIntervalSince1970
        guard current.isFinite, observed.isFinite, retrieved.isFinite,
              observed > 0, retrieved > 0, observed <= retrieved, retrieved <= current,
              current - observed < 48 * 60 * 60 else {
            throw CacheError.invalidEvidence("The source evidence has invalid timestamps or is at least 48 hours old.")
        }
        if let start = value.validFrom {
            guard start.timeIntervalSince1970.isFinite, start <= date else { throw CacheError.invalidEvidence("The source offer has not started.") }
        }
        if let end = value.validUntil {
            guard end.timeIntervalSince1970.isFinite, date < end else { throw CacheError.invalidEvidence("The source offer has expired.") }
        }
        if let start = value.validFrom, let end = value.validUntil, start >= end {
            throw CacheError.invalidEvidence("The source offer has an inconsistent validity window.")
        }
        try validateSourceURL(value.sourceURL, productID: productID, context: context)
        if context.store == .lidl {
            guard value.available == nil, value.validFrom != nil, value.validUntil != nil,
                  !(value.sourceExclusion?.isEmpty ?? true) else {
                throw CacheError.invalidEvidence("Lidl regional evidence must preserve unknown local stock and its validity window.")
            }
        }
        if context.store == .hmart, value.sourceExclusion?.isEmpty ?? true {
            throw CacheError.invalidEvidence("H Mart online evidence must preserve its local-price exclusion.")
        }
    }

    private static func validateSourceURL(_ text: String, productID: String, context: PriceContext) throws {
        guard text.utf8.count <= 4_096, let url = URLComponents(string: text), url.scheme == "https",
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil else {
            throw CacheError.invalidEvidence("The source evidence has an invalid public retailer URL.")
        }
        let valid: Bool
        switch context.store {
        case .wegmans:
            valid = url.host == "www.wegmans.com" && url.path == "/api/products/133/\(productID)" && url.query == nil
        case .hmart:
            let product = productID.split(separator: ":")[0]
            let terms = url.queryItems?.filter { $0.name == "fq" } ?? []
            valid = url.host == "www.hmart.com" && url.path == "/api/catalog_system/pub/products/search/"
                && terms.count == 1 && terms[0].value == "productId:\(product)"
        case .lidl:
            valid = url.host == "www.lidl.com" && url.path.hasPrefix("/p/") && url.path.hasSuffix("/p\(productID)") && url.query == nil
        case .target, .walmart: valid = false
        }
        guard valid else { throw CacheError.invalidEvidence("The public source URL does not match the requested retailer, location, and product.") }
    }
}
