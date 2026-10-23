#if canImport(Security) && canImport(CryptoKit)
import Foundation
import Security
import CryptoKit

/// A small system boundary allows offline verification without touching a Mac login Keychain.
protocol SessionKeychainOperations: Sendable {
    func copy(_ query: [String: Any]) -> (OSStatus, Data?)
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func add(_ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}
private struct SystemSessionKeychain: SessionKeychainOperations {
    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus { SecItemUpdate(query as CFDictionary, attributes as CFDictionary) }
    func add(_ attributes: [String: Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary, nil) }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

/// The access/refresh pair and crash marker occupy ONE non-synchronizing, device-only item.
/// No access group is added: the app's own signed Keychain group is the boundary.
public final class KeychainSessionStorage: SessionCredentialStorage, @unchecked Sendable {
    private let service: String
    private let lock = NSLock()
    private let operations: any SessionKeychainOperations
    public convenience init(bundleIdentifier: String, endpoint: SessionEndpoint) throws {
        try self.init(bundleIdentifier: bundleIdentifier, endpoint: endpoint, operations: SystemSessionKeychain())
    }
    init(bundleIdentifier: String, endpoint: SessionEndpoint, operations: any SessionKeychainOperations) throws {
        self.operations = operations
        guard !bundleIdentifier.isEmpty, bundleIdentifier.utf8.count <= 200 else { throw NativeSessionError.configuration }
        let hash = SHA256.hash(data: Data(endpoint.url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        service = bundleIdentifier + ".pilot-session.v1." + hash
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "credential-pair", kSecAttrSynchronizable as String: false]
    }
    public func read() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        var request = query
        request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = operations.copy(request)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data, data.count <= 8192 else { throw NativeSessionError.storage }
        return data
    }
    public func replace(with data: Data) throws {
        guard data.count <= 8192 else { throw NativeSessionError.storage }
        lock.lock(); defer { lock.unlock() }
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = operations.update(query, attributes: attributes)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            guard operations.add(item) == errSecSuccess else { throw NativeSessionError.storage }
        } else if status != errSecSuccess { throw NativeSessionError.storage }
    }
    public func remove() throws {
        lock.lock(); defer { lock.unlock() }
        let status = operations.delete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NativeSessionError.storage }
    }
}
#endif
