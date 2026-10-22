import Foundation
import Testing
import Vapor
import VaporTesting
import MarketHTTP
import SharedMarketCore
import ClientSessions
import StapleScoutKit

@Suite(.serialized)
struct MarketHTTPTests {
    private let token: String
    private let sessions: ClientSessionStore
    init() async throws {
        let store = try ClientSessionStore(databasePath: ":memory:", now: { Date(timeIntervalSince1970: 1_792_190_000) })
        let invitation = try await store.issueInvitation()
        self.token = try await store.enroll(invitation: invitation.invitation).accessToken
        self.sessions = store
    }
    private let instant = Date(timeIntervalSince1970: 1_792_190_000)
    private var headers: HTTPHeaders { ["Host": "127.0.0.1:8878", "Authorization": "Bearer " + token] }
    private let pricePath = "/v1/price?store=wegmans&storeCode=133&channel=in_store&productID=94427"

    @Test func defaultDisabledRequiresAuthenticationAndNeverCreatesEvidence() async throws {
        let cache = try SharedPriceCache(databasePath: ":memory:")
        let service = MarketService(cache: cache, sessions: sessions)
        try await withApp(configure: { service.configure($0) }) { app in
            try await app.testing().test(.GET, "/health", headers: ["Host": "localhost"]) { response in
                #expect(response.status == .ok)
                #expect(response.body.string.contains("disabled"))
                #expect(!response.body.string.contains(token))
            }
            try await app.testing().test(.GET, pricePath, headers: ["Host": "localhost"]) { response in
                #expect(response.status == .unauthorized)
            }
            try await app.testing().test(.GET, pricePath, headers: headers) { response in
                #expect(response.status == .serviceUnavailable)
                #expect(response.body.string.contains("source_access_not_configured"))
                #expect(!response.body.string.contains("94427"))
            }
            try await app.testing().test(.GET, "/v1/sources", headers: headers) { response in
                #expect(response.status == .ok)
                let entries = try #require(JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [[String: Any]])
                #expect(entries.count == 5)
                #expect(entries.allSatisfy { ($0["fetchingEnabled"] as? Bool) == false && ($0["publicAccessApproved"] as? Bool) == false })
            }
        }
    }

    @Test func twoAuthenticatedClientsShareOriginalEvidenceAndDecimalWireValues() async throws {
        let upstream = FakeUpstream(value: evidence())
        let cache = try SharedPriceCache(databasePath: ":memory:", now: { instant })
        let secondInvitation = try await sessions.issueInvitation()
        let secondTokens = try await sessions.enroll(invitation: secondInvitation.invitation)
        let firstPrincipal = try await sessions.authenticate(accessToken: token)
        #expect(firstPrincipal.clientID != secondTokens.clientID)
        var secondHeaders = headers
        secondHeaders.replaceOrAdd(name: "Authorization", value: "Bearer " + secondTokens.accessToken)
        let service = MarketService(cache: cache, sessions: sessions, upstream: upstream, now: { instant })
        try await withApp(configure: { service.configure($0) }) { app in
            let tester = try app.testing()
            async let first = tester.sendRequest(.GET, pricePath, headers: headers)
            async let second = tester.sendRequest(.GET, pricePath, headers: secondHeaders)
            let responses = try await [first, second]
            let payloads = try responses.map { response -> SharedPriceResponse in
                #expect(response.status == .ok)
                #expect(response.headers.first(name: "Cache-Control") == "no-store")
                return try SharedMarketWire.decoder().decode(SharedPriceResponse.self, from: Data(response.body.readableBytesView))
            }
            #expect(await upstream.priceCalls == 1)
            #expect(payloads.filter(\.cacheHit).count == 1)
            for payload in payloads {
                #expect(payload.product.price == "3.39")
                #expect(payload.product.quantity == "128")
                #expect(payload.product.observedAt == instant.addingTimeInterval(-120))
                #expect(payload.product.retrievedAt == instant.addingTimeInterval(-60))
                #expect(payload.product.available == nil)
                #expect(payload.product.conditions == "Fixture condition")
                #expect(payload.context.storeCode == "133")
                #expect(payload.servedAt == instant)
            }
        }
    }

    @Test func invalidContextOriginHostDuplicateQueryAndBodyNeverFetch() async throws {
        let upstream = FakeUpstream(value: evidence())
        let service = MarketService(cache: try SharedPriceCache(databasePath: ":memory:"), sessions: sessions, upstream: upstream)
        try await withApp(configure: { service.configure($0) }) { app in
            for path in [pricePath + "&productID=94427", pricePath + "&token=hidden",
                         pricePath.replacingOccurrences(of: "133", with: "132"),
                         pricePath.replacingOccurrences(of: "in_store", with: "online"),
                         pricePath.replacingOccurrences(of: "94427", with: "1:2"),
                         "/v1/search?store=wegmans&storeCode=133&channel=in_store&q=x"] {
                try await app.testing().test(.GET, path, headers: headers) { #expect($0.status == .badRequest) }
            }
            var originHeaders = headers; originHeaders.add(name: "Origin", value: "https://example.invalid")
            try await app.testing().test(.GET, pricePath, headers: originHeaders) { #expect($0.status == .badRequest) }
            var remoteHeaders = headers; remoteHeaders.replaceOrAdd(name: "Host", value: "example.invalid")
            try await app.testing().test(.GET, pricePath, headers: remoteHeaders) { #expect($0.status == .badRequest) }
            try await app.testing().test(.GET, pricePath, headers: headers, body: ByteBuffer(string: "unexpected")) { #expect($0.status == .badRequest) }
            #expect(await upstream.priceCalls == 0)
            #expect(await upstream.searchCalls == 0)
        }
    }

    @Test func failedAttemptIsNotRetriedOrReportedAsFreshAndBudgetIsShared() async throws {
        let upstream = FakeUpstream(value: evidence(), failure: true)
        let cache = try SharedPriceCache(databasePath: ":memory:", dailyLimit: 1, monthlyLimit: 1, now: { instant })
        let service = MarketService(cache: cache, sessions: sessions, upstream: upstream, now: { instant })
        try await withApp(configure: { service.configure($0) }) { app in
            try await app.testing().test(.GET, pricePath, headers: headers) { response in
                #expect(response.status == .badGateway)
                #expect(!response.body.string.contains("private upstream secret"))
            }
            try await app.testing().test(.GET, pricePath, headers: headers) { response in
                #expect(response.status == .tooManyRequests)
                #expect(response.body.string.contains("attempted_today"))
            }
            try await app.testing().test(.GET, "/v1/search?store=wegmans&storeCode=133&channel=in_store&q=milk", headers: headers) { response in
                #expect(response.status == .tooManyRequests)
                #expect(response.body.string.contains("budget_exceeded"))
            }
            #expect(await upstream.priceCalls == 1)
            #expect(await upstream.searchCalls == 0)
        }
    }

    @Test func searchNormalizationSharesCache() async throws {
        let upstream = FakeUpstream(value: evidence())
        let service = MarketService(cache: try SharedPriceCache(databasePath: ":memory:", now: { instant }), sessions: sessions, upstream: upstream, now: { instant })
        try await withApp(configure: { service.configure($0) }) { app in
            for (query, hit) in [("Milk", false), ("%20milk%20", true)] {
                try await app.testing().test(.GET, "/v1/search?store=wegmans&storeCode=133&channel=in_store&q=" + query, headers: headers) { response in
                    #expect(response.status == .ok)
                    let payload = try SharedMarketWire.decoder().decode(SharedSearchResponse.self, from: Data(response.body.readableBytesView))
                    #expect(payload.products.count == 1)
                    #expect(payload.cacheHit == hit)
                }
            }
            #expect(await upstream.searchCalls == 1)
        }
    }

    private func evidence() -> FetchedPrice {
        FetchedPrice(productID: "94427", productName: "Synthetic milk", barcode: "00000000000000", price: Decimal(string: "3.39"), quantity: 128,
                     unit: .flOz, packCount: 1, quantityKind: .fixed, available: nil,
                     observedAt: instant.addingTimeInterval(-120), retrievedAt: instant.addingTimeInterval(-60), conditions: "Fixture condition",
                     source: .wegmans, sourceURL: "https://www.wegmans.com/api/products/133/94427", sourceExclusion: "Stock unknown")
    }
}

private actor FakeUpstream: MarketUpstream {
    private let value: FetchedPrice
    private let failure: Bool
    private(set) var priceCalls = 0
    private(set) var searchCalls = 0
    init(value: FetchedPrice, failure: Bool = false) { self.value = value; self.failure = failure }
    func price(context: PriceContext, productID: String) async throws -> FetchedPrice {
        priceCalls += 1
        try await Task.sleep(for: .milliseconds(20))
        if failure { throw Failure.privateMessage("private upstream secret") }
        return value
    }
    func search(context: PriceContext, query: String) async throws -> RetailSearchPage {
        searchCalls += 1
        return RetailSearchPage(candidates: [value])
    }
    private enum Failure: Error { case privateMessage(String) }
}
