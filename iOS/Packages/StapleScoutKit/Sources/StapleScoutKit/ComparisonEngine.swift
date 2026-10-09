import Foundation

public enum ComparisonEngine {
    public static func compare(state: LibraryState, channel: Channel = .inStore, stores: Set<StoreID> = Set(StoreID.allCases), neededOnly: Bool = false, asOf: Date = Date()) -> [StapleComparison] {
        state.staples.filter { !neededOnly || $0.needed }.map { staple in
            var latest: [String: PriceObservation] = [:]
            for observation in state.observations where observation.stapleID == staple.id {
                guard let variant = state.variants.first(where: { $0.id == observation.variantID }), stores.contains(variant.store),
                      let location = state.location(for: variant.store), observation.locationID == location.id else { continue }
                let key = variant.id.uuidString + ":" + observation.channel.rawValue
                if let previous = latest[key], !precedes(previous, observation) { continue }
                latest[key] = observation
            }
            let offers = latest.values.sorted { $0.id.uuidString < $1.id.uuidString }.compactMap { observation -> OfferResult? in
                guard let variant = state.variants.first(where: { $0.id == observation.variantID }), let location = state.location(for: variant.store) else { return nil }
                let matches = state.matches.filter { $0.stapleID == staple.id && $0.variantID == variant.id }
                var reasons = evidenceExclusions(observation, asOf: asOf)
                if matches.isEmpty || matches.contains(where: { $0.status != .approved }) {
                    reasons.append(matches.contains(where: { $0.status == .rejected }) ? "match_rejected" : "not_approved")
                }
                if channel == .online || observation.channel == .online { reasons.append("online_reference_only") }
                if observation.channel != channel { reasons.append(channel == .inStore ? "not_in_store" : "not_" + channel.rawValue) }
                if variant.quantityKind != .fixed { reasons.append("uncertain_quantity") }
                if variant.unit.basis != staple.basis.basis { reasons.append("incompatible_dimension") }
                let normalized = unitPrice(observation: observation, variant: variant, basis: staple.basis)
                if normalized == nil && !reasons.contains("incompatible_dimension") { reasons.append("invalid_price_or_quantity") }
                let outlay = reasons.isEmpty ? packageOutlay(observation: observation, variant: variant, staple: staple) : nil
                return OfferResult(observation: observation, variant: variant, location: location, unitPrice: normalized, exclusionReasons: reasons, outlay: outlay)
            }
            let eligible = offers.filter(\.eligible)
            let winner = eligible.min { a, b in
                a.unitPrice! == b.unitPrice! ? a.id.uuidString < b.id.uuidString : a.unitPrice! < b.unitPrice!
            }
            let outlayWinner = eligible.filter { $0.outlay != nil }.min { a, b in
                a.outlay!.cost == b.outlay!.cost ? a.id.uuidString < b.id.uuidString : a.outlay!.cost < b.outlay!.cost
            }
            return StapleComparison(staple: staple, offers: offers, winnerID: winner?.id, outlayWinnerID: outlayWinner?.id)
        }
    }

    /// Time and sequence are the evidence ordering. UUID only resolves malformed duplicate sequences deterministically.
    static func precedes(_ lhs: PriceObservation, _ rhs: PriceObservation) -> Bool {
        if lhs.observedAt != rhs.observedAt { return lhs.observedAt < rhs.observedAt }
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    static func evidenceExclusions(_ observation: PriceObservation, asOf: Date) -> [String] {
        var reasons: [String] = []
        if let exclusion = observation.sourceExclusion, !exclusion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reasons.append(exclusion) }
        if let from = observation.validFrom, asOf < from { reasons.append("offer_not_started") }
        if let until = observation.validUntil, asOf >= until { reasons.append("offer_expired") }
        if observation.available == nil { reasons.append("availability_unknown") }
        else if observation.available == false { reasons.append("unavailable") }
        if let price = observation.price {
            if price.isNaN || price < 0 { reasons.append("invalid_price") }
        } else { reasons.append("price_unknown") }
        let age = asOf.timeIntervalSince(observation.observedAt)
        if age < 0 { reasons.append("future_observation") }
        else if age >= 48 * 60 * 60 { reasons.append("stale") }
        if let retrieved = observation.retrievedAt, retrieved > asOf { reasons.append("future_retrieval") }
        if let ingested = observation.ingestedAt, ingested > asOf { reasons.append("future_ingestion") }
        if observation.source != .manual && observation.retrievedAt == nil { reasons.append("retrieval_time_unknown") }
        if !observation.conditions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reasons.append("conditional_price") }
        if observation.source == .hmart && observation.channel != .online { reasons.append("online_reference_only") }
        return reasons
    }

    static func unitPrice(observation: PriceObservation, variant: ProductVariant, basis: MeasureUnit) -> Decimal? {
        guard variant.unit.basis == basis.basis,
              let price = observation.price, !price.isNaN, price >= 0,
              let package = packageBaseQuantity(variant),
              let numerator = exactProduct(price, basis.baseFactor) else { return nil }
        return quotient(numerator, package)
    }

    static func packageBaseQuantity(_ variant: ProductVariant) -> Decimal? {
        guard !variant.quantity.isNaN, variant.quantity > 0, variant.packCount > 0,
              let packed = exactProduct(variant.quantity, Decimal(variant.packCount)),
              let total = exactProduct(packed, variant.unit.baseFactor), total > 0 else { return nil }
        return total
    }

    static func packageOutlay(observation: PriceObservation, variant: ProductVariant, staple: Staple) -> PackageOutlay? {
        guard variant.quantityKind == .fixed, let desired = staple.desiredQuantity, !desired.isNaN, desired > 0,
              let unit = staple.desiredUnit, unit.basis == staple.basis.basis, variant.unit.basis == unit.basis,
              let price = observation.price, !price.isNaN, price >= 0,
              let package = packageBaseQuantity(variant), let need = exactProduct(desired, unit.baseFactor),
              var ratio = quotient(need, package), ratio <= Decimal(Int.max) else { return nil }
        var floor = Decimal()
        NSDecimalRound(&floor, &ratio, 0, .down)
        // Correct the divided value using exact products before applying the ceiling.
        // This prevents a rounded quotient at a package boundary from adding a package.
        guard var total = exactProduct(floor, package) else { return nil }
        if total > need { floor -= 1; guard let corrected = exactProduct(floor, package) else { return nil }; total = corrected }
        let count = total < need ? floor + 1 : floor
        guard count > 0, count <= Decimal(Int.max), let purchased = exactProduct(count, package), purchased >= need,
              let excessBase = exactDifference(purchased, need), let excess = quotient(excessBase, unit.baseFactor),
              let cost = exactProduct(price, count) else { return nil }
        return PackageOutlay(packages: NSDecimalNumber(decimal: count).intValue, cost: cost, excess: excess, unit: unit)
    }

    static func exactProduct(_ a: Decimal, _ b: Decimal) -> Decimal? {
        var a = a, b = b, result = Decimal()
        guard NSDecimalMultiply(&result, &a, &b, .plain) == .noError, !result.isNaN else { return nil }
        return result
    }
    static func exactDifference(_ a: Decimal, _ b: Decimal) -> Decimal? {
        var a = a, b = b, result = Decimal()
        guard NSDecimalSubtract(&result, &a, &b, .plain) == .noError, !result.isNaN else { return nil }
        return result
    }
    static func quotient(_ a: Decimal, _ b: Decimal) -> Decimal? {
        var a = a, b = b, result = Decimal()
        let error = NSDecimalDivide(&result, &a, &b, .plain)
        guard error == .noError || error == .lossOfPrecision, !result.isNaN else { return nil }
        return result
    }
}
