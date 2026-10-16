import XCTest
import SwiftData
import StapleScoutKit
@testable import StapleScout

@MainActor final class LibraryStoreTests: XCTestCase {
    private func library() throws -> (LibraryStore, ModelContainer) {
        let container = try ModelContainer(for: SavedLibrary.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return (try LibraryStore(context: ModelContext(container)), container)
    }
    private func addPrice(_ store: LibraryStore, staple: Staple, price: Decimal = 4, reuseID: UUID? = nil, approve: Bool = true, when: Date = Date().addingTimeInterval(-60)) throws {
        try store.recordPrice(stapleID: staple.id, variant: ProductVariant(store: .wegmans, name: "Fixture rice", quantity: 16, unit: .oz), reuseID: reuseID, channel: .inStore, price: price, available: true, observedAt: when, conditions: "", sourceURL: nil, approveNew: approve)
    }
    func testFirstLaunchIsEmptyAndPersistsWithoutPython() throws {
        let (store, container) = try library()
        XCTAssertTrue(store.state.staples.isEmpty)
        XCTAssertTrue(store.state.observations.isEmpty)
        let staple = Staple(name: "Fixture rice", basis: .oz)
        try store.saveStaple(staple)
        let reopened = try LibraryStore(context: ModelContext(container))
        XCTAssertEqual(reopened.state.staples.first?.id, staple.id)
        XCTAssertEqual(reopened.state.staples.first?.name, "Fixture rice")
    }
    func testRequirementEditsClearReviewsButNeededAndAmountDoNot() throws {
        let (store, _) = try library()
        var staple = Staple(name: "Fixture rice", basis: .oz)
        try store.saveStaple(staple); try addPrice(store, staple: staple)
        try store.setNeeded(staple.id, needed: false)
        XCTAssertEqual(store.state.matches.first?.status, .approved)
        staple.needed = false; staple.desiredQuantity = 20; staple.desiredUnit = .oz
        try store.saveStaple(staple)
        XCTAssertEqual(store.state.matches.first?.status, .approved)
        staple.rules = "Plain dry rice only"
        try store.saveStaple(staple)
        XCTAssertEqual(store.state.matches.first?.status, .pending)
    }
    func testNativeObservationReuseKeepsIdentityAndReview() throws {
        let (store, _) = try library()
        let staple = Staple(name: "Fixture rice", basis: .oz)
        try store.saveStaple(staple); try addPrice(store, staple: staple)
        let id = try XCTUnwrap(store.state.variants.first?.id)
        try addPrice(store, staple: staple, price: 3, reuseID: id, approve: false)
        XCTAssertEqual(store.state.variants.count, 1)
        XCTAssertEqual(store.state.matches.first?.status, .approved)
        XCTAssertEqual(store.state.observations.count, 2)
        XCTAssertEqual(Set(store.state.observations.map(\.variantID)), [id])
    }
    func testChangedPackageCannotReuseApprovedVariant() throws {
        let (store, _) = try library()
        let staple = Staple(name: "Fixture rice", basis: .oz)
        try store.saveStaple(staple); try addPrice(store, staple: staple)
        let id = try XCTUnwrap(store.state.variants.first?.id)
        XCTAssertThrowsError(try store.recordPrice(stapleID: staple.id, variant: ProductVariant(store: .wegmans, name: "Fixture rice", quantity: 32, unit: .oz), reuseID: id, channel: .inStore, price: 4, available: true, observedAt: Date().addingTimeInterval(-30), conditions: "", sourceURL: nil, approveNew: true))
        XCTAssertEqual(store.state.observations.count, 1)
    }
    func testLocationChangeKeepsHistoryAndRemovesOldWinner() throws {
        let (store, _) = try library()
        let staple = Staple(name: "Fixture rice", basis: .oz)
        try store.saveStaple(staple); try addPrice(store, staple: staple)
        let oldContext = store.state.observations[0].locationID
        XCTAssertNotNil(ComparisonEngine.compare(state: store.state)[0].winner)
        try store.selectLocation(store: .wegmans, name: "Fixture other location", code: "134")
        XCTAssertEqual(store.state.observations[0].locationID, oldContext)
        XCTAssertNil(ComparisonEngine.compare(state: store.state)[0].winner)
        XCTAssertFalse(SourceCapability.forLocation(try XCTUnwrap(store.state.location(for: .wegmans)), channel: .inStore).isConnected)
    }
    func testSavedReportSurvivesStapleDeletionAndSameTimestampDropIsRetained() throws {
        let (store, container) = try library()
        let staple = Staple(name: "Fixture rice", basis: .oz)
        try store.saveStaple(staple)
        let when = Date().addingTimeInterval(-60)
        try addPrice(store, staple: staple, price: 6, when: when)
        let variantID = try XCTUnwrap(store.state.variants.first?.id)
        try addPrice(store, staple: staple, price: 4, reuseID: variantID, when: when)
        let request = ReportRequest(asOf: Date().addingTimeInterval(-1), stores: [.wegmans])
        let first = try store.report(request)
        XCTAssertEqual(first.priceDrops.count, 1)
        XCTAssertEqual(first.priceDrops.first?.amount, 2)
        try store.deleteStaple(staple.id)
        let same = try store.report(request)
        XCTAssertEqual(same.id, first.id)
        XCTAssertEqual(same.comparisons[0].staple.name, "Fixture rice")
        XCTAssertEqual(store.state.reports.count, 1)
        let reopened = try LibraryStore(context: ModelContext(container))
        XCTAssertTrue(reopened.state.staples.isEmpty)
        XCTAssertEqual(reopened.state.reports.first?.id, first.id)
    }
    func testInvalidEditsDoNotReplacePersistedLibrary() throws {
        let (store, container) = try library()
        try store.saveStaple(Staple(name: "Fixture rice", basis: .oz))
        XCTAssertThrowsError(try store.saveStaple(Staple(name: " ", basis: .oz)))
        XCTAssertThrowsError(try store.saveStaple(Staple(name: "Bad request", basis: .oz, desiredQuantity: 2, desiredUnit: .flOz)))
        XCTAssertEqual(store.state.staples.count, 1)
        XCTAssertEqual(try LibraryStore(context: ModelContext(container)).state.staples.count, 1)
    }
    func testEmptyRefreshDoesNotConsumeDailyClaim() async throws {
        let (store, _) = try library()
        await store.refresh()
        XCTAssertNil(store.state.lastRefreshDay)
        XCTAssertTrue(store.state.sourceRuns.isEmpty)
        XCTAssertNotNil(store.failure)
    }
    func testSavingUnchangedBlankStoreCodeDoesNotCreateAnotherContext() throws {
        let (store, _) = try library()
        let location = try XCTUnwrap(store.state.location(for: .hmart))
        let count = store.state.locations.count
        try store.selectLocation(store: .hmart, name: location.name, code: "")
        XCTAssertEqual(store.state.location(for: .hmart)?.id, location.id)
        XCTAssertEqual(store.state.locations.count, count)
    }
    func testNumericInputRejectsTrailingText() {
        XCTAssertNil(entryDecimal("12abc"))
        XCTAssertNil(entryDecimal("-1"))
        XCTAssertNil(entryDecimal("NaN"))
        XCTAssertEqual(entryDecimal("12"), 12)
    }
    func testUnknownLibrarySchemaFailsWithoutOverwritingData() throws {
        let (store, container) = try library()
        try store.saveStaple(Staple(name: "Fixture rice", basis: .oz))
        let context = ModelContext(container)
        let record = try XCTUnwrap(context.fetch(FetchDescriptor<SavedLibrary>()).first)
        let before = record.payload
        record.schemaVersion = 999; try context.save()
        XCTAssertThrowsError(try LibraryStore(context: ModelContext(container)))
        XCTAssertEqual(record.payload, before)
    }
}
