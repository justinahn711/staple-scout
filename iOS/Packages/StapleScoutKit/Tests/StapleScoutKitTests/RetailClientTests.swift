import XCTest
@testable import StapleScoutKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class RetailClientTests: XCTestCase {
    private let retrievedAt = Date(timeIntervalSince1970: 1_760_000_000)

    override func tearDown() {
        FixtureURLProtocol.handler = nil
        super.tearDown()
    }

    func testCapabilitiesAreLocationAndChannelSpecific() {
        let locations = Dictionary(uniqueKeysWithValues: StoreLocation.defaults.map { ($0.store, $0) })
        XCTAssertTrue(SourceCapability.forLocation(locations[.wegmans]!, channel: .inStore).isConnected)
        XCTAssertFalse(SourceCapability.forLocation(locations[.wegmans]!, channel: .pickup).isConnected)
        XCTAssertTrue(SourceCapability.forLocation(locations[.hmart]!, channel: .online).isConnected)
        XCTAssertFalse(SourceCapability.forLocation(locations[.hmart]!, channel: .inStore).isConnected)
        XCTAssertFalse(SourceCapability.forLocation(locations[.target]!, channel: .inStore).isConnected)
        XCTAssertFalse(SourceCapability.forLocation(locations[.walmart]!, channel: .inStore).isConnected)
        XCTAssertFalse(SourceCapability.forLocation(locations[.lidl]!, channel: .inStore).isConnected)
    }

    func testWegmansPreservesExactIdentityPackageStockAndCacheAge() async throws {
        let payload = try fixtureArray("wegmans-products")[0]
        FixtureURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://www.wegmans.com/api/products/133/94427")
            XCTAssertLessThanOrEqual(request.timeoutInterval, 10)
            return Self.response(request, json: payload, headers: ["Date": "Thu, 09 Oct 2025 08:52:00 GMT", "Age": "120"])
        }
        let client = RetailClient(session: fixtureSession(), now: { self.retrievedAt })
        let result = try await client.fetch(request(store: .wegmans, productID: "94427", channel: .inStore))
        XCTAssertEqual(result.productID, "94427")
        XCTAssertEqual(result.productName, "Wegmans Vitamin D Whole Milk")
        XCTAssertEqual(result.barcode, "00077890944271")
        XCTAssertEqual(result.price, Decimal(string: "3.39"))
        XCTAssertEqual(result.quantity, 128)
        XCTAssertEqual(result.unit, .flOz)
        XCTAssertEqual(result.quantityKind, .fixed)
        XCTAssertEqual(result.available, false)
        XCTAssertEqual(result.source, .wegmans)
        XCTAssertEqual(result.conditions, "")
        XCTAssertEqual(result.observedAt, retrievedAt.addingTimeInterval(-120))
        XCTAssertEqual(result.retrievedAt, retrievedAt)
    }

    func testWegmansEstimatedWeightUsesBasePriceAndRetainsConditionalTerms() async throws {
        let payload = try fixtureArray("wegmans-products")[1]
        FixtureURLProtocol.handler = { Self.response($0, json: payload) }
        let result = try await RetailClient(session: fixtureSession(), now: { self.retrievedAt })
            .fetch(request(store: .wegmans, productID: "57084", channel: .inStore))
        XCTAssertEqual(result.price, 11)
        XCTAssertEqual(result.quantity, Decimal(string: "4.8"))
        XCTAssertEqual(result.unit, .lb)
        XCTAssertEqual(result.quantityKind, .estimated)
        XCTAssertTrue(result.conditions.contains("9.56"))
        XCTAssertTrue(result.conditions.contains("eligibility"))
        XCTAssertTrue(result.conditions.contains("actual weight and cost may vary"))
    }

    func testWegmansRejectsDeliveryPriceWithoutFallback() async throws {
        var payload = try XCTUnwrap(try fixtureArray("wegmans-products")[0] as? [String: Any])
        var price = try XCTUnwrap(payload["price_inStore"] as? [String: Any])
        price["channelKey"] = "133-Delivery"
        payload["price_inStore"] = price
        FixtureURLProtocol.handler = { Self.response($0, json: payload) }
        do {
            _ = try await RetailClient(session: fixtureSession(), now: { self.retrievedAt })
                .fetch(request(store: .wegmans, productID: "94427", channel: .inStore))
            XCTFail("Expected an identity error")
        } catch let error as RetailClientError {
            XCTAssertTrue(error.localizedDescription.contains("different sales channel"))
        }
    }

    func testWegmansMissingShelfEvidenceStaysUnknown() async throws {
        var payload = try XCTUnwrap(try fixtureArray("wegmans-products")[0] as? [String: Any])
        payload.removeValue(forKey: "price_inStore")
        payload.removeValue(forKey: "isAvailable")
        payload["price_delivery"] = ["amount": 0.01, "channelKey": "133-Delivery"]
        FixtureURLProtocol.handler = { Self.response($0, json: payload) }
        let result = try await RetailClient(session: fixtureSession(), now: { self.retrievedAt })
            .fetch(request(store: .wegmans, productID: "94427", channel: .inStore))
        XCTAssertNil(result.price)
        XCTAssertNil(result.available)
    }

    func testWegmansFalseStockFlagDominatesMissingFlag() async throws {
        var payload = try XCTUnwrap(try fixtureArray("wegmans-products")[0] as? [String: Any])
        payload.removeValue(forKey: "isSoldAtStore")
        payload["isAvailable"] = false
        FixtureURLProtocol.handler = { Self.response($0, json: payload) }
        let result = try await RetailClient(session: fixtureSession(), now: { self.retrievedAt })
            .fetch(request(store: .wegmans, productID: "94427", channel: .inStore))
        XCTAssertEqual(result.available, false)
    }

    func testUnknownWegmansPackageCarriesSourceExclusion() async throws {
        var payload = try XCTUnwrap(try fixtureArray("wegmans-products")[0] as? [String: Any])
        payload["packSize"] = "family size"
        FixtureURLProtocol.handler = { Self.response($0, json: payload) }
        let result = try await RetailClient(session: fixtureSession(), now: { self.retrievedAt })
            .fetch(request(store: .wegmans, productID: "94427", channel: .inStore))
        XCTAssertNil(result.quantity)
        XCTAssertNil(result.unit)
        XCTAssertEqual(result.quantityKind, .variable)
        XCTAssertEqual(result.sourceExclusion, "Source package size is unknown.")
    }

    func testUnsupportedContextMakesNoNetworkRequest() async throws {
        var calls = 0
        FixtureURLProtocol.handler = { request in
            calls += 1
            return Self.response(request, json: [:])
        }
        do {
            _ = try await RetailClient(session: fixtureSession()).fetch(request(store: .wegmans, productID: "94427", channel: .pickup))
            XCTFail("Expected an unsupported source error")
        } catch let error as RetailClientError {
            XCTAssertTrue(error.localizedDescription.contains("store 133"))
        }
        XCTAssertEqual(calls, 0)
    }

    func testHMartIsOnlineOnlyAndPreservesCompositeIdentity() async throws {
        let payload = try fixtureObject("hmart-catalog")
        FixtureURLProtocol.handler = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "fq" })?.value, "productId:332")
            return Self.response(request, json: payload, status: 206, headers: ["Age": "120"])
        }
        let result = try await RetailClient(session: fixtureSession(), now: { self.retrievedAt })
            .fetch(request(store: .hmart, productID: "332:332", channel: .online))
        XCTAssertEqual(result.productID, "332:332")
        XCTAssertEqual(result.barcode, "00001234")
        XCTAssertEqual(result.price, Decimal(string: "4.99"))
        XCTAssertEqual(result.quantity, Decimal(string: "7.05"))
        XCTAssertEqual(result.unit, .oz)
        XCTAssertEqual(result.available, false)
        XCTAssertEqual(result.source, .hmart)
        XCTAssertTrue(result.conditions.contains("shipping"))
        XCTAssertTrue(result.conditions.contains("5.99"))
        XCTAssertNotNil(result.sourceExclusion)
        XCTAssertEqual(result.observedAt, retrievedAt.addingTimeInterval(-120))
    }

    func testHMartNeverFallsBackToMarketplaceSeller() async throws {
        var payload = try fixtureObject("hmart-catalog")
        var products = try XCTUnwrap(payload["products"] as? [[String: Any]])
        var items = try XCTUnwrap(products[0]["items"] as? [[String: Any]])
        var sellers = try XCTUnwrap(items[0]["sellers"] as? [[String: Any]])
        sellers[0]["sellerName"] = "Other Seller"
        items[0]["sellers"] = sellers
        products[0]["items"] = items
        payload["products"] = products
        FixtureURLProtocol.handler = { Self.response($0, json: payload) }
        do {
            _ = try await RetailClient(session: fixtureSession(), now: { self.retrievedAt })
                .fetch(request(store: .hmart, productID: "332:332", channel: .online))
            XCTFail("Expected first-party seller enforcement")
        } catch let error as RetailClientError {
            XCTAssertTrue(error.localizedDescription.contains("first-party"))
        }
    }

    func testMalformedCacheAgeIsRejected() async throws {
        let payload = try fixtureArray("wegmans-products")[0]
        FixtureURLProtocol.handler = { Self.response($0, json: payload, headers: ["Age": "private"] ) }
        do {
            _ = try await RetailClient(session: fixtureSession(), now: { self.retrievedAt })
                .fetch(request(store: .wegmans, productID: "94427", channel: .inStore))
            XCTFail("Expected invalid cache metadata")
        } catch let error as RetailClientError {
            XCTAssertTrue(error.localizedDescription.contains("cache metadata"))
        }
    }

    func testHTTPAndMalformedPayloadErrorsRemainSafeForDisplay() async throws {
        FixtureURLProtocol.handler = { Self.response($0, json: ["secret": "do not expose"], status: 503) }
        do {
            _ = try await RetailClient(session: fixtureSession()).fetch(request(store: .wegmans, productID: "94427", channel: .inStore))
            XCTFail("Expected an HTTP error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The retailer source is temporarily unavailable (HTTP 503).")
            XCTAssertFalse(error.localizedDescription.contains("secret"))
        }
    }

    private func request(store: StoreID, productID: String, channel: Channel) -> FetchRequest {
        let location = StoreLocation.defaults.first { $0.store == store }!
        let variant = ProductVariant(store: store, productID: productID, name: "Fixture", quantity: 1, unit: .each)
        return FetchRequest(variant: variant, location: location, channel: channel)
    }

    private func fixtureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func fixtureArray(_ name: String) throws -> [Any] {
        try JSONSerialization.jsonObject(with: fixtureData(name)) as! [Any]
    }

    private func fixtureObject(_ name: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: fixtureData(name)) as! [String: Any]
    }

    private func fixtureData(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try Data(contentsOf: url)
    }

    private static func response(_ request: URLRequest, json: Any, status: Int = 200, headers: [String: String] = [:]) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (response, try! JSONSerialization.data(withJSONObject: json))
    }
}

private final class FixtureURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
