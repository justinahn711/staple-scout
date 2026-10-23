import Foundation
import XCTest
import Darwin
import ServiceOwnership
import SharedMarketCore
import StapleScoutKit
@testable import ProviderBudgets

extension ProviderBudgetTests {
    func testExclusiveOwnershipRejectsSameProcessAlternateTopologyAndAliases() throws {
        let directory = try ownershipDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let paths = ownershipPaths(directory)
        let owner = try ServiceOwnership(databasePaths: paths)
        try owner.validate()
        XCTAssertThrowsError(try ServiceOwnership(databasePaths: paths))
        let other = directory.appendingPathComponent("other.sqlite").path
        XCTAssertThrowsError(try ServiceOwnership(databasePaths: [paths[0], paths[1], other]))
        XCTAssertThrowsError(try ServiceOwnership(databasePaths: [paths[0], paths[1], paths[0] + ".owner.lock"]))
        let alias = directory.appendingPathComponent("alias.sqlite").path
        XCTAssertEqual(link(paths[2], alias), 0)
        XCTAssertThrowsError(try owner.validate())
        XCTAssertThrowsError(try ServiceOwnership(databasePaths: [paths[0], paths[1], alias]))
        XCTAssertEqual(unlink(alias), 0)
        let symlinkPath = directory.appendingPathComponent("symbolic.sqlite").path
        XCTAssertEqual(symlink(paths[2], symlinkPath), 0)
        XCTAssertThrowsError(try ServiceOwnership(databasePaths: [paths[0], paths[1], symlinkPath]))
    }

    func testOwnershipCapabilityCannotRecoverAnotherActorUsingSameOwner() async throws {
        let directory = try ownershipDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let paths = ownershipPaths(directory); let owner = try ServiceOwnership(databasePaths: paths)
        let ledger = try ProviderBudgetLedger(databasePath: paths[2], policy: policy(), ownership: owner, now: { self.instant })
        let principal = try await client()
        let (_, _) = try await ledger.admit(principal: principal)
        XCTAssertThrowsError(try ProviderBudgetLedger(databasePath: paths[2], policy: policy(), ownership: owner, now: { self.instant }))
        let usage = try await ledger.usage(for: principal)
        XCTAssertEqual(usage.windows[0].pending, 1)
        let cache = try SharedPriceCache(databasePath: paths[1], ownership: owner)
        XCTAssertThrowsError(try SharedPriceCache(databasePath: paths[1], ownership: owner))
        await cache.shutdown()
    }

    func testActualSubprocessCannotStealLiveLocksAndCrashRecoveryNeverRefundsOrReplays() async throws {
        let key = "THRIFTY_OWNER_TEST_DIRECTORY"
        if let path = ProcessInfo.processInfo.environment[key] {
            let directory = URL(fileURLWithPath: path)
            let paths = ownershipPaths(directory)
            if ProcessInfo.processInfo.environment["THRIFTY_OWNER_TEST_MODE"] == "blocked" {
                XCTAssertThrowsError(try ServiceOwnership(databasePaths: paths))
                XCTAssertThrowsError(try ServiceOwnership(databasePaths: [paths[0], paths[1], directory.appendingPathComponent("different.sqlite").path]))
                return
            }
            let owner = try ServiceOwnership(databasePaths: paths)
            let ledger = try ProviderBudgetLedger(databasePath: paths[2], policy: policy(globalUnits: 2, concurrent: 1), ownership: owner, now: { self.instant })
            let principal = try await client()
            let (_, reservation) = try await ledger.admit(principal: principal)
            try await ledger.dispatched(reservation)
            // A real process exit leaves a dispatched durable hold and releases
            // kernel locks without running cleanup or fabricating completion.
            _exit(0)
        }
        let directory = try ownershipDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let paths = ownershipPaths(directory)
        var owner: ServiceOwnership? = try ServiceOwnership(databasePaths: paths)
        try ownershipChild(directory, mode: "blocked")
        owner = nil
        try ownershipChild(directory, mode: "crash")
        let recoveredOwner = try ServiceOwnership(databasePaths: paths)
        let recoveredAt = instant.addingTimeInterval(40 * 86400)
        let ledger = try ProviderBudgetLedger(databasePath: paths[2], policy: policy(globalUnits: 2, concurrent: 1), ownership: recoveredOwner, now: { recoveredAt })
        let principal = try await client()
        let recovered = try await ledger.usage(for: principal).windows[0]
        XCTAssertEqual(recovered.reserved, 1); XCTAssertEqual(recovered.attempted, 1)
        XCTAssertEqual(recovered.uncertain, 1); XCTAssertEqual(recovered.pending, 0)
        XCTAssertEqual(recovered.remaining, 1)
        // Concurrency is reclaimed, but the uncertain charge consumes all
        // windows from recovery time, even after a forty-day outage.
        let network = FakeProviderNetwork()
        let controller = ProviderBudgetController(ledger: ledger, network: network)
        try await controller.withMiss(principal: principal) { _ = try await $0.load(self.searchRequest()) }
        await expect(.providerLimit) { try await controller.withMiss(principal: principal) { _ = try await $0.load(self.searchRequest()) } }
        let count = await network.count; XCTAssertEqual(count, 1)
        withExtendedLifetime(owner) {}
    }

    func testPerRequestSourcePreflightStopsSecondOperationWithoutRefundingFirst() async throws {
        let context = try PriceContext(store: .wegmans, storeCode: "133", channel: .inStore)
        let approved = try SourcePolicy(context: context, fetchApproved: true, publicServingApproved: true, attribution: "Offline fixture")
        let cache = try SharedPriceCache(databasePath: ":memory:", policies: SourcePolicyRegistry(policies: [approved]), now: { self.instant })
        let authorization = try cache.authorization(context: context)
        let principal = try await client()
        let ledger = try ProviderBudgetLedger(databasePath: ":memory:", policy: policy(), now: { self.instant })
        let network = FakeProviderNetwork(); let controller = ProviderBudgetController(ledger: ledger, network: network)
        let admitted = try await controller.admit(principal: principal, beforeRequest: authorization)
        _ = try await admitted.requests.load(searchRequest())
        try await cache.replacePolicy(SourcePolicy(context: context, fetchApproved: false, publicServingApproved: false, attribution: "Offline fixture"))
        do { _ = try await admitted.requests.load(searchRequest()); XCTFail("Withdrawn paging cannot send") } catch ProviderBudgetError.sourceNotApproved {}
        try await admitted.finish()
        let count = await network.count; XCTAssertEqual(count, 1)
        let usage = try await ledger.usage(for: principal).windows[0]
        XCTAssertEqual(usage.reserved, 1); XCTAssertEqual(usage.pending, 0)
    }

    func testWithdrawalWhileDispatchSuspendedRetainsReservationWithoutSending() async throws {
        let context = try PriceContext(store: .wegmans, storeCode: "133", channel: .inStore)
        let approved = try SourcePolicy(context: context, fetchApproved: true, publicServingApproved: true, attribution: "Offline fixture")
        let cache = try SharedPriceCache(databasePath: ":memory:", policies: SourcePolicyRegistry(policies: [approved]), now: { self.instant })
        let principal = try await client()
        let ledger = try ProviderBudgetLedger(databasePath: ":memory:", policy: policy(), now: { self.instant })
        let network = FakeProviderNetwork(); let gate = BudgetGate()
        let controller = ProviderBudgetController(ledger: ledger, network: network, dispatchCheckpoint: { await gate.enterAndWait() })
        let admitted = try await controller.admit(principal: principal, beforeRequest: cache.authorization(context: context))
        let task = Task { try await admitted.requests.load(self.searchRequest()) }
        await gate.waitUntilEntered()
        try await cache.replacePolicy(SourcePolicy(context: context, fetchApproved: false, publicServingApproved: false, attribution: "Offline fixture"))
        await gate.open()
        do { _ = try await task.value; XCTFail("Withdrawn delayed request cannot send") } catch ProviderBudgetError.sourceNotApproved {}
        try await admitted.finish()
        let count = await network.count; XCTAssertEqual(count, 0)
        let usage = try await ledger.usage(for: principal).windows[0]
        XCTAssertEqual(usage.reserved, 1); XCTAssertEqual(usage.uncertain, 1); XCTAssertEqual(usage.pending, 0)
    }

    private func ownershipDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("service-owner-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }
    private func ownershipPaths(_ directory: URL) -> [String] { ["auth.sqlite", "cache.sqlite", "provider.sqlite"].map { directory.appendingPathComponent($0).path } }
    private func ownershipChild(_ directory: URL, mode: String) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["-XCTest", "ProviderBudgetsTests.ProviderBudgetTests/testActualSubprocessCannotStealLiveLocksAndCrashRecoveryNeverRefundsOrReplays", Bundle(for: ProviderBudgetTests.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["THRIFTY_OWNER_TEST_DIRECTORY"] = directory.path; environment["THRIFTY_OWNER_TEST_MODE"] = mode
        process.environment = environment
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run(); process.waitUntilExit()
        let log = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, "Isolated ownership child failed: \(log)")
    }
}
