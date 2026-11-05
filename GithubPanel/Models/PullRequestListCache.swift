import Foundation

/// A list as last loaded from GitHub, saved to defaults so it shows straight away when the app starts again,
/// before the first refresh comes back.
struct CachedPullRequestList<Rows: Codable & Equatable>: Codable, Equatable {
    /// When GitHub returned the list.
    let savedAt: Date
    let rows: Rows

    /// Nil when nothing is saved or the saved list no longer decodes, such as after an update changed its shape.
    static func decode(_ string: String?) -> CachedPullRequestList? {
        guard let string, !string.isEmpty else { return nil }
        return try? JSONDecoder().decode(CachedPullRequestList.self, from: Data(string.utf8))
    }

    func encode() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
