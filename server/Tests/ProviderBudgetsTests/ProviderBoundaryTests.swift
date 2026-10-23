import Foundation
import XCTest
import Darwin
import ClientSessions
@testable import ProviderBudgets

extension ProviderBudgetTests {
    func testRealHTTPRedirectAndConnectionDropAreSingleAttempts() async throws {
        for mode in [BudgetHTTPFixture.Mode.redirect, .drop] {
            let server = try BudgetHTTPFixture(mode: mode)
            let network = SingleAttemptProviderHTTP(fixtureOrigin: server.origin)
            let principal = try await client()
            let ledger = try ProviderBudgetLedger(databasePath: ":memory:", policy: policy(), now: { self.instant })
            let controller = ProviderBudgetController(ledger: ledger, network: network)
            await expect(.networkUnavailable) { try await controller.withMiss(principal: principal) { _ = try await $0.load(self.searchRequest()) } }
            try await network.shutdown(); server.stop()
            XCTAssertEqual(server.count, 1)
            let usage = try await ledger.usage(for: principal).windows[0]
            XCTAssertEqual(usage.reserved, 1); XCTAssertEqual(usage.attempted, 1); XCTAssertEqual(usage.uncertain, 1)
        }
    }

    func testAbsoluteHTTPDeadlineIncludesAContinuouslyTricklingBody() async throws {
        let server = try BudgetHTTPFixture(mode: .trickle)
        let network = SingleAttemptProviderHTTP(fixtureOrigin: server.origin, completeTimeout: 0.08)
        let principal = try await client()
        let ledger = try ProviderBudgetLedger(databasePath: ":memory:", policy: policy(), now: { self.instant })
        let controller = ProviderBudgetController(ledger: ledger, network: network)
        let started = ContinuousClock.now
        await expect(.networkUnavailable) { try await controller.withMiss(principal: principal) { _ = try await $0.load(self.searchRequest()) } }
        let duration = started.duration(to: .now)
        try await network.shutdown(); server.stop()
        XCTAssertLessThan(duration, .seconds(1))
        XCTAssertGreaterThan(server.bodyBytesSent, 0)
        XCTAssertEqual(server.count, 1)
        let usage = try await ledger.usage(for: principal).windows[0]
        XCTAssertEqual(usage.reserved, 1); XCTAssertEqual(usage.pending, 0); XCTAssertEqual(usage.uncertain, 1)
    }

    func testFactoryUsesExactEngineSpecificQueryNamesAndFixedStores() throws {
        for (engine, name, store) in [(SerpAPIEngine.walmart, "query", "5969"), (.target, "q", "1827")] {
            let request = try ProviderHTTPRequest(engine: engine, query: "milk & eggs", page: 2, purpose: .pagination)
            let items = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)
            let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(fields, ["engine": engine.rawValue, "store_id": store, name: "milk & eggs", "page": "2"])
        }
    }

    func testDurableProviderCapIsSharedWithAnActualSubprocess() async throws {
        let childKey = "THRIFTY_BUDGET_TEST_CHILD_PATH"
        if let path = ProcessInfo.processInfo.environment[childKey] {
            let principal = try await client()
            let ledger = try ProviderBudgetLedger(databasePath: path, policy: policy(globalUnits: 2), now: { self.instant })
            let controller = ProviderBudgetController(ledger: ledger, network: FakeProviderNetwork())
            try await controller.withMiss(principal: principal) { _ = try await $0.load(self.searchRequest()) }
            await expect(.providerLimit) { try await controller.withMiss(principal: principal) { _ = try await $0.load(self.searchRequest()) } }
            return
        }
        let path = try databasePath(); defer { cleanup(path) }
        let principal = try await client()
        let ledger = try ProviderBudgetLedger(databasePath: path, policy: policy(globalUnits: 2), now: { self.instant })
        let controller = ProviderBudgetController(ledger: ledger, network: FakeProviderNetwork())
        try await controller.withMiss(principal: principal) { _ = try await $0.load(self.searchRequest()) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["-XCTest", "ProviderBudgetsTests.ProviderBudgetTests/testDurableProviderCapIsSharedWithAnActualSubprocess", Bundle(for: ProviderBudgetTests.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment; environment[childKey] = path
        process.environment = environment
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run(); process.waitUntilExit()
        let log = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, "Isolated child failed: \(log)")
        let usage = try await ledger.usage(for: principal).windows[0]
        XCTAssertEqual(usage.reserved, 2)
        await expect(.providerLimit) { try await controller.withMiss(principal: principal) { _ = try await $0.load(self.searchRequest()) } }
    }
}

/// Deliberately synthetic loopback server. No retailer/provider account traffic.
private final class BudgetHTTPFixture: @unchecked Sendable {
    enum Mode { case redirect, drop, trickle }
    private let listener: Int32
    private let lock = NSLock()
    private var stopped = false
    private var requests = 0
    private var bytesSent = 0
    let origin: URL
    var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    var bodyBytesSent: Int { lock.lock(); defer { lock.unlock() }; return bytesSent }
    init(mode: Mode) throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        self.listener = listener
        guard listener >= 0 else { throw URLError(.cannotConnectToHost) }
        var one: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(listener, 8) == 0 else { close(listener); throw URLError(.cannotConnectToHost) }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &size) } }
        origin = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))")!
        DispatchQueue.global().async { [self] in
            while true {
                let connection = accept(listener, nil, nil)
                if connection < 0 { return }
                DispatchQueue.global().async { [self] in handle(connection, mode: mode) }
            }
        }
    }
    deinit { stop() }
    func stop() {
        lock.lock(); let closeNow = !stopped; stopped = true; lock.unlock()
        if closeNow { shutdown(listener, SHUT_RDWR); close(listener) }
    }
    private func handle(_ connection: Int32, mode: Mode) {
        defer { close(connection) }
        var one: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 1_024)
        while data.range(of: Data("\r\n\r\n".utf8)) == nil && data.count < 8_192 {
            let read = recv(connection, &buffer, buffer.count, 0)
            guard read > 0 else { return }; data.append(contentsOf: buffer.prefix(read))
        }
        lock.lock(); requests += 1; lock.unlock()
        switch mode {
        case .drop: return
        case .redirect:
            sendText("HTTP/1.1 302 Found\r\nLocation: \(origin)/unexpected\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", to: connection)
        case .trickle:
            sendText("HTTP/1.1 200 OK\r\nContent-Length: 500\r\nConnection: close\r\n\r\n", to: connection)
            for _ in 0..<500 {
                var byte: UInt8 = 32
                guard send(connection, &byte, 1, 0) == 1 else { return }
                lock.lock(); bytesSent += 1; let shouldStop = stopped; lock.unlock()
                if shouldStop { return }
                // A paced fault fixture intentionally stays below the idle
                // timeout while exceeding the short absolute test deadline.
                usleep(20_000)
            }
        }
    }
    private func sendText(_ text: String, to socket: Int32) { _ = text.withCString { send(socket, $0, strlen($0), 0) } }
}
