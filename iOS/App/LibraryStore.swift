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

struct StoreSearchResult: Identifiable {
    var id: StoreID { location.store }
    var location: StoreLocation
    var channel: Channel
    var candidates: [FetchedPrice] = []
    var message: String?
}

private struct UnconfiguredSharedTransport: RetailPriceFetching, RetailProductSearching {
    private func error() -> LibraryError {
        LibraryError(message: "The shared service configuration is incomplete or invalid. Set its URL and access token in the Xcode Run environment.")
    }
    func fetch(_ request: FetchRequest) async throws -> FetchedPrice { throw error() }
    func search(query: String, location: StoreLocation, channel: Channel) async throws -> RetailSearchPage { throw error() }
}

@MainActor @Observable final class LibraryStore {
    private(set) var state: LibraryState
    private(set) var refreshing = false
    var notice: String?
    var failure: String?
    private let context: ModelContext
    private var record: SavedLibrary
    private let client: any RetailPriceFetching
    private let searchClient: any RetailProductSearching
    private var searchedProducts: [StoreSearchResult] = []
    private let sourceClient: (any RemoteSourceLoading)?
    private(set) var remoteSources: RemoteSourceSnapshot?
    private(set) var checkingSources = false
    private(set) var sourceStatusError: String?
    private(set) var selectedRemoteContexts: [StoreID: String] = [:]
    private var sourceEpoch = 0
    var isSharedPilot: Bool { sourceClient != nil }
    var hasCurrentSources: Bool { remoteSources?.isCurrent() == true }

    func invalidateRemoteSources() {
        sourceEpoch += 1; remoteSources = nil; searchedProducts = []; selectedRemoteContexts = [:]
    }
    func checkSources() async {
        guard !checkingSources, let sourceClient else { return }
        sourceEpoch += 1; let epoch = sourceEpoch
        checkingSources = true; sourceStatusError = nil; remoteSources = nil; searchedProducts = []
        defer { checkingSources = false }
        do {
            let snapshot = try await sourceClient.sources()
            guard epoch == sourceEpoch, !Task.isCancelled else { return }
            remoteSources = snapshot
            selectedRemoteContexts = selectedRemoteContexts.filter { store, id in snapshot.sources.contains { $0.store == store && $0.id == id && $0.permitsRequests } }
        } catch {
            guard epoch == sourceEpoch else { return }
            sourceStatusError = error.localizedDescription
        }
    }
    func sourceStatus(for location: StoreLocation, channel: Channel? = nil) -> RemoteSourceStatus? {
        remoteSources?.status(location: location, channel: channel)
    }
    func selectRemoteSource(_ source: RemoteSourceStatus) throws {
        guard let snapshot = remoteSources else { throw LibraryError(message: "Check source status before choosing a pilot source.") }
        _ = try snapshot.require(source.context)
        guard snapshot.sources.contains(where: { $0.id == source.id }), let validated = StoreLocation.defaults.first(where: { $0.store == source.store && $0.code == source.storeCode }) else {
            throw LibraryError(message: "This store location is not in the current pilot catalog.")
        }
        try update { next in
            let location = next.locations.first { $0.store == validated.store && $0.code == validated.code } ?? validated
            if !next.locations.contains(where: { $0.id == location.id }) { next.locations.append(location) }
            next.preferredLocations[validated.store] = location.id
        }
        sourceEpoch += 1
        selectedRemoteContexts[source.store] = source.id
        searchedProducts = []
    }
    func requestChannel(for location: StoreLocation) -> Channel {
        if isSharedPilot {
            return remoteSources?.sources.first { $0.store == location.store && $0.storeCode == location.code && $0.id == selectedRemoteContexts[location.store] }?.channel
                ?? sourceStatus(for: location)?.channel ?? (location.store == .walmart ? .pickup : location.store == .hmart ? .online : .inStore)
        }
        return location.store == .hmart ? .online : .inStore
    }
    func sourceRequestReason(location: StoreLocation, channel: Channel) -> String? {
        if isSharedPilot {
            guard let snapshot = remoteSources, snapshot.isCurrent() else { return "Check source status in My stores before requesting prices. Status checks are valid for five minutes." }
            guard let source = snapshot.status(location: location, channel: channel) else { return "This location and channel are outside the limited pilot catalog." }
            guard source.permitsRequests else { return source.channelVerified ? source.statusText + ". " + source.limitation : "Price channel unverified. " + source.limitation }
            guard selectedRemoteContexts[location.store] == source.id else { return "Choose this approved location and channel in My stores before searching." }
            return nil
        }
        let capability = SourceCapability.forLocation(location, channel: channel)
        return capability.isConnected ? nil : capability.message
    }

    init(context: ModelContext, client: any RetailPriceFetching = RetailClient(), searchClient: any RetailProductSearching = RetailSearchClient(), sourceClient: (any RemoteSourceLoading)? = nil) throws {
        self.context = context; self.client = client; self.searchClient = searchClient; self.sourceClient = sourceClient
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

    /// The simulator can opt into the local prototype through Xcode Run environment variables.
    /// Credentials stay outside the library payload and the project/scheme files.
    static func configured(context: ModelContext, environment: [String: String]) throws -> LibraryStore {
        if environment["THRIFTY_SERVICE_URL"] != nil || environment["THRIFTY_ACCESS_TOKEN"] != nil {
            let transport: any RetailPriceFetching & RetailProductSearching
            if let address = environment["THRIFTY_SERVICE_URL"], let url = URL(string: address),
               let token = environment["THRIFTY_ACCESS_TOKEN"],
               let remote = try? SharedMarketClient(baseURL: url, accessToken: token) {
                transport = remote
            } else {
                transport = UnconfiguredSharedTransport()
            }
            return try LibraryStore(context: context, client: transport, searchClient: transport)
        }
        return try LibraryStore(context: context)
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

    func searchProducts(query: String) async -> [StoreSearchResult] {
        let epoch = sourceEpoch
        var results: [StoreSearchResult] = []
        let locations = StoreID.allCases.compactMap { state.location(for: $0) }
        for location in locations {
            if Task.isCancelled || (isSharedPilot && epoch != sourceEpoch) { return [] }
            let channel = requestChannel(for: location)
            if let reason = sourceRequestReason(location: location, channel: channel) {
                results.append(StoreSearchResult(location: location, channel: channel, message: reason))
                continue
            }
            do {
                let page = try await searchClient.search(query: query, location: location, channel: channel)
                guard !isSharedPilot || (epoch == sourceEpoch && sourceRequestReason(location: location, channel: channel) == nil) else { return [] }
                results.append(StoreSearchResult(location: location, channel: channel, candidates: page.candidates, message: page.message))
            } catch {
                if Task.isCancelled || (isSharedPilot && (epoch != sourceEpoch || !hasCurrentSources)) { return [] }
                results.append(StoreSearchResult(location: location, channel: channel, message: error.localizedDescription))
            }
        }
        guard !Task.isCancelled, !isSharedPilot || epoch == sourceEpoch else { return [] }
        searchedProducts = results
        return results
    }

    func trackProduct(_ candidate: FetchedPrice, location: StoreLocation, channel: Channel, stapleID: UUID) throws {
        guard state.location(for: location.store)?.id == location.id,
              sourceRequestReason(location: location, channel: channel) == nil,
              let fetched = searchedProducts.first(where: { $0.location.id == location.id && $0.channel == channel })?.candidates.first(where: { $0.productID == candidate.productID }) else {
            throw LibraryError(message: "These search results are no longer current. Search again for your selected store.")
        }
        guard let size = fetched.quantity, size > 0, !size.isNaN, let unit = fetched.unit else {
            throw LibraryError(message: "The store did not supply a usable package size. Choose another product so unit prices stay accurate.")
        }
        guard fetched.retrievedAt <= Date(), fetched.observedAt <= fetched.retrievedAt else {
            throw LibraryError(message: "The store returned an invalid price time. Search again later.")
        }
        try update { next in
            guard next.staples.contains(where: { $0.id == stapleID }) else { throw LibraryError(message: "This staple was removed. Add it again before tracking products.") }
            let sameProduct = next.variants.filter { $0.store == location.store && $0.productID == fetched.productID }
            let variant = sameProduct.first { $0.name == fetched.productName && $0.barcode == fetched.barcode && $0.quantity == size && $0.unit == unit && $0.packCount == fetched.packCount && $0.quantityKind == fetched.quantityKind }
                ?? ProductVariant(store: location.store, productID: fetched.productID, barcode: fetched.barcode, name: fetched.productName, quantity: size, unit: unit, packCount: fetched.packCount, quantityKind: fetched.quantityKind)
            // Rejected matches still belong to package history. They must not revive an older approval.
            let productIDs = Set(sameProduct.map(\.id))
            let latest = next.observations.filter { $0.stapleID == stapleID && productIDs.contains($0.variantID) && $0.locationID == location.id && $0.channel == channel }
                .max { ($0.observedAt, $0.sequence) < ($1.observedAt, $1.sequence) }
            let oldIDs = Set([latest?.variantID].compactMap { $0 }.filter { $0 != variant.id })
            let oldEvidence = next.observations.filter { $0.stapleID == stapleID && oldIDs.contains($0.variantID) && $0.locationID == location.id && $0.channel == channel }
            guard !oldEvidence.contains(where: { $0.observedAt > fetched.observedAt }) else {
                throw LibraryError(message: "The source returned older product details. Your newer recorded package and approval were preserved.")
            }
            let finished = Date()
            if !next.variants.contains(where: { $0.id == variant.id }) { next.variants.append(variant) }
            if let i = next.matches.firstIndex(where: { $0.stapleID == stapleID && $0.variantID == variant.id }) {
                if !oldEvidence.isEmpty || next.matches[i].status == .rejected { next.matches[i].status = .pending }
            } else { next.matches.append(ProductMatch(stapleID: stapleID, variantID: variant.id)) }
            for oldID in Set(oldEvidence.map(\.variantID)) {
                next.observations.append(PriceObservation(sequence: (next.observations.map(\.sequence).max() ?? 0) + 1, stapleID: stapleID, variantID: oldID, locationID: location.id, channel: channel, price: nil, available: nil, observedAt: fetched.observedAt, retrievedAt: fetched.retrievedAt, source: fetched.source, sourceURL: fetched.sourceURL, sourceExclusion: "Product details changed; review the new package.", ingestedAt: finished))
            }
            if !next.observations.contains(where: { $0.stapleID == stapleID && $0.variantID == variant.id && $0.locationID == location.id && $0.channel == channel && $0.retrievedAt == fetched.retrievedAt && $0.source == fetched.source }) {
                next.observations.append(PriceObservation(sequence: (next.observations.map(\.sequence).max() ?? 0) + 1, stapleID: stapleID, variantID: variant.id, locationID: location.id, channel: channel, price: fetched.price, available: fetched.available, observedAt: fetched.observedAt, retrievedAt: fetched.retrievedAt, conditions: fetched.conditions, source: fetched.source, sourceURL: fetched.sourceURL, validFrom: fetched.validFrom, validUntil: fetched.validUntil, sourceExclusion: fetched.sourceExclusion, ingestedAt: finished))
            }
        }
    }

    /// Current pilot policy is a view over dated evidence; never rewrite library history.
    func comparisonState(at date: Date = Date()) -> LibraryState {
        guard isSharedPilot else { return state }
        var result = state
        for i in result.observations.indices where result.observations[i].source != .manual {
            let observation = result.observations[i]
            let location = result.locations.first { $0.id == observation.locationID }
            let source = location.flatMap { remoteSources?.status(location: $0, channel: observation.channel) }
            let reason: String?
            if !hasCurrentSources { reason = "Current pilot source permission is unverified. Check source status in My stores." }
            else if let source, source.technicallySupported && source.channelVerified && source.publicAccessApproved && source.displayTTLSeconds > 0 {
                if let retrieved = observation.retrievedAt, date >= retrieved,
                   date.timeIntervalSince(retrieved) < min(source.displayTTLSeconds, source.retentionSeconds),
                   date.timeIntervalSince(observation.observedAt) < source.maximumObservationAgeSeconds {
                    reason = source.referenceOnly ? "National online reference; excluded from local comparisons." : nil
                } else { reason = "Evidence exceeds this pilot source’s display or observation limit." }
            } else { reason = "Public display is not approved for this exact pilot store and channel." }
            if let reason {
                result.observations[i].sourceExclusion = [observation.sourceExclusion, reason].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            }
        }
        return result
    }

    func report(_ request: ReportRequest) throws -> WeeklyReport {
        let report = try ReportEngine.build(state: comparisonState(), request: request)
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
            let channel = requestChannel(for: location)
            guard sourceRequestReason(location: location, channel: channel) == nil else { continue }
            let key = "\(variant.store.rawValue):\(location.id):\(variant.productID ?? "")"
            guard !activeLinks(in: state, store: variant.store, productID: variant.productID ?? "", locationID: location.id, channel: channel).isEmpty, seen.insert(key).inserted else { continue }
            requests.append(FetchRequest(variant: variant, location: location, channel: channel))
        }
        guard !requests.isEmpty else { failure = isSharedPilot ? "Check source status and choose an approved location and channel in My stores, then find and track a product. No price retrieval was started." : "Choose Find store prices on a staple and track a product first. Connected stores can then refresh its price automatically."; return }
        guard requests.count <= 50 else { failure = "More than 50 tracked products are selected. Remove unused product tracking before refreshing."; return }
        do { try update { $0.lastRefreshDay = day } } catch { failure = error.localizedDescription; return }
        failure = nil
        refreshing = true; defer { refreshing = false }
        var successes = 0; var errors = 0
        let epoch = sourceEpoch
        for request in requests {
            guard !Task.isCancelled, !isSharedPilot || (epoch == sourceEpoch && sourceRequestReason(location: request.location, channel: request.channel) == nil && state.location(for: request.location.store)?.id == request.location.id) else {
                failure = "The source selection or connection changed. The remaining refresh requests were not started. Check source status before trying again."
                break
            }
            let attempted = Date()
            do {
                let fetched = try await client.fetch(request)
                guard !isSharedPilot || (epoch == sourceEpoch && sourceRequestReason(location: request.location, channel: request.channel) == nil && state.location(for: request.location.store)?.id == request.location.id) else { throw NativeSessionError.superseded }
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
                            next.observations.append(PriceObservation(sequence: (next.observations.map(\.sequence).max() ?? 0) + 1, stapleID: stapleID, variantID: variant.id, locationID: request.location.id, channel: request.channel, price: fetched.price, available: fetched.available, observedAt: fetched.observedAt, retrievedAt: fetched.retrievedAt, conditions: fetched.conditions, source: fetched.source, sourceURL: fetched.sourceURL, validFrom: fetched.validFrom, validUntil: fetched.validUntil, sourceExclusion: fetched.sourceExclusion ?? (fetched.quantity == nil ? "Source package size is unknown." : nil), ingestedAt: finished))
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
