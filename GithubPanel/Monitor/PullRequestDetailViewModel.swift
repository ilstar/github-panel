import Foundation

/// Loads one pull request's detail and changed files for the detail window.
@MainActor
final class PullRequestDetailViewModel: ObservableObject {
    typealias Fetch = (PullRequestReference) async throws -> PullRequestDetailContent
    /// Marks or unmarks one file as viewed: the pull request's node ID, the file path, and the new state.
    typealias SetViewed = (String, String, Bool) async throws -> Void

    let reference: PullRequestReference
    /// The last loaded content. Kept when a reload fails so the window does not go blank.
    @Published private(set) var content: PullRequestDetailContent?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    /// Parsed diff lines for each file, keyed by filename. Parsed once per load.
    @Published private(set) var diffLines: [String: [DiffLine]] = [:]
    /// Filenames the viewer marked as viewed.
    @Published private(set) var viewedFiles: Set<String> = []

    private let fetch: Fetch
    private let syncViewed: SetViewed
    /// Presentations built so far, keyed by filename and whether whitespace changes are hidden.
    private var presentations: [PresentationKey: DiffPresentation] = [:]

    private struct PresentationKey: Hashable {
        let filename: String
        let hideWhitespace: Bool
    }

    init(reference: PullRequestReference,
         fetch: @escaping Fetch,
         setViewed: @escaping SetViewed = { _, _, _ in }) {
        self.reference = reference
        self.fetch = fetch
        self.syncViewed = setViewed
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await fetch(reference)
            diffLines = Dictionary(loaded.files.map { ($0.filename, DiffParser.parse($0.patch ?? "")) },
                                   uniquingKeysWith: { first, _ in first })
            presentations = [:]
            viewedFiles = Set(loaded.files.filter(\.isViewed).map(\.filename))
            content = loaded
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The file's diff with word highlights, built on first use and then reused.
    func presentation(for filename: String, hideWhitespace: Bool) -> DiffPresentation {
        let key = PresentationKey(filename: filename, hideWhitespace: hideWhitespace)
        if let cached = presentations[key] { return cached }
        let presentation = DiffPresentation(lines: diffLines[filename] ?? [], hideWhitespace: hideWhitespace)
        presentations[key] = presentation
        return presentation
    }

    /// Updates the viewed mark right away and syncs it to GitHub, restoring it if GitHub refuses.
    func setViewed(_ viewed: Bool, filename: String) async {
        guard let pullRequestID = content?.detail.nodeID, viewedFiles.contains(filename) != viewed else { return }
        update(filename, viewed: viewed)
        do {
            try await syncViewed(pullRequestID, filename, viewed)
        } catch {
            update(filename, viewed: !viewed)
            errorMessage = error.localizedDescription
        }
    }

    private func update(_ filename: String, viewed: Bool) {
        if viewed {
            viewedFiles.insert(filename)
        } else {
            viewedFiles.remove(filename)
        }
    }
}
