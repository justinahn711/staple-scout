#if canImport(Security) && canImport(CryptoKit)
import Foundation
import Security
import XCTest
@testable import StapleScoutKit

final class KeychainSessionStorageTests: XCTestCase {
    private let endpoint = try! SessionEndpoint(url: URL(string: "https://pilot.example.invalid")!)
    func testPairAndCrashMarkerUseOneAtomicItemWithoutDeletingPreviousPair() throws {
        let system = FakeSessionKeychain(), store = try storage(system)
        let first = Data("synthetic-pair-1".utf8), marked = Data("synthetic-pair-1-in-flight".utf8), rotated = Data("synthetic-pair-2".utf8)
        try store.replace(with: first); try store.replace(with: marked); XCTAssertEqual(try store.read(), marked)
        try store.replace(with: rotated)
        let reopened = try storage(system); XCTAssertEqual(try reopened.read(), rotated)
        XCTAssertEqual(system.calls.filter { $0.0 == "add" }.count, 1)
        XCTAssertEqual(system.calls.filter { $0.0 == "update" }.count, 3)
        XCTAssertFalse(system.calls.contains { $0.0 == "delete" })
        XCTAssertEqual(Set(system.calls.compactMap { $0.1[kSecAttrService as String] as? String }).count, 1)
        try reopened.remove(); XCTAssertNil(try store.read())
    }
    func testQueriesRequireDeviceOnlyUnsynchronizedOwnAppScope() throws {
        let system = FakeSessionKeychain(), store = try storage(system)
        try store.replace(with: Data("synthetic pair".utf8)); _ = try store.read()
        let add = try XCTUnwrap(system.calls.first { $0.0 == "add" }?.1)
        XCTAssertEqual(add[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(add[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertNil(add[kSecAttrAccessGroup as String]); XCTAssertNil(add[kSecAttrGeneric as String])
        XCTAssertEqual(add[kSecAttrAccount as String] as? String, "credential-pair")
        let read = try XCTUnwrap(system.calls.first { $0.0 == "copy" }?.1)
        XCTAssertEqual(read[kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(read[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
    }
    func testExactServiceAndBundleScopesCannotReadEachOthersCredentials() throws {
        let system = FakeSessionKeychain(), first = try storage(system)
        try first.replace(with: Data("synthetic pair".utf8))
        let otherBundle = try KeychainSessionStorage(bundleIdentifier: "test.other", endpoint: endpoint, operations: system)
        let otherHost = try KeychainSessionStorage(bundleIdentifier: "test.pilot", endpoint: SessionEndpoint(url: URL(string: "https://other.example.invalid")!), operations: system)
        let otherPort = try KeychainSessionStorage(bundleIdentifier: "test.pilot", endpoint: SessionEndpoint(url: URL(string: "https://pilot.example.invalid:8443")!), operations: system)
        XCTAssertNil(try otherBundle.read()); XCTAssertNil(try otherHost.read()); XCTAssertNil(try otherPort.read())
        XCTAssertNotNil(try first.read())
    }
    func testStorageFailuresPropagateWithoutDeleteOrFallbackAdd() throws {
        let system = FakeSessionKeychain(), store = try storage(system)
        let original = Data("synthetic old pair".utf8)
        try store.replace(with: original)
        system.forcedUpdateStatus = errSecInteractionNotAllowed
        XCTAssertThrowsError(try store.replace(with: Data("new pair".utf8))) { XCTAssertEqual($0 as? NativeSessionError, .storage) }
        XCTAssertEqual(try store.read(), original)
        XCTAssertEqual(system.calls.filter { $0.0 == "add" }.count, 1)
        XCTAssertFalse(system.calls.contains { $0.0 == "delete" })
        system.forcedCopyStatus = errSecMissingEntitlement
        XCTAssertThrowsError(try store.read()) { XCTAssertEqual($0 as? NativeSessionError, .storage) }
        system.forcedDeleteStatus = errSecInteractionNotAllowed
        XCTAssertThrowsError(try store.remove()) { XCTAssertEqual($0 as? NativeSessionError, .storage) }
        system.forcedCopyStatus = nil; XCTAssertEqual(try store.read(), original)
    }
    func testBoundedItemAndInvalidSystemResultFailClosed() throws {
        let system = FakeSessionKeychain(), store = try storage(system)
        XCTAssertThrowsError(try store.replace(with: Data(repeating: 0, count: 8193)))
        XCTAssertTrue(system.calls.isEmpty)
        system.forcedCopyStatus = errSecSuccess
        XCTAssertThrowsError(try store.read())
        system.forcedCopyStatus = nil
        system.forcedAddStatus = errSecDuplicateItem
        XCTAssertThrowsError(try store.replace(with: Data("pair".utf8)))
        XCTAssertNil(try store.read())
    }
    private func storage(_ system: FakeSessionKeychain) throws -> KeychainSessionStorage {
        try KeychainSessionStorage(bundleIdentifier: "test.pilot", endpoint: endpoint, operations: system)
    }
}

/// A deterministic SecItem boundary; it never accesses the Mac or simulator Keychain.
private final class FakeSessionKeychain: SessionKeychainOperations, @unchecked Sendable {
    private var values: [String: Data] = [:]
    private(set) var calls: [(String, [String: Any])] = []
    var forcedCopyStatus: OSStatus?, forcedUpdateStatus: OSStatus?, forcedAddStatus: OSStatus?, forcedDeleteStatus: OSStatus?
    private func key(_ query: [String: Any]) -> String { (query[kSecAttrService as String] as? String ?? "") + ":" + (query[kSecAttrAccount as String] as? String ?? "") }
    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
        calls.append(("copy", query))
        if let status = forcedCopyStatus { return (status, nil) }
        guard let data = values[key(query)] else { return (errSecItemNotFound, nil) }; return (errSecSuccess, data)
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        calls.append(("update", query))
        if let status = forcedUpdateStatus { return status }
        guard values[key(query)] != nil else { return errSecItemNotFound }
        values[key(query)] = attributes[kSecValueData as String] as? Data; return errSecSuccess
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        calls.append(("add", attributes))
        if let status = forcedAddStatus { return status }
        guard values[key(attributes)] == nil else { return errSecDuplicateItem }
        values[key(attributes)] = attributes[kSecValueData as String] as? Data; return errSecSuccess
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        calls.append(("delete", query))
        if let status = forcedDeleteStatus { return status }
        return values.removeValue(forKey: key(query)) == nil ? errSecItemNotFound : errSecSuccess
    }
}
#endif
