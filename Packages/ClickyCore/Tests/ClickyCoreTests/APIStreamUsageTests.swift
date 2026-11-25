import XCTest
@testable import ClickyCore

final class APIStreamUsageTests: XCTestCase {
    func testAnthropicInputFromTheStartAndOutputFromTheLastDelta() {
        var meter = APIStreamUsage()
        meter.take(line: "event: message_start")
        meter.take(line: #"data: {"type":"message_start","message":{"id":"m","usage":{"input_tokens":1200,"cache_creation_input_tokens":300,"cache_read_input_tokens":4000,"output_tokens":1}}}"#)
        meter.take(line: #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"the usage is fine"}}"#)
        meter.take(line: #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":15}}"#)
        meter.take(line: #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":42}}"#)
        XCTAssertEqual(meter.usage, BotTurnUsage(inputTokens: 1200, outputTokens: 42, cacheReadTokens: 4000, cacheWriteTokens: 300))
    }

    func testOpenAIStyleSplitsCachedInputOut() {
        var meter = APIStreamUsage()
        meter.take(line: #"data: {"choices":[{"delta":{"content":"hi"}}]}"#)
        meter.take(line: #"data: {"choices":[],"usage":{"prompt_tokens":900,"completion_tokens":80,"prompt_tokens_details":{"cached_tokens":600}}}"#)
        meter.take(line: "data: [DONE]")
        XCTAssertEqual(meter.usage, BotTurnUsage(inputTokens: 300, outputTokens: 80, cacheReadTokens: 600))
    }

    func testGroqAndANullUsageChunk() {
        var meter = APIStreamUsage()
        meter.take(line: #"data: {"choices":[{"delta":{"content":"x"}}],"usage":null}"#)
        XCTAssertTrue(meter.usage.isEmpty)
        meter.take(line: #"data: {"choices":[],"x_groq":{"usage":{"prompt_tokens":50,"completion_tokens":7}}}"#)
        XCTAssertEqual(meter.usage, BotTurnUsage(inputTokens: 50, outputTokens: 7))
    }

    func testOnlyServersKnownToTakeTheOptionAreAskedForIt() {
        XCTAssertTrue(APIStreamUsage.asksForUsage(providerID: "openai"))
        XCTAssertFalse(APIStreamUsage.asksForUsage(providerID: "lmstudio"))
        XCTAssertFalse(APIStreamUsage.asksForUsage(providerID: "anthropic"))
    }
}
