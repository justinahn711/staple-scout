import Foundation
import Testing
import Vapor
import VaporTesting
import MarketHTTP
import ClientSessions
import SharedMarketCore
import StapleScoutKit

@Suite(.serialized)
struct SessionHTTPTests {
    private let instant = Date(timeIntervalSince1970: 1_792_382_400)
    private let pricePath = "/v1/price?store=wegmans&storeCode=133&channel=in_store&productID=123"
    private let searchPath = "/v1/search?store=wegmans&storeCode=133&channel=in_store&q=milk"
    private var jsonHeaders: HTTPHeaders { ["Host": "localhost", "Content-Type": "application/json"] }

    @Test func realInvitationEnrollmentProtectsEveryEndpointWithoutGlobalTokenFallback() async throws {
        let sessions = try ClientSessionStore(databasePath: ":memory:", now: { instant })
        let invitation = try await sessions.issueInvitation()
        let service = MarketService(cache: try SharedPriceCache(databasePath: ":memory:"), sessions: sessions)
        try await withApp(configure: { service.configure($0) }) { app in
            let tester = try app.testing()
            let response = try await tester.sendRequest(.POST, "/v1/session/enroll", headers: jsonHeaders, body: body("invitation", invitation.invitation))
            #expect(response.status == .ok)
            #expect(response.headers.first(name: "Cache-Control") == "no-store")
            let tokens = try SharedMarketWire.decoder().decode(ClientSessionTokens.self, from: Data(response.body.readableBytesView))
            #expect(tokens.clientID == invitation.clientID)
            #expect(tokens.accessToken.hasPrefix("acc1_"))
            #expect(tokens.refreshToken.hasPrefix("ref1_"))
            #expect(!response.body.string.contains(invitation.invitation))
            let raw = try #require(JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
            #expect(raw["schemaVersion"] as? Int == 1)
            #expect(raw["accessExpiresAt"] as? Double == instant.addingTimeInterval(900).timeIntervalSince1970 * 1_000)
            for path in ["/v1/sources", pricePath, searchPath] {
                for headers: HTTPHeaders in [["Host": "localhost"], ["Host": "localhost", "Authorization": "Bearer " + String(repeating: "x", count: 40)]] {
                    try await tester.test(.GET, path, headers: headers) { response in
                        #expect(response.status == .unauthorized)
                        #expect(response.body.string.contains("auth_invalid"))
                        #expect(!response.body.string.contains("xxxx"))
                    }
                }
                try await tester.test(.GET, path, headers: auth(tokens.accessToken)) { response in
                    #expect(response.status == (path == "/v1/sources" ? .ok : .serviceUnavailable))
                }
            }
            try await tester.test(.GET, "/health", headers: ["Host": "localhost"]) { response in
                #expect(response.status == .ok)
                #expect(!response.body.string.contains(tokens.clientID))
                #expect(!response.body.string.contains("sqlite"))
                #expect(!response.body.string.contains(tokens.accessToken))
            }
        }
    }

    @Test func invitationReplayAndUnknownCredentialsHaveTypedSafeErrors() async throws {
        let sessions = try ClientSessionStore(databasePath: ":memory:", now: { instant })
        let invitation = try await sessions.issueInvitation()
        _ = try await sessions.enroll(invitation: invitation.invitation)
        let service = MarketService(cache: try SharedPriceCache(databasePath: ":memory:"), sessions: sessions)
        try await withApp(configure: { service.configure($0) }) { app in
            try await app.testing().test(.POST, "/v1/session/enroll", headers: jsonHeaders, body: body("invitation", invitation.invitation)) { response in
                #expect(response.status == .conflict)
                #expect(response.body.string.contains("invitation_used"))
                #expect(!response.body.string.contains(invitation.invitation))
            }
            for (key, prefix, route, code) in [("invitation", "inv1_", "enroll", "invitation_invalid"), ("refreshToken", "ref1_", "refresh", "auth_invalid")] {
                let secret = prefix + String(repeating: "0", count: 64)
                try await app.testing().test(.POST, "/v1/session/" + route, headers: jsonHeaders, body: body(key, secret)) { response in
                    #expect(response.status == .unauthorized)
                    #expect(response.body.string.contains(code))
                    #expect(!response.body.string.contains(secret))
                }
            }
        }
    }

    @Test func strictSmallSessionBodiesRejectDuplicatesUnknownKeysAndSecretsInURLs() async throws {
        let sessions = try ClientSessionStore(databasePath: ":memory:", now: { instant })
        let invitation = try await sessions.issueInvitation()
        let secret = invitation.invitation
        let service = MarketService(cache: try SharedPriceCache(databasePath: ":memory:"), sessions: sessions)
        try await withApp(configure: { service.configure($0) }) { app in
            let invalid = ["{}", "[]", "null", "{\"schemaVersion\":2,\"invitation\":\"\(secret)\"}",
                           "{\"schemaVersion\":1,\"schemaVersion\":1,\"invitation\":\"\(secret)\"}",
                           "{\"schemaVersion\":1,\"invitation\":\"\(secret)\",\"invitation\":\"\(secret)\"}",
                           "{\"schemaVersion\":1,\"invitation\":\"\(secret)\",\"userUUID\":\"private-sentinel\"}",
                           "{\"schemaVersion\":1,\"invitation\":\"inv1_bad\"}",
                           "{\"schemaVersion\":1.0,\"invitation\":\"\(secret)\"}",
                           "{\"schemaVersion\":1,\"invitation\":\"\(secret)\"}" + String(repeating: " ", count: 1_024)]
            for value in invalid {
                try await app.testing().test(.POST, "/v1/session/enroll", headers: jsonHeaders, body: ByteBuffer(string: value)) { response in
                    #expect(response.status == .badRequest)
                    #expect(response.body.string.contains("invalid_request"))
                    #expect(!response.body.string.contains(secret))
                    #expect(!response.body.string.contains("private-sentinel"))
                }
            }
            for route in ["/v1/session/enroll?invitation=" + secret, "/v1/session/enroll?extra=1"] {
                try await app.testing().test(.POST, route, headers: jsonHeaders, body: body("invitation", secret)) { #expect($0.status == .badRequest) }
            }
            var origin = jsonHeaders; origin.add(name: "Origin", value: "https://example.invalid")
            var remote = jsonHeaders; remote.replaceOrAdd(name: "Host", value: "example.invalid")
            var authorization = jsonHeaders; authorization.add(name: "Authorization", value: "Bearer " + secret)
            var contentType = jsonHeaders; contentType.replaceOrAdd(name: "Content-Type", value: "text/plain")
            for headers in [origin, remote, authorization, contentType] {
                try await app.testing().test(.POST, "/v1/session/enroll", headers: headers, body: body("invitation", secret)) { #expect($0.status == .badRequest) }
            }
            // Rejected shapes did not consume the one-use invitation itself.
            try await app.testing().test(.POST, "/v1/session/enroll", headers: jsonHeaders, body: body("invitation", secret, reversed: true)) { #expect($0.status == .ok) }
        }
    }

    @Test func expirationRotationAndReplayProtectAllPriceAndSourceRoutes() async throws {
        let clock = HTTPAuthClock(instant)
        let policy = try SessionPolicy(accessLifetime: 5, refreshLifetime: 60)
        let sessions = try ClientSessionStore(databasePath: ":memory:", policy: policy, now: { clock.read() })
        let tokens = try await sessions.enroll(invitation: sessions.issueInvitation().invitation)
        let service = MarketService(cache: try SharedPriceCache(databasePath: ":memory:"), sessions: sessions)
        clock.advance(5)
        try await withApp(configure: { service.configure($0) }) { app in
            for path in ["/v1/sources", pricePath, searchPath] {
                try await app.testing().test(.GET, path, headers: auth(tokens.accessToken)) { response in
                    #expect(response.status == .unauthorized)
                    #expect(response.body.string.contains("auth_expired"))
                }
            }
            let response = try await app.testing().sendRequest(.POST, "/v1/session/refresh", headers: jsonHeaders, body: body("refreshToken", tokens.refreshToken))
            #expect(response.status == .ok)
            let rotated = try SharedMarketWire.decoder().decode(ClientSessionTokens.self, from: Data(response.body.readableBytesView))
            #expect(rotated.clientID == tokens.clientID)
            #expect(rotated.accessToken != tokens.accessToken)
            try await app.testing().test(.GET, "/v1/sources", headers: auth(rotated.accessToken)) { #expect($0.status == .ok) }
            try await app.testing().test(.POST, "/v1/session/refresh", headers: jsonHeaders, body: body("refreshToken", tokens.refreshToken)) { response in
                #expect(response.status == .unauthorized)
                #expect(response.body.string.contains("refresh_replayed"))
            }
            for path in ["/v1/sources", pricePath, searchPath] {
                try await app.testing().test(.GET, path, headers: auth(rotated.accessToken)) { response in
                    #expect(response.status == .unauthorized)
                    #expect(response.body.string.contains("auth_revoked"))
                }
            }
        }
    }

    @Test func malformedEnrollmentAttemptsAreReservedAndRateLimitedBeforeMinting() async throws {
        let policy = try SessionPolicy(enrollmentHourlyAttempts: 2)
        let sessions = try ClientSessionStore(databasePath: ":memory:", policy: policy, now: { instant })
        let invitation = try await sessions.issueInvitation()
        let service = MarketService(cache: try SharedPriceCache(databasePath: ":memory:"), sessions: sessions)
        try await withApp(configure: { service.configure($0) }) { app in
            for _ in 0..<2 {
                try await app.testing().test(.POST, "/v1/session/enroll", headers: jsonHeaders, body: ByteBuffer(string: "{}")) { #expect($0.status == .badRequest) }
            }
            try await app.testing().test(.POST, "/v1/session/enroll", headers: jsonHeaders, body: body("invitation", invitation.invitation)) { response in
                #expect(response.status == .tooManyRequests)
                #expect(response.body.string.contains("request_limit"))
                #expect(!response.body.string.contains(invitation.invitation))
                #expect(!response.body.string.contains("accessToken"))
            }
        }
    }

    @Test func perClientQuotaIncludesSourcesAndDoesNotResetAfterRefresh() async throws {
        let policy = try SessionPolicy(clientDailyRequests: 1)
        let sessions = try ClientSessionStore(databasePath: ":memory:", policy: policy, now: { instant })
        let tokens = try await sessions.enroll(invitation: sessions.issueInvitation().invitation)
        let service = MarketService(cache: try SharedPriceCache(databasePath: ":memory:"), sessions: sessions)
        try await withApp(configure: { service.configure($0) }) { app in
            try await app.testing().test(.GET, "/v1/sources", headers: auth(tokens.accessToken)) { #expect($0.status == .ok) }
            let rotated = try await sessions.rotate(refreshToken: tokens.refreshToken)
            try await app.testing().test(.GET, pricePath, headers: auth(rotated.accessToken)) { response in
                #expect(response.status == .tooManyRequests)
                #expect(response.body.string.contains("request_limit"))
                #expect(!response.body.string.contains("source_access_not_configured"))
            }
        }
    }

    private func body(_ key: String, _ token: String, reversed: Bool = false) -> ByteBuffer {
        ByteBuffer(string: reversed ? "{ \"\(key)\": \"\(token)\", \"schemaVersion\": 1 }" : "{\"schemaVersion\":1,\"\(key)\":\"\(token)\"}")
    }
    private func auth(_ token: String) -> HTTPHeaders { ["Host": "localhost", "Authorization": "Bearer " + token] }
}

private final class HTTPAuthClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; date = date.addingTimeInterval(seconds) }
}
