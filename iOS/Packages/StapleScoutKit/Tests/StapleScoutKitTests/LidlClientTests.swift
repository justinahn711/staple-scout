import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import StapleScoutKit

final class LidlClientTests: XCTestCase {
    private let retrievedAt = Date(timeIntervalSince1970: 1_792_123_200)

    override func tearDown() {
        LidlFixtureProtocol.handler = nil
        super.tearDown()
    }

    func testKeywordSearchUsesChantillyRegionalPriceInsteadOfDefaultPrice() async throws {
        let fixture = try fixtureData("lidl-search")
        var requestCount = 0
        LidlFixtureProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/q/api/search")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "q" }?.value, "whole milk")
            XCTAssertEqual(query.first { $0.name == "assortment" }?.value, "US")
            XCTAssertEqual(query.first { $0.name == "locale" }?.value, "en_US")
            XCTAssertEqual(query.first { $0.name == "version" }?.value, "v2.0.0")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/mindshift.search+json;version=2")
            XCTAssertLessThanOrEqual(request.timeoutInterval, 10)
            return Self.response(request, data: fixture)
        }
        let page = try await client().search(query: " whole milk ", location: chantilly(), channel: .inStore)
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(page.candidates.count, 2)
        let milk = try XCTUnwrap(page.candidates.first)
        XCTAssertEqual(milk.productID, "11675058")
        XCTAssertEqual(milk.productName, "whole milk")
        XCTAssertEqual(milk.price, Decimal(string: "3.47"))
        XCTAssertNotEqual(milk.price, Decimal(string: "3.48"), "The unregionalized top-level price must not be used")
        XCTAssertNotEqual(milk.price, Decimal(string: "8.88"), "A different store's Region US1469 price must not be used")
        XCTAssertEqual(milk.quantity, 128)
        XCTAssertEqual(milk.unit, .flOz)
        XCTAssertEqual(milk.packCount, 1)
        XCTAssertNil(milk.available)
        XCTAssertEqual(milk.observedAt, Date(timeIntervalSince1970: 1_792_042_498))
        XCTAssertEqual(milk.source, .lidl)
        XCTAssertTrue(milk.conditions.contains("offer region 1112"))
        XCTAssertTrue(milk.conditions.contains("2026-10-15T05:34:43Z"))
        XCTAssertTrue(milk.conditions.contains("2026-11-13T06:00:00Z"))
        XCTAssertTrue(milk.conditions.contains("Local shelf stock is not provided"))
        XCTAssertTrue(milk.sourceExclusion?.contains("stock is unknown") == true)
        XCTAssertEqual(milk.validFrom, date("2026-10-15T05:34:43.560Z"))
        XCTAssertEqual(milk.validUntil, date("2026-11-13T06:00:00Z"))
        XCTAssertEqual(milk.sourceURL, "https://www.lidl.com/p/whole-milk/p11675058")
    }

    func testKeywordSearchAcceptsCurrentRegionDictionaryAndSkipsMalformedSibling() async throws {
        var object = try fixtureObject("lidl-search")
        var items = object["items"] as! [[String: Any]]
        var gridbox = items[0]["gridbox"] as! [String: Any]
        var product = gridbox["data"] as! [String: Any]
        var groups = product["regionsPrices"] as! [String: Any]
        var group = groups["9"] as! [String: Any]
        var currentPrice = group["currentPrice"] as! [String: Any]
        currentPrice["endDateExclusive"] = "2026-11-13T06:00Z"
        group["currentPrice"] = currentPrice
        groups["9"] = group
        product["regionsPrices"] = groups
        let regions = product["regionsV2"] as! [[String: Any]]
        var regionDictionary = Dictionary(uniqueKeysWithValues: regions.map { region in
            let name = region["regionName"] as! String
            return (String(name.suffix(4)), region)
        })
        regionDictionary["8018"] = ["regionName": "Region US8018", "status": "OFFLINE"]
        product["regionsV2"] = regionDictionary
        gridbox["data"] = product
        items[0]["gridbox"] = gridbox
        object["items"] = [items[0], ["type": "product", "resultClass": "product", "code": "broken"]]
        LidlFixtureProtocol.handler = { Self.response($0, json: object) }

        let page = try await client().search(query: "milk", location: chantilly(), channel: .inStore)

        XCTAssertEqual(page.candidates.map(\.productID), ["11675058"])
        let price = try XCTUnwrap(try XCTUnwrap(page.candidates.first).price)
        XCTAssertEqual(NSDecimalNumber(decimal: price).doubleValue, 3.47, accuracy: 0.000_001)
        XCTAssertTrue(page.message?.contains("1 Lidl catalog results") == true)
    }

    func testDuplicateSelectedRegionWithoutPriceStillMakesTheContextAmbiguous() async throws {
        var object = try fixtureObject("lidl-search")
        var items = object["items"] as! [[String: Any]]
        var gridbox = items[0]["gridbox"] as! [String: Any]
        var product = gridbox["data"] as! [String: Any]
        var regions = product["regionsV2"] as! [[String: Any]]
        regions.append(["regionName": "Region US1112", "status": "ONLINE"])
        product["regionsV2"] = regions
        gridbox["data"] = product
        items[0]["gridbox"] = gridbox
        object["items"] = [items[0]]
        LidlFixtureProtocol.handler = { Self.response($0, json: object) }

        let page = try await client().search(query: "milk", location: chantilly(), channel: .inStore)
        XCTAssertTrue(page.candidates.isEmpty)
        XCTAssertNotNil(page.message)
    }

    func testExactFetchResolvesOfficialRedirectThenParsesPublicProductPayload() async throws {
        var raw = try fixtureArray("lidl-product-page")
        let missingPriceRegion = raw.count
        raw.append(["regionName": missingPriceRegion + 1, "status": 14])
        raw.append("Region US8018")
        raw[6] = ["1469": 9, "1112": 10, "8018": missingPriceRegion]
        let nuxt = String(decoding: try JSONSerialization.data(withJSONObject: raw), as: UTF8.self)
        var requests: [URLRequest] = []
        LidlFixtureProtocol.handler = { request in
            requests.append(request)
            if request.url?.path == "/q/api/search" {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertEqual(query.first { $0.name == "q" }?.value, "11675058")
                return Self.response(request, json: [
                    "type": "redirect", "q": "11675058", "locale": "en_US", "assortment": "US",
                    "redirectURL": "/p/whole-milk/p11675058"
                ])
            }
            XCTAssertEqual(request.url?.path, "/p/whole-milk/p11675058")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/html")
            let html = #"<html><script type="application/json" data-nuxt-data="pdp-view" id="__NUXT_DATA__">"# + nuxt + "</script></html>"
            return Self.response(request, data: Data(html.utf8), contentType: "text/html")
        }
        let variant = ProductVariant(store: .lidl, productID: "11675058", name: "milk", quantity: 128, unit: .flOz)
        let result = try await client().fetch(FetchRequest(variant: variant, location: chantilly(), channel: .inStore))
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(result.productID, "11675058")
        XCTAssertEqual(result.price, Decimal(string: "3.47"))
        XCTAssertNotEqual(result.price, Decimal(string: "8.88"), "A different store's Region US1469 price must not be used")
        XCTAssertEqual(result.quantity, 128)
        XCTAssertNil(result.available)
        XCTAssertEqual(result.validFrom, date("2026-10-15T05:34:43.560Z"))
        XCTAssertEqual(result.validUntil, date("2026-11-13T06:00:00Z"))
    }

    func testWrongStoreChannelOrInvalidIdentityMakesNoRequest() async throws {
        LidlFixtureProtocol.handler = { _ in XCTFail("No network request permitted"); throw URLError(.badURL) }
        let source = client()
        let wrongStore = StoreLocation(store: .lidl, name: "Different Lidl", code: "US01469")
        for (location, channel) in [(chantilly(), Channel.online), (wrongStore, Channel.inStore)] {
            do { _ = try await source.search(query: "milk", location: location, channel: channel); XCTFail("Expected unsupported context") }
            catch { XCTAssertNotNil(error as? RetailClientError) }
        }
        let variant = ProductVariant(store: .lidl, productID: "milk", name: "milk", quantity: 1, unit: .each)
        do { _ = try await source.fetch(FetchRequest(variant: variant, location: chantilly(), channel: .inStore)); XCTFail("Expected invalid identity") }
        catch { XCTAssertNotNil(error as? RetailClientError) }
    }

    func testMissingOfferRegionDoesNotFallBackToAnotherRegionOrDefaultPrice() async throws {
        var object = try fixtureObject("lidl-search")
        var items = object["items"] as! [[String: Any]]
        var gridbox = items[0]["gridbox"] as! [String: Any]
        var product = gridbox["data"] as! [String: Any]
        product["regionsV2"] = [["regionName": "Region US1469", "regionPriceId": "10", "status": "ONLINE"]]
        gridbox["data"] = product; items[0]["gridbox"] = gridbox; object["items"] = [items[0]]
        LidlFixtureProtocol.handler = { Self.response($0, json: object) }
        let page = try await client().search(query: "milk", location: chantilly(), channel: .inStore)
        XCTAssertTrue(page.candidates.isEmpty)
        XCTAssertTrue(page.message?.contains("lacked a verifiable current Chantilly price") == true)
    }

    func testExpiredRegionalPriceIsNotRetimedToRetrieval() async throws {
        var object = try fixtureObject("lidl-search")
        var items = object["items"] as! [[String: Any]]
        var gridbox = items[0]["gridbox"] as! [String: Any]
        var product = gridbox["data"] as! [String: Any]
        var groups = product["regionsPrices"] as! [String: Any]
        var group = groups["9"] as! [String: Any]
        var price = group["currentPrice"] as! [String: Any]
        price["endDateExclusive"] = "2026-10-16T00:00:00Z"
        group["currentPrice"] = price; groups["9"] = group; product["regionsPrices"] = groups
        gridbox["data"] = product; items[0]["gridbox"] = gridbox; object["items"] = [items[0]]
        LidlFixtureProtocol.handler = { Self.response($0, json: object) }
        let page = try await client().search(query: "milk", location: chantilly(), channel: .inStore)
        XCTAssertTrue(page.candidates.isEmpty)
        XCTAssertNotNil(page.message)
    }

    func testExactRedirectCannotChangeProductIdentity() async throws {
        LidlFixtureProtocol.handler = { request in
            Self.response(request, json: [
                "type": "redirect", "q": "11675058", "locale": "en_US", "assortment": "US",
                "redirectURL": "/p/other/p99999999"
            ])
        }
        let variant = ProductVariant(store: .lidl, productID: "11675058", name: "milk", quantity: 128, unit: .flOz)
        do { _ = try await client().fetch(FetchRequest(variant: variant, location: chantilly(), channel: .inStore)); XCTFail("Expected identity rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("different identity")) }
    }

    func testRepeatedExactFetchRequestsFreshSourceAndUsesChangedPriceAndRetrievalTime() async throws {
        let clock = LidlTestClock(retrievedAt)
        var requestCount = 0
        var productPageCount = 0
        LidlFixtureProtocol.handler = { request in
            requestCount += 1
            if request.url?.path == "/q/api/search" {
                return Self.response(request, json: [
                    "type": "redirect", "q": "11675058", "locale": "en_US", "assortment": "US",
                    "redirectURL": "/p/whole-milk/p11675058"
                ])
            }
            productPageCount += 1
            var raw = try self.fixtureArray("lidl-product-page")
            if productPageCount == 2 { raw[22] = 4.01 }
            return Self.response(request, data: try Self.productHTML(raw), contentType: "text/html")
        }
        let source = LidlClient(session: session(), now: { clock.value })
        let request = FetchRequest(
            variant: ProductVariant(store: .lidl, productID: "11675058", name: "milk", quantity: 128, unit: .flOz),
            location: chantilly(),
            channel: .inStore
        )

        let first = try await source.fetch(request)
        clock.value = retrievedAt.addingTimeInterval(60)
        let second = try await source.fetch(request)

        XCTAssertEqual(requestCount, 4)
        XCTAssertEqual(productPageCount, 2)
        XCTAssertEqual(first.price, Decimal(string: "3.47"))
        XCTAssertEqual(second.price, Decimal(string: "4.01"))
        XCTAssertEqual(first.retrievedAt, retrievedAt)
        XCTAssertEqual(second.retrievedAt, retrievedAt.addingTimeInterval(60))
    }

    func testVariableBillingPackageTextIsNotParsedAsFixedQuantity() async throws {
        var object = try fixtureObject("lidl-search")
        var items = object["items"] as! [[String: Any]]
        var gridbox = items[0]["gridbox"] as! [String: Any]
        var product = gridbox["data"] as! [String: Any]
        var groups = product["regionsPrices"] as! [String: Any]
        var group = groups["9"] as! [String: Any]
        var price = group["currentPrice"] as! [String: Any]
        price["packaging"] = ["text": "16 oz per lb"]
        group["currentPrice"] = price; groups["9"] = group; product["regionsPrices"] = groups
        gridbox["data"] = product; items[0]["gridbox"] = gridbox; object["items"] = [items[0]]
        LidlFixtureProtocol.handler = { Self.response($0, json: object) }

        let page = try await client().search(query: "chicken", location: chantilly(), channel: .inStore)
        let result = try XCTUnwrap(page.candidates.first)
        XCTAssertNil(result.quantity)
        XCTAssertNil(result.unit)
        XCTAssertEqual(result.quantityKind, .variable)
        XCTAssertTrue(result.sourceExclusion?.contains("package size is unknown") == true)
    }

    func testNumericVariantFlagInProductPayloadIsRejected() async throws {
        var raw = try fixtureArray("lidl-product-page")
        raw[24] = 0
        LidlFixtureProtocol.handler = { request in
            if request.url?.path == "/q/api/search" {
                return Self.response(request, json: [
                    "type": "redirect", "q": "11675058", "locale": "en_US", "assortment": "US",
                    "redirectURL": "/p/whole-milk/p11675058"
                ])
            }
            return Self.response(request, data: try Self.productHTML(raw), contentType: "text/html")
        }
        let request = FetchRequest(
            variant: ProductVariant(store: .lidl, productID: "11675058", name: "milk", quantity: 128, unit: .flOz),
            location: chantilly(),
            channel: .inStore
        )
        do { _ = try await client().fetch(request); XCTFail("Expected non-boolean variant flag rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("unreadable regional price data")) }
    }

    func testPriceWithoutExplicitExclusiveEndIsRejected() async throws {
        var object = try fixtureObject("lidl-search")
        var items = object["items"] as! [[String: Any]]
        var gridbox = items[0]["gridbox"] as! [String: Any]
        var product = gridbox["data"] as! [String: Any]
        var groups = product["regionsPrices"] as! [String: Any]
        var group = groups["9"] as! [String: Any]
        var price = group["currentPrice"] as! [String: Any]
        price.removeValue(forKey: "endDateExclusive")
        group["currentPrice"] = price; groups["9"] = group; product["regionsPrices"] = groups
        gridbox["data"] = product; items[0]["gridbox"] = gridbox; object["items"] = [items[0]]
        LidlFixtureProtocol.handler = { Self.response($0, json: object) }

        let page = try await client().search(query: "milk", location: chantilly(), channel: .inStore)
        XCTAssertTrue(page.candidates.isEmpty)
        XCTAssertNotNil(page.message)
    }

    private func client() -> LidlClient { LidlClient(session: session(), now: { self.retrievedAt }) }
    private func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = text.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter.date(from: text)
    }
    private func chantilly() -> StoreLocation { StoreLocation.defaults.first { $0.store == .lidl }! }
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LidlFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }
    private func fixtureData(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        return try Data(contentsOf: url)
    }
    private func fixtureObject(_ name: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: fixtureData(name)) as! [String: Any]
    }
    private func fixtureArray(_ name: String) throws -> [Any] {
        try JSONSerialization.jsonObject(with: fixtureData(name)) as! [Any]
    }
    private static func productHTML(_ raw: [Any]) throws -> Data {
        let nuxt = String(decoding: try JSONSerialization.data(withJSONObject: raw), as: UTF8.self)
        return Data((#"<html><script type="application/json" data-nuxt-data="pdp-view" id="__NUXT_DATA__">"# + nuxt + "</script></html>").utf8)
    }
    private static func response(_ request: URLRequest, json: Any, status: Int = 200) -> (HTTPURLResponse, Data) {
        response(request, data: try! JSONSerialization.data(withJSONObject: json), status: status)
    }
    private static func response(_ request: URLRequest, data: Data, status: Int = 200, contentType: String = "application/json") -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType])!, data)
    }
}

private final class LidlTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Date
    init(_ value: Date) { storedValue = value }
    var value: Date {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

private final class LidlFixtureProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
