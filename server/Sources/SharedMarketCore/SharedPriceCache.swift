import Foundation
import StapleScoutKit
import ServiceOwnership

/// Admission is completed only by the single-flight leader, before the durable
/// logical cache claim. Denied clients cannot poison another client's key.
public struct CacheFetchOperation<Value: Sendable>: Sendable {
    let run: @Sendable () async throws -> Value
    let finish: @Sendable () async throws -> Void
    public init(run: @escaping @Sendable () async throws -> Value, finish: @escaping @Sendable () async throws -> Void = {}) {
        self.run = run; self.finish = finish
    }
}

/// Shared public evidence only. Neither keys nor payloads contain a user's
/// library, list, substitutions, or library UUIDs.
public actor SharedPriceCache {
    private let storage: SQLiteStore
    public nonisolated let policies: SourcePolicyRegistry
    private let ownership: ServiceOwnership?
    private var stopping = false
    private let dailyLimit: Int
    private let monthlyLimit: Int
    private let now: @Sendable () -> Date
    private let maximumInFlight: Int
    private let maximumFollowers: Int
    private var followers: [String: Int] = [:]
    private var pricesInFlight: [String: Task<FetchedPrice, Error>] = [:]
    private var searchesInFlight: [String: Task<RetailSearchPage, Error>] = [:]

    public init(databasePath: String, dailyLimit: Int = 50, monthlyLimit: Int = 250, maximumInFlight: Int = 4, maximumFollowers: Int = 50, policies: SourcePolicyRegistry? = nil, ownership: ServiceOwnership? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) throws {
        guard dailyLimit >= 0, monthlyLimit >= 0, (1...32).contains(maximumInFlight), (1...100).contains(maximumFollowers) else { throw CacheError.invalidRequest("The cache attempt or concurrency limits are invalid.") }
        try ownership?.claimDatabase(databasePath)
        self.ownership = ownership
        self.policies = try policies ?? SourcePolicyRegistry()
        self.storage = try SQLiteStore(path: databasePath)
        self.dailyLimit = dailyLimit
        self.monthlyLimit = monthlyLimit
        self.now = now
        self.maximumInFlight = maximumInFlight; self.maximumFollowers = maximumFollowers
        _ = try Self.utcDay(now())
        try Self.maintain(storage: storage, policies: self.policies, at: now())
        if ownership != nil { try storage.recoverPending() }
    }

    public func price(context: PriceContext, productID: String,
                      fetch: @escaping @Sendable () async throws -> FetchedPrice) async throws -> CachedPrice {
        try await admittedPrice(context: context, productID: productID, admit: { CacheFetchOperation(run: fetch) })
    }

    public func admittedPrice(context: PriceContext, productID: String,
                      admit: @escaping @Sendable () async throws -> CacheFetchOperation<FetchedPrice>) async throws -> CachedPrice {
        try checkRunning()
        try Self.validateIdentity(productID, context: context)
        try Task.checkCancellation()
        try maintain()
        let policy = try policies.require(context)
        let revision = policies.revisionFor(context)
        let checkedAt = now()
        let day = try Self.utcDay(checkedAt)
        let key = try Self.key(kind: "price", context: context, identity: productID)
        if let entry = try storage.cached(key: key, day: day), entry.policy == policy.fingerprint {
            let saved: FetchedPrice = try decode(entry.data)
            if (try? policy.validateCache(at: checkedAt, insertedAt: entry.insertedAt)) != nil, (try? Self.validate(saved, context: context, productID: productID, at: checkedAt)) != nil,
               (try? policy.validate(saved, at: checkedAt, insertedAt: entry.insertedAt)) != nil {
                return CachedPrice(value: saved, cacheHit: true)
            }
        }
        let operation = day + key
        if let task = pricesInFlight[operation] {
            try addFollower(operation)
            defer { removeFollower(operation) }
            let value = try await task.value
            try authorize(policy, context: context, revision: revision)
            try Self.validate(value, context: context, productID: productID, at: now())
            try policy.validate(value, at: now(), insertedAt: nil)
            return CachedPrice(value: value, cacheHit: true)
        }
        // Register the leader before awaiting admission. The durable claim
        // still precedes fetching; another process cannot repeat that fetch.
        guard pricesInFlight.count + searchesInFlight.count < maximumInFlight else { throw CacheError.pending("The upstream work limit is busy.") }
        let task = Task<FetchedPrice, Error> {
            let work = try await admit()
            var started = false
            do {
                try self.authorize(policy, context: context, revision: revision)
                try self.storage.claim(key: key, day: day, month: String(day.prefix(7)), dailyLimit: self.dailyLimit, monthlyLimit: self.monthlyLimit)
                started = true
                try self.record(.pending, context: context, day: day)
                try self.authorize(policy, context: context, revision: revision)
                let value = try await work.run()
                try self.authorize(policy, context: context, revision: revision)
                try await work.finish()
                try self.finishPrice(value, context: context, productID: productID, key: key, day: day, policy: policy, revision: revision)
                try self.record(.ready, context: context, day: day)
                return value
            } catch { try? await work.finish(); if started && self.policies.revisionFor(context) == revision { try? self.record(.failed, context: context, day: day) }; throw error }
        }
        pricesInFlight[operation] = task
        defer { pricesInFlight.removeValue(forKey: operation) }
        let value = try await task.value
        try authorize(policy, context: context, revision: revision)
        try Self.validate(value, context: context, productID: productID, at: now())
        try policy.validate(value, at: now(), insertedAt: nil)
        return CachedPrice(value: value, cacheHit: false)
    }

    public func search(context: PriceContext, query: String,
                       fetch: @escaping @Sendable () async throws -> RetailSearchPage) async throws -> CachedSearch {
        try await admittedSearch(context: context, query: query, admit: { CacheFetchOperation(run: fetch) })
    }

    public func admittedSearch(context: PriceContext, query: String,
                       admit: @escaping @Sendable () async throws -> CacheFetchOperation<RetailSearchPage>) async throws -> CachedSearch {
        try checkRunning()
        try maintain()
        let policy = try policies.require(context)
        let revision = policies.revisionFor(context)
        let normalized = try Self.normalize(query)
        try Task.checkCancellation()
        let checkedAt = now()
        let day = try Self.utcDay(checkedAt)
        let key = try Self.key(kind: "search", context: context, identity: normalized)
        if let entry = try storage.cached(key: key, day: day), entry.policy == policy.fingerprint {
            let saved: SearchPayload = try decode(entry.data)
            if (try? policy.validateCache(at: checkedAt, insertedAt: entry.insertedAt)) == nil {
                try storage.delete(key: key)
            }
            let page = RetailSearchPage(candidates: saved.candidates, message: saved.message)
            if (try? policy.validateCache(at: checkedAt, insertedAt: entry.insertedAt)) != nil, saved.message == nil, (try? Self.validate(page, context: context, at: checkedAt)) != nil,
               page.candidates.allSatisfy({ (try? policy.validate($0, at: checkedAt, insertedAt: entry.insertedAt)) != nil }) {
                return CachedSearch(page: page, cacheHit: true)
            }
        }
        let operation = day + key
        if let task = searchesInFlight[operation] {
            try addFollower(operation)
            defer { removeFollower(operation) }
            let page = try await task.value
            try authorize(policy, context: context, revision: revision)
            try Self.validate(page, context: context, at: now())
            for value in page.candidates { try policy.validate(value, at: now(), insertedAt: nil) }
            return CachedSearch(page: page, cacheHit: true)
        }
        guard pricesInFlight.count + searchesInFlight.count < maximumInFlight else { throw CacheError.pending("The upstream work limit is busy.") }
        let task = Task<RetailSearchPage, Error> {
            let work = try await admit()
            var started = false
            do {
                try self.authorize(policy, context: context, revision: revision)
                try self.storage.claim(key: key, day: day, month: String(day.prefix(7)), dailyLimit: self.dailyLimit, monthlyLimit: self.monthlyLimit)
                started = true
                try self.record(.pending, context: context, day: day)
                try self.authorize(policy, context: context, revision: revision)
                let page = try await work.run()
                try self.authorize(policy, context: context, revision: revision)
                try await work.finish()
                try self.finishSearch(page, context: context, key: key, day: day, policy: policy, revision: revision)
                try self.record(page.message == nil ? .ready : .partial, context: context, day: day)
                return page
            } catch { try? await work.finish(); if started && self.policies.revisionFor(context) == revision { try? self.record(.failed, context: context, day: day) }; throw error }
        }
        searchesInFlight[operation] = task
        defer { searchesInFlight.removeValue(forKey: operation) }
        let page = try await task.value
        try authorize(policy, context: context, revision: revision)
        try Self.validate(page, context: context, at: now())
        for value in page.candidates { try policy.validate(value, at: now(), insertedAt: nil) }
        return CachedSearch(page: page, cacheHit: false)
    }

    public nonisolated func authorization(context: PriceContext) throws -> @Sendable () throws -> Void {
        let source = try policies.authorization(context: context)
        return { [self] in try ownership?.validate(); try source() }
    }
    public nonisolated func validateForServing(_ value: FetchedPrice, context: PriceContext, at date: Date) throws {
        try ownership?.validate()
        let policy = try policies.require(context)
        try Self.validate(value, context: context, productID: value.productID, at: date)
        try policy.validate(value, at: date, insertedAt: nil)
    }
    private func record(_ state: SourceState, context: PriceContext, day: String) throws {
        try storage.record(state: state, context: Self.contextKey(context), day: day)
    }
    private func checkRunning() throws {
        try ownership?.validate()
        guard !stopping else { throw CacheError.shuttingDown }
    }
    private func authorize(_ expected: SourcePolicy, context: PriceContext, revision: UUID?) throws {
        try checkRunning()
        guard try policies.require(context).fingerprint == expected.fingerprint, policies.revisionFor(context) == revision else { throw CacheError.sourceDisabled }
    }
    public func replacePolicy(_ policy: SourcePolicy) throws { try replacePolicy(policy, purgeCheckpoint: {}) }
    func replacePolicy(_ policy: SourcePolicy, purgeCheckpoint: () throws -> Void) throws {
        try checkRunning()
        // Install denial first. Storage failure cannot leave the old license
        // active, and every old in-flight authorization is invalidated now.
        policies.replace(policy.denied())
        try purgeCheckpoint()
        for kind in ["price", "search"] { try storage.purge(prefix: Self.prefix(kind: kind, store: policy.store, code: policy.storeCode, channel: policy.channel)) }
        try storage.clearRecorded(context: Self.contextKey(store: policy.store, code: policy.storeCode, channel: policy.channel))
        policies.replace(policy)
    }
    public func shutdown() async {
        stopping = true
        let prices = Array(pricesInFlight.values); let searches = Array(searchesInFlight.values)
        for task in prices { task.cancel() }; for task in searches { task.cancel() }
        for task in prices { _ = await task.result }; for task in searches { _ = await task.result }
    }
    private func maintain() throws { _ = try Self.utcDay(now()); try Self.maintain(storage: storage, policies: policies, at: now()) }
    private static func maintain(storage: SQLiteStore, policies: SourcePolicyRegistry, at date: Date) throws {
        let policies = policies.snapshot()
        for key in try storage.entryKeys() {
            guard let entry = try storage.entry(key: key) else { continue }
            guard let parts = try? JSONDecoder().decode([String].self, from: Data(key.utf8)), parts.count == 5,
                  let policy = policies.first(where: { $0.store.rawValue == parts[1] && ($0.storeCode ?? "") == parts[2] && $0.channel.rawValue == parts[3] }),
                  policy.permitted, policy.fingerprint == entry.policy,
                  date >= entry.insertedAt, date.timeIntervalSince(entry.insertedAt) < policy.retention else {
                try storage.delete(key: key); continue
            }
            let values: [FetchedPrice]
            if parts[0] == "price", let value = try? JSONDecoder().decode(FetchedPrice.self, from: entry.data) { values = [value] }
            else if parts[0] == "search", let page = try? JSONDecoder().decode(SearchPayload.self, from: entry.data) { values = page.candidates }
            else { try storage.delete(key: key); continue }
            if values.contains(where: { date.timeIntervalSince($0.retrievedAt) >= policy.retention }) { try storage.delete(key: key) }
        }
    }
    static func contextKey(_ context: PriceContext) -> String { contextKey(store: context.store, code: context.storeCode, channel: context.channel) }
    static func contextKey(store: StoreID, code: String?, channel: Channel) -> String { "\(store.rawValue)|\(code ?? "")|\(channel.rawValue)" }
    private static func prefix(kind: String, store: StoreID, code: String?, channel: Channel) -> String {
        let value = String(decoding: try! JSONEncoder().encode([kind, store.rawValue, code ?? "", channel.rawValue]), as: UTF8.self)
        return String(value.dropLast()) + ","
    }
    public func sourceStatuses(transportReady: Bool) throws -> SourceStatusResponse {
        try ownership?.validate()
        try maintain()
        let date = now(); let entries = try storage.entryKeys()
        return SourceStatusResponse(at: date, sources: try policies.snapshot().map { policy in
            var evidence: FetchedPrice?
            var usable = false
            for key in entries {
                guard let entry = try storage.entry(key: key) else { continue }
                let isPrice = key.hasPrefix(Self.prefix(kind: "price", store: policy.store, code: policy.storeCode, channel: policy.channel))
                let isSearch = key.hasPrefix(Self.prefix(kind: "search", store: policy.store, code: policy.storeCode, channel: policy.channel))
                guard isPrice || isSearch else { continue }
                let values: [FetchedPrice]
                if isPrice, let value = try? JSONDecoder().decode(FetchedPrice.self, from: entry.data) { values = [value] }
                else if isSearch, let page = try? JSONDecoder().decode(SearchPayload.self, from: entry.data), page.message == nil { values = page.candidates }
                else { continue }
                var valid = (try? policy.validateCache(at: date, insertedAt: entry.insertedAt)) != nil
                for value in values {
                    if evidence == nil || value.observedAt > evidence!.observedAt { evidence = value }
                    if (try? policy.validate(value, at: date, insertedAt: entry.insertedAt)) == nil ||
                       (try? PriceContext(store: policy.store, storeCode: policy.storeCode, channel: policy.channel)).map({ (try? Self.validate(value, context: $0, productID: value.productID, at: date)) != nil }) != true { valid = false }
                }
                if valid && entry.day == (try? Self.utcDay(date)) { usable = true }
            }
            let state: SourceState
            let recorded = try storage.recorded(context: Self.contextKey(store: policy.store, code: policy.storeCode, channel: policy.channel))
            if !policy.permitted || !transportReady || stopping { state = .disabled }
            else if let recorded, [.pending, .partial, .failed].contains(recorded) { state = recorded }
            else if usable { state = .ready }
            else if evidence != nil || recorded == .ready || recorded == .stale { state = .stale }
            else { state = .pending }
            return PublicSourceStatus(policy: policy, state: state, evidence: evidence.map { SourceEvidenceDates(observedAt: $0.observedAt, retrievedAt: $0.retrievedAt, validFrom: $0.validFrom, validUntil: $0.validUntil) }, transportReady: transportReady && !stopping)
        })
    }
    public struct KnownProduct: Sendable { public let context: PriceContext; public let productID: String }
    public func beginScheduledRun(enabled: Bool, maximumProducts: Int = 50) throws -> (day: String, products: [KnownProduct])? {
        try checkRunning()
        guard enabled else { return nil }
        guard (1...50).contains(maximumProducts) else { throw CacheError.invalidRequest("The scheduled refresh bound is invalid.") }
        try maintain()
        let day = try Self.utcDay(now())
        guard try storage.claimScheduled(day: day) else { return nil }
        var products: [KnownProduct] = []
        for key in try storage.entryKeys() {
            guard products.count < maximumProducts,
                  let parts = try? JSONDecoder().decode([String].self, from: Data(key.utf8)), parts.count == 5, parts[0] == "price",
                  let store = StoreID(rawValue: parts[1]), let channel = Channel(rawValue: parts[3]),
                  let context = try? PriceContext(store: store, storeCode: parts[2].isEmpty ? nil : parts[2], channel: channel),
                  (try? policies.require(context)) != nil else { continue }
            products.append(KnownProduct(context: context, productID: parts[4]))
        }
        return (day, products)
    }
    public func scheduledDayIsCurrent(_ day: String) throws -> Bool { try checkRunning(); return try Self.utcDay(now()) == day }

    private func addFollower(_ operation: String) throws {
        guard followers[operation, default: 0] < maximumFollowers else { throw CacheError.pending("The shared operation has enough waiting requests.") }
        followers[operation, default: 0] += 1
    }
    private func removeFollower(_ operation: String) {
        if followers[operation, default: 0] <= 1 { followers.removeValue(forKey: operation) }
        else { followers[operation, default: 0] -= 1 }
    }

    private func finishPrice(_ value: FetchedPrice, context: PriceContext, productID: String, key: String, day: String, policy: SourcePolicy, revision: UUID?) throws {
        let finishedAt = now()
        try authorize(policy, context: context, revision: revision)
        try Self.validate(value, context: context, productID: productID, at: finishedAt)
        try policy.validate(value, at: finishedAt, insertedAt: nil)
        try storage.save(JSONEncoder().encode(value), key: key, day: day, now: finishedAt, policy: policy.fingerprint)
    }

    private func finishSearch(_ page: RetailSearchPage, context: PriceContext, key: String, day: String, policy: SourcePolicy, revision: UUID?) throws {
        let finishedAt = now()
        try authorize(policy, context: context, revision: revision)
        try Self.validate(page, context: context, at: finishedAt)
        for value in page.candidates { try policy.validate(value, at: finishedAt, insertedAt: nil) }
        // A partial page can be displayed, but its durable claim prevents a
        // retry being silently promoted to a complete result on the same day.
        if page.message == nil {
            try storage.save(JSONEncoder().encode(SearchPayload(candidates: page.candidates, message: page.message)), key: key, day: day, now: finishedAt, policy: policy.fingerprint)
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

    static func utcDay(_ date: Date) throws -> String {
        guard date.timeIntervalSince1970.isFinite, (0..<253_402_300_800).contains(date.timeIntervalSince1970) else { throw CacheError.invalidRequest("The cache clock is invalid.") }
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

    static func validateIdentity(_ identity: String, context: PriceContext) throws {
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
                && url.queryItems?.count == 1 && terms.count == 1 && terms[0].value == "productId:\(product)"
        case .lidl:
            valid = url.host == "www.lidl.com" && url.path.hasPrefix("/p/") && url.path.hasSuffix("/p\(productID)") && url.query == nil
        case .target, .walmart: valid = false
        }
        guard valid else { throw CacheError.invalidEvidence("The public source URL does not match the requested retailer, location, and product.") }
    }
}
