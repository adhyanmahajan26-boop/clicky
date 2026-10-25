import XCTest
@testable import EvalFixture

final class GreeterTests: XCTestCase {
    func testGreet() { XCTAssertEqual(Greeter.greet("a"), "Hello, a") }
}
