import XCTest
@testable import GithubPanel

final class InMemoryTokenStoreTests: XCTestCase {
    func testStartsEmptyByDefault() {
        let store = InMemoryTokenStore()

        XCTAssertNil(store.loadToken())
        XCTAssertFalse(store.hasToken)
    }

    func testSaveLoadAndClearToken() {
        let store = InMemoryTokenStore(token: "first")
        XCTAssertEqual(store.loadToken(), "first")

        store.saveToken("second")
        XCTAssertEqual(store.loadToken(), "second")
        XCTAssertTrue(store.hasToken)

        store.clearToken()
        XCTAssertNil(store.loadToken())
        XCTAssertFalse(store.hasToken)
    }
}
