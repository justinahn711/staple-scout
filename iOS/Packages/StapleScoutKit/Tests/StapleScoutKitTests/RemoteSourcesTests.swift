import Foundation
import XCTest
@testable import StapleScoutKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class RemoteSourcesTests: XCTestCase {
    let now = Date().addingTimeInterval(-2)
    override func tearDown() { SourceFixtureProtocol.handler = nil; super.tearDown() }
    func testDisabledCatalogPreservesUnverifiedContextsAndDistinctDates() throws {
        var objects = StoreID.allCases.map { source($0, enabled: false) }
        objects[0]["lastAttemptedAt"] = ms(now.addingTimeInterval(-30))
        objects[0]["lastSucceededAt"] = ms(now.addingTimeInterval(-20))
        let snapshot = try decode(objects)
        XCTAssertEqual(snapshot.sources.count, 5)
        XCTAssertTrue(snapshot.sources.allSatisfy { !$0.permitsRequests })
        XCTAssertFalse(try XCTUnwrap(snapshot.sources.first { $0.store == .target }).channelVerified)
        XCTAssertEqual(try XCTUnwrap(snapshot.sources.first { $0.store == .walmart }).channel, .pickup)
        XCTAssertTrue(try XCTUnwrap(snapshot.sources.first { $0.store == .hmart }).referenceOnly)
        XCTAssertGreaterThan(snapshot.sources[0].lastSucceededAt!, snapshot.sources[0].lastAttemptedAt!)
        objects[0]["lastSucceededAt"] = ms(now.addingTimeInterval(-60))
        XCTAssertNoThrow(try decode(objects), "A later failed attempt retains its prior complete success")
        objects[0].removeValue(forKey: "lastAttemptedAt")
        XCTAssertNoThrow(try decode(objects), "Operational fields expire independently")
    }
    func testObservationMayPrecedeValidOfferAndStaleStatusKeepsExpiredDates() throws {
        var object = source(.lidl)
        object["evidence"] = ["observedAt": ms(now.addingTimeInterval(-200)), "retrievedAt": ms(now.addingTimeInterval(-150)),
                              "validFrom": ms(now.addingTimeInterval(-100)), "validUntil": ms(now.addingTimeInterval(-50))]
        object["state"] = "stale"
        XCTAssertNoThrow(try decode([object]))
    }
    func testCatalogRejectsUnknownDuplicateEscapedKeysMalformedFlagsAndContexts() throws {
        let valid = source(.wegmans)
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["unexpected"] = true }, { $0["storeCode"] = "999" }, { $0["channel"] = "pickup" },
            { $0["state"] = "connected" }, { $0["displayTTLSeconds"] = -1 }, { $0["cacheTTLSeconds"] = 172_801 },
            { $0["channelVerified"] = false }, { $0["publicAccessApproved"] = false },
            { $0["state"] = "pending" }, { $0["lastAttemptedAt"] = self.ms(self.now.addingTimeInterval(30)) },
            { $0["evidence"] = ["observedAt": 100, "retrievedAt": 99] },
            { $0["attribution"] = String(repeating: "x", count: 1025) }
        ]
        for mutate in mutations { var object = valid; mutate(&object); XCTAssertThrowsError(try decode([object])) }
        XCTAssertThrowsError(try decode([valid, valid]))
        XCTAssertThrowsError(try decode(Array(repeating: valid, count: 6)))
        var text = String(decoding: try envelope([valid]), as: UTF8.self)
        text = text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schemaVersion\":1")
        XCTAssertThrowsError(try RemoteSourceSnapshot.decode(Data(text.utf8)))
        text = String(decoding: try envelope([valid]), as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1,\"schem\\u0061Version\":1")
        XCTAssertThrowsError(try RemoteSourceSnapshot.decode(Data(text.utf8)))
    }
    func testAllAggregateStatesRemainDistinctAndPendingNeverPromisesScheduling() throws {
        for state in ["disabled", "pending", "ready", "partial", "failed", "stale"] {
            var object = source(.wegmans, enabled: state != "disabled")
            object["state"] = state
            if state == "pending" { object["pendingMeaning"] = "Active work or no accepted result; checking does not schedule work." }
            let snapshot = try decode([object])
            XCTAssertEqual(snapshot.sources.first?.state.rawValue, state)
            if state == "pending" { XCTAssertTrue(snapshot.sources[0].statusText.contains("or work is active")) }
        }
    }

    func testHMartSourceURLRejectsUnknownOrCredentialQueryMembers() async throws {
        let value = FetchedPrice(productID: "123:456", productName: "Synthetic tofu", price: 2, quantity: 16, unit: .oz, available: nil,
            observedAt: now.addingTimeInterval(-60), retrievedAt: now.addingTimeInterval(-30), source: .hmart,
            sourceURL: "https://www.hmart.com/api/catalog_system/pub/products/search/?fq=productId:123&api_key=secret",
            sourceExclusion: "National online reference only")
        let payload = try SharedMarketWire.encoder().encode(SharedPriceResponse(context: SharedPriceContext(store: .hmart, storeCode: nil, channel: .online), value: value, cacheHit: true, servedAt: now))
        SourceFixtureProtocol.handler = { _ in (200, payload) }
        let location = StoreLocation.defaults.first { $0.store == .hmart }!
        let request = FetchRequest(variant: ProductVariant(store: .hmart, productID: "123:456", name: "Tofu", quantity: 16, unit: .oz), location: location, channel: .online)
        do { _ = try await makeClient().fetch(request); XCTFail() } catch RetailClientError.invalidResponse {}
    }

    func testSafeQuotaMessagesKeepDayAndPendingRecoveryDistinctWithoutRawProse() {
        XCTAssertTrue(SharedServiceError(status: 429, code: "attempted_today").localizedDescription.contains("next UTC day"))
        XCTAssertTrue(SharedServiceError(status: 429, code: "work_pending").localizedDescription.contains("explicit action"))
        XCTAssertNil(SharedServiceError(status: 429, code: "private-provider-secret").code)
    }

    func testSnapshotExpiresAndWallClockRollbackFailsClosed() throws {
        let snapshot = try decode([source(.wegmans)])
        XCTAssertTrue(snapshot.isCurrent(at: now))
        XCTAssertFalse(snapshot.isCurrent(at: now.addingTimeInterval(-1)))
        XCTAssertFalse(snapshot.isCurrent(at: now.addingTimeInterval(300)))
        XCTAssertThrowsError(try RemoteSourceSnapshot.decode(try envelope([source(.wegmans)], generatedAt: now.addingTimeInterval(-301)), at: now))
    }
    func testSourcesRequestIsAuthenticatedWithoutContextBodyOrRetailFallback() async throws {
        let data = try envelope(StoreID.allCases.map { source($0, enabled: false) })
        var requests: [URLRequest] = []
        SourceFixtureProtocol.handler = { request in
            requests.append(request)
            XCTAssertEqual(request.url?.absoluteString, "https://pilot.example.invalid/v1/sources")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + String(repeating: "t", count: 40))
            XCTAssertNil(request.httpBody); return (200, data)
        }
        let client = try makeClient()
        let snapshot = try await client.sources()
        XCTAssertEqual(snapshot.sources.count, 5); XCTAssertEqual(requests.count, 1)
    }
    func testApprovedRemoteWalmartAndTargetRequireStructuredFirstPartyEvidence() async throws {
        for retailer in [StoreID.walmart, .target] {
            let snapshot = try decode([source(retailer)])
            let payload = try price(retailer)
            SourceFixtureProtocol.handler = { _ in (200, payload) }
            let result = try await makeClient(snapshot).fetch(request(retailer))
            XCTAssertEqual(result.productID, "123"); XCTAssertEqual(result.price, Decimal(string: "3.49"))
            XCTAssertEqual(result.observedAt.timeIntervalSince1970, now.addingTimeInterval(-60).timeIntervalSince1970, accuracy: 0.001)
        }
    }
    func testRemoteEvidenceRejectsWrongSellerChannelStoreIDURLAndMissingProvenance() async throws {
        let snapshot = try decode([source(.walmart)])
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["provenance"] = NSNull() },
            { var p = $0["provenance"] as! [String: Any]; p["seller"] = "Marketplace seller"; $0["provenance"] = p },
            { var p = $0["provenance"] as! [String: Any]; p["channel"] = "in_store"; $0["provenance"] = p },
            { var p = $0["provenance"] as! [String: Any]; p["storeCode"] = "999"; $0["provenance"] = p },
            { var p = $0["provenance"] as! [String: Any]; p["priceType"] = "member"; $0["provenance"] = p },
            { var p = $0["provenance"] as! [String: Any]; p["provider"] = "unselected"; $0["provenance"] = p },
            { var p = $0["provenance"] as! [String: Any]; p["extra"] = "untrusted"; $0["provenance"] = p },
            { $0["sourceURL"] = "https://www.walmart.com/ip/milk/999" },
            { $0["sourceURL"] = "https://www.walmart.com/ip/milk/123?store=999" },
            { $0["productID"] = "999" }, { $0["source"] = "target" }, { $0["price"] = "3.49junk" }
        ]
        for mutate in mutations {
            var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: price(.walmart)) as? [String: Any])
            var product = payload["product"] as! [String: Any]; mutate(&product); payload["product"] = product
            let data = try JSONSerialization.data(withJSONObject: payload)
            SourceFixtureProtocol.handler = { _ in (200, data) }
            do { _ = try await makeClient(snapshot).fetch(request(.walmart)); XCTFail("Unverified evidence accepted") }
            catch RetailClientError.invalidResponse {} catch { XCTFail("Unexpected \(error)") }
        }
    }
    func testRemoteCanonicalURLsRejectDotEmptyEncodedAndAmbiguousSegments() async throws {
        for store in [StoreID.walmart, .target] {
            let invalid = store == .walmart ? ["/ip/../123", "/ip/./123", "/ip//milk/123", "/ip/milk//123", "/ip/milk/123/", "/ip/%2e%2e/123", "/ip/milk%2F123"]
                : ["/p/../-/A-123", "/p/./-/A-123", "/p//milk/-/A-123", "/p/milk//-/A-123", "/p/milk/-/A-123/", "/p/%2e%2e/-/A-123", "/p/milk%2F-/A-123"]
            let snapshot = try decode([source(store)])
            for path in invalid {
                var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: price(store)) as? [String: Any])
                var product = payload["product"] as! [String: Any]
                product["sourceURL"] = "https://www." + (store == .walmart ? "walmart.com" : "target.com") + path
                payload["product"] = product
                let data = try JSONSerialization.data(withJSONObject: payload)
                SourceFixtureProtocol.handler = { _ in (200, data) }
                do { _ = try await makeClient(snapshot).fetch(request(store)); XCTFail(path) }
                catch RetailClientError.invalidResponse {} catch { XCTFail("Unexpected \(error)") }
            }
        }
    }

    func testRemotePermissionsCannotEnableUnknownStoreOrUnverifiedTargetChannel() async throws {
        var object = source(.target, enabled: false)
        object["fetchingEnabled"] = true; object["publicAccessApproved"] = true
        XCTAssertThrowsError(try decode([object]))
        let disabled = try decode([source(.walmart, enabled: false)])
        var count = 0; SourceFixtureProtocol.handler = { _ in count += 1; return (200, Data()) }
        do { _ = try await makeClient(disabled).fetch(request(.walmart)); XCTFail() } catch RetailClientError.unsupportedSource {}
        XCTAssertEqual(count, 0)
        do { _ = try await makeClient().fetch(request(.walmart)); XCTFail() } catch RetailClientError.unsupportedSource {}
        XCTAssertEqual(count, 0, "Legacy personal capability must remain blocked")
    }
    func testCatalogRevisionRejectsLatePublishAndClearsImmediately() async throws {
        let catalog = RemoteSourceCatalog(), snapshot = try decode([source(.wegmans)])
        let older = await catalog.beginCheck(), newer = await catalog.beginCheck()
        let rejected = await catalog.replace(snapshot, expected: older, sessionEpoch: 1)
        XCTAssertFalse(rejected)
        let accepted = await catalog.replace(snapshot, expected: newer, sessionEpoch: 2)
        XCTAssertTrue(accepted)
        let captured = await catalog.capture(); XCTAssertEqual(captured.2, 2)
        await catalog.clear()
        let current = await catalog.current(); XCTAssertNil(current)
        let matches = await catalog.matches(captured.1); XCTAssertFalse(matches)
    }
    private func ms(_ date: Date) -> Double { date.timeIntervalSince1970 * 1000 }
    private func source(_ store: StoreID, enabled: Bool = true) -> [String: Any] {
        let supported = enabled || [.wegmans, .hmart, .lidl].contains(store)
        var value: [String: Any] = ["provider": [.walmart, .target].contains(store) ? (enabled ? "serpapi" : "unselected") : "retailer_website",
            "store": store.rawValue, "channel": store == .hmart ? "online" : store == .walmart ? "pickup" : "in_store",
            "technicallySupported": supported, "channelVerified": supported, "fetchingEnabled": enabled, "publicAccessApproved": enabled,
            "attribution": "Synthetic source fixture", "referenceOnly": store == .hmart,
            "limitation": store == .hmart ? "National online reference" : store == .lidl ? "Regional offers; stock unknown" : "Synthetic fixture only",
            "cacheTTLSeconds": enabled ? 86_400 : 0, "displayTTLSeconds": enabled ? 86_400 : 0,
            "maximumObservationAgeSeconds": enabled ? 172_800 : 0, "retentionSeconds": enabled ? 172_800 : 0, "state": enabled ? "ready" : "disabled"]
        if let code = StoreLocation.defaults.first(where: { $0.store == store })!.code { value["storeCode"] = code }
        return value
    }
    private func envelope(_ sources: [[String: Any]], generatedAt: Date? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "generatedAt": ms(generatedAt ?? now), "sources": sources], options: .sortedKeys)
    }
    private func decode(_ values: [[String: Any]]) throws -> RemoteSourceSnapshot { try RemoteSourceSnapshot.decode(envelope(values), at: now) }
    private func makeClient(_ snapshot: RemoteSourceSnapshot? = nil) throws -> SharedMarketClient {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [SourceFixtureProtocol.self]
        return try SharedMarketClient(baseURL: URL(string: "https://pilot.example.invalid")!, accessToken: String(repeating: "t", count: 40), configuration: configuration, sourceSnapshot: snapshot)
    }
    private func request(_ store: StoreID) -> FetchRequest {
        let location = StoreLocation.defaults.first { $0.store == store }!
        return FetchRequest(variant: ProductVariant(store: store, productID: "123", name: "Milk", quantity: 64, unit: .flOz), location: location, channel: store == .walmart ? .pickup : .inStore)
    }
    private func price(_ store: StoreID) throws -> Data {
        let request = request(store)
        let value = FetchedPrice(productID: "123", productName: "Synthetic milk", price: Decimal(string: "3.49"), quantity: 64, unit: .flOz, available: true,
            observedAt: now.addingTimeInterval(-60), retrievedAt: now.addingTimeInterval(-30), source: store == .walmart ? .walmart : .target,
            sourceURL: store == .walmart ? "https://www.walmart.com/ip/milk/123" : "https://www.target.com/p/milk/-/A-123")
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: SharedMarketWire.encoder().encode(SharedPriceResponse(context: SharedPriceContext(location: request.location, channel: request.channel), value: value, cacheHit: true, servedAt: now))) as? [String: Any])
        var product = payload["product"] as! [String: Any]
        product["provenance"] = ["schemaVersion": 1, "provider": "serpapi", "store": store.rawValue, "storeCode": request.location.code!, "channel": request.channel.rawValue, "seller": store.name, "priceType": "regular"]
        payload["product"] = product
        return try JSONSerialization.data(withJSONObject: payload)
    }
}
private final class SourceFixtureProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
