import XCTest
import SwiftData
import Security
import StapleScoutKit
@testable import StapleScout

@MainActor final class NativePilotTests: XCTestCase {
    override func tearDown() { PilotAppProtocol.handler = nil; super.tearDown() }

    func testAppHostLibraryIsInMemoryDuringTestsForBothModes() throws {
        XCTAssertTrue(try AppLibraryConfiguration.make(pilot: false, runningTests: true).isStoredInMemoryOnly)
        XCTAssertTrue(try AppLibraryConfiguration.make(pilot: true, runningTests: true).isStoredInMemoryOnly)
    }

    func testPilotConfigurationFailsClosedAndPersonalModeStaysExplicit() throws {
        for address: String? in [nil, "", "$(THRIFTY_SERVICE_URL)", "http://127.0.0.1:8878", "http://pilot.example.invalid", "https://user:secret@pilot.example.invalid", "https://pilot.example.invalid?token=secret"] {
            let mode = AppServiceConfiguration.resolve(pilotBuild: true, address: address)
            XCTAssertEqual(mode.mode, .pilot); XCTAssertNil(mode.endpoint)
        }
        let configured = AppServiceConfiguration.resolve(pilotBuild: true, address: "https://pilot.example.invalid")
        XCTAssertEqual(configured.mode, .pilot); XCTAssertNotNil(configured.endpoint)
        let personal = AppServiceConfiguration.resolve(pilotBuild: false, address: "https://pilot.example.invalid")
        XCTAssertEqual(personal.mode, .personal); XCTAssertNil(personal.endpoint)
    }

    func testCompiledBundleSelectsModeAndPreservesPilotServiceSetting() throws {
        if Bundle.main.bundleIdentifier?.hasSuffix(".pilot") == true {
            XCTAssertEqual(AppServiceConfiguration.current.mode, .pilot)
            let address = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "ThriftyServiceURL") as? String,
                "The Pilot template must preserve the setting even when its value is empty.")
            let expected = URL(string: address).flatMap { try? SessionEndpoint(url: $0) }
            XCTAssertEqual(AppServiceConfiguration.current.endpoint, expected)
        } else {
            XCTAssertEqual(AppServiceConfiguration.current.mode, .personal)
        }
    }

    func testRealKeychainPairReplacementRestorationAndScopeIsolation() throws {
        // Dedicated simulator test namespaces only. Never the production app's credential service.
        let bundle = "test.thrifty.session." + UUID().uuidString
        let endpoint = try SessionEndpoint(url: URL(string: "https://pilot.example.invalid")!)
        let first = try KeychainSessionStorage(bundleIdentifier: bundle, endpoint: endpoint)
        let reopened = try KeychainSessionStorage(bundleIdentifier: bundle, endpoint: endpoint)
        let anotherHost = try KeychainSessionStorage(bundleIdentifier: bundle, endpoint: SessionEndpoint(url: URL(string: "https://other.example.invalid")!))
        let anotherBundle = try KeychainSessionStorage(bundleIdentifier: bundle + ".other", endpoint: endpoint)
        defer { try? first.remove(); try? anotherHost.remove(); try? anotherBundle.remove() }
        let probe: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: bundle + ".probe", kSecAttrAccount as String: "probe"]
        let status = SecItemCopyMatching(probe as CFDictionary, nil)
        if status == errSecMissingEntitlement {
            throw XCTSkip("This unsigned simulator test host has no Keychain entitlement (OSStatus \(status)). Injected SecItem operation tests cover storage semantics; signed device smoke remains required.")
        }
        XCTAssertTrue(status == errSecSuccess || status == errSecItemNotFound)
        XCTAssertNil(try first.read())
        let original = Data(#"{"tokens":"synthetic pair 1","refreshInFlight":false}"#.utf8)
        let marked = Data(#"{"tokens":"synthetic pair 1","refreshInFlight":true}"#.utf8)
        let rotated = Data(#"{"tokens":"synthetic pair 2","refreshInFlight":false}"#.utf8)
        try first.replace(with: original); XCTAssertEqual(try reopened.read(), original)
        try first.replace(with: marked); XCTAssertEqual(try reopened.read(), marked)
        try first.replace(with: rotated); XCTAssertEqual(try reopened.read(), rotated)
        XCTAssertNil(try anotherHost.read()); XCTAssertNil(try anotherBundle.read())
        try reopened.remove(); XCTAssertNil(try first.read())
    }

    func testUnconfiguredPilotPreservesLibraryWithoutDirectRetailerFallback() async throws {
        let connection = PilotConnection(endpoint: nil, bundleIdentifier: "test.pilot.unconfigured")
        let container = try ModelContainer(for: SavedLibrary.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = try LibraryStore(context: ModelContext(container), client: connection.transport, searchClient: connection.transport)
        let staple = Staple(name: "Private milk", basis: .flOz)
        try store.saveStaple(staple)
        let results = await store.searchProducts(query: "milk")
        for result in results.filter({ [.wegmans, .lidl, .hmart].contains($0.id) }) {
            XCTAssertTrue(result.candidates.isEmpty); XCTAssertTrue(result.message?.contains("HTTPS") == true)
        }
        let reopened = try LibraryStore(context: ModelContext(container), client: connection.transport, searchClient: connection.transport)
        XCTAssertEqual(reopened.state.staples.map(\.id), [staple.id]); XCTAssertTrue(reopened.state.observations.isEmpty)
        XCTAssertFalse(connection.configured)
    }

    func testEnrolledPilotSearchApprovalReopenAndSessionLossKeepLibraryPrivate() async throws {
        let date = Date().addingTimeInterval(-60), credentialDate = Date()
        let recorded = PilotRequests()
        let evidence = FetchedPrice(productID: "123", productName: "Synthetic whole milk", barcode: nil,
            price: Decimal(string: "3.25"), quantity: 64, unit: .flOz, packCount: 1, quantityKind: .fixed,
            available: true, observedAt: date.addingTimeInterval(-60), retrievedAt: date,
            conditions: "Synthetic fixture only", source: .wegmans,
            sourceURL: "https://www.wegmans.com/api/products/133/123", sourceExclusion: nil)
        PilotAppProtocol.handler = { request in
            recorded.append(request)
            if request.url!.path == "/v1/session/enroll" {
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")); XCTAssertNil(request.url?.query)
                return (200, try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "clientID": "client1_" + String(repeating: "a", count: 32), "tokenType": "Bearer",
                    "accessToken": "acc1_" + String(repeating: "b", count: 64), "accessExpiresAt": credentialDate.addingTimeInterval(900).timeIntervalSince1970 * 1000,
                    "refreshToken": "ref1_" + String(repeating: "c", count: 64), "refreshExpiresAt": credentialDate.addingTimeInterval(30 * 86_400).timeIntervalSince1970 * 1000]))
            }
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let retailer = try XCTUnwrap(StoreID(rawValue: try XCTUnwrap(items.first { $0.name == "store" }?.value)))
            let channel = try XCTUnwrap(Channel(rawValue: try XCTUnwrap(items.first { $0.name == "channel" }?.value)))
            let context = SharedPriceContext(store: retailer, storeCode: items.first { $0.name == "storeCode" }?.value, channel: channel)
            if request.url!.path == "/v1/search" {
                return (200, try SharedMarketWire.encoder().encode(SharedSearchResponse(context: context, page: RetailSearchPage(candidates: retailer == .wegmans ? [evidence] : []), cacheHit: true, servedAt: date)))
            }
            return (200, try SharedMarketWire.encoder().encode(SharedPriceResponse(context: context, value: evidence, cacheHit: true, servedAt: date)))
        }
        let credentials = PilotMemoryCredentials()
        let endpoint = try SessionEndpoint(url: URL(string: "https://pilot.example.invalid")!)
        let sessions = NativeSessionController(endpoint: endpoint, storage: credentials, configuration: protocolConfiguration())
        try await sessions.enroll(invitation: "inv1_" + String(repeating: "d", count: 64))
        let transport = SessionMarketClient(sessions: sessions, configuration: { protocolConfiguration() })
        let container = try ModelContainer(for: SavedLibrary.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = try LibraryStore(context: ModelContext(container), client: transport, searchClient: transport)
        let staple = Staple(name: "Private milk plan", basis: .flOz, rules: "Private brand approval")
        try store.saveStaple(staple)
        let results = await store.searchProducts(query: "milk")
        let result = try XCTUnwrap(results.first { $0.id == .wegmans })
        try store.trackProduct(XCTUnwrap(result.candidates.first), location: result.location, channel: result.channel, stapleID: staple.id)
        let variant = try XCTUnwrap(store.state.variants.first)
        try store.review(stapleID: staple.id, variantID: variant.id, status: .approved)
        let reopened = try LibraryStore(context: ModelContext(container), client: transport, searchClient: transport)
        await reopened.refresh()
        XCTAssertEqual(reopened.state.matches.first?.status, .approved)
        XCTAssertEqual(reopened.state.observations.count, 2)
        for observation in reopened.state.observations {
            XCTAssertEqual(observation.observedAt.timeIntervalSince1970, evidence.observedAt.timeIntervalSince1970, accuracy: 0.001)
            XCTAssertEqual(observation.conditions, evidence.conditions)
        }
        let savedObservations = reopened.state.observations.count
        try await sessions.signOut()
        let failed = await reopened.searchProducts(query: "milk")
        XCTAssertTrue(failed.allSatisfy { $0.candidates.isEmpty })
        XCTAssertEqual(reopened.state.observations.count, savedObservations)
        XCTAssertEqual(reopened.state.matches.first?.status, .approved)
        for request in recorded.snapshot() {
            XCTAssertEqual(request.url?.host, "pilot.example.invalid")
            XCTAssertFalse(request.url!.absoluteString.contains(staple.id.uuidString))
            XCTAssertFalse(request.url!.absoluteString.contains("Private"))
            if request.url!.path != "/v1/session/enroll" { XCTAssertNil(request.httpBody) }
        }
    }
}

private func protocolConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [PilotAppProtocol.self]; return configuration
}
private final class PilotMemoryCredentials: SessionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock(); private var data: Data?
    func read() throws -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    func replace(with data: Data) throws { lock.lock(); defer { lock.unlock() }; self.data = data }
    func remove() throws { lock.lock(); defer { lock.unlock() }; data = nil }
}
private final class PilotRequests: @unchecked Sendable {
    private let lock = NSLock(); private var requests: [URLRequest] = []
    func append(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; requests.append(request) }
    func snapshot() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}
private final class PilotAppProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
