import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct RetailSearchPage: Sendable {
    public var candidates: [FetchedPrice]
    public var message: String?
    public init(candidates: [FetchedPrice], message: String? = nil) {
        self.candidates = candidates; self.message = message
    }
}

/// Keyword discovery never treats search-index prices as verified shelf offers.
/// Each discovered identity is checked with the existing exact-product client.
public actor RetailSearchClient {
    private let session: URLSession
    private let prices: RetailClient
    private var wegmansConfiguration: (appID: String, key: String)?
    private var cache: [String: RetailSearchPage] = [:]

    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
        self.prices = RetailClient(session: session)
    }

    public func search(query: String, location: StoreLocation, channel: Channel) async throws -> RetailSearchPage {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...100).contains(query.count), !query.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw RetailClientError.invalidProduct("Enter a product name between 2 and 100 characters.")
        }
        let capability = SourceCapability.forLocation(location, channel: channel)
        guard capability.isConnected else { throw RetailClientError.unsupportedSource(capability.message) }
        let day = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        let cacheKey = "\(day):\(location.id):\(channel.rawValue):\(query.lowercased())"
        let checkedAt = Date()
        if let saved = cache[cacheKey], saved.candidates.allSatisfy({ candidate in
            if let start = candidate.validFrom, checkedAt < start { return false }
            if let end = candidate.validUntil, checkedAt >= end { return false }
            return true
        }) { return saved }
        try Task.checkCancellation()
        if location.store == .lidl {
            let page = try await LidlClient(session: session).search(query: query, location: location, channel: channel)
            try Task.checkCancellation()
            save(page, key: cacheKey, day: day, successful: page.message == nil)
            return page
        }
        let identities: [String]
        switch location.store {
        case .wegmans: identities = try await wegmansIdentities(query: query)
        case .hmart: identities = try await hmartIdentities(query: query)
        default: throw RetailClientError.unsupportedSource(capability.message)
        }
        var candidates: [FetchedPrice] = []
        var failures = 0
        for identity in identities {
            try Task.checkCancellation()
            let variant = ProductVariant(store: location.store, productID: identity, name: query, quantity: 1, unit: .each, quantityKind: .variable)
            do { candidates.append(try await prices.fetch(FetchRequest(variant: variant, location: location, channel: channel))) }
            catch is CancellationError { throw CancellationError() }
            catch { failures += 1 }
        }
        try Task.checkCancellation()
        let message = failures == 0 ? nil : "\(failures) product prices could not be checked. Only successfully checked products are shown."
        let page = RetailSearchPage(candidates: candidates, message: message)
        save(page, key: cacheKey, day: day, successful: failures == 0)
        return page
    }

    private func save(_ page: RetailSearchPage, key: String, day: String, successful: Bool) {
        cache = cache.filter { $0.key.hasPrefix(day + ":") }
        if cache.count >= 50 { cache.removeAll() }
        if successful { cache[key] = page }
    }

    private func hmartIdentities(query: String) async throws -> [String] {
        var url = URLComponents(string: "https://www.hmart.com/api/catalog_system/pub/products/search/")!
        url.queryItems = [URLQueryItem(name: "ft", value: query), URLQueryItem(name: "_from", value: "0"), URLQueryItem(name: "_to", value: "4")]
        let object = try JSONSerialization.jsonObject(with: await load(URLRequest(url: url.url!)))
        guard let products = object as? [[String: Any]], products.count <= 5 else {
            throw RetailClientError.invalidResponse("H Mart returned an unreadable product search.")
        }
        var identities: [String] = []
        for product in products {
            guard let productID = product["productId"] as? String, numeric(productID), let items = product["items"] as? [[String: Any]] else {
                throw RetailClientError.invalidResponse("H Mart returned a product without a valid identity.")
            }
            for item in items {
                guard let itemID = item["itemId"] as? String, numeric(itemID) else {
                    throw RetailClientError.invalidResponse("H Mart returned a product without a valid SKU.")
                }
                let identity = "\(productID):\(itemID)"
                if !identities.contains(identity) { identities.append(identity) }
                if identities.count == 5 { return identities }
            }
        }
        return identities
    }

    private func wegmansIdentities(query: String) async throws -> [String] {
        let configuration = try await publishedWegmansConfiguration()
        let url = URL(string: "https://\(configuration.appID.lowercased())-dsn.algolia.net/1/indexes/products_v2/query")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(configuration.appID, forHTTPHeaderField: "X-Algolia-Application-Id")
        request.setValue(configuration.key, forHTTPHeaderField: "X-Algolia-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query, "hitsPerPage": 5, "analytics": false, "clickAnalytics": false,
            "filters": "soldAtStores:133 AND fulfillmentInStore:133 AND excludeFromWeb:false"
        ])
        let object = try JSONSerialization.jsonObject(with: await load(request))
        guard let response = object as? [String: Any], let hits = response["hits"] as? [[String: Any]], hits.count <= 5 else {
            throw RetailClientError.invalidResponse("Wegmans returned an unreadable product search.")
        }
        var identities: [String] = []
        for hit in hits {
            guard let identity = hit["productID"] as? String, numeric(identity), hit["objectID"] as? String == identity,
                  let stores = hit["soldAtStores"] as? [Int], stores.contains(133),
                  let fulfillment = hit["fulfillmentInStore"] as? [Int], fulfillment.contains(133) else {
                throw RetailClientError.invalidResponse("Wegmans returned a product for an unverified store or identity.")
            }
            if !identities.contains(identity) { identities.append(identity) }
        }
        return identities
    }

    /// Read only the configuration intentionally published to the public storefront.
    /// No keys are committed, persisted, printed, guessed, or requested from an account.
    private func publishedWegmansConfiguration() async throws -> (appID: String, key: String) {
        if let wegmansConfiguration { return wegmansConfiguration }
        let data = try await load(URLRequest(url: URL(string: "https://www.wegmans.com/")!))
        guard let html = String(data: data, encoding: .utf8),
              let appID = captures(#"https://([A-Z0-9]{6,20})-dsn\.algolia\.net"#, in: html).first?.first else {
            throw RetailClientError.invalidResponse("Wegmans search is temporarily unavailable. Its public website configuration changed.")
        }
        var paths = Array(Set(captures(#"<script[^>]+src="(/_next/static/chunks/[A-Za-z0-9_-]+\.js)""#, in: html).compactMap(\.first))).sorted()
        // A performance hint only. Discovery falls back to the current page's own assets.
        let hint = "/_next/static/chunks/0gfjp7fne0rb2.js"
        if let i = paths.firstIndex(of: hint) { paths.remove(at: i); paths.insert(hint, at: 0) }
        guard !paths.isEmpty, paths.count <= 64 else {
            throw RetailClientError.invalidResponse("Wegmans search is temporarily unavailable. Its public website configuration changed.")
        }
        let pattern = "\"" + NSRegularExpression.escapedPattern(for: appID) + #"",[A-Za-z_$][A-Za-z0-9_$]*="([a-f0-9]{32})""#
        let deadline = Date().addingTimeInterval(20)
        for path in paths {
            guard Date() < deadline else { break }
            try Task.checkCancellation()
            guard let asset = try? await load(URLRequest(url: URL(string: "https://www.wegmans.com" + path)!)),
                  let script = String(data: asset, encoding: .utf8),
                  let key = captures(pattern, in: script).first?.first else { continue }
            let configuration = (appID: appID, key: key)
            wegmansConfiguration = configuration
            return configuration
        }
        throw RetailClientError.invalidResponse("Wegmans search is temporarily unavailable. Its public website configuration changed.")
    }

    private func load(_ input: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        var request = input
        request.timeoutInterval = 10
        request.setValue("application/json, text/html, text/javascript", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { if Task.isCancelled { throw CancellationError() }; throw RetailClientError.invalidResponse("The store could not be reached. Try searching again later.") }
        guard let http = response as? HTTPURLResponse else { throw RetailClientError.invalidResponse("The store returned an unreadable response.") }
        guard (200...299).contains(http.statusCode) else { throw RetailClientError.unavailable(http.statusCode) }
        guard data.count <= 4_000_000 else { throw RetailClientError.invalidResponse("The store response exceeded the search size limit.") }
        return data
    }

    private func numeric(_ text: String) -> Bool {
        (1...20).contains(text.count) && text.utf8.allSatisfy { (48...57).contains($0) }
    }
    private func captures(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
        }
    }
}
