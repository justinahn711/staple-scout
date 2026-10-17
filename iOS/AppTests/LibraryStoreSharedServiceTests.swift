import XCTest
import SwiftData
import Network
import StapleScoutKit
@testable import StapleScout

@MainActor final class LibraryStoreSharedServiceTests: XCTestCase {
    override func tearDown() { SharedAppProtocol.handler = nil; super.tearDown() }

    func testSharedSearchTrackReopenRefreshPreservesPrivateApprovalsAndEvidence() async throws {
        // Offline, synthetic evidence. Unknown local stock must never become a winner.
        let instant = Date().addingTimeInterval(-60)
        let evidence = FetchedPrice(productID: "11675058", productName: "Synthetic milk", barcode: nil,
                                    price: Decimal(string: "3.47"), quantity: 128, unit: .flOz, packCount: 1, quantityKind: .fixed,
                                    available: nil, observedAt: instant.addingTimeInterval(-60), retrievedAt: instant,
                                    conditions: "Regional offer; synthetic test", source: .lidl,
                                    sourceURL: "https://www.lidl.com/p/whole-milk/p11675058", sourceExclusion: "Local stock unknown",
                                    validFrom: instant.addingTimeInterval(-3600), validUntil: instant.addingTimeInterval(3600))
        let recorded = SharedAppRequests()
        SharedAppProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "127.0.0.1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + String(repeating: "t", count: 40))
            recorded.append(request)
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let store = try XCTUnwrap(StoreID(rawValue: try XCTUnwrap(items.first { $0.name == "store" }?.value)))
            let channel = try XCTUnwrap(Channel(rawValue: try XCTUnwrap(items.first { $0.name == "channel" }?.value)))
            let context = SharedPriceContext(store: store, storeCode: items.first { $0.name == "storeCode" }?.value, channel: channel)
            let data: Data
            if request.url!.path == "/v1/search" {
                let products = store == .lidl ? [evidence] : []
                data = try SharedMarketWire.encoder().encode(SharedSearchResponse(context: context, page: RetailSearchPage(candidates: products), cacheHit: true, servedAt: instant))
            } else {
                XCTAssertEqual(store, .lidl)
                data = try SharedMarketWire.encoder().encode(SharedPriceResponse(context: context, value: evidence, cacheHit: true, servedAt: instant))
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, data)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SharedAppProtocol.self]
        let client = try SharedMarketClient(baseURL: URL(string: "http://127.0.0.1:8878")!, accessToken: String(repeating: "t", count: 40), configuration: configuration)
        let container = try ModelContainer(for: SavedLibrary.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = try LibraryStore(context: ModelContext(container), client: client, searchClient: client)
        let staple = Staple(name: "Private staple name", basis: .flOz, rules: "Private substitution rule")
        try store.saveStaple(staple)
        let results = await store.searchProducts(query: "milk")
        let result = try XCTUnwrap(results.first { $0.id == .lidl })
        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertTrue(store.state.observations.isEmpty)
        try store.trackProduct(candidate, location: result.location, channel: result.channel, stapleID: staple.id)
        let variant = try XCTUnwrap(store.state.variants.first)
        XCTAssertEqual(store.state.matches.first?.status, .pending)
        try store.review(stapleID: staple.id, variantID: variant.id, status: .approved)
        let reopened = try LibraryStore(context: ModelContext(container), client: client, searchClient: client)
        XCTAssertEqual(reopened.state.matches.first?.status, .approved)
        await reopened.refresh()
        XCTAssertNil(reopened.failure)
        XCTAssertEqual(reopened.state.observations.count, 2)
        for value in reopened.state.observations {
            XCTAssertEqual(value.price, evidence.price)
            XCTAssertEqual(try XCTUnwrap(value.retrievedAt).timeIntervalSince1970, evidence.retrievedAt.timeIntervalSince1970, accuracy: 0.001)
            XCTAssertEqual(value.observedAt.timeIntervalSince1970, evidence.observedAt.timeIntervalSince1970, accuracy: 0.001)
            XCTAssertEqual(value.validUntil, candidate.validUntil)
            XCTAssertEqual(value.conditions, evidence.conditions)
            XCTAssertNil(value.available)
        }
        XCTAssertNil(ComparisonEngine.compare(state: reopened.state).first?.winner)
        XCTAssertEqual(recorded.snapshot().filter { $0.url?.path == "/v1/price" }.count, 1)
        await reopened.refresh()
        XCTAssertEqual(recorded.snapshot().filter { $0.url?.path == "/v1/price" }.count, 1)
        for request in recorded.snapshot() {
            XCTAssertNil(request.httpBody)
            let url = request.url!.absoluteString
            XCTAssertFalse(url.contains(staple.id.uuidString))
            XCTAssertFalse(url.contains("Private"))
            XCTAssertFalse(url.contains("token"))
        }
    }

    func testIncompleteOptInConfigurationPreservesLibraryAndShowsFailureWithoutFallback() async throws {
        let container = try ModelContainer(for: SavedLibrary.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = try LibraryStore.configured(context: ModelContext(container), environment: ["THRIFTY_SERVICE_URL": "http://127.0.0.1:8878"])
        let staple = Staple(name: "Milk", basis: .flOz)
        try store.saveStaple(staple)
        let results = await store.searchProducts(query: "milk")
        for result in results.filter({ [.wegmans, .hmart, .lidl].contains($0.id) }) {
            XCTAssertTrue(result.candidates.isEmpty)
            XCTAssertTrue(result.message?.contains("configuration") == true)
        }
        XCTAssertEqual(store.state.staples.map(\.id), [staple.id])
        XCTAssertTrue(store.state.observations.isEmpty)
    }

    func testRealSimulatorLoopbackConnectionReachesDisabledService() async throws {
        // Exercise the actual URLSession/ATS path, which URLProtocol fixtures bypass.
        // The listener is synthetic and local to this test; no retailer is called.
        let token = String(repeating: "t", count: 40)
        let fixture = try LocalServiceFixture(token: token)
        let port = try await fixture.start()
        defer { fixture.stop() }
        let client = try SharedMarketClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!, accessToken: token)
        do {
            _ = try await client.search(query: "milk", location: StoreLocation.defaults.first { $0.store == .wegmans }!, channel: .inStore)
            XCTFail("The local fixture always reports a disabled source")
        } catch RetailClientError.unavailable(let status) {
            XCTAssertEqual(status, 503, "The real HTTP response proves ATS permitted the loopback request and auth reached the listener")
        }
    }
}

private final class LocalServiceFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "thrifty-test-loopback")
    private let token: String
    init(token: String) throws {
        self.token = token
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    if let port = listener.port { continuation.resume(returning: port.rawValue) }
                    else { continuation.resume(throwing: URLError(.cannotConnectToHost)) }
                case .failed(let error): listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [self] connection in
                connection.start(queue: queue)
                receive(connection, bytes: Data())
            }
            listener.start(queue: queue)
        }
    }
    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, complete, error in
            let received = bytes + (data ?? Data())
            guard error == nil, received.count <= 16_384 else { connection.cancel(); return }
            let request = String(decoding: received, as: UTF8.self)
            guard request.contains("\r\n\r\n") else {
                if !complete { receive(connection, bytes: received) } else { connection.cancel() }
                return
            }
            let authenticated = request.lowercased().contains(("authorization: bearer " + token).lowercased())
            let status = authenticated ? "503 Service Unavailable" : "401 Unauthorized"
            let body = #"{"code":"source_access_not_configured","message":"Synthetic local test: source disabled"}"#
            let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
    func stop() { listener.cancel(); listener.newConnectionHandler = nil; listener.stateUpdateHandler = nil }
}

private final class SharedAppRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    func append(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; requests.append(request) }
    func snapshot() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}

private final class SharedAppProtocol: URLProtocol {
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
