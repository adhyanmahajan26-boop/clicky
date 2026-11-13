//
//  EngineSetupRules.swift
//  ClickyCore
//
//  Small rules about the coding agents Theo runs, kept here so they can be tested: telling a signed-out Gemini apart from
//  any other failure, the settings that keep Gemini from updating itself while Theo runs its sign-in, and the model a
//  new bot on each engine starts with.
//

import Foundation

public enum EngineSetupRules {
    /// Gemini CLI exits 41 when it has no sign-in (checked 13 Nov 2026, version 0.68.0):
    /// `{"error": {"type": "Error", "message": "Please set an Auth method in your …/settings.json …", "code": 41}}`.
    public static func geminiNeedsSignIn(exitStatus: Int32, output: String) -> Bool {
        if exitStatus == 41 { return true }
        let lower = output.lowercased()
        return lower.contains("\"code\": 41") || lower.contains("\"code\":41") || lower.contains("please set an auth method")
            || lower.contains("fatalauthenticationerror")
    }

    /// The plain words for that, which the sign-in card recognises.
    public static let geminiSignedOut = "Gemini CLI isn't signed in. Sign in, then try again."

    /// Workspace settings for the folder Theo runs Gemini's sign-in in. Gemini only checks for updates in its interactive
    /// screen, which is exactly what a sign-in is, and it reads the switch from a settings file; Theo keeps this file in a
    /// folder of its own (with GEMINI_CLI_TRUST_WORKSPACE so the folder counts), so the owner's ~/.gemini is never touched
    /// and the installed version is never changed.
    public static let geminiQuietSettings: [String: Any] = [
        "general": ["enableAutoUpdate": false, "enableAutoUpdateNotification": false],
    ]

    public static func geminiQuietSettingsData() -> Data {
        (try? JSONSerialization.data(withJSONObject: geminiQuietSettings, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    }

    /// Environment for Gemini's sign-in: trust only Theo's own sign-in folder, for this one process.
    public static let geminiSignInEnvironment = ["GEMINI_CLI_TRUST_WORKSPACE": "true"]

    /// The model a new bot on an engine starts with, before its settings change it (the New bot sheet's list).
    public static let starterModels: [String: String] = [
        "claude": "claude-sonnet-5-5", "codex": "gpt-5.6-luna", "cursor": "auto",
        "opencode": "opencode/deepseek-v4.1-flash-free", "grok": "grok-4.6", "gemini": "gemini-3-pro",
    ]

    /// The owner's default for that engine first, then the engine's own first model, then the starter. Never another
    /// engine's model.
    public static func starterModel(for engine: String, ownerDefault: String?, firstKnown: String?) -> String {
        if let ownerDefault, !ownerDefault.isEmpty { return ownerDefault }
        if let firstKnown, !firstKnown.isEmpty { return firstKnown }
        return starterModels[engine] ?? ""
    }
}
