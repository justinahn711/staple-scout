import SwiftUI
import StapleScoutKit

struct ShoppingView: View {
    @Bindable var store: LibraryStore
    @State private var channel: Channel = .inStore
    @State private var planned = Set(StoreID.allCases)
    @State private var neededOnly = true
    @State private var makingReport = false
    @State private var asOf = Date()
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    private var comparisons: [StapleComparison] { ComparisonEngine.compare(state: store.state, channel: channel, stores: planned, neededOnly: neededOnly, asOf: asOf) }
    var body: some View {
        List {
            ComparisonFilters(channel: $channel, planned: $planned, neededOnly: $neededOnly)
            if planned.isEmpty { ContentUnavailableView("Select a planned store", systemImage: "storefront") }
            else if comparisons.isEmpty { ContentUnavailableView("Nothing on this week’s list", systemImage: "basket", description: Text("Mark staples as needed, or turn off Needed staples only.")) }
            else {
                ForEach(StoreID.allCases, id: \.self) { retailer in
                    let groups = comparisons.filter { $0.winner?.location.store == retailer }
                    if !groups.isEmpty {
                        Section {
                            ForEach(groups) { group in
                                if let winner = group.winner {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(group.staple.name).font(.headline)
                                        OfferRow(offer: winner, basis: group.staple.basis, winner: true, outlayWinner: winner.id == group.outlayWinnerID)
                                        if group.outlayWinnerID != nil && group.outlayWinnerID != group.winnerID { Text("Another offer has a lower whole-package cost. See Compare.").font(.subheadline).foregroundStyle(.secondary) }
                                    }
                                }
                            }
                        } header: { Text(retailer.name) }
                    }
                }
                let gaps = comparisons.filter { $0.winner == nil }
                if !gaps.isEmpty {
                    Section("Coverage gaps (\(gaps.count))") {
                        ForEach(gaps) { group in
                            VStack(alignment: .leading, spacing: 6) { Text(group.staple.name).font(.headline); Text("No eligible price at your planned stores. Review matches and dated evidence in Compare.").font(.subheadline).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            Section("Weekly reports") {
                Button("Save a weekly report", systemImage: "doc.badge.plus") { makingReport = true }.frame(minHeight: 44)
                ForEach(store.state.reports.sorted { $0.generatedAt > $1.generatedAt }) { report in
                    NavigationLink { SavedReportView(report: report) } label: {
                        VStack(alignment: .leading, spacing: 4) { Text(report.generatedAt.formatted(date: .abbreviated, time: .shortened)); Text("Cutoff \(report.request.asOf.formatted(date: .abbreviated, time: .shortened)) · \(report.request.channel.name)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .navigationTitle("This week")
        .toolbar { RefreshButton(store: store) }
        .onAppear { asOf = Date() }
        .onReceive(timer) { asOf = $0 }
        .onChange(of: store.refreshing) { _, value in if !value { asOf = Date() } }
        .sheet(isPresented: $makingReport) { ReportEditor(store: store, initialChannel: channel, initialStores: planned, initialNeeded: neededOnly) }
    }
}

struct ReportEditor: View {
    @Bindable var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State var cutoff = Date()
    @State var channel: Channel
    @State var planned: Set<StoreID>
    @State var neededOnly: Bool
    @State var error: String?
    @State var saved: WeeklyReport?
    @State var showingSaved = false
    init(store: LibraryStore, initialChannel: Channel, initialStores: Set<StoreID>, initialNeeded: Bool) { self.store = store; _channel = State(initialValue: initialChannel); _planned = State(initialValue: initialStores); _neededOnly = State(initialValue: initialNeeded) }
    var body: some View {
        NavigationStack {
            Form {
                if let error { Text(error).foregroundStyle(.red) }
                Section { DatePicker("Evidence cutoff", selection: $cutoff, in: ...Date(), displayedComponents: [.date, .hourAndMinute]) }
                ComparisonFilters(channel: $channel, planned: $planned, neededOnly: $neededOnly)
                Section { Text("Saving freezes your current requirements, reviews and locations with evidence recorded by the cutoff. It does not reconstruct older settings or fetch new prices.").foregroundStyle(.secondary) }
                Section { Button("Save report") { do { saved = try store.report(ReportRequest(asOf: cutoff, stores: planned, channel: channel, neededOnly: neededOnly)); error = nil; showingSaved = true } catch { self.error = describe(error) } }.frame(minHeight: 44) }
            }
            .navigationTitle("Weekly report").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .navigationDestination(isPresented: $showingSaved) { if let saved { SavedReportView(report: saved) } }
        }
    }
}

struct SavedReportView: View {
    let report: WeeklyReport
    var body: some View {
        List {
            Section("Saved snapshot") {
                LabeledContent("Generated", value: report.generatedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Evidence cutoff", value: report.request.asOf.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Channel", value: report.request.channel == .inStore ? "Shelf" : report.request.channel.name)
                Text("Later edits do not change this report.").foregroundStyle(.secondary)
            }
            if report.comparisons.isEmpty { ContentUnavailableView("No staples matched", systemImage: "doc.text", description: Text("This saved report has no qualifying staple selection.")) }
            ForEach(report.comparisons) { group in
                Section(group.staple.name) {
                    if let winner = group.winner { OfferRow(offer: winner, basis: group.staple.basis, winner: true, outlayWinner: winner.id == group.outlayWinnerID) }
                    else { Label("Coverage gap: no eligible price", systemImage: "exclamationmark.circle") }
                    if let outlay = group.outlayWinner, outlay.id != group.winnerID { OfferRow(offer: outlay, basis: group.staple.basis, outlayWinner: true) }
                    DisclosureGroup("Recorded offers and exclusions (\(group.offers.count))") { ForEach(group.offers) { offer in OfferRow(offer: offer, basis: group.staple.basis) } }
                }
            }
            Section("Comparable price drops") {
                if report.priceDrops.isEmpty { Text("No comparable price drops were recorded.").foregroundStyle(.secondary) }
                ForEach(report.priceDrops) { drop in
                    VStack(alignment: .leading, spacing: 6) { Text(drop.stapleName).font(.headline); Text(drop.productName); Text("\(money(drop.previousPrice)) → \(money(drop.price)) · \(money(drop.amount)) lower per package").monospacedDigit(); Text("Observation \(drop.previousObservationID.uuidString.prefix(8)) → \(drop.observationID.uuidString.prefix(8))").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section {
                DisclosureGroup("Source status at cutoff") {
                    if report.sourceRuns.isEmpty { Text("No source refresh was recorded by this cutoff. Manual observations can still qualify.").foregroundStyle(.secondary) }
                    ForEach(report.sourceRuns) { run in
                        VStack(alignment: .leading, spacing: 4) { Text("\(run.store.name) · \(run.channel.name)").font(.headline); Text(run.attemptedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption); Text(run.error ?? (run.succeededAt == nil ? "No completed refresh" : "Refresh completed")).foregroundStyle(.secondary) }
                    }
                }
            }
        }.navigationTitle("Saved report").navigationBarTitleDisplayMode(.inline)
    }
}
