import XCTest
import AppKit
import SwiftUI
@testable import GithubPanel

final class PullRequestDetailHeaderTests: XCTestCase {
    func testEditTitleButtonSitsByTheTitleOfYourOwnPullRequest() async throws {
        let detail = try await mockDetail(own: true)
        XCTAssertTrue(detail.canEdit)
        XCTAssertTrue(PullRequestDetailHeader.showsEditTitleButton(for: detail))
    }

    func testNoEditTitleButtonWhenYouCannotEditThePullRequest() async throws {
        let detail = try await mockDetail(own: false)
        XCTAssertFalse(detail.canEdit)
        XCTAssertFalse(PullRequestDetailHeader.showsEditTitleButton(for: detail))
    }

    func testPullRequestNumberLinksToGitHub() async throws {
        let detail = try await mockDetail(own: true)
        XCTAssertEqual(PullRequestDetailHeader.numberLabel(for: detail), "#109")
        XCTAssertEqual(detail.htmlURL.lastPathComponent, "109")
    }

    func testHeaderLinesUpWithTheConversationButSpansTheFilesTab() {
        XCTAssertEqual(PullRequestDetailView.headerMaxWidth(for: .conversation), PullRequestConversationView.contentMaxWidth)
        XCTAssertEqual(PullRequestDetailView.headerMaxWidth(for: .files), .infinity)
    }

    @MainActor
    func testToolbarButtonsAreRound() throws {
        let toolbarButton = Button("Update branch") {}
            .buttonStyle(DetailToolbarButtonStyle(isProminent: true))
        try assertRound(toolbarButton, "toolbar button")
        let merge = MergeActionButton(action: PullRequestMergeAction(state: .merge, mergeMethod: .squash) {})
        try assertRound(merge, "merge button")
        let tabs = PullRequestDetailTabBar(selection: .constant(.conversation),
                                           tabs: [.init(value: .conversation, title: "Conversation")])
        try assertRound(tabs, "selected tab", height: 28)
    }

    /// A capsule leaves its corners empty well past where a small corner radius would fill them,
    /// and fills the middle of its left edge.
    @MainActor
    private func assertRound<V: View>(_ view: V, _ name: String, height: Int = 30) throws {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
        renderer.scale = 1
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage, name))
        XCTAssertEqual(bitmap.pixelsHigh, height, name)
        let corner = try XCTUnwrap(bitmap.colorAt(x: 3, y: 3), name)
        let leftMiddle = try XCTUnwrap(bitmap.colorAt(x: 1, y: height / 2), name)
        // The selected tab's fill is faint, so this only asks that the edge is painted and the corner is not.
        XCTAssertLessThan(corner.alphaComponent, 0.01, name)
        XCTAssertGreaterThan(leftMiddle.alphaComponent, 0.03, name)
    }

    func testFilesTabHeaderSharesTheFileTreesLeftEdge() {
        XCTAssertEqual(PullRequestDetailView.headerInset(for: .files), PullRequestFilesView.leadingInset)
        XCTAssertEqual(PullRequestDetailView.headerInset(for: .conversation), 32)
    }

    private func mockDetail(own: Bool) async throws -> PullRequestDetail {
        let api = MockGitHubAPI()
        let reference: PullRequestReference
        if own {
            reference = PullRequestReference(repoFullName: "mock/github-panel", number: 109)
        } else {
            let requests = try await api.fetchReviewRequests(token: "token")
            let row = try XCTUnwrap(requests.rows.first)
            reference = PullRequestReference(repoFullName: row.repoFullName, number: row.number)
        }
        return try await api.fetchPullRequestDetail(token: "token", reference: reference).detail
    }
}
