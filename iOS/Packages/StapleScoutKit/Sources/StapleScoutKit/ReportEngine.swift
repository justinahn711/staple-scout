import Foundation

public enum ReportError: Error, Equatable, LocalizedError {
    case futureCutoff, emptyStores, onlineChannel
    public var errorDescription: String? {
        switch self {
        case .futureCutoff: return "The report cutoff cannot be in the future."
        case .emptyStores: return "Choose at least one store for the report."
        case .onlineChannel: return "Online reference prices cannot rank in a shopping report."
        }
    }
}

public enum ReportEngine {
    public static func build(state: LibraryState, request: ReportRequest, generatedAt: Date = Date()) throws -> WeeklyReport {
        guard request.asOf <= generatedAt else { throw ReportError.futureCutoff }
        guard !request.stores.isEmpty else { throw ReportError.emptyStores }
        guard request.channel != .online else { throw ReportError.onlineChannel }
        if let saved = state.reports.first(where: { $0.request == request }) { return saved }
        // Snapshots freeze current requirements, approval decisions and selected contexts
        // at first generation. The cutoff scopes evidence, not historical user settings.
        var scoped = state
        scoped.observations = state.observations.filter { observation in
            guard observation.observedAt <= request.asOf else { return false }
            if let ingested = observation.ingestedAt, ingested > request.asOf { return false }
            if let retrieved = observation.retrievedAt {
                return retrieved <= request.asOf && (observation.ingestedAt ?? retrieved) <= request.asOf
            }
            return observation.source == .manual
        }
        let comparisons = ComparisonEngine.compare(state: scoped, channel: request.channel, stores: request.stores, neededOnly: request.neededOnly, asOf: request.asOf)
        var drops: [PriceDrop] = []
        for comparison in comparisons {
            for current in comparison.offers where current.eligible {
                let observation = current.observation
                // Select the immediately preceding evidence before checking its quality.
                // Unavailable/conditional/unknown entries therefore cannot be skipped.
                let prior = scoped.observations.filter {
                    $0.stapleID == observation.stapleID && $0.variantID == observation.variantID &&
                    $0.locationID == observation.locationID && $0.channel == observation.channel &&
                    $0.source == observation.source && ComparisonEngine.precedes($0, observation)
                }.max(by: ComparisonEngine.precedes)
                guard let prior, let previousPrice = prior.price, let price = observation.price,
                      previousPrice > price,
                      previousEvidenceIsEligible(prior) else { continue }
                drops.append(PriceDrop(stapleName: comparison.staple.name, productName: current.variant.name, previousObservationID: prior.id, observationID: observation.id, previousPrice: previousPrice, price: price))
            }
        }
        let locations = StoreID.allCases.filter { request.stores.contains($0) }.compactMap { state.location(for: $0) }
        let runs = state.sourceRuns.filter {
            request.stores.contains($0.store) && $0.locationID == state.preferredLocations[$0.store] &&
            $0.channel == request.channel && $0.attemptedAt <= request.asOf
        }.map { run -> SourceRun in
            var result = run
            // A later completion must not leak a future success/error into the snapshot.
            if run.finishedAt == nil || run.finishedAt! > request.asOf {
                result.finishedAt = nil; result.succeededAt = nil; result.error = nil
            } else if let succeeded = run.succeededAt, succeeded > request.asOf {
                result.succeededAt = nil
            }
            return result
        }
        return WeeklyReport(request: request, generatedAt: generatedAt, comparisons: comparisons, priceDrops: drops, locations: locations, sourceRuns: runs)
    }

    private static func previousEvidenceIsEligible(_ observation: PriceObservation) -> Bool {
        // Prior imports can legitimately be retrieved after their source timestamp.
        // Retrieval cutoff was checked above; offer terms must hold at observation time.
        var originalTerms = observation
        originalTerms.retrievedAt = nil
        originalTerms.ingestedAt = nil
        originalTerms.source = .manual
        return ComparisonEngine.evidenceExclusions(originalTerms, asOf: observation.observedAt).isEmpty
    }
}
