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
    /// Parsed diff lines for each file, keyed by filename. Parsed once per load.
    @Published private(set) var diffLines: [String: [DiffLine]] = [:]

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
            let loaded = try await fetch(reference)
            diffLines = Dictionary(loaded.files.map { ($0.filename, DiffParser.parse($0.patch ?? "")) },
                                   uniquingKeysWith: { first, _ in first })
            content = loaded
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
