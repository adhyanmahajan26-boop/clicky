import Foundation
import Testing
@testable import ClickyCore

struct BrainProviderTests {
    @Test func settingsSplitIntoProviderAndModel() {
        #expect(BrainModel(setting: "claude-sonnet-5-5") == BrainModel(provider: .claude, modelIdentifier: "claude-sonnet-5-5"))
        #expect(BrainModel(setting: "codex:gpt-6-luna") == BrainModel(provider: .codex, modelIdentifier: "gpt-6-luna"))
        #expect(BrainModel(setting: "opencode:lmstudio/qwen/qwen3.8-27b").modelIdentifier == "lmstudio/qwen/qwen3.8-27b")
        #expect(BrainModel(setting: "cursor:gpt-6").setting == "cursor:gpt-6")
        #expect(BrainModel(setting: "opencode:opencode/big-pickle").sendsScreenshotsToThirdParty)
        #expect(!BrainModel(setting: "opencode:lmstudio/qwen/qwen3.8-27b").sendsScreenshotsToThirdParty)
    }

    @Test func codexArgumentsPutImagesBeforeTheStdinPrompt() {
        let (arguments, stdinPrompt) = BrainCLI.arguments(for: BrainModel(setting: "codex:gpt-6-luna"), imagePaths: ["/t/screen1.jpg", "/t/screen2.jpg"],
                                                          workingDirectory: "/w", prompt: "hi")
        #expect(arguments.last == "-")
        #expect(stdinPrompt == "hi")
        #expect(arguments.contains("--json") && arguments.contains("read-only"))
        #expect(arguments.filter { $0 == "--image" }.count == 2)
    }

    @Test func parsesEachCLIsOutput() {
        func events(_ json: String, _ provider: BrainProvider) -> [BrainCLI.OutputEvent] { BrainCLI.parseLine(Data(json.utf8), provider: provider) }
        #expect(events(#"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"tokyo."}}"#, .codex) == [.text("tokyo.")])
        #expect(events(#"{"type":"turn.failed","error":{"message":"{\"type\":\"error\",\"status\":400,\"error\":{\"message\":\"model not supported\"}}"}}"#, .codex)
                == [.error("model not supported")])
        #expect(events(#"{"type":"text","part":{"type":"text","text":"ready"}}"#, .opencode) == [.text("ready")])
        #expect(events(#"{"type":"result","is_error":false,"result":"done"}"#, .cursor) == [.finalText("done")])
        #expect(BrainModelCatalog.codexModels(cacheJSON: Data(#"{"models":[{"slug":"gpt-6-luna","visibility":"list"},{"slug":"gpt-reserve","visibility":"hide"}]}"#.utf8)) == ["gpt-6-luna"])
        #expect(BrainModelCatalog.openCodeModels(listing: "opencode/big-pickle\nlmstudio/qwen/qwen3.8-27b\n\nsome note here") == ["opencode/big-pickle", "lmstudio/qwen/qwen3.8-27b"])
    }
}

struct BrainBlockRepairTests {
    @Test func fixesSlippedClosingTags() {
        #expect(BrainCLI.repairBlockTags(#"ok <actions>{"steps":[]}</actions}"#) == #"ok <actions>{"steps":[]}</actions>"#)
        #expect(BrainCLI.repairBlockTags("<actions>{}</actions") == "<actions>{}</actions>")
        #expect(BrainCLI.repairBlockTags("<actions>{}</actions> then") == "<actions>{}</actions> then")
        #expect(BrainCLI.repairBlockTags("<whiteboard>\n{}\n</whiteboard]\n") == "<whiteboard>\n{}\n</whiteboard>\n")
    }
}
