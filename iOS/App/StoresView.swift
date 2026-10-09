import SwiftUI
import StapleScoutKit

struct StoresView: View {
    @Bindable var store: LibraryStore
    @State private var editing: StoreLocation?
    var body: some View {
        List {
            Section {
                ForEach(StoreID.allCases, id: \.self) { retailer in
                    if let location = store.state.location(for: retailer) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(retailer.name).font(.headline)
                            Text(location.name).font(.subheadline)
                            SourceStatusRow(store: store, location: location, channel: .inStore)
                            if retailer == .hmart { SourceStatusRow(store: store, location: location, channel: .online) }
                            Button("Change location") { editing = location }.frame(minHeight: 44)
                        }.padding(.vertical, 4)
                    }
                }
            } footer: { Text("Changing a location preserves old prices at their original store. Manual observations can qualify even when a website source is disconnected.") }
            Section("Refresh") {
                RefreshButton(store: store).frame(minHeight: 44)
                Text("Up to 50 tracked products, once per UTC day while you use the app. No background schedule or account login.").font(.subheadline).foregroundStyle(.secondary)
                if let day = store.state.lastRefreshDay { LabeledContent("Last attempted UTC day", value: day) }
            }
        }
        .navigationTitle("My stores")
        .sheet(item: $editing) { location in LocationEditor(store: store, location: location) }
    }
}

struct SourceStatusRow: View {
    let store: LibraryStore
    let location: StoreLocation
    let channel: Channel
    private var capability: SourceCapability { SourceCapability.forLocation(location, channel: channel) }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(capability.message, systemImage: capability.isConnected ? "checkmark.circle" : "minus.circle").font(.subheadline).foregroundStyle(.secondary)
            if let run = store.state.sourceRuns.filter({ $0.locationID == location.id && $0.channel == channel }).max(by: { $0.attemptedAt < $1.attemptedAt }) {
                Text("Last attempt \(run.attemptedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                if let error = run.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

struct LocationEditor: View {
    @Bindable var store: LibraryStore
    let location: StoreLocation
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var code: String
    @State private var error: String?
    init(store: LibraryStore, location: StoreLocation) { self.store = store; self.location = location; _name = State(initialValue: location.name); _code = State(initialValue: location.code ?? "") }
    var body: some View {
        NavigationStack {
            Form {
                if let error { Text(error).foregroundStyle(.red) }
                Section(location.store.name) {
                    TextField("Location name", text: $name)
                    TextField("Store code (optional)", text: $code).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section { Text("Old prices retain their original location. Website support is checked against this code; changing it does not validate a source.").foregroundStyle(.secondary) }
            }
            .navigationTitle("Store location").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { do { try store.selectLocation(store: location.store, name: name, code: code); dismiss() } catch { self.error = describe(error) } } }
            }
        }
    }
}
