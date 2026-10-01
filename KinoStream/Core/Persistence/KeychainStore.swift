import Foundation
import Security

enum KeychainStore {
    private static let service = "ru.nailultyev.kinostream"

    static func readPassword() -> String {
        readSecret(for: "torrserver-password")
    }

    static func savePassword(_ password: String) {
        saveSecret(password, for: "torrserver-password")
    }

    static func readSecret(for account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func saveSecret(_ secret: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        guard !secret.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(secret.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}
