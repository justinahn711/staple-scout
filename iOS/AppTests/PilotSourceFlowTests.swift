import XCTest
import SwiftData
import StapleScoutKit
@testable import StapleScout

@MainActor final class PilotSourceFlowTests: XCTestCase {
    func testEmptyPilotRequiresManualStatusAndSelectionWithoutConsumingRefreshDay() async throws {
        let transport = PilotSourceFake(), sources = PilotStatusFake(try snapshot([source(.walmart)]))
        let store = try library(transport, sources)
        XCTAssertTrue(store.state.staples.isEmpty)
        let staple = Staple(name: "Milk", basis: .flOz); try store.saveStaple(staple)
        let initial = await store.searchProducts(query: "milk")
        XCTAssertEqual(initial.count, StoreID.allCases.count)
        XCTAssertTrue(initial.allSatisfy { $0.candidates.isEmpty && $0.message?.contains("Check source status") == true })
        await store.refresh(); XCTAssertNil(store.state.lastRefreshDay)
        let initialCalls = await transport.calls(); XCTAssertTrue(initialCalls.isEmpty)
        await store.checkSources()
        let status = try XCTUnwrap(store.remoteSources?.sources.first)
        try store.selectRemoteSource(status)
        let results = await store.searchProducts(query: "milk")
        let result = try XCTUnwrap(results.first { $0.id == .walmart })
        XCTAssertEqual(result.channel, .pickup)
        let candidate = try XCTUnwrap(result.candidates.first)
        try store.trackProduct(candidate, location: result.location, channel: result.channel, stapleID: staple.id)
        XCTAssertEqual(store.state.matches.first?.status, .pending)
        let variant = try XCTUnwrap(store.state.variants.first)
        try store.review(stapleID: staple.id, variantID: variant.id, status: .approved)
        XCTAssertNotNil(ComparisonEngine.compare(state: store.comparisonState(), channel: .pickup).first?.winner)
        await store.refresh()
        XCTAssertNotNil(store.state.lastRefreshDay)
        let calls = await transport.calls(); XCTAssertEqual(calls.filter { $0 == "price:walmart:pickup" }.count, 1)
        XCTAssertEqual(store.state.matches.first?.status, .approved)
        for observation in store.state.observations {
            XCTAssertLessThan(observation.observedAt, observation.retrievedAt!)
            XCTAssertEqual(observation.channel, .pickup)
        }
    }

    func testUnverifiedDisabledCatalogDoesNotEnableStoresAndPreservesLibrary() async throws {
        let transport = PilotSourceFake(), sources = PilotStatusFake(try snapshot(StoreID.allCases.map { source($0, enabled: false) }))
        let store = try library(transport, sources)
        try store.saveStaple(Staple(name: "Rice", basis: .oz))
        await store.checkSources()
        for status in store.remoteSources!.sources { XCTAssertThrowsError(try store.selectRemoteSource(status)) }
        let results = await store.searchProducts(query: "rice")
        XCTAssertTrue(results.allSatisfy { $0.candidates.isEmpty && $0.message != nil })
        XCTAssertTrue(results.first { $0.id == .target }?.message?.contains("unverified") == true)
        let calls = await transport.calls(); XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(store.state.staples.count, 1); XCTAssertTrue(store.state.observations.isEmpty)
    }

    func testValidatedCatalogCanReplaceUnsupportedPreferenceAndExposeBothTargetChannels() async throws {
        let sources = PilotStatusFake(try snapshot([source(.target), source(.target, channel: .pickup)]))
        let store = try library(PilotSourceFake(), sources)
        try store.selectLocation(store: .target, name: "Old unsupported location", code: "999")
        let old = try XCTUnwrap(store.state.location(for: .target))
        await store.checkSources()
        XCTAssertNil(store.sourceStatus(for: old))
        let choices = store.remoteSources!.sources
        XCTAssertEqual(choices.count, 2)
        try store.selectRemoteSource(choices.first { $0.channel == .pickup }!)
        let selected = try XCTUnwrap(store.state.location(for: .target))
        XCTAssertEqual(selected.code, "1827"); XCTAssertNotEqual(selected.id, old.id)
        XCTAssertTrue(store.state.locations.contains { $0.id == old.id && $0.code == "999" })
        XCTAssertEqual(store.requestChannel(for: selected), .pickup)
        try store.selectRemoteSource(choices.first { $0.channel == .inStore }!)
        XCTAssertEqual(store.requestChannel(for: selected), .inStore)
        XCTAssertEqual(store.state.location(for: .target)?.id, selected.id)
    }

    func testCurrentPermissionProjectionKeepsHistoryManualEvidenceAndFrozenReports() async throws {
        let sources = PilotStatusFake(try snapshot([source(.wegmans)]))
        let store = try library(PilotSourceFake(), sources)
        let staple = Staple(name: "Milk", basis: .flOz); try store.saveStaple(staple)
        let location = store.state.location(for: .wegmans)!
        let variant = ProductVariant(store: .wegmans, name: "Manual milk", quantity: 64, unit: .flOz)
        try store.recordPrice(stapleID: staple.id, variant: variant, reuseID: nil, channel: .inStore, price: 4, available: true, observedAt: Date().addingTimeInterval(-30), conditions: "", sourceURL: nil, approveNew: true)
        await store.checkSources(); try store.selectRemoteSource(store.remoteSources!.sources[0])
        let results = await store.searchProducts(query: "milk")
        let candidate = try XCTUnwrap(results.first { $0.id == .wegmans }?.candidates.first)
        try store.trackProduct(candidate, location: location, channel: .inStore, stapleID: staple.id)
        let remote = store.state.variants.first { $0.productID == candidate.productID }!
        try store.review(stapleID: staple.id, variantID: remote.id, status: .approved)
        let original = store.state.observations
        let saved = try store.report(ReportRequest(asOf: Date(), stores: [.wegmans], channel: .inStore, neededOnly: false))
        XCTAssertEqual(saved.comparisons.first?.winner?.variant.id, remote.id)
        store.invalidateRemoteSources()
        let projected = ComparisonEngine.compare(state: store.comparisonState()).first!
        XCTAssertEqual(projected.winner?.variant.id, variant.id, "Manual observation remains independently eligible")
        XCTAssertTrue(projected.offers.first { $0.variant.id == remote.id }!.exclusionReasons.contains { $0.contains("unverified") })
        XCTAssertEqual(store.state.observations.map(\.sourceExclusion), original.map(\.sourceExclusion))
        XCTAssertEqual(store.state.matches.first { $0.variantID == remote.id }?.status, .approved)
        XCTAssertEqual(store.state.reports.first?.comparisons.first?.winnerID, saved.comparisons.first?.winnerID)
        await sources.replace(try snapshot([source(.wegmans, state: "failed")]))
        await store.checkSources()
        XCTAssertEqual(ComparisonEngine.compare(state: store.comparisonState()).first?.winner?.variant.id, remote.id, "Operational failure does not withdraw approved usable retained evidence")
        var short = source(.wegmans); short["displayTTLSeconds"] = 1
        await sources.replace(try snapshot([short])); await store.checkSources()
        XCTAssertEqual(ComparisonEngine.compare(state: store.comparisonState()).first?.winner?.variant.id, variant.id)
        XCTAssertEqual(store.state.observations.count, original.count)
    }

    func testStatusFailureClearsRemoteEligibilityAndKeepsSafeQuotaRecovery() async throws {
        let transport = PilotSourceFake(), sources = PilotStatusFake(try snapshot([source(.wegmans)]))
        let store = try library(transport, sources)
        await store.checkSources(); try store.selectRemoteSource(store.remoteSources!.sources[0])
        await sources.fail(); await store.checkSources()
        XCTAssertNil(store.remoteSources); XCTAssertNotNil(store.sourceStatusError)
        let results = await store.searchProducts(query: "milk")
        XCTAssertTrue(results.allSatisfy { $0.candidates.isEmpty })
        let calls = await transport.calls(); XCTAssertTrue(calls.isEmpty)
        await sources.replace(try snapshot([source(.wegmans)])); await store.checkSources()
        try store.selectRemoteSource(store.remoteSources!.sources[0])
        _ = await store.searchProducts(query: "milk")
        let recovered = await transport.calls(); XCTAssertEqual(recovered, ["search:wegmans:in_store"])
    }

    func testPartialOutageReferenceOffersAndStaleTrackingNeverInventWinners() async throws {
        let transport = PilotSourceFake(), sources = PilotStatusFake(try snapshot([source(.wegmans), source(.hmart), source(.lidl)]))
        let store = try library(transport, sources)
        let staple = Staple(name: "Milk", basis: .flOz); try store.saveStaple(staple)
        await store.checkSources()
        for source in store.remoteSources!.sources { try store.selectRemoteSource(source) }
        await transport.fail(.wegmans)
        let results = await store.searchProducts(query: "milk")
        XCTAssertTrue(results.first { $0.id == .wegmans }!.candidates.isEmpty)
        XCTAssertNotNil(results.first { $0.id == .wegmans }!.message)
        for result in results.filter({ [.hmart, .lidl].contains($0.id) }) {
            let candidate = try XCTUnwrap(result.candidates.first)
            try store.trackProduct(candidate, location: result.location, channel: result.channel, stapleID: staple.id)
            let variant = store.state.variants.first { $0.store == result.id }!
            try store.review(stapleID: staple.id, variantID: variant.id, status: .approved)
        }
        XCTAssertNil(ComparisonEngine.compare(state: store.comparisonState()).first?.winner)
        XCTAssertTrue(store.state.observations.allSatisfy { $0.sourceExclusion?.isEmpty == false })
        let result = results.first { $0.id == .lidl }!, original = result.candidates[0]
        var wrong = original; wrong.quantity = 999
        try store.trackProduct(wrong, location: result.location, channel: result.channel, stapleID: staple.id)
        XCTAssertEqual(store.state.variants.first { $0.store == .lidl }?.quantity, original.quantity)
        let wrongLocation = StoreLocation(store: .lidl, name: "Wrong", code: "999")
        XCTAssertThrowsError(try store.trackProduct(original, location: wrongLocation, channel: result.channel, stapleID: staple.id))
        store.invalidateRemoteSources()
        XCTAssertThrowsError(try store.trackProduct(original, location: result.location, channel: result.channel, stapleID: staple.id))
        XCTAssertNil(ComparisonEngine.compare(state: store.comparisonState()).first?.winner)
    }

    func testSelectionChangeStopsRemainingPrebuiltRefreshRequests() async throws {
        let transport = PilotSourceFake(), sources = PilotStatusFake(try snapshot([source(.wegmans), source(.lidl)])), gate = PilotFlowGate()
        let store = try library(transport, sources)
        let staple = Staple(name: "Milk", basis: .flOz); try store.saveStaple(staple)
        await store.checkSources()
        for source in store.remoteSources!.sources { try store.selectRemoteSource(source) }
        let results = await store.searchProducts(query: "milk")
        for result in results where !result.candidates.isEmpty {
            try store.trackProduct(result.candidates[0], location: result.location, channel: result.channel, stapleID: staple.id)
        }
        await transport.suspendFirstPrice(gate)
        let refresh = Task { await store.refresh() }
        await gate.waitUntilEntered()
        try store.selectRemoteSource(store.remoteSources!.sources.first { $0.store == .wegmans }!)
        await gate.open(); await refresh.value
        let calls = await transport.calls().filter { $0.hasPrefix("price:") }
        XCTAssertEqual(calls.count, 1, "Old remaining contexts must not consume provider work after a selection change")
        XCTAssertNotNil(store.state.lastRefreshDay, "The legitimate first attempt retains its conservative daily claim")
    }

    func testDelayedSearchFailureCannotRepublishEarlierCandidatesAfterStatusCheck() async throws {
        let transport = PilotSourceFake(), sources = PilotStatusFake(try snapshot([source(.wegmans), source(.lidl)])), gate = PilotFlowGate()
        let store = try library(transport, sources)
        let staple = Staple(name: "Milk", basis: .flOz); try store.saveStaple(staple)
        await store.checkSources()
        for source in store.remoteSources!.sources { try store.selectRemoteSource(source) }
        await transport.fail(.lidl); await transport.suspendSearch(.lidl, gate: gate)
        let search = Task { await store.searchProducts(query: "milk") }
        await gate.waitUntilEntered()
        await store.checkSources()
        try store.selectRemoteSource(store.remoteSources!.sources.first { $0.store == .wegmans }!)
        await gate.open()
        let result = await search.value; XCTAssertTrue(result.isEmpty)
        let candidate = await transport.sample(.wegmans), location = store.state.location(for: .wegmans)!
        XCTAssertThrowsError(try store.trackProduct(candidate, location: location, channel: .inStore, stapleID: staple.id))
        XCTAssertTrue(store.state.observations.isEmpty)
    }

    private func library(_ transport: PilotSourceFake, _ sources: PilotStatusFake) throws -> LibraryStore {
        let container = try ModelContainer(for: SavedLibrary.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return try LibraryStore(context: ModelContext(container), client: transport, searchClient: transport, sourceClient: sources)
    }
    private func snapshot(_ sources: [[String: Any]]) throws -> RemoteSourceSnapshot {
        try RemoteSourceSnapshot.decode(JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "generatedAt": Date().addingTimeInterval(-1).timeIntervalSince1970 * 1000, "sources": sources]))
    }
    private func source(_ store: StoreID, enabled: Bool = true, channel: Channel? = nil, state: String? = nil) -> [String: Any] {
        let supported = enabled || [.wegmans, .hmart, .lidl].contains(store)
        var value: [String: Any] = ["provider": [.walmart, .target].contains(store) ? (enabled ? "serpapi" : "unselected") : "retailer_website",
            "store": store.rawValue, "channel": (channel ?? (store == .walmart ? .pickup : store == .hmart ? .online : .inStore)).rawValue,
            "technicallySupported": supported, "channelVerified": supported, "fetchingEnabled": enabled, "publicAccessApproved": enabled,
            "attribution": "Synthetic fixture", "referenceOnly": store == .hmart, "limitation": "Synthetic reference or regional limitation",
            "cacheTTLSeconds": enabled ? 86400 : 0, "displayTTLSeconds": enabled ? 86400 : 0,
            "maximumObservationAgeSeconds": enabled ? 172800 : 0, "retentionSeconds": enabled ? 172800 : 0, "state": state ?? (enabled ? "ready" : "disabled")]
        if let code = StoreLocation.defaults.first(where: { $0.store == store })!.code { value["storeCode"] = code }
        return value
    }
}

private actor PilotStatusFake: RemoteSourceLoading {
    private var snapshot: RemoteSourceSnapshot?
    init(_ snapshot: RemoteSourceSnapshot) { self.snapshot = snapshot }
    func replace(_ value: RemoteSourceSnapshot) { snapshot = value }
    func fail() { snapshot = nil }
    func sources() throws -> RemoteSourceSnapshot { guard let snapshot else { throw NativeSessionError.requestLimit }; return snapshot }
}
private actor PilotSourceFake: RetailPriceFetching, RetailProductSearching {
    private var recorded: [String] = []
    private var failures = Set<StoreID>()
    private var delayedSearch: (StoreID, PilotFlowGate)?
    private var delayedPrice: PilotFlowGate?
    func suspendSearch(_ store: StoreID, gate: PilotFlowGate) { delayedSearch = (store, gate) }
    func suspendFirstPrice(_ gate: PilotFlowGate) { delayedPrice = gate }
    func sample(_ store: StoreID) -> FetchedPrice { evidence(store) }
    func fail(_ store: StoreID) { failures.insert(store) }
    func calls() -> [String] { recorded }
    func search(query: String, location: StoreLocation, channel: Channel) async throws -> RetailSearchPage {
        recorded.append("search:\(location.store.rawValue):\(channel.rawValue)")
        if let delayedSearch, delayedSearch.0 == location.store { self.delayedSearch = nil; await delayedSearch.1.pause() }
        if failures.contains(location.store) { throw NativeSessionError.unavailable }
        return RetailSearchPage(candidates: [evidence(location.store)])
    }
    func fetch(_ request: FetchRequest) async -> FetchedPrice {
        recorded.append("price:\(request.location.store.rawValue):\(request.channel.rawValue)")
        if let delayedPrice { self.delayedPrice = nil; await delayedPrice.pause() }
        return evidence(request.location.store)
    }
    private func evidence(_ store: StoreID) -> FetchedPrice {
        let time = Date().addingTimeInterval(-60)
        let reference = [.hmart, .lidl].contains(store)
        return FetchedPrice(productID: store == .hmart ? "123:456" : "123", productName: "Synthetic milk", price: 3, quantity: 64, unit: .flOz,
            available: store == .lidl ? nil : true, observedAt: time.addingTimeInterval(-60), retrievedAt: time, source: SourceID(rawValue: store.rawValue)!,
            sourceURL: store == .walmart ? "https://www.walmart.com/ip/milk/123" : "https://www.wegmans.com/api/products/133/123",
            sourceExclusion: reference ? "National reference or regional offers; local stock unverified." : nil)
    }
}


private actor PilotFlowGate {
    private var entered = false
    private var released = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        entered = true; entryWaiters.forEach { $0.resume() }; entryWaiters = []
        if !released { await withCheckedContinuation { waiting = $0 } }
    }
    func waitUntilEntered() async { if !entered { await withCheckedContinuation { entryWaiters.append($0) } } }
    func open() { released = true; waiting?.resume(); waiting = nil }
}
