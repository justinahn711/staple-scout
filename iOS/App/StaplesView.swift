import SwiftUI
import StapleScoutKit

struct StaplesView: View {
    @Bindable var store: LibraryStore
    @State private var adding = false
    @State private var deleting: Staple?
    var body: some View {
        List {
            if store.state.staples.isEmpty {
                ContentUnavailableView {
                    Label("Start with your staples", systemImage: "carrot")
                } description: { Text("Add the groceries you actually buy. Approve acceptable products, then compare dated prices at your stores.") }
                actions: { Button("Add your first staple") { adding = true }.buttonStyle(.borderedProminent).frame(minHeight: 44) }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(store.state.staples) { staple in
                        NavigationLink {
                            StapleDetailView(store: store, stapleID: staple.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(staple.name).font(.headline)
                                Text(staple.needed ? "Needed this week" : "Not needed this week").font(.subheadline).foregroundStyle(.secondary)
                                if let amount = staple.desiredQuantity, let unit = staple.desiredUnit { Text("Request \(quantity(amount)) \(unit.name)").font(.subheadline).foregroundStyle(.secondary) }
                            }.padding(.vertical, 4)
                        }
                        .swipeActions { Button("Delete", role: .destructive) { deleting = staple } }
                    }
                } footer: { Text("Products are approved individually. Editing a staple’s name, basis or requirements asks you to review them again.") }
            }
        }
        .navigationTitle("My staples")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Add staple", systemImage: "plus") { adding = true } } }
        .sheet(isPresented: $adding) { StapleEditor(store: store, original: nil) }
        .confirmationDialog("Delete \(deleting?.name ?? "staple")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete staple", role: .destructive) { if let staple = deleting { do { try store.deleteStaple(staple.id) } catch { store.failure = describe(error) } }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("Its prices and product reviews will be removed. Saved reports keep their original snapshot.") }
    }
}

struct StapleDetailView: View {
    @Bindable var store: LibraryStore
    let stapleID: UUID
    @State private var editing = false
    @State private var recording = false
    private var staple: Staple? { store.state.staples.first { $0.id == stapleID } }
    var body: some View {
        Group {
            if let staple {
                List {
                    Section("This week") {
                        Toggle("Needed this week", isOn: Binding(get: { self.staple?.needed ?? false }, set: { value in do { try store.setNeeded(stapleID, needed: value) } catch { store.failure = describe(error) } }))
                        if let amount = staple.desiredQuantity, let unit = staple.desiredUnit { LabeledContent("Requested amount", value: "\(quantity(amount)) \(unit.name)") }
                        LabeledContent("Compare by", value: staple.basis == .oz ? "Weight (oz)" : staple.basis == .flOz ? "Volume (fl oz)" : "Count")
                        if !staple.rules.isEmpty { Text(staple.rules) }
                    }
                    Section {
                        Button("Record a price", systemImage: "plus.circle") { recording = true }.frame(minHeight: 44)
                    }
                    Section {
                        let matches = store.state.matches.filter { $0.stapleID == stapleID }
                        if matches.isEmpty { Text("Record a product price to begin reviewing matches.").foregroundStyle(.secondary) }
                        ForEach(matches) { match in
                            if let variant = store.state.variants.first(where: { $0.id == match.variantID }) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(variant.name).font(.headline)
                                    Text("\(variant.store.name) · \(quantity(variant.quantity)) \(variant.unit.name) × \(variant.packCount)").font(.subheadline).foregroundStyle(.secondary)
                                    if let barcode = variant.barcode { Text("Barcode \(barcode)").font(.caption).foregroundStyle(.secondary) }
                                    Picker("Product review", selection: Binding(get: { store.state.matches.first(where: { $0.id == match.id })?.status ?? .pending }, set: { value in do { try store.review(stapleID: stapleID, variantID: variant.id, status: value) } catch { store.failure = describe(error) } })) {
                                        Text("Pending").tag(MatchStatus.pending)
                                        Text("Approved").tag(MatchStatus.approved)
                                        Text("Rejected").tag(MatchStatus.rejected)
                                    }.pickerStyle(.menu)
                                    if let latest = store.state.observations.filter({ $0.variantID == variant.id && $0.stapleID == stapleID }).max(by: { ($0.observedAt, $0.sequence) < ($1.observedAt, $1.sequence) }) {
                                        Text("Latest \(money(latest.price)) · \(latest.channel.name) · \(latest.observedAt.formatted(date: .abbreviated, time: .shortened))").font(.subheadline)
                                    }
                                }.padding(.vertical, 4)
                            }
                        }
                    } header: { Text("Review acceptable products") } footer: { Text("Approval confirms that the product meets your requirements. It does not verify the price or turn online evidence into a shelf price.") }
                }
                .navigationTitle(staple.name).navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Edit") { editing = true } }
                .sheet(isPresented: $editing) { StapleEditor(store: store, original: staple) }
                .sheet(isPresented: $recording) { PriceEditor(store: store, staple: staple) }
            } else { ContentUnavailableView("Staple removed", systemImage: "list.bullet") }
        }
    }
}

struct StapleEditor: View {
    @Bindable var store: LibraryStore
    let original: Staple?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var basis: MeasureUnit
    @State private var rules: String
    @State private var needed: Bool
    @State private var amount: String
    @State private var unit: MeasureUnit
    @State private var error: String?
    init(store: LibraryStore, original: Staple?) {
        self.store = store; self.original = original
        _name = State(initialValue: original?.name ?? ""); _basis = State(initialValue: original?.basis ?? .oz)
        _rules = State(initialValue: original?.rules ?? ""); _needed = State(initialValue: original?.needed ?? true)
        _amount = State(initialValue: original?.desiredQuantity.map { NSDecimalNumber(decimal: $0).stringValue } ?? "")
        _unit = State(initialValue: original?.desiredUnit ?? original?.basis ?? .oz)
    }
    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { Text(error).foregroundStyle(.red).accessibilityAddTraits(.isStaticText) } }
                Section("What you buy") {
                    TextField("Staple name", text: $name).textInputAutocapitalization(.sentences)
                    Picker("Compare by", selection: $basis) { Text("Weight (oz)").tag(MeasureUnit.oz); Text("Volume (fl oz)").tag(MeasureUnit.flOz); Text("Count").tag(MeasureUnit.each) }
                    TextField("Acceptable products and substitutes", text: $rules, axis: .vertical).lineLimit(3...6)
                }
                Section {
                    Toggle("Needed this week", isOn: $needed)
                    TextField("Requested amount (optional)", text: $amount).keyboardType(.decimalPad)
                    Picker("Requested unit", selection: $unit) { ForEach(MeasureUnit.allCases.filter { $0.basis == basis }, id: \.self) { Text($0.name).tag($0) } }
                } header: { Text("This week") } footer: { Text("Leave the amount blank to compare by unit price only.") }
                if original != nil { Section { Text("Changing the name, comparison basis or requirements returns product reviews to Pending.").foregroundStyle(.secondary) } }
            }
            .navigationTitle(original == nil ? "Add staple" : "Edit staple").navigationBarTitleDisplayMode(.inline)
            .onChange(of: basis) { _, value in if unit.basis != value { unit = value } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
        }
    }
    private func save() {
        let value = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = value.isEmpty ? nil : entryDecimal(value)
        guard value.isEmpty || parsed != nil else { error = "Enter a valid requested amount, or leave it blank."; return }
        do {
            try store.saveStaple(Staple(id: original?.id ?? UUID(), name: name, basis: basis, rules: rules, needed: needed, desiredQuantity: parsed, desiredUnit: parsed == nil ? nil : unit))
            dismiss()
        } catch { self.error = describe(error) }
    }
}
