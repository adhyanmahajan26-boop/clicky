//
//  BotPlaces.swift
//  leanring-buddy
//
//  Where a bot is and what it's for. "Theo works on the Mac you're using": a message typed on a Mac is answered on that Mac, with its
//  folders and coding runs there. These are the facts behind the "where you are" and "who you are" blocks every bot turn starts with,
//  what this Mac tells the other one about itself, and bot memory, which lives in Theo's own folder rather than in T3 Code's.
//

import ClickyCore
import Foundation

/// This turn runs here for the other Mac, because the bot's engine can't run there.
struct ForwardedTurn: Equatable {
    /// The Mac the owner typed on, by its full name.
    var fromMacFullName: String
    var why: String
    var fromMac: String { TheoLink.shortName(fromMacFullName) }
}

/// Whether a bot's engine can run on this Mac.
@MainActor
enum EngineReadiness {
    /// What's in the way, in words for the chat. Nil when it can run, or when Theo can't tell yet.
    static func problem(with provider: String) -> String? {
        if TheoProfile.isTest, UserDefaults.standard.stringArray(forKey: "test.engines.missing")?.contains(provider) == true { return "\(HarnessCatalog.label(provider)) isn't signed in" }
        if provider.hasPrefix("api:") {
            let id = String(provider.dropFirst("api:".count))
            return ProviderKeys.shared.hasKey(for: id) ? nil : "there's no \(ProviderInfo.info(for: id)?.label ?? id) key saved"
        }
        guard let status = HarnessCenter.shared.statuses[provider] else { return nil }
        let label = HarnessCatalog.label(provider)
        if !status.installed { return "\(label) isn't installed" }
        if status.loggedIn == false, !HarnessPrefs.usesAPIKey(provider) { return "\(label) isn't signed in" }
        return nil
    }
}

/// What this Mac tells the other one about itself.
@MainActor
enum DeviceSnapshotBuilder {
    static func current() -> DeviceSnapshot {
        var ready: [String: Bool] = [:]
        for info in HarnessCatalog.all {
            if let status = HarnessCenter.shared.statuses[info.id] { ready[info.id] = status.ready }
        }
        for provider in ProviderKeys.shared.usableChatProviders { ready["api:\(provider.id)"] = true }
        return DeviceSnapshot(name: TheoLink.localName, projectsFolder: BotsT3.projectsFolder.path, projects: BotsT3.projects(), harnesses: ready,
                              hasScreens: StudioController.isAvailable, t3Version: HarnessCenter.shared.statuses["t3"]?.version, firesRoutines: DeviceRoles.runsHere(.routines))
    }
}

extension BotsStore {
    /// The facts for this chat's "where you are" block, for this bot's turn.
    func placeFacts(room: String, bot: NativeBot? = nil) -> BotPlaceFacts {
        let link = TheoLink.shared
        let here = TheoLink.shortName(TheoLink.localName)
        let center = HarnessCenter.shared
        let hereReady = HarnessCatalog.all.compactMap { info -> String? in
            guard let status = center.statuses[info.id], status.ready else { return nil }
            if info.id == "t3" { return status.version.map { "T3 Code \($0)" } ?? "T3 Code" }
            return status.loggedIn == true ? "\(info.label) (signed in)" : info.label
        }
        let hereProjects = BotsT3.projects().map(\.name)
        let otherName = link.isPaired ? (link.peerName ?? link.knownPeerName).map(TheoLink.shortName) : nil
        // This turn is about to run on the other Mac, and the bot should hear so from that Mac's side.
        if let bot, let across = turnGoesAcross(bot), let other = otherName {
            return BotPlaceFacts(owner: BotPrompts.ownerName, thisMac: other, ownerMac: here, whyHere: across.why, codingMac: here, projects: hereProjects, projectsFolder: BotsT3.projectsWords,
                                 ready: peerReadyLabels, otherMac: here, otherMacConnected: true, otherMacHasScreens: StudioController.isAvailable, thisMacHasScreens: peerDevice?.hasScreens ?? false)
        }
        let forwarded = forwardedTurns[room]
        let projects = forwarded != nil ? (peerDevice?.projects.map(\.name) ?? []) : hereProjects
        // Run on this Mac for the other one, its folders are the other Mac's. Only a test profile's folder isn't "~/Projects" there.
        let projectsFolder = forwarded != nil && TheoProfile.isTest ? (peerDevice?.projectsFolder ?? BotsT3.projectsWords) : BotsT3.projectsWords
        // Bots & coding is set to this Mac, and the owner typed on the other: its folders and runs are this Mac's.
        let typedOn = ownerMacs[room].map(TheoLink.shortName)
        let why = forwarded?.why ?? typedOn.map { _ in "Bots & coding is set to this Mac" }
        return BotPlaceFacts(owner: BotPrompts.ownerName, thisMac: here, ownerMac: forwarded?.fromMac ?? typedOn, whyHere: why, codingMac: forwarded?.fromMac, projects: projects, projectsFolder: projectsFolder, ready: hereReady,
                             otherMac: otherName, otherMacConnected: link.isConnected, otherMacHasScreens: otherName != nil && (peerDevice?.hasScreens ?? (DeviceRoles.thisMac != .macStudio)),
                             thisMacHasScreens: StudioController.isAvailable)
    }

    private var peerReadyLabels: [String] {
        guard let peer = peerDevice else { return [] }
        return HarnessCatalog.all.filter { peer.harnesses[$0.id] == true }.map { info in
            info.id == "t3" ? (peer.t3Version.map { "T3 Code \($0)" } ?? "T3 Code") : info.label
        }
    }

    /// When this bot's engine can't run on this Mac but can on the other, connected one: that Mac's name, and why. Nil means it runs here.
    func turnGoesAcross(_ bot: NativeBot) -> (mac: String, why: String)? {
        guard let problem = EngineReadiness.problem(with: bot.provider), let peer = TheoLink.shared.peerName,
              DeviceRouting.botTurn(choice: DeviceRoles.choice(.bots), thisMac: DeviceRoles.thisMac, paired: TheoLink.shared.isPaired, otherMacOnline: TheoLink.shared.isConnected,
                                    engineHere: false, engineThere: peerDevice?.harnesses[bot.provider] == true) == .engineOnOtherMac else { return nil }
        return (peer, "\(problem) on the \(TheoLink.shortName(TheoLink.localName))")
    }

    /// One bot's turn on the other Mac. It answers there, its words reach this chat through the link, and this Mac carries on from them.
    func runTurnOnOtherMac(_ bot: NativeBot, across: (mac: String, why: String), in room: String, prompt: String, privately: BotDMTurn?, fromOwner: Bool, then: @escaping (String?) -> Void) {
        let exchangeID = privately?.exchangeID
        turnsOnOtherMac.insert(bot.id)
        post(BotChatMessage(author: Self.noteAuthor, text: "Answered on your \(TheoLink.shortName(across.mac)): \(across.why).", exchangeID: exchangeID), to: room)
        // While a group talks a build through, this Mac starts the run from the outcome: the other Mac mustn't start one too.
        var fields = ["bot": bot.id, "room": room, "prompt": prompt, "fromMac": TheoLink.localName, "why": across.why, "fromOwner": fromOwner && !isDiscussing(room) ? "1" : "0"]
        if let privately {
            let chain = "\(TheoLink.localName)#\(ownerTurns[privately.context.rootRoom] ?? 0)"
            fields.merge(privately.linkFields(chain: chain)) { _, new in new }
        }
        Task { [weak self] in
            let reply = await TheoLink.shared.ask("botTurn", fields, timeoutSeconds: BotRunner.turnLimitSeconds + 60)
            guard let self else { return }
            let wasStopped = self.stopped.remove(bot.id) != nil
            self.turnsOnOtherMac.remove(bot.id)
            self.endTurnHere(bot.id)
            guard let reply, !wasStopped else {
                if !wasStopped { self.post(BotChatMessage(author: bot.id, text: "Couldn't reply: your \(TheoLink.shortName(across.mac)) stopped answering.", exchangeID: exchangeID), to: room) }
                return then(nil)
            }
            let answer = reply["answer"].flatMap { $0.isEmpty ? nil : $0 }
            // Whoever's next should read this bot's words, and they're on their way over the link.
            if let answer, let messageID = reply["message"] {
                TheoLink.shared.syncSoon()
                for _ in 0..<40 where !self.conversation(room).messages.contains(where: { $0.id == messageID }) { try? await Task.sleep(nanoseconds: 250_000_000) }
                then(answer)
            } else {
                then(answer)
            }
        }
    }

    /// The other Mac asks this one to run a bot's turn, because its engine can't run there.
    func handleTurnFromOtherMac(_ fields: [String: String]) {
        guard let botID = fields["bot"], let room = fields["room"], let prompt = fields["prompt"], let replyID = fields["replyID"] else { return }
        guard let target = bot(botID) else {
            // This Mac doesn't have that bot yet: the asker hears at once rather than waiting out the turn's time limit.
            _ = TheoLink.shared.request("reply", ["replyID": replyID, "answer": "", "message": ""])
            return
        }
        if let from = fields["fromMac"], let why = fields["why"] { forwardedTurns[room] = ForwardedTurn(fromMacFullName: from, why: why) }
        if fields["fromOwner"] == "1" { ownerSpoke(in: room) }
        Task { [weak self] in
            // It might be busy here too.
            while self?.replying[botID] != nil { try? await Task.sleep(nanoseconds: 500_000_000) }
            guard let self else { return }
            let session = self.conversation(room).sessions[botID]
            // Part of a private exchange: who asked, and the chat the owner spoke in, whose limits start over with each message of theirs.
            let turn = BotDMTurn(linkFields: fields)
            if let turn, let chain = fields["chain"], self.ownerMessageMarks.isNew(room: turn.context.rootRoom, message: chain) { self.ownerSpoke(in: turn.context.rootRoom) }
            self.reply(bot: target, in: room, prompt: prompt, session: session, handsOnWhenStopped: true, fromOwner: fields["fromOwner"] == "1", mayUseScreen: turn?.context.ownerWords != nil, privately: turn) { [weak self] answer in
                guard let self else { return }
                self.forwardedTurns[room] = nil
                let message = self.conversation(room).messages.last { $0.author == botID }
                _ = TheoLink.shared.request("reply", ["replyID": replyID, "answer": answer ?? "", "message": message?.id ?? ""])
            }
        }
    }

    /// The facts for a bot's "who you are" block, from its own settings.
    func identityFacts(of bot: NativeBot) -> BotIdentityFacts {
        let teams = categories(of: bot.id)
        let description = bot.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstSentence = bot.instructions.split(whereSeparator: { ".\n".contains($0) }).first.map(String.init) ?? ""
        let job = description.isEmpty ? firstSentence : description
        return BotIdentityFacts(name: bot.name, owner: BotPrompts.ownerName, job: String(job.prefix(160)), isCEO: bot.primary, teams: teams.map(\.name),
                                managerName: manager(of: bot)?.name, managesTeams: teams.filter { $0.leaderID == bot.id }.map(\.name),
                                ceoName: primary?.name, apps: BotConnectors.known.filter { bot.apps.contains($0.id) }.map(\.name), memoryPath: bot.provider.hasPrefix("api:") ? nil : bot.memoryPath)
    }

    /// When the owner talks about carrying on earlier work: that folder's chats on that harness, for the bot to pick from.
    func recentChatsNote(for words: String, room: String) async -> String? {
        guard CodingIntent.asksToContinueChat(words) else { return nil }
        let harness = continuingHarness(words: words, room: room)
        let named = projectChoice(ownerWords: words, answer: nil).repo?.path
        guard let folder = named ?? latestRun(in: room).flatMap({ $0.isRemote ? nil : $0.folder }) else {
            return "Addy wants to carry on earlier work but no folder is clear yet: ask which folder, in one short question."
        }
        let chats = await HarnessChats.list(harness: harness, folder: folder)
        let label = HarnessCatalog.label(harness)
        if chats.isEmpty, harness == "t3", !HarnessChats.isT3ServerUp {
            return "T3 Code isn't open on this Mac, so its threads in \(folder) can't be listed right now. If Addy names one by its title, write it in a \"Continue:\" line anyway, and Theo opens T3 Code to find it."
        }
        guard !chats.isEmpty else { return "There are no earlier \(label) chats in \(folder), so a run there starts a new one. Say so if Addy asked to continue one." }
        let lines = chats.prefix(8).map { "- \($0.title) (\(HarnessChatText.age(of: $0.updatedAt)) ago): \($0.id)" }.joined(separator: "\n")
        return "Earlier \(label) chats in \(folder), newest first:\n\(lines)\nTo continue one, write a line \"Continue: <its id>\" next to the ```prompt block, with \"Repo: \(folder)\"."
    }
}

/// A bot's memory file, in Theo's own folder. It used to be in ~/.t3/bots, which now belongs to stock T3 Code.
enum BotMemory {
    static let relativeFolder = "Library/Application Support/Theo/Bots/memory"

    /// The folder all memory files sit in. Bots run from here, so reading and keeping memory never needs a permission nobody is there to give.
    static var root: URL {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(relativeFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func file(botID: String) -> URL { root.appendingPathComponent(botID, isDirectory: true).appendingPathComponent("memory.md") }

    /// The harness guide every bot can read (ClickyCore `HarnessGuide`), next to the memory files, where bots run.
    static var guideFile: URL { root.appendingPathComponent(HarnessGuide.fileName) }

    /// Written at launch, so it always matches this build's rules. Only rewritten when it changed.
    static func writeGuide(owner: String) {
        let text = HarnessGuide.markdown(owner: owner)
        if (try? String(contentsOf: guideFile, encoding: .utf8)) != text { try? text.write(to: guideFile, atomically: true, encoding: .utf8) }
    }

    static func read(botID: String) -> String { (try? String(contentsOf: file(botID: botID), encoding: .utf8)) ?? "" }

    /// What's on both Macs, each line once. Written only when a line is new.
    static func merge(_ theirs: String, botID: String) {
        let mine = read(botID: botID)
        let merged = BotMemoryMerge.union(mine, theirs)
        guard BotMemoryMerge.digest(merged) != BotMemoryMerge.digest(mine) else { return }
        let target = file(botID: botID)
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? merged.write(to: target, atomically: true, encoding: .utf8)
    }

    /// One fingerprint per bot that has memory.
    static func digests(botIDs: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for id in botIDs {
            let text = read(botID: id)
            if !text.isEmpty { result["botMemory/\(id)"] = BotMemoryMerge.digest(text) }
        }
        return result
    }

    /// Where memory used to be, oldest first, so a file ends up with its history first and what's newer after it.
    nonisolated static let oldFolders = [".t3-backup-20261105/bots", ".t3/bots"]

    /// Once: memory moves here from ~/.t3/bots and its backup. The old files stay where they are, untouched: only T3 Code writes in ~/.t3.
    /// Bots' engine sessions don't need moving: Claude Code finds a session by its id from any folder, and one that's lost starts over from the chat.
    static func migrateOnce() {
        let key = "v3.bots.memoryMoved"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        for old in oldFolders {
            let folder = home.appendingPathComponent(old, isDirectory: true)
            for id in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? [] where !id.hasPrefix(".") {
                if let text = try? String(contentsOf: folder.appendingPathComponent(id).appendingPathComponent("memory.md"), encoding: .utf8) { merge(text, botID: id) }
            }
        }
    }
}

/// Skills: step-by-step procedures saved as `skills/<name>/SKILL.md` (ClickyCore `BotSkill`). A bot writes its own in
/// `memory/<bot>/skills/`, the only place it may write; the owner can drop shared ones (agentskills.io layout) in `memory/skills/`.
/// Every bot sees all of them listed in its prompt and reads one before a task it matches.
enum BotSkills {
    static var sharedFolder: URL { BotMemory.root.appendingPathComponent("skills", isDirectory: true) }
    static func folder(botID: String) -> URL { BotMemory.file(botID: botID).deletingLastPathComponent().appendingPathComponent("skills", isDirectory: true) }

    /// Every skill on this Mac: the shared folder's, then each bot's. `names` maps a bot id to its name.
    static func all(names: [String: String]) -> [BotSkill] {
        var skills: [BotSkill] = []
        func scan(_ folder: URL, author: String?) {
            guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let file = entry.appendingPathComponent("SKILL.md")
                // Only the start: the front matter is all the list needs, and a huge file mustn't slow every turn.
                guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
                let head = String(decoding: (try? handle.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
                try? handle.close()
                if let skill = BotSkill.parse(head, path: file.path, author: author, folderName: entry.lastPathComponent) { skills.append(skill) }
            }
        }
        scan(sharedFolder, author: nil)
        for (id, name) in names.sorted(by: { $0.key < $1.key }) { scan(folder(botID: id), author: name) }
        return skills
    }
}
