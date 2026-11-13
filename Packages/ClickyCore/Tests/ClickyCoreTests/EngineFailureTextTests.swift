import Testing
@testable import ClickyCore

struct EngineFailureTextTests {
    /// What Grok printed on 13 Nov 2026 with its usage balance used up (session ids shortened).
    static let usedUp = #"""
    {"type":"system","subtype":"init","apiKeySource":"oauth","model":"grok-4.7-build-fast","session_id":"01a1"}
    {"type":"result","subtype":"error_during_execution","is_error":true,"duration_ms":1047,"total_cost_usd":0.0,"errors":["Internal error: {\n  \"message\": \"API error (status 402 Payment Required): Grok Build usage balance exhausted\",\n  \"http_status\": 402\n}"],"session_id":"01a1","uuid":"2f46"}
    """#

    @Test func grokSaysItsOwnMessage() {
        #expect(EngineFailureText.grok(Self.usedUp) == "API error (status 402 Payment Required): Grok Build usage balance exhausted")
    }

    @Test func grokPlainErrorIsKept() {
        let output = #"{"type":"result","is_error":true,"errors":["Model not found: grok-9"]}"#
        #expect(EngineFailureText.grok(output) == "Model not found: grok-9")
    }

    @Test func noErrorEventIsNil() {
        #expect(EngineFailureText.grok(#"{"type":"result","is_error":false,"result":"pong"}"#) == nil)
        #expect(EngineFailureText.grok("not json at all") == nil)
    }
}
