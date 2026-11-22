//
//  TestProfileSecretFile.swift
//  ClickyCore
//
//  Where a test profile keeps its secrets instead of the login Keychain: one JSON file, readable only by the owner,
//  in the test profile's own folder. A test build is signed differently from the owner's Vello and from the build
//  before it, so any Keychain item it made or read could bring up a macOS password prompt on the owner's screen.
//  A test profile never touches the Keychain at all, so that can't happen. The owner's real profile keeps using
//  the Keychain.
//

import Foundation

public final class TestProfileSecretFile: @unchecked Sendable {
    /// The file: `{ "service": { "account": "value" } }`.
    public let fileURL: URL
    private let fileLock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func read(service: String, account: String) -> String? {
        fileLock.lock(); defer { fileLock.unlock() }
        let value = readAllSecrets()[service]?[account]
        return value?.isEmpty == false ? value : nil
    }

    /// Saves one secret, or removes it when the value is nil or empty. Returns whether the file was written.
    @discardableResult
    public func write(service: String, account: String, value: String?) -> Bool {
        fileLock.lock(); defer { fileLock.unlock() }
        var allSecrets = readAllSecrets()
        var secretsForService = allSecrets[service] ?? [:]
        if let value, !value.isEmpty {
            secretsForService[account] = value
        } else {
            secretsForService[account] = nil
        }
        allSecrets[service] = secretsForService.isEmpty ? nil : secretsForService
        return writeAllSecrets(allSecrets)
    }

    private func readAllSecrets() -> [String: [String: String]] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { return [:] }
        return decoded
    }

    private func writeAllSecrets(_ allSecrets: [String: [String: String]]) -> Bool {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(allSecrets)
            try data.write(to: fileURL, options: .atomic)
            // Only the owner's account can read it, like a Keychain item.
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            return false
        }
    }
}
