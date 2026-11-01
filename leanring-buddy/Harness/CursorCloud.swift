//
//  CursorCloud.swift
//  leanring-buddy
//
//  Cursor's Cloud Agents API (public beta, https://cursor.com/docs/cloud-agent/api/endpoints) as a coding target, with
//  the owner's Cursor API key: POST /v1/agents starts an agent on a GitHub repo, autoCreatePR opens the pull request
//  when it finishes, and GET /v1/agents/{id}/runs/{runId} tracks it. It only needs the repo on GitHub, not on this Mac.
//

import Foundation

enum CursorCloud {
    static let harnessID = "cursor-cloud"
    static let baseURL = "https://api.cursor.com"

    private static func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        guard let key = ProviderKeychain.get("cursor") else { throw BotsT3Error.failed("Cursor's cloud agents need your Cursor API key. Add it in Settings › Models & API keys.") }
        guard let url = URL(string: baseURL + path) else { throw BotsT3Error.failed("Bad Cursor address.") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("Basic " + Data("\(key):".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private static func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let failure = ProviderInfo.testFailure(statusCode: status, body: data) { throw BotsT3Error.failed("Cursor: \(failure)") }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// "git@github.com:me/repo.git" → "https://github.com/me/repo".
    static func webURL(fromRemote remote: String) -> String? {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("git@github.com:") { text = "https://github.com/" + text.dropFirst("git@github.com:".count) }
        guard text.contains("github.com") else { return nil }
        if text.hasSuffix(".git") { text.removeLast(4) }
        return text
    }

    /// The body for a new agent. Pure, so it can be tested.
    static func startBody(prompt: String, repoURL: String, startingRef: String) -> [String: Any] {
        ["prompt": ["text": prompt], "repos": [["url": repoURL, "startingRef": startingRef]], "autoCreatePR": true]
    }

    /// (agent id, run id) out of the run's id "cursor:<agent>/<run>".
    private static func ids(of run: T3Run) -> (agent: String, run: String)? {
        let parts = run.id.dropFirst("cursor:".count).split(separator: "/").map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    static func start(prompt: String, title: String, repo: URL?) async throws -> T3Run {
        guard let repo else { throw BotsT3Error.failed("Cursor's cloud agents work on a GitHub repo: pick a folder with a GitHub remote.") }
        let remote = try await BotsT3.shell(BotsT3.git, ["remote", "get-url", "origin"], in: repo)
        guard let repoURL = webURL(fromRemote: remote) else { throw BotsT3Error.failed("\(repo.lastPathComponent) has no GitHub remote, which Cursor's cloud agents need.") }
        let branch = try await BotsT3.shell(BotsT3.git, ["rev-parse", "--abbrev-ref", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = try await send(request("/v1/agents", method: "POST", body: startBody(prompt: prompt, repoURL: repoURL, startingRef: branch)))
        guard let agentID = (reply["agent"] as? [String: Any])?["id"] as? String, let runID = (reply["run"] as? [String: Any])?["id"] as? String else {
            throw BotsT3Error.failed("Cursor didn't return the new agent.")
        }
        var run = T3Run(id: "cursor:\(agentID)/\(runID)", title: title, folder: repo.path, repo: repo.path)
        run.harness = harnessID
        run.model = "Cursor cloud agent"
        run.effort = "default"
        run.link = "https://cursor.com/agents?id=\(agentID)"
        return run
    }

    static func state(of run: T3Run) async -> BotsT3.ThreadState? {
        guard let ids = ids(of: run), let request = try? request("/v1/agents/\(ids.agent)/runs/\(ids.run)"), let reply = try? await send(request) else { return nil }
        let status = (reply["status"] as? String ?? "RUNNING").uppercased()
        let git = reply["git"] as? [String: Any]
        let pullRequest = (git?["branches"] as? [[String: Any]])?.compactMap { $0["prUrl"] as? String }.first
        switch status {
        case "FINISHED":
            return BotsT3.ThreadState(status: "completed", busy: false, waitingForAnswer: false, lastMessage: reply["summary"] as? String, worktree: nil, pullRequest: pullRequest)
        case "ERROR", "CANCELLED", "EXPIRED":
            return BotsT3.ThreadState(status: status == "ERROR" ? "failed" : "cancelled", busy: false, waitingForAnswer: false, lastMessage: reply["error"] as? String, worktree: nil, pullRequest: pullRequest)
        default:
            return BotsT3.ThreadState(status: "running", busy: true, waitingForAnswer: false, lastMessage: nil, worktree: nil, pullRequest: pullRequest)
        }
    }

    static func sendFollowup(_ text: String, to run: T3Run) async throws {
        guard let ids = ids(of: run) else { throw BotsT3Error.failed("That run can't be continued.") }
        _ = try await send(request("/v1/agents/\(ids.agent)/runs", method: "POST", body: ["prompt": ["text": text]]))
    }

    static func stop(_ run: T3Run) async {
        guard let ids = ids(of: run), let request = try? request("/v1/agents/\(ids.agent)/runs/\(ids.run)/cancel", method: "POST") else { return }
        _ = try? await send(request)
    }
}
