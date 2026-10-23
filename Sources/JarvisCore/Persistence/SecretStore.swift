import Foundation
import Security

/// Storage for credentials (API keys of future model providers). Secrets never go into settings, history, logs or files.
public protocol SecretStoring: Sendable {
    func set(_ secret: String, for account: String) throws
    func secret(for account: String) throws -> String?
    func removeSecret(for account: String) throws
}

public enum SecretStoreError: Error, Equatable, Sendable {
    case keychain(OSStatus)
}

/// macOS Keychain implementation (generic passwords, available only while the Mac is unlocked, never synced).
public struct KeychainSecretStore: SecretStoring {
    public let service: String

    public init(service: String = "com.newportdiaz.JarvisAppleIntegrations") {
        self.service = service
    }

    private func query(for account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func set(_ secret: String, for account: String) throws {
        let data = Data(secret.utf8)
        var attributes = query(for: account)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(attributes as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw SecretStoreError.keychain(status) }
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(attributes as CFDictionary, nil)
        guard added == errSecSuccess else { throw SecretStoreError.keychain(added) }
    }

    public func secret(for account: String) throws -> String? {
        var request = query(for: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw SecretStoreError.keychain(status) }
        return String(data: data, encoding: .utf8)
    }

    public func removeSecret(for account: String) throws {
        let status = SecItemDelete(query(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.keychain(status) }
    }
}

/// In-memory secrets for tests and previews.
public final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    public init() {}
    public func set(_ secret: String, for account: String) throws { lock.withLock { values[account] = secret } }
    public func secret(for account: String) throws -> String? { lock.withLock { values[account] } }
    public func removeSecret(for account: String) throws { lock.withLock { values[account] = nil } }
}
