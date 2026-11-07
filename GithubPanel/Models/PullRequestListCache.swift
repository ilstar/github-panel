import Foundation

/// A list as last loaded from GitHub, saved to the local store so it shows straight away when the app starts again,
/// before the first refresh comes back.
struct CachedPullRequestList<Rows: Codable & Equatable>: Equatable {
    /// When GitHub returned the list.
    let savedAt: Date
    let rows: Rows
}
