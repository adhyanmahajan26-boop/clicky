import XCTest
@testable import ClickyCore

final class TheoGatewayHTTPTests: XCTestCase {
    private func req(_ raw: String) -> TheoGatewayHTTP.Request? {
        if case .request(let r) = TheoGatewayHTTP.parse(Data(raw.utf8)) { return r }
        return nil
    }

    func testParsesRequestWithBodyAndQuery() {
        let r = req("POST /v1/bots/pip/messages?x=1&y=a%20b HTTP/1.1\r\nHost: 127.0.0.1:47380\r\nContent-Length: 13\r\n\r\n{\"text\":\"hi\"}")
        XCTAssertEqual(r?.method, "POST")
        XCTAssertEqual(r?.path, "/v1/bots/pip/messages")
        XCTAssertEqual(r?.query["y"], "a b")
        XCTAssertEqual(r?.headers["host"], "127.0.0.1:47380")
        XCTAssertEqual(r?.body, Data("{\"text\":\"hi\"}".utf8))
    }

    func testIncompleteAndOversized() {
        XCTAssertEqual(TheoGatewayHTTP.parse(Data("GET /v1/health HTTP/1.1\r\nHost: x".utf8)), .incomplete)
        XCTAssertEqual(TheoGatewayHTTP.parse(Data("POST /v1/x HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc".utf8)), .incomplete)
        XCTAssertEqual(TheoGatewayHTTP.parse(Data("POST /v1/x HTTP/1.1\r\nContent-Length: 999999\r\n\r\n".utf8)), .bad(status: 413, reason: "Body too large"))
        XCTAssertEqual(TheoGatewayHTTP.parse(Data("POST /v1/x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)), .bad(status: 411, reason: "Send a Content-Length"))
        XCTAssertEqual(TheoGatewayHTTP.parse(Data(String(repeating: "a", count: 20_000).utf8)), .bad(status: 431, reason: "Headers too large"))
        XCTAssertEqual(TheoGatewayHTTP.parse(Data("NONSENSE\r\n\r\n".utf8)), .bad(status: 400, reason: "Bad request line"))
    }

    func testChecksHostOriginAndToken() {
        let good = req("GET /v1/health HTTP/1.1\r\nHost: 127.0.0.1:47380\r\nAuthorization: Bearer secret\r\n\r\n")!
        XCTAssertNil(TheoGatewayHTTP.check(good, port: 47380, token: "secret"))
        XCTAssertEqual(TheoGatewayHTTP.check(good, port: 47380, token: "other"), .unauthorized)
        XCTAssertEqual(TheoGatewayHTTP.check(good, port: 47380, token: ""), .unauthorized)
        var rebound = good; rebound.headers["host"] = "evil.example:47380"
        XCTAssertNotNil(TheoGatewayHTTP.check(rebound, port: 47380, token: "secret"))
        var browser = good; browser.headers["origin"] = "https://evil.example"
        XCTAssertNotNil(TheoGatewayHTTP.check(browser, port: 47380, token: "secret"))
        var fetch = good; fetch.headers["sec-fetch-site"] = "cross-site"
        XCTAssertNotNil(TheoGatewayHTTP.check(fetch, port: 47380, token: "secret"))
        var noToken = good; noToken.headers["authorization"] = nil
        XCTAssertEqual(TheoGatewayHTTP.check(noToken, port: 47380, token: "secret"), .unauthorized)
        XCTAssertTrue(TheoGatewayHTTP.constantTimeEqual("abc", "abc"))
        XCTAssertFalse(TheoGatewayHTTP.constantTimeEqual("abc", "abcd"))
    }

    func testRoutes() {
        XCTAssertEqual(TheoGatewayHTTP.route(method: "GET", path: "/v1/health"), .health)
        XCTAssertEqual(TheoGatewayHTTP.route(method: "POST", path: "/v1/bots/pip/messages"), .message(botID: "pip"))
        XCTAssertEqual(TheoGatewayHTTP.route(method: "GET", path: "/v1/bots/pip/messages"), .methodNotAllowed)
        XCTAssertEqual(TheoGatewayHTTP.route(method: "POST", path: "/v1/routines/r-1/run"), .runRoutine(id: "r-1"))
        XCTAssertEqual(TheoGatewayHTTP.route(method: "POST", path: "/v1/bots/../messages"), .notFound)
        XCTAssertEqual(TheoGatewayHTTP.route(method: "GET", path: "/v2/health"), .notFound)
    }

    func testMessageBodyLimitsAndSource() {
        guard case .success(let body) = TheoGatewayHTTP.messageBody(Data(#"{"text":" build failed ","source":"ci<script>","wait":true,"timeout":9999}"#.utf8)) else { return XCTFail() }
        XCTAssertEqual(body, .init(text: "build failed", source: "ciscript", wait: true, timeout: 600))
        if case .success = TheoGatewayHTTP.messageBody(Data(#"{"text":""}"#.utf8)) { XCTFail() }
        if case .success = TheoGatewayHTTP.messageBody(Data("[]".utf8)) { XCTFail() }
        let long = String(repeating: "x", count: TheoGatewayHTTP.maxTextCharacters + 1)
        if case .success = TheoGatewayHTTP.messageBody(try! JSONSerialization.data(withJSONObject: ["text": long])) { XCTFail() }
    }

    func testOutsideNoteSaysItIsNotTheOwner() {
        let note = TheoGatewayHTTP.outsideNote(source: "ci", owner: "Addy")
        XCTAssertTrue(note.contains("not from Addy typing"))
        XCTAssertTrue(note.contains("can't start coding runs or routines"))
    }

    func testRateLimiter() {
        var limiter = TheoGatewayHTTP.RateLimiter(limit: 2, window: 60)
        XCTAssertTrue(limiter.allow(now: 0))
        XCTAssertTrue(limiter.allow(now: 1))
        XCTAssertFalse(limiter.allow(now: 2))
        XCTAssertTrue(limiter.allow(now: 61))
    }

    func testResponseIsWellFormed() {
        let text = String(decoding: TheoGatewayHTTP.response(status: 401, json: ["error": "no"]), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
        XCTAssertTrue(text.contains("WWW-Authenticate: Bearer"))
        XCTAssertTrue(text.hasSuffix("{\"error\":\"no\"}"))
    }
}
