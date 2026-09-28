import Foundation
import Security

/// Separate credentials for each provider; never stored in UserDefaults.
enum Keychain {
    static func loadAPIKey(for provider: TranscriptionProvider = .fal) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: provider.keychainService,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else {
            return nil
        }
        return key
    }

    struct SaveError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Couldn't save the API key in Keychain (status \(status)). Unlock your login keychain and try again." }
    }

    static func saveAPIKey(_ key: String, for provider: TranscriptionProvider = .fal) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: provider.keychainService,
            kSecAttrAccount as String: provider.rawValue,
        ]
        if trimmed.isEmpty {
            let status = SecItemDelete(base as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw SaveError(status: status) }
            return
        }
        let data = Data(trimmed.utf8)
        var status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SaveError(status: status) }
    }
}
