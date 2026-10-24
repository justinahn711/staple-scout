import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A service location is configuration, never an invitation, token, library ID or retailer key.
public struct SessionEndpoint: Equatable, Sendable {
    public let url: URL
    public init(url: URL, allowLoopbackDevelopment: Bool = false) throws {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = c.host,
              !host.isEmpty, c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path.isEmpty || c.path == "/", c.percentEncodedPath == c.path,
              c.scheme == "https" || (allowLoopbackDevelopment && c.scheme == "http"
                && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())),
              c.port.map({ (1...65535).contains($0) }) ?? true else { throw NativeSessionError.configuration }
        self.url = url
    }
}

public enum NativeSessionState: Equatable, Sendable {
    case signedOut, connected, enrolling, refreshing, recoveryRequired, storageUnavailable, disconnectPending
}

public enum NativeSessionError: Error, LocalizedError, Equatable, Sendable {
    case configuration, invitationFormat, invitationRejected, invitationExpired, invitationUsed
    case signInRequired, recoveryRequired, storage, requestLimit, unavailable, superseded, invalidResponse
    public var errorDescription: String? {
        switch self {
        case .configuration: return "The pilot service is not configured. An approved HTTPS service address is required in this build."
        case .invitationFormat: return "Enter the invitation provided by the pilot operator."
        case .invitationRejected: return "The invitation was rejected. Ask the pilot operator for a new invitation."
        case .invitationExpired: return "This invitation expired. Ask the pilot operator for a new invitation."
        case .invitationUsed: return "This invitation has already been used. Ask the pilot operator for a new invitation."
        case .signInRequired: return "Connect the pilot in My stores before searching or refreshing prices."
        case .recoveryRequired: return "This session can’t be safely restored. Ask the pilot operator for a new invitation, then reconnect. Your library is preserved."
        case .storage: return "Secure session storage is unavailable. Unlock your device and try again. Your library is preserved."
        case .requestLimit: return "The pilot request limit was reached. Try again later."
        case .unavailable: return "The pilot service is unavailable. Check your connection and try again later."
        case .superseded: return "The connection changed. Try your request again."
        case .invalidResponse: return "The pilot returned an unsupported session response. Ask the pilot operator for help."
        }
    }
}

/// Implementations replace the whole item atomically. No credentials enter SwiftData or UserDefaults.
public protocol SessionCredentialStorage: Sendable {
    func read() throws -> Data?
    func replace(with data: Data) throws
    func remove() throws
}

struct NativeSessionTokens: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let clientID: String
    let tokenType: String
    let accessToken: String
    let accessExpiresAt: Date
    let refreshToken: String
    let refreshExpiresAt: Date

    func validate(now: Date, expectedClientID: String? = nil, fresh: Bool) throws {
        guard schemaVersion == 1, tokenType == "Bearer", Self.valid(clientID, prefix: "client1_", digits: 32),
              Self.valid(accessToken, prefix: "acc1_"), Self.valid(refreshToken, prefix: "ref1_"),
              expectedClientID.map({ $0 == clientID }) ?? true,
              accessExpiresAt.timeIntervalSince1970.isFinite, refreshExpiresAt.timeIntervalSince1970.isFinite,
              accessExpiresAt.timeIntervalSince1970 > 0, refreshExpiresAt >= accessExpiresAt,
              refreshExpiresAt <= now.addingTimeInterval(30 * 86_400 + 30),
              accessExpiresAt <= now.addingTimeInterval(900 + 30),
              !fresh || (accessExpiresAt > now && refreshExpiresAt > now) else { throw NativeSessionError.invalidResponse }
    }

    static func valid(_ value: String, prefix: String, digits: Int = 64) -> Bool {
        value.hasPrefix(prefix) && value.utf8.count == prefix.utf8.count + digits
            && value.dropFirst(prefix.count).utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Flat v1 schema: reject duplicate, escaped and unknown keys rather than JSONDecoder's last-key wins.
    static func decodeResponse(_ data: Data) throws -> Self {
        guard data.count <= 4096, let text = String(data: data, encoding: .utf8) else { throw NativeSessionError.invalidResponse }
        let pattern = #"\s*\{\s*(?:\"([A-Za-z]+)\"\s*:\s*(\"[^\"\\\x00-\x1F]*\"|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)\s*)(?:,\s*\"([A-Za-z]+)\"\s*:\s*(\"[^\"\\\x00-\x1F]*\"|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)\s*)*\}\s*"#
        guard let whole = text.range(of: pattern, options: .regularExpression), whole == text.startIndex..<text.endIndex else { throw NativeSessionError.invalidResponse }
        let keyExpression = try NSRegularExpression(pattern: #"\"([A-Za-z]+)\"\s*:"#)
        let keys = keyExpression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
        let expected: Set<String> = ["schemaVersion", "clientID", "tokenType", "accessToken", "accessExpiresAt", "refreshToken", "refreshExpiresAt"]
        guard keys.count == expected.count, Set(keys) == expected else { throw NativeSessionError.invalidResponse }
        // Schema version must be an integer literal, not 1.0, 1e0, a Boolean or a string.
        guard text.range(of: #"\"schemaVersion\"\s*:\s*1\s*[,}]"#, options: .regularExpression) != nil else { throw NativeSessionError.invalidResponse }
        do { return try SharedMarketWire.decoder().decode(Self.self, from: data) }
        catch { throw NativeSessionError.invalidResponse }
    }
}

private struct StoredNativeSession: Codable {
    let storageVersion: Int
    let tokens: NativeSessionTokens
    let refreshInFlight: Bool
}

private final class SessionRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// One actor owns credentials, refresh coalescing and invalidation. The persisted marker survives process death.
public actor NativeSessionController {
    public nonisolated let endpoint: SessionEndpoint
    private let storage: any SessionCredentialStorage
    private let session: URLSession
    private let now: @Sendable () -> Date
    private var tokens: NativeSessionTokens?
    private var state: NativeSessionState
    private var observer: (@Sendable (NativeSessionState) -> Void)?
    private var generation = 0
    private var refreshTask: Task<NativeSessionTokens, Error>?
    private var refreshID: UUID?
    private var retryAfter: Date?
    private var pendingDeletion: NativeSessionState?

    public init(endpoint: SessionEndpoint, storage: any SessionCredentialStorage,
                configuration: URLSessionConfiguration = .ephemeral, now: @escaping @Sendable () -> Date = { Date() }) {
        self.endpoint = endpoint; self.storage = storage; self.now = now
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: SessionRedirectGuard(), delegateQueue: nil)
        let restored = Self.load(storage: storage, now: now())
        tokens = restored.0; state = restored.1
    }

    private static func load(storage: any SessionCredentialStorage, now: Date) -> (NativeSessionTokens?, NativeSessionState) {
        let data: Data?
        do { data = try storage.read() }
        catch { return (nil, .storageUnavailable) }
        guard let data else { return (nil, .signedOut) }
        do {
            let saved = try SharedMarketWire.decoder().decode(StoredNativeSession.self, from: data)
            try saved.tokens.validate(now: now, fresh: false)
            guard saved.storageVersion == 1, !saved.refreshInFlight, saved.tokens.refreshExpiresAt > now else {
                throw NativeSessionError.recoveryRequired
            }
            return (saved.tokens, .connected)
        } catch {
            do { try storage.remove(); return (nil, .recoveryRequired) }
            catch { return (nil, .storageUnavailable) }
        }
    }

    /// Retry after unlocking the device. Never reload an old pair during a live exchange.
    public func restoreSecureStorage() {
        guard state == .storageUnavailable || state == .disconnectPending, refreshTask == nil else { return }
        generation += 1
        if let target = pendingDeletion {
            do { try storage.remove(); pendingDeletion = nil; setState(target) }
            catch { setState(target == .signedOut ? .disconnectPending : .storageUnavailable) }
            return
        }
        let restored = Self.load(storage: storage, now: now())
        tokens = restored.0; setState(restored.1)
    }

    public func currentState() -> NativeSessionState { state }
    func operationGeneration() -> Int { generation }
    func acceptsOperation(_ epoch: Int) -> Bool { epoch == generation && tokens != nil && (state == .connected || state == .refreshing) }
    public func observe(_ handler: @escaping @Sendable (NativeSessionState) -> Void) { observer = handler; handler(state) }
    private func setState(_ value: NativeSessionState) { state = value; observer?(value) }
    private func persist(_ value: NativeSessionTokens, inFlight: Bool) throws {
        do { try storage.replace(with: SharedMarketWire.encoder().encode(StoredNativeSession(storageVersion: 1, tokens: value, refreshInFlight: inFlight))) }
        catch { throw NativeSessionError.storage }
    }

    public func signOut() throws {
        generation += 1; refreshTask = nil; refreshID = nil; tokens = nil; retryAfter = nil
        pendingDeletion = .signedOut
        do { try storage.remove(); pendingDeletion = nil; setState(.signedOut) }
        catch { setState(.disconnectPending); throw NativeSessionError.storage }
    }

    public func enroll(invitation: String) async throws {
        guard NativeSessionTokens.valid(invitation, prefix: "inv1_") else { throw NativeSessionError.invitationFormat }
        try signOut()
        let epoch = generation
        setState(.enrolling)
        do {
            let value = try await exchange(field: "invitation", credential: invitation, path: "v1/session/enroll")
            guard generation == epoch else { throw NativeSessionError.superseded }
            try value.validate(now: now(), fresh: true)
            try persist(value, inFlight: false)
            tokens = value; setState(.connected)
        } catch {
            guard generation == epoch else { throw NativeSessionError.superseded }
            tokens = nil
            if error as? NativeSessionError == .storage { setState(.storageUnavailable) }
            else { setState(.signedOut) }
            throw safe(error)
        }
    }

    public func accessToken(rejectedAccessToken: String? = nil) async throws -> String {
        try Task.checkCancellation()
        guard let value = tokens else {
            if state == .storageUnavailable || state == .disconnectPending { throw NativeSessionError.storage }
            throw state == .recoveryRequired ? NativeSessionError.recoveryRequired : NativeSessionError.signInRequired
        }
        if let retryAfter, retryAfter > now() { throw NativeSessionError.requestLimit }
        if let task = refreshTask, let id = refreshID {
            return try await finish(task: task, id: id, epoch: generation, old: value).accessToken
        }
        guard value.refreshExpiresAt > now() else { try requireRecovery(); throw NativeSessionError.recoveryRequired }
        if value.accessExpiresAt > now().addingTimeInterval(30), rejectedAccessToken == nil || rejectedAccessToken != value.accessToken { return value.accessToken }
        // Write before dispatch: a killed process must not replay this refresh after restart.
        do { try persist(value, inFlight: true) }
        catch { tokens = nil; setState(.storageUnavailable); throw NativeSessionError.storage }
        let id = UUID(), epoch = generation
        let task = Task { try await self.exchange(field: "refreshToken", credential: value.refreshToken, path: "v1/session/refresh") }
        refreshTask = task; refreshID = id; setState(.refreshing)
        return try await finish(task: task, id: id, epoch: epoch, old: value).accessToken
    }

    private func finish(task: Task<NativeSessionTokens, Error>, id: UUID, epoch: Int, old: NativeSessionTokens) async throws -> NativeSessionTokens {
        do {
            let updated = try await task.value
            guard generation == epoch else { throw NativeSessionError.superseded }
            if refreshID == id {
                try updated.validate(now: now(), expectedClientID: old.clientID, fresh: true)
                guard updated.refreshToken != old.refreshToken, updated.accessToken != old.accessToken else { throw NativeSessionError.invalidResponse }
                try persist(updated, inFlight: false)
                tokens = updated; refreshID = nil; refreshTask = nil; retryAfter = nil; setState(.connected)
            }
            guard tokens == updated else { throw NativeSessionError.superseded }
            return updated
        } catch {
            guard generation == epoch else { throw NativeSessionError.superseded }
            if error as? NativeSessionError == .superseded { throw NativeSessionError.superseded }
            if error as? NativeSessionError == .requestLimit, refreshID == nil, tokens == old, retryAfter != nil {
                throw NativeSessionError.requestLimit
            }
            if refreshID == id {
                refreshID = nil; refreshTask = nil
                if error as? NativeSessionError == .requestLimit {
                    do { try persist(old, inFlight: false); retryAfter = now().addingTimeInterval(60); setState(.connected) }
                    catch { try? requireRecovery(); throw NativeSessionError.recoveryRequired }
                    throw NativeSessionError.requestLimit
                }
                // Any uncertain delivery or unsafe storage result requires a new invitation, never a retry.
                try? requireRecovery()
            }
            throw NativeSessionError.recoveryRequired
        }
    }

    /// A late rejected request cannot clear a newer enrollment or rotation.
    @discardableResult public func reject(accessToken: String) throws -> Bool {
        guard tokens?.accessToken == accessToken else { return false }
        try requireRecovery(); return true
    }
    private func requireRecovery() throws {
        generation += 1; tokens = nil; refreshTask = nil; refreshID = nil; retryAfter = nil
        pendingDeletion = .recoveryRequired
        do { try storage.remove(); pendingDeletion = nil; setState(.recoveryRequired) }
        catch { setState(.storageUnavailable); throw NativeSessionError.storage }
    }

    private func exchange(field: String, credential: String, path: String) async throws -> NativeSessionTokens {
        var request = URLRequest(url: endpoint.url.appendingPathComponent(path))
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, field: credential])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, raw) = try await session.data(for: request)
        guard let response = raw as? HTTPURLResponse, response.url == request.url, data.count <= 4096,
              response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else { throw NativeSessionError.invalidResponse }
        guard response.statusCode == 200 else {
            let code = (try? JSONDecoder().decode(SharedAPIError.self, from: data))?.code
            switch (response.statusCode, code) {
            case (401, "invitation_expired"): throw NativeSessionError.invitationExpired
            case (409, "invitation_used"): throw NativeSessionError.invitationUsed
            case (401, "invitation_invalid"): throw NativeSessionError.invitationRejected
            case (429, "request_limit"): throw NativeSessionError.requestLimit
            case (401, _): throw NativeSessionError.recoveryRequired
            default: throw NativeSessionError.unavailable
            }
        }
        return try NativeSessionTokens.decodeResponse(data)
    }
    private func safe(_ error: Error) -> NativeSessionError { (error as? NativeSessionError) ?? .unavailable }
}

/// Authenticated price requests retain the existing evidence validator and never instantiate direct clients.
public final class SessionMarketClient: RetailPriceFetching, RetailProductSearching, RemoteSourceLoading, @unchecked Sendable {
    private let sessions: NativeSessionController
    private let configuration: @Sendable () -> URLSessionConfiguration
    private let catalog: RemoteSourceCatalog?
    public init(sessions: NativeSessionController, catalog: RemoteSourceCatalog? = nil, configuration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) {
        self.sessions = sessions; self.catalog = catalog; self.configuration = configuration
    }
    public func search(query: String, location: StoreLocation, channel: Channel) async throws -> RetailSearchPage {
        try await perform { try await $0.search(query: query, location: location, channel: channel) }
    }
    public func fetch(_ request: FetchRequest) async throws -> FetchedPrice { try await perform { try await $0.fetch(request) } }
    public func sources() async throws -> RemoteSourceSnapshot {
        // Status checks are explicit; never turn a missing status into a polling loop.
        let epoch = await sessions.operationGeneration()
        let revision = await catalog?.beginCheck()
        let result: RemoteSourceSnapshot = try await perform(requiresCatalog: false, expectedEpoch: epoch) { try await $0.sources() }
        if let catalog, let revision { guard await catalog.replace(result, expected: revision, sessionEpoch: epoch) else { throw NativeSessionError.superseded } }
        guard await sessions.acceptsOperation(epoch) else { throw NativeSessionError.superseded }
        return result
    }
    private func perform<T>(requiresCatalog: Bool = true, expectedEpoch: Int? = nil, _ action: (SharedMarketClient) async throws -> T) async throws -> T {
        let epoch = await sessions.operationGeneration()
        if let expectedEpoch, expectedEpoch != epoch { throw NativeSessionError.superseded }
        let captured = await catalog?.capture()
        if requiresCatalog, catalog != nil, captured?.0 == nil {
            throw RetailClientError.unsupportedSource("Check source status in My stores before searching or refreshing. The status check is valid for five minutes.")
        }
        if requiresCatalog, catalog != nil, captured?.2 != epoch { throw NativeSessionError.superseded }
        let snapshot = requiresCatalog ? captured?.0 : nil
        func checked(_ token: String) async throws -> T {
            guard await sessions.acceptsOperation(epoch) else { throw NativeSessionError.superseded }
            if requiresCatalog, let catalog, let revision = captured?.1 {
                guard await catalog.matches(revision) else { throw NativeSessionError.superseded }
            }
            let result = try await action(client(token, snapshot: snapshot))
            guard await sessions.acceptsOperation(epoch) else { throw NativeSessionError.superseded }
            if requiresCatalog, let catalog, let revision = captured?.1 {
                guard await catalog.matches(revision) else { throw NativeSessionError.superseded }
            }
            return result
        }
        let first = try await sessions.accessToken()
        do { return try await checked(first) }
        catch let error as SharedServiceError where error.status == 401 {
            if error.code == "auth_revoked" || error.code == "refresh_replayed" {
                let cleared = try await sessions.reject(accessToken: first)
                throw cleared ? NativeSessionError.recoveryRequired : NativeSessionError.superseded
            }
            let replacement = try await sessions.accessToken(rejectedAccessToken: first)
            do { return try await checked(replacement) }
            catch let error as SharedServiceError where error.status == 401 {
                let cleared = try await sessions.reject(accessToken: replacement)
                throw cleared ? NativeSessionError.recoveryRequired : NativeSessionError.superseded
            }
        }
    }
    private func client(_ token: String, snapshot: RemoteSourceSnapshot?) throws -> SharedMarketClient {
        try SharedMarketClient(baseURL: sessions.endpoint.url, accessToken: token, configuration: configuration(), typedServiceErrors: true, sourceSnapshot: snapshot)
    }
}
