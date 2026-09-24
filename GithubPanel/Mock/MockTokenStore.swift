import Foundation

#if DEBUG
final class MockTokenStore: TokenStoring {
    private var token: String? = "mock-github-token"

    var hasToken: Bool {
        token != nil
    }

    func saveToken(_ token: String) {
        self.token = token
    }

    func loadToken() -> String? {
        token
    }

    func clearToken() {
        token = nil
    }
}
#endif
