import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SharedMarketCore
import ClientSessions
import ProviderBudgets
import StapleScoutKit
import Vapor

public protocol MarketUpstream: Sendable {
    func price(context: PriceContext, productID: String, requests: ProviderRequestScope) async throws -> FetchedPrice
    func search(context: PriceContext, query: String, requests: ProviderRequestScope) async throws -> RetailSearchPage
}

public struct MarketService: Sendable {
    private let cache: SharedPriceCache
    private let sessions: ClientSessionStore
    private let providerBudgets: ProviderBudgetController?
    private let upstream: (any MarketUpstream)?
    private let now: @Sendable () -> Date

    public init(cache: SharedPriceCache, sessions: ClientSessionStore, upstream: (any MarketUpstream)? = nil, providerBudgets: ProviderBudgetController? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.cache = cache; self.sessions = sessions; self.upstream = upstream; self.providerBudgets = providerBudgets; self.now = now
    }

    public func configure(_ app: Application) {
        // No request-body or credential logging. No CORS middleware is installed.
        app.middleware = .init()
        app.middleware.use(QuietBoundaryErrors(sessions: sessions))
        app.routes.defaultMaxBodySize = "1kb"
        app.get("health") { request async throws -> Response in
            try guardLocalRequest(request)
            return try json(Health(status: "ok", schemaVersion: 1, localOnly: true,
                                   sourceMode: upstream == nil || providerBudgets?.enabled != true ? "disabled" : "offline-configured"))
        }
        app.post("v1", "session", "enroll") { request async throws -> Response in
            await respond(request) {
                let invitation: String
                do { invitation = try sessionBody(request, key: "invitation", prefix: "inv1_") }
                catch { try await sessions.rejectEnrollmentAttempt(); throw SessionError.invalidRequest }
                return try json(try await sessions.enroll(invitation: invitation))
            }
        }
        app.post("v1", "session", "refresh") { request async throws -> Response in
            await respond(request) {
                let token: String
                do { token = try sessionBody(request, key: "refreshToken", prefix: "ref1_") }
                catch { try await sessions.rejectRefreshAttempt(); throw SessionError.invalidRequest }
                return try json(try await sessions.rotate(refreshToken: token))
            }
        }
        app.get("v1", "sources") { request async throws -> Response in
            await respond(request) {
                _ = try await authenticate(request)
                guard request.url.query == nil else { throw CacheError.invalidRequest("The sources endpoint does not accept query parameters.") }
                return try json(StoreLocation.defaults.map { location in
                    SourceStatus(store: location.store, storeCode: location.code,
                                 channel: location.store == .hmart ? .online : .inStore,
                                 fetchingEnabled: upstream != nil && providerBudgets?.enabled == true && SourceCapability.forLocation(location, channel: location.store == .hmart ? .online : .inStore).isConnected,
                                 publicAccessApproved: false,
                                 message: SourceCapability.forLocation(location, channel: location.store == .hmart ? .online : .inStore).message)
                })
            }
        }
        app.get("v1", "usage") { request async throws -> Response in
            await respond(request) {
                let principal = try await authenticate(request)
                guard request.url.query == nil else { throw CacheError.invalidRequest("The usage endpoint does not accept query parameters.") }
                guard let providerBudgets else { throw ProviderBudgetError.disabled }
                return try json(try await providerBudgets.ledger.usage(for: principal))
            }
        }
        app.get("v1", "price") { request async throws -> Response in
            await respond(request) {
                let principal = try await authenticate(request)
                let (context, parameter) = try parse(request, parameter: "productID")
                guard let upstream, let providerBudgets else { return try unavailable() }
                let result = try await cache.admittedPrice(context: context, productID: parameter, admit: {
                    let admitted = try await providerBudgets.admit(principal: principal)
                    return CacheFetchOperation(run: { try await upstream.price(context: context, productID: parameter, requests: admitted.requests) }, finish: { try await admitted.finish() })
                })
                return try json(SharedPriceResponse(context: SharedPriceContext(location: context.location, channel: context.channel),
                                                    value: result.value, cacheHit: result.cacheHit, servedAt: now()))
            }
        }
        app.get("v1", "search") { request async throws -> Response in
            await respond(request) {
                let principal = try await authenticate(request)
                let (context, parameter) = try parse(request, parameter: "q")
                guard let upstream, let providerBudgets else { return try unavailable() }
                let result = try await cache.admittedSearch(context: context, query: parameter, admit: {
                    let admitted = try await providerBudgets.admit(principal: principal)
                    return CacheFetchOperation(run: { try await upstream.search(context: context, query: parameter, requests: admitted.requests) }, finish: { try await admitted.finish() })
                })
                return try json(SharedSearchResponse(context: SharedPriceContext(location: context.location, channel: context.channel),
                                                     page: result.page, cacheHit: result.cacheHit, servedAt: now()))
            }
        }
    }

    private func guardLocalRequest(_ request: Request, allowsBody: Bool = false) throws {
        let hosts = request.headers["Host"]
        let host = hosts.first?.lowercased() ?? ""
        let allowed = host == "localhost" || host == "127.0.0.1" || host == "[::1]"
            || host.range(of: #"^(localhost|127\.0\.0\.1|\[::1\]):[0-9]{1,5}$"#, options: .regularExpression) != nil
        guard hosts.count == 1, allowed, request.headers["Origin"].isEmpty,
              request.url.string.utf8.count <= 2048, allowsBody || request.body.data?.readableBytes ?? 0 == 0 else {
            throw CacheError.invalidRequest("Only local requests without an Origin or request body are supported.")
        }
    }

    private func authenticate(_ request: Request) async throws -> ClientPrincipal {
        try guardLocalRequest(request)
        let headers = request.headers["Authorization"]
        guard headers.count == 1, headers[0].hasPrefix("Bearer "), headers[0].utf8.count <= 128 else {
            try await sessions.rejectAuthenticationAttempt()
            throw SessionError.invalidCredential
        }
        return try await sessions.authenticate(accessToken: String(headers[0].dropFirst(7)))
    }

    private func sessionBody(_ request: Request, key: String, prefix: String) throws -> String {
        try guardLocalRequest(request, allowsBody: true)
        guard request.url.query == nil, request.headers["Authorization"].isEmpty,
              request.headers["Content-Type"] == ["application/json"], let data = request.body.data,
              (1...1_024).contains(data.readableBytes), let body = data.getString(at: data.readerIndex, length: data.readableBytes) else {
            throw SessionError.invalidRequest
        }
        // Exactly two ASCII JSON members, in either order. This deliberately
        // rejects duplicate/unknown/escaped keys and credential escapes rather
        // than letting a JSON dictionary silently collapse duplicate members.
        let space = "[ \\t\\r\\n]*"
        let version = "\"schemaVersion\"" + space + ":" + space + "1"
        let credential = "\"" + key + "\"" + space + ":" + space + "\"(" + prefix + "[0-9a-f]{64})\""
        for members in [version + space + "," + space + credential, credential + space + "," + space + version] {
            let regex = try NSRegularExpression(pattern: "\\A" + space + "\\{" + space + members + space + "\\}" + space + "\\z")
            if let match = regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)), let range = Range(match.range(at: 1), in: body) {
                return String(body[range])
            }
        }
        throw SessionError.invalidRequest
    }

    private func parse(_ request: Request, parameter: String) throws -> (PriceContext, String) {
        guard let parts = URLComponents(string: request.url.string), let items = parts.queryItems,
              (3...4).contains(items.count), Set(items.map(\.name)).count == items.count,
              items.allSatisfy({ ["store", "storeCode", "channel", parameter].contains($0.name) && $0.value != nil }) else {
            throw CacheError.invalidRequest("Use one store, optional storeCode, channel, and product query.")
        }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
        guard let storeName = values["store"], let store = StoreID(rawValue: storeName),
              let channelName = values["channel"], let channel = StapleScoutKit.Channel(rawValue: channelName),
              let value = values[parameter] else { throw CacheError.invalidRequest("The store, channel, or query is missing or invalid.") }
        let context = try PriceContext(store: store, storeCode: values["storeCode"], channel: channel)
        if parameter == "q" {
            guard (2...100).contains(value.trimmingCharacters(in: .whitespacesAndNewlines).count),
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw CacheError.invalidRequest("Enter a query between 2 and 100 characters without controls.")
            }
        } else {
            let pattern = store == .hmart ? #"^[0-9]{1,20}:[0-9]{1,20}$"# : #"^[0-9]{1,20}$"#
            guard value.range(of: pattern, options: .regularExpression) != nil else { throw CacheError.invalidRequest("The product identity is invalid.") }
        }
        return (context, value)
    }

    private func unavailable() throws -> Response {
        try json(SharedAPIError(code: "source_access_not_configured", message: "Live sources are disabled. Public price access has not been configured."), status: .serviceUnavailable)
    }
    private func respond(_ request: Request, action: () async throws -> Response) async -> Response {
        do { return try await action() }
        catch {
            let status: HTTPResponseStatus
            let code: String
            let message: String
            switch error {
            case SessionError.invalidRequest: status = .badRequest; code = "invalid_request"; message = "The session request is invalid."
            case SessionError.invalidCredential: status = .unauthorized; code = "auth_invalid"; message = "A valid individual access credential is required."
            case SessionError.expiredCredential: status = .unauthorized; code = "auth_expired"; message = "The session credential has expired."
            case SessionError.revokedCredential: status = .unauthorized; code = "auth_revoked"; message = "This client or session has been revoked."
            case SessionError.invitationInvalid: status = .unauthorized; code = "invitation_invalid"; message = "The invitation is invalid."
            case SessionError.invitationExpired: status = .unauthorized; code = "invitation_expired"; message = "The invitation has expired."
            case SessionError.invitationUsed: status = .conflict; code = "invitation_used"; message = "The invitation has already been used."
            case SessionError.refreshReplay: status = .unauthorized; code = "refresh_replayed"; message = "Refresh reuse revoked this session. Obtain a new operator invitation."
            case SessionError.rateLimited: status = .tooManyRequests; code = "request_limit"; message = "The client or enrollment request limit was reached."
            case SessionError.storageUnavailable, SessionError.entropyUnavailable: status = .serviceUnavailable; code = "auth_unavailable"; message = "Session storage is unavailable."
            case ProviderBudgetError.disabled: status = .serviceUnavailable; code = "provider_disabled"; message = "Provider fetching is disabled."
            case ProviderBudgetError.providerLimit: status = .tooManyRequests; code = "provider_budget_exhausted"; message = "The provider reservation limit was reached."
            case ProviderBudgetError.clientLimit: status = .tooManyRequests; code = "client_provider_limit"; message = "This client's upstream reservation limit was reached."
            case ProviderBudgetError.workPending, CacheError.pending: status = .tooManyRequests; code = "work_pending"; message = "Bounded upstream work is already pending."
            case ProviderBudgetError.operationLimit: status = .tooManyRequests; code = "operation_limit"; message = "The maximum upstream operations for this miss was reached."
            case ProviderBudgetError.storageUnavailable: status = .serviceUnavailable; code = "provider_storage_unavailable"; message = "Provider reservation storage is unavailable."
            case ProviderBudgetError.invalidRequest: status = .badRequest; code = "invalid_request"; message = "The provider request is invalid."
            case CacheError.invalidRequest: status = .badRequest; code = "invalid_request"; message = "The store context or product query is invalid."
            case CacheError.budgetExceeded: status = .tooManyRequests; code = "budget_exceeded"; message = "The shared upstream attempt limit was reached."
            case CacheError.alreadyAttempted: status = .tooManyRequests; code = "attempted_today"; message = "This request was already attempted today; no usable cached evidence is available."
            case CacheError.storage: status = .serviceUnavailable; code = "storage_unavailable"; message = "Shared evidence storage is unavailable."
            default: status = .badGateway; code = "source_unavailable"; message = "The source did not return usable price evidence."
            }
            return (try? json(SharedAPIError(code: code, message: message), status: status)) ?? Response(status: .internalServerError)
        }
    }
    private func json<T: Encodable>(_ value: T, status: HTTPResponseStatus = .ok) throws -> Response {
        Response(status: status, headers: ["Content-Type": "application/json", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"],
                 body: .init(data: try SharedMarketWire.encoder().encode(value)))
    }
    private struct Health: Encodable { let status: String; let schemaVersion: Int; let localOnly: Bool; let sourceMode: String }
    private struct SourceStatus: Encodable {
        let store: StoreID; let storeCode: String?; let channel: StapleScoutKit.Channel
        let fetchingEnabled: Bool; let publicAccessApproved: Bool; let message: String
    }
}

/// Covers body collection and routing failures before the handlers. Vapor's
/// default ErrorMiddleware logs errors with request context, so it is replaced.
private struct QuietBoundaryErrors: AsyncMiddleware {
    let sessions: ClientSessionStore
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        do { return try await next.respond(to: request) }
        catch {
            var status = HTTPResponseStatus.badRequest
            var code = "invalid_request"
            if request.url.path == "/v1/session/enroll" {
                do { try await sessions.rejectEnrollmentAttempt() }
                catch SessionError.rateLimited { status = .tooManyRequests; code = "request_limit" }
                catch { status = .serviceUnavailable; code = "auth_unavailable" }
            } else if request.url.path == "/v1/session/refresh" {
                do { try await sessions.rejectRefreshAttempt() }
                catch SessionError.rateLimited { status = .tooManyRequests; code = "request_limit" }
                catch { status = .serviceUnavailable; code = "auth_unavailable" }
            }
            let data = try SharedMarketWire.encoder().encode(SharedAPIError(code: code, message: "The request could not be processed."))
            return Response(status: status, headers: ["Content-Type": "application/json", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"], body: .init(data: data))
        }
    }
}
