import Foundation
import Observation
import StapleScoutKit

/// Device builds read the compiled pilot configuration; environment variables cannot downgrade it.
struct AppServiceConfiguration {
    enum Mode { case personal, pilot }
    let mode: Mode
    let endpoint: SessionEndpoint?
    static func resolve(pilotBuild: Bool, address: String?) -> Self {
        guard pilotBuild else { return Self(mode: .personal, endpoint: nil) }
        let endpoint = address.flatMap(URL.init(string:)).flatMap { try? SessionEndpoint(url: $0) }
        return Self(mode: .pilot, endpoint: endpoint)
    }
    static var current: Self {
        #if THRIFTY_PILOT
        resolve(pilotBuild: true, address: Bundle.main.object(forInfoDictionaryKey: "ThriftyServiceURL") as? String)
        #else
        resolve(pilotBuild: false, address: nil)
        #endif
    }
}

private struct UnavailablePilotTransport: RetailPriceFetching, RetailProductSearching, RemoteSourceLoading {
    func sources() async throws -> RemoteSourceSnapshot { throw NativeSessionError.configuration }
    func fetch(_ request: FetchRequest) async throws -> FetchedPrice { throw NativeSessionError.configuration }
    func search(query: String, location: StoreLocation, channel: Channel) async throws -> RetailSearchPage { throw NativeSessionError.configuration }
}

@MainActor @Observable final class PilotConnection {
    let controller: NativeSessionController?
    let transport: any RetailPriceFetching & RetailProductSearching & RemoteSourceLoading
    private(set) var state: NativeSessionState = .signedOut
    private(set) var busy = false
    var message: String?
    let configured: Bool
    private let catalog = RemoteSourceCatalog()

    init(endpoint: SessionEndpoint?, bundleIdentifier: String) {
        configured = endpoint != nil
        if let endpoint, let storage = try? KeychainSessionStorage(bundleIdentifier: bundleIdentifier, endpoint: endpoint) {
            let sessions = NativeSessionController(endpoint: endpoint, storage: storage)
            controller = sessions; transport = SessionMarketClient(sessions: sessions, catalog: catalog)
        } else {
            controller = nil; transport = UnavailablePilotTransport()
        }
    }
    func observe() async {
        await controller?.observe { [weak self] state in
            Task { @MainActor [weak self] in self?.state = state }
        }
    }
    func enroll(_ invitation: String) async {
        guard !busy, let controller else { message = NativeSessionError.configuration.localizedDescription; return }
        busy = true; message = nil
        await catalog.clear()
        defer { busy = false }
        do { try await controller.enroll(invitation: invitation.trimmingCharacters(in: .whitespacesAndNewlines)) }
        catch { message = (error as? NativeSessionError ?? .unavailable).localizedDescription }
        state = await controller.currentState()
    }
    func retryStorage() async {
        await controller?.restoreSecureStorage()
        if let controller { state = await controller.currentState() }
        message = nil
    }
    func signOut() async {
        guard let controller else { return }
        busy = true; message = nil
        defer { busy = false }
        await catalog.clear()
        do { try await controller.signOut() }
        catch { message = NativeSessionError.storage.localizedDescription }
        state = await controller.currentState()
    }
    var explanation: String {
        guard configured else { return NativeSessionError.configuration.localizedDescription }
        switch state {
        case .signedOut: return "Enter the single-use invitation from the pilot operator to connect this installation."
        case .connected: return "Session saved securely on this device. Price sources may still be unavailable."
        case .enrolling: return "Connecting this installation…"
        case .refreshing: return "Renewing your session…"
        case .recoveryRequired: return NativeSessionError.recoveryRequired.localizedDescription
        case .storageUnavailable: return NativeSessionError.storage.localizedDescription
        case .disconnectPending: return "Disconnecting couldn’t clear secure storage. Unlock your device and retry disconnecting. Your library is preserved."
        }
    }
}
