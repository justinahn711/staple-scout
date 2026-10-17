import Foundation
import CoreFoundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Lidl's public US catalog exposes regional in-store prices but no local stock count.
/// Shared retail clients route only the verified Chantilly in-store context here.
public actor LidlClient {
    private static let chantillyStoreCode = "US01112"
    private static let chantillyOfferRegion = "1112"
    private static let searchAccept = "application/mindshift.search+json;version=2"

    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
        self.now = { Date() }
    }

    init(session: URLSession, now: @escaping @Sendable () -> Date) {
        self.session = session
        self.now = now
    }

    public func search(query: String, location: StoreLocation, channel: Channel) async throws -> RetailSearchPage {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...100).contains(query.count),
              !query.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw RetailClientError.invalidProduct("Enter a product name between 2 and 100 characters.")
        }
        try validate(location: location, channel: channel)

        var components = URLComponents(string: "https://www.lidl.com/q/api/search")!
        components.queryItems = [
            URLQueryItem(name: "assortment", value: "US"),
            URLQueryItem(name: "locale", value: "en_US"),
            URLQueryItem(name: "version", value: "v2.0.0"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "newArticleFlag", value: "1")
        ]
        let (data, response, retrievedAt) = try await load(components.url!, accept: Self.searchAccept)
        let decoded: LidlSearchResponse
        do { decoded = try JSONDecoder().decode(LidlSearchResponse.self, from: data) }
        catch { throw RetailClientError.invalidResponse("Lidl returned unreadable product search data.") }
        guard decoded.type == "search", decoded.assortment == "US", decoded.locale == "en_US",
              decoded.items.totalCount <= 48 else {
            throw RetailClientError.invalidResponse("Lidl returned an unexpected product search context.")
        }

        var candidates: [FetchedPrice] = []
        var failures = decoded.items.rejectedCount
        for item in decoded.items.elements.prefix(12) {
            try Task.checkCancellation()
            do {
                let candidate = try makeFetchedPrice(
                    item: item,
                    retrievedAt: retrievedAt,
                    responseURL: response.url ?? components.url!
                )
                if !candidates.contains(where: { $0.productID == candidate.productID }) {
                    candidates.append(candidate)
                }
                if candidates.count == 5 { break }
            } catch is CancellationError { throw CancellationError() }
            catch { failures += 1 }
        }
        let message: String?
        if failures > 0 {
            message = "\(failures) Lidl catalog results lacked a verifiable current Chantilly price. Only verified regional prices are shown."
        } else {
            message = nil
        }
        return RetailSearchPage(candidates: candidates, message: message)
    }

    public func fetch(_ request: FetchRequest) async throws -> FetchedPrice {
        try validate(location: request.location, channel: request.channel)
        guard request.variant.store == .lidl,
              let productID = request.variant.productID,
              productID.range(of: #"^[0-9]{1,20}$"#, options: .regularExpression) != nil else {
            throw RetailClientError.invalidProduct("Select a Lidl product with a verified numeric product ID.")
        }
        var components = URLComponents(string: "https://www.lidl.com/q/api/search")!
        components.queryItems = [
            URLQueryItem(name: "assortment", value: "US"),
            URLQueryItem(name: "locale", value: "en_US"),
            URLQueryItem(name: "version", value: "v2.0.0"),
            URLQueryItem(name: "q", value: productID),
            URLQueryItem(name: "newArticleFlag", value: "1")
        ]
        let (redirectData, _, _) = try await load(components.url!, accept: Self.searchAccept)
        let redirect: LidlRedirectResponse
        do { redirect = try JSONDecoder().decode(LidlRedirectResponse.self, from: redirectData) }
        catch { throw RetailClientError.invalidResponse("Lidl did not return a verified product location.") }
        guard redirect.type == "redirect", redirect.assortment == "US", redirect.locale == "en_US",
              redirect.q == productID,
              redirect.redirectURL.range(of: #"^/p/[a-z0-9-]+/p"# + NSRegularExpression.escapedPattern(for: productID) + #"$"#, options: .regularExpression) != nil,
              let productURL = URL(string: "https://www.lidl.com" + redirect.redirectURL) else {
            throw RetailClientError.invalidResponse("Lidl returned a product location for a different identity.")
        }

        let (html, response, retrievedAt) = try await load(productURL, accept: "text/html")
        let item = try productItem(fromHTML: html, productID: productID)
        return try makeFetchedPrice(
            item: item,
            retrievedAt: retrievedAt,
            responseURL: response.url ?? productURL
        )
    }

    private func validate(location: StoreLocation, channel: Channel) throws {
        guard location.store == .lidl, location.code == Self.chantillyStoreCode else {
            throw RetailClientError.unsupportedSource("Lidl is connected only for Lidl US01112 at 14445 Chantilly Crossing Lane.")
        }
        guard channel == .inStore else {
            throw RetailClientError.unsupportedSource("Lidl's public US catalog provides regional in-store prices, not pickup or online purchase prices.")
        }
    }

    private func load(_ url: URL, accept: String) async throws -> (Data, HTTPURLResponse, Date) {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (compatible; StapleScout/1.0)", forHTTPHeaderField: "User-Agent")
        let data: Data
        let rawResponse: URLResponse
        do { (data, rawResponse) = try await session.data(for: request) }
        catch { if Task.isCancelled { throw CancellationError() }; throw RetailClientError.invalidResponse("Lidl could not be reached. Try again later.") }
        let retrievedAt = now()
        guard let response = rawResponse as? HTTPURLResponse else {
            throw RetailClientError.invalidResponse("Lidl returned an unreadable network response.")
        }
        guard (200...299).contains(response.statusCode) else { throw RetailClientError.unavailable(response.statusCode) }
        guard data.count <= 4_000_000 else { throw RetailClientError.invalidResponse("Lidl returned more product data than expected.") }
        return (data, response, retrievedAt)
    }
}

private extension LidlClient {
    func makeFetchedPrice(item: LidlSearchItem, retrievedAt: Date, responseURL: URL) throws -> FetchedPrice {
        guard item.type == "product", item.resultClass == "product", item.gridbox.country == "US" else {
            throw RetailClientError.invalidResponse("Lidl returned a non-product search result.")
        }
        return try makeFetchedPrice(product: item.gridbox.data, code: item.code, retrievedAt: retrievedAt, responseURL: responseURL)
    }

    func makeFetchedPrice(product: LidlProduct, code: String, retrievedAt: Date, responseURL: URL) throws -> FetchedPrice {
        let productID = String(product.productId)
        guard code == productID, product.erpNumber == productID, String(product.itemId) == productID,
              !product.fullTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              product.canonicalURL.hasPrefix("/p/"), product.canonicalURL.hasSuffix("/p" + productID),
              product.productType.hasPrefix("RETAIL") else {
            throw RetailClientError.invalidResponse("Lidl returned inconsistent product identity data.")
        }
        let regionName = "Region US" + Self.chantillyOfferRegion
        let regions = product.regionsV2.values.filter { $0.regionName == regionName && $0.status == "ONLINE" }
        guard regions.count == 1, let region = regions.first,
              let priceID = region.regionPriceId,
              let regional = product.regionsPrices[priceID],
              let current = regional.currentPrice else {
            throw RetailClientError.invalidResponse("Lidl does not list a unique current price for Chantilly offer region 1112.")
        }
        guard current.currencyCode == "USD", current.price > 0,
              current.variantsHaveDifferentPrices == false else {
            throw RetailClientError.invalidResponse("Lidl returned an unsupported or ambiguous regional price.")
        }
        guard let validFrom = lidlDate(current.startDate),
              let validUntil = lidlDate(current.endDateExclusive),
              validFrom < validUntil,
              retrievedAt >= validFrom,
              retrievedAt < validUntil else {
            throw RetailClientError.invalidResponse("Lidl's regional price is outside its stated validity window.")
        }
        let observedAt = Date(timeIntervalSince1970: TimeInterval(product.renderedTs))
        guard observedAt.timeIntervalSince1970 > 946_684_800,
              observedAt <= retrievedAt.addingTimeInterval(300) else {
            throw RetailClientError.invalidResponse("Lidl returned invalid product observation time data.")
        }
        let package = lidlPackage(current.packaging.text)
        var terms = [
            "Regional in-store catalog price for Lidl Chantilly offer region 1112.",
            "Source current-price window \(lidlTimestamp(validFrom)) through \(lidlTimestamp(validUntil)) (exclusive).",
            "Local shelf stock is not provided; the catalog's ONLINE region status is not treated as availability."
        ]
        if let oldPrice = current.oldPrice, oldPrice != current.price {
            terms.append("Source old price USD \(oldPrice); the regional current price is used and no Lidl Plus price is used.")
        }
        var exclusions = ["Lidl local stock is unknown."]
        if package == nil { exclusions.append("Source package size is unknown.") }
        let canonical = URL(string: "https://www.lidl.com" + product.canonicalURL)?.absoluteString ?? responseURL.absoluteString
        return FetchedPrice(
            productID: productID,
            productName: product.fullTitle,
            price: current.price,
            quantity: package?.quantity,
            unit: package?.unit,
            packCount: package?.packCount ?? 1,
            quantityKind: package == nil ? .variable : .fixed,
            available: nil,
            observedAt: observedAt,
            retrievedAt: retrievedAt,
            conditions: terms.joined(separator: " "),
            source: .lidl,
            sourceURL: canonical,
            sourceExclusion: exclusions.joined(separator: " "),
            validFrom: validFrom,
            validUntil: validUntil
        )
    }

    func lidlPackage(_ text: String) -> (quantity: Decimal, unit: MeasureUnit, packCount: Int)? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let multipack = #"^([0-9]{1,3})\s*(?:[-x×])\s*([0-9]+(?:\.[0-9]+)?)\s*(fl\.?\s*oz\.?|oz\.?|lbs?\.?|kg|g|ml|l)(?:\s+(?:bottles?|cans?|packs?|pieces?))?\.?\s*$"#
        if let match = normalized.lidlFirstMatch(multipack),
           let count = Int(match[1]), count > 0,
           let amount = Decimal(string: match[2], locale: Locale(identifier: "en_US_POSIX")), amount > 0,
           let unit = lidlUnit(match[3]) {
            return (amount, unit, count)
        }
        let single = #"^([0-9]+(?:\.[0-9]+)?)\s*(fl\.?\s*oz\.?|oz\.?|lbs?\.?|kg|g|ml|l|pieces?|count|ct\.?|each)\.?\s*$"#
        guard let match = normalized.lidlFirstMatch(single),
              let amount = Decimal(string: match[1], locale: Locale(identifier: "en_US_POSIX")), amount > 0,
              let unit = lidlUnit(match[2]) else { return nil }
        return (amount, unit, 1)
    }

    func lidlUnit(_ raw: String) -> MeasureUnit? {
        switch raw.lowercased().replacingOccurrences(of: ".", with: "").replacingOccurrences(of: " ", with: "") {
        case "oz": return .oz
        case "lb", "lbs": return .lb
        case "g": return .g
        case "kg": return .kg
        case "floz": return .flOz
        case "ml": return .ml
        case "l": return .l
        case "piece", "pieces", "count", "ct", "each": return .each
        default: return nil
        }
    }

    func lidlDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) { return date }
        let minutePrecision = #"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2})(Z|[+-]\d{2}:\d{2})$"#
        guard let match = text.lidlFirstMatch(minutePrecision) else { return nil }
        return ISO8601DateFormatter().date(from: match[1] + ":00" + match[2])
    }

    func lidlTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

private struct LidlSearchResponse: Decodable {
    var type: String
    var assortment: String
    var locale: String
    var items: LidlLossyArray<LidlSearchItem>
}

private struct LidlLossyArray<Element: Decodable>: Decodable {
    var elements: [Element] = []
    var rejectedCount = 0
    var totalCount: Int { elements.count + rejectedCount }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            let elementDecoder = try container.superDecoder()
            do { elements.append(try Element(from: elementDecoder)) }
            catch { rejectedCount += 1 }
        }
    }
}

private struct LidlRedirectResponse: Decodable {
    var type: String
    var q: String
    var locale: String
    var assortment: String
    var redirectURL: String
}

private struct LidlSearchItem: Decodable {
    var resultClass: String
    var type: String
    var code: String
    var gridbox: LidlGridbox
}

private struct LidlGridbox: Decodable {
    var country: String
    var data: LidlProduct
}

private struct LidlProduct: Decodable {
    var canonicalURL: String
    var erpNumber: String
    var fullTitle: String
    var itemId: Int64
    var productId: Int64
    var productType: String
    var regionsV2: LidlRegions
    var regionsPrices: [String: LidlRegionalPrice]
    var renderedTs: Int64

    enum CodingKeys: String, CodingKey {
        case canonicalURL = "canonicalUrl"
        case erpNumber, fullTitle, itemId, productId, productType, regionsV2, regionsPrices, renderedTs
    }
}

private struct LidlRegions: Decodable {
    var values: [LidlRegion]

    init(values: [LidlRegion]) { self.values = values }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let array = try? container.decode([LidlRegion].self) {
            values = array
            return
        }
        values = Array(try container.decode([String: LidlRegion].self).values)
    }
}

private struct LidlRegion: Decodable {
    var regionName: String
    var regionPriceId: String?
    var status: String
}

private struct LidlRegionalPrice: Decodable {
    var currentPrice: LidlPrice?
}

private struct LidlPrice: Decodable {
    struct Packaging: Decodable { var text: String }
    var currencyCode: String
    var endDateExclusive: String?
    var oldPrice: Decimal?
    var packaging: Packaging
    var price: Decimal
    var startDate: String?
    var variantsHaveDifferentPrices: Bool
}

private extension LidlClient {
    func productItem(fromHTML data: Data, productID: String) throws -> LidlSearchItem {
        guard let html = String(data: data, encoding: .utf8),
              let payload = html.lidlNuxtPayload(),
              let raw = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [Any] else {
            throw RetailClientError.invalidResponse("Lidl returned an unreadable product page.")
        }
        for case let object as [String: Any] in raw where object["productId"] != nil && object["regionsV2"] != nil && object["regionsPrices"] != nil {
            guard lidlDevalueString(object["productId"], raw) == productID else { continue }
            let product = try lidlProduct(object, raw)
            return LidlSearchItem(resultClass: "product", type: "product", code: productID, gridbox: LidlGridbox(country: "US", data: product))
        }
        throw RetailClientError.invalidResponse("Lidl's product page did not contain the requested regional product.")
    }

    func lidlProduct(_ object: [String: Any], _ raw: [Any]) throws -> LidlProduct {
        guard let productID = lidlDevalueInt64(object["productId"], raw),
              let itemID = lidlDevalueInt64(object["itemId"], raw),
              let erpNumber = lidlDevalueString(object["erpNumber"], raw),
              let canonicalURL = lidlDevalueString(object["canonicalUrl"] ?? object["canonicalPath"], raw),
              let productType = lidlDevalueString(object["productType"], raw),
              let renderedTs = lidlDevalueInt64(object["renderedTs"], raw),
              let regionsRaw = lidlDevalueCollection(object["regionsV2"], raw),
              let pricesRaw = lidlDevalueObject(object["regionsPrices"], raw) else {
            throw RetailClientError.invalidResponse("Lidl's product page omitted required product fields.")
        }
        let keyfacts = lidlDevalueObject(object["keyfacts"], raw)
        guard let fullTitle = lidlDevalueString(object["fullTitle"], raw) ?? keyfacts.flatMap({ lidlDevalueString($0["fullTitle"] ?? $0["title"], raw) }) else {
            throw RetailClientError.invalidResponse("Lidl's product page omitted the product name.")
        }
        let regions: [LidlRegion] = try regionsRaw.map { entry in
            guard let region = lidlDevalueObject(entry, raw),
                  let name = lidlDevalueString(region["regionName"], raw),
                  let status = lidlDevalueString(region["status"], raw) else {
                throw RetailClientError.invalidResponse("Lidl returned unreadable regional identity data.")
            }
            return LidlRegion(regionName: name, regionPriceId: lidlDevalueString(region["regionPriceId"], raw), status: status)
        }
        var prices: [String: LidlRegionalPrice] = [:]
        for (key, value) in pricesRaw {
            guard let group = lidlDevalueObject(value, raw) else { continue }
            let current: LidlPrice?
            if let priceObject = lidlDevalueObject(group["currentPrice"], raw) {
                current = try lidlPrice(priceObject, raw)
            } else { current = nil }
            prices[key] = LidlRegionalPrice(currentPrice: current)
        }
        return LidlProduct(canonicalURL: canonicalURL, erpNumber: erpNumber, fullTitle: fullTitle, itemId: itemID, productId: productID, productType: productType, regionsV2: LidlRegions(values: regions), regionsPrices: prices, renderedTs: renderedTs)
    }

    func lidlPrice(_ object: [String: Any], _ raw: [Any]) throws -> LidlPrice {
        guard let currency = lidlDevalueString(object["currencyCode"], raw),
              let price = lidlDevalueDecimal(object["price"], raw),
              let packagingObject = lidlDevalueObject(object["packaging"], raw),
              let packaging = lidlDevalueString(packagingObject["text"], raw),
              let variants = lidlDevalueBool(object["variantsHaveDifferentPrices"], raw) else {
            throw RetailClientError.invalidResponse("Lidl returned unreadable regional price data.")
        }
        return LidlPrice(currencyCode: currency, endDateExclusive: lidlDevalueString(object["endDateExclusive"], raw), oldPrice: lidlDevalueDecimal(object["oldPrice"], raw), packaging: .init(text: packaging), price: price, startDate: lidlDevalueString(object["startDate"], raw), variantsHaveDifferentPrices: variants)
    }

    func lidlDevalueEntry(_ reference: Any?, _ raw: [Any]) -> Any? {
        guard let number = reference as? NSNumber else { return nil }
        let index = number.intValue
        guard index >= 0, index < raw.count else { return nil }
        return raw[index]
    }

    func lidlDevalueString(_ reference: Any?, _ raw: [Any]) -> String? {
        if let value = lidlDevalueEntry(reference, raw) as? String { return value }
        if let value = lidlDevalueEntry(reference, raw) as? NSNumber { return value.stringValue }
        return nil
    }

    func lidlDevalueInt64(_ reference: Any?, _ raw: [Any]) -> Int64? {
        (lidlDevalueEntry(reference, raw) as? NSNumber)?.int64Value
    }

    func lidlDevalueDecimal(_ reference: Any?, _ raw: [Any]) -> Decimal? {
        guard let number = lidlDevalueEntry(reference, raw) as? NSNumber else { return nil }
        return Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX"))
    }

    func lidlDevalueBool(_ reference: Any?, _ raw: [Any]) -> Bool? {
        guard let value = lidlDevalueEntry(reference, raw) as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    func lidlDevalueArray(_ reference: Any?, _ raw: [Any]) -> [Any]? {
        lidlDevalueEntry(reference, raw) as? [Any]
    }

    func lidlDevalueCollection(_ reference: Any?, _ raw: [Any]) -> [Any]? {
        if let array = lidlDevalueArray(reference, raw) { return array }
        if let object = lidlDevalueObject(reference, raw) { return Array(object.values) }
        return nil
    }

    func lidlDevalueObject(_ reference: Any?, _ raw: [Any]) -> [String: Any]? {
        lidlDevalueEntry(reference, raw) as? [String: Any]
    }
}

private extension String {
    func lidlFirstMatch(_ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return nil }
        return (0..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: self).map { String(self[$0]) } }
    }

    func lidlNuxtPayload() -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"<script[^>]*id=\"__NUXT_DATA__\"[^>]*>(.*?)</script>"#, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              let range = Range(match.range(at: 1), in: self) else { return nil }
        return String(self[range])
    }
}
