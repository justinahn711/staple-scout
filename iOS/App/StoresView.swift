import SwiftUI
import StapleScoutKit

struct StoresView: View {
    @Bindable var store: LibraryStore
    var pilot: PilotConnection? = nil
    @State private var editing: StoreLocation?
    var body: some View {
        List {
            if let pilot {
                PilotConnectionSection(connection: pilot)
                PilotSourcesSection(store: store)
            }
            Section {
                ForEach(StoreID.allCases, id: \.self) { retailer in
                    if let location = store.state.location(for: retailer) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(retailer.name).font(.headline)
                            Text(location.name).font(.subheadline)
                            if store.isSharedPilot {
                                PilotStoreSources(store: store, location: location)
                            } else {
                                SourceStatusRow(store: store, location: location, channel: .inStore)
                                if retailer == .hmart { SourceStatusRow(store: store, location: location, channel: .online) }
                                Button("Change location") { editing = location }.frame(minHeight: 44)
                            }
                        }.padding(.vertical, 4)
                    }
                }
            } footer: { Text("Changing a location preserves old prices at their original store. Manual observations can qualify independently. The pilot covers only the locations and channels supplied by the service.") }
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


struct PilotSourcesSection: View {
    @Bindable var store: LibraryStore
    var body: some View {
        Section("Pilot coverage") {
            Text("This small pilot checks a limited catalog, not every supermarket item. Start with My stores, check source status, then choose an approved location and channel.")
                .font(.subheadline).foregroundStyle(.secondary)
            Button { Task { await store.checkSources() } } label: {
                HStack { if store.checkingSources { ProgressView() }; Text(store.checkingSources ? "Checking source status…" : "Check source status") }
            }.frame(minHeight: 44).disabled(store.checkingSources)
                .accessibilityHint("Checks permissions and availability. Does not request product prices or schedule work.")
            if let error = store.sourceStatusError { Text(error).font(.subheadline).foregroundStyle(.secondary) }
            if let snapshot = store.remoteSources {
                Text("Status generated \(snapshot.generatedAt.formatted(date: .abbreviated, time: .shortened)). Check again after five minutes before requesting prices. Attempt and success times may be unavailable after retention.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("What is sent to the service") {
                Text("Search sends the words you enter and exact retailer, store code and price channel. Refresh sends a product ID and that context. Requests use your pilot session. Your staple list, product approvals and saved reports stay on this device.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("Source status describes recent work for a store and channel. Ready does not mean complete inventory, stock or an eligible comparison winner. Pending is not a promise of background work; checking status never schedules a price refresh.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

struct RemoteSourceStatusRow: View {
    let store: LibraryStore
    let location: StoreLocation
    var channel: Channel? = nil
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in sourceBody(at: context.date) }
    }
    private func sourceBody(at date: Date) -> some View {
        let current = store.remoteSources?.isCurrent(at: date) == true
        return VStack(alignment: .leading, spacing: 6) {
            if let source = store.sourceStatus(for: location, channel: channel) {
                Label("\(source.channel == .inStore ? "Shelf" : source.channel.name): \(!current ? "source status unverified — check again" : source.channelVerified ? source.statusText : "price channel unverified")", systemImage: current && source.state == .ready ? "info.circle" : "exclamationmark.circle")
                    .font(.subheadline).foregroundStyle(.secondary)
                if !current { Text("Status needs a new check before requesting prices.").font(.caption).foregroundStyle(.secondary) }
                Text(source.attribution).font(.caption).foregroundStyle(.secondary)
                if !source.limitation.isEmpty { Text(source.limitation).font(.caption).foregroundStyle(.secondary) }
                if source.referenceOnly { Label("National online reference; not a local shelf or pickup price", systemImage: "globe").font(.caption).foregroundStyle(.secondary) }
                if source.store == .lidl { Text("Regional offers; local stock is unknown.").font(.caption).foregroundStyle(.secondary) }
                if let attempt = source.lastAttemptedAt { Text("Last source attempt \(attempt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                else { Text("Source attempt time unavailable").font(.caption).foregroundStyle(.secondary) }
                if let success = source.lastSucceededAt { Text("Last complete source success \(success.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                else { Text("Complete success time unavailable").font(.caption).foregroundStyle(.secondary) }
                if let evidence = source.evidence {
                    Text("Source observed \(evidence.observedAt.formatted(date: .abbreviated, time: .shortened)) (\(evidence.observedAt.formatted(.relative(presentation: .named))))")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Source retrieved \(evidence.retrievedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
                if let meaning = source.pendingMeaning { Text(meaning).font(.caption).foregroundStyle(.secondary) }
                if source.permitsRequests {
                    if store.selectedRemoteContexts[source.store] == source.id {
                        Label("Selected for search and refresh", systemImage: "checkmark.circle").font(.subheadline)
                    } else {
                        Button("Use \(location.name) · \(source.channel == .inStore ? "Shelf" : source.channel.name)") {
                            do { try store.selectRemoteSource(source) } catch { store.failure = error.localizedDescription }
                        }.frame(minHeight: 44).disabled(!current)
                    }
                }
            } else {
                Label("\(location.store.name): \(store.hasCurrentSources ? "outside this pilot catalog" : "source status unverified")", systemImage: "questionmark.circle")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("Check source status in My stores. Unsupported locations remain unavailable.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}


struct PilotStoreSources: View {
    let store: LibraryStore
    let location: StoreLocation
    private var choices: [RemoteSourceStatus] { store.remoteSources?.sources.filter { $0.store == location.store } ?? [] }
    var body: some View {
        if choices.isEmpty {
            RemoteSourceStatusRow(store: store, location: location)
        } else {
            if !choices.contains(where: { $0.storeCode == location.code }) {
                Text("This saved location is outside the pilot. Its old prices retain their original store. Choose an approved pilot location below when available.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(choices) { source in
                if let validated = StoreLocation.defaults.first(where: { $0.store == source.store && $0.code == source.storeCode }) {
                    Text(validated.name).font(.subheadline)
                    RemoteSourceStatusRow(store: store, location: validated, channel: source.channel)
                }
            }
        }
    }
}
