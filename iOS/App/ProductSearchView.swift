import SwiftUI
import StapleScoutKit

struct ProductSearchView: View {
    @Bindable var store: LibraryStore
    let stapleID: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var results: [StoreSearchResult] = []
    @State private var loading = false
    @State private var hasSearched = false
    @State private var searchTask: Task<Void, Never>?
    @State private var tracked = Set<CandidateKey>()
    @State private var trackErrors: [CandidateKey: String] = [:]

    init(store: LibraryStore, stapleID: UUID, initialQuery: String) {
        self.store = store
        self.stapleID = stapleID
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Search stores", systemImage: "magnifyingglass") {
                        beginSearch()
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(loading || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text(store.isSharedPilot ? "Search sends these words and your selected store/channel to the pilot service. Check status and choose approved sources in My stores first. Track a product as Pending, then review its package and match." : "Search results are source evidence. Track a product to add it as Pending for your review.")
                }

                ForEach(StoreID.allCases, id: \.self) { retailer in
                    storeSection(retailer)
                }
            }
            .navigationTitle("Find store prices")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Product or staple")
            .onSubmit(of: .search) { beginSearch() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await search() }
            .onDisappear { searchTask?.cancel() }
        }
    }

    @ViewBuilder
    private func storeSection(_ retailer: StoreID) -> some View {
        Section {
            if loading {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Searching \(retailer.name)…").foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
            } else if let result = results.first(where: { $0.id == retailer }) {
                sourceRow(result)

                if let message = result.message, !message.isEmpty {
                    Label(message, systemImage: result.candidates.isEmpty ? "info.circle" : "exclamationmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if result.candidates.isEmpty, result.message == nil {
                    Text("No products found for this search.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(result.candidates.enumerated()), id: \.offset) { _, candidate in
                        candidateRow(candidate, result: result)
                    }
                }
            } else if hasSearched {
                if let location = store.state.location(for: retailer) {
                    LabeledContent("Source", value: "\(location.name) · \(channelName(for: retailer))")
                }
                Text("No response was returned for this store.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Ready to search.").foregroundStyle(.secondary)
            }
        } header: {
            Text(retailer.name)
        }
    }

    @ViewBuilder
    private func sourceRow(_ result: StoreSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Source", value: "\(result.location.name) · \(channelName(result.channel))")
            if store.isSharedPilot { RemoteSourceStatusRow(store: store, location: result.location, channel: result.channel) }
            if result.id == .hmart {
                Label("Online reference only — local shelf stock and shipping are unverified.", systemImage: "globe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func candidateRow(_ candidate: FetchedPrice, result: StoreSearchResult) -> some View {
        let key = CandidateKey(store: result.id, productID: candidate.productID, sourceURL: candidate.sourceURL)
        return VStack(alignment: .leading, spacing: 8) {
            Text(candidate.productName).font(.headline)

            HStack(alignment: .firstTextBaseline) {
                Text(candidate.price.map { money($0) } ?? "Price unavailable")
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                Spacer()
                Text(availability(candidate.available))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("As of \(candidate.observedAt.formatted(date: .abbreviated, time: .shortened))")
                Text("Checked \(candidate.retrievedAt.formatted(date: .abbreviated, time: .shortened))")
                if Date().timeIntervalSince(candidate.observedAt) >= 48 * 3600 {
                    Text("Older than 48 hours; excluded from comparisons")
                }
            }.font(.caption).foregroundStyle(.secondary)

            Text(packageDescription(candidate))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !candidate.conditions.isEmpty {
                Text(candidate.conditions).font(.caption).foregroundStyle(.secondary)
            }
            if let exclusion = candidate.sourceExclusion, !exclusion.isEmpty {
                Label(exclusion, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = trackErrors[key] {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityAddTraits(.isStaticText)
            }

            if tracked.contains(key) {
                Label("Tracked for review", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(minHeight: 44)
            } else {
                Button("Track product", systemImage: "plus.circle") {
                    track(candidate, result: result, key: key)
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
            }
        }
        .padding(.vertical, 4)
    }

    private func beginSearch() {
        guard !loading else { return }
        searchTask = Task { await search() }
    }

    private func search() async {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !loading else { return }
        loading = true
        defer { loading = false }
        hasSearched = true
        tracked.removeAll()
        trackErrors.removeAll()
        let found = await store.searchProducts(query: cleaned)
        guard !Task.isCancelled else { return }
        results = found
    }

    private func track(_ candidate: FetchedPrice, result: StoreSearchResult, key: CandidateKey) {
        trackErrors[key] = nil
        do {
            try store.trackProduct(candidate, location: result.location, channel: result.channel, stapleID: stapleID)
            tracked.insert(key)
        } catch {
            trackErrors[key] = describe(error)
        }
    }

    private func packageDescription(_ candidate: FetchedPrice) -> String {
        guard let amount = candidate.quantity, let unit = candidate.unit else {
            return "Package size unavailable"
        }
        let package = "\(quantity(amount)) \(unit.name)"
        return candidate.packCount == 1 ? package : "\(package) × \(candidate.packCount)"
    }

    private func availability(_ value: Bool?) -> String {
        switch value {
        case .some(true): return "Available"
        case .some(false): return "Unavailable"
        case .none: return "Availability unknown"
        }
    }

    private func channelName(for retailer: StoreID) -> String {
        retailer == .hmart ? channelName(.online) : channelName(.inStore)
    }

    private func channelName(_ channel: Channel) -> String {
        channel == .inStore ? "Shelf" : channel.name
    }
}

private struct CandidateKey: Hashable {
    let store: StoreID
    let productID: String
    let sourceURL: String
}
