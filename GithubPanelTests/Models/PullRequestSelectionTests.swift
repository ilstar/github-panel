import XCTest
@testable import GithubPanel

final class PullRequestSelectionTests: XCTestCase {
    private let history = PullRequestHistoryRow(id: "acme/widgets#90",
                                                title: "Old",
                                                number: 90,
                                                repoFullName: "acme/widgets",
                                                htmlURL: URL(string: "https://github.com/acme/widgets/pull/90")!,
                                                updatedAt: Date(timeIntervalSince1970: 0),
                                                closedAt: nil,
                                                mergedAt: nil)

    func testUsesTheVisibleTabSelection() {
        let open = [row(number: 1, status: .success), row(number: 2, status: .pending)]

        XCTAssertEqual(reference(tab: .open, open: open, openID: "acme/widgets#2"),
                       PullRequestReference(repoFullName: "acme/widgets", number: 2))
        XCTAssertEqual(reference(tab: .history, open: open, openID: "acme/widgets#2"),
                       PullRequestReference(repoFullName: "acme/widgets", number: 90))
    }

    func testNoSelectionOrMissingRowShowsNothing() {
        let open = [row(number: 1, status: .success)]

        XCTAssertNil(reference(tab: .open, open: open, openID: nil))
        XCTAssertNil(reference(tab: .open, open: open, openID: "acme/widgets#3"))
        XCTAssertNil(PullRequestSelection.reference(tab: .history,
                                                    openRows: open,
                                                    historyRows: [history],
                                                    selectedOpenID: nil,
                                                    selectedHistoryID: nil))
    }

    private func reference(tab: PullRequestTab, open: [PullRequestRow], openID: String?) -> PullRequestReference? {
        PullRequestSelection.reference(tab: tab,
                                       openRows: open,
                                       historyRows: [history],
                                       selectedOpenID: openID,
                                       selectedHistoryID: history.id)
    }
}
