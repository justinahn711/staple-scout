import SwiftUI
import StapleScoutKit

struct ComparisonFilters: View {
    @Binding var channel: Channel
    @Binding var planned: Set<StoreID>
    @Binding var neededOnly: Bool
    var body: some View {
        Section {
            Picker("Price channel", selection: $channel) { Text("Shelf").tag(Channel.inStore); Text("Pickup").tag(Channel.pickup) }.pickerStyle(.segmented)
            Toggle("Needed staples only", isOn: $neededOnly)
            DisclosureGroup("Stores you plan to visit (\(planned.count))") {
                ForEach(StoreID.allCases, id: \.self) { retailer in
                    Toggle(retailer.name, isOn: Binding(get: { planned.contains(retailer) }, set: { if $0 { planned.insert(retailer) } else { planned.remove(retailer) } }))
                }
            }
        }
    }
}

struct CompareView: View {
    @Bindable var store: LibraryStore
    @State private var channel: Channel = .inStore
    @State private var planned = Set(StoreID.allCases)
    @State private var neededOnly = false
    @State private var asOf = Date()
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    private var comparisons: [StapleComparison] { ComparisonEngine.compare(state: store.state, channel: channel, stores: planned, neededOnly: neededOnly, asOf: asOf) }
    var body: some View {
        List {
            ComparisonFilters(channel: $channel, planned: $planned, neededOnly: $neededOnly)
            if planned.isEmpty {
                ContentUnavailableView("Select a planned store", systemImage: "storefront", description: Text("Choose at least one store above to compare prices."))
            } else if comparisons.isEmpty {
                ContentUnavailableView("No staples to compare", systemImage: "list.bullet", description: Text("Add staples or turn off Needed staples only."))
            } else {
                ForEach(comparisons) { group in
                    Section {
                        if group.winner == nil { Label(group.offers.isEmpty ? "No recorded price at these locations" : "No eligible price; review the exclusions", systemImage: "exclamationmark.circle").foregroundStyle(.secondary) }
                        if group.offers.isEmpty { Text("Record a price and approve an acceptable product to compare this staple.").foregroundStyle(.secondary) }
                        ForEach(group.offers) { offer in OfferRow(offer: offer, basis: group.staple.basis, winner: offer.id == group.winnerID, outlayWinner: offer.id == group.outlayWinnerID) }
                    } header: { Text(group.staple.name) } footer: {
                        if let amount = group.staple.desiredQuantity, let unit = group.staple.desiredUnit { Text("Requested \(quantity(amount)) \(unit.name). Lowest unit price and lowest whole-package cost can favor different products.") }
                    }
                }
            }
            Section {
                DisclosureGroup("Price source status") {
                    ForEach(StoreID.allCases.filter { planned.contains($0) }, id: \.self) { retailer in
                        if let location = store.state.location(for: retailer) { SourceStatusRow(store: store, location: location, channel: channel) }
                    }
                }
            } footer: { Text("Only approved, available, unconditional prices less than 48 hours old can win. Online reference prices and uncertain weights remain excluded.") }
        }
        .navigationTitle("Compare prices")
        .onAppear { asOf = Date() }
        .onReceive(timer) { asOf = $0 }
        .onChange(of: store.refreshing) { _, value in if !value { asOf = Date() } }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { RefreshButton(store: store) } }
    }
}

struct OfferRow: View {
    let offer: OfferResult
    let basis: MeasureUnit
    var winner = false
    var outlayWinner = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(offer.variant.name).font(.headline)
                Spacer(minLength: 12)
                Text(money(offer.observation.price)).font(.headline).monospacedDigit()
            }
            Text("\(offer.location.store.name) · \(offer.location.name)").font(.subheadline).foregroundStyle(.secondary)
            Text("\(quantity(offer.variant.quantity)) \(offer.variant.unit.name) per pack × \(offer.variant.packCount)").font(.subheadline)
            if let unitPrice = offer.unitPrice { Text("$\(quantity(unitPrice)) / \(basis.name)").font(.subheadline).monospacedDigit() }
            if winner { Label("Lowest unit price", systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(.tint) }
            if let outlay = offer.outlay {
                Text("\(outlay.packages) packages · \(money(outlay.cost)) total").font(.subheadline).monospacedDigit()
                Text("\(quantity(outlay.excess)) \(outlay.unit.name) extra\(outlayWinner ? " · Lowest package cost" : "")").font(.subheadline).foregroundStyle(.secondary)
            }
            Text("\(offer.observation.channel == .inStore ? "Shelf" : offer.observation.channel.name) · \(offer.observation.observedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            if !offer.observation.conditions.isEmpty { DisclosureGroup("Price conditions") { Text(offer.observation.conditions).font(.subheadline) } }
            if !offer.exclusionReasons.isEmpty { Label("Excluded: \(offer.exclusionReasons.map(exclusionLabel).joined(separator: "; "))", systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(.secondary) }
            if let value = offer.observation.sourceURL, let url = URL(string: value), ["https", "http"].contains(url.scheme) { Link("View price source", destination: url).font(.subheadline).frame(minHeight: 44) }
        }.padding(.vertical, 6)
    }
}

struct RefreshButton: View {
    @Bindable var store: LibraryStore
    var body: some View {
        Button { Task { await store.refresh() } } label: {
            if store.refreshing { ProgressView().accessibilityLabel("Refreshing recorded products") }
            else { Label("Refresh prices", systemImage: "arrow.clockwise") }
        }.disabled(store.refreshing)
    }
}

func exclusionLabel(_ reason: String) -> String {
    switch reason {
    case "not_approved": return "Product awaiting approval"
    case "match_rejected": return "Product rejected"
    case "online_reference_only": return "Online reference only"
    case "not_in_store": return "Not a shelf price"
    case "not_pickup": return "Not a pickup price"
    case "uncertain_quantity": return "Exact package quantity is uncertain"
    case "incompatible_dimension": return "Package unit does not match this staple"
    case "availability_unknown": return "Stock is unknown"
    case "unavailable": return "Out of stock"
    case "price_unknown": return "Price is unknown"
    case "stale": return "Price is at least 48 hours old"
    case "conditional_price": return "Coupon, membership or other conditions apply"
    case "offer_not_started": return "Offer has not started"
    case "offer_expired": return "Offer has expired"
    case "future_observation", "future_retrieval", "future_ingestion": return "Evidence time is in the future"
    case "retrieval_time_unknown": return "Source retrieval time is unknown"
    case "invalid_price_or_quantity", "invalid_price": return "Price or quantity could not be verified"
    default: return reason
    }
}
