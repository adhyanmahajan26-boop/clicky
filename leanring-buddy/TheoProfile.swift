//
//  TheoProfile.swift
//  leanring-buddy
//
//  `--profile test`: the same app with its own everything, so testing never touches the owner's bots, chats or
//  settings. It re-launches itself with a home folder of its own (~/Library/Application Support/Theo-Test/home,
//  which holds symlinks to the coding CLIs' sign-ins), keeps its preferences in a separate domain and its keys
//  under a separate Keychain service, stays out of the Dock and menu bar, never takes focus, and doesn't start
//  the mic, the spark overlay, the pill or the global key tap.
//

import AppKit
import Foundation
import ObjectiveC

enum TheoProfile {
    /// The name after `--profile`: "test", or "test-<anything>" for another separate test instance beside it.
    static let name: String? = {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--profile"), arguments.indices.contains(flag + 1) else { return nil }
        return arguments[flag + 1]
    }()

    /// Launched with `--profile test` (or test-…).
    static let isTest: Bool = name == "test" || name?.hasPrefix("test-") == true

    /// "Theo-Test", "Theo-Test-clicks", …
    private static var folderName: String { "Theo-Test" + (name.map { $0.dropFirst("test".count) } ?? "") }

    /// Keychain service suffix, so a test key never overwrites a real one.
    static var keychainSuffix: String { isTest ? "." + (name ?? "test") : "" }

    /// The owner's real home, whatever CFFIXED_USER_HOME says.
    static var realHome: String {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return NSHomeDirectory() }
        return String(cString: directory)
    }

    static var testHome: URL {
        URL(fileURLWithPath: realHome).appendingPathComponent("Library/Application Support/\(folderName)/home", isDirectory: true)
    }

    private static let homeVariable = "CFFIXED_USER_HOME"
    private static var testDefaultsDomain: String { "com.personal.clicky." + (name ?? "test") }

    /// What the test home borrows from the real one: where the CLIs live and what they're signed in with.
    private static let sharedHomeItems = [".claude", ".claude.json", ".codex", ".config", ".cursor", ".gemini", ".grok", ".local",
                                          ".npm-global", ".bun", ".opencode", ".gitconfig", ".ssh", "Library/pnpm",
                                          ".t3/bin", ".t3-claudia/bin"]

    /// The first thing the app does. In the test profile it restarts itself with the test home (the path has to
    /// be in place before anything asks where home is), then swaps the defaults and stops focus changes.
    static func prepareAtLaunch() {
        guard isTest else { return }
        if getenv(homeVariable) == nil {
            makeTestHome()
            setenv(homeVariable, testHome.path, 1)
            guard let executable = Bundle.main.executablePath else { return }
            var arguments: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) }
            arguments.append(nil)
            execv(executable, &arguments)
            return
        }
        useSeparateDefaults()
        usePrivatePasteboard()
        stopTakingFocus()
        keepRealHomeForChildProcesses()
    }

    /// Tests of Copy and ⌘V use a pasteboard of their own, never the owner's clipboard.
    private static func usePrivatePasteboard() {
        let board = NSPasteboard(name: NSPasteboard.Name("com.personal.clicky.\(name ?? "test").pasteboard"))
        guard let method = class_getClassMethod(NSPasteboard.self, NSSelectorFromString("generalPasteboard")) else { return }
        let block: @convention(block) (AnyObject) -> NSPasteboard = { _ in board }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    private static func makeTestHome() {
        let manager = FileManager.default
        try? manager.createDirectory(at: testHome.appendingPathComponent("Library/Application Support"), withIntermediateDirectories: true)
        for item in sharedHomeItems {
            let real = URL(fileURLWithPath: realHome).appendingPathComponent(item)
            guard manager.fileExists(atPath: real.path) else { continue }
            let link = testHome.appendingPathComponent(item)
            try? manager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? manager.createSymbolicLink(at: link, withDestinationURL: real)
        }
    }

    /// `UserDefaults.standard` (the app's and SwiftUI's @AppStorage) becomes a separate domain.
    private static func useSeparateDefaults() {
        guard let domain = UserDefaults(suiteName: testDefaultsDomain),
              let method = class_getClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults")) else { return }
        let block: @convention(block) (AnyObject) -> UserDefaults = { _ in domain }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    /// Nothing in the test profile may pull focus from the owner.
    private static func stopTakingFocus() {
        let doNothing: @convention(block) (AnyObject) -> Void = { _ in }
        let doNothingWithFlag: @convention(block) (AnyObject, Bool) -> Void = { _, _ in }
        if let method = class_getInstanceMethod(NSApplication.self, NSSelectorFromString("activate")) {
            method_setImplementation(method, imp_implementationWithBlock(doNothing))
        }
        if let method = class_getInstanceMethod(NSApplication.self, NSSelectorFromString("activateIgnoringOtherApps:")) {
            method_setImplementation(method, imp_implementationWithBlock(doNothingWithFlag))
        }
        // AppKit can still activate on its own (a click on a terminal view or an alert did), so hand focus straight back.
        func isOwner(_ application: NSRunningApplication?) -> Bool { application?.bundleIdentifier != Bundle.main.bundleIdentifier }
        var ownersApp = isOwner(NSWorkspace.shared.frontmostApplication) ? NSWorkspace.shared.frontmostApplication : nil
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if isOwner(application) { ownersApp = application }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            ownersApp?.activate()
        }
    }

    /// The CLIs Theo starts must see the real home: `security`, which Claude Code uses for its sign-in, would
    /// otherwise look for the Keychain in the test home. Process (NSTask) is the one place they all pass through.
    private static func keepRealHomeForChildProcesses() {
        guard let taskClass = NSClassFromString("NSConcreteTask"),
              let method = class_getInstanceMethod(taskClass, NSSelectorFromString("launchAndReturnError:")) else { return }
        typealias Launch = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> Bool
        let original = unsafeBitCast(method_getImplementation(method), to: Launch.self)
        let selector = NSSelectorFromString("launchAndReturnError:")
        let replacement: @convention(block) (AnyObject, UnsafeMutablePointer<NSError?>?) -> Bool = { task, error in
            if let process = task as? Process {
                var environment = process.environment ?? ProcessInfo.processInfo.environment
                environment[homeVariable] = nil
                // A test bot's Theo tools still talk to this test instance, not the owner's Theo.
                environment["THEO_CONTROL_HOME"] = testHome.path
                process.environment = environment
            }
            return original(task, selector, error)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }
}
