import XCTest
@testable import LumaChat

final class EndpointNormalizerTests: XCTestCase {
    func testCanonicalizesEquivalentEndpoints() {
        XCTAssertEqual(
            EndpointNormalizer.normalized(" HTTPS://Example.COM:443/v1/?ignored=yes#fragment "),
            "https://example.com/v1"
        )
        XCTAssertTrue(EndpointNormalizer.haveSameIdentity("localhost:11434/", "http://LOCALHOST:11434"))
        XCTAssertEqual(EndpointNormalizer.normalized("http://example.com:80"), "http://example.com")
    }

    func testRejectsUnsupportedOrIncompleteEndpoints() {
        XCTAssertFalse(EndpointNormalizer.isValid(""))
        XCTAssertFalse(EndpointNormalizer.isValid("file:///tmp/model"))
        XCTAssertFalse(EndpointNormalizer.isValid("https://"))
    }
}
