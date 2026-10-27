//
//  ClickySecrets.swift
//  ClickyCore
//
//  The two secrets Setup saves: the Anthropic API key (API-key mode) and
//  the key for a voice server on another Mac. Both live in the login
//  Keychain as generic passwords, never in UserDefaults; reads are cached
//  so every Claude Code launch doesn't hit the Keychain.
//

import Foundation
import Security

public enum ClickySecrets {
    public enum Item: String, CaseIterable, Sendable {
        case anthropicAPIKey = "anthropic-api-key"
        case voiceServerKey = "voice-server-key"
        /// Read-only GitHub token, only for a private updates repo.
        case updateToken = "update-token"
    }

    static let service = "com.personal.clicky.secrets"
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [Item: String?] = [:]

    public static func read(_ item: Item) -> String? {
        cacheLock.lock()
        if let cached = cache[item] { cacheLock.unlock(); return cached }
        cacheLock.unlock()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        var value: String?
        if status == errSecSuccess, let data = result as? Data {
            value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if value?.isEmpty == true { value = nil }
        }
        cacheLock.lock(); cache[item] = .some(value); cacheLock.unlock()
        return value
    }

    /// Saves (or, for an empty string, deletes) one secret.
    @discardableResult
    public static func write(_ item: Item, value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue
        ]
        SecItemDelete(baseQuery as CFDictionary)
        var status = errSecSuccess
        if !trimmed.isEmpty {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = Data(trimmed.utf8)
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        cacheLock.lock(); cache[item] = .some(trimmed.isEmpty ? nil : trimmed); cacheLock.unlock()
        return status == errSecSuccess
    }
}
