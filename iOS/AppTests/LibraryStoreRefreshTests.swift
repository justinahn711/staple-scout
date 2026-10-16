import XCTest
import SwiftData
import StapleScoutKit
@testable import StapleScout

@MainActor final class LibraryStoreRefreshTests: XCTestCase {
    override func tearDown() {
        RefreshURLProtocol.handler = nil
        super.tearDown()
    }

    func testSuccessfulRefreshClaimsDayAndReopenDoesNotReplay() async throws {
        var calls = 0
        RefreshURLProtocol.handler = { request in
            calls += 1
            return Self.response(request, json: Self.wegmansProduct())
        }
        let session = fixtureSession()
        let (store, container) = try library(session: session)
        _ = try trackedProduct(in: store)

        await store.refresh()
        XCTAssertEqual(calls, 1)
        XCTAssertNotNil(store.state.lastRefreshDay)
        XCTAssertEqual(store.state.sourceRuns.count, 1)
        XCTAssertNotNil(store.state.sourceRuns.first?.succeededAt)
        XCTAssertNotNil(store.state.sourceRuns.first?.finishedAt)
        XCTAssertEqual(store.state.observations.filter { $0.source == .wegmans }.count, 1)

        let reopened = try LibraryStore(context: ModelContext(container), client: RetailClient(session: session))
        await reopened.refresh()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(reopened.state.sourceRuns.count, 1)
        XCTAssertTrue(reopened.failure?.contains("already been attempted") == true)
    }

    func testSourceFailurePreservesObservationsAndPersistsAttemptClaim() async throws {
        var calls = 0
        RefreshURLProtocol.handler = { request in
            calls += 1
            return Self.response(request, json: [:], status: 503)
        }
        let session = fixtureSession()
        let (store, container) = try library(session: session)
        _ = try trackedProduct(in: store)
        let before = store.state.observations

        await store.refresh()

        XCTAssertEqual(calls, 1)
        XCTAssertEqual(store.state.observations.map(\.id), before.map(\.id))
        XCTAssertNotNil(store.state.lastRefreshDay)
        XCTAssertEqual(store.state.sourceRuns.count, 1)
        XCTAssertNotNil(store.state.sourceRuns.first?.error)
        XCTAssertNil(store.state.sourceRuns.first?.succeededAt)
        XCTAssertNotNil(store.state.sourceRuns.first?.finishedAt)

        let reopened = try LibraryStore(context: ModelContext(container), client: RetailClient(session: session))
        XCTAssertEqual(reopened.state.observations.map(\.id), before.map(\.id))
        await reopened.refresh()
        XCTAssertEqual(calls, 1)
    }

    func testChangedProductAlwaysReturnsToPendingAndOldApprovalCannotWin() async throws {
        RefreshURLProtocol.handler = { request in
            Self.response(request, json: Self.wegmansProduct(name: "Returned package", barcode: "00000000000022", price: 3))
        }
        let (store, _) = try library(session: fixtureSession())
        let staple = Staple(name: "Milk", basis: .flOz)
        try store.saveStaple(staple)

        let returned = ProductVariant(store: .wegmans, productID: "94427", barcode: "00000000000022", name: "Returned package", quantity: 128, unit: .flOz)
        try store.recordPrice(stapleID: staple.id, variant: returned, reuseID: nil, channel: .inStore, price: 5, available: true, observedAt: Date().addingTimeInterval(-120), conditions: "", sourceURL: nil, approveNew: true)
        let returnedID = try XCTUnwrap(store.state.variants.last?.id)
        let current = ProductVariant(store: .wegmans, productID: "94427", barcode: "00000000000011", name: "Current package", quantity: 128, unit: .flOz)
        try store.recordPrice(stapleID: staple.id, variant: current, reuseID: nil, channel: .inStore, price: 4, available: true, observedAt: Date().addingTimeInterval(-60), conditions: "", sourceURL: nil, approveNew: true)
        let currentID = try XCTUnwrap(store.state.variants.last?.id)

        await store.refresh()

        XCTAssertEqual(store.state.matches.first { $0.stapleID == staple.id && $0.variantID == returnedID }?.status, .pending)
        let oldLatest = store.state.observations
            .filter { $0.stapleID == staple.id && $0.variantID == currentID }
            .max { ($0.observedAt, $0.sequence) < ($1.observedAt, $1.sequence) }
        XCTAssertNotNil(oldLatest?.sourceExclusion)
        XCTAssertNil(ComparisonEngine.compare(state: store.state, asOf: Date()).first?.winner)
    }

    func testUnknownPackageStockAndPriceSuppressPriorApprovedOffer() async throws {
        var product = Self.wegmansProduct(packSize: "family size")
        product.removeValue(forKey: "price_inStore")
        product.removeValue(forKey: "isAvailable")
        RefreshURLProtocol.handler = { request in Self.response(request, json: product) }
        let (store, _) = try library(session: fixtureSession())
        let staple = try trackedProduct(in: store)

        XCTAssertNotNil(ComparisonEngine.compare(state: store.state, asOf: Date()).first?.winner)
        await store.refresh()

        let imported = try XCTUnwrap(store.state.observations.last)
        XCTAssertEqual(imported.stapleID, staple.id)
        XCTAssertNil(imported.price)
        XCTAssertNil(imported.available)
        XCTAssertEqual(imported.sourceExclusion, "Source package size is unknown.")
        XCTAssertNil(ComparisonEngine.compare(state: store.state, asOf: Date()).first?.winner)
    }

    func testDuplicateTrackedProductFetchesOnceAndUpdatesEveryStaple() async throws {
        var calls = 0
        RefreshURLProtocol.handler = { request in
            calls += 1
            return Self.response(request, json: Self.wegmansProduct())
        }
        let (store, _) = try library(session: fixtureSession())
        let first = try trackedProduct(in: store, stapleName: "Milk")
        let second = try trackedProduct(in: store, stapleName: "Milk for baking")

        await store.refresh()

        XCTAssertEqual(calls, 1)
        let importedStaples = Set(store.state.observations.filter { $0.source == .wegmans }.map(\.stapleID))
        XCTAssertEqual(importedStaples, [first.id, second.id])
        XCTAssertEqual(store.state.sourceRuns.count, 1)
    }

    func testNextDayRefreshUsesApprovedCurrentPackageWithoutReactivatingHistoricalAliases() async throws {
        var calls = 0
        let changed = Self.wegmansProduct(name: "Changed package", barcode: "00000000000022", price: 3)
        RefreshURLProtocol.handler = { request in
            calls += 1
            return Self.response(request, json: changed)
        }
        let session = fixtureSession()
        let (store, container) = try library(session: session)
        let first = try trackedProduct(in: store, stapleName: "Milk")
        let second = try trackedProduct(in: store, stapleName: "Milk for baking")

        await store.refresh()
        XCTAssertEqual(calls, 1)
        let changedID = try XCTUnwrap(store.state.variants.first { $0.barcode == "00000000000022" }?.id)
        for staple in [first, second] {
            XCTAssertEqual(store.state.matches.first { $0.stapleID == staple.id && $0.variantID == changedID }?.status, .pending)
            try store.review(stapleID: staple.id, variantID: changedID, status: .approved)
        }
        let beforeCounts = Dictionary(uniqueKeysWithValues: [first, second].map { staple in
            (staple.id, store.state.observations.filter { $0.stapleID == staple.id }.count)
        })

        let context = ModelContext(container)
        let saved = try XCTUnwrap(context.fetch(FetchDescriptor<SavedLibrary>()).first)
        var persisted = try JSONDecoder().decode(LibraryState.self, from: saved.payload)
        persisted.lastRefreshDay = "2000-01-01"
        saved.payload = try JSONEncoder().encode(persisted)
        try context.save()

        let reopened = try LibraryStore(context: ModelContext(container), client: RetailClient(session: session))
        await reopened.refresh()

        XCTAssertEqual(calls, 2)
        for staple in [first, second] {
            XCTAssertEqual(reopened.state.matches.first { $0.stapleID == staple.id && $0.variantID == changedID }?.status, .approved)
            XCTAssertEqual(reopened.state.observations.filter { $0.stapleID == staple.id }.count, beforeCounts[staple.id]! + 1)
            let comparison = try XCTUnwrap(ComparisonEngine.compare(state: reopened.state, asOf: Date()).first { $0.staple.id == staple.id })
            XCTAssertEqual(comparison.winner?.variant.id, changedID)
        }
    }

    func testStaleChangedPackageIsRejectedWithoutMutatingApprovedEvidence() async throws {
        let changed = Self.wegmansProduct(name: "Stale changed package", barcode: "00000000000033", price: 2)
        RefreshURLProtocol.handler = { request in
            Self.response(
                request,
                json: changed,
                headers: ["Date": "Wed, 08 Oct 2025 12:00:00 GMT", "Age": "120"]
            )
        }
        let (store, _) = try library(session: fixtureSession())
        let staple = try trackedProduct(in: store)
        let originalVariant = try XCTUnwrap(store.state.variants.first)
        let observationIDs = store.state.observations.map(\.id)
        let matchIDs = store.state.matches.map(\.id)
        XCTAssertEqual(ComparisonEngine.compare(state: store.state, asOf: Date()).first?.winner?.variant.id, originalVariant.id)

        await store.refresh()

        XCTAssertEqual(store.state.variants.map(\.id), [originalVariant.id])
        XCTAssertEqual(store.state.matches.map(\.id), matchIDs)
        XCTAssertEqual(store.state.matches.first?.status, .approved)
        XCTAssertEqual(store.state.observations.map(\.id), observationIDs)
        XCTAssertFalse(store.state.variants.contains { $0.barcode == "00000000000033" })
        XCTAssertEqual(ComparisonEngine.compare(state: store.state, asOf: Date()).first { $0.staple.id == staple.id }?.winner?.variant.id, originalVariant.id)
        XCTAssertEqual(store.state.sourceRuns.count, 1)
        XCTAssertNotNil(store.state.sourceRuns.first?.error)
        XCTAssertNil(store.state.sourceRuns.first?.succeededAt)
        XCTAssertNotNil(store.state.sourceRuns.first?.finishedAt)
    }

    func testSuccessfulRefreshClearsEarlierTransientFailure() async throws {
        RefreshURLProtocol.handler = { request in Self.response(request, json: Self.wegmansProduct()) }
        let (store, _) = try library(session: fixtureSession())
        await store.refresh()
        XCTAssertNotNil(store.failure)
        _ = try trackedProduct(in: store)

        await store.refresh()

        XCTAssertNil(store.failure)
        XCTAssertNotNil(store.notice)
    }

    private func library(session: URLSession) throws -> (LibraryStore, ModelContainer) {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: SavedLibrary.self, configurations: configuration)
        let store = try LibraryStore(context: ModelContext(container), client: RetailClient(session: session))
        return (store, container)
    }

    @discardableResult
    private func trackedProduct(in store: LibraryStore, stapleName: String = "Milk") throws -> Staple {
        let staple = Staple(name: stapleName, basis: .flOz)
        try store.saveStaple(staple)
        let variant = ProductVariant(store: .wegmans, productID: "94427", barcode: "00000000000001", name: "Fixture milk", quantity: 128, unit: .flOz)
        try store.recordPrice(stapleID: staple.id, variant: variant, reuseID: nil, channel: .inStore, price: 4, available: true, observedAt: Date().addingTimeInterval(-60), conditions: "", sourceURL: nil, approveNew: true)
        return staple
    }

    private func fixtureSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefreshURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func wegmansProduct(
        name: String = "Fixture milk",
        barcode: String = "00000000000001",
        packSize: String = "1 gallon",
        price: Decimal = Decimal(string: "3.39")!
    ) -> [String: Any] {
        [
            "objectId": "133-94427", "storeNumber": "133", "skuId": "94427", "productID": "94427", "productId": "94427",
            "productName": name, "packSize": packSize, "upc": [barcode], "isSoldByWeight": false,
            "isSoldAtStore": true, "isAvailable": true, "soldByVendor": NSNull(), "bottleDeposit": 0,
            "price_inStore": ["unitPrice": "$3.39/gallon", "amount": NSDecimalNumber(decimal: price), "channelKey": "133-Instore", "fulfillmentPrice": NSDecimalNumber(decimal: price)],
            "price_inStoreLoyalty": [:], "loyaltyInstoreDiscount": NSNull(), "digitalCouponsOfferIds": [], "digitalCouponsOffers": [], "discountType": NSNull()
        ]
    }

    private static func response(
        _ request: URLRequest,
        json: Any,
        status: Int = 200,
        headers: [String: String]? = nil
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (response, try! JSONSerialization.data(withJSONObject: json))
    }
}

private final class RefreshURLProtocol: URLProtocol {
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
