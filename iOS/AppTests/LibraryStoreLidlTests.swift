import XCTest
import SwiftData
import StapleScoutKit
@testable import StapleScout

@MainActor final class LibraryStoreLidlTests: XCTestCase {
    override func tearDown() {
        LidlAppURLProtocol.handler = nil
        super.tearDown()
    }

    func testLidlSearchTrackReopenAndRefreshPreserveDatesAndUnknownStock() async throws {
        let start = Date().addingTimeInterval(-3600)
        let end = Date().addingTimeInterval(3600)
        var price = Decimal(string: "3.47")!
        var requests: [String] = []
        LidlAppURLProtocol.handler = { request in
            guard request.url?.host == "www.lidl.com" else { throw URLError(.badURL) }
            let path = request.url!.path
            requests.append(path)
            let product = Self.product(price: price, start: start, end: end)
            if path == "/q/api/search" {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "q" }?.value
                if query == "11675058" {
                    return Self.response(request, object: ["type": "redirect", "q": "11675058", "assortment": "US", "locale": "en_US", "redirectURL": "/p/whole-milk/p11675058"])
                }
                return Self.response(request, object: ["type": "search", "assortment": "US", "locale": "en_US", "items": [["type": "product", "resultClass": "product", "code": "11675058", "gridbox": ["country": "US", "data": product]]]])
            }
            guard path == "/p/whole-milk/p11675058" else { throw URLError(.badURL) }
            var entries: [Any] = []
            _ = Self.flatten(product, entries: &entries)
            let payload = String(decoding: try JSONSerialization.data(withJSONObject: entries), as: UTF8.self)
            let html = "<script id=\"__NUXT_DATA__\">" + payload + "</script>"
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!, Data(html.utf8))
        }
        let (store, container, session) = try library()
        let staple = Staple(name: "Milk", basis: .flOz)
        try store.saveStaple(staple)
        let results = await store.searchProducts(query: "milk")
        let lidl = try XCTUnwrap(results.first { $0.id == .lidl })
        XCTAssertEqual(lidl.location.code, "US01112")
        XCTAssertEqual(lidl.channel, .inStore)
        let candidate = try XCTUnwrap(lidl.candidates.first)
        XCTAssertEqual(candidate.price, price)
        XCTAssertNil(candidate.available)
        try store.trackProduct(candidate, location: lidl.location, channel: lidl.channel, stapleID: staple.id)
        let variant = try XCTUnwrap(store.state.variants.first)
        XCTAssertEqual(store.state.matches.first?.status, .pending)
        try store.review(stapleID: staple.id, variantID: variant.id, status: .approved)

        let reopened = try LibraryStore(context: ModelContext(container), client: RetailClient(session: session))
        let saved = try XCTUnwrap(reopened.state.observations.first)
        XCTAssertEqual(saved.source, .lidl)
        XCTAssertEqual(try XCTUnwrap(saved.validFrom).timeIntervalSince1970, start.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(saved.validUntil).timeIntervalSince1970, end.timeIntervalSince1970, accuracy: 1)
        XCTAssertNil(saved.available)
        XCTAssertNil(ComparisonEngine.compare(state: reopened.state).first?.winner)

        price = Decimal(string: "3.59")!
        await reopened.refresh()
        XCTAssertNil(reopened.failure)
        XCTAssertEqual(reopened.state.observations.count, 2)
        let refreshed = try XCTUnwrap(reopened.state.observations.last)
        XCTAssertEqual(refreshed.price, price)
        XCTAssertEqual(refreshed.validFrom, saved.validFrom)
        XCTAssertEqual(refreshed.validUntil, saved.validUntil)
        XCTAssertEqual(refreshed.observedAt, saved.observedAt)
        XCTAssertNil(refreshed.available)
        XCTAssertNotNil(refreshed.sourceExclusion)
        XCTAssertNil(ComparisonEngine.compare(state: reopened.state).first?.winner)
        XCTAssertEqual(requests.filter { $0 == "/q/api/search" }.count, 2)
        XCTAssertEqual(requests.filter { $0 == "/p/whole-milk/p11675058" }.count, 1)
        await reopened.refresh()
        XCTAssertEqual(requests.count, 3, "Durable daily refresh claim prevents repeated store requests")
    }

    func testLidlRefreshFailurePreservesTrackedEvidence() async throws {
        let start = Date().addingTimeInterval(-3600)
        let end = Date().addingTimeInterval(3600)
        LidlAppURLProtocol.handler = { request in
            guard request.url?.host == "www.lidl.com" else { throw URLError(.badURL) }
            return Self.response(request, object: ["type": "search", "assortment": "US", "locale": "en_US", "items": [["type": "product", "resultClass": "product", "code": "11675058", "gridbox": ["country": "US", "data": Self.product(price: 3, start: start, end: end)]]]])
        }
        let (store, _, _) = try library()
        let staple = Staple(name: "Milk", basis: .flOz)
        try store.saveStaple(staple)
        let results = await store.searchProducts(query: "milk")
        let result = try XCTUnwrap(results.first { $0.id == .lidl })
        try store.trackProduct(try XCTUnwrap(result.candidates.first), location: result.location, channel: result.channel, stapleID: staple.id)
        let before = store.state.observations
        LidlAppURLProtocol.handler = { Self.response($0, object: [:], status: 503) }
        await store.refresh()
        XCTAssertEqual(store.state.observations.map(\.id), before.map(\.id))
        XCTAssertEqual(store.state.observations.first?.retrievedAt, before.first?.retrievedAt)
        XCTAssertEqual(store.state.observations.first?.validUntil, before.first?.validUntil)
        XCTAssertNotNil(store.state.sourceRuns.first?.error)
        XCTAssertNil(store.state.sourceRuns.first?.succeededAt)
    }

    private func library() throws -> (LibraryStore, ModelContainer, URLSession) {
        let container = try ModelContainer(for: SavedLibrary.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LidlAppURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return (try LibraryStore(context: ModelContext(container), client: RetailClient(session: session), searchClient: RetailSearchClient(session: session)), container, session)
    }

    // Synthetic, API-shaped offline fixtures use relative dates so CI never contacts a retailer.
    private static func product(price: Decimal, start: Date, end: Date) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        return [
            "canonicalUrl": "/p/whole-milk/p11675058", "erpNumber": "11675058", "fullTitle": "Fixture whole milk",
            "itemId": 11675058, "productId": 11675058, "productType": "RETAIL_HEAD", "renderedTs": Int(start.timeIntervalSince1970),
            "regionsV2": [["regionName": "Region US1112", "regionPriceId": "9", "status": "ONLINE"]],
            "regionsPrices": ["9": ["currentPrice": ["currencyCode": "USD", "price": NSDecimalNumber(decimal: price), "packaging": ["text": "128 fl.oz."], "variantsHaveDifferentPrices": false, "startDate": formatter.string(from: start), "endDateExclusive": formatter.string(from: end)]]]
        ]
    }

    private static func flatten(_ value: Any, entries: inout [Any]) -> Int {
        let index = entries.count
        entries.append(NSNull())
        if let object = value as? [String: Any] {
            var refs: [String: Int] = [:]
            for (key, child) in object { refs[key] = flatten(child, entries: &entries) }
            entries[index] = refs
        } else if let array = value as? [Any] {
            entries[index] = array.map { flatten($0, entries: &entries) }
        } else { entries[index] = value }
        return index
    }

    private static func response(_ request: URLRequest, object: Any, status: Int = 200) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, try! JSONSerialization.data(withJSONObject: object))
    }
}

private final class LidlAppURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
