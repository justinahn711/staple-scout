import Foundation
import Observation
import SwiftData
import StapleScoutKit

@Model final class SavedLibrary {
    @Attribute(.unique) var key: String
    var schemaVersion: Int
    var payload: Data
    init(payload: Data) { key = "library"; schemaVersion = 1; self.payload = payload }
}

struct LibraryError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor @Observable final class LibraryStore {
    private(set) var state: LibraryState
    private(set) var refreshing = false
    var notice: String?
    var failure: String?
    private let context: ModelContext
    private var record: SavedLibrary
    private let client: RetailClient

    init(context: ModelContext, client: RetailClient = RetailClient()) throws {
        self.context = context; self.client = client
        let records = try context.fetch(FetchDescriptor<SavedLibrary>())
        guard records.count <= 1 else { throw LibraryError(message: "More than one library was found. Your data has been preserved; reopen the app or restore a backup.") }
        if let saved = records.first {
            guard saved.schemaVersion == 1 else { throw LibraryError(message: "This library needs a newer version of Staple Scout. Your data has been preserved.") }
            state = try JSONDecoder().decode(LibraryState.self, from: saved.payload)
            record = saved
        } else {
            let initial = LibraryState()
            state = initial
            record = SavedLibrary(payload: try JSONEncoder().encode(initial))
            context.insert(record)
            try context.save()
        }
        context.autosaveEnabled = false
    }

    private func update(_ change: (inout LibraryState) throws -> Void) throws {
        var next = state
        try change(&next)
        let data = try JSONEncoder().encode(next)
        record.payload = data
        do { try context.save(); state = next }
        catch { context.rollback(); throw LibraryError(message: "Couldn’t save your change. Your previous library is intact. Free some device storage and try again.") }
    }

    func saveStaple(_ staple: Staple) throws {
        let name = staple.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200 else { throw LibraryError(message: "Enter a staple name up to 200 characters.") }
        guard [.oz, .flOz, .each].contains(staple.basis) else { throw LibraryError(message: "Choose weight, volume, or count.") }
        guard (staple.desiredQuantity == nil) == (staple.desiredUnit == nil),
              staple.desiredQuantity.map({ $0 > 0 && $0 <= 1_000_000 && !$0.isNaN }) ?? true,
              staple.desiredUnit.map({ $0.basis == staple.basis }) ?? true else { throw LibraryError(message: "Enter a positive requested amount in a compatible unit, or leave it blank.") }
        try update { next in
            var cleaned = staple; cleaned.name = name
            if let index = next.staples.firstIndex(where: { $0.id == staple.id }) {
                let old = next.staples[index]
                if old.name != cleaned.name || old.basis != cleaned.basis || old.rules != cleaned.rules {
                    for i in next.matches.indices where next.matches[i].stapleID == staple.id { next.matches[i].status = .pending }
                }
                next.staples[index] = cleaned
            } else {
                guard next.staples.count < 50 else { throw LibraryError(message: "This version supports up to 50 staples. Edit your existing list before adding another.") }
                next.staples.append(cleaned)
            }
        }
    }

    func setNeeded(_ id: UUID, needed: Bool) throws {
        try update { state in if let i = state.staples.firstIndex(where: { $0.id == id }) { state.staples[i].needed = needed } }
    }

    func deleteStaple(_ id: UUID) throws {
        try update { next in
            next.staples.removeAll { $0.id == id }
            next.matches.removeAll { $0.stapleID == id }
            next.observations.removeAll { $0.stapleID == id }
            // Frozen reports are value snapshots and retain their original evidence.
        }
    }

    func review(stapleID: UUID, variantID: UUID, status: MatchStatus) throws {
        try update { next in
            guard next.staples.contains(where: { $0.id == stapleID }), next.variants.contains(where: { $0.id == variantID }) else { throw LibraryError(message: "This product or staple no longer exists. Reopen the staple.") }
            if let i = next.matches.firstIndex(where: { $0.stapleID == stapleID && $0.variantID == variantID }) { next.matches[i].status = status }
            else { next.matches.append(ProductMatch(stapleID: stapleID, variantID: variantID, status: status)) }
        }
    }

    func selectLocation(store: StoreID, name: String, code: String?) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = code?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200, (code?.count ?? 0) <= 100 else { throw LibraryError(message: "Enter a location name and a store code up to 100 characters.") }
        try update { next in
            let normalizedCode = code?.isEmpty == true ? nil : code
            let existing = next.locations.first { $0.store == store && $0.name == name && $0.code == normalizedCode }
            let location = existing ?? StoreLocation(store: store, name: name, code: normalizedCode)
            if existing == nil { next.locations.append(location) }
            next.preferredLocations[store] = location.id
        }
    }

    func recordPrice(stapleID: UUID, variant: ProductVariant, reuseID: UUID?, channel: Channel, price: Decimal, available: Bool, observedAt: Date, conditions: String, sourceURL: String?, approveNew: Bool) throws {
        guard price >= 0, price <= 1_000_000, !price.isNaN, variant.quantity > 0, variant.quantity <= 1_000_000, !variant.quantity.isNaN, variant.packCount >= 1, variant.packCount <= 10_000,
              !variant.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, observedAt <= Date() else { throw LibraryError(message: "Check the product, nonnegative price, positive package quantity, pack count and observation time.") }
        if let sourceURL, !sourceURL.isEmpty { guard let url = URL(string: sourceURL), ["https", "http"].contains(url.scheme), url.host != nil, url.user == nil, url.password == nil else { throw LibraryError(message: "Enter a public http or https product URL without credentials.") } }
        try update { next in
            guard next.staples.contains(where: { $0.id == stapleID }), let location = next.location(for: variant.store) else { throw LibraryError(message: "Select a saved staple and store location first.") }
            var selected = variant
            if let reuseID {
                guard let old = next.variants.first(where: { $0.id == reuseID }), old.store == variant.store, old.quantity == variant.quantity, old.unit == variant.unit, old.packCount == variant.packCount, old.quantityKind == variant.quantityKind else { throw LibraryError(message: "This package differs from the saved product. Select New product so it can be reviewed separately.") }
                selected = old
            } else {
                next.variants.append(selected)
                next.matches.append(ProductMatch(stapleID: stapleID, variantID: selected.id, status: approveNew ? .approved : .pending))
            }
            if !next.matches.contains(where: { $0.stapleID == stapleID && $0.variantID == selected.id }) { next.matches.append(ProductMatch(stapleID: stapleID, variantID: selected.id)) }
            next.observations.append(PriceObservation(sequence: (next.observations.map(\.sequence).max() ?? 0) + 1, stapleID: stapleID, variantID: selected.id, locationID: location.id, channel: channel, price: price, available: available, observedAt: observedAt, conditions: conditions, sourceURL: sourceURL?.isEmpty == false ? sourceURL : nil))
        }
    }

    func report(_ request: ReportRequest) throws -> WeeklyReport {
        let report = try ReportEngine.build(state: state, request: request)
        if !state.reports.contains(where: { $0.id == report.id }) { try update { $0.reports.append(report) } }
        return report
    }

    /// Track the latest package for each staple/source product, not superseded historical aliases.
    private func activeLinks(in library: LibraryState, store: StoreID, productID: String, locationID: UUID, channel: Channel) -> [UUID: UUID] {
        let variants = Set(library.variants.filter { $0.store == store && $0.productID == productID }.map(\.id))
        let matches = library.matches.filter { match in variants.contains(match.variantID) && match.status != .rejected && library.staples.contains(where: { $0.id == match.stapleID }) }
        var links: [UUID: UUID] = [:]
        for stapleID in Set(matches.map(\.stapleID)) {
            let accepted = Set(matches.filter { $0.stapleID == stapleID }.map(\.variantID))
            let evidence = library.observations.filter { $0.stapleID == stapleID && $0.locationID == locationID && accepted.contains($0.variantID) }
            let sameChannel = evidence.filter { $0.channel == channel }
            let latest = (sameChannel.isEmpty ? evidence : sameChannel).max { ($0.observedAt, $0.sequence) < ($1.observedAt, $1.sequence) }
            if let latest {
                if latest.sourceExclusion != "Product details changed; review the new package." { links[stapleID] = latest.variantID }
            } else { links[stapleID] = matches.last(where: { $0.stapleID == stapleID })?.variantID }
        }
        return links
    }

    func refresh() async {
        guard !refreshing else { return }
        notice = nil
        let now = Date()
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: now)
        guard state.lastRefreshDay != day else { failure = "Today’s refresh has already been attempted. Recorded prices remain available; another refresh is available tomorrow (UTC)."; return }
        var requests: [FetchRequest] = []
        var seen = Set<String>()
        for variant in state.variants.reversed() where variant.productID?.isEmpty == false {
            guard state.matches.contains(where: { match in match.variantID == variant.id && match.status != .rejected && state.staples.contains(where: { $0.id == match.stapleID }) }), let location = state.location(for: variant.store) else { continue }
            let channel: Channel = variant.store == .hmart ? .online : .inStore
            guard SourceCapability.forLocation(location, channel: channel).isConnected else { continue }
            let key = "\(variant.store.rawValue):\(location.id):\(variant.productID ?? "")"
            guard !activeLinks(in: state, store: variant.store, productID: variant.productID ?? "", locationID: location.id, channel: channel).isEmpty, seen.insert(key).inserted else { continue }
            requests.append(FetchRequest(variant: variant, location: location, channel: channel))
        }
        guard !requests.isEmpty else { failure = "Add a tracked Wegmans product ID or H Mart product:SKU ID when recording a price. Only validated store and channel sources can refresh."; return }
        guard requests.count <= 50 else { failure = "More than 50 tracked products are selected. Remove unused product tracking before refreshing."; return }
        do { try update { $0.lastRefreshDay = day } } catch { failure = error.localizedDescription; return }
        failure = nil
        refreshing = true; defer { refreshing = false }
        var successes = 0; var errors = 0
        for request in requests {
            let attempted = Date()
            do {
                let fetched = try await client.fetch(request)
                let finished = Date()
                try update { next in
                    // One fetch serves every tracked alias of this exact store product.
                    let links = activeLinks(in: next, store: request.variant.store, productID: request.variant.productID ?? "", locationID: request.location.id, channel: request.channel)
                    let aliases = next.variants.filter { links.values.contains($0.id) }
                    for alias in aliases {
                        let stapleIDs = Set(links.filter { $0.value == alias.id }.map(\.key))
                        guard !stapleIDs.isEmpty else { continue }
                        var variant = alias
                        if let quantity = fetched.quantity, let unit = fetched.unit {
                            let samePackage = alias.quantity == quantity && alias.unit == unit && alias.packCount == fetched.packCount && alias.quantityKind == fetched.quantityKind
                            let sameIdentity = alias.name == fetched.productName && alias.barcode == fetched.barcode
                            if !samePackage || !sameIdentity {
                                let newerEvidence = next.observations.contains {
                                    stapleIDs.contains($0.stapleID) && $0.variantID == alias.id &&
                                    $0.locationID == request.location.id && $0.channel == request.channel &&
                                    $0.observedAt > fetched.observedAt
                                }
                                guard !newerEvidence else {
                                    throw LibraryError(message: "The source returned older product details. Your newer recorded package and approval were preserved.")
                                }
                                let existing = next.variants.first { candidate in
                                    guard candidate.store == alias.store, candidate.productID == fetched.productID else { return false }
                                    guard candidate.name == fetched.productName, candidate.barcode == fetched.barcode else { return false }
                                    return candidate.quantity == quantity && candidate.unit == unit && candidate.packCount == fetched.packCount && candidate.quantityKind == fetched.quantityKind
                                }
                                variant = existing ?? ProductVariant(store: alias.store, productID: fetched.productID, barcode: fetched.barcode, name: fetched.productName, quantity: quantity, unit: unit, packCount: fetched.packCount, quantityKind: fetched.quantityKind)
                                if !next.variants.contains(where: { $0.id == variant.id }) { next.variants.append(variant) }
                            }
                        }
                        for stapleID in stapleIDs where next.staples.contains(where: { $0.id == stapleID }) {
                            if let index = next.matches.firstIndex(where: { $0.stapleID == stapleID && $0.variantID == variant.id }) {
                                // Returning to an older reviewed package still requires a fresh review.
                                if variant.id != alias.id { next.matches[index].status = .pending }
                            } else { next.matches.append(ProductMatch(stapleID: stapleID, variantID: variant.id)) }
                            if variant.id != alias.id {
                                next.observations.append(PriceObservation(sequence: (next.observations.map(\.sequence).max() ?? 0) + 1, stapleID: stapleID, variantID: alias.id, locationID: request.location.id, channel: request.channel, price: nil, available: nil, observedAt: fetched.observedAt, retrievedAt: fetched.retrievedAt, source: fetched.source, sourceURL: fetched.sourceURL, sourceExclusion: "Product details changed; review the new package.", ingestedAt: finished))
                            }
                            next.observations.append(PriceObservation(sequence: (next.observations.map(\.sequence).max() ?? 0) + 1, stapleID: stapleID, variantID: variant.id, locationID: request.location.id, channel: request.channel, price: fetched.price, available: fetched.available, observedAt: fetched.observedAt, retrievedAt: fetched.retrievedAt, conditions: fetched.conditions, source: fetched.source, sourceURL: fetched.sourceURL, sourceExclusion: fetched.sourceExclusion ?? (fetched.quantity == nil ? "Source package size is unknown." : nil), ingestedAt: finished))
                        }
                    }
                    next.sourceRuns.append(SourceRun(store: request.location.store, locationID: request.location.id, channel: request.channel, attemptedAt: attempted, succeededAt: finished, finishedAt: finished))
                }
                successes += 1
            } catch {
                errors += 1
                do { try update { $0.sourceRuns.append(SourceRun(store: request.location.store, locationID: request.location.id, channel: request.channel, attemptedAt: attempted, error: error.localizedDescription, finishedAt: Date())) } }
                catch { failure = error.localizedDescription; break }
            }
        }
        notice = "Refresh finished: \(successes) products checked, \(errors) failed. Imports never approve product matches."
    }
}
