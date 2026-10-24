import Foundation
import XCTest
@testable import StapleScoutKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class NativeSessionTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_790_000_000)
    private let invitation = "inv1_" + String(repeating: "a", count: 64)
    private let endpoint = try! SessionEndpoint(url: URL(string: "https://pilot.example.invalid")!)
    override func tearDown() { NativeSessionStub.reset(); super.tearDown() }

    func testDedicatedEndpointRejectsMissingUnsafeAndNonHTTPSConfiguration() throws {
        for text in ["http://pilot.example.invalid", "http://127.0.0.1:8878", "https://u:p@pilot.example.invalid", "https://pilot.example.invalid?key=secret", "https://pilot.example.invalid#token", "https://pilot.example.invalid/path", "https://pilot.example.invalid/%2F", "https://pilot.example.invalid:0"] {
            XCTAssertThrowsError(try SessionEndpoint(url: XCTUnwrap(URL(string: text))), text)
        }
        XCTAssertNoThrow(try SessionEndpoint(url: URL(string: "http://127.0.0.1:8878")!, allowLoopbackDevelopment: true))
        XCTAssertThrowsError(try SessionEndpoint(url: URL(string: "http://192.168.1.10")!, allowLoopbackDevelopment: true))
    }

    func testEnrollmentSendsOnlyVersionedBodyAndRestoresAtomicallyWithoutNetwork() async throws {
        let storage = MemorySessionStorage(), clock = SessionClock(instant)
        let data = payload(at: instant)
        NativeSessionStub.install { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "https://pilot.example.invalid/v1/session/enroll")
            XCTAssertNil(request.url?.query); XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
            XCTAssertEqual(Set(body.keys), ["schemaVersion", "invitation"])
            XCTAssertEqual(body["schemaVersion"] as? Int, 1)
            return .ok(data)
        }
        let first = controller(storage, clock)
        try await first.enroll(invitation: invitation)
        let token = try await first.accessToken()
        XCTAssertEqual(token, access(1))
        let saved = try XCTUnwrap(storage.snapshot())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertEqual(object["refreshInFlight"] as? Bool, false)
        XCTAssertEqual(Set(object.keys), ["storageVersion", "tokens", "refreshInFlight"])
        let restored = controller(storage, clock)
        let restoredToken = try await restored.accessToken()
        XCTAssertEqual(restoredToken, token)
        XCTAssertEqual(NativeSessionStub.requests.count, 1)
    }

    func testInvalidInvitationNeverReplacesExistingCredentialsOrSendsNetwork() async throws {
        let store = MemorySessionStorage(), clock = SessionClock(instant)
        NativeSessionStub.install { _ in .ok(self.payload(at: self.instant)) }
        let c = controller(store, clock); try await c.enroll(invitation: invitation)
        let old = store.snapshot()
        do { try await c.enroll(invitation: "not an invitation"); XCTFail() }
        catch { XCTAssertEqual(error as? NativeSessionError, .invitationFormat) }
        XCTAssertEqual(store.snapshot(), old); XCTAssertEqual(NativeSessionStub.requests.count, 1)
    }

    func testTwentyExpiredAccessRequestsCoalesceIntoOneRotationWithMarkerBeforeDispatch() async throws {
        let store = MemorySessionStorage(), clock = SessionClock(instant)
        NativeSessionStub.install { request in
            if request.url!.path.hasSuffix("enroll") { return .ok(self.payload(at: self.instant)) }
            let marker = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(store.snapshot())) as? [String: Any])
            XCTAssertEqual(marker["refreshInFlight"] as? Bool, true)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            XCTAssertEqual(Set(body.keys), ["schemaVersion", "refreshToken"])
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            try await Task.sleep(nanoseconds: 30_000_000)
            return .ok(self.payload(at: clock.value(), version: 2))
        }
        let c = controller(store, clock); try await c.enroll(invitation: invitation); clock.advance(901)
        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 { group.addTask { try await c.accessToken() } }
            var values: [String] = []; for try await value in group { values.append(value) }; return values
        }
        XCTAssertEqual(Set(results), [access(2)])
        XCTAssertEqual(NativeSessionStub.requests.filter { $0.url!.path.hasSuffix("refresh") }.count, 1)
        let restored = controller(store, clock)
        let token = try await restored.accessToken(); XCTAssertEqual(token, access(2))
    }

    func testCrashMarkerNeverRestoresOrReplaysOldRefresh() async throws {
        let store = MemorySessionStorage(), clock = SessionClock(instant)
        NativeSessionStub.install { _ in .ok(self.payload(at: self.instant)) }
        let c = controller(store, clock); try await c.enroll(invitation: invitation)
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(store.snapshot())) as? [String: Any])
        saved["refreshInFlight"] = true
        try store.replace(with: JSONSerialization.data(withJSONObject: saved))
        let restored = controller(store, clock)
        let state = await restored.currentState(); XCTAssertEqual(state, .recoveryRequired)
        do { _ = try await restored.accessToken(); XCTFail() }
        catch { XCTAssertEqual(error as? NativeSessionError, .recoveryRequired) }
        XCTAssertNil(store.snapshot()); XCTAssertEqual(NativeSessionStub.requests.count, 1)
    }

    func testLostRefreshResponseIsNotRetriedInProcessOrAfterRestart() async throws {
        let store = MemorySessionStorage(), clock = SessionClock(instant)
        NativeSessionStub.install { request in
            if request.url!.path.hasSuffix("enroll") { return .ok(self.payload(at: self.instant)) }
            throw URLError(.networkConnectionLost)
        }
        let c = controller(store, clock); try await c.enroll(invitation: invitation); clock.advance(901)
        for _ in 0..<3 {
            do { _ = try await c.accessToken(); XCTFail() }
            catch { XCTAssertEqual(error as? NativeSessionError, .recoveryRequired) }
        }
        let restored = controller(store, clock)
        do { _ = try await restored.accessToken(); XCTFail() } catch {}
        XCTAssertEqual(NativeSessionStub.requests.count, 2); XCTAssertNil(store.snapshot())
    }

    func testKeychainWriteFailureAfterRotationCannotRestoreOldPair() async throws {
        let store = MemorySessionStorage(), clock = SessionClock(instant)
        NativeSessionStub.install { request in
            if request.url!.path.hasSuffix("enroll") { return .ok(self.payload(at: self.instant)) }
            store.failNextWrite(); store.failRemovals(true)
            return .ok(self.payload(at: clock.value(), version: 2))
        }
        let c = controller(store, clock); try await c.enroll(invitation: invitation); clock.advance(901)
        do { _ = try await c.accessToken(); XCTFail() } catch {}
        // The persisted marker remains even if deleting a locked item also failed.
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(store.snapshot())) as? [String: Any])
        XCTAssertEqual(saved["refreshInFlight"] as? Bool, true)
        store.failRemovals(false)
        let restored = controller(store, clock)
        let state = await restored.currentState(); XCTAssertEqual(state, .recoveryRequired)
        XCTAssertEqual(NativeSessionStub.requests.count, 2)
    }

    func testFailedMarkerWriteDoesNotSendRefreshAndCanRestoreAfterUnlock() async throws {
        let store = MemorySessionStorage(), clock = SessionClock(instant)
        NativeSessionStub.install { request in .ok(self.payload(at: clock.value(), version: request.url!.path.hasSuffix("enroll") ? 1 : 2)) }
        let c = controller(store, clock); try await c.enroll(invitation: invitation); clock.advance(901)
        store.failNextWrite()
        do { _ = try await c.accessToken(); XCTFail() } catch { XCTAssertEqual(error as? NativeSessionError, .storage) }
        XCTAssertEqual(NativeSessionStub.requests.count, 1)
        await c.restoreSecureStorage()
        _ = try await c.accessToken()
        XCTAssertEqual(NativeSessionStub.requests.count, 2)
    }

    func testLockedLaunchCanRestoreAfterUnlockWithoutInvitation() async throws {
        let store = MemorySessionStorage(), clock = SessionClock(instant)
        NativeSessionStub.install { _ in .ok(self.payload(at: self.instant)) }
        let original = controller(store, clock); try await original.enroll(invitation: invitation)
        store.failReads(true)
        let restored = controller(store, clock)
        var state = await restored.currentState(); XCTAssertEqual(state, .storageUnavailable)
        store.failReads(false); await restored.restoreSecureStorage()
        state = await restored.currentState(); XCTAssertEqual(state, .connected)
        let token = try await restored.accessToken(); XCTAssertEqual(token, access(1))
        XCTAssertEqual(NativeSessionStub.requests.count, 1)
    }

    func testFailedDisconnectRetryDeletesInsteadOfRestoringExistingPair() async throws {
        let store = MemorySessionStorage(), clock = SessionClock(instant)
        NativeSessionStub.install { _ in .ok(self.payload(at: self.instant)) }
        let c = controller(store, clock); try await c.enroll(invitation: invitation)
        store.failRemovals(true)
        do { try await c.signOut(); XCTFail() } catch { XCTAssertEqual(error as? NativeSessionError, .storage) }
        var state = await c.currentState(); XCTAssertEqual(state, .disconnectPending)
        XCTAssertNotNil(store.snapshot())
        await c.restoreSecureStorage()
        state = await c.currentState(); XCTAssertEqual(state, .disconnectPending)
        store.failRemovals(false); await c.restoreSecureStorage()
        state = await c.currentState(); XCTAssertEqual(state, .signedOut)
        XCTAssertNil(store.snapshot())
        do { _ = try await c.accessToken(); XCTFail() } catch { XCTAssertEqual(error as? NativeSessionError, .signInRequired) }
        XCTAssertEqual(NativeSessionStub.requests.count, 1)
    }

    func testExpiredRefreshAndCorruptStorageRequireRecoveryWithoutNetwork() async throws {
        for corrupt in [false, true] {
            let store = MemorySessionStorage(), clock = SessionClock(instant)
            NativeSessionStub.install { _ in .ok(self.payload(at: self.instant)) }
            let c = controller(store, clock); try await c.enroll(invitation: invitation)
            if corrupt { try store.replace(with: Data("corrupt".utf8)) } else { clock.advance(30 * 86_400) }
            let restored = controller(store, clock)
            let state = await restored.currentState(); XCTAssertEqual(state, .recoveryRequired)
            XCTAssertNil(store.snapshot()); XCTAssertEqual(NativeSessionStub.requests.count, 1)
        }
    }

    func testSignOutDuringRefreshDiscardsLatePair() async throws {
        let store = MemorySessionStorage(), clock = SessionClock(instant), gate = SessionGate()
        NativeSessionStub.install { request in
            if request.url!.path.hasSuffix("enroll") { return .ok(self.payload(at: self.instant)) }
            await gate.wait(); return .ok(self.payload(at: clock.value(), version: 2))
        }
        let c = controller(store, clock); try await c.enroll(invitation: invitation); clock.advance(901)
        let pending = Task { try await c.accessToken() }
        await NativeSessionStub.waitForRequests(2)
        try await c.signOut(); await gate.open()
        do { _ = try await pending.value; XCTFail() } catch { XCTAssertEqual(error as? NativeSessionError, .superseded) }
        XCTAssertNil(store.snapshot()); let state = await c.currentState(); XCTAssertEqual(state, .signedOut)
    }

    func testNewEnrollmentDuringRefreshCannotBeOverwrittenByOldPair() async throws {
        let store = MemorySessionStorage(), clock = SessionClock(instant), gate = SessionGate()
        NativeSessionStub.install { request in
            if request.url!.path.hasSuffix("enroll") {
                let generation = NativeSessionStub.requests.filter { $0.url!.path.hasSuffix("enroll") }.count
                return .ok(self.payload(at: clock.value(), version: generation == 1 ? 1 : 3))
            }
            await gate.wait(); return .ok(self.payload(at: clock.value(), version: 2))
        }
        let c = controller(store, clock); try await c.enroll(invitation: invitation); clock.advance(901)
        let pending = Task { try await c.accessToken() }; await NativeSessionStub.waitForRequests(2)
        try await c.enroll(invitation: invitation); await gate.open()
        do { _ = try await pending.value; XCTFail() } catch {}
        let token = try await c.accessToken(); XCTAssertEqual(token, access(3))
        let restored = controller(store, clock); let restoredToken = try await restored.accessToken(); XCTAssertEqual(restoredToken, access(3))
    }

    func testKnownRefreshLimitRetainsPairButDoesNotLoopAndReplayRevocationClearsIt() async throws {
        let store = MemorySessionStorage(), clock = SessionClock(instant)
        NativeSessionStub.install { request in
            request.url!.path.hasSuffix("enroll") ? .ok(self.payload(at: self.instant)) : .error(429, "request_limit")
        }
        let c = controller(store, clock); try await c.enroll(invitation: invitation); clock.advance(901)
        for _ in 0..<4 {
            do { _ = try await c.accessToken(); XCTFail() } catch { XCTAssertEqual(error as? NativeSessionError, .requestLimit) }
        }
        XCTAssertEqual(NativeSessionStub.requests.count, 2)
        XCTAssertNotNil(store.snapshot()); clock.advance(61)
        NativeSessionStub.install(resetRequests: false) { _ in .error(401, "refresh_replayed") }
        do { _ = try await c.accessToken(); XCTFail() } catch { XCTAssertEqual(error as? NativeSessionError, .recoveryRequired) }
        XCTAssertNil(store.snapshot()); XCTAssertEqual(NativeSessionStub.requests.count, 3)
    }

    func testCoalescedKnownRefreshLimitDoesNotTellOtherWaitersToReenroll() async throws {
        let store = MemorySessionStorage(), clock = SessionClock(instant)
        NativeSessionStub.install { request in
            if request.url!.path.hasSuffix("enroll") { return .ok(self.payload(at: self.instant)) }
            try await Task.sleep(nanoseconds: 30_000_000)
            return .error(429, "request_limit")
        }
        let c = controller(store, clock); try await c.enroll(invitation: invitation); clock.advance(901)
        let errors = await withTaskGroup(of: NativeSessionError?.self) { group in
            for _ in 0..<20 { group.addTask { do { _ = try await c.accessToken(); return nil } catch { return error as? NativeSessionError } } }
            var result: [NativeSessionError?] = []; for await error in group { result.append(error) }; return result
        }
        XCTAssertTrue(errors.allSatisfy { $0 == .requestLimit })
        let state = await c.currentState(); XCTAssertEqual(state, .connected)
        XCTAssertNotNil(store.snapshot()); XCTAssertEqual(NativeSessionStub.requests.count, 2)
    }

    func testRefreshRejectsIdentitySwapNonRotatedTokensAndMalformedResponse() async throws {
        for mutation in ["identity", "same", "schema", "expired", "duplicate", "redirect", "contentType"] {
            let store = MemorySessionStorage(), clock = SessionClock(instant)
            NativeSessionStub.install { request in
                if request.url!.path.hasSuffix("enroll") { return .ok(self.payload(at: self.instant)) }
                var data = self.payload(at: clock.value(), version: mutation == "same" ? 1 : 2)
                if mutation == "duplicate" {
                    data = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "{", with: "{\"schemaVersion\":1,").utf8)
                } else {
                    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                    if mutation == "identity" { object["clientID"] = "client1_" + String(repeating: "f", count: 32) }
                    if mutation == "schema" { object["schemaVersion"] = 2 }
                    if mutation == "expired" { object["accessExpiresAt"] = clock.value().addingTimeInterval(-1).timeIntervalSince1970 * 1000 }
                    data = try JSONSerialization.data(withJSONObject: object)
                }
                return SessionStubResponse(status: 200, data: data, contentType: mutation == "contentType" ? "text/html" : "application/json",
                    finalURL: mutation == "redirect" ? URL(string: "https://elsewhere.example.invalid")! : nil)
            }
            let c = controller(store, clock); try await c.enroll(invitation: invitation); clock.advance(901)
            do { _ = try await c.accessToken(); XCTFail(mutation) } catch {}
            XCTAssertNil(store.snapshot(), mutation); XCTAssertEqual(NativeSessionStub.requests.count, 2)
        }
    }

    func testSessionSchemaRejectsUnknownDuplicateEscapedWrongPurposeAndInvalidBounds() throws {
        let original = payload(at: instant)
        let text = String(decoding: original, as: UTF8.self)
        for invalid in [text.replacingOccurrences(of: "{", with: "{\"schemaVersion\":1,"),
                        text.replacingOccurrences(of: "{", with: "{\"extra\":0,"),
                        text.replacingOccurrences(of: "schemaVersion", with: "schema\\u0056ersion"),
                        text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1.0"),
                        text.replacingOccurrences(of: "acc1_", with: "ref1_")] {
            XCTAssertThrowsError(try NativeSessionTokens.decodeResponse(Data(invalid.utf8)).validate(now: instant, fresh: true))
        }
        XCTAssertNoThrow(try NativeSessionTokens.decodeResponse(original).validate(now: instant, fresh: true))
    }

    func testInvitationErrorsAreSafeAndDoNotEchoServerMessageOrCredential() async throws {
        for (status, code, expected) in [(401,"invitation_expired",NativeSessionError.invitationExpired),
            (401,"invitation_invalid",.invitationRejected),(409,"invitation_used",.invitationUsed),(429,"request_limit",.requestLimit),(503,"auth_unavailable",.unavailable)] {
            NativeSessionStub.install { _ in .error(status, code, message: self.invitation) }
            let c = controller(MemorySessionStorage(), SessionClock(instant))
            do { try await c.enroll(invitation: invitation); XCTFail() }
            catch { XCTAssertEqual(error as? NativeSessionError, expected); XCTAssertFalse(error.localizedDescription.contains(invitation)) }
            XCTAssertEqual(NativeSessionStub.requests.count, 1)
        }
    }

    func testPriceAccessRejectionRefreshesOnceAndPreservesEvidenceAndPartialMessage() async throws {
        let date = Date(), store = MemorySessionStorage(), clock = SessionClock(Date())
        NativeSessionStub.install { request in
            if request.url!.path.hasSuffix("enroll") { return .ok(self.payload(at: date)) }
            if request.url!.path.hasSuffix("refresh") { return .ok(self.payload(at: clock.value(), version: 2)) }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer " + self.access(1) { return .error(401, "auth_expired") }
            return .ok(self.searchPayload(at: date))
        }
        let c = controller(store, clock); try await c.enroll(invitation: invitation)
        let client = SessionMarketClient(sessions: c, configuration: { NativeSessionStub.configuration() })
        let page = try await client.search(query: "milk", location: StoreLocation.defaults.first { $0.store == .wegmans }!, channel: .inStore)
        XCTAssertEqual(page.candidates.count, 1); XCTAssertEqual(page.message, "One product is unavailable.")
        XCTAssertEqual(page.candidates.first?.observedAt.timeIntervalSince1970 ?? 0, date.addingTimeInterval(-120).timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(page.candidates.first?.conditions, "Synthetic conditional offer")
        XCTAssertNil(page.candidates.first?.available)
        XCTAssertEqual(NativeSessionStub.requests.count, 4)
        for request in NativeSessionStub.requests {
            XCTAssertEqual(request.url?.host, "pilot.example.invalid")
            XCTAssertFalse(request.url!.absoluteString.contains("acc1_")); XCTAssertFalse(request.url!.absoluteString.contains("ref1_"))
        }
    }

    func testLateOldAccessFailureJoinsInFlightRefreshInsteadOfRevokingNewPair() async throws {
        let date = Date(), store = MemorySessionStorage(), clock = SessionClock(Date()), searchGate = SessionGate(), refreshGate = SessionGate()
        NativeSessionStub.install { request in
            if request.url!.path.hasSuffix("enroll") { return .ok(self.payload(at: date)) }
            if request.url!.path.hasSuffix("refresh") { await refreshGate.wait(); return .ok(self.payload(at: clock.value(), version: 2)) }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer " + self.access(1) {
                await searchGate.wait(); return .error(401, "auth_invalid")
            }
            return .ok(self.searchPayload(at: date))
        }
        let c = controller(store, clock); try await c.enroll(invitation: invitation)
        let client = SessionMarketClient(sessions: c, configuration: { NativeSessionStub.configuration() })
        let search = Task { try await client.search(query: "milk", location: StoreLocation.defaults.first { $0.store == .wegmans }!, channel: .inStore) }
        await NativeSessionStub.waitForRequests(2)
        let rotation = Task { try await c.accessToken(rejectedAccessToken: self.access(1)) }
        await NativeSessionStub.waitForRequests(3); await searchGate.open()
        try await Task.sleep(nanoseconds: 10_000_000); await refreshGate.open()
        let page = try await search.value, token = try await rotation.value
        XCTAssertEqual(page.candidates.count, 1); XCTAssertEqual(token, access(2)); XCTAssertEqual(NativeSessionStub.requests.count, 4)
        let restored = controller(store, clock); let savedToken = try await restored.accessToken(); XCTAssertEqual(savedToken, access(2))
    }

    func testRevokedPriceSessionClearsCredentialsWithoutRefreshAndLateOldRejectionIsIgnored() async throws {
        let date = Date(), store = MemorySessionStorage(), clock = SessionClock(Date())
        NativeSessionStub.install { request in request.url!.path.hasSuffix("enroll") ? .ok(self.payload(at: date)) : .error(401, "auth_revoked") }
        let c = controller(store, clock); try await c.enroll(invitation: invitation)
        let client = SessionMarketClient(sessions: c, configuration: { NativeSessionStub.configuration() })
        do { _ = try await client.search(query: "milk", location: StoreLocation.defaults.first { $0.store == .wegmans }!, channel: .inStore); XCTFail() }
        catch { XCTAssertEqual(error as? NativeSessionError, .recoveryRequired) }
        XCTAssertNil(store.snapshot()); XCTAssertEqual(NativeSessionStub.requests.count, 2)
        NativeSessionStub.install(resetRequests: false) { _ in .ok(self.payload(at: date, version: 3)) }
        try await c.enroll(invitation: invitation)
        let cleared = try await c.reject(accessToken: access(1)); XCTAssertFalse(cleared)
        let token = try await c.accessToken(); XCTAssertEqual(token, access(3))
    }

    func testOfflineQuotaDisabledAndProviderErrorsDoNotRefreshOrFetchDirectly() async throws {
        let date = Date()
        for status in [0, 429, 503, 502] {
            let store = MemorySessionStorage(), clock = SessionClock(date)
            NativeSessionStub.install { request in
                if request.url!.path.hasSuffix("enroll") { return .ok(self.payload(at: date)) }
                if status == 0 { throw URLError(.notConnectedToInternet) }
                return .error(status, self.invitation, message: self.invitation)
            }
            let c = controller(store, clock); try await c.enroll(invitation: invitation)
            let client = SessionMarketClient(sessions: c, configuration: { NativeSessionStub.configuration() })
            do { _ = try await client.search(query: "milk", location: StoreLocation.defaults.first { $0.store == .wegmans }!, channel: .inStore); XCTFail() }
            catch {
                XCTAssertFalse(error.localizedDescription.contains(invitation))
                XCTAssertFalse(String(describing: error).contains(invitation))
                if let service = error as? SharedServiceError { XCTAssertNil(service.code) }
            }
            XCTAssertEqual(NativeSessionStub.requests.count, 2); XCTAssertNotNil(store.snapshot())
            XCTAssertTrue(NativeSessionStub.requests.allSatisfy { $0.url?.host == "pilot.example.invalid" })
        }
    }

    func testSecondUnauthorizedPriceResponseStopsWithoutRefreshLoop() async throws {
        let date = Date(), store = MemorySessionStorage(), clock = SessionClock(Date())
        NativeSessionStub.install { request in
            if request.url!.path.hasSuffix("enroll") { return .ok(self.payload(at: date)) }
            if request.url!.path.hasSuffix("refresh") { return .ok(self.payload(at: date, version: 2)) }
            return .error(401, "auth_invalid")
        }
        let c = controller(store, clock); try await c.enroll(invitation: invitation)
        let client = SessionMarketClient(sessions: c, configuration: { NativeSessionStub.configuration() })
        do { _ = try await client.search(query: "milk", location: StoreLocation.defaults.first { $0.store == .wegmans }!, channel: .inStore); XCTFail() } catch {}
        XCTAssertNil(store.snapshot()); XCTAssertEqual(NativeSessionStub.requests.count, 4)
    }

    func testManualStatusGateAndLatePriceAfterCatalogChangeAreRejected() async throws {
        let date = Date(), gate = SessionGate(), catalog = RemoteSourceCatalog()
        NativeSessionStub.install { request in
            if request.url!.path.hasSuffix("enroll") { return .ok(self.payload(at: date)) }
            if request.url!.path.hasSuffix("sources") { return .ok(self.sourcePayload(at: date)) }
            await gate.wait(); return .ok(self.searchPayload(at: date))
        }
        let c = controller(MemorySessionStorage(), SessionClock(date)); try await c.enroll(invitation: invitation)
        let client = SessionMarketClient(sessions: c, catalog: catalog, configuration: { NativeSessionStub.configuration() })
        let location = StoreLocation.defaults.first { $0.store == .wegmans }!
        do { _ = try await client.search(query: "milk", location: location, channel: .inStore); XCTFail() }
        catch RetailClientError.unsupportedSource {}
        XCTAssertEqual(NativeSessionStub.requests.count, 1)
        _ = try await client.sources()
        let search = Task { try await client.search(query: "milk", location: location, channel: .inStore) }
        await NativeSessionStub.waitForRequests(3)
        NativeSessionStub.install(resetRequests: false) { _ in .ok(self.sourcePayload(at: date, enabled: false)) }
        _ = try await client.sources()
        await gate.open()
        do { _ = try await search.value; XCTFail("A withdrawn source cannot finish an old request") }
        catch { XCTAssertEqual(error as? NativeSessionError, .superseded) }
        XCTAssertEqual(NativeSessionStub.requests.count, 4)
    }

    func testLateStatusCannotOverwriteNewSessionCatalogAndOldEpochCannotAuthorizeRequests() async throws {
        let date = Date(), gate = SessionGate(), catalog = RemoteSourceCatalog()
        NativeSessionStub.install { request in
            if request.url!.path.hasSuffix("enroll") { return .ok(self.payload(at: date)) }
            await gate.wait(); return .ok(self.sourcePayload(at: date))
        }
        let c = controller(MemorySessionStorage(), SessionClock(date)); try await c.enroll(invitation: invitation)
        let client = SessionMarketClient(sessions: c, catalog: catalog, configuration: { NativeSessionStub.configuration() })
        let older = Task { try await client.sources() }
        await NativeSessionStub.waitForRequests(2)
        try await c.signOut()
        NativeSessionStub.install(resetRequests: false) { request in
            request.url!.path.hasSuffix("enroll") ? .ok(self.payload(at: date, version: 2)) : .ok(self.sourcePayload(at: date, enabled: false))
        }
        try await c.enroll(invitation: invitation)
        _ = try await client.sources()
        await gate.open()
        do { _ = try await older.value; XCTFail() } catch { XCTAssertEqual(error as? NativeSessionError, .superseded) }
        let current = await catalog.current(); XCTAssertEqual(current?.sources.first?.state, .disabled)
        // Even without the UI's explicit catalog.clear, a new session epoch invalidates old grants.
        try await c.signOut()
        try await c.enroll(invitation: invitation)
        let count = NativeSessionStub.requests.count
        do { _ = try await client.search(query: "milk", location: StoreLocation.defaults[0], channel: .inStore); XCTFail() }
        catch { XCTAssertEqual(error as? NativeSessionError, .superseded) }
        XCTAssertEqual(NativeSessionStub.requests.count, count)
    }

    private func sourcePayload(at date: Date, enabled: Bool = true) -> Data {
        try! JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "generatedAt": date.timeIntervalSince1970 * 1000, "sources": [[
            "provider": "retailer_website", "store": "wegmans", "storeCode": "133", "channel": "in_store",
            "technicallySupported": true, "channelVerified": true, "fetchingEnabled": enabled, "publicAccessApproved": enabled,
            "attribution": "Synthetic status", "referenceOnly": false, "limitation": "Synthetic fixture",
            "cacheTTLSeconds": enabled ? 86400 : 0, "displayTTLSeconds": enabled ? 86400 : 0,
            "maximumObservationAgeSeconds": enabled ? 172800 : 0, "retentionSeconds": enabled ? 172800 : 0,
            "state": enabled ? "ready" : "disabled"]]])
    }

    private func searchPayload(at date: Date) -> Data {
        let value = FetchedPrice(productID: "123", productName: "Synthetic milk", barcode: nil,
            price: 3, quantity: 64, unit: .flOz, packCount: 1, quantityKind: .fixed, available: nil,
            observedAt: date.addingTimeInterval(-120), retrievedAt: date.addingTimeInterval(-60), conditions: "Synthetic conditional offer", source: .wegmans,
            sourceURL: "https://www.wegmans.com/api/products/133/123", sourceExclusion: nil)
        return try! SharedMarketWire.encoder().encode(SharedSearchResponse(context: SharedPriceContext(store: .wegmans, storeCode: "133", channel: .inStore),
            page: RetailSearchPage(candidates: [value], message: "One product is unavailable."), cacheHit: true, servedAt: date.addingTimeInterval(-30)))
    }

    private func controller(_ store: MemorySessionStorage, _ clock: SessionClock) -> NativeSessionController {
        NativeSessionController(endpoint: endpoint, storage: store, configuration: NativeSessionStub.configuration(), now: { clock.value() })
    }
    private func access(_ version: Int) -> String { "acc1_" + String(repeating: String(version), count: 64) }
    private func payload(at date: Date, version: Int = 1) -> Data {
        try! JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "clientID": "client1_" + String(repeating: "b", count: 32), "tokenType": "Bearer",
            "accessToken": access(version), "accessExpiresAt": date.addingTimeInterval(900).timeIntervalSince1970 * 1000,
            "refreshToken": "ref1_" + String(repeating: String(version), count: 64), "refreshExpiresAt": date.addingTimeInterval(30 * 86_400).timeIntervalSince1970 * 1000])
    }
}

final class MemorySessionStorage: SessionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?, failWrite = false, failRead = false, failRemove = false
    func read() throws -> Data? { lock.lock(); defer { lock.unlock() }; if failRead { throw NativeSessionError.storage }; return data }
    func replace(with value: Data) throws {
        lock.lock(); defer { lock.unlock() }
        if failWrite { failWrite = false; throw NativeSessionError.storage }; data = value
    }
    func remove() throws { lock.lock(); defer { lock.unlock() }; if failRemove { throw NativeSessionError.storage }; data = nil }
    func snapshot() -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    func failNextWrite() { lock.lock(); defer { lock.unlock() }; failWrite = true }
    func failReads(_ value: Bool) { lock.lock(); defer { lock.unlock() }; failRead = value }
    func failRemovals(_ value: Bool) { lock.lock(); defer { lock.unlock() }; failRemove = value }
}
final class SessionClock: @unchecked Sendable {
    private let lock = NSLock(); private var date: Date
    init(_ date: Date) { self.date = date }
    func value() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ interval: TimeInterval) { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(interval) }
}
actor SessionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async { if !opened { await withCheckedContinuation { continuation = $0 } } }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}
struct SessionStubResponse {
    let status: Int, data: Data
    var contentType = "application/json"
    var finalURL: URL?
    static func ok(_ data: Data) -> Self { Self(status: 200, data: data) }
    static func error(_ status: Int, _ code: String, message: String = "Safe test error") -> Self {
        Self(status: status, data: try! JSONEncoder().encode(SharedAPIError(code: code, message: message)))
    }
}
final class NativeSessionStub: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) async throws -> SessionStubResponse)?
    private static var captured: [URLRequest] = []
    private var loadingTask: Task<Void, Never>?
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    static func install(resetRequests: Bool = true, _ value: @escaping (URLRequest) async throws -> SessionStubResponse) {
        lock.lock(); defer { lock.unlock() }; handler = value; if resetRequests { captured = [] }
    }
    static func reset() { lock.lock(); defer { lock.unlock() }; captured = []; handler = nil }
    static func configuration() -> URLSessionConfiguration { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [NativeSessionStub.self]; return c }
    static func waitForRequests(_ count: Int) async {
        for _ in 0..<500 { if requests.count >= count { return }; try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTFail("Expected fixture request did not arrive")
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var request = self.request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var body = Data(), buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; body.append(buffer, count: count)
            }
            request.httpBody = body
        }
        Self.lock.lock(); Self.captured.append(request); let handler = Self.handler; Self.lock.unlock()
        loadingTask = Task {
            do {
                guard let handler else { throw URLError(.unsupportedURL) }
                let result = try await handler(request)
                guard !Task.isCancelled else { return }
                let response = HTTPURLResponse(url: result.finalURL ?? request.url!, statusCode: result.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": result.contentType])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: result.data); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() { loadingTask?.cancel() }
}
