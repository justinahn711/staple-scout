import Foundation
import ClientSessions
import AsyncHTTPClient

public struct ProviderHTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) { self.status = status; self.body = body }
}

public protocol ProviderHTTPNetwork: Sendable {
    /// Exactly one application HTTP attempt; implementations must not hide
    /// pagination, redirects, authentication retries or provider HTTP retries.
    func send(_ request: ProviderHTTPRequest) async throws -> ProviderHTTPResponse
}

public struct DisabledProviderNetwork: ProviderHTTPNetwork {
    public init() {}
    public func send(_ request: ProviderHTTPRequest) async throws -> ProviderHTTPResponse { throw ProviderBudgetError.disabled }
}

/// No credential or enabled source is configured by this type. Future approved
/// adapters must resolve provider auth separately; no api_key URL is accepted.
public final class SingleAttemptProviderHTTP: ProviderHTTPNetwork, @unchecked Sendable {
    private let client: HTTPClient
    private let fixtureOrigin: URL?
    private let completeTimeout: TimeInterval
    public convenience init() { self.init(fixtureOrigin: nil) }
    // Internal-only loopback fixture seam, never exposed by the executable.
    init(fixtureOrigin: URL?, completeTimeout: TimeInterval = 15) {
        var configuration = HTTPClient.Configuration()
        configuration.redirectConfiguration = .disallow
        configuration.connectionPool.retryConnectionEstablishment = false
        configuration.connectionPool.preWarmedHTTP1ConnectionCount = 0
        configuration.httpVersion = .http1Only
        configuration.tracing.tracer = nil
        configuration.timeout = .init(connect: .seconds(5), read: .seconds(10))
        client = HTTPClient(configuration: configuration)
        self.fixtureOrigin = fixtureOrigin
        self.completeTimeout = completeTimeout
    }
    public func shutdown() async throws { try await client.shutdown() }
    public func send(_ request: ProviderHTTPRequest) async throws -> ProviderHTTPResponse {
        var url = request.url
        if let fixtureOrigin {
            guard fixtureOrigin.scheme == "http", fixtureOrigin.host == "127.0.0.1" else { throw ProviderBudgetError.invalidRequest }
            var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
            components.scheme = fixtureOrigin.scheme; components.host = fixtureOrigin.host; components.port = fixtureOrigin.port
            url = components.url!
        }
        var outgoing = HTTPClientRequest(url: url.absoluteString)
        outgoing.method = .GET
        outgoing.headers.add(name: "Accept", value: "application/json")
        outgoing.headers.add(name: "Connection", value: "close")
        // AHC's execute deadline ends at the response head. Race the complete
        // head+body operation against an absolute deadline as well; a trickle
        // that keeps resetting the idle timeout must not retain a slot forever.
        let requestToSend = outgoing
        return try await withThrowingTaskGroup(of: ProviderHTTPResponse.self) { group in
            group.addTask {
                let response = try await self.client.execute(requestToSend, timeout: .seconds(15))
                let body = try await response.body.collect(upTo: 1_000_000)
                return ProviderHTTPResponse(status: Int(response.status.code), body: Data(body.readableBytesView))
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0.001, min(15, self.completeTimeout)) * 1_000_000_000))
                throw ProviderBudgetError.networkUnavailable
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw ProviderBudgetError.networkUnavailable }
            return result
        }
    }
}

public actor ProviderRequestScope {
    private let ledger: ProviderBudgetLedger
    private let lease: MissLease
    private var firstReservation: UnitReservation?
    private let network: any ProviderHTTPNetwork
    private let dispatchCheckpoint: (@Sendable () async -> Void)?
    init(ledger: ProviderBudgetLedger, lease: MissLease, firstReservation: UnitReservation, network: any ProviderHTTPNetwork, dispatchCheckpoint: (@Sendable () async -> Void)? = nil) {
        self.ledger = ledger; self.lease = lease; self.firstReservation = firstReservation; self.network = network; self.dispatchCheckpoint = dispatchCheckpoint
    }
    public func load(_ request: ProviderHTTPRequest) async throws -> Data {
        try Task.checkCancellation()
        let reservation: UnitReservation
        if let firstReservation { reservation = firstReservation; self.firstReservation = nil }
        else { reservation = try await ledger.reserve(lease: lease, purpose: request.purpose) }
        do {
            // Internal deterministic scheduling seam; no public/runtime API
            // exposes it. Holds must stay charged even if dispatch is delayed.
            if let dispatchCheckpoint { await dispatchCheckpoint() }
            try Task.checkCancellation()
            try await ledger.dispatched(reservation, purpose: request.purpose)
            let response = try await network.send(request)
            let successful = (200...299).contains(response.status)
            try await ledger.complete(reservation, receivedSuccess: successful)
            guard successful, response.body.count <= 1_000_000 else { throw ProviderBudgetError.networkUnavailable }
            return response.body
        } catch {
            try? await ledger.complete(reservation, receivedSuccess: false)
            if error is CancellationError { throw CancellationError() }
            if let error = error as? ProviderBudgetError { throw error }
            throw ProviderBudgetError.networkUnavailable
        }
    }
    func finish() async throws {
        if let firstReservation {
            self.firstReservation = nil
            try await ledger.complete(firstReservation, receivedSuccess: false)
        }
        try await ledger.endMiss(lease)
    }

}

public struct AdmittedProviderMiss: Sendable {
    public let requests: ProviderRequestScope
    public func finish() async throws { try await requests.finish() }
}

public struct ProviderBudgetController: Sendable {
    public let ledger: ProviderBudgetLedger
    private let network: any ProviderHTTPNetwork
    private let dispatchCheckpoint: (@Sendable () async -> Void)?
    public var enabled: Bool { ledger.enabled }
    public init(ledger: ProviderBudgetLedger, network: any ProviderHTTPNetwork = DisabledProviderNetwork()) {
        self.ledger = ledger; self.network = network; self.dispatchCheckpoint = nil
    }
    init(ledger: ProviderBudgetLedger, network: any ProviderHTTPNetwork, dispatchCheckpoint: @escaping @Sendable () async -> Void) {
        self.ledger = ledger; self.network = network; self.dispatchCheckpoint = dispatchCheckpoint
    }
    public func admit(principal: ClientPrincipal) async throws -> AdmittedProviderMiss {
        let (lease, reservation) = try await ledger.admit(principal: principal)
        let scope = ProviderRequestScope(ledger: ledger, lease: lease, firstReservation: reservation, network: network, dispatchCheckpoint: dispatchCheckpoint)
        return AdmittedProviderMiss(requests: scope)
    }
    public func withMiss<Value: Sendable>(principal: ClientPrincipal,
                                         perform: @escaping @Sendable (ProviderRequestScope) async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let admitted = try await admit(principal: principal)
        do {
            let value = try await perform(admitted.requests)
            try await admitted.finish()
            return value
        } catch { try? await admitted.finish(); throw error }
    }
}
