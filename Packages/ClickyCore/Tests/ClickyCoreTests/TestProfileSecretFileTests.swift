import Foundation
import Testing
@testable import ClickyCore

@Suite("A test profile's secrets live in a file, not the Keychain")
struct TestProfileSecretFileTests {
    private func makeSecretFile() -> TestProfileSecretFile {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("secret-file-\(UUID().uuidString)", isDirectory: true)
        return TestProfileSecretFile(fileURL: folder.appendingPathComponent("test-secrets.json"))
    }

    @Test("A saved secret reads back, per service and account")
    func savedSecretReadsBack() {
        let secretFile = makeSecretFile()
        #expect(secretFile.write(service: "com.theo.providers.test-speed", account: "openai", value: "sk-test-one"))
        #expect(secretFile.write(service: "com.theo.gateway.test-speed", account: "token", value: "theo_token"))
        #expect(secretFile.read(service: "com.theo.providers.test-speed", account: "openai") == "sk-test-one")
        #expect(secretFile.read(service: "com.theo.gateway.test-speed", account: "token") == "theo_token")
        #expect(secretFile.read(service: "com.theo.providers.test-speed", account: "anthropic") == nil)
    }

    @Test("Saving nothing removes the secret")
    func emptyValueRemovesSecret() {
        let secretFile = makeSecretFile()
        secretFile.write(service: "service", account: "account", value: "value")
        secretFile.write(service: "service", account: "account", value: nil)
        #expect(secretFile.read(service: "service", account: "account") == nil)
        secretFile.write(service: "service", account: "account", value: "again")
        secretFile.write(service: "service", account: "account", value: "")
        #expect(secretFile.read(service: "service", account: "account") == nil)
    }

    @Test("Only the owner's account can read the file")
    func fileIsPrivate() throws {
        let secretFile = makeSecretFile()
        secretFile.write(service: "service", account: "account", value: "value")
        let attributes = try FileManager.default.attributesOfItem(atPath: secretFile.fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
