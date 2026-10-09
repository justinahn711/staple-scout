import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct FetchRequest: Codable, Sendable {
    public var variant: ProductVariant
    public var location: StoreLocation
    public var channel: Channel

    public init(variant: ProductVariant, location: StoreLocation, channel: Channel) {
        self.variant = variant
        self.location = location
        self.channel = channel
    }
}

public struct FetchedPrice: Codable, Sendable {
    public var productID: String
    public var productName: String
    public var barcode: String?
    public var price: Decimal?
    public var quantity: Decimal?
    public var unit: MeasureUnit?
    public var packCount: Int
    public var quantityKind: QuantityKind
    public var available: Bool?
    public var observedAt: Date
    public var retrievedAt: Date
    public var conditions: String
    public var source: SourceID
    public var sourceURL: String
    public var sourceExclusion: String?

    public init(
        productID: String,
        productName: String,
        barcode: String? = nil,
        price: Decimal? = nil,
        quantity: Decimal? = nil,
        unit: MeasureUnit? = nil,
        packCount: Int = 1,
        quantityKind: QuantityKind = .fixed,
        available: Bool? = nil,
        observedAt: Date,
        retrievedAt: Date,
        conditions: String = "",
        source: SourceID,
        sourceURL: String,
        sourceExclusion: String? = nil
    ) {
        self.productID = productID
        self.productName = productName
        self.barcode = barcode
        self.price = price
        self.quantity = quantity
        self.unit = unit
        self.packCount = packCount
        self.quantityKind = quantityKind
        self.available = available
        self.observedAt = observedAt
        self.retrievedAt = retrievedAt
        self.conditions = conditions
        self.source = source
        self.sourceURL = sourceURL
        self.sourceExclusion = sourceExclusion
    }
}

public struct SourceCapability: Equatable, Codable, Sendable {
    public var isConnected: Bool
    public var message: String

    public init(isConnected: Bool, message: String) {
        self.isConnected = isConnected
        self.message = message
    }

    public static func forLocation(_ location: StoreLocation, channel: Channel) -> SourceCapability {
        switch location.store {
        case .wegmans:
            guard location.code == "133", channel == .inStore else {
                return SourceCapability(isConnected: false, message: "Wegmans is connected only for Chantilly store 133 in-store prices.")
            }
            return SourceCapability(isConnected: true, message: "Connected to Wegmans Chantilly store 133 in-store prices.")
        case .hmart:
            guard location.code == nil, channel == .online else {
                return SourceCapability(isConnected: false, message: "H Mart is connected only as an online catalog reference; local shelf and pickup prices are not available.")
            }
            return SourceCapability(isConnected: true, message: "Connected to the H Mart online catalog reference. Local stock and shipping are unverified.")
        case .target, .walmart:
            return SourceCapability(isConnected: false, message: "This store source is blocked until a public, validated price context is available.")
        case .lidl:
            return SourceCapability(isConnected: false, message: "Lidl price retrieval is not connected.")
        }
    }
}

public enum RetailClientError: LocalizedError, Sendable {
    case unsupportedSource(String)
    case invalidProduct(String)
    case unavailable(Int)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSource(let message), .invalidProduct(let message), .invalidResponse(let message):
            return message
        case .unavailable(let status):
            return "The retailer source is temporarily unavailable (HTTP \(status))."
        }
    }
}

public final class RetailClient: @unchecked Sendable {
    private let session: URLSession
    private let now: @Sendable () -> Date

    public convenience init(session: URLSession = .shared) {
        self.init(session: session, now: { Date() })
    }

    init(session: URLSession, now: @escaping @Sendable () -> Date) {
        self.session = session
        self.now = now
    }

    public func fetch(_ request: FetchRequest) async throws -> FetchedPrice {
        guard request.variant.store == request.location.store else {
            throw RetailClientError.invalidProduct("The selected product does not belong to this store.")
        }
        let capability = SourceCapability.forLocation(request.location, channel: request.channel)
        guard capability.isConnected else {
            throw RetailClientError.unsupportedSource(capability.message)
        }
        guard let identity = request.variant.productID, !identity.isEmpty else {
            throw RetailClientError.invalidProduct("Select a product with a verified retailer ID before refreshing its price.")
        }

        switch request.location.store {
        case .wegmans:
            return try await fetchWegmans(productID: identity)
        case .hmart:
            return try await fetchHMart(identity: identity)
        case .target, .walmart, .lidl:
            throw RetailClientError.unsupportedSource(capability.message)
        }
    }

    private func fetchWegmans(productID: String) async throws -> FetchedPrice {
        guard productID.range(of: #"^[0-9]{1,20}$"#, options: .regularExpression) != nil,
              let url = URL(string: "https://www.wegmans.com/api/products/133/\(productID)") else {
            throw RetailClientError.invalidProduct("The Wegmans product ID is invalid.")
        }
        let (object, response, retrievedAt) = try await loadJSON(url: url)
        guard let product = object as? [String: Any] else {
            throw RetailClientError.invalidResponse("Wegmans returned an unreadable product response.")
        }
        guard try requiredString(product, "objectId") == "133-\(productID)",
              try requiredString(product, "storeNumber") == "133",
              try requiredString(product, "skuId") == productID,
              try requiredString(product, "productID") == productID,
              try requiredString(product, "productId") == productID else {
            throw RetailClientError.invalidResponse("Wegmans returned a product or store that does not match the request.")
        }
        let name = try requiredString(product, "productName")
        let priceObject: [String: Any]
        if let rawPrice = product["price_inStore"], !(rawPrice is NSNull) {
            guard let candidate = rawPrice as? [String: Any] else {
                throw RetailClientError.invalidResponse("Wegmans returned an unreadable in-store price.")
            }
            if candidate.isEmpty {
                priceObject = [:]
            } else {
                guard try requiredString(candidate, "channelKey") == "133-Instore" else {
                    throw RetailClientError.invalidResponse("Wegmans returned a price for a different sales channel.")
                }
                priceObject = candidate
            }
        } else {
            priceObject = [:]
        }
        let price = try optionalNonnegativeDecimal(priceObject, "amount", label: "Wegmans price")
        let soldAtStore = try optionalBool(product, "isSoldAtStore", label: "Wegmans availability")
        let isAvailable = try optionalBool(product, "isAvailable", label: "Wegmans availability")
        let available: Bool? = (soldAtStore == false || isAvailable == false) ? false :
            (soldAtStore == true && isAvailable == true ? true : nil)
        let barcode = try firstString(product, "upc", label: "Wegmans UPC")
        let package = try wegmansQuantity(product: product, price: priceObject)
        let conditions = try wegmansConditions(product: product, price: priceObject)

        return FetchedPrice(
            productID: productID,
            productName: name,
            barcode: barcode,
            price: price,
            quantity: package.quantity,
            unit: package.unit,
            packCount: 1,
            quantityKind: package.kind,
            available: available,
            observedAt: try observedAt(response: response, retrievedAt: retrievedAt, source: "Wegmans"),
            retrievedAt: retrievedAt,
            conditions: conditions,
            source: .wegmans,
            sourceURL: response.url?.absoluteString ?? url.absoluteString,
            sourceExclusion: package.quantity == nil ? "Source package size is unknown." : nil
        )
    }

    private func fetchHMart(identity: String) async throws -> FetchedPrice {
        let pieces = identity.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              pieces.allSatisfy({ $0.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 } }) else {
            throw RetailClientError.invalidProduct("Select an H Mart product using its productId:itemId identity.")
        }
        let productID = String(pieces[0])
        let itemID = String(pieces[1])
        var components = URLComponents(string: "https://www.hmart.com/api/catalog_system/pub/products/search/")!
        components.queryItems = [
            URLQueryItem(name: "fq", value: "productId:\(productID)"),
            URLQueryItem(name: "_from", value: "0"),
            URLQueryItem(name: "_to", value: "49")
        ]
        let url = components.url!
        let (object, response, retrievedAt) = try await loadJSON(url: url)
        let products: [Any]
        if let array = object as? [Any] {
            products = array
        } else if let wrapper = object as? [String: Any], let array = wrapper["products"] as? [Any] {
            products = array
        } else {
            throw RetailClientError.invalidResponse("H Mart returned an unreadable catalog response.")
        }
        guard products.count <= 50 else {
            throw RetailClientError.invalidResponse("H Mart returned more catalog results than requested.")
        }

        var matched: [(product: [String: Any], item: [String: Any])] = []
        for rawProduct in products {
            guard let product = rawProduct as? [String: Any], stringIdentity(product["productId"]) == productID else {
                throw RetailClientError.invalidResponse("H Mart returned a different product than requested.")
            }
            guard let items = product["items"] as? [Any] else {
                throw RetailClientError.invalidResponse("H Mart returned an unreadable item list.")
            }
            for rawItem in items {
                guard let item = rawItem as? [String: Any] else {
                    throw RetailClientError.invalidResponse("H Mart returned an unreadable catalog item.")
                }
                if stringIdentity(item["itemId"]) == itemID { matched.append((product, item)) }
            }
        }
        guard matched.count == 1, let match = matched.first else {
            throw RetailClientError.invalidResponse("The requested H Mart catalog item was not found uniquely.")
        }
        guard let sellers = match.item["sellers"] as? [Any] else {
            throw RetailClientError.invalidResponse("H Mart returned an unreadable seller list.")
        }
        let firstParty = try sellers.compactMap { raw -> [String: Any]? in
            guard let seller = raw as? [String: Any] else {
                throw RetailClientError.invalidResponse("H Mart returned an unreadable seller.")
            }
            return seller["sellerId"] as? String == "1" && seller["sellerName"] as? String == "HMart - US" ? seller : nil
        }
        guard firstParty.count == 1, let seller = firstParty.first else {
            throw RetailClientError.invalidResponse("A unique first-party H Mart offer is not available for this item.")
        }
        guard let offer = seller["commertialOffer"] as? [String: Any] else {
            throw RetailClientError.invalidResponse("H Mart returned an unreadable online offer.")
        }
        let name = try nonemptyString(match.item["name"] ?? match.product["productName"], label: "H Mart product name")
        let barcode = try optionalString(match.item["ean"], label: "H Mart barcode")
        let price = try optionalNonnegativeDecimal(offer, "Price", label: "H Mart price")
        let listPrice = try optionalNonnegativeDecimal(offer, "ListPrice", label: "H Mart list price")
        var available = try optionalBool(offer, "IsAvailable", label: "H Mart availability")
        if let stock = try optionalNonnegativeDecimal(offer, "AvailableQuantity", label: "H Mart stock"), stock == 0 {
            available = false
        }
        let isKit = try optionalBool(match.item, "isKit", label: "H Mart kit flag") ?? false
        let multiplier = try optionalNonnegativeDecimal(match.item, "unitMultiplier", label: "H Mart unit multiplier") ?? 1
        let parsed = (!isKit && multiplier == 1) ? hmartQuantity(name) : nil
        var conditions = "Online catalog reference; local store stock, shipping and promotion eligibility are unverified."
        if let listPrice, let price, listPrice != price {
            conditions += " Source ListPrice USD \(listPrice); discount terms are unverified."
        }
        if let validity = try optionalString(offer["PriceValidUntil"], label: "H Mart price validity") {
            guard ISO8601DateFormatter().date(from: validity) != nil else {
                throw RetailClientError.invalidResponse("H Mart returned an invalid price validity timestamp.")
            }
            conditions += " Source price validity ends \(validity)."
        }

        return FetchedPrice(
            productID: identity,
            productName: name,
            barcode: barcode,
            price: price,
            quantity: parsed?.quantity,
            unit: parsed?.unit,
            packCount: 1,
            quantityKind: parsed == nil ? .variable : .fixed,
            available: available,
            observedAt: try observedAt(response: response, retrievedAt: retrievedAt, source: "H Mart"),
            retrievedAt: retrievedAt,
            conditions: conditions,
            source: .hmart,
            sourceURL: response.url?.absoluteString ?? url.absoluteString,
            sourceExclusion: "Online catalog evidence cannot represent local shelf or pickup prices."
        )
    }

    private func loadJSON(url: URL) async throws -> (Any, HTTPURLResponse, Date) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let rawResponse: URLResponse
        do {
            (data, rawResponse) = try await session.data(for: request)
        } catch {
            throw RetailClientError.invalidResponse("The retailer source could not be reached. Try again later.")
        }
        let retrievedAt = now()
        guard let response = rawResponse as? HTTPURLResponse else {
            throw RetailClientError.invalidResponse("The retailer returned an unreadable network response.")
        }
        guard (200...299).contains(response.statusCode) else {
            throw RetailClientError.unavailable(response.statusCode)
        }
        do {
            return (try JSONSerialization.jsonObject(with: data), response, retrievedAt)
        } catch {
            throw RetailClientError.invalidResponse("The retailer returned unreadable product data.")
        }
    }
}

private extension RetailClient {
    typealias Package = (quantity: Decimal?, unit: MeasureUnit?, kind: QuantityKind)

    func wegmansQuantity(product: [String: Any], price: [String: Any]) throws -> Package {
        let soldByWeight = try optionalBool(product, "isSoldByWeight", label: "Wegmans weight-sale flag")
        let parsed = (product["packSize"] as? String).flatMap(parseWegmansSize)
        if soldByWeight == true {
            let approximate = try optionalNonnegativeDecimal(product, "onlineApproxUnitWeight", label: "Wegmans approximate weight")
            let unitPrice = price["unitPrice"] as? String
            if parsed?.quantity == 1, parsed?.unit == .lb,
               let unitPrice,
               unitPrice.range(of: #"^\$[0-9]+(?:\.[0-9]+)?/lb\.?$"#, options: .regularExpression) != nil,
               let approximate, approximate > 0 {
                return (approximate, .lb, .estimated)
            }
            return (nil, nil, .variable)
        }
        guard soldByWeight == false, let parsed, parsed.quantity > 0 else {
            return (nil, nil, .variable)
        }
        return (parsed.quantity, parsed.unit, .fixed)
    }

    func parseWegmansSize(_ text: String) -> (quantity: Decimal, unit: MeasureUnit)? {
        let pattern = #"^\s*([0-9]+(?:\.[0-9]+)?)\s*(gallon|lb|oz|count|ct)\.?\s*$"#
        guard let match = text.firstMatch(pattern), let value = Decimal(string: match[1], locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        switch match[2].lowercased() {
        case "gallon": return (value * 128, .flOz)
        case "lb": return (value, .lb)
        case "oz": return (value, .oz)
        case "count", "ct": return (value, .each)
        default: return nil
        }
    }

    func hmartQuantity(_ text: String) -> (quantity: Decimal, unit: MeasureUnit)? {
        if text.range(of: #"[0-9]\s*(?:[x×]|[-–])\s*[0-9]|pack\s+of|[0-9]\s*(?:packs?|pk)\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return nil }
        let pattern = #"(?<![\w.\-])([0-9]+(?:\.[0-9]+)?)\s*(fl\s*oz|oz|lbs?|kg|g|ml|l|count|ct|each)\b"#
        let matches = text.matches(pattern)
        guard (1...2).contains(matches.count) else { return nil }
        let sizes: [(Decimal, MeasureUnit)] = matches.compactMap { match in
            guard let amount = Decimal(string: match[1], locale: Locale(identifier: "en_US_POSIX")), amount > 0,
                  let unit = measureUnit(match[2]) else { return nil }
            return (amount, unit)
        }
        guard sizes.count == matches.count else { return nil }
        if sizes.count == 2 {
            let first = sizes[0], second = sizes[1]
            guard first.1.basis == second.1.basis, first.1 != second.1 else { return nil }
            let ratio = second.0 * second.1.baseFactor / (first.0 * first.1.baseFactor)
            guard ratio >= Decimal(string: "0.97")!, ratio <= Decimal(string: "1.03")! else { return nil }
        }
        return sizes[0]
    }

    func measureUnit(_ raw: String) -> MeasureUnit? {
        switch raw.lowercased().replacingOccurrences(of: " ", with: "") {
        case "oz": return .oz
        case "lb", "lbs": return .lb
        case "g": return .g
        case "kg": return .kg
        case "floz": return .flOz
        case "ml": return .ml
        case "l": return .l
        case "count", "ct", "each": return .each
        default: return nil
        }
    }

    func wegmansConditions(product: [String: Any], price: [String: Any]) throws -> String {
        if let vendor = product["soldByVendor"], !(vendor is NSNull) {
            throw RetailClientError.invalidResponse("Wegmans returned an unsupported third-party offer.")
        }
        var terms: [String] = []
        if let deposit = try optionalNonnegativeDecimal(product, "bottleDeposit", label: "Wegmans bottle deposit"), deposit > 0 {
            terms.append("Source bottleDeposit \(deposit); deposit units and final cost are unverified.")
        }
        let loyalty = try optionalObject(product, "price_inStoreLoyalty", label: "Wegmans loyalty price")
        if let loyalty, !loyalty.isEmpty {
            guard try requiredString(loyalty, "channelKey") == "133-Instore-Loyalty" else {
                throw RetailClientError.invalidResponse("Wegmans returned loyalty terms for a different channel.")
            }
            terms.append("Base in-store price shown; loyalty/coupon eligibility and terms are unverified.")
            var projection: [String: Any] = [:]
            for key in ["amount", "unitPrice", "fulfillmentPrice"] where loyalty[key] != nil { projection[key] = loyalty[key] }
            terms.append("Conditional loyalty price \(try jsonText(projection, label: "Wegmans loyalty price")).")
        }
        let discounts = try optionalArray(product, "loyaltyInstoreDiscount", maximum: 10, label: "Wegmans loyalty terms")
        if let discounts, !discounts.isEmpty {
            let fields = ["savings", "expiryDate", "triggerQuantity", "discountedQuantity", "discountPercent", "cartLimit", "name", "description"]
            let projection = try discounts.map { raw -> [String: Any] in
                guard let item = raw as? [String: Any] else { throw RetailClientError.invalidResponse("The retailer returned invalid Wegmans loyalty terms.") }
                return Dictionary(uniqueKeysWithValues: fields.compactMap { key in item[key].map { (key, $0) } })
            }
            if !terms.contains(where: { $0.contains("eligibility") }) { terms.append("Base in-store price shown; loyalty/coupon eligibility and terms are unverified.") }
            terms.append("Source loyalty terms \(try jsonText(projection, label: "Wegmans loyalty terms")).")
        }
        let coupons = try optionalArray(product, "digitalCouponsOfferIds", maximum: 50, label: "Wegmans coupon identities")
        if let coupons, !coupons.isEmpty {
            guard coupons.allSatisfy({ $0 is String }) else { throw RetailClientError.invalidResponse("The retailer returned invalid Wegmans coupon identities.") }
            if !terms.contains(where: { $0.contains("eligibility") }) { terms.append("Base in-store price shown; loyalty/coupon eligibility and terms are unverified.") }
            terms.append("Source coupon IDs: \(coupons.compactMap { $0 as? String }.joined(separator: ", ")); details may be missing.")
        }
        let offers = try optionalArray(product, "digitalCouponsOffers", maximum: 50, label: "Wegmans coupon terms")
        if let offers, !offers.isEmpty {
            guard offers.allSatisfy({ $0 is [String: Any] }) else { throw RetailClientError.invalidResponse("The retailer returned invalid Wegmans coupon terms.") }
            terms.append("Additional coupon offers are present; quantities, validity and eligibility are unresolved.")
        }
        if try optionalString(product["discountType"], label: "Wegmans discount type") != nil,
           !terms.contains(where: { $0.contains("eligibility") }) {
            terms.append("Base in-store price shown; loyalty/coupon eligibility and terms are unverified.")
        }
        if try optionalBool(product, "isSoldByWeight", label: "Wegmans weight-sale flag") == true {
            let unitPrice = price["unitPrice"] as? String ?? "unknown"
            let fulfillment = try optionalNonnegativeDecimal(price, "fulfillmentPrice", label: "Wegmans fulfillment price")
            terms.append("Estimated-weight package total; source unit price \(unitPrice), fulfillmentPrice \(fulfillment.map(String.init(describing:)) ?? "unknown"); actual weight and cost may vary.")
        }
        return terms.joined(separator: " ")
    }

    func observedAt(response: HTTPURLResponse, retrievedAt: Date, source: String) throws -> Date {
        let dateHeader = response.value(forHTTPHeaderField: "Date")
        let base: Date
        if let dateHeader {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            guard let parsed = formatter.date(from: dateHeader) else {
                throw RetailClientError.invalidResponse("\(source) returned an invalid response date.")
            }
            base = parsed
        } else {
            base = retrievedAt
        }
        guard base <= retrievedAt else {
            throw RetailClientError.invalidResponse("\(source) returned a response date in the future.")
        }
        let ageText = response.value(forHTTPHeaderField: "Age") ?? "0"
        guard !ageText.isEmpty, ageText.allSatisfy(\.isNumber), let age = TimeInterval(ageText) else {
            throw RetailClientError.invalidResponse("\(source) returned invalid cache metadata.")
        }
        return min(base, retrievedAt.addingTimeInterval(-age))
    }
}

private func requiredString(_ object: [String: Any], _ key: String) throws -> String {
    try nonemptyString(object[key], label: key)
}

private func nonemptyString(_ value: Any?, label: String) throws -> String {
    guard let string = value as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw RetailClientError.invalidResponse("The retailer returned a missing or invalid \(label).")
    }
    return string
}

private func optionalString(_ value: Any?, label: String) throws -> String? {
    guard let value, !(value is NSNull) else { return nil }
    return try nonemptyString(value, label: label)
}

private func optionalBool(_ object: [String: Any], _ key: String, label: String) throws -> Bool? {
    guard let value = object[key], !(value is NSNull) else { return nil }
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
        throw RetailClientError.invalidResponse("The retailer returned an invalid \(label).")
    }
    return number.boolValue
}

private func optionalNonnegativeDecimal(_ object: [String: Any], _ key: String, label: String) throws -> Decimal? {
    guard let value = object[key], !(value is NSNull) else { return nil }
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          let decimal = Decimal(string: number.stringValue, locale: Locale(identifier: "en_US_POSIX")),
          !decimal.isNaN, decimal >= 0 else {
        throw RetailClientError.invalidResponse("The retailer returned an invalid \(label).")
    }
    return decimal
}

private func firstString(_ object: [String: Any], _ key: String, label: String) throws -> String? {
    guard let value = object[key], !(value is NSNull) else { return nil }
    guard let values = value as? [Any] else {
        throw RetailClientError.invalidResponse("The retailer returned an invalid \(label).")
    }
    for raw in values { _ = try nonemptyString(raw, label: label) }
    return values.first as? String
}

private func optionalObject(_ object: [String: Any], _ key: String, label: String) throws -> [String: Any]? {
    guard let value = object[key], !(value is NSNull) else { return nil }
    guard let result = value as? [String: Any] else {
        throw RetailClientError.invalidResponse("The retailer returned an invalid \(label).")
    }
    return result
}

private func optionalArray(_ object: [String: Any], _ key: String, maximum: Int, label: String) throws -> [Any]? {
    guard let value = object[key], !(value is NSNull) else { return nil }
    guard let array = value as? [Any], array.count <= maximum else {
        throw RetailClientError.invalidResponse("The retailer returned invalid \(label).")
    }
    return array
}

private func jsonText(_ value: Any, label: String) throws -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        throw RetailClientError.invalidResponse("The retailer returned invalid \(label).")
    }
    return text
}

private func stringIdentity(_ value: Any?) -> String? {
    if let string = value as? String { return string }
    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
    return nil
}

private extension String {
    func matches(_ pattern: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(startIndex..., in: self)
        return regex.matches(in: self, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                guard let range = Range(match.range(at: index), in: self) else { return "" }
                return String(self[range])
            }
        }
    }

    func firstMatch(_ pattern: String) -> [String]? { matches(pattern).first }
}
