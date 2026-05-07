import Foundation
import Security
import ClearlyCore

/// Stores the vault chat API bearer token outside UserDefaults. Endpoint and
/// model preferences are plain settings, but the token is a credential.
enum ChatAPIKeychain {
    private static let service = "com.sabotage.clearly.vault-chat-api"
    private static let account = "openai-compatible"

    static func loadToken() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let token = String(data: data, encoding: .utf8)
            else {
                throw KeychainError.unreadableData
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    static func saveToken(_ token: String) throws {
        guard !token.isEmpty else {
            try deleteToken()
            return
        }

        let data = Data(token.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = baseQuery()
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.status(addStatus)
            }
        default:
            throw KeychainError.status(updateStatus)
        }
    }

    static func deleteToken() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    enum KeychainError: LocalizedError, Equatable {
        case status(OSStatus)
        case unreadableData

        var errorDescription: String? {
            switch self {
            case .status(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return "Keychain error: \(message)"
            case .unreadableData:
                return "Keychain item was not valid UTF-8."
            }
        }
    }
}

extension OpenAICompatibleAgentRunner.Settings {
    static func loadFromUserDefaults(_ defaults: UserDefaults = .standard) throws -> Self {
        let baseURLString = defaults.string(forKey: OpenAICompatibleAgentRunner.Keys.baseURL) ??
            OpenAICompatibleAgentRunner.Settings.defaultBaseURLString
        let baseURL = try normalizedBaseURL(from: baseURLString)
        let model = (defaults.string(forKey: OpenAICompatibleAgentRunner.Keys.model) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw VaultChatAPIConfigurationError.missingModel
        }
        let thinkingRaw = defaults.string(forKey: OpenAICompatibleAgentRunner.Keys.thinkingLevel) ??
            OpenAICompatibleAgentRunner.ThinkingLevel.providerDefault.rawValue
        let thinkingLevel = OpenAICompatibleAgentRunner.ThinkingLevel(rawValue: thinkingRaw) ?? .providerDefault
        let token = try ChatAPIKeychain.loadToken() ?? ""
        return Self(
            baseURL: baseURL,
            token: token,
            model: model,
            thinkingLevel: thinkingLevel
        )
    }
}
