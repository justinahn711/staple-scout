import Foundation
import XCTest
@testable import StapleScoutKit

final class CoreTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func decimal(_ value: String) -> Decimal { Decimal(string: value)! }
    func fixture() -> LibraryState {
        let staple = Staple(name: "Rice", basis: .oz, desiredQuantity: 1, desiredUnit: .lb)
        let variant = ProductVariant(store: .wegmans, name: "Rice 1 lb", quantity: 1, unit: .lb)
        var state = LibraryState(staples: [staple], variants: [variant], matches: [.init(stapleID: staple.id, variantID: variant.id, status: .approved)])
        state.observations = [.init(sequence: 1, stapleID: staple.id, variantID: variant.id, locationID: state.location(for: .wegmans)!.id, channel: .inStore, price: 4, available: true, observedAt: now)]
        return state
    }
    func compare(_ state: LibraryState, channel: Channel = .inStore) -> StapleComparison {
        ComparisonEngine.compare(state: state, channel: channel, asOf: now)[0]
    }
    func request() -> ReportRequest { .init(asOf: now, stores: [.wegmans]) }

    func testDefaultLibraryContainsNoFabricatedEvidenceAndRoundTrips() throws {
        let empty = LibraryState()
        XCTAssertTrue(empty.staples.isEmpty)
        XCTAssertTrue(empty.variants.isEmpty)
        XCTAssertTrue(empty.observations.isEmpty)
        XCTAssertTrue(empty.reports.isEmpty)
        XCTAssertEqual(empty.locations.count, 5)
        var state = fixture()
        state.reports = [try ReportEngine.build(state: state, request: request(), generatedAt: now)]
        let restored = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.observations[0].price, 4)
        XCTAssertEqual(restored.location(for: .wegmans)?.id, state.location(for: .wegmans)?.id)
        XCTAssertEqual(restored.reports[0].id, state.reports[0].id)
        XCTAssertEqual(restored.reports[0].comparisons[0].winnerID, state.observations[0].id)
    }

    func testExplicitApprovalIsAuthoritative() {
        var state = fixture()
        XCTAssertNotNil(compare(state).winner)
        state.matches[0].status = .pending
        XCTAssertNil(compare(state).winner)
        XCTAssertTrue(compare(state).offers[0].exclusionReasons.contains("not_approved"))
        state.matches[0].status = .rejected
        XCTAssertTrue(compare(state).offers[0].exclusionReasons.contains("match_rejected"))
        state.matches = []
        XCTAssertNil(compare(state).winner)
    }

    func testLatestUnavailableUnknownOrConditionalSuppressesOlderCheapOfferIncludingTimestampTies() {
        for condition in 0..<3 {
            var state = fixture()
            var latest = state.observations[0]
            latest.id = UUID(); latest.sequence = 2
            if condition == 0 { latest.available = false }
            if condition == 1 { latest.available = nil; latest.price = nil }
            if condition == 2 { latest.conditions = "Requires membership" }
            state.observations.insert(latest, at: 0) // Array order cannot override sequence.
            let result = compare(state)
            XCTAssertNil(result.winner)
            XCTAssertEqual(result.offers.count, 1)
            XCTAssertEqual(result.offers.first?.id, latest.id)
        }
    }

    func testLocationPreferenceChangeDoesNotReuseOldContext() {
        var state = fixture()
        let old = state.location(for: .wegmans)!
        let replacement = StoreLocation(store: .wegmans, name: "New store", code: "42")
        state.locations.append(replacement)
        state.preferredLocations[.wegmans] = replacement.id
        XCTAssertTrue(compare(state).offers.isEmpty)
        XCTAssertEqual(state.observations[0].locationID, old.id)
        var new = state.observations[0]; new.id = UUID(); new.locationID = replacement.id; new.sequence = 2
        state.observations.append(new)
        XCTAssertEqual(compare(state).winner?.location.id, replacement.id)
    }

    func testDimensionsNeverCrossAndConversionsAreExact() {
        var state = fixture()
        XCTAssertEqual(compare(state).winner?.unitPrice, decimal("0.25"))
        state.variants[0].unit = .g; state.variants[0].quantity = decimal("453.59237")
        XCTAssertEqual(compare(state).winner?.unitPrice, decimal("0.25"))
        XCTAssertEqual(compare(state).winner?.outlay?.packages, 1)
        XCTAssertEqual(compare(state).winner?.outlay?.excess, 0)
        state.variants[0].unit = .flOz
        XCTAssertNil(compare(state).winner)
        XCTAssertTrue(compare(state).offers[0].exclusionReasons.contains("incompatible_dimension"))
        state.staples[0].basis = .each
        XCTAssertNil(compare(state).winner)
    }

    func testExactCeilingAroundMetricBoundaryAndMultipacks() {
        var state = fixture()
        state.variants[0].unit = .g; state.variants[0].quantity = 500
        state.staples[0].desiredUnit = .g
        for (need, count) in [("500", 1), ("500.0000000000000000001", 2), ("499.9999999999999999999", 1), ("1000", 2)] {
            state.staples[0].desiredQuantity = decimal(need)
            XCTAssertEqual(compare(state).winner?.outlay?.packages, count, need)
        }
        state.variants[0].packCount = 2
        XCTAssertEqual(compare(state).winner?.outlay?.packages, 1)
        XCTAssertEqual(compare(state).winner?.outlay?.cost, 4)
        state.staples[0].desiredQuantity = 0
        XCTAssertNil(compare(state).winner?.outlay)
        state.staples[0].desiredQuantity = 1; state.staples[0].desiredUnit = .l
        XCTAssertNil(compare(state).winner?.outlay)
    }

    func testUnitWinnerCanDifferFromWholePackageWinner() {
        var state = fixture()
        let smallID = state.variants[0].id
        let bulk = ProductVariant(store: .wegmans, name: "Bulk rice", quantity: 10, unit: .lb)
        state.variants.append(bulk)
        state.matches.append(.init(stapleID: state.staples[0].id, variantID: bulk.id, status: .approved))
        var observation = state.observations[0]; observation.id = UUID(); observation.variantID = bulk.id; observation.price = 20; observation.sequence = 2
        state.observations.append(observation)
        XCTAssertEqual(compare(state).winner?.variant.id, bulk.id)
        XCTAssertEqual(compare(state).outlayWinner?.variant.id, smallID)
        XCTAssertEqual(compare(state).outlayWinner?.outlay?.cost, 4)
    }

    func testFreshnessAndTermsAreConservativeAtBoundaries() {
        var state = fixture()
        state.observations[0].observedAt = now.addingTimeInterval(-48 * 3600 + 1)
        XCTAssertNotNil(compare(state).winner)
        state.observations[0].observedAt = now.addingTimeInterval(-48 * 3600)
        XCTAssertTrue(compare(state).offers[0].exclusionReasons.contains("stale"))
        state.observations[0].observedAt = now.addingTimeInterval(1)
        XCTAssertTrue(compare(state).offers[0].exclusionReasons.contains("future_observation"))
        state.observations[0].observedAt = now
        state.observations[0].validUntil = now
        XCTAssertTrue(compare(state).offers[0].exclusionReasons.contains("offer_expired"))
        state.observations[0].validUntil = nil; state.observations[0].validFrom = now.addingTimeInterval(1)
        XCTAssertTrue(compare(state).offers[0].exclusionReasons.contains("offer_not_started"))
        state.observations[0].validFrom = nil; state.observations[0].sourceExclusion = "source_product_changed"
        XCTAssertNil(compare(state).winner)
    }

    func testUncertainInvalidAndOverflowingQuantitiesCannotWinOrTrap() {
        for kind in [QuantityKind.estimated, .variable] {
            var state = fixture(); state.variants[0].quantityKind = kind
            XCTAssertNil(compare(state).winner)
        }
        var state = fixture(); state.variants[0].quantity = 0
        XCTAssertNil(compare(state).winner)
        state.variants[0].quantity = 1; state.variants[0].packCount = -1
        XCTAssertNil(compare(state).winner)
        state.variants[0].packCount = 1; state.observations[0].price = -1
        XCTAssertNil(compare(state).winner)
        state.observations[0].price = 4; state.staples[0].desiredQuantity = Decimal.greatestFiniteMagnitude
        XCTAssertNil(compare(state).winner?.outlay)
    }

    func testShelfPickupAndOnlineStaySeparate() {
        var state = fixture()
        var pickup = state.observations[0]; pickup.id = UUID(); pickup.channel = .pickup; pickup.price = 1; pickup.sequence = 2
        state.observations.append(pickup)
        XCTAssertEqual(compare(state).winner?.observation.price, 4)
        XCTAssertEqual(compare(state, channel: .pickup).winner?.observation.price, 1)
        pickup.id = UUID(); pickup.channel = .online; state.observations.append(pickup)
        XCTAssertNil(compare(state, channel: .online).winner)
        XCTAssertEqual(compare(state, channel: .online).offers.count, 3)
        XCTAssertEqual(compare(state).offers.count, 3)
        XCTAssertTrue(compare(state).offers.first { $0.observation.channel == .online }!.exclusionReasons.contains("online_reference_only"))
        XCTAssertTrue(ComparisonEngine.compare(state: state, stores: [.target], asOf: now)[0].offers.isEmpty)
        state.staples[0].needed = false
        XCTAssertTrue(ComparisonEngine.compare(state: state, neededOnly: true, asOf: now).isEmpty)
    }

    func testReportFiltersEvidenceNotKnownByCutoffBeforeSelectingLatest() throws {
        var state = fixture()
        var futureImport = state.observations[0]
        futureImport.id = UUID(); futureImport.sequence = 2; futureImport.source = .wegmans
        futureImport.observedAt = now.addingTimeInterval(-1); futureImport.retrievedAt = now.addingTimeInterval(1); futureImport.price = 1
        state.observations[0].observedAt = now.addingTimeInterval(-2)
        state.observations.append(futureImport)
        let report = try ReportEngine.build(state: state, request: request(), generatedAt: now)
        XCTAssertEqual(report.comparisons[0].winnerID, state.observations[0].id)
        state.observations[1].retrievedAt = nil
        XCTAssertEqual(try ReportEngine.build(state: state, request: request(), generatedAt: now).comparisons[0].winnerID, state.observations[0].id)
        state.observations[1].retrievedAt = now
        XCTAssertEqual(try ReportEngine.build(state: state, request: request(), generatedAt: now).comparisons[0].winnerID, futureImport.id)
    }

    func testSavedReportReusesFrozenSettingsAndContextsWithCanonicalRequest() throws {
        var state = fixture()
        let originalRequest = ReportRequest(asOf: now, stores: [.wegmans, .target])
        let original = try ReportEngine.build(state: state, request: originalRequest, generatedAt: now)
        state.reports.append(original)
        state.staples[0].name = "Changed"; state.staples[0].needed = false
        state.matches[0].status = .rejected; state.preferredLocations[.wegmans] = UUID()
        let reordered = ReportRequest(asOf: now, stores: Set([.target, .wegmans]))
        let reused = try ReportEngine.build(state: state, request: reordered, generatedAt: now.addingTimeInterval(100))
        XCTAssertEqual(reused.id, original.id)
        XCTAssertEqual(reused.generatedAt, now)
        XCTAssertEqual(reused.comparisons[0].staple.name, "Rice")
        XCTAssertNotNil(reused.comparisons[0].winner)
        XCTAssertEqual(reused.locations.count, 2)
    }

    func testPriceDropsUseTimestampThenSequenceAndRetainTraceability() throws {
        var state = fixture()
        var current = state.observations[0]; current.id = UUID(); current.sequence = 2; current.price = 3
        state.observations.insert(current, at: 0)
        let report = try ReportEngine.build(state: state, request: request(), generatedAt: now)
        XCTAssertEqual(report.priceDrops.count, 1)
        XCTAssertEqual(report.priceDrops[0].previousObservationID, state.observations[1].id)
        XCTAssertEqual(report.priceDrops[0].observationID, current.id)
        XCTAssertEqual(report.priceDrops[0].amount, 1)
    }

    func testPriceDropsNeverSkipUnknownUnavailableConditionalOrExcludedPriorEvidence() throws {
        for invalid in 0..<5 {
            var state = fixture()
            var middle = state.observations[0]; middle.id = UUID(); middle.sequence = 2
            if invalid == 0 { middle.available = false }
            if invalid == 1 { middle.available = nil }
            if invalid == 2 { middle.price = nil }
            if invalid == 3 { middle.conditions = "Coupon" }
            if invalid == 4 { middle.sourceExclusion = "source_product_changed" }
            var current = middle; current.id = UUID(); current.sequence = 3; current.price = 2; current.available = true; current.conditions = ""; current.sourceExclusion = nil
            state.observations += [middle, current]
            XCTAssertTrue(try ReportEngine.build(state: state, request: request(), generatedAt: now).priceDrops.isEmpty, "Invalid prior case \(invalid)")
        }
    }

    func testPriceDropDoesNotCrossSourceOrLocation() throws {
        var state = fixture()
        var current = state.observations[0]; current.id = UUID(); current.sequence = 2; current.price = 2; current.source = .wegmans; current.retrievedAt = now
        state.observations.append(current)
        XCTAssertTrue(try ReportEngine.build(state: state, request: request(), generatedAt: now).priceDrops.isEmpty)
        state.observations[0].source = .wegmans; state.observations[0].retrievedAt = now; state.observations[0].locationID = UUID()
        XCTAssertTrue(try ReportEngine.build(state: state, request: request(), generatedAt: now).priceDrops.isEmpty)
    }

    func testReportRejectsUnsupportedRequestsAndDoesNotLeakFutureRunCompletion() throws {
        var state = fixture()
        XCTAssertThrowsError(try ReportEngine.build(state: state, request: .init(asOf: now.addingTimeInterval(1), stores: [.wegmans]), generatedAt: now))
        XCTAssertThrowsError(try ReportEngine.build(state: state, request: .init(asOf: now, stores: []), generatedAt: now))
        XCTAssertThrowsError(try ReportEngine.build(state: state, request: .init(asOf: now, stores: [.wegmans], channel: .online), generatedAt: now))
        state.sourceRuns = [.init(store: .wegmans, locationID: state.location(for: .wegmans)!.id, channel: .inStore, attemptedAt: now.addingTimeInterval(-2), succeededAt: now.addingTimeInterval(1))]
        let report = try ReportEngine.build(state: state, request: request(), generatedAt: now)
        XCTAssertEqual(report.sourceRuns.count, 1)
        XCTAssertNil(report.sourceRuns[0].succeededAt)
    }

    func testReportExcludesEvidenceIngestedAfterCutoffAndAcceptsLegacyRetrievalTime() throws {
        var state = fixture()
        var imported = state.observations[0]
        imported.id = UUID(); imported.sequence = 2; imported.source = .wegmans
        imported.retrievedAt = now; imported.ingestedAt = now.addingTimeInterval(1); imported.price = 2
        state.observations.append(imported)
        XCTAssertEqual(try ReportEngine.build(state: state, request: request(), generatedAt: now).comparisons[0].winnerID, state.observations[0].id)
        XCTAssertNil(compare(state).winner)
        state.observations[1].ingestedAt = now
        XCTAssertEqual(try ReportEngine.build(state: state, request: request(), generatedAt: now).comparisons[0].winnerID, imported.id)
        state.observations[1].ingestedAt = nil
        XCTAssertEqual(try ReportEngine.build(state: state, request: request(), generatedAt: now).comparisons[0].winnerID, imported.id)
    }

    func testReportRedactsFutureFinishedAndUnfinishedFailuresButRetainsKnownFailure() throws {
        var state = fixture()
        let locationID = state.location(for: .wegmans)!.id
        state.sourceRuns = [
            .init(store: .wegmans, locationID: locationID, channel: .inStore, attemptedAt: now.addingTimeInterval(-2), error: "Later failure", finishedAt: now.addingTimeInterval(1)),
            .init(store: .wegmans, locationID: locationID, channel: .inStore, attemptedAt: now.addingTimeInterval(-2), error: "Unknown completion"),
            .init(store: .wegmans, locationID: locationID, channel: .inStore, attemptedAt: now.addingTimeInterval(-2), error: "Known failure", finishedAt: now),
            .init(store: .wegmans, locationID: locationID, channel: .inStore, attemptedAt: now.addingTimeInterval(-2), succeededAt: now, finishedAt: now)
        ]
        let runs = try ReportEngine.build(state: state, request: request(), generatedAt: now).sourceRuns
        XCTAssertEqual(runs.count, 4)
        XCTAssertNil(runs[0].error); XCTAssertNil(runs[0].finishedAt)
        XCTAssertNil(runs[1].error); XCTAssertNil(runs[1].finishedAt)
        XCTAssertEqual(runs[2].error, "Known failure"); XCTAssertEqual(runs[2].finishedAt, now)
        XCTAssertEqual(runs[3].succeededAt, now)
    }

    func testPriorImportedDropUsesOfferTermsAndCutoffNotRetrievalAtSourceTime() throws {
        var state = fixture()
        state.observations[0].observedAt = now.addingTimeInterval(-3600)
        state.observations[0].source = .wegmans
        state.observations[0].retrievedAt = now.addingTimeInterval(-300)
        state.observations[0].ingestedAt = now.addingTimeInterval(-200)
        var current = state.observations[0]
        current.id = UUID(); current.sequence = 2; current.price = 2
        current.observedAt = now; current.retrievedAt = now; current.ingestedAt = now
        state.observations.append(current)
        let drops = try ReportEngine.build(state: state, request: request(), generatedAt: now).priceDrops
        XCTAssertEqual(drops.count, 1)
        XCTAssertEqual(drops.first?.previousObservationID, state.observations[0].id)
    }

    func testOptionalEvidenceTimestampsDecodeFromLegacyPayloads() throws {
        let state = fixture()
        let encodedObservation = try JSONEncoder().encode(state.observations[0])
        var observationJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedObservation) as? [String: Any])
        observationJSON.removeValue(forKey: "ingestedAt")
        let observation = try JSONDecoder().decode(PriceObservation.self, from: JSONSerialization.data(withJSONObject: observationJSON))
        XCTAssertNil(observation.ingestedAt)
        let run = SourceRun(store: .wegmans, locationID: state.location(for: .wegmans)!.id, channel: .inStore, attemptedAt: now)
        var runJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as? [String: Any])
        runJSON.removeValue(forKey: "finishedAt")
        let restored = try JSONDecoder().decode(SourceRun.self, from: JSONSerialization.data(withJSONObject: runJSON))
        XCTAssertNil(restored.finishedAt)
    }

}
