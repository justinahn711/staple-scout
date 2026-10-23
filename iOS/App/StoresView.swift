import SwiftUI
import StapleScoutKit

struct StoresView: View {
    @Bindable var store: LibraryStore
    var pilot: PilotConnection? = nil
    @State private var editing: StoreLocation?
    var body: some View {
        List {
            if let pilot { PilotConnectionSection(connection: pilot) }
            Section {
                ForEach(StoreID.allCases, id: \.self) { retailer in
                    if let location = store.state.location(for: retailer) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(retailer.name).font(.headline)
                            Text(location.name).font(.subheadline)
                            SourceStatusRow(store: store, location: location, channel: .inStore, sharedPilot: pilot != nil)
                            if retailer == .hmart { SourceStatusRow(store: store, location: location, channel: .online, sharedPilot: pilot != nil) }
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
    var sharedPilot = false
    private var capability: SourceCapability { SourceCapability.forLocation(location, channel: channel) }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(sharedPilot ? "\(channel == .inStore ? "Shelf" : "Online reference"): pilot source availability unverified" : capability.message, systemImage: sharedPilot ? "questionmark.circle" : (capability.isConnected ? "checkmark.circle" : "minus.circle")).font(.subheadline).foregroundStyle(.secondary)
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


struct PilotConnectionSection: View {
    @Bindable var connection: PilotConnection
    @State private var invitation = ""
    @State private var confirmingSignOut = false
    var body: some View {
        Section {
            Text(connection.explanation).font(.subheadline).foregroundStyle(.secondary)
            if let message = connection.message { Text(message).font(.subheadline).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently) }
            if connection.configured {
                if connection.state == .storageUnavailable || connection.state == .disconnectPending {
                    Button(connection.state == .disconnectPending ? "Retry disconnect" : "Retry secure storage") { Task { await connection.retryStorage() } }.frame(minHeight: 44).disabled(connection.busy)
                }
                if connection.state != .connected && connection.state != .refreshing && connection.state != .storageUnavailable && connection.state != .disconnectPending {
                    SecureField("Pilot invitation", text: $invitation)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textContentType(.password).disabled(connection.busy)
                        .onChange(of: invitation) { _, text in if text.count > 128 { invitation = String(text.prefix(128)) } }
                    Button(connection.busy ? "Connecting…" : "Connect pilot") {
                        let value = invitation; invitation = ""
                        Task { await connection.enroll(value) }
                    }.frame(minHeight: 44).disabled(connection.busy || invitation.isEmpty)
                }
                if connection.state == .connected || connection.state == .refreshing || connection.state == .storageUnavailable {
                    Button("Disconnect this device", role: .destructive) { confirmingSignOut = true }
                        .frame(minHeight: 44).disabled(connection.busy)
                }
            }
        } header: { Text("Pilot connection") } footer: {
            Text("Your staples, saved reports and product approvals stay on this device. Disconnecting clears its credentials and requires a new operator invitation to reconnect.")
        }
        .confirmationDialog("Disconnect this device?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Disconnect this device", role: .destructive) { invitation = ""; Task { await connection.signOut() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your library will be preserved. The operator must issue a new invitation to reconnect. This does not revoke the session on the server.") }
    }
}
