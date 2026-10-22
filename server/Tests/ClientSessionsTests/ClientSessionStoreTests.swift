import Foundation
import XCTest
import CSQLite
@testable import ClientSessions

final class ClientSessionStoreTests: XCTestCase, @unchecked Sendable {
    private let instant = Date(timeIntervalSince1970: 1_792_382_400)

    func testRealInvitationsYieldUniqueOpaqueCredentialsWithHashesOnlyAtRest() async throws {
        let path = try temporaryDatabase(); defer { removeDatabase(path) }
        let store = try ClientSessionStore(databasePath: path, now: { self.instant })
        let invitation = try await store.issueInvitation()
        let tokens = try await store.enroll(invitation: invitation.invitation)
        XCTAssertEqual(tokens.clientID, invitation.clientID)
        XCTAssertEqual(tokens.tokenType, "Bearer")
        XCTAssertEqual(tokens.schemaVersion, 1)
        XCTAssertEqual(tokens.accessExpiresAt, instant.addingTimeInterval(900))
        XCTAssertEqual(tokens.refreshExpiresAt, instant.addingTimeInterval(30 * 86_400))
        let principal = try await store.authenticate(accessToken: tokens.accessToken)
        XCTAssertEqual(principal.clientID, invitation.clientID)
        XCTAssertEqual(Set([invitation.invitation, tokens.accessToken, tokens.refreshToken]).count, 3)
        XCTAssertTrue(SessionCrypto.isToken(invitation.invitation, prefix: "inv1_"))
        XCTAssertTrue(SessionCrypto.isToken(tokens.accessToken, prefix: "acc1_"))
        XCTAssertTrue(SessionCrypto.isToken(tokens.refreshToken, prefix: "ref1_"))
        for suffix in ["", "-wal", "-shm"] {
            let data = try Data(contentsOf: URL(fileURLWithPath: path + suffix))
            for secret in [invitation.invitation, tokens.accessToken, tokens.refreshToken] { XCTAssertNil(data.range(of: Data(secret.utf8))) }
            let attributes = try FileManager.default.attributesOfItem(atPath: path + suffix)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testEnrollmentAndCredentialsPersistAndInvitationCannotReplayAfterRestart() async throws {
        let path = try temporaryDatabase(); defer { removeDatabase(path) }
        let first = try ClientSessionStore(databasePath: path, now: { self.instant })
        let invitation = try await first.issueInvitation()
        let tokens = try await first.enroll(invitation: invitation.invitation)
        let restarted = try ClientSessionStore(databasePath: path, now: { self.instant })
        await expect(.invitationUsed) { _ = try await restarted.enroll(invitation: invitation.invitation) }
        let principal = try await restarted.authenticate(accessToken: tokens.accessToken)
        XCTAssertEqual(principal.clientID, invitation.clientID)
        let rotated = try await restarted.rotate(refreshToken: tokens.refreshToken)
        XCTAssertEqual(rotated.clientID, invitation.clientID)
        XCTAssertNotEqual(rotated.accessToken, tokens.accessToken)
        XCTAssertNotEqual(rotated.refreshToken, tokens.refreshToken)
        await expect(.invalidCredential) { _ = try await first.authenticate(accessToken: tokens.accessToken) }
        _ = try await first.authenticate(accessToken: rotated.accessToken)
    }

    func testExpiredInvitationAccessAndRefreshFailAtExactBoundaries() async throws {
        let clock = SessionTestClock(instant)
        let policy = try SessionPolicy(accessLifetime: 10, refreshLifetime: 20, invitationLifetime: 30)
        let store = try ClientSessionStore(databasePath: ":memory:", policy: policy, now: { clock.read() })
        let invitation = try await store.issueInvitation()
        let tokens = try await store.enroll(invitation: invitation.invitation)
        let pending = try await store.issueInvitation()
        clock.advance(10)
        await expect(.expiredCredential) { _ = try await store.authenticate(accessToken: tokens.accessToken) }
        clock.advance(10)
        await expect(.expiredCredential) { _ = try await store.rotate(refreshToken: tokens.refreshToken) }
        clock.advance(10)
        await expect(.invitationExpired) { _ = try await store.enroll(invitation: pending.invitation) }
    }

    func testRevocationSurvivesRestartAndDoesNotRevokeOtherClients() async throws {
        let path = try temporaryDatabase(); defer { removeDatabase(path) }
        let first = try ClientSessionStore(databasePath: path, now: { self.instant })
        let invitation = try await first.issueInvitation()
        let tokens = try await first.enroll(invitation: invitation.invitation)
        let other = try await first.enroll(invitation: first.issueInvitation().invitation)
        let pending = try await first.issueInvitation()
        try await first.revoke(clientID: invitation.clientID)
        try await first.revoke(clientID: pending.clientID)
        let restarted = try ClientSessionStore(databasePath: path, now: { self.instant })
        await expect(.revokedCredential) { _ = try await restarted.authenticate(accessToken: tokens.accessToken) }
        await expect(.revokedCredential) { _ = try await restarted.rotate(refreshToken: tokens.refreshToken) }
        await expect(.revokedCredential) { _ = try await restarted.enroll(invitation: pending.invitation) }
        _ = try await restarted.authenticate(accessToken: other.accessToken)
    }

    func testSpentRefreshReplayAtomicallyRevokesTheWholeRotatedFamilyAfterRestart() async throws {
        let path = try temporaryDatabase(); defer { removeDatabase(path) }
        let first = try ClientSessionStore(databasePath: path, now: { self.instant })
        let tokens = try await first.enroll(invitation: first.issueInvitation().invitation)
        let rotated = try await first.rotate(refreshToken: tokens.refreshToken)
        let restarted = try ClientSessionStore(databasePath: path, now: { self.instant })
        await expect(.refreshReplay) { _ = try await restarted.rotate(refreshToken: tokens.refreshToken) }
        let third = try ClientSessionStore(databasePath: path, now: { self.instant })
        await expect(.revokedCredential) { _ = try await third.authenticate(accessToken: rotated.accessToken) }
        await expect(.revokedCredential) { _ = try await third.rotate(refreshToken: rotated.refreshToken) }
    }

    func testConcurrentConnectionsCanRedeemAnInvitationOnlyOnce() async throws {
        let path = try temporaryDatabase(); defer { removeDatabase(path) }
        let first = try ClientSessionStore(databasePath: path, now: { self.instant })
        let second = try ClientSessionStore(databasePath: path, now: { self.instant })
        let invitation = try await first.issueInvitation()
        let results = await withTaskGroup(of: Result<ClientSessionTokens, SessionError>.self) { group in
            for store in [first, second] { group.addTask { do { return .success(try await store.enroll(invitation: invitation.invitation)) } catch { return .failure((error as? SessionError) ?? .storageUnavailable) } } }
            var results: [Result<ClientSessionTokens, SessionError>] = []
            for await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(results.compactMap { try? $0.get() }.count, 1)
        XCTAssertEqual(results.filter { if case .failure(.invitationUsed) = $0 { return true }; return false }.count, 1)
    }

    func testConcurrentRefreshReplayRevokesEvenTheWinningRotation() async throws {
        let path = try temporaryDatabase(); defer { removeDatabase(path) }
        let first = try ClientSessionStore(databasePath: path, now: { self.instant })
        let second = try ClientSessionStore(databasePath: path, now: { self.instant })
        let tokens = try await first.enroll(invitation: first.issueInvitation().invitation)
        let results = await withTaskGroup(of: Result<ClientSessionTokens, SessionError>.self) { group in
            for store in [first, second] { group.addTask { do { return .success(try await store.rotate(refreshToken: tokens.refreshToken)) } catch { return .failure((error as? SessionError) ?? .storageUnavailable) } } }
            var results: [Result<ClientSessionTokens, SessionError>] = []
            for await result in group { results.append(result) }
            return results
        }
        let winners = results.compactMap { try? $0.get() }
        XCTAssertEqual(winners.count, 1)
        XCTAssertEqual(results.filter { if case .failure(.refreshReplay) = $0 { return true }; return false }.count, 1)
        let winner = try XCTUnwrap(winners.first)
        await expect(.revokedCredential) { _ = try await first.authenticate(accessToken: winner.accessToken) }
        await expect(.revokedCredential) { _ = try await second.rotate(refreshToken: winner.refreshToken) }
    }

    func testEnrollmentAttemptReservationsPersistAcrossConnectionsAndRestart() async throws {
        let path = try temporaryDatabase(); defer { removeDatabase(path) }
        let clock = SessionTestClock(instant)
        let policy = try SessionPolicy(enrollmentHourlyAttempts: 2, enrollmentDailyAttempts: 10)
        let first = try ClientSessionStore(databasePath: path, policy: policy, now: { clock.read() })
        let invitation = try await first.issueInvitation()
        await expect(.invitationInvalid) { _ = try await first.enroll(invitation: "invalid") }
        let restarted = try ClientSessionStore(databasePath: path, policy: policy, now: { clock.read() })
        try await restarted.rejectEnrollmentAttempt()
        await expect(.rateLimited) { _ = try await first.enroll(invitation: invitation.invitation) }
        clock.advance(3_600)
        _ = try await restarted.enroll(invitation: invitation.invitation)
    }

    func testStableIdentityQuotaCannotBeResetByRotationOrConnectionChange() async throws {
        let path = try temporaryDatabase(); defer { removeDatabase(path) }
        let policy = try SessionPolicy(clientDailyRequests: 2)
        let first = try ClientSessionStore(databasePath: path, policy: policy, now: { self.instant })
        let tokens = try await first.enroll(invitation: first.issueInvitation().invitation)
        _ = try await first.authenticate(accessToken: tokens.accessToken)
        let rotated = try await first.rotate(refreshToken: tokens.refreshToken)
        let second = try ClientSessionStore(databasePath: path, policy: policy, now: { self.instant })
        let principal = try await second.authenticate(accessToken: rotated.accessToken)
        XCTAssertEqual(principal.clientID, tokens.clientID)
        await expect(.rateLimited) { _ = try await first.authenticate(accessToken: rotated.accessToken) }
        let other = try await second.enroll(invitation: second.issueInvitation().invitation)
        _ = try await second.authenticate(accessToken: other.accessToken)
    }

    func testRotationLimitAndExpiredReplayHistoryAreBounded() async throws {
        let clock = SessionTestClock(instant)
        let policy = try SessionPolicy(accessLifetime: 1, refreshLifetime: 2, clientDailyRotations: 1)
        let store = try ClientSessionStore(databasePath: ":memory:", policy: policy, now: { clock.read() })
        let tokens = try await store.enroll(invitation: store.issueInvitation().invitation)
        let rotated = try await store.rotate(refreshToken: tokens.refreshToken)
        await expect(.rateLimited) { _ = try await store.rotate(refreshToken: rotated.refreshToken) }
        clock.advance(3)
        // A retired refresh tombstone is removed only after that credential
        // could no longer have been valid; it cannot revive a session.
        await expect(.invalidCredential) { _ = try await store.rotate(refreshToken: tokens.refreshToken) }
        await expect(.expiredCredential) { _ = try await store.rotate(refreshToken: rotated.refreshToken) }
    }

    func testUnknownMalformedWrongPurposeCredentialsAndInvalidAuthLimits() async throws {
        let policy = try SessionPolicy(invalidAuthHourlyAttempts: 2)
        let store = try ClientSessionStore(databasePath: ":memory:", policy: policy, now: { self.instant })
        let invitation = try await store.issueInvitation()
        let tokens = try await store.enroll(invitation: invitation.invitation)
        await expect(.invalidCredential) { _ = try await store.authenticate(accessToken: tokens.refreshToken) }
        await expect(.invalidCredential) { _ = try await store.authenticate(accessToken: "acc1_" + String(repeating: "0", count: 64)) }
        await expect(.rateLimited) { try await store.rejectAuthenticationAttempt() }
        // Random invalid traffic does not consume a known client's own quota.
        _ = try await store.authenticate(accessToken: tokens.accessToken)
        await expect(.invalidCredential) { _ = try await store.rotate(refreshToken: tokens.accessToken) }
    }

    func testClientCapCannotBeBypassedByConcurrentIssuanceOrRevocation() async throws {
        let policy = try SessionPolicy(maximumClients: 1)
        let store = try ClientSessionStore(databasePath: ":memory:", policy: policy)
        let invitation = try await store.issueInvitation()
        await expect(.clientLimitReached) { _ = try await store.issueInvitation() }
        try await store.revoke(clientID: invitation.clientID)
        await expect(.clientLimitReached) { _ = try await store.issueInvitation() }
    }

    func testAuthDatabaseRejectsAliasAndUnrelatedSchemaWithoutChangingIt() throws {
        let path = try temporaryDatabase(); defer { removeDatabase(path) }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE unrelated_private_data (value TEXT); INSERT INTO unrelated_private_data VALUES ('synthetic only'); PRAGMA user_version=7;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try ClientSessionStore(databasePath: path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
        XCTAssertThrowsError(try SessionDatabasePaths.validate(authPath: path, cachePath: path))
        let alias = path + ".alias"
        try FileManager.default.linkItem(atPath: path, toPath: alias)
        XCTAssertThrowsError(try SessionDatabasePaths.validate(authPath: alias, cachePath: path))
        try FileManager.default.removeItem(atPath: alias)
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: path)
        XCTAssertThrowsError(try SessionDatabasePaths.validate(authPath: alias, cachePath: path))
        XCTAssertThrowsError(try ClientSessionStore(databasePath: alias))
        try FileManager.default.removeItem(atPath: alias)
    }

    func testPermissiveExistingAuthPathIsRejectedWithoutChmodOrContentChanges() throws {
        let path = try temporaryDatabase(); defer { removeDatabase(path) }
        try Data("synthetic non-database".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        XCTAssertThrowsError(try ClientSessionStore(databasePath: path))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "synthetic non-database")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue, 0o644)
    }

    func testInterruptedBootstrapRollsBackSchemaAndCanRecoverOnReopen() async throws {
        let path = try temporaryDatabase(); defer { removeDatabase(path) }
        XCTAssertThrowsError(try SessionSQLite(path: path, bootstrapCheckpoint: { throw SessionError.storageUnavailable }))
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(connection, "SELECT COUNT(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 0)
        sqlite3_finalize(statement)
        let recovered = try ClientSessionStore(databasePath: path, now: { self.instant })
        let invitation = try await recovered.issueInvitation()
        let tokens = try await recovered.enroll(invitation: invitation.invitation)
        _ = try await recovered.authenticate(accessToken: tokens.accessToken)
    }

    func testAdminSubprocessRevocationIsVisibleToAnAlreadyOpenStore() async throws {
        let path = try temporaryDatabase(); defer { removeDatabase(path) }
        let running = try ClientSessionStore(databasePath: path)
        let original = try await running.enroll(invitation: running.issueInvitation().invitation)
        _ = try await running.authenticate(accessToken: original.accessToken)
        let invitationPath = path + ".invitation.json"
        try runAdmin(["invite", invitationPath], databasePath: path)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let invitation = try decoder.decode(IssuedInvitation.self, from: Data(contentsOf: URL(fileURLWithPath: invitationPath)))
        let tokens = try await running.enroll(invitation: invitation.invitation)
        _ = try await running.authenticate(accessToken: tokens.accessToken)
        try runAdmin(["revoke", tokens.clientID], databasePath: path)
        // Opening/checking/closing raw DB or SHM descriptors in the admin
        // process must not invalidate SQLite locks and leave this store stale.
        await expect(.revokedCredential) { _ = try await running.authenticate(accessToken: tokens.accessToken) }
        await expect(.revokedCredential) { _ = try await running.rotate(refreshToken: tokens.refreshToken) }
        _ = try await running.authenticate(accessToken: original.accessToken)
        let reopened = try ClientSessionStore(databasePath: path)
        await expect(.revokedCredential) { _ = try await reopened.authenticate(accessToken: tokens.accessToken) }
    }

    private func runAdmin(_ arguments: [String], databasePath: String) throws {
        var directory = Bundle(for: ClientSessionStoreTests.self).bundleURL
        var executable: URL?
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("ThriftyMarketSessionAdmin")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { executable = candidate; break }
            directory.deleteLastPathComponent()
        }
        let process = Process()
        process.executableURL = try XCTUnwrap(executable, "swift test must build the session admin product")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["THRIFTY_AUTH_DATABASE_PATH"] = databasePath
        environment["THRIFTY_DATABASE_PATH"] = databasePath + ".cache"
        process.environment = environment
        process.standardOutput = Pipe(); process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "The local admin fixture failed; credential output is intentionally suppressed")
    }

    private func expect(_ expected: SessionError, file: StaticString = #filePath, line: UInt = #line, action: () async throws -> Void) async {
        do { try await action(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch let error as SessionError { XCTAssertEqual(error, expected, file: file, line: line) }
        catch { XCTFail("Unexpected error type", file: file, line: line) }
    }
    private func temporaryDatabase() throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("thrifty-sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory.appendingPathComponent("auth.sqlite").path
    }
    private func removeDatabase(_ path: String) { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
}

private final class SessionTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; date = date.addingTimeInterval(seconds) }
}
