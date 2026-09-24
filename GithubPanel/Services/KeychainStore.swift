import Foundation
import Security

protocol TokenStoring {
    var hasToken: Bool { get }
    func saveToken(_ token: String)
    func loadToken() -> String?
    func clearToken()
}

protocol SecurityClient {
    func delete(_ query: [String: Any]) -> OSStatus
    func add(_ attributes: [String: Any]) -> OSStatus
    func copyMatching(_ query: [String: Any], result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus
}

struct SystemSecurityClient: SecurityClient {
    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func copyMatching(_ query: [String: Any], result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus {
        SecItemCopyMatching(query as CFDictionary, result)
    }
}

final class KeychainStore: TokenStoring {
    private let service = "com.githubpanel.token"
    private let account = "github-token"
    private let security: SecurityClient

    init(security: SecurityClient = SystemSecurityClient()) {
        self.security = security
    }

    var hasToken: Bool {
        loadToken() != nil
    }

    func saveToken(_ token: String) {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        _ = security.delete(query)
        let attributes: [String: Any] = query.merging([
            kSecValueData as String: data
        ]) { $1 }
        _ = security.add(attributes)
    }

    func loadToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = security.copyMatching(query, result: &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        return token
    }

    func clearToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        _ = security.delete(query)
    }
}
