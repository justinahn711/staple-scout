import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import StapleScoutKit

final class RetailSearchClientTests: XCTestCase {
    override func tearDown() { SearchFixtureProtocol.handler = nil; super.tearDown() }

    func testWegmansKeywordSearchResolvesExactShelfPricesAndCachesQuery() async throws {
        var requests: [URLRequest] = []
        let product = try fixture("wegmans-products")[0]
        SearchFixtureProtocol.handler = { request in
            requests.append(request)
            switch request.url!.path {
            case "/": return Self.text(request, #"<link href="https://PUBLICAPP-dsn.algolia.net"><script src="/_next/static/chunks/store.js"></script>"#)
            case "/_next/static/chunks/store.js": return Self.text(request, "let app=\"PUBLICAPP\",key=\"" + String(repeating: "a", count: 32) + "\";")
            case "/1/indexes/products_v2/query":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Algolia-Application-Id"), "PUBLICAPP")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Algolia-API-Key"), String(repeating: "a", count: 32))
                let body = try JSONSerialization.jsonObject(with: Self.body(request)) as! [String: Any]
                XCTAssertEqual(body["query"] as? String, "milk")
                XCTAssertEqual(body["hitsPerPage"] as? Int, 5)
                XCTAssertEqual(body["filters"] as? String, "soldAtStores:133 AND fulfillmentInStore:133 AND excludeFromWeb:false")
                return Self.json(request, ["hits": [["objectID": "94427", "productID": "94427", "soldAtStores": [133], "fulfillmentInStore": [133]]]])
            case "/api/products/133/94427": return Self.json(request, product)
            default: throw URLError(.badURL)
            }
        }
        let client = RetailSearchClient(session: session())
        let first = try await client.search(query: "milk", location: location(.wegmans), channel: .inStore)
        let second = try await client.search(query: " MILK ", location: location(.wegmans), channel: .inStore)
        XCTAssertEqual(first.candidates.map(\.productID), ["94427"])
        XCTAssertEqual(first.candidates.first?.price, Decimal(string: "3.39"))
        XCTAssertEqual(first.candidates.first?.quantity, 128)
        XCTAssertEqual(first.candidates.first?.source, .wegmans)
        XCTAssertEqual(second.candidates.map(\.productID), first.candidates.map(\.productID))
        XCTAssertEqual(requests.count, 4)
    }

    func testWegmansRejectsSearchHitsForWrongLocationBeforePriceFetch() async throws {
        SearchFixtureProtocol.handler = { request in
            if request.url!.path == "/" { return Self.text(request, #"<link href="https://PUBLICAPP-dsn.algolia.net"><script src="/_next/static/chunks/search.js"></script>"#) }
            if request.url!.path.hasSuffix(".js") { return Self.text(request, "let app=\"PUBLICAPP\",key=\"" + String(repeating: "a", count: 32) + "\";") }
            XCTAssertEqual(request.url!.path, "/1/indexes/products_v2/query")
            return Self.json(request, ["hits": [["objectID": "94427", "productID": "94427", "soldAtStores": [24], "fulfillmentInStore": [24]]]])
        }
        do { _ = try await RetailSearchClient(session: session()).search(query: "milk", location: location(.wegmans), channel: .inStore); XCTFail("Expected wrong-store rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("unverified store")) }
    }

    func testHMartKeywordIsEncodedAndResolvesCompositeSKUOnlineOnly() async throws {
        let products = try fixture("hmart-catalog")
        let product = products[0] as! [String: Any]
        let productID = product["productId"] as! String
        let item = (product["items"] as! [[String: Any]])[0]
        let itemID = item["itemId"] as! String
        var count = 0
        SearchFixtureProtocol.handler = { request in
            count += 1
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            if count == 1 {
                XCTAssertEqual(query.first { $0.name == "ft" }?.value, "rice & tofu")
                XCTAssertNil(query.first { $0.name == "fq" })
                XCTAssertEqual(query.first { $0.name == "_to" }?.value, "4")
            } else { XCTAssertEqual(query.first { $0.name == "fq" }?.value, "productId:\(productID)") }
            return Self.json(request, [product])
        }
        let page = try await RetailSearchClient(session: session()).search(query: "rice & tofu", location: location(.hmart), channel: .online)
        XCTAssertEqual(page.candidates.first?.productID, "\(productID):\(itemID)")
        XCTAssertEqual(page.candidates.first?.source, .hmart)
        XCTAssertNotNil(page.candidates.first?.sourceExclusion)
        XCTAssertEqual(count, 2)
    }

    func testUnsupportedStoreOrChannelMakesNoRequest() async throws {
        SearchFixtureProtocol.handler = { _ in XCTFail("No network request permitted"); throw URLError(.badURL) }
        let client = RetailSearchClient(session: session())
        for store in [StoreID.hmart, .walmart, .target, .lidl] {
            do { _ = try await client.search(query: "milk", location: location(store), channel: .inStore); XCTFail("Expected unsupported source") }
            catch { XCTAssertNotNil(error as? RetailClientError) }
        }
    }

    func testInvalidQueryMakesNoRequest() async throws {
        SearchFixtureProtocol.handler = { _ in XCTFail("No network request permitted"); throw URLError(.badURL) }
        for query in [" ", "x", "milk\nsecret", String(repeating: "x", count: 101)] {
            do { _ = try await RetailSearchClient(session: session()).search(query: query, location: location(.wegmans), channel: .inStore); XCTFail("Expected invalid query") }
            catch { XCTAssertNotNil(error as? RetailClientError) }
        }
    }

    func testFailedExactPriceIsAnExplicitGapRatherThanAnIndexPrice() async throws {
        let product = try fixture("hmart-catalog")[0]
        var count = 0
        SearchFixtureProtocol.handler = { request in
            count += 1
            return count == 1 ? Self.json(request, [product]) : Self.json(request, ["error": "unavailable"], status: 503)
        }
        let page = try await RetailSearchClient(session: session()).search(query: "rice", location: location(.hmart), channel: .online)
        XCTAssertTrue(page.candidates.isEmpty)
        XCTAssertTrue(page.message?.contains("could not be checked") == true)
    }

    func testFailedExactPriceCanBeRetriedExplicitlyOnSameDay() async throws {
        let product = try fixture("hmart-catalog")[0]
        var priceAttempts = 0
        SearchFixtureProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            if query.contains(where: { $0.name == "ft" }) { return Self.json(request, [product]) }
            priceAttempts += 1
            return priceAttempts == 1 ? Self.json(request, ["error": "unavailable"], status: 503) : Self.json(request, [product])
        }
        let client = RetailSearchClient(session: session())
        let failed = try await client.search(query: "rice", location: location(.hmart), channel: .online)
        XCTAssertTrue(failed.candidates.isEmpty)
        let retried = try await client.search(query: "rice", location: location(.hmart), channel: .online)
        XCTAssertEqual(retried.candidates.count, 1)
        XCTAssertNil(retried.message)
        XCTAssertEqual(priceAttempts, 2)
    }

    func testChangedPublicConfigurationFailsWithoutGuessingKeys() async throws {
        SearchFixtureProtocol.handler = { request in
            XCTAssertEqual(request.url!.host, "www.wegmans.com")
            XCTAssertEqual(request.url!.path, "/")
            return Self.text(request, "<html>Public search configuration is absent</html>")
        }
        do { _ = try await RetailSearchClient(session: session()).search(query: "milk", location: location(.wegmans), channel: .inStore); XCTFail("Expected configuration gap") }
        catch { XCTAssertTrue(error.localizedDescription.contains("configuration changed")) }
    }

    private func location(_ store: StoreID) -> StoreLocation { StoreLocation.defaults.first { $0.store == store }! }
    private func fixture(_ name: String) throws -> [Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name).json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        if let array = object as? [Any] { return array }
        return try XCTUnwrap((object as? [String: Any])?["products"] as? [Any])
    }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SearchFixtureProtocol.self]
        return URLSession(configuration: config)
    }
    private static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count)) }
        return data
    }
    private static func text(_ request: URLRequest, _ text: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(text.utf8))
    }
    private static func json(_ request: URLRequest, _ object: Any, status: Int = 200) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, try! JSONSerialization.data(withJSONObject: object))
    }
}

private final class SearchFixtureProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
