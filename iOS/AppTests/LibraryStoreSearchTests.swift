import XCTest
import SwiftData
import StapleScoutKit
@testable import StapleScout

@MainActor final class LibraryStoreSearchTests: XCTestCase {
    override func tearDown() {
        StoreSearchURLProtocol.handler = nil
        super.tearDown()
    }

    func testKeywordSearchReturnsEveryStoreAndKeepsPartialFailureReadOnly() async throws {
        installSearchFixtures()
        let (store, container) = try library()
        let staple = Staple(name: "Milk", basis: .flOz)
        try store.saveStaple(staple)

        let results = await store.searchProducts(query: "milk")

        XCTAssertEqual(results.map(\.id), StoreID.allCases)
        XCTAssertEqual(results.count, 5)
        let wegmans = try XCTUnwrap(results.first { $0.id == .wegmans })
        XCTAssertEqual(wegmans.location.code, "133")
        XCTAssertEqual(wegmans.channel, .inStore)
        XCTAssertEqual(wegmans.candidates.map(\.productID), ["94427"])
        XCTAssertEqual(wegmans.candidates.first?.source, .wegmans)
        XCTAssertEqual(wegmans.candidates.first?.price, Decimal(string: "3.39"))

        let hmart = try XCTUnwrap(results.first { $0.id == .hmart })
        XCTAssertEqual(hmart.channel, .online)
        XCTAssertTrue(hmart.candidates.isEmpty)
        XCTAssertTrue(hmart.message?.contains("temporarily unavailable") == true)
        for retailer in [StoreID.walmart, .target, .lidl] {
            let unsupported = try XCTUnwrap(results.first { $0.id == retailer })
            XCTAssertTrue(unsupported.candidates.isEmpty)
            XCTAssertNotNil(unsupported.message)
        }

        XCTAssertTrue(store.state.variants.isEmpty)
        XCTAssertTrue(store.state.matches.isEmpty)
        XCTAssertTrue(store.state.observations.isEmpty)
        let reopened = try makeStore(container: container)
        XCTAssertEqual(reopened.state.staples.map(\.id), [staple.id])
        XCTAssertTrue(reopened.state.variants.isEmpty)
        XCTAssertTrue(reopened.state.observations.isEmpty)
    }

    func testTrackSavesAutomaticEvidencePendingAndDuplicatePreservesApproval() async throws {
        installSearchFixtures()
        let (store, container) = try library()
        let staple = Staple(name: "Milk", basis: .flOz)
        try store.saveStaple(staple)
        let result = try await wegmansResult(from: store)
        let candidate = try XCTUnwrap(result.candidates.first)

        try store.trackProduct(candidate, location: result.location, channel: result.channel, stapleID: staple.id)

        let variant = try XCTUnwrap(store.state.variants.first)
        XCTAssertEqual(variant.productID, "94427")
        XCTAssertEqual(variant.barcode, "00077890944271")
        XCTAssertEqual(variant.quantity, 128)
        XCTAssertEqual(variant.unit, .flOz)
        XCTAssertEqual(store.state.matches.first?.status, .pending)
        let observation = try XCTUnwrap(store.state.observations.first)
        XCTAssertEqual(observation.price, Decimal(string: "3.39"))
        XCTAssertEqual(observation.source, .wegmans)
        XCTAssertEqual(observation.locationID, result.location.id)
        XCTAssertEqual(observation.channel, .inStore)
        XCTAssertNotNil(observation.retrievedAt)
        XCTAssertNil(ComparisonEngine.compare(state: store.state).first?.winner)

        try store.review(stapleID: staple.id, variantID: variant.id, status: .approved)
        XCTAssertEqual(ComparisonEngine.compare(state: store.state).first?.winner?.variant.id, variant.id)
        try store.trackProduct(candidate, location: result.location, channel: result.channel, stapleID: staple.id)
        XCTAssertEqual(store.state.matches.count, 1)
        XCTAssertEqual(store.state.matches.first?.status, .approved)
        XCTAssertEqual(store.state.observations.count, 1)

        let reopened = try makeStore(container: container)
        XCTAssertEqual(reopened.state.variants.count, 1)
        XCTAssertEqual(reopened.state.variants.first?.productID, "94427")
        XCTAssertEqual(reopened.state.matches.first?.status, .approved)
        XCTAssertEqual(reopened.state.observations.count, 1)
        XCTAssertEqual(ComparisonEngine.compare(state: reopened.state).first?.winner?.variant.id, variant.id)
    }

    func testChangingPreferredLocationRejectsStaleSearchBeforeWriting() async throws {
        installSearchFixtures()
        let (store, _) = try library()
        let staple = Staple(name: "Milk", basis: .flOz)
        try store.saveStaple(staple)
        let result = try await wegmansResult(from: store)
        let candidate = try XCTUnwrap(result.candidates.first)

        try store.selectLocation(store: .wegmans, name: "Alternate Wegmans #133", code: "133")

        XCTAssertThrowsError(try store.trackProduct(candidate, location: result.location, channel: result.channel, stapleID: staple.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("no longer current"))
        }
        XCTAssertTrue(store.state.variants.isEmpty)
        XCTAssertTrue(store.state.matches.isEmpty)
        XCTAssertTrue(store.state.observations.isEmpty)
    }

    func testReturningPackageAfterRejectedChangeRequiresExplicitReapproval() async throws {
        var packageA = wegmansProductFixture()
        packageA["productName"] = "Fixture milk package A"
        packageA["upc"] = ["00000000000001"]
        var packageB = packageA
        packageB["productName"] = "Fixture milk package B"
        packageB["upc"] = ["00000000000002"]
        var currentProduct = packageA
        installSearchFixtures(product: { currentProduct })

        let (store, _) = try library()
        let staple = Staple(name: "Milk", basis: .flOz)
        try store.saveStaple(staple)

        let firstResult = try await wegmansResult(from: store, query: "whole milk")
        try store.trackProduct(
            try XCTUnwrap(firstResult.candidates.first),
            location: firstResult.location,
            channel: firstResult.channel,
            stapleID: staple.id
        )
        let packageAID = try XCTUnwrap(store.state.variants.first { $0.barcode == "00000000000001" }?.id)
        try store.review(stapleID: staple.id, variantID: packageAID, status: .approved)
        XCTAssertEqual(ComparisonEngine.compare(state: store.state).first?.winner?.variant.id, packageAID)

        currentProduct = packageB
        let changedResult = try await wegmansResult(from: store, query: "changed milk")
        try store.trackProduct(
            try XCTUnwrap(changedResult.candidates.first),
            location: changedResult.location,
            channel: changedResult.channel,
            stapleID: staple.id
        )
        let packageBID = try XCTUnwrap(store.state.variants.first { $0.barcode == "00000000000002" }?.id)
        XCTAssertNotEqual(packageAID, packageBID)
        XCTAssertEqual(store.state.matches.first { $0.variantID == packageBID }?.status, .pending)
        try store.review(stapleID: staple.id, variantID: packageBID, status: .rejected)

        currentProduct = packageA
        let returnedResult = try await wegmansResult(from: store, query: "original milk")
        try store.trackProduct(
            try XCTUnwrap(returnedResult.candidates.first),
            location: returnedResult.location,
            channel: returnedResult.channel,
            stapleID: staple.id
        )

        XCTAssertEqual(store.state.matches.first { $0.variantID == packageAID }?.status, .pending)
        XCTAssertEqual(store.state.matches.first { $0.variantID == packageBID }?.status, .rejected)
        XCTAssertNil(ComparisonEngine.compare(state: store.state).first?.winner)

        try store.review(stapleID: staple.id, variantID: packageAID, status: .approved)
        XCTAssertEqual(ComparisonEngine.compare(state: store.state).first?.winner?.variant.id, packageAID)
    }

    private func wegmansResult(from store: LibraryStore, query: String = "milk") async throws -> StoreSearchResult {
        let results = await store.searchProducts(query: query)
        return try XCTUnwrap(results.first { $0.id == .wegmans })
    }

    private func library() throws -> (LibraryStore, ModelContainer) {
        let container = try ModelContainer(
            for: SavedLibrary.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return (try makeStore(container: container), container)
    }

    private func makeStore(container: ModelContainer) throws -> LibraryStore {
        let session = fixtureSession()
        return try LibraryStore(
            context: ModelContext(container),
            client: RetailClient(session: session),
            searchClient: RetailSearchClient(session: session)
        )
    }

    private func fixtureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StoreSearchURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func installSearchFixtures() {
        let product = wegmansProductFixture()
        installSearchFixtures(product: { product })
    }

    private func installSearchFixtures(product: @escaping () -> [String: Any]) {
        StoreSearchURLProtocol.handler = { request in
            switch (request.url?.host, request.url?.path) {
            case ("www.wegmans.com", "/"):
                return Self.text(
                    request,
                    #"<link href="https://PUBLICAPP-dsn.algolia.net"><script src="/_next/static/chunks/store.js"></script>"#
                )
            case ("www.wegmans.com", "/_next/static/chunks/store.js"):
                return Self.text(request, "let app=\"PUBLICAPP\",key=\"" + String(repeating: "a", count: 32) + "\";")
            case ("publicapp-dsn.algolia.net", "/1/indexes/products_v2/query"):
                return Self.json(request, [
                    "hits": [[
                        "objectID": "94427", "productID": "94427",
                        "soldAtStores": [133], "fulfillmentInStore": [133]
                    ]]
                ])
            case ("www.wegmans.com", "/api/products/133/94427"):
                return Self.json(request, product())
            case ("www.hmart.com", "/api/catalog_system/pub/products/search/"), ("www.hmart.com", "/api/catalog_system/pub/products/search"):
                return Self.json(request, ["error": "fixture outage"], status: 503)
            default:
                throw URLError(.badURL)
            }
        }
    }

    private func wegmansProductFixture() -> [String: Any] {
        [
            "objectId": "133-94427",
            "storeNumber": "133",
            "skuId": "94427",
            "productID": "94427",
            "productId": "94427",
            "productName": "Fixture milk",
            "packSize": "1 gallon",
            "upc": ["00077890944271"],
            "isSoldByWeight": false,
            "isSoldAtStore": true,
            "isAvailable": true,
            "soldByVendor": NSNull(),
            "bottleDeposit": 0,
            "price_inStore": [
                "unitPrice": "$3.39/gallon",
                "amount": NSDecimalNumber(string: "3.39"),
                "channelKey": "133-Instore",
                "fulfillmentPrice": NSDecimalNumber(string: "3.39")
            ],
            "price_inStoreLoyalty": [:],
            "loyaltyInstoreDiscount": NSNull(),
            "digitalCouponsOfferIds": [],
            "digitalCouponsOffers": [],
            "discountType": NSNull()
        ]
    }

    private static func text(_ request: URLRequest, _ text: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(text.utf8))
    }

    private static func json(_ request: URLRequest, _ object: Any, status: Int = 200) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (response, try! JSONSerialization.data(withJSONObject: object))
    }
}

private final class StoreSearchURLProtocol: URLProtocol {
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
