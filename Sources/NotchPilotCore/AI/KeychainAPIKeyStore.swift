import Foundation
import Security

/// Stores provider API keys as generic passwords in the user's login keychain (service
/// "app.notchpilot.apikeys", one item per provider).
///
/// Scope of protection: an ad-hoc-signed SwiftPM build cannot use the data-protection
/// keychain (that needs an application-identifier entitlement from a real signing identity),
/// so the item lives in the file-based login keychain. There, the
/// `WhenUnlockedThisDeviceOnly` attribute is not enforced; access is governed by the item's
/// ACL, and macOS asks the user before any *other* app may read it. A Developer-ID-signed
/// release can add `kSecUseDataProtectionKeychain` for device-bound storage.
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
        let data: [String: Any] = [kSecValueData as String: Data(trimmed.utf8)]
        let query = baseQuery(for: provider)
        // Update only the secret; changing kSecAttrAccessible in an update can fail with
        // errSecParam on the file-based keychain. The attribute is set when the item is added.
        var status = SecItemUpdate(query as CFDictionary, data as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(data) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
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
