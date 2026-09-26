import XCTest
@testable import GithubPanel

final class PullRequestReferenceTests: XCTestCase {
    func testRowReferencesMatchRowIDs() {
        let history = PullRequestHistoryRow(id: "acme/widgets#12",
                                            title: "Old",
                                            number: 12,
                                            repoFullName: "acme/widgets",
                                            htmlURL: URL(string: "https://github.com/acme/widgets/pull/12")!,
                                            updatedAt: Date(timeIntervalSince1970: 0),
                                            closedAt: nil,
                                            mergedAt: nil)

        XCTAssertEqual(history.reference, PullRequestReference(repoFullName: "acme/widgets", number: 12))
        XCTAssertEqual(history.reference.id, history.id)
    }

    func testReferenceRoundTripsThroughCodableForWindowRestoration() throws {
        let reference = PullRequestReference(repoFullName: "acme/widgets", number: 7)

        let data = try JSONEncoder().encode(reference)

        XCTAssertEqual(try JSONDecoder().decode(PullRequestReference.self, from: data), reference)
    }
}
