//
//  UpdateController.swift
//  leanring-buddy
//
//  One-click updates. Checks the updates repo's newest release (at launch,
//  every 6 hours, or from the Update button); when it's newer than this
//  build, the panel and Setup offer "Update now". That downloads the zip,
//  checks its SHA-256 against the release notes, unzips it, checks the new
//  app is signed by the same team with the same bundle id, then quits and
//  lets a small script swap the app in place and open the new one.
//  Permissions survive: the signature identity doesn't change.
//

import AppKit
import ClickyCore
import Combine
import CryptoKit
import Foundation
import Security

@MainActor
final class UpdateController: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateRelease)
        case installing(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private var periodicCheckTimer: Timer?
    static let checkIntervalSeconds: TimeInterval = 6 * 60 * 60

    var currentBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }
    var currentVersionLabel: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "\(version) (build \(currentBuild))"
    }

    var availableRelease: UpdateRelease? {
        if case .available(let release) = state { return release }
        return nil
    }

    /// Checks soon after launch and then every 6 hours (never installs by itself).
    func startAutomaticChecks() {
        guard ClickySettings.isUpdateAutoCheckEnabled else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            await self?.check(quietly: true)
        }
        periodicCheckTimer = Timer.scheduledTimer(withTimeInterval: Self.checkIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(quietly: true) }
        }
    }

    /// `quietly`: a failed background check leaves the state as it was.
    func check(quietly: Bool = false) async {
        if case .installing = state { return }
        let previousState = state
        if !quietly { state = .checking }
        var request = URLRequest(url: ClickySettings.updateFeedURL)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let token = await accessToken()
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard statusCode == 200 else {
                if quietly { state = previousState } else {
                    state = .failed(statusCode != 404 ? "The update check answered \(statusCode)."
                                    : token == nil ? "This Mac isn't signed in to GitHub, so it can't see your private updates. Run gh auth login in Terminal, or paste a token below."
                                    : "No updates published yet.")
                }
                return
            }
            guard let release = UpdateFeed.parseRelease(data) else {
                if !quietly { state = .failed("The newest release isn't a Clicky build.") }
                return
            }
            state = UpdateFeed.isNewer(release, thanBuild: currentBuild) ? .available(release) : .upToDate
            print("⬆️ Update check: newest build \(release.build), this is \(currentBuild)")
        } catch {
            if quietly { state = previousState } else { state = .failed("Couldn't reach the updates repo: \(error.localizedDescription)") }
        }
    }

    /// Download, verify, swap, relaunch.
    func installAvailableUpdate() {
        guard let release = availableRelease else { return }
        state = .installing("Downloading build \(release.build)…")
        Task {
            do {
                let newAppURL = try await download(release)
                state = .installing("Installing…")
                try relaunchInto(newAppURL)
            } catch {
                state = .failed("Update failed: \(error.localizedDescription)")
            }
        }
    }

    /// The other Mac asked: checks, and installs once nothing's going on here. Gives up after half an hour.
    func installWhenIdle() {
        Task { @MainActor [weak self] in
            for _ in 0..<30 {
                guard let self else { return }
                await self.check(quietly: true)
                guard self.availableRelease != nil else { return }
                let store = BotsStore.shared
                let busy = !store.replying.isEmpty || store.isClickyBusy || TheoCallController.isActive
                    || store.t3Runs.contains { !$0.isRemote && ["running", "waiting", "reporting"].contains($0.phase) }
                if !busy {
                    self.installAvailableUpdate()
                    return
                }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    // MARK: - Steps

    /// The updates repo is private: a saved token, or this Mac's own GitHub sign-in, so there's nothing to paste.
    private func accessToken() async -> String? {
        if let token = ClickySecrets.read(.updateToken) { return token }
        guard let gh = BotsT3.gh else { return nil }
        return await Task.detached { () -> String? in
            let process = Process()
            let output = Pipe()
            process.executableURL = gh
            process.arguments = ["auth", "token", "--hostname", "github.com"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return process.terminationStatus == 0 && !token.isEmpty ? token : nil
        }.value
    }

    struct UpdateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func download(_ release: UpdateRelease) async throws -> URL {
        var request: URLRequest
        if let token = await accessToken(), let apiAssetURL = release.apiAssetURL {
            request = URLRequest(url: apiAssetURL)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        } else {
            request = URLRequest(url: release.zipURL)
        }
        request.timeoutInterval = 300
        let (downloadedFileURL, response) = try await URLSession.shared.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError(message: "the download answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let zipData = try Data(contentsOf: downloadedFileURL, options: .mappedIfSafe)
        let digest = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
        guard digest == release.sha256 else { throw UpdateError(message: "the download doesn't match its checksum") }

        let workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-update-\(release.build)", isDirectory: true)
        try? FileManager.default.removeItem(at: workDirectory)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let zipURL = workDirectory.appendingPathComponent("update.zip")
        try zipData.write(to: zipURL)
        try runTool("/usr/bin/ditto", ["-x", "-k", zipURL.path, workDirectory.path])
        guard let newAppURL = findApp(in: workDirectory) else { throw UpdateError(message: "the zip has no app in it") }
        try verifySameIdentity(newAppURL)
        return newAppURL
    }

    private func findApp(in directory: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "app" { return url }
        }
        return nil
    }

    /// Same bundle id, same signing team, a valid signature: nothing else replaces Clicky.
    private func verifySameIdentity(_ newAppURL: URL) throws {
        try runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", newAppURL.path])
        guard let newBundle = Bundle(url: newAppURL), newBundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError(message: "the new app isn't Clicky")
        }
        guard let newTeam = Self.teamIdentifier(of: newAppURL), newTeam == Self.teamIdentifier(of: Bundle.main.bundleURL) else {
            throw UpdateError(message: "the new app isn't signed by the same developer")
        }
    }

    static func teamIdentifier(of appURL: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private func relaunchInto(_ newAppURL: URL) throws {
        let installedAppPath = Bundle.main.bundleURL.path
        let script = UpdateFeed.installScript(processIdentifier: getpid(), newAppPath: newAppURL.path, installedAppPath: installedAppPath)
        let scriptURL = newAppURL.deletingLastPathComponent().appendingPathComponent("install-update.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        print("⬆️ Update: installing \(newAppURL.lastPathComponent) over \(installedAppPath) and relaunching")
        NSApp.terminate(nil)
    }

    private func runTool(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw UpdateError(message: "\(URL(fileURLWithPath: path).lastPathComponent) failed: \(message.prefix(160))")
        }
    }
}
