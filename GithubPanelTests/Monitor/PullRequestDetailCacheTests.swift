import XCTest
@testable import GithubPanel

@MainActor
final class PullRequestDetailCacheTests: XCTestCase {
    func testStoresDetailAndKeepsCommentsAcrossDetailUpdates() {
        let cache = PullRequestDetailCache()
        let comments = PullRequestComments(comments: [], threads: [])

        cache.store(content(number: 1, title: "First"))
        cache.store(comments, for: reference(1))
        cache.store(content(number: 1, title: "Second"))

        XCTAssertEqual(cache.entry(for: reference(1))?.content.detail.title, "Second")
        XCTAssertEqual(cache.entry(for: reference(1))?.comments, comments)
        XCTAssertNil(cache.entry(for: reference(2)))
    }

    func testIgnoresCommentsWithoutDetail() {
        let cache = PullRequestDetailCache()

        cache.store(.empty, for: reference(1))

        XCTAssertNil(cache.entry(for: reference(1)))
        XCTAssertEqual(cache.count, 0)
    }

    func testNeedsRefreshWhenMissingIncompleteOrOlderThanTheList() {
        let cache = PullRequestDetailCache()
        let updatedAt = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(cache.needsRefresh(reference(1), updatedAt: updatedAt))

        cache.store(content(number: 1, updatedAt: updatedAt))
        XCTAssertTrue(cache.needsRefresh(reference(1), updatedAt: updatedAt), "Comments are not cached yet")

        cache.store(.empty, for: reference(1))
        XCTAssertFalse(cache.needsRefresh(reference(1), updatedAt: updatedAt))
        XCTAssertFalse(cache.needsRefresh(reference(1), updatedAt: updatedAt.addingTimeInterval(-1)))
        XCTAssertTrue(cache.needsRefresh(reference(1), updatedAt: updatedAt.addingTimeInterval(1)))

        cache.store(content(number: 2, updatedAt: nil))
        cache.store(.empty, for: reference(2))
        XCTAssertTrue(cache.needsRefresh(reference(2), updatedAt: updatedAt), "No updatedAt to compare")
    }

    func testEvictsTheLeastRecentlyUsedEntry() {
        let cache = PullRequestDetailCache(capacity: 2)
        cache.store(content(number: 1))
        cache.store(content(number: 2))
        _ = cache.entry(for: reference(1))

        cache.store(content(number: 3))

        XCTAssertNotNil(cache.entry(for: reference(1)))
        XCTAssertNil(cache.entry(for: reference(2)))
        XCTAssertNotNil(cache.entry(for: reference(3)))
        XCTAssertEqual(cache.count, 2)
    }

    func testRemoveAllEmptiesTheCache() {
        let cache = PullRequestDetailCache()
        cache.store(content(number: 1))

        cache.removeAll()

        XCTAssertNil(cache.entry(for: reference(1)))
        XCTAssertEqual(cache.count, 0)
    }

    private func reference(_ number: Int) -> PullRequestReference {
        PullRequestReference(repoFullName: "acme/widgets", number: number)
    }

    private func content(number: Int, title: String = "PR", updatedAt: Date? = nil) -> PullRequestDetailContent {
        detailContent(for: reference(number), title: title, updatedAt: updatedAt)
    }
}
