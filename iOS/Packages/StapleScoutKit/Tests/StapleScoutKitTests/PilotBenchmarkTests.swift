import Foundation
import XCTest
@testable import StapleScoutKit

/// Opt-in offline benchmark specifications; none of these resources seed an app library.
final class PilotBenchmarkTests: XCTestCase {
    private func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private func decimal(_ string: String) throws -> Decimal {
        XCTAssertNotNil(string.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression))
        let value = try XCTUnwrap(Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")))
        XCTAssertFalse(value.isNaN)
        return value
    }

    func testCatalogIsFrozenProvisionalCompleteAndDimensionallyCoherent() throws {
        let catalog = try load("pilot-catalog", as: PilotCatalog.self)
        XCTAssertEqual(catalog.schemaVersion, 1)
        XCTAssertEqual(catalog.catalogID, "chantilly-40-v1")
        XCTAssertEqual(catalog.fixtureKind, "provisional_benchmark_definition")
        XCTAssertFalse(catalog.personalPreferences)
        XCTAssertTrue(catalog.sampleOnly)
        XCTAssertFalse(catalog.retailerFetchesAllowed)
        XCTAssertEqual(catalog.items.count, 40)
        XCTAssertEqual(catalog.items.map(\.id), (1...40).map { String(format: "P%03d", $0) })
        XCTAssertEqual(Set(catalog.items.map(\.name)).count, 40)
        XCTAssertEqual(Set(catalog.items.map(\.basis)), Set([.oz, .flOz, .each]))
        XCTAssertEqual(catalog.items.filter { $0.package.quantityKind == .fixed }.count, 37)
        XCTAssertEqual(catalog.items.filter { $0.package.quantityKind == .variable }.count, 2)
        XCTAssertEqual(catalog.items.filter { $0.package.quantityKind == .estimated }.count, 1)

        for item in catalog.items {
            XCTAssertFalse(item.category.isEmpty, item.id)
            XCTAssertFalse(item.package.specification.isEmpty, item.id)
            XCTAssertGreaterThan(try decimal(item.package.quantity), 0, item.id)
            XCTAssertGreaterThan(try decimal(item.desiredAmount.quantity), 0, item.id)
            XCTAssertGreaterThan(item.package.packCount, 0, item.id)
            XCTAssertEqual(item.package.unit.basis, item.basis, item.id)
            XCTAssertEqual(item.desiredAmount.unit.basis, item.basis, item.id)
            XCTAssertEqual(item.package.quantityMeaning, item.package.quantityKind == .fixed
                ? "exact_net_per_pack" : "nominal_weight_reference_not_exact_package", item.id)
            XCTAssertEqual(item.substitutionRule.brandPolicy, "store_or_name_brand_after_explicit_review", item.id)
            XCTAssertEqual(item.substitutionRule.requiredSpecification, item.package.specification, item.id)
            XCTAssertFalse(item.substitutionRule.packageSizeChangeAllowed, item.id)
            XCTAssertFalse(item.substitutionRule.automaticApproval, item.id)
        }
    }

    func testContextsAndDenominatorsDoNotHideDisconnectedOrReferenceOnlyStores() throws {
        let catalog = try load("pilot-catalog", as: PilotCatalog.self)
        XCTAssertEqual(Set(catalog.contexts.map(\.store)), Set(StoreID.allCases))
        XCTAssertEqual(catalog.contexts.count, 5)
        for context in catalog.contexts {
            XCTAssertEqual(context.storeCode, StoreLocation.defaults.first { $0.store == context.store }?.code)
            XCTAssertEqual(context.publicAccessStatus, "unapproved")
            XCTAssertFalse(context.evidenceLimit.isEmpty)
            XCTAssertTrue(Set(context.nativeSupportedChannels).isSubset(of: Set(context.requestedChannels)))
        }
        let reference = try XCTUnwrap(catalog.contexts.first { $0.store == .hmart })
        XCTAssertNil(reference.storeCode)
        XCTAssertFalse(reference.localComparisonCandidate)
        XCTAssertEqual(reference.requestedChannels, [.online])
        XCTAssertEqual(catalog.contexts.first { $0.store == .lidl }?.region, "US1112")
        let coverage = catalog.coverage
        XCTAssertEqual(Set(coverage.localModes), Set([.inStore, .pickup]))
        XCTAssertEqual(Set(coverage.localStores), Set([.wegmans, .walmart, .target, .lidl]))
        XCTAssertEqual(Set(coverage.mandatoryStores), Set([.walmart, .target]))
        XCTAssertEqual(coverage.itemsPerStore, catalog.items.count)
        XCTAssertEqual(coverage.localCellsPerMode, catalog.items.count * coverage.localStores.count)
        XCTAssertEqual(coverage.localCellsTotal, coverage.localCellsPerMode * coverage.localModes.count)
        XCTAssertEqual(coverage.referenceCells, catalog.items.count)
        XCTAssertEqual(coverage.minimumComparableStores, 2)
        XCTAssertEqual(coverage.minimumEligibleItemsPerMandatoryStore, 32)
        XCTAssertEqual(coverage.minimumJointlyComparableItems, 28)
        XCTAssertEqual(coverage.minimumEligibleLocalCellsInPrimaryMode, 64)
        XCTAssertEqual(coverage.criticalEvidenceAccuracyPercent, 100)
        XCTAssertEqual(coverage.packagePriceAccuracyPercent, 100)
        XCTAssertEqual(coverage.minimumIndependentSpotChecksPerMandatoryStore, 10)
        XCTAssertEqual(coverage.liveRunsRequired, 2)
    }

    func testHistoricalIdentityReferencesRemainTraceableWithoutBecomingLiveEvidence() throws {
        let catalog = try load("pilot-catalog", as: PilotCatalog.self)
        let references = catalog.items.flatMap(\.identityReferences)
        XCTAssertEqual(references.count, 3)
        for reference in references {
            XCTAssertEqual(reference.status, "historical_committed_fixture_not_current_validation")
            let url = try XCTUnwrap(Bundle.module.url(
                forResource: (reference.evidenceFile as NSString).deletingPathExtension, withExtension: "json"))
            let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            if reference.store == .wegmans {
                let rows = try XCTUnwrap(raw as? [[String: Any]])
                let source = try XCTUnwrap(rows.first { $0["productID"] as? String == reference.productID })
                let barcode = try XCTUnwrap(reference.barcode)
                XCTAssertTrue((source["upc"] as? [String])?.contains(barcode) == true)
                XCTAssertTrue(barcode.hasPrefix("0"))
            } else {
                XCTAssertEqual(reference.store, .hmart)
                let root = try XCTUnwrap(raw as? [String: Any])
                let products = try XCTUnwrap(root["products"] as? [[String: Any]])
                let identities = products.flatMap { product -> [String] in
                    guard let productID = product["productId"] as? String,
                          let skus = product["items"] as? [[String: Any]] else { return [] }
                    return skus.compactMap { ($0["itemId"] as? String).map { productID + ":" + $0 } }
                }
                XCTAssertTrue(identities.contains(reference.productID))
                // The existing H Mart fixture's zero-padded test EAN is not a verified retail barcode.
                XCTAssertNil(reference.barcode)
            }
        }
    }

    func testSyntheticAdversarialCasesUseTheShippingComparisonEngine() throws {
        let fixture = try load("pilot-comparison-cases", as: PilotCases.self)
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(fixture.fixtureKind, "synthetic_offline_comparison")
        XCTAssertTrue(fixture.sampleOnly)
        XCTAssertFalse(fixture.retailerFetchesAllowed)
        XCTAssertEqual(fixture.cases.count, 24)
        XCTAssertEqual(Set(fixture.cases.map(\.id)).count, fixture.cases.count)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: fixture.asOf))

        for entry in fixture.cases {
            let input = entry.offer
            XCTAssertTrue(input.productID.hasPrefix("fixture-only-"), entry.id)
            XCTAssertEqual(URL(string: input.sourceURL)?.host, "fixtures.invalid", entry.id)
            XCTAssertEqual(input.barcode, "00000000000000", entry.id)
            let staple = Staple(name: "SYNTHETIC: " + entry.id, basis: entry.stapleBasis,
                desiredQuantity: try decimal(entry.desiredQuantity), desiredUnit: entry.desiredUnit)
            let variant = ProductVariant(store: input.store, productID: input.productID,
                barcode: input.barcode, name: "SYNTHETIC: " + entry.id,
                quantity: try decimal(input.quantity), unit: input.unit,
                packCount: input.packCount, quantityKind: input.quantityKind)
            var state = LibraryState(staples: [staple], variants: [variant], matches: [
                .init(stapleID: staple.id, variantID: variant.id, status: input.matchStatus)
            ])
            var observedLocation = try XCTUnwrap(state.location(for: input.store))
            if input.locationCode != observedLocation.code {
                observedLocation = .init(store: input.store, name: "SYNTHETIC other location", code: input.locationCode)
                state.locations.append(observedLocation)
            }
            let observation = PriceObservation(sequence: 1, stapleID: staple.id, variantID: variant.id,
                locationID: observedLocation.id, channel: input.channel,
                price: try input.price.map(decimal), available: input.available,
                observedAt: now.addingTimeInterval(input.observedOffsetSeconds),
                retrievedAt: now.addingTimeInterval(input.retrievedOffsetSeconds),
                conditions: input.conditions, source: input.source, sourceURL: input.sourceURL,
                validFrom: input.validFromOffsetSeconds.map { now.addingTimeInterval($0) },
                validUntil: input.validUntilOffsetSeconds.map { now.addingTimeInterval($0) })
            state.observations = [observation]
            let result = try XCTUnwrap(ComparisonEngine.compare(state: state,
                channel: entry.comparisonChannel, stores: Set(entry.plannedStores), asOf: now).first)
            XCTAssertEqual(result.offers.count, entry.expected.offerCount, entry.id)
            XCTAssertEqual(result.winnerID, entry.expected.winner ? observation.id : nil, entry.id)
            if let offer = result.offers.first {
                XCTAssertEqual(offer.eligible, entry.expected.eligible, entry.id)
                XCTAssertEqual(Set(offer.exclusionReasons), Set(entry.expected.exclusionReasons), entry.id)
                if let unitPrice = entry.expected.unitPrice {
                    XCTAssertEqual(offer.unitPrice, try decimal(unitPrice), entry.id)
                }
                if let packages = entry.expected.packagesNeeded {
                    XCTAssertEqual(offer.outlay?.packages, packages, entry.id)
                    XCTAssertEqual(offer.outlay?.cost, try entry.expected.purchaseCost.map(decimal), entry.id)
                    XCTAssertEqual(offer.outlay?.excess, try entry.expected.excessQuantity.map(decimal), entry.id)
                    XCTAssertEqual(offer.outlay?.unit, entry.expected.excessUnit, entry.id)
                } else {
                    XCTAssertNil(offer.outlay, entry.id)
                }
            }
        }
    }

    func testSyntheticPartialCoverageRetainsTheFull160CellDenominator() throws {
        let catalog = try load("pilot-catalog", as: PilotCatalog.self)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-20T12:00:00Z"))
        let staples = try catalog.items.map { item in
            Staple(name: "SYNTHETIC: " + item.id, basis: item.basis,
                desiredQuantity: try decimal(item.desiredAmount.quantity), desiredUnit: item.desiredAmount.unit)
        }
        var state = LibraryState(staples: staples)
        let fixed = catalog.items.indices.filter { catalog.items[$0].package.quantityKind == .fixed }
        let selections: [(StoreID, [Int])] = [(.walmart, Array(fixed.prefix(32))),
            (.target, Array(fixed.prefix(28)) + Array(fixed.dropFirst(32).prefix(4)))]
        for (store, selected) in selections {
            for index in selected {
                let item = catalog.items[index]
                let variant = ProductVariant(store: store, productID: "fixture-only-" + item.id,
                    name: "SYNTHETIC: " + item.name, quantity: try decimal(item.package.quantity),
                    unit: item.package.unit, packCount: item.package.packCount)
                state.variants.append(variant)
                state.matches.append(.init(stapleID: staples[index].id, variantID: variant.id, status: .approved))
                state.observations.append(.init(sequence: state.observations.count + 1,
                    stapleID: staples[index].id, variantID: variant.id,
                    locationID: try XCTUnwrap(state.location(for: store)).id, channel: .inStore,
                    price: 4, available: true, observedAt: now, source: .manual,
                    sourceURL: "https://fixtures.invalid/coverage/" + item.id))
            }
        }
        let results = ComparisonEngine.compare(state: state, channel: .inStore,
            stores: Set(catalog.coverage.localStores), asOf: now)
        let eligible = results.flatMap(\.offers).filter(\.eligible)
        XCTAssertEqual(results.count, 40)
        XCTAssertEqual(eligible.filter { $0.variant.store == .walmart }.count, 32)
        XCTAssertEqual(eligible.filter { $0.variant.store == .target }.count, 32)
        XCTAssertEqual(results.filter { Set($0.offers.filter(\.eligible).map { $0.variant.store }).count >= 2 }.count, 28)
        let denominator = results.count * catalog.coverage.localStores.count
        XCTAssertEqual(denominator, 160)
        XCTAssertEqual(eligible.count, 64)
        XCTAssertEqual(denominator - eligible.count, 96)
        // This is 40% coverage, not 100% of the returned observations. It proves arithmetic, not access approval.
        XCTAssertEqual(Decimal(eligible.count) / Decimal(denominator), Decimal(string: "0.4"))
        XCTAssertTrue(LibraryState().staples.isEmpty)
        XCTAssertTrue(LibraryState().observations.isEmpty)
    }
}

private struct PilotCatalog: Decodable {
    let schemaVersion: Int
    let catalogID, fixtureKind: String
    let personalPreferences, sampleOnly, retailerFetchesAllowed: Bool
    let contexts: [PilotContext]
    let coverage: PilotCoverage
    let items: [PilotItem]
}
private struct PilotContext: Decodable {
    let store: StoreID
    let storeCode, region: String?
    let requestedChannels, nativeSupportedChannels: [Channel]
    let localComparisonCandidate: Bool
    let publicAccessStatus, evidenceLimit: String
}
private struct PilotCoverage: Decodable {
    let localModes: [Channel]
    let localStores, mandatoryStores: [StoreID]
    let itemsPerStore, localCellsPerMode, localCellsTotal, referenceCells: Int
    let minimumComparableStores, minimumEligibleItemsPerMandatoryStore: Int
    let minimumJointlyComparableItems, minimumEligibleLocalCellsInPrimaryMode: Int
    let criticalEvidenceAccuracyPercent, packagePriceAccuracyPercent: Int
    let minimumIndependentSpotChecksPerMandatoryStore, liveRunsRequired: Int
}
private struct PilotItem: Decodable {
    let id, category, name: String
    let basis: MeasureUnit
    let package: PilotPackage
    let desiredAmount: PilotAmount
    let substitutionRule: PilotSubstitution
    let identityReferences: [PilotIdentity]
}
private struct PilotPackage: Decodable {
    let quantity: String
    let unit: MeasureUnit
    let packCount: Int
    let quantityKind: QuantityKind
    let quantityMeaning, specification: String
}
private struct PilotAmount: Decodable { let quantity: String; let unit: MeasureUnit }
private struct PilotSubstitution: Decodable {
    let brandPolicy, requiredSpecification: String
    let packageSizeChangeAllowed, automaticApproval: Bool
}
private struct PilotIdentity: Decodable {
    let store: StoreID
    let productID: String
    let barcode: String?
    let evidenceFile, status: String
}
private struct PilotCases: Decodable {
    let schemaVersion: Int
    let fixtureKind, asOf: String
    let sampleOnly, retailerFetchesAllowed: Bool
    let cases: [PilotCase]
}
private struct PilotCase: Decodable {
    let id: String
    let stapleBasis, desiredUnit: MeasureUnit
    let desiredQuantity: String
    let comparisonChannel: Channel
    let plannedStores: [StoreID]
    let offer: PilotOffer
    let expected: PilotExpectation
}
private struct PilotOffer: Decodable {
    let id, productID, barcode, quantity: String
    let store: StoreID
    let locationCode: String?
    let unit: MeasureUnit
    let packCount: Int
    let quantityKind: QuantityKind
    let channel: Channel
    let price: String?
    let available: Bool?
    let observedOffsetSeconds, retrievedOffsetSeconds: TimeInterval
    let validFromOffsetSeconds, validUntilOffsetSeconds: TimeInterval?
    let conditions, sourceURL: String
    let source: SourceID
    let matchStatus: MatchStatus
}
private struct PilotExpectation: Decodable {
    let offerCount: Int
    let eligible, winner: Bool
    let exclusionReasons: [String]
    let unitPrice: String?
    let packagesNeeded: Int?
    let purchaseCost, excessQuantity: String?
    let excessUnit: MeasureUnit?
}
