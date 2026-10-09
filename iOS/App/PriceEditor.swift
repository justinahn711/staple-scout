import SwiftUI
import StapleScoutKit

struct PriceEditor: View {
    @Bindable var store: LibraryStore
    let staple: Staple
    @Environment(\.dismiss) private var dismiss
    @State private var retailer: StoreID = .wegmans
    @State private var existing: UUID?
    @State private var product = ""
    @State private var productID = ""
    @State private var barcode = ""
    @State private var price = ""
    @State private var size = ""
    @State private var unit: MeasureUnit = .oz
    @State private var packs = 1
    @State private var kind: QuantityKind = .fixed
    @State private var channel: Channel = .inStore
    @State private var observed = Date()
    @State private var available = true
    @State private var approved = false
    @State private var conditions = ""
    @State private var sourceURL = ""
    @State private var error: String?
    private var variants: [ProductVariant] { store.state.variants.filter { $0.store == retailer } }
    var body: some View {
        NavigationStack {
            Form {
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section("Product") {
                    Text(staple.name).font(.headline)
                    Picker("Store", selection: $retailer) { ForEach(StoreID.allCases, id: \.self) { Text($0.name).tag($0) } }
                    if let location = store.state.location(for: retailer) { Text(location.name).font(.subheadline).foregroundStyle(.secondary) }
                    Picker("Product identity", selection: $existing) {
                        Text("New product").tag(nil as UUID?)
                        ForEach(variants) { Text("\($0.name) · \(quantity($0.quantity)) \($0.unit.name) × \($0.packCount)").tag(Optional($0.id)) }
                    }
                    TextField("Product name", text: $product).disabled(existing != nil)
                    TextField("Quantity per pack", text: $size).keyboardType(.decimalPad).disabled(existing != nil)
                    Picker("Package unit", selection: $unit) { ForEach(MeasureUnit.allCases, id: \.self) { Text($0.name).tag($0) } }.disabled(existing != nil)
                    Stepper("Packs included in price: \(packs)", value: $packs, in: 1...10_000).disabled(existing != nil)
                    Picker("Quantity accuracy", selection: $kind) { ForEach(QuantityKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }.disabled(existing != nil)
                }
                Section("Price evidence") {
                    TextField("Total package price ($)", text: $price).keyboardType(.decimalPad)
                    Picker("Purchase channel", selection: $channel) { ForEach(Channel.allCases, id: \.self) { Text($0 == .inStore ? "Shelf" : $0.name).tag($0) } }
                    DatePicker("Observed at", selection: $observed, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                    Toggle("In stock", isOn: $available)
                    TextField("Coupon, membership or other conditions", text: $conditions, axis: .vertical)
                    TextField("Public source URL (optional)", text: $sourceURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if existing == nil {
                    Section {
                        Toggle("Approve this product", isOn: $approved)
                        if !staple.rules.isEmpty { Text(staple.rules) }
                    } header: { Text("Acceptable substitute?") } footer: { Text("Approve only after checking the product meets your staple’s requirements. Price imports never approve products.") }
                    Section {
                        TextField("Website product ID (optional)", text: $productID).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Barcode (optional)", text: $barcode).textInputAutocapitalization(.never).autocorrectionDisabled()
                    } header: { Text("Track website prices") } footer: { Text("Wegmans uses its numeric product ID. H Mart uses product:SKU identity and stays online reference only. Unverified sources cannot refresh.") }
                }
            }
            .navigationTitle("Record a price").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
            .onAppear { unit = staple.basis }
            .onChange(of: retailer) { _, _ in existing = nil; resetProduct() }
            .onChange(of: existing) { _, id in
                if let variant = variants.first(where: { $0.id == id }) {
                    product = variant.name; size = NSDecimalNumber(decimal: variant.quantity).stringValue; unit = variant.unit; packs = variant.packCount; kind = variant.quantityKind
                } else { resetProduct() }
            }
        }
    }
    private func resetProduct() { product = ""; size = ""; unit = staple.basis; packs = 1; kind = .fixed; productID = ""; barcode = ""; approved = false }
    private func save() {
        guard let price = entryDecimal(price), let size = entryDecimal(size) else { error = "Enter a numeric total price and package quantity."; return }
        do {
            let variant = ProductVariant(store: retailer, productID: productID.isEmpty ? nil : productID, barcode: barcode.isEmpty ? nil : barcode, name: product, quantity: size, unit: unit, packCount: packs, quantityKind: kind)
            try store.recordPrice(stapleID: staple.id, variant: variant, reuseID: existing, channel: channel, price: price, available: available, observedAt: observed, conditions: conditions, sourceURL: sourceURL, approveNew: approved)
            dismiss()
        } catch { self.error = describe(error) }
    }
}
