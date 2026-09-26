import Foundation

/// Loads one pull request's detail and changed files for the detail window.
@MainActor
final class PullRequestDetailViewModel: ObservableObject {
    typealias Fetch = (PullRequestReference) async throws -> PullRequestDetailContent

    let reference: PullRequestReference
    /// The last loaded content. Kept when a reload fails so the window does not go blank.
    @Published private(set) var content: PullRequestDetailContent?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let fetch: Fetch

    init(reference: PullRequestReference, fetch: @escaping Fetch) {
        self.reference = reference
        self.fetch = fetch
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            content = try await fetch(reference)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
