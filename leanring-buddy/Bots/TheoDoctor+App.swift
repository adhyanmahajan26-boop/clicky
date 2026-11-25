//
//  TheoDoctor+App.swift
//  leanring-buddy
//
//  The health check (ClickyCore `TheoDoctor`): brains, permissions, apps, the other Mac, updates, saved files, bots,
//  routines, memory, skills, hooks and the local API. It only reads; nothing is changed or started. Problems carry a fix
//  (`TheoDoctorFix`), which Settings › Health and Home's "Finish setting up" show as a button (`TheoHealth`).
//

import AVFoundation
import ClickyCore
import Foundation

extension BotsStore {
    func doctorFindings() -> [TheoDoctorFinding] {
        var findings: [TheoDoctorFinding] = setupFindings()
        let fileManager = FileManager.default
        // Engines the bots use: installed and signed in.
        let engines = Set(bots.filter { $0.isOn && !$0.provider.hasPrefix("api:") }.map(\.provider))
        for engine in engines.sorted() {
            let users = bots.filter { $0.isOn && $0.provider == engine }.map(\.name)
            var status = HarnessCenter.shared.status(for: engine)
            let label = HarnessCatalog.label(engine)
            // The engines bots run directly: found where the bots find them (a test profile's stand-in included), even before Settings has checked.
            if let provider = BrainProvider(rawValue: engine), provider == .claude || provider == .opencode {
                status.installed = BotRunner.executable(for: provider) != nil
                if !HarnessCenter.shared.hasStatus(for: engine) { status.loggedIn = nil }
            }
            if !status.installed {
                findings.append(.init(.fail, label, "Not installed on this Mac, and \(users.joined(separator: ", ")) \(users.count == 1 ? "runs" : "run") on it. Install it in Settings › Harnesses.", fix: .openSettings(section: "coding")))
            } else if status.loggedIn == false {
                findings.append(.init(.fail, label, "Not signed in. \(users.joined(separator: ", ")) can't answer until you sign in, in Settings › Harnesses.", fix: .openSettings(section: "coding")))
            } else {
                findings.append(.init(.ok, label, "Installed\(status.loggedIn == true ? " and signed in" : ""); \(users.count) bot\(users.count == 1 ? " uses" : "s use") it."))
            }
        }
        for bot in bots where bot.isOn && bot.provider.hasPrefix("api:") {
            let provider = String(bot.provider.dropFirst(4))
            if ProviderKeychain.get(provider) == nil {
                findings.append(.init(.fail, "\(bot.name)'s key", "\(bot.name) runs on a \(provider) key, and none is saved. Add it in Settings › Models & API keys.", fix: .openSettings(section: "keys")))
            }
        }
        // Saved files read back.
        let folder = BotMemory.root.deletingLastPathComponent()
        for name in ["bots.json", "groups.json", "routines.json"] {
            let url = folder.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            if let data = try? Data(contentsOf: url), (try? JSONSerialization.jsonObject(with: data)) != nil {
                findings.append(.init(.ok, name, "Reads back cleanly."))
            } else {
                findings.append(.init(.fail, name, "Can't be read. Vello keeps a .lastgood copy beside it; quit Vello and move that back."))
            }
        }
        if !fileManager.isWritableFile(atPath: folder.path) {
            findings.append(.init(.fail, "Bots folder", "Vello can't write to \(folder.path), so nothing new is saved."))
        }
        // Routines pointing nowhere.
        for routine in routines where !routine.paused {
            if routine.target.hasPrefix("group:"), group(String(routine.target.dropFirst(6))) == nil {
                findings.append(.init(.warn, "Routine \"\(routine.name)\"", "Its group chat is gone, so each run fails. Delete or pause it."))
            } else if !routine.target.contains(":"), let bot = bot(routine.target), !bot.isOn {
                findings.append(.init(.warn, "Routine \"\(routine.name)\"", "\(bot.name) is turned off, so each run is skipped."))
            } else if !routine.target.contains(":"), bot(routine.target) == nil {
                findings.append(.init(.warn, "Routine \"\(routine.name)\"", "Its bot is gone, so each run fails. Delete it."))
            }
            if let last = routine.runs.last, last.status == "failed" {
                findings.append(.init(.warn, "Routine \"\(routine.name)\"", "Its last run failed: \(last.summary ?? "no details")."))
            }
        }
        if !routines.isEmpty {
            findings.append(.init(.ok, "Routines", "\(routines.count) routine\(routines.count == 1 ? "" : "s"), \(routines.filter(\.paused).count) paused."))
        }
        // Memory over its limit, skills that can't be listed.
        for bot in bots where bot.owner == nil {
            let size = BotMemory.read(botID: bot.id).count
            if size > BotMemoryPrompt.limit {
                findings.append(.init(.warn, "\(bot.name)'s memory", "\(size) characters, over the \(BotMemoryPrompt.limit) that go in its prompt. It's asked to tidy it each turn; you can edit it in its settings."))
            }
        }
        let names = Dictionary(bots.filter { $0.owner == nil }.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let listed = Set(BotSkills.all(names: names).map(\.path))
        var unlisted: [String] = []
        for root in [BotSkills.sharedFolder] + names.keys.map({ BotSkills.folder(botID: $0) }) {
            for entry in (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [] {
                let file = root.appendingPathComponent(entry).appendingPathComponent("SKILL.md")
                if fileManager.fileExists(atPath: file.path), !listed.contains(file.path) { unlisted.append(file.path) }
            }
        }
        findings.append(unlisted.isEmpty ? .init(.ok, "Skills", "\(listed.count) skill\(listed.count == 1 ? "" : "s"), all listed.")
                        : .init(.warn, "Skills", "\(unlisted.count) SKILL.md file\(unlisted.count == 1 ? " has" : "s have") no description, so no bot sees \(unlisted.count == 1 ? "it" : "them"): \(unlisted.joined(separator: ", "))."))
        // Hooks that won't run.
        var skippedHooks: [String] = []
        var hookCount = 0
        for event in TheoHookEvent.allCases {
            let directory = TheoHooks.folder.appendingPathComponent(event.rawValue)
            let all = ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []).filter { !$0.hasPrefix(".") }
            let runs = Set(TheoHooks.scripts(for: event).map(\.lastPathComponent))
            hookCount += runs.count
            skippedHooks += all.filter { !runs.contains($0) }.map { "\(event.rawValue)/\($0)" }
        }
        if !skippedHooks.isEmpty {
            findings.append(.init(.warn, "Hooks", "Not run: \(skippedHooks.joined(separator: ", ")). A hook must be an executable file you own that nobody else can write to (chmod 700)."))
        } else if hookCount > 0 {
            findings.append(.init(.ok, "Hooks", "\(hookCount) hook\(hookCount == 1 ? "" : "s") ready."))
        }
        // The local API.
        if TheoGateway.isEnabled {
            let gateway = TheoGateway.shared
            if let problem = gateway.lastProblem { findings.append(.init(.fail, "Local API", problem, fix: .openSettings(section: "devices"))) }
            else if TheoGatewayToken.read() == nil { findings.append(.init(.fail, "Local API", "On, but its token is missing from the Keychain. Make a new one in Settings › Devices.", fix: .openSettings(section: "devices"))) }
            else { findings.append(.init(.ok, "Local API", "Listening on 127.0.0.1:\(TheoGateway.port).")) }
        }
        // Space for chats and runs.
        if let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]), let free = values.volumeAvailableCapacityForImportantUsage {
            let gigabytes = Double(free) / 1_000_000_000
            findings.append(gigabytes < 2 ? .init(.warn, "Disk", String(format: "Only %.1f GB free.", gigabytes)) : .init(.ok, "Disk", String(format: "%.0f GB free.", gigabytes)))
        }
        return findings
    }

    /// What a new Mac (or a Mac that came from the other one) still needs: a brain, your name, the permissions the products
    /// that are on need, the apps bots use signed in here, the other Mac reachable, and the newest build.
    func setupFindings() -> [TheoDoctorFinding] {
        var findings: [TheoDoctorFinding] = []
        // A brain: nothing answers without one.
        if BrainAvailability.inventory.hasUsableBrain {
            findings.append(.init(.ok, "Brain", "At least one brain can answer here."))
        } else {
            findings.append(.init(.fail, "Brain", "Nothing can answer yet. Paste one API key (the quickest), or sign in to a coding agent such as Claude Code or Codex.", fix: .openSettings(section: "keys")))
        }
        if ClickySettings.savedOwnerName.isEmpty {
            findings.append(.init(.warn, "Your name", "Your bots call you \u{201C}the owner\u{201D}. Tell Vello your name.", fix: .openSettings(section: "about")))
        }
        // Permissions, only for what's on.
        let usesVoice = TheoProducts.isOn(.theo) || TheoProducts.isOn(.clicky) || TheoProducts.isOn(.dictation)
        if usesVoice {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: findings.append(.init(.ok, "Microphone", "Allowed."))
            default: findings.append(.init(.warn, "Microphone", "Not allowed, so calls, \u{201C}hey \(ClickySettings.assistantName)\u{201D} and dictation can't hear you.", fix: .askPermission("microphone")))
            }
        }
        if TheoProducts.isOn(.clicky) {
            findings.append(TheoPermissions.isAccessibilityGranted ? .init(.ok, "Accessibility", "Allowed.")
                            : .init(.fail, "Accessibility", "Not allowed, so Vello can't point, click or type for you.", fix: .askPermission("accessibility")))
            findings.append(TheoPermissions.screenRecordingCountsAsGranted ? .init(.ok, "Screen recording", "Allowed.")
                            : .init(.fail, "Screen recording", "Not allowed, so Vello can't see your screen when you ask.", fix: .askPermission("screenRecording")))
        }
        findings += appFindings()
        // The other Mac.
        let link = TheoLink.shared
        if link.isPaired {
            let name = TheoLink.shortName(link.peerName ?? link.knownPeerName ?? "other Mac")
            findings.append(link.isConnected ? .init(.ok, "Your other Mac", "Connected to your \(name).")
                            : .init(.warn, "Your other Mac", "Your \(name) can't be reached, so bots and chats don't sync until it's on and on the same network (or a sync folder is set).", fix: .openSettings(section: "link")))
        }
        // The newest build.
        if let release = CompanionManager.current?.updateController.availableRelease {
            findings.append(.init(.warn, "Update", "Build \(release.build) is ready. Updating takes a few seconds and keeps everything.", fix: .installUpdate))
        }
        return findings
    }

    /// The apps bots use, as they stand on this Mac. Sign-ins stay on the Mac they were made on, so an app connected on the
    /// other Mac shows here as needing a sign-in.
    private func appFindings() -> [TheoDoctorFinding] {
        let botsUsingApps = bots.filter { $0.isOn && !$0.apps.isEmpty }
        guard !botsUsingApps.isEmpty else { return [] }
        guard ConnectorHub.isAvailable else {
            return [.init(.warn, "Apps", ConnectorHub.helperMissingWords)]
        }
        var findings: [TheoDoctorFinding] = []
        let records = ConnectorHealth.shared.hubApps
        for record in records where record.enabled {
            let users = botsUsingApps.filter { $0.apps.contains(record.id) }.map(\.name)
            guard !users.isEmpty else { continue }
            let who = users.count <= 3 ? users.joined(separator: ", ") : "\(users.prefix(2).joined(separator: ", ")) and \(users.count - 2) more"
            switch record.status {
            case "needsSignIn":
                let fix: TheoDoctorFix = record.signsInWithBrowser ? .signInApp(id: record.id) : .openConnectors
                let how = record.isComposio ? "Paste your Composio key on this Mac." : record.takesPastedToken ? "Paste its token on this Mac." : "Sign in on this Mac."
                findings.append(.init(.fail, record.name, "\(who) \(users.count == 1 ? "uses" : "use") it, and it isn't signed in here. \(how)", fix: fix))
            case "failed":
                let reason = record.reason.map { ConnectorListing.plainReason($0, app: record.name) } ?? "It isn't answering."
                findings.append(.init(.fail, record.name, "\(reason) \(who) \(users.count == 1 ? "uses" : "use") it.", fix: record.isClaudeAccount ? .openConnectors : (record.signsInWithBrowser ? .signInApp(id: record.id) : .openConnectors)))
            case "connected":
                findings.append(.init(.ok, record.name, "Connected; \(who) \(users.count == 1 ? "uses" : "use") it."))
            default:
                continue
            }
        }
        return findings
    }
}
