import Foundation

/// Keeps the token in memory only. The test host uses it so launching the app
/// under XCTest never reads the Keychain, which would prompt for a password on
/// every ad-hoc signed build.
final class InMemoryTokenStore: TokenStoring {
    private var token: String?

    init(token: String? = nil) {
        self.token = token
    }

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
