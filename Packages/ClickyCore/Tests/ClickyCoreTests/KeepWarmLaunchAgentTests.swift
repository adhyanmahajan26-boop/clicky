import Foundation
import Testing
@testable import ClickyCore

/// The keep-warm LaunchAgent plist and its decisions. Pure: plists are written only to a temporary
/// directory and linted with plutil there. launchctl is never run, and ~/Library/LaunchAgents is never touched.
struct KeepWarmLaunchAgentTests {
    static let fakeHomeDirectoryPath = "/Users/tester"
    static let fakeUserIdentifier: uid_t = 501

    static func parsedPlist() throws -> [String: Any] {
        let plistData = try KeepWarmLaunchAgent.plistData(homeDirectoryPath: fakeHomeDirectoryPath)
        return try #require(try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
    }

    @Test func generatedPlistParsesWithExactProgramArgumentsAndEnvironment() throws {
        let plist = try Self.parsedPlist()
        #expect(plist["Label"] as? String == "local.clicky.tts")
        #expect(plist["ProgramArguments"] as? [String] == ["/Applications/MLX Core.app/Contents/MacOS/mlx-serve", "serve", "--host", "127.0.0.1", "--port", "11234"])
        #expect(plist["EnvironmentVariables"] as? [String: String] == ["HF_HUB_OFFLINE": "1", "HF_HUB_CACHE": "/Users/tester/.cache/huggingface/hub"])
    }

    @Test func generatedPlistHasTheLaunchOptionsAndAbsoluteLogPath() throws {
        let plist = try Self.parsedPlist()
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? Bool == true)
        #expect(plist["ThrottleInterval"] as? Int == 30)
        #expect(plist["ProcessType"] as? String == "Interactive")
        #expect(plist["StandardErrorPath"] as? String == "/Users/tester/Library/Logs/Clicky/mlx-serve.log")
        #expect(Set(plist.keys) == ["Label", "ProgramArguments", "EnvironmentVariables", "RunAtLoad", "KeepAlive", "ThrottleInterval", "ProcessType", "StandardErrorPath"])
    }

    @Test func generatedPlistPassesPlutilLint() throws {
        let plistData = try KeepWarmLaunchAgent.plistData(homeDirectoryPath: Self.fakeHomeDirectoryPath)
        let temporaryPlistURL = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-keepwarm-test-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: temporaryPlistURL) }
        try plistData.write(to: temporaryPlistURL)

        let lintProcess = Process()
        lintProcess.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        lintProcess.arguments = ["-lint", temporaryPlistURL.path]
        lintProcess.standardOutput = FileHandle.nullDevice
        lintProcess.standardError = FileHandle.nullDevice
        try lintProcess.run()
        lintProcess.waitUntilExit()
        #expect(lintProcess.terminationStatus == 0)
    }

    @Test func plistFilePathIsInTheUsersLaunchAgents() {
        #expect(KeepWarmLaunchAgent.plistFilePath(homeDirectoryPath: Self.fakeHomeDirectoryPath) == "/Users/tester/Library/LaunchAgents/local.clicky.tts.plist")
    }

    @Test func bootoutAndBootstrapArgumentsAreExact() {
        #expect(KeepWarmLaunchAgent.bootoutArguments(userIdentifier: Self.fakeUserIdentifier) == ["/bin/launchctl", "bootout", "gui/501/local.clicky.tts"])
        #expect(KeepWarmLaunchAgent.bootstrapArguments(userIdentifier: Self.fakeUserIdentifier, plistFilePath: "/Users/tester/Library/LaunchAgents/local.clicky.tts.plist")
                == ["/bin/launchctl", "bootstrap", "gui/501", "/Users/tester/Library/LaunchAgents/local.clicky.tts.plist"])
    }

    @Test func installOnlyWhenSettingIsOnAndUserApproved() {
        #expect(KeepWarmLaunchAgent.installDecision(isKeepWarmSettingOn: true, isInstallApprovedByUser: true, isAgentInstalled: false) == .install)
        #expect(KeepWarmLaunchAgent.installDecision(isKeepWarmSettingOn: true, isInstallApprovedByUser: false, isAgentInstalled: false) == .leaveAlone)
        #expect(KeepWarmLaunchAgent.installDecision(isKeepWarmSettingOn: false, isInstallApprovedByUser: true, isAgentInstalled: false) == .leaveAlone)
    }

    @Test func turningTheSettingOffBootsOutAnInstalledAgent() {
        #expect(KeepWarmLaunchAgent.installDecision(isKeepWarmSettingOn: false, isInstallApprovedByUser: true, isAgentInstalled: true) == .bootOut)
        #expect(KeepWarmLaunchAgent.installDecision(isKeepWarmSettingOn: false, isInstallApprovedByUser: false, isAgentInstalled: false) == .leaveAlone)
    }

    @Test func adoptsARunningServerOnlyWhenHealthyAndSameModel() {
        let expectedModel = QwenTuning.defaultModelIdentifier
        #expect(KeepWarmLaunchAgent.adoptDecision(healthStatusCode: 200, servedModelIdentifiers: [expectedModel], expectedModelIdentifier: expectedModel) == .adoptRunningServer)
        #expect(KeepWarmLaunchAgent.adoptDecision(healthStatusCode: 200, servedModelIdentifiers: ["some/other-model"], expectedModelIdentifier: expectedModel) == .startOwnServer)
        #expect(KeepWarmLaunchAgent.adoptDecision(healthStatusCode: 503, servedModelIdentifiers: [expectedModel], expectedModelIdentifier: expectedModel) == .startOwnServer)
        #expect(KeepWarmLaunchAgent.adoptDecision(healthStatusCode: nil, servedModelIdentifiers: [], expectedModelIdentifier: expectedModel) == .startOwnServer)
    }

    @Test func installPlanCarriesThePlistAndBootstrapArguments() throws {
        let plan = try KeepWarmLaunchAgent.installPlanRequiringUserApproval(homeDirectoryPath: Self.fakeHomeDirectoryPath, userIdentifier: Self.fakeUserIdentifier)
        #expect(plan.plistFilePath == "/Users/tester/Library/LaunchAgents/local.clicky.tts.plist")
        #expect(plan.bootstrapArguments == ["/bin/launchctl", "bootstrap", "gui/501", "/Users/tester/Library/LaunchAgents/local.clicky.tts.plist"])
        #expect(plan.plistData == (try KeepWarmLaunchAgent.plistData(homeDirectoryPath: Self.fakeHomeDirectoryPath)))
    }
}
