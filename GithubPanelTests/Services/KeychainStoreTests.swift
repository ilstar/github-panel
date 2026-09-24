import XCTest
import Security
@testable import GithubPanel

final class KeychainStoreTests: XCTestCase {
    func testSaveReplacesExistingToken() {
        let security = FakeSecurityClient()
        let store = KeychainStore(security: security)

        store.saveToken("first")
        store.saveToken("second")

        XCTAssertEqual(security.deleteQueries.count, 2)
        XCTAssertEqual(security.addAttributes.count, 2)
        XCTAssertEqual(security.tokenData.flatMap { String(data: $0, encoding: .utf8) }, "second")
    }

    func testLoadTokenSuccessAndHasToken() {
        let security = FakeSecurityClient()
        security.tokenData = Data("secret".utf8)
        let store = KeychainStore(security: security)

        XCTAssertEqual(store.loadToken(), "secret")
        XCTAssertTrue(store.hasToken)
        XCTAssertEqual(security.copyQueries.count, 2)
    }

    func testLoadTokenReturnsNilForMissingOrMalformedData() {
        let missing = KeychainStore(security: FakeSecurityClient(copyStatus: errSecItemNotFound))
        XCTAssertNil(missing.loadToken())

        let malformedSecurity = FakeSecurityClient()
        malformedSecurity.copyResult = NSObject()
        let malformed = KeychainStore(security: malformedSecurity)
        XCTAssertNil(malformed.loadToken())
    }

    func testClearDeletesToken() {
        let security = FakeSecurityClient()
        security.tokenData = Data("secret".utf8)
        let store = KeychainStore(security: security)

        store.clearToken()

        XCTAssertNil(security.tokenData)
        XCTAssertEqual(security.deleteQueries.count, 1)
    }

    func testSaveAndClearIgnoreSecurityReturnValues() {
        let security = FakeSecurityClient(deleteStatus: errSecAuthFailed, addStatus: errSecAuthFailed)
        let store = KeychainStore(security: security)

        store.saveToken("secret")
        store.clearToken()

        XCTAssertEqual(security.deleteQueries.count, 2)
        XCTAssertEqual(security.addAttributes.count, 1)
    }
}

private final class FakeSecurityClient: SecurityClient {
    var deleteStatus: OSStatus
    var addStatus: OSStatus
    var copyStatus: OSStatus
    var tokenData: Data?
    var copyResult: AnyObject?

    private(set) var deleteQueries: [[String: Any]] = []
    private(set) var addAttributes: [[String: Any]] = []
    private(set) var copyQueries: [[String: Any]] = []

    init(deleteStatus: OSStatus = errSecSuccess,
         addStatus: OSStatus = errSecSuccess,
         copyStatus: OSStatus = errSecSuccess) {
        self.deleteStatus = deleteStatus
        self.addStatus = addStatus
        self.copyStatus = copyStatus
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        deleteQueries.append(query)
        tokenData = nil
        return deleteStatus
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        addAttributes.append(attributes)
        tokenData = attributes[kSecValueData as String] as? Data
        return addStatus
    }

    func copyMatching(_ query: [String: Any], result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus {
        copyQueries.append(query)
        if let copyResult {
            result?.pointee = copyResult
        } else if let tokenData {
            result?.pointee = tokenData as AnyObject
        }
        return copyStatus
    }
}
