import Foundation
import XCTest
@testable import StapleScoutKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class SharedMarketClientTests: XCTestCase {
    private let token = "offline-test-access-token-1234567890123456"
    private let baseURL = URL(string: "https://shared-cache.example.invalid/pilot/")!
    private var servedAt: Date { Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) - 60) }

    override func tearDown() {
        SharedMarketStub.reset()
        super.tearDown()
    }

    func testPriceWirePreservesExactDecimalDatesUnknownStockAndConditions() async throws {
        let served = servedAt
        var expected = fixture(at: served)
        expected.price = Decimal(string: "0.1234567890123456789012345678901234567")!
        expected.quantity = Decimal(string: "64.25000000000000000000000000000000001")!
        expected.barcode = "000012340000"
        expected.packCount = 3
        expected.quantityKind = .estimated
        expected.conditions = "Member offer; limit 2. Actual weight varies. 지역 가격."
        expected.sourceExclusion = "Package weight is estimated; stock is unknown."
        let value = expected
        let payload = try pricePayload(value, served: served)
        XCTAssertEqual((payload["product"] as? [String: Any])?["price"] as? String,
                       NSDecimalNumber(decimal: expected.price!).stringValue)
        try SharedMarketStub.install(json: payload)
        let actual = try await makeClient().fetch(request())
        assertEvidence(actual, equals: value)
        XCTAssertNil(actual.available)
        XCTAssertEqual(SharedMarketStub.requests.count, 1)
    }

    func testUnavailableAndUnknownTombstonesDoNotAcquirePriceSizeOrStock() async throws {
        let served = servedAt
        for availability: Bool? in [nil, false] {
            var value = fixture(at: served)
            value.price = nil; value.quantity = nil; value.unit = nil; value.available = availability
            value.quantityKind = .variable
            value.sourceExclusion = "Source package size is unknown."
            var payload = try pricePayload(value, served: served)
            var product = try XCTUnwrap(payload["product"] as? [String: Any])
            product["price"] = NSNull(); product["quantity"] = NSNull(); product["unit"] = NSNull()
            if availability == nil { product["available"] = NSNull() }
            payload["product"] = product
            try SharedMarketStub.install(json: payload)
            let actual = try await makeClient().fetch(request())
            assertEvidence(actual, equals: value)
            XCTAssertNil(actual.price)
            XCTAssertNil(actual.quantity)
            XCTAssertNil(actual.unit)
            XCTAssertEqual(actual.available, availability)
        }
    }

    func testSearchPreservesCompositeIdentityOnlineSourceAndPartialMessage() async throws {
        let served = servedAt
        var expected = fixture(id: "332:445", store: .hmart, at: served)
        expected.available = false
        expected.conditions = "Online reference only. Shipping and local stock are unverified."
        expected.sourceExclusion = "Online evidence cannot represent local shelf or pickup prices."
        let page = RetailSearchPage(candidates: [expected], message: "One product price could not be checked.")
        try SharedMarketStub.install(json: searchPayload(page, store: .hmart, served: served))
        let actual = try await makeClient().search(query: "rice", location: location(.hmart), channel: .online)
        XCTAssertEqual(actual.message, page.message)
        XCTAssertEqual(actual.candidates.count, 1)
        assertEvidence(try XCTUnwrap(actual.candidates.first), equals: expected)
    }

    func testPriceAndSearchSendOnlyCanonicalPublicContextAndAuthorizationHeader() async throws {
        let served = servedAt
        let value = fixture(at: served)
        let price = try JSONSerialization.data(withJSONObject: pricePayload(value, served: served))
        let search = try JSONSerialization.data(withJSONObject: searchPayload(RetailSearchPage(candidates: [value]), served: served))
        SharedMarketStub.install { request in
            let data = request.url?.path.hasSuffix("/v1/price") == true ? price : search
            return (200, [:], data)
        }
        let client = try makeClient()
        // Independent libraries have different location UUIDs for the same public context.
        let firstLocation = StoreLocation(store: .wegmans, name: "My private location label", code: "133")
        let secondLocation = StoreLocation(store: .wegmans, name: "Another user's label", code: "133")
        _ = try await client.fetch(request(location: firstLocation))
        _ = try await client.search(query: "milk & eggs", location: secondLocation, channel: .inStore)
        let requests = SharedMarketStub.requests
        XCTAssertEqual(requests.count, 2)
        for sent in requests {
            let url = try XCTUnwrap(sent.url)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let items = try XCTUnwrap(components.queryItems)
            let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(Set(values.keys), Set(["store", "storeCode", "channel", url.path.hasSuffix("/price") ? "productID" : "q"]))
            XCTAssertEqual(values["store"], "wegmans")
            XCTAssertEqual(values["storeCode"], "133")
            XCTAssertEqual(values["channel"], "in_store")
            XCTAssertEqual(sent.httpMethod, "GET")
            XCTAssertNil(sent.httpBody)
            XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer " + token)
            XCTAssertEqual(sent.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertNil(sent.value(forHTTPHeaderField: "Cookie"))
            XCTAssertLessThanOrEqual(sent.timeoutInterval, 20)
            XCTAssertEqual(url.host, baseURL.host)
            XCTAssertTrue(url.path.hasPrefix("/pilot/v1/"))
            for privateValue in [token, firstLocation.id.uuidString, secondLocation.id.uuidString, firstLocation.name, secondLocation.name] {
                XCTAssertFalse(url.absoluteString.contains(privateValue))
            }
            let otherHeaders = (sent.allHTTPHeaderFields ?? [:]).filter { $0.key.caseInsensitiveCompare("Authorization") != .orderedSame }
            XCTAssertFalse(otherHeaders.values.contains { $0.contains(token) })
        }
        XCTAssertEqual(URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value, "milk & eggs")
    }

    func testPriceRejectsDifferentStoreLocationChannelProductSchemaAndSource() async throws {
        let served = servedAt
        let original = try pricePayload(fixture(at: served), served: served)
        var invalid: [[String: Any]] = []
        for (field, replacement) in [("store", "hmart"), ("storeCode", "134"), ("channel", "online")] {
            var payload = original
            var context = try XCTUnwrap(payload["context"] as? [String: Any])
            context[field] = replacement; payload["context"] = context; invalid.append(payload)
        }
        var payload = original; payload["schemaVersion"] = 2; invalid.append(payload)
        payload = original; payload["schemaVersion"] = NSNull(); invalid.append(payload)
        for (field, replacement) in [("productID", "999"), ("source", "hmart"), ("source", "manual"), ("source", "unknown_source")] {
            payload = original
            var product = try XCTUnwrap(payload["product"] as? [String: Any])
            product[field] = replacement; payload["product"] = product; invalid.append(payload)
        }
        for payload in invalid { await assertPriceRejected(payload) }
    }

    func testSearchRejectsDuplicatesTooManyProductsAndInconsistentContextOrSource() async throws {
        let served = servedAt
        let value = fixture(at: served)
        let original = try searchPayload(RetailSearchPage(candidates: [value]), served: served)
        let product = try XCTUnwrap((original["products"] as? [[String: Any]])?.first)
        var invalid: [[String: Any]] = []
        var payload = original; payload["products"] = [product, product]; invalid.append(payload)
        payload = original; payload["products"] = Array(repeating: product, count: 6); invalid.append(payload)
        payload = original; payload["schemaVersion"] = 0; invalid.append(payload)
        payload = original; payload["context"] = ["store": "hmart", "channel": "online"]; invalid.append(payload)
        payload = original
        var wrongSource = product; wrongSource["source"] = "lidl"; payload["products"] = [wrongSource]; invalid.append(payload)
        for payload in invalid {
            try SharedMarketStub.install(json: payload)
            do {
                _ = try await makeClient().search(query: "milk", location: location(), channel: .inStore)
                XCTFail("Inconsistent search evidence must be rejected")
            } catch RetailClientError.invalidResponse {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(SharedMarketStub.requests.count, 1)
        }
    }

    func testMalformedDecimalsAndUnsupportedCurrencyAreRejected() async throws {
        let served = servedAt
        let original = try pricePayload(fixture(at: served), served: served)
        let invalidAmounts = ["", "NaN", "Infinity", "-1", "-0", "+1", "1e2", "1,000", " 3.49", "3.49 ", ".5", "1.", "1000000.01", String(repeating: "9", count: 41)]
        for amount in invalidAmounts {
            var payload = original
            var product = try XCTUnwrap(payload["product"] as? [String: Any])
            product["price"] = amount; payload["product"] = product
            await assertPriceRejected(payload)
        }
        for (field, replacement) in [("quantity", "0"), ("quantity", "-2"), ("currency", "EUR")] {
            var payload = original
            var product = try XCTUnwrap(payload["product"] as? [String: Any])
            product[field] = replacement; payload["product"] = product
            await assertPriceRejected(payload)
        }
        var numericAmount = original
        var product = try XCTUnwrap(numericAmount["product"] as? [String: Any])
        product["price"] = 3.49; numericAmount["product"] = product
        await assertPriceRejected(numericAmount)
    }

    func testZeroPriceIsPreservedAsKnownZero() async throws {
        let served = servedAt
        var value = fixture(at: served); value.price = 0
        try SharedMarketStub.install(json: pricePayload(value, served: served))
        let result = try await makeClient().fetch(request())
        XCTAssertEqual(result.price, 0)
        XCTAssertNotNil(result.price)
    }

    func testMalformedTimesFutureEvidenceAndInactiveOffersAreRejected() async throws {
        let served = servedAt
        let original = try pricePayload(fixture(at: served), served: served)
        var invalid: [[String: Any]] = []
        for (field, value) in [("observedAt", served.addingTimeInterval(1)),
                               ("retrievedAt", served.addingTimeInterval(1)),
                               ("validFrom", served.addingTimeInterval(1)),
                               ("validUntil", served)] {
            var payload = original
            var product = try XCTUnwrap(payload["product"] as? [String: Any])
            product[field] = value.timeIntervalSince1970 * 1_000
            payload["product"] = product; invalid.append(payload)
        }
        var payload = original; payload["servedAt"] = Date().addingTimeInterval(600).timeIntervalSince1970 * 1_000; invalid.append(payload)
        payload = original
        var product = try XCTUnwrap(payload["product"] as? [String: Any])
        product["observedAt"] = "2026-10-16T12:00:00Z"; payload["product"] = product; invalid.append(payload)
        payload = original; product = try XCTUnwrap(payload["product"] as? [String: Any])
        product["retrievedAt"] = NSNull(); payload["product"] = product; invalid.append(payload)
        for payload in invalid { await assertPriceRejected(payload) }
    }

    func testEvidenceAtLeast48HoursOldIsRejectedAgainstTheCurrentClock() async throws {
        let current = Date()
        let served = current.addingTimeInterval(-300)
        for age: TimeInterval in [172_800, 172_801] {
            var value = fixture(at: served)
            value.observedAt = current.addingTimeInterval(-age)
            // The observation is still less than 48h old at servedAt. Checking
            // only the server's timestamp would incorrectly accept this body.
            XCTAssertLessThan(served.timeIntervalSince(value.observedAt), 172_800)
            await assertPriceRejected(try pricePayload(value, served: served))
        }
    }

    func testOfferThatExpiredAfterServingCannotBeAcceptedAsCurrentEvidence() async throws {
        let current = Date()
        let served = current.addingTimeInterval(-60)
        var value = fixture(at: served)
        value.validUntil = current.addingTimeInterval(-1)
        XCTAssertLessThan(served, value.validUntil!)
        await assertPriceRejected(try pricePayload(value, served: served))
    }

    func testServedAtClockToleranceCannotAuthorizeFutureSourceTimestamps() async throws {
        let current = Date()
        let served = current.addingTimeInterval(4.5)
        var value = fixture(at: served)
        value.observedAt = current.addingTimeInterval(3)
        value.retrievedAt = current.addingTimeInterval(4)
        // The response's permitted servedAt skew must not apply to the
        // retailer's original observation and retrieval timestamps.
        await assertPriceRejected(try pricePayload(value, served: served))
    }

    func testPriceRejectsWrongPublicSourceHostProductLocationOrScheme() async throws {
        let served = servedAt
        let invalidURLs = ["https://other-retailer.example.invalid/product/123",
                           "https://www.wegmans.com/api/products/133/999",
                           "https://www.wegmans.com/api/products/134/123",
                           "https://www.wegmans.com.example.invalid/api/products/133/123",
                           "https://www.wegmans.com/api/products/133/123?otherStore=134",
                           "https://user:password@www.wegmans.com/api/products/133/123",
                           "http://www.wegmans.com/api/products/133/123"]
        for url in invalidURLs {
            var value = fixture(at: served); value.sourceURL = url
            await assertPriceRejected(try pricePayload(value, served: served))
        }
        var hmart = fixture(id: "332:445", store: .hmart, at: served)
        hmart.sourceURL = "https://www.hmart.com/api/catalog_system/pub/products/search/?fq=productId:333"
        try SharedMarketStub.install(json: searchPayload(RetailSearchPage(candidates: [hmart]), store: .hmart, served: served))
        do {
            _ = try await makeClient().search(query: "rice", location: location(.hmart), channel: .online)
            XCTFail("H Mart's source URL must retain the candidate's product identity")
        } catch RetailClientError.invalidResponse {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(SharedMarketStub.requests.count, 1)
    }

    func testQuantityAndUnitMustBothBeKnownOrBothUnknown() async throws {
        let served = servedAt
        var value = fixture(at: served); value.unit = nil
        await assertPriceRejected(try pricePayload(value, served: served))
        value = fixture(at: served); value.quantity = nil
        await assertPriceRejected(try pricePayload(value, served: served))
    }

    func testRetailerSpecificRequestIdentitiesAreRejectedBeforeNetwork() async throws {
        for (store, identity, channel) in [(StoreID.wegmans, "123:456", Channel.inStore),
                                           (.lidl, "123:456", .inStore), (.hmart, "123", .online)] {
            SharedMarketStub.install { _ in XCTFail("Invalid retailer identity must not be sent"); return (500, [:], Data()) }
            let location = location(store)
            let invalid = FetchRequest(variant: ProductVariant(store: store, productID: identity, name: "Invalid identity", quantity: 1, unit: .each),
                                       location: location, channel: channel)
            do {
                _ = try await makeClient().fetch(invalid)
                XCTFail("\(store.rawValue) must reject identity \(identity)")
            } catch RetailClientError.invalidProduct {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertTrue(SharedMarketStub.requests.isEmpty)
        }
    }

    func testRetailerSpecificSearchResultIdentitiesAreRejected() async throws {
        let served = servedAt
        for (store, identity) in [(StoreID.wegmans, "123:456"), (.lidl, "123:456"), (.hmart, "332")] {
            var value = fixture(id: identity, store: store, at: served)
            if store == .lidl {
                value.source = .lidl
                value.sourceURL = "https://www.lidl.com/p/milk/p\(identity)"
                value.sourceExclusion = "Lidl local stock is unknown."
            }
            try SharedMarketStub.install(json: searchPayload(RetailSearchPage(candidates: [value]), store: store, served: served))
            do {
                _ = try await makeClient().search(query: "milk", location: location(store), channel: store == .hmart ? .online : .inStore)
                XCTFail("\(store.rawValue) must reject search identity \(identity)")
            } catch RetailClientError.invalidResponse {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(SharedMarketStub.requests.count, 1)
        }
    }

    func testHTTPIsAllowedOnlyForLoopbackAndInvalidConfigurationDoesNotSendRequests() throws {
        SharedMarketStub.install { _ in XCTFail("Configuration validation cannot make a request"); return (500, [:], Data()) }
        for address in ["http://localhost:8080/", "http://127.0.0.1:8080/", "http://[::1]:8080/", "https://cache.example.invalid/"] {
            XCTAssertNoThrow(try makeClient(baseURL: URL(string: address)!))
        }
        for address in ["http://cache.example.invalid/", "http://192.168.1.3/", "http://127.0.0.1.example.invalid/", "ftp://localhost/",
                        "https://user:password@cache.example.invalid/", "https://cache.example.invalid/?token=secret", "https://cache.example.invalid/#secret"] {
            XCTAssertThrowsError(try makeClient(baseURL: URL(string: address)!))
        }
        for invalidToken in ["short", String(repeating: "a", count: 257), String(repeating: "a", count: 32) + "\n", String(repeating: "a", count: 32) + " "] {
            XCTAssertThrowsError(try SharedMarketClient(baseURL: baseURL, accessToken: invalidToken, configuration: configuration()))
        }
        XCTAssertTrue(SharedMarketStub.requests.isEmpty)
    }

    func testHTTP429IsExplicitAndNeverRetriesOrFallsBackToRetailers() async throws {
        SharedMarketStub.install { _ in
            (429, ["Retry-After": "0"], Data(#"{"code":"budgetExceeded","message":"No upstream attempts remain."}"#.utf8))
        }
        let client = try makeClient()
        do {
            _ = try await client.fetch(request())
            XCTFail("HTTP 429 must surface to the caller")
        } catch RetailClientError.unsupportedSource(let message) { XCTAssertTrue(message.contains("limit")) }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(SharedMarketStub.requests.count, 1)
        do {
            _ = try await client.search(query: "milk", location: location(), channel: .inStore)
            XCTFail("HTTP 429 must surface to the caller")
        } catch RetailClientError.unsupportedSource(let message) { XCTAssertTrue(message.contains("limit")) }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(SharedMarketStub.requests.count, 2)
        XCTAssertTrue(SharedMarketStub.requests.allSatisfy { $0.url?.host == baseURL.host })
    }

    func testNonSuccessAndOversizedResponsesDoNotBecomeEvidence() async throws {
        for status in [401, 302, 500, 503] {
            SharedMarketStub.install { _ in (status, [:], Data()) }
            do { _ = try await makeClient().fetch(request()); XCTFail("HTTP \(status) must fail") }
            catch is RetailClientError {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(SharedMarketStub.requests.count, 1)
        }
        SharedMarketStub.install { _ in (200, [:], Data(repeating: 32, count: 1_000_001)) }
        do { _ = try await makeClient().fetch(request()); XCTFail("Oversized payload must fail") }
        catch RetailClientError.invalidResponse {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(SharedMarketStub.requests.count, 1)
    }

    func testUnexpectedFinalResponseURLIsRejectedWithoutAnotherRequest() async throws {
        let served = servedAt
        let payload = try pricePayload(fixture(at: served), served: served)
        for unexpectedURL in [URL(string: "https://other-origin.example.invalid/v1/price")!,
                              baseURL.appendingPathComponent("different-endpoint")] {
            try SharedMarketStub.install(json: payload)
            SharedMarketStub.overrideResponseURL(unexpectedURL)
            do {
                _ = try await makeClient().fetch(request())
                XCTFail("A body delivered under another response URL must be rejected")
            } catch RetailClientError.invalidResponse {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(SharedMarketStub.requests.count, 1)
            XCTAssertEqual(SharedMarketStub.requests.first?.url?.host, baseURL.host)
        }
    }

    private func assertPriceRejected(_ payload: [String: Any], file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try SharedMarketStub.install(json: payload)
            _ = try await makeClient().fetch(request())
            XCTFail("Invalid shared evidence must be rejected", file: file, line: line)
        } catch RetailClientError.invalidResponse {} catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
        XCTAssertEqual(SharedMarketStub.requests.count, 1, file: file, line: line)
    }

    private func makeClient(baseURL: URL? = nil) throws -> SharedMarketClient {
        try SharedMarketClient(baseURL: baseURL ?? self.baseURL, accessToken: token, configuration: configuration())
    }
    private func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SharedMarketStub.self]
        return configuration
    }
    private func location(_ store: StoreID = .wegmans) -> StoreLocation { StoreLocation.defaults.first { $0.store == store }! }
    private func request(location: StoreLocation? = nil) -> FetchRequest {
        let location = location ?? self.location()
        return FetchRequest(variant: ProductVariant(store: location.store, productID: "123", name: "Milk", quantity: 64, unit: .flOz),
                            location: location, channel: .inStore)
    }
    private func pricePayload(_ value: FetchedPrice, served: Date) throws -> [String: Any] {
        let response = SharedPriceResponse(context: SharedPriceContext(location: location(), channel: .inStore), value: value, cacheHit: true, servedAt: served)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: SharedMarketWire.encoder().encode(response)) as? [String: Any])
    }
    private func searchPayload(_ page: RetailSearchPage, store: StoreID = .wegmans, served: Date) throws -> [String: Any] {
        let response = SharedSearchResponse(context: SharedPriceContext(location: location(store), channel: store == .hmart ? .online : .inStore),
                                            page: page, cacheHit: true, servedAt: served)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: SharedMarketWire.encoder().encode(response)) as? [String: Any])
    }
    private func fixture(id: String = "123", store: StoreID = .wegmans, at date: Date) -> FetchedPrice {
        let source: SourceID = store == .hmart ? .hmart : .wegmans
        let url = store == .hmart ? "https://www.hmart.com/api/catalog_system/pub/products/search/?fq=productId:332" : "https://www.wegmans.com/api/products/133/\(id)"
        return FetchedPrice(productID: id, productName: "Whole milk", price: Decimal(string: "3.49"), quantity: 64, unit: .flOz,
                            available: nil, observedAt: date.addingTimeInterval(-180.125), retrievedAt: date.addingTimeInterval(-120.875),
                            conditions: "Source conditions", source: source, sourceURL: url,
                            sourceExclusion: store == .hmart ? "Online reference only." : nil,
                            validFrom: date.addingTimeInterval(-3_600), validUntil: date.addingTimeInterval(3_600))
    }
    private func assertEvidence(_ actual: FetchedPrice, equals expected: FetchedPrice, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.productID, expected.productID, file: file, line: line)
        XCTAssertEqual(actual.productName, expected.productName, file: file, line: line)
        XCTAssertEqual(actual.barcode, expected.barcode, file: file, line: line)
        XCTAssertEqual(actual.price, expected.price, file: file, line: line)
        XCTAssertEqual(actual.quantity, expected.quantity, file: file, line: line)
        XCTAssertEqual(actual.unit, expected.unit, file: file, line: line)
        XCTAssertEqual(actual.packCount, expected.packCount, file: file, line: line)
        XCTAssertEqual(actual.quantityKind, expected.quantityKind, file: file, line: line)
        XCTAssertEqual(actual.available, expected.available, file: file, line: line)
        XCTAssertEqual(actual.observedAt, expected.observedAt, file: file, line: line)
        XCTAssertEqual(actual.retrievedAt, expected.retrievedAt, file: file, line: line)
        XCTAssertEqual(actual.conditions, expected.conditions, file: file, line: line)
        XCTAssertEqual(actual.source, expected.source, file: file, line: line)
        XCTAssertEqual(actual.sourceURL, expected.sourceURL, file: file, line: line)
        XCTAssertEqual(actual.sourceExclusion, expected.sourceExclusion, file: file, line: line)
        XCTAssertEqual(actual.validFrom, expected.validFrom, file: file, line: line)
        XCTAssertEqual(actual.validUntil, expected.validUntil, file: file, line: line)
    }
}

/// Separate from retailer fixture protocols so every URL, including an accidental
/// fallback, is intercepted without making any live network request.
private final class SharedMarketStub: URLProtocol {
    typealias Handler = (URLRequest) throws -> (Int, [String: String], Data)
    private static let lock = NSLock()
    private static var handler: Handler?
    private static var recorded: [URLRequest] = []
    private static var responseURL: URL?
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    static func reset() { lock.lock(); defer { lock.unlock() }; handler = nil; recorded = []; responseURL = nil }
    static func install(_ newHandler: @escaping Handler) { lock.lock(); defer { lock.unlock() }; recorded = []; handler = newHandler; responseURL = nil }
    static func overrideResponseURL(_ url: URL) { lock.lock(); defer { lock.unlock() }; responseURL = url }
    static func install(json: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        install { _ in (200, ["Content-Type": "application/json"], data) }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.recorded.append(request); let handler = Self.handler; let responseURL = Self.responseURL; Self.lock.unlock()
        guard let handler else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        do {
            let (status, headers, data) = try handler(request)
            guard let url = responseURL ?? request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
                throw URLError(.badServerResponse)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
