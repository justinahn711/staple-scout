import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SharedMarketCore
import StapleScoutKit
import Vapor

public protocol MarketUpstream: Sendable {
    func price(context: PriceContext, productID: String) async throws -> FetchedPrice
    func search(context: PriceContext, query: String) async throws -> RetailSearchPage
}

/// Personal research only. Working website access does not grant public redistribution rights.
public struct LocalResearchUpstream: MarketUpstream {
    private let prices: RetailClient
    private let products: RetailSearchClient
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        prices = RetailClient(session: session); products = RetailSearchClient(session: session)
    }
    public func price(context: PriceContext, productID: String) async throws -> FetchedPrice {
        let variant = ProductVariant(store: context.store, productID: productID, name: productID,
                                     quantity: 1, unit: .each, quantityKind: .variable)
        return try await prices.fetch(FetchRequest(variant: variant, location: context.location, channel: context.channel))
    }
    public func search(context: PriceContext, query: String) async throws -> RetailSearchPage {
        try await products.search(query: query, location: context.location, channel: context.channel)
    }
}

public struct MarketService: Sendable {
    private let cache: SharedPriceCache
    private let token: [UInt8]
    private let upstream: (any MarketUpstream)?
    private let now: @Sendable () -> Date

    public init(cache: SharedPriceCache, accessToken: String, upstream: (any MarketUpstream)? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) throws {
        guard (32...256).contains(accessToken.utf8.count), accessToken.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw CacheError.invalidRequest("Use a random access token of 32 to 256 printable ASCII characters.")
        }
        self.cache = cache; token = Array(("Bearer " + accessToken).utf8); self.upstream = upstream; self.now = now
    }

    public func configure(_ app: Application) {
        // No request-body or credential logging. No CORS middleware is installed.
        app.middleware = .init()
        app.routes.defaultMaxBodySize = "4kb"
        app.get("health") { request async throws -> Response in
            try guardLocalRequest(request)
            return try json(Health(status: "ok", schemaVersion: 1, localOnly: true,
                                   sourceMode: upstream == nil ? "disabled" : "local-research"))
        }
        app.get("v1", "sources") { request async throws -> Response in
            await respond(request) {
                try authenticate(request)
                guard request.url.query == nil else { throw CacheError.invalidRequest("The sources endpoint does not accept query parameters.") }
                return try json(StoreLocation.defaults.map { location in
                    SourceStatus(store: location.store, storeCode: location.code,
                                 channel: location.store == .hmart ? .online : .inStore,
                                 fetchingEnabled: upstream != nil && SourceCapability.forLocation(location, channel: location.store == .hmart ? .online : .inStore).isConnected,
                                 publicAccessApproved: false,
                                 message: SourceCapability.forLocation(location, channel: location.store == .hmart ? .online : .inStore).message)
                })
            }
        }
        app.get("v1", "price") { request async throws -> Response in
            await respond(request) {
                try authenticate(request)
                let (context, parameter) = try parse(request, parameter: "productID")
                guard let upstream else { return try unavailable() }
                let result = try await cache.price(context: context, productID: parameter) {
                    try await upstream.price(context: context, productID: parameter)
                }
                return try json(SharedPriceResponse(context: SharedPriceContext(location: context.location, channel: context.channel),
                                                    value: result.value, cacheHit: result.cacheHit, servedAt: now()))
            }
        }
        app.get("v1", "search") { request async throws -> Response in
            await respond(request) {
                try authenticate(request)
                let (context, parameter) = try parse(request, parameter: "q")
                guard let upstream else { return try unavailable() }
                let result = try await cache.search(context: context, query: parameter) {
                    try await upstream.search(context: context, query: parameter)
                }
                return try json(SharedSearchResponse(context: SharedPriceContext(location: context.location, channel: context.channel),
                                                     page: result.page, cacheHit: result.cacheHit, servedAt: now()))
            }
        }
    }

    private func guardLocalRequest(_ request: Request) throws {
        let hosts = request.headers["Host"]
        let host = hosts.first?.lowercased() ?? ""
        let allowed = host == "localhost" || host == "127.0.0.1" || host == "[::1]"
            || host.range(of: #"^(localhost|127\.0\.0\.1|\[::1\]):[0-9]{1,5}$"#, options: .regularExpression) != nil
        guard hosts.count == 1, allowed, request.headers["Origin"].isEmpty,
              request.url.string.utf8.count <= 2048, request.body.data?.readableBytes ?? 0 == 0 else {
            throw CacheError.invalidRequest("Only local requests without an Origin or request body are supported.")
        }
    }

    private func authenticate(_ request: Request) throws {
        try guardLocalRequest(request)
        let headers = request.headers["Authorization"]
        guard headers.count == 1 else { throw AccessError.unauthorized }
        let candidate = Array(headers[0].utf8)
        guard candidate.count == token.count else { throw AccessError.unauthorized }
        var difference: UInt8 = 0
        for index in token.indices { difference |= candidate[index] ^ token[index] }
        guard difference == 0 else { throw AccessError.unauthorized }
    }

    private func parse(_ request: Request, parameter: String) throws -> (PriceContext, String) {
        guard let parts = URLComponents(string: request.url.string), let items = parts.queryItems,
              (3...4).contains(items.count), Set(items.map(\.name)).count == items.count,
              items.allSatisfy({ ["store", "storeCode", "channel", parameter].contains($0.name) && $0.value != nil }) else {
            throw CacheError.invalidRequest("Use one store, optional storeCode, channel, and product query.")
        }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
        guard let storeName = values["store"], let store = StoreID(rawValue: storeName),
              let channelName = values["channel"], let channel = StapleScoutKit.Channel(rawValue: channelName),
              let value = values[parameter] else { throw CacheError.invalidRequest("The store, channel, or query is missing or invalid.") }
        let context = try PriceContext(store: store, storeCode: values["storeCode"], channel: channel)
        if parameter == "q" {
            guard (2...100).contains(value.trimmingCharacters(in: .whitespacesAndNewlines).count),
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw CacheError.invalidRequest("Enter a query between 2 and 100 characters without controls.")
            }
        } else {
            let pattern = store == .hmart ? #"^[0-9]{1,20}:[0-9]{1,20}$"# : #"^[0-9]{1,20}$"#
            guard value.range(of: pattern, options: .regularExpression) != nil else { throw CacheError.invalidRequest("The product identity is invalid.") }
        }
        return (context, value)
    }

    private func unavailable() throws -> Response {
        try json(SharedAPIError(code: "source_access_not_configured", message: "Live sources are disabled. Public price access has not been configured."), status: .serviceUnavailable)
    }
    private func respond(_ request: Request, action: () async throws -> Response) async -> Response {
        do { return try await action() }
        catch {
            let status: HTTPResponseStatus
            let code: String
            let message: String
            switch error {
            case AccessError.unauthorized: status = .unauthorized; code = "unauthorized"; message = "A valid service access token is required."
            case CacheError.invalidRequest: status = .badRequest; code = "invalid_request"; message = "The store context or product query is invalid."
            case CacheError.budgetExceeded: status = .tooManyRequests; code = "budget_exceeded"; message = "The shared upstream attempt limit was reached."
            case CacheError.alreadyAttempted: status = .tooManyRequests; code = "attempted_today"; message = "This request was already attempted today; no usable cached evidence is available."
            case CacheError.storage: status = .serviceUnavailable; code = "storage_unavailable"; message = "Shared evidence storage is unavailable."
            default: status = .badGateway; code = "source_unavailable"; message = "The source did not return usable price evidence."
            }
            return (try? json(SharedAPIError(code: code, message: message), status: status)) ?? Response(status: .internalServerError)
        }
    }
    private func json<T: Encodable>(_ value: T, status: HTTPResponseStatus = .ok) throws -> Response {
        Response(status: status, headers: ["Content-Type": "application/json", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"],
                 body: .init(data: try SharedMarketWire.encoder().encode(value)))
    }
    private enum AccessError: Error { case unauthorized }
    private struct Health: Encodable { let status: String; let schemaVersion: Int; let localOnly: Bool; let sourceMode: String }
    private struct SourceStatus: Encodable {
        let store: StoreID; let storeCode: String?; let channel: StapleScoutKit.Channel
        let fetchingEnabled: Bool; let publicAccessApproved: Bool; let message: String
    }
}
