import Foundation
import ServiceOwnership

/// Invitation verification is real in every build. Only the injected clock and
/// isolated database differ in tests; there is no simulator/development bypass.
public actor ClientSessionStore {
    private let ownership: ServiceOwnership?
    private let database: SessionSQLite
    private let policy: SessionPolicy
    private let now: @Sendable () -> Date

    public init(databasePath: String, policy: SessionPolicy? = nil, ownership: ServiceOwnership? = nil, now: @escaping @Sendable () -> Date = { Date() }) throws {
        try ownership?.claimDatabase(databasePath)
        self.ownership = ownership
        self.policy = try policy ?? SessionPolicy()
        self.database = try SessionSQLite(path: databasePath)
        self.now = now
    }

    /// Operator-only API, reachable from the local admin executable, never HTTP.
    public func issueInvitation() throws -> IssuedInvitation {
        let invitation = try SessionCrypto.token(prefix: "inv1_")
        let clientID = try SessionCrypto.token(prefix: "client1_", bytes: 16)
        return try clockedTransaction { time in
            try prune(at: time)
            guard try database.scalar("SELECT COUNT(*) FROM auth_clients") < policy.maximumClients else { throw SessionError.clientLimitReached }
            try database.run("INSERT INTO auth_clients (client_id, created_at) VALUES (?, ?)", [clientID, String(time)])
            try database.run("INSERT INTO auth_invitations (invitation_hash, client_id, expires_at) VALUES (?, ?, ?)",
                             [SessionCrypto.hash(invitation), clientID, String(time + policy.invitationLifetime)])
            return IssuedInvitation(clientID: clientID, invitation: invitation, expiresAt: Date(timeIntervalSince1970: time + policy.invitationLifetime))
        }
    }

    public func enroll(invitation: String) throws -> ClientSessionTokens {
        return try clockedTransaction { time in
            try prune(at: time)
            try reserveEnrollment(at: time)
            guard SessionCrypto.isToken(invitation, prefix: "inv1_") else { throw SessionError.invitationInvalid }
            guard let row = try database.rows("SELECT i.*, c.revoked_at FROM auth_invitations i JOIN auth_clients c USING(client_id) WHERE invitation_hash = ?", [SessionCrypto.hash(invitation)]).first else { throw SessionError.invitationInvalid }
            guard row["revoked_at"] == nil else { throw SessionError.revokedCredential }
            guard row["used_at"] == nil else { throw SessionError.invitationUsed }
            guard try number(row, "expires_at") > time else { throw SessionError.invitationExpired }
            let clientID = try required(row, "client_id")
            let sessionID = try SessionCrypto.token(prefix: "session1_", bytes: 16)
            let tokens = try makeTokens(clientID: clientID, at: time)
            try database.run("UPDATE auth_invitations SET used_at = ? WHERE invitation_hash = ?", [String(time), SessionCrypto.hash(invitation)])
            try database.run("UPDATE auth_clients SET enrolled_at = ? WHERE client_id = ?", [String(time), clientID])
            try database.run("INSERT INTO auth_sessions (session_id, client_id, access_hash, refresh_hash, access_expires, refresh_expires) VALUES (?, ?, ?, ?, ?, ?)",
                             [sessionID, clientID, SessionCrypto.hash(tokens.accessToken), SessionCrypto.hash(tokens.refreshToken), String(tokens.accessExpiresAt.timeIntervalSince1970), String(tokens.refreshExpiresAt.timeIntervalSince1970)])
            return tokens
        }
    }

    /// Count malformed enrollment bodies too, without persisting their contents.
    public func rejectEnrollmentAttempt() throws {
        try clockedTransaction { time in try prune(at: time); try reserveEnrollment(at: time) }
    }

    public func rotate(refreshToken: String) throws -> ClientSessionTokens {
        return try clockedTransaction { time in
            try prune(at: time)
            try reserve(scope: "hour:refresh", period: hour(time), limit: policy.refreshHourlyAttempts)
            guard SessionCrypto.isToken(refreshToken, prefix: "ref1_") else { throw SessionError.invalidCredential }
            let hash = SessionCrypto.hash(refreshToken)
            if let spent = try database.rows("SELECT session_id FROM auth_refresh_history WHERE refresh_hash = ? AND expires_at > ?", [hash, String(time)]).first {
                try database.run("UPDATE auth_sessions SET revoked_at = COALESCE(revoked_at, ?) WHERE session_id = ?", [String(time), try required(spent, "session_id")])
                throw SessionError.refreshReplay
            }
            guard let row = try database.rows("SELECT s.*, c.revoked_at AS client_revoked FROM auth_sessions s JOIN auth_clients c USING(client_id) WHERE refresh_hash = ?", [hash]).first else { throw SessionError.invalidCredential }
            guard row["revoked_at"] == nil, row["client_revoked"] == nil else { throw SessionError.revokedCredential }
            guard try number(row, "refresh_expires") > time else { throw SessionError.expiredCredential }
            let clientID = try required(row, "client_id")
            try reserve(scope: "day:rotations:" + clientID, period: day(time), limit: policy.clientDailyRotations)
            let tokens = try makeTokens(clientID: clientID, at: time)
            try database.run("INSERT INTO auth_refresh_history (refresh_hash, session_id, expires_at) VALUES (?, ?, ?)", [hash, try required(row, "session_id"), try required(row, "refresh_expires")])
            try database.run("UPDATE auth_sessions SET access_hash = ?, refresh_hash = ?, access_expires = ?, refresh_expires = ?, generation = generation + 1 WHERE session_id = ?",
                             [SessionCrypto.hash(tokens.accessToken), SessionCrypto.hash(tokens.refreshToken), String(tokens.accessExpiresAt.timeIntervalSince1970), String(tokens.refreshExpiresAt.timeIntervalSince1970), try required(row, "session_id")])
            return tokens
        }
    }

    public func rejectRefreshAttempt() throws {
        try clockedTransaction { time in try prune(at: time); try reserve(scope: "hour:refresh", period: hour(time), limit: policy.refreshHourlyAttempts) }
    }

    /// Quotas follow server identity across credential rotation and cache hits.
    /// The credential itself never becomes a quota key or a cache key.
    public func authenticate(accessToken: String) throws -> ClientPrincipal {
        return try clockedTransaction { time in
            try prune(at: time)
            guard SessionCrypto.isToken(accessToken, prefix: "acc1_") else {
                try reserveInvalidAuth(at: time); throw SessionError.invalidCredential
            }
            guard let row = try database.rows("SELECT s.*, c.revoked_at AS client_revoked FROM auth_sessions s JOIN auth_clients c USING(client_id) WHERE access_hash = ?", [SessionCrypto.hash(accessToken)]).first else {
                try reserveInvalidAuth(at: time); throw SessionError.invalidCredential
            }
            guard row["revoked_at"] == nil, row["client_revoked"] == nil else {
                try reserveInvalidAuth(at: time); throw SessionError.revokedCredential
            }
            guard try number(row, "access_expires") > time else {
                try reserveInvalidAuth(at: time); throw SessionError.expiredCredential
            }
            let clientID = try required(row, "client_id")
            try reserve(scope: "day:requests:" + clientID, period: day(time), limit: policy.clientDailyRequests)
            return ClientPrincipal(clientID: clientID)
        }
    }

    public func rejectAuthenticationAttempt() throws {
        try clockedTransaction { time in try prune(at: time); try reserveInvalidAuth(at: time) }
    }

    public func revoke(clientID: String) throws {
        guard clientID.utf8.count == 40, clientID.hasPrefix("client1_"), clientID.dropFirst(8).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw SessionError.invalidRequest }
        try clockedTransaction { time in
            guard try database.scalar("SELECT COUNT(*) FROM auth_clients WHERE client_id = ?", [clientID]) == 1 else { throw SessionError.invalidRequest }
            try database.run("UPDATE auth_clients SET revoked_at = COALESCE(revoked_at, ?) WHERE client_id = ?", [String(time), clientID])
            try database.run("UPDATE auth_sessions SET revoked_at = COALESCE(revoked_at, ?) WHERE client_id = ?", [String(time), clientID])
        }
    }

    /// Operator-only reduction, requiring the exclusive owner of all databases.
    /// A stable deleted client tombstone remains: a slot can never be recycled.
    public func purgeRetainedData(deleting clientID: String? = nil) throws {
        guard let ownership else { throw SessionError.storageUnavailable }
        try ownership.validate()
        try clockedTransaction { time in
            try prune(at: time)
            if let clientID {
                guard clientID.count == 40, clientID.hasPrefix("client1_"), clientID.dropFirst(8).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                      try database.scalar("SELECT COUNT(*) FROM auth_clients WHERE client_id = ?", [clientID]) == 1 else { throw SessionError.invalidRequest }
                // Revocation and deletion are one transaction; crash cannot
                // remove denial while leaving usable credentials behind.
                try database.run("UPDATE auth_clients SET revoked_at = COALESCE(revoked_at, ?), deleted_at = COALESCE(deleted_at, ?), enrolled_at = NULL WHERE client_id = ?", [String(time), String(time), clientID])
            }
            try database.run("DELETE FROM auth_refresh_history WHERE session_id IN (SELECT s.session_id FROM auth_sessions s JOIN auth_clients c USING(client_id) WHERE c.deleted_at IS NOT NULL OR c.revoked_at IS NOT NULL OR s.revoked_at IS NOT NULL OR s.refresh_expires <= ?)", [String(time)])
            try database.run("DELETE FROM auth_sessions WHERE client_id IN (SELECT client_id FROM auth_clients WHERE deleted_at IS NOT NULL OR revoked_at IS NOT NULL) OR revoked_at IS NOT NULL OR refresh_expires <= ?", [String(time)])
            try database.run("DELETE FROM auth_invitations WHERE client_id IN (SELECT client_id FROM auth_clients WHERE deleted_at IS NOT NULL OR revoked_at IS NOT NULL) OR expires_at <= ?", [String(time)])
        }
        try database.checkpoint()
        try ownership.validate()
    }
    private func clockedTransaction<T>(_ body: (Double) throws -> T) throws -> T {
        try ownership?.validate()
        return try database.transaction { try body(database.clampedTime(timestamp())) }
    }
    private func makeTokens(clientID: String, at time: TimeInterval) throws -> ClientSessionTokens {
        ClientSessionTokens(clientID: clientID, accessToken: try SessionCrypto.token(prefix: "acc1_"),
                            accessExpiresAt: Date(timeIntervalSince1970: time + policy.accessLifetime),
                            refreshToken: try SessionCrypto.token(prefix: "ref1_"),
                            refreshExpiresAt: Date(timeIntervalSince1970: time + policy.refreshLifetime))
    }
    private func reserveEnrollment(at time: TimeInterval) throws {
        try reserve(scope: "hour:enroll", period: hour(time), limit: policy.enrollmentHourlyAttempts)
        try reserve(scope: "day:enroll", period: day(time), limit: policy.enrollmentDailyAttempts)
    }
    private func reserveInvalidAuth(at time: TimeInterval) throws {
        try reserve(scope: "hour:invalid-auth", period: hour(time), limit: policy.invalidAuthHourlyAttempts)
    }
    private func reserve(scope: String, period: Int, limit: Int) throws {
        let count = try database.scalar("SELECT COALESCE(MAX(attempts), 0) FROM auth_attempts WHERE scope = ? AND period = ?", [scope, String(period)])
        guard count < limit else { throw SessionError.rateLimited }
        try database.run("INSERT INTO auth_attempts (scope, period, attempts) VALUES (?, ?, 1) ON CONFLICT(scope, period) DO UPDATE SET attempts = attempts + 1", [scope, String(period)])
    }
    private func prune(at time: TimeInterval) throws {
        try database.run("DELETE FROM auth_refresh_history WHERE rowid IN (SELECT rowid FROM auth_refresh_history WHERE expires_at <= ? LIMIT 5000)", [String(time)])
        try database.run("DELETE FROM auth_attempts WHERE rowid IN (SELECT rowid FROM auth_attempts WHERE (scope LIKE 'hour:%' AND period < ?) OR (scope LIKE 'day:%' AND period < ?) LIMIT 5000)", [String(hour(time)), String(day(time))])
    }
    private func hour(_ time: TimeInterval) -> Int { Int(time / 3_600) }
    private func day(_ time: TimeInterval) -> Int { Int(time / 86_400) }
    private func timestamp() throws -> TimeInterval {
        let value = now().timeIntervalSince1970
        guard value.isFinite, (0..<253_402_300_800).contains(value) else { throw SessionError.storageUnavailable }
        return value
    }
    private func required(_ row: [String: String], _ key: String) throws -> String {
        guard let value = row[key] else { throw SessionError.storageUnavailable }; return value
    }
    private func number(_ row: [String: String], _ key: String) throws -> Double {
        guard let value = Double(try required(row, key)), value.isFinite else { throw SessionError.storageUnavailable }; return value
    }
}
