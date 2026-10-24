import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol RetailPriceFetching: Sendable {
    func fetch(_ request: FetchRequest) async throws -> FetchedPrice
}
public protocol RetailProductSearching: Sendable {
    func search(query: String, location: StoreLocation, channel: Channel) async throws -> RetailSearchPage
}
extension RetailClient: RetailPriceFetching {}
extension RetailSearchClient: RetailProductSearching {}

/// Wire context deliberately excludes a user's local UUID, staple list and match decisions.
public struct SharedPriceContext: Codable, Equatable, Sendable {
    public let store: StoreID
    public let storeCode: String?
    public let channel: Channel
    public init(store: StoreID, storeCode: String?, channel: Channel) {
        self.store = store; self.storeCode = storeCode; self.channel = channel
    }
    public init(location: StoreLocation, channel: Channel) {
        self.init(store: location.store, storeCode: location.code, channel: channel)
    }
}

/// Version 1 uses decimal strings and Unix-millisecond dates, independent of SwiftData encoding.
public struct SharedPriceRecord: Codable, Sendable {
    public let productID: String
    public let productName: String
    public let barcode: String?
    public let currency: String
    public let price: String?
    public let quantity: String?
    public let unit: MeasureUnit?
    public let packCount: Int
    public let quantityKind: QuantityKind
    public let available: Bool?
    public let observedAt: Date
    public let retrievedAt: Date
    public let conditions: String
    public let source: SourceID
    public let sourceURL: String
    public let sourceExclusion: String?
    public let validFrom: Date?
    public let validUntil: Date?
    public let provenance: SharedRetailProvenance?

    public init(_ value: FetchedPrice, provenance: SharedRetailProvenance? = nil) {
        self.provenance = provenance
        productID = value.productID; productName = value.productName; barcode = value.barcode
        currency = "USD"; price = value.price.map { NSDecimalNumber(decimal: $0).stringValue }
        quantity = value.quantity.map { NSDecimalNumber(decimal: $0).stringValue }
        unit = value.unit; packCount = value.packCount; quantityKind = value.quantityKind
        available = value.available; observedAt = value.observedAt; retrievedAt = value.retrievedAt
        conditions = value.conditions; source = value.source; sourceURL = value.sourceURL
        sourceExclusion = value.sourceExclusion; validFrom = value.validFrom; validUntil = value.validUntil
    }

    public func evidence() throws -> FetchedPrice {
        func decimal(_ text: String?) throws -> Decimal? {
            guard let text else { return nil }
            guard text.count <= 40, text.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
                  let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
                  !value.isNaN, value <= 1_000_000 else {
                throw RetailClientError.invalidResponse("The shared service returned an invalid decimal amount.")
            }
            return value
        }
        let amount = try decimal(price)
        let size = try decimal(quantity)
        guard currency == "USD", (1...200).contains(productID.count), (1...1000).contains(productName.count),
              (1...10_000).contains(packCount), size.map({ $0 > 0 }) ?? true, (size == nil) == (unit == nil),
              conditions.count <= 8000, (sourceExclusion?.count ?? 0) <= 8000,
              let url = URL(string: sourceURL), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil else {
            throw RetailClientError.invalidResponse("The shared service returned unsupported product evidence.")
        }
        return FetchedPrice(productID: productID, productName: productName, barcode: barcode, price: amount,
                            quantity: size, unit: unit, packCount: packCount, quantityKind: quantityKind,
                            available: available, observedAt: observedAt, retrievedAt: retrievedAt,
                            conditions: conditions, source: source, sourceURL: sourceURL, sourceExclusion: sourceExclusion,
                            validFrom: validFrom, validUntil: validUntil)
    }
}

public struct SharedSearchResponse: Codable, Sendable {
    public let schemaVersion: Int
    public let context: SharedPriceContext
    public let products: [SharedPriceRecord]
    public let message: String?
    public let cacheHit: Bool
    public let servedAt: Date
    public init(context: SharedPriceContext, page: RetailSearchPage, cacheHit: Bool, servedAt: Date) {
        schemaVersion = 1; self.context = context; products = page.candidates.map { SharedPriceRecord($0) }
        message = page.message; self.cacheHit = cacheHit; self.servedAt = servedAt
    }
}
public struct SharedPriceResponse: Codable, Sendable {
    public let schemaVersion: Int
    public let context: SharedPriceContext
    public let product: SharedPriceRecord
    public let cacheHit: Bool
    public let servedAt: Date
    public init(context: SharedPriceContext, value: FetchedPrice, cacheHit: Bool, servedAt: Date) {
        schemaVersion = 1; self.context = context; product = SharedPriceRecord(value)
        self.cacheHit = cacheHit; self.servedAt = servedAt
    }
}
public struct SharedAPIError: Codable, Sendable {
    public let code: String
    public let message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
}
public enum SharedMarketWire {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; return encoder
    }
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970; return decoder
    }
}

/// Typed safe codes; arbitrary server messages never reach the interface.
public struct SharedServiceError: Error, LocalizedError, Sendable {
    public let status: Int
    public let code: String?
    init(status: Int, code: String?) {
        self.status = status
        // Never retain arbitrary server prose in an error's debug representation.
        let safeCodes: Set<String> = ["auth_invalid", "auth_expired", "auth_revoked", "refresh_replayed", "attempted_today", "budget_exceeded", "provider_budget_exhausted", "client_provider_limit", "work_pending", "operation_limit", "source_access_not_configured", "service_stopping", "provider_disabled", "provider_storage_unavailable"]
        self.code = code.flatMap { safeCodes.contains($0) ? $0 : nil }
    }
    public var errorDescription: String? {
        switch status {
        case 401: return "The pilot session was rejected. Reconnect in My stores."
        case 429:
            if code == "attempted_today" { return "This request was already attempted today. No usable cached evidence is available; try again on the next UTC day." }
            if code == "work_pending" { return "A bounded request is pending. Saved evidence keeps its date; try again later with an explicit action." }
            return "The shared service request limit was reached. Try again later; checking source status does not reset a quota."
        case 503: return "This price source is unavailable or pending. Saved evidence keeps its original date."
        default: return "The shared service could not complete the request. Try again later."
        }
    }
}

/// Opt-in transport for a configured service. It never silently falls back to direct retailer requests.
public final class SharedMarketClient: RetailPriceFetching, RetailProductSearching, @unchecked Sendable {
    private let baseURL: URL
    private let token: String
    private let session: URLSession
    private let typedServiceErrors: Bool
    private let sourceSnapshot: RemoteSourceSnapshot?

    public init(baseURL: URL, accessToken: String, configuration: URLSessionConfiguration = .ephemeral, typedServiceErrors: Bool = false, sourceSnapshot: RemoteSourceSnapshot? = nil) throws {
        let localHosts = ["localhost", "127.0.0.1", "[::1]", "::1"]
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty,
              components.scheme == "https" || (components.scheme == "http" && localHosts.contains(host.lowercased())),
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              (32...256).contains(accessToken.utf8.count), accessToken.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw RetailClientError.invalidProduct("Configure an HTTPS shared service and a valid access token. HTTP is allowed only on loopback for development.")
        }
        self.baseURL = baseURL; token = accessToken; self.typedServiceErrors = typedServiceErrors; self.sourceSnapshot = sourceSnapshot
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: SharedMarketRedirectGuard(), delegateQueue: nil)
    }

    public func search(query: String, location: StoreLocation, channel: Channel) async throws -> RetailSearchPage {
        try validateContext(location, channel: channel)
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...100).contains(query.count), !query.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw RetailClientError.invalidProduct("Enter a product name between 2 and 100 characters.")
        }
        let context = SharedPriceContext(location: location, channel: channel)
        let response: SharedSearchResponse = try await load(path: "v1/search", context: context, parameter: URLQueryItem(name: "q", value: query))
        guard response.schemaVersion == 1, response.context == context, response.products.count <= 5 else {
            throw RetailClientError.invalidResponse("The shared service returned a different store or unsupported search response.")
        }
        let values = try response.products.map { try validate($0, context: context, servedAt: response.servedAt) }
        guard Set(values.map(\.productID)).count == values.count else { throw RetailClientError.invalidResponse("The shared service returned duplicate products.") }
        return RetailSearchPage(candidates: values, message: response.message)
    }

    public func fetch(_ request: FetchRequest) async throws -> FetchedPrice {
        try validateContext(request.location, channel: request.channel)
        let pattern = request.location.store == .hmart ? #"^[0-9]{1,20}:[0-9]{1,20}$"# : #"^[0-9]{1,20}$"#
        guard request.variant.store == request.location.store, let identity = request.variant.productID,
              identity.range(of: pattern, options: .regularExpression) != nil else {
            throw RetailClientError.invalidProduct("Select a verified retailer product before refreshing.")
        }
        let context = SharedPriceContext(location: request.location, channel: request.channel)
        let response: SharedPriceResponse = try await load(path: "v1/price", context: context, parameter: URLQueryItem(name: "productID", value: identity))
        guard response.schemaVersion == 1, response.context == context, response.product.productID == identity else {
            throw RetailClientError.invalidResponse("The shared service returned a different product or store.")
        }
        return try validate(response.product, context: context, servedAt: response.servedAt)
    }

    private func validateContext(_ location: StoreLocation, channel: Channel) throws {
        if let sourceSnapshot { _ = try sourceSnapshot.require(SharedPriceContext(location: location, channel: channel)); return }
        let capability = SourceCapability.forLocation(location, channel: channel)
        guard capability.isConnected else { throw RetailClientError.unsupportedSource(capability.message) }
    }

    private func validate(_ record: SharedPriceRecord, context: SharedPriceContext, servedAt: Date) throws -> FetchedPrice {
        let remote = try sourceSnapshot?.require(context)
        let value = try record.evidence()
        let current = Date()
        let identityPattern = context.store == .hmart ? #"^[0-9]{1,20}:[0-9]{1,20}$"# : #"^[0-9]{1,20}$"#
        let expected: SourceID
        switch context.store {
        case .wegmans: expected = .wegmans
        case .hmart: expected = .hmart
        case .lidl: expected = .lidl
        case .walmart: expected = .walmart
        case .target: expected = .target
        }
        guard value.source == expected, value.productID.range(of: identityPattern, options: .regularExpression) != nil,
              value.observedAt.timeIntervalSince1970 > 0, value.observedAt <= value.retrievedAt,
              value.retrievedAt <= servedAt, value.retrievedAt <= current,
              current.timeIntervalSince(value.observedAt) < 48 * 60 * 60,
              servedAt <= current.addingTimeInterval(5), value.validFrom.map({ $0 <= servedAt && $0 <= current }) ?? true,
              value.validUntil.map({ servedAt < $0 && current < $0 }) ?? true else {
            throw RetailClientError.invalidResponse("The shared service returned inconsistent source or offer times.")
        }
        guard let url = URLComponents(string: value.sourceURL), url.port == nil, url.fragment == nil else {
            throw RetailClientError.invalidResponse("The shared service returned an invalid retailer URL.")
        }
        let matchesSource: Bool
        switch context.store {
        case .wegmans:
            matchesSource = url.host == "www.wegmans.com" && context.storeCode == "133"
                && url.path == "/api/products/133/\(value.productID)" && url.query == nil
        case .hmart:
            matchesSource = url.host == "www.hmart.com" && url.path == "/api/catalog_system/pub/products/search/"
                && url.queryItems?.count == 1
                && url.queryItems?.filter({ $0.name == "fq" }).map(\.value) == ["productId:\(value.productID.split(separator: ":")[0])"]
                && !(value.sourceExclusion?.isEmpty ?? true)
        case .lidl:
            matchesSource = url.host == "www.lidl.com" && url.path.hasPrefix("/p/")
                && url.path.hasSuffix("/p\(value.productID)") && url.query == nil
                && value.available == nil && value.validFrom != nil && value.validUntil != nil
                && !(value.sourceExclusion?.isEmpty ?? true)
        case .walmart, .target:
            let p = record.provenance
            let walmart = context.store == .walmart
            // Deliberately narrow canonical product paths: no dot/empty segments,
            // repeated/trailing slashes, encoded path substitutions or arbitrary slug syntax.
            let productPath = walmart
                ? "^/ip/[A-Za-z0-9][A-Za-z0-9_-]{0,299}/" + value.productID + "$"
                : "^/p/(?:[A-Za-z0-9][A-Za-z0-9_-]{0,299}/)?-/A-" + value.productID + "$"
            let exactURL = url.host == (walmart ? "www.walmart.com" : "www.target.com")
                && url.path.range(of: productPath, options: .regularExpression) != nil
            matchesSource = remote != nil && remote?.provider == "serpapi" && p?.schemaVersion == 1
                && p?.provider == remote?.provider && p?.store == context.store && p?.storeCode == context.storeCode
                && p?.channel == context.channel && p?.seller == (walmart ? "Walmart" : "Target") && p?.priceType == "regular"
                && (walmart ? context.channel == .pickup && context.storeCode == "5969"
                    : [.inStore, .pickup].contains(context.channel) && context.storeCode == "1827")
                && exactURL && url.query == nil && url.percentEncodedPath == url.path
        }
        if let remote {
            guard current.timeIntervalSince(value.observedAt) < remote.maximumObservationAgeSeconds,
                  current.timeIntervalSince(value.retrievedAt) < min(remote.cacheTTLSeconds, remote.displayTTLSeconds, remote.retentionSeconds),
                  !remote.referenceOnly || !(value.sourceExclusion?.isEmpty ?? true) else {
                throw RetailClientError.invalidResponse("The source evidence exceeds its approved limits or lost its comparison exclusion.")
            }
        }
        guard matchesSource else { throw RetailClientError.invalidResponse("The shared service returned a different retailer source or incomplete evidence.") }
        return value
    }

    public func sources() async throws -> RemoteSourceSnapshot {
        let data = try await request(path: "v1/sources", query: nil)
        return try RemoteSourceSnapshot.decode(data)
    }

    private func load<T: Decodable>(path: String, context: SharedPriceContext, parameter: URLQueryItem) async throws -> T {
        var query = [URLQueryItem(name: "store", value: context.store.rawValue), URLQueryItem(name: "channel", value: context.channel.rawValue), parameter]
        if let code = context.storeCode { query.append(URLQueryItem(name: "storeCode", value: code)) }
        let data = try await request(path: path, query: query)
        if let sourceSnapshot { _ = try sourceSnapshot.require(context) }
        do {
            if sourceSnapshot != nil { try SharedJSONStructure.validateProvenance(data) }
            return try SharedMarketWire.decoder().decode(T.self, from: data)
        }
        catch { throw RetailClientError.invalidResponse("The shared service returned an unsupported response.") }
    }
    private func request(path: String, query: [URLQueryItem]?) async throws -> Data {
        try Task.checkCancellation()
        var url = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        url.queryItems = query
        var request = URLRequest(url: url.url!); request.timeoutInterval = 20
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, rawResponse) = try await session.data(for: request)
        guard let response = rawResponse as? HTTPURLResponse, response.url == request.url else { throw RetailClientError.invalidResponse("The shared service returned an unreadable or redirected response.") }
        guard response.statusCode == 200 else {
            if typedServiceErrors {
                let code = data.count <= 4096 ? (try? JSONDecoder().decode(SharedAPIError.self, from: data))?.code : nil
                throw SharedServiceError(status: response.statusCode, code: code)
            }
            if response.statusCode == 401 { throw RetailClientError.unsupportedSource("Shared service access was rejected. Check its access configuration.") }
            if response.statusCode == 429 { throw RetailClientError.unsupportedSource("The shared service request limit was reached. Try again later.") }
            throw RetailClientError.unavailable(response.statusCode)
        }
        guard data.count <= 1_000_000 else { throw RetailClientError.invalidResponse("The shared service response exceeded the size limit.") }
        return data
    }
}

private final class SharedMarketRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
