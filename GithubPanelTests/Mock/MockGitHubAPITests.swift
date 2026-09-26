import XCTest
@testable import GithubPanel

@MainActor
final class MockGitHubAPITests: XCTestCase {
    func testEmptyMockGitHubAPIHasNoPullRequests() async throws {
        let api = MockGitHubAPI(isEmpty: true)

        let result = try await api.fetchOpenPRs(token: "token")

        XCTAssertTrue(result.rows.isEmpty)
    }

    func testMockReviewRequestsCoverBothGroups() async throws {
        let requests = try await MockGitHubAPI().fetchReviewRequests(token: "token")
        let empty = try await MockGitHubAPI(isEmpty: true).fetchReviewRequests(token: "token")

        XCTAssertFalse(requests.fromMe.isEmpty)
        XCTAssertFalse(requests.fromMyTeams.isEmpty)
        XCTAssertEqual(empty, .empty)
    }

    func testMockDetailUsesTheListTitleAndParsableDiffs() async throws {
        let api = MockGitHubAPI()
        let reference = PullRequestReference(repoFullName: "mock/github-panel", number: 109)

        let content = try await api.fetchPullRequestDetail(token: "token", reference: reference)

        XCTAssertEqual(content.detail.title, "Draft: success but not mergeable")
        XCTAssertEqual(content.detail.state, .draft)
        XCTAssertEqual(content.detail.changedFiles, content.files.count)
        XCTAssertTrue(content.files.contains { $0.patch == nil })
        for file in content.files {
            guard let patch = file.patch else { continue }
            let lines = DiffParser.parse(patch)
            XCTAssertEqual(lines.filter { $0.kind == .addition }.count, file.additions, file.filename)
            XCTAssertEqual(lines.filter { $0.kind == .deletion }.count, file.deletions, file.filename)
        }
    }

    func testMockEditsOwnPullRequestsOnly() async throws {
        let api = MockGitHubAPI()
        let own = PullRequestReference(repoFullName: "mock/github-panel", number: 109)
        let requests = try await api.fetchReviewRequests(token: "token")
        let reviewRow = try XCTUnwrap(requests.rows.first)
        let review = PullRequestReference(repoFullName: reviewRow.repoFullName, number: reviewRow.number)

        let ownDetail = try await api.fetchPullRequestDetail(token: "token", reference: own).detail
        let reviewDetail = try await api.fetchPullRequestDetail(token: "token", reference: review).detail
        XCTAssertTrue(ownDetail.canEdit)
        XCTAssertFalse(reviewDetail.canEdit)
        XCTAssertEqual(reviewDetail.authorLogin, reviewRow.authorLogin)

        try await api.editPullRequest(token: "token", reference: own, title: "Renamed", body: "New body")

        let edited = try await api.fetchPullRequestDetail(token: "token", reference: own).detail
        XCTAssertEqual(edited.title, "Renamed")
        XCTAssertEqual(edited.body, "New body")
        let rows = try await api.fetchOpenPRs(token: "token").rows
        XCTAssertEqual(rows.first { $0.id == own.id }?.title, "Renamed")
    }
}

@MainActor
final class MockGitHubAPICommentTests: XCTestCase {
    private let reference = PullRequestReference(repoFullName: "mock/github-panel", number: 101)

    func testMockCommentsSitOnMockDiffLines() async throws {
        let api = MockGitHubAPI()
        let content = try await api.fetchPullRequestDetail(token: "token", reference: reference)
        let comments = try await api.fetchPullRequestComments(token: "token", reference: reference)

        XCTAssertFalse(comments.comments.isEmpty)
        for thread in comments.threads where !thread.isOutdated {
            let file = try XCTUnwrap(content.files.first { $0.filename == thread.path })
            let lines = DiffPresentation(lines: DiffParser.parse(file.patch ?? ""), hideWhitespace: false).unified
            XCTAssertEqual(ReviewThreadIndex(threads: [thread]).unplacedThreads(in: lines, path: thread.path), [], thread.id)
        }
    }

    func testMockPostsGeneralInlineAndReplyComments() async throws {
        let api = MockGitHubAPI()
        let before = try await api.fetchPullRequestComments(token: "token", reference: reference)
        let anchor = DiffCommentAnchor(path: "Sources/WidgetView.swift", line: 3, side: .right)
        let replyTarget = try XCTUnwrap(before.threads.first)

        try await api.postPullRequestComment(token: "token", reference: reference, comment: .general(body: "Ship it"))
        try await api.postPullRequestComment(token: "token", reference: reference,
                                             comment: .inline(body: "Nice", commitID: "sha", anchor: anchor))
        try await api.postPullRequestComment(token: "token", reference: reference,
                                             comment: .reply(body: "Done", commentID: try XCTUnwrap(replyTarget.comments.first).databaseID))
        let after = try await api.fetchPullRequestComments(token: "token", reference: reference)

        XCTAssertEqual(after.comments.last?.body, "Ship it")
        XCTAssertEqual(after.threads.last?.anchor, anchor)
        XCTAssertEqual(after.threads.last?.comments.map(\.body), ["Nice"])
        XCTAssertEqual(after.threads.first?.comments.last?.body, "Done")
        XCTAssertEqual(after.threads.first?.comments.count, replyTarget.comments.count + 1)
    }
}
