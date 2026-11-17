import Foundation
import Security

/// Lightweight, zero-dependency Keychain & UserDefaults helper for storing LLM API keys.
public enum KeychainHelper {
    private static let service = "com.sparkbar.app.apikeys"

    public static func saveKey(_ key: String, for account: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)

        if !trimmed.isEmpty {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(addQuery as CFDictionary, nil)
        }
        // Also mirror to UserDefaults fallback for unsigned CLI builds so user doesn't get repeated Keychain prompts
        UserDefaults.standard.set(trimmed, forKey: "sparkbar.key.\(account)")
    }

    public static func loadKey(for account: String) -> String {
        // Check environment variables first for power users
        let envMap: [String: String] = [
            "deepseek": "DEEPSEEK_API_KEY",
            "openai": "OPENAI_API_KEY",
            "openrouter": "OPENROUTER_API_KEY",
            "anthropic": "ANTHROPIC_API_KEY",
            "groq": "GROQ_API_KEY",
            "gemini": "GEMINI_API_KEY"
        ]
        if let envVar = envMap[account],
           let envVal = ProcessInfo.processInfo.environment[envVar],
           !envVal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return envVal.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess,
           let data = item as? Data,
           let key = String(data: data, encoding: .utf8),
           !key.isEmpty {
            return key
        }

        return UserDefaults.standard.string(forKey: "sparkbar.key.\(account)") ?? ""
    }
}
