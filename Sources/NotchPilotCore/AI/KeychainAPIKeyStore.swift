import Foundation
import Security

/// Stores provider API keys as generic passwords, readable only while the Mac is unlocked
/// and never synced or migrated to another device.
public struct KeychainAPIKeyStore: APIKeyStoring {
    public static let defaultService = "app.notchpilot.apikeys"

    private let service: String

    public init(service: String = KeychainAPIKeyStore.defaultService) {
        self.service = service
    }

    public func apiKey(for provider: AIProvider) throws -> String? {
        var query = baseQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw AssistantError.keychain(status)
        }
    }

    /// Saves `key` (trimmed), replacing any existing key; an empty key removes it.
    public func setAPIKey(_ key: String, for provider: AIProvider) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try removeAPIKey(for: provider) }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let query = baseQuery(for: provider)
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AssistantError.keychain(status) }
    }

    public func removeAPIKey(for provider: AIProvider) throws {
        let status = SecItemDelete(baseQuery(for: provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AssistantError.keychain(status) }
    }

    private func baseQuery(for provider: AIProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
    }
}
