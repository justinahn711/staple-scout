import Foundation

/// No device UUID, Apple identifier, name, email, IP address, or library data.
public struct ClientPrincipal: Sendable, Equatable {
    public let clientID: String
}

public struct IssuedInvitation: Codable, Sendable {
    public let schemaVersion: Int
    public let clientID: String
    public let invitation: String
    public let expiresAt: Date
    init(clientID: String, invitation: String, expiresAt: Date) {
        schemaVersion = 1; self.clientID = clientID; self.invitation = invitation; self.expiresAt = expiresAt
    }
}

public struct ClientSessionTokens: Codable, Sendable {
    public let schemaVersion: Int
    public let clientID: String
    public let tokenType: String
    public let accessToken: String
    public let accessExpiresAt: Date
    public let refreshToken: String
    public let refreshExpiresAt: Date
    init(clientID: String, accessToken: String, accessExpiresAt: Date, refreshToken: String, refreshExpiresAt: Date) {
        schemaVersion = 1; tokenType = "Bearer"; self.clientID = clientID
        self.accessToken = accessToken; self.accessExpiresAt = accessExpiresAt
        self.refreshToken = refreshToken; self.refreshExpiresAt = refreshExpiresAt
    }
}

public enum SessionError: Error, Sendable, Equatable {
    case invalidRequest, invalidCredential, expiredCredential, revokedCredential
    case invitationInvalid, invitationExpired, invitationUsed, refreshReplay
    case rateLimited, clientLimitReached, storageUnavailable, entropyUnavailable
}

public struct SessionPolicy: Sendable {
    public let accessLifetime: TimeInterval
    public let refreshLifetime: TimeInterval
    public let invitationLifetime: TimeInterval
    public let maximumClients: Int
    public let clientDailyRequests: Int
    public let enrollmentHourlyAttempts: Int
    public let enrollmentDailyAttempts: Int
    public let refreshHourlyAttempts: Int
    public let clientDailyRotations: Int
    public let invalidAuthHourlyAttempts: Int

    public init(accessLifetime: TimeInterval = 900, refreshLifetime: TimeInterval = 30 * 86_400,
                invitationLifetime: TimeInterval = 86_400, maximumClients: Int = 50,
                clientDailyRequests: Int = 1_000, enrollmentHourlyAttempts: Int = 100,
                enrollmentDailyAttempts: Int = 500, refreshHourlyAttempts: Int = 1_000,
                clientDailyRotations: Int = 100, invalidAuthHourlyAttempts: Int = 2_000) throws {
        guard (1...900).contains(accessLifetime), (1...30 * 86_400).contains(refreshLifetime),
              (1...3 * 86_400).contains(invitationLifetime), (1...50).contains(maximumClients),
              (1...100_000).contains(clientDailyRequests), (1...10_000).contains(enrollmentHourlyAttempts),
              (1...10_000).contains(enrollmentDailyAttempts), (1...10_000).contains(refreshHourlyAttempts),
              (1...100).contains(clientDailyRotations), (1...100_000).contains(invalidAuthHourlyAttempts) else {
            throw SessionError.invalidRequest
        }
        self.accessLifetime = accessLifetime; self.refreshLifetime = refreshLifetime
        self.invitationLifetime = invitationLifetime; self.maximumClients = maximumClients
        self.clientDailyRequests = clientDailyRequests; self.enrollmentHourlyAttempts = enrollmentHourlyAttempts
        self.enrollmentDailyAttempts = enrollmentDailyAttempts; self.refreshHourlyAttempts = refreshHourlyAttempts
        self.clientDailyRotations = clientDailyRotations; self.invalidAuthHourlyAttempts = invalidAuthHourlyAttempts
    }
}
