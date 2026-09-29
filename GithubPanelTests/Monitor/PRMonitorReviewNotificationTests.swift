import XCTest
@testable import GithubPanel

@MainActor
final class PRMonitorReviewNotificationTests: XCTestCase {
    func testNewApprovalsAndChangeRequestsOnMyPullRequestsPostOnce() async {
        let api = FakeGitHubAPI()
        let notifications = FakeNotificationPoster()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), notificationPoster: notifications)
        api.rows = [reviewed(number: 1, approvedBy: ["hubot"])]
        await monitor.refreshNow()
        XCTAssertTrue(notifications.reviewPosts.isEmpty, "The first list only sets the baseline")

        api.rows = [reviewed(number: 1, approvedBy: ["hubot", "octocat"], changesRequestedBy: ["monalisa"])]
        await monitor.refreshNow()

        XCTAssertEqual(notifications.reviewPosts.map(\.kind), [.approved(by: ["octocat"]), .changesRequested(by: ["monalisa"])])
        XCTAssertEqual(notifications.reviewPosts.first?.reference, PullRequestReference(repoFullName: "acme/widgets", number: 1))

        await monitor.refreshNow()
        XCTAssertEqual(notifications.reviewPosts.count, 2, "Nothing changed, so nothing new is posted")
    }

    func testAPullRequestNewToTheListPostsNothing() async {
        let api = FakeGitHubAPI()
        let notifications = FakeNotificationPoster()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), notificationPoster: notifications)
        await monitor.refreshNow()

        api.rows = [reviewed(number: 2, approvedBy: ["hubot"])]
        await monitor.refreshNow()

        XCTAssertTrue(notifications.reviewPosts.isEmpty)
    }

    func testNewReviewRequestsPostButNotOnTheFirstLoadOrForDrafts() async {
        let api = FakeGitHubAPI()
        let notifications = FakeNotificationPoster()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), notificationPoster: notifications)
        api.reviewRequests = ReviewRequests(fromMe: [reviewRequestRow(number: 1)], fromMyTeams: [])
        await monitor.refreshReviewRequests()
        XCTAssertTrue(notifications.reviewPosts.isEmpty)

        var draft = reviewRequestRow(number: 3)
        draft = ReviewRequestRow(id: draft.id, title: draft.title, number: 3, repoFullName: draft.repoFullName,
                                 htmlURL: draft.htmlURL, authorLogin: "hubot", isDraft: true, updatedAt: draft.updatedAt)
        api.reviewRequests = ReviewRequests(fromMe: [reviewRequestRow(number: 1), reviewRequestRow(number: 2, author: "monalisa")],
                                            fromMyTeams: [draft])
        await monitor.refreshReviewRequests()

        XCTAssertEqual(notifications.reviewPosts.map(\.kind), [.reviewRequested(by: "monalisa")])
        XCTAssertEqual(notifications.reviewPosts.map(\.reference.number), [2])
    }

    func testAReRequestedReviewPostsAgain() async {
        let api = FakeGitHubAPI()
        let notifications = FakeNotificationPoster()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), notificationPoster: notifications)
        await monitor.refreshReviewRequests()
        api.reviewRequests = ReviewRequests(fromMe: [reviewRequestRow(number: 1)], fromMyTeams: [])
        await monitor.refreshReviewRequests()
        api.reviewRequests = .empty
        await monitor.refreshReviewRequests()

        api.reviewRequests = ReviewRequests(fromMe: [reviewRequestRow(number: 1)], fromMyTeams: [])
        await monitor.refreshReviewRequests()

        XCTAssertEqual(notifications.reviewPosts.count, 2)
    }

    func testAFailedRefreshKeepsWhatWasSeen() async {
        let api = FakeGitHubAPI()
        let notifications = FakeNotificationPoster()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), notificationPoster: notifications)
        api.reviewRequests = ReviewRequests(fromMe: [reviewRequestRow(number: 1)], fromMyTeams: [])
        await monitor.refreshReviewRequests()
        api.reviewRequestsHandler = { _ in throw TestError(message: "offline") }
        await monitor.refreshReviewRequests()

        api.reviewRequestsHandler = nil
        await monitor.refreshReviewRequests()

        XCTAssertTrue(notifications.reviewPosts.isEmpty)
    }

    func testANewTokenStartsAFreshBaseline() async {
        let api = FakeGitHubAPI()
        let notifications = FakeNotificationPoster()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), notificationPoster: notifications)
        await monitor.refreshReviewRequests()

        monitor.saveToken("other-token")
        api.reviewRequests = ReviewRequests(fromMe: [reviewRequestRow(number: 1)], fromMyTeams: [])
        await monitor.refreshReviewRequests()

        XCTAssertTrue(notifications.reviewPosts.isEmpty)
    }

    func testShowPullRequestPicksTheTabThatListsIt() {
        let monitor = makeMonitor()
        let mine = row(number: 1, status: .success)
        monitor.prRows = [mine]
        monitor.reviewRequests = ReviewRequests(fromMe: [reviewRequestRow(number: 2)], fromMyTeams: [])
        monitor.selectedTab = .history

        XCTAssertFalse(monitor.showPullRequest(mine.reference), "No main window is open yet")
        XCTAssertNil(monitor.pullRequestToShow)

        monitor.listWindowAppeared()
        XCTAssertTrue(monitor.showPullRequest(mine.reference))
        XCTAssertEqual(monitor.selectedTab, .open)
        XCTAssertEqual(monitor.pullRequestToShow, PullRequestToShow(reference: mine.reference, tab: .open))

        let review = PullRequestReference(repoFullName: "acme/widgets", number: 2)
        monitor.showPullRequest(review)
        XCTAssertEqual(monitor.selectedTab, .reviews)
        XCTAssertEqual(monitor.pullRequestToShow?.tab, .reviews)

        let elsewhere = PullRequestReference(repoFullName: "acme/gears", number: 9)
        monitor.showPullRequest(elsewhere)
        XCTAssertEqual(monitor.selectedTab, .reviews, "A pull request on neither list keeps the tab")
        XCTAssertEqual(monitor.pullRequestToShow, PullRequestToShow(reference: elsewhere, tab: nil))

        monitor.listWindowDisappeared()
        XCTAssertFalse(monitor.showPullRequest(mine.reference))
    }

    func testNotificationTextNamesWhoAndWhat() {
        let reference = PullRequestReference(repoFullName: "acme/widgets", number: 7)
        let url = URL(string: "https://github.com/acme/widgets/pull/7")!
        func notification(_ kind: PullRequestNotification.Kind) -> PullRequestNotification {
            PullRequestNotification(kind: kind, reference: reference, pullRequestTitle: "Add tests", htmlURL: url)
        }

        XCTAssertEqual(notification(.approved(by: ["octocat"])).heading, "Approved")
        XCTAssertEqual(notification(.approved(by: ["octocat", "hubot"])).body, "octocat and hubot approved acme/widgets#7: Add tests")
        XCTAssertEqual(notification(.changesRequested(by: ["monalisa"])).body, "monalisa requested changes on acme/widgets#7: Add tests")
        XCTAssertEqual(notification(.reviewRequested(by: "octocat")).heading, "Review Requested")
        XCTAssertEqual(notification(.reviewRequested(by: nil)).body, "Someone wants your review on acme/widgets#7: Add tests")
    }

    func testNotificationsCarryThePullRequestForOpeningInTheApp() {
        let reference = PullRequestReference(repoFullName: "acme/widgets", number: 7)
        let userInfo = NotificationManager.userInfo(for: reference, htmlURL: URL(string: "https://github.com/acme/widgets/pull/7")!)

        XCTAssertEqual(NotificationManager.reference(from: userInfo), reference)
        XCTAssertEqual(userInfo["url"] as? String, "https://github.com/acme/widgets/pull/7")
        XCTAssertNil(NotificationManager.reference(from: ["url": "https://github.com"]), "Older notifications only had a URL")
    }

    func testNotificationPreferencesDefaultToEnabledAndPersistIndependently() {
        let defaults = FakeDefaults()
        let flags: [ReferenceWritableKeyPath<PRMonitor, Bool>] = [
            \.notifyCheckResults, \.notifyApprovals, \.notifyChangesRequested,
            \.notifyReviewsFromMe, \.notifyReviewsFromMyTeams
        ]
        for flag in flags {
            let monitor = makeMonitor(defaults: defaults)
            XCTAssertTrue(monitor[keyPath: flag])
            monitor[keyPath: flag] = false
            let restored = makeMonitor(defaults: defaults)
            for other in flags {
                XCTAssertEqual(restored[keyPath: other], other != flag)
            }
            restored[keyPath: flag] = true
        }
    }

    func testPersonalAndTeamReviewPreferencesAreIndependentWithoutReplayingMutedRequests() async {
        for personalEnabled in [true, false] {
            let api = FakeGitHubAPI()
            let notifications = FakeNotificationPoster()
            let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), notificationPoster: notifications)
            monitor.notifyReviewsFromMe = personalEnabled
            monitor.notifyReviewsFromMyTeams = !personalEnabled
            await monitor.refreshReviewRequests()
            api.reviewRequests = ReviewRequests(fromMe: [reviewRequestRow(number: 1)], fromMyTeams: [reviewRequestRow(number: 2)])
            await monitor.refreshReviewRequests()
            XCTAssertEqual(notifications.reviewPosts.map(\.reference.number), [personalEnabled ? 1 : 2])

            monitor.notifyReviewsFromMe = true
            monitor.notifyReviewsFromMyTeams = true
            await monitor.refreshReviewRequests()
            XCTAssertEqual(notifications.reviewPosts.count, 1)
        }
    }

    func testDirectRequestAfterMutedTeamRequestStillNotifies() async {
        let api = FakeGitHubAPI()
        let notifications = FakeNotificationPoster()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), notificationPoster: notifications)
        monitor.notifyReviewsFromMyTeams = false
        api.reviewRequests = ReviewRequests(fromMe: [], fromMyTeams: [reviewRequestRow(number: 1)])
        await monitor.refreshReviewRequests()
        api.reviewRequests = ReviewRequests(fromMe: [reviewRequestRow(number: 1)], fromMyTeams: [])
        await monitor.refreshReviewRequests()
        XCTAssertEqual(notifications.reviewPosts.map(\.reference.number), [1])
    }

    func testApprovalAndChangeRequestPreferencesAreIndependentWithoutReplayingMutedReviews() async {
        for approvalsEnabled in [true, false] {
            let api = FakeGitHubAPI()
            let notifications = FakeNotificationPoster()
            let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), notificationPoster: notifications)
            monitor.notifyApprovals = approvalsEnabled
            monitor.notifyChangesRequested = !approvalsEnabled
            api.rows = [reviewed(number: 1)]
            await monitor.refreshNow()
            api.rows = [reviewed(number: 1, approvedBy: ["octocat"], changesRequestedBy: ["hubot"])]
            await monitor.refreshNow()
            XCTAssertEqual(notifications.reviewPosts.map(\.kind), approvalsEnabled ? [.approved(by: ["octocat"])] : [.changesRequested(by: ["hubot"])])
            monitor.notifyApprovals = true
            monitor.notifyChangesRequested = true
            await monitor.refreshNow()
            XCTAssertEqual(notifications.reviewPosts.count, 1)
        }
    }

    func testMutedCheckResultsStillRunHooksAndDoNotReplayWhenEnabled() async {
        let api = FakeGitHubAPI()
        let notifications = FakeNotificationPoster()
        let hooks = FakeHookRunner()
        let monitor = makeMonitor(api: api, tokenStore: FakeTokenStore(token: "token"), notificationPoster: notifications, hookRunner: hooks)
        monitor.notifyCheckResults = false
        monitor.allSucceededHookScript = "echo success"
        api.rows = [row(number: 1, status: .pending)]
        await monitor.refreshNow()
        api.rows = [row(number: 1, status: .success)]
        await monitor.refreshNow()
        XCTAssertTrue(notifications.posts.isEmpty)
        XCTAssertEqual(hooks.runs.count, 1)
        monitor.notifyCheckResults = true
        await monitor.refreshNow()
        XCTAssertTrue(notifications.posts.isEmpty)
        api.rows = [row(number: 1, status: .pending)]
        await monitor.refreshNow()
        api.rows = [row(number: 1, status: .failure)]
        await monitor.refreshNow()
        XCTAssertEqual(notifications.posts.map(\.state), [.failure])
    }

    private func reviewed(number: Int, approvedBy: [String] = [], changesRequestedBy: [String] = []) -> PullRequestRow {
        var item = row(number: number, status: .success)
        item.reviewStatus = PullRequestReviewStatus(approvedBy: approvedBy, changesRequestedBy: changesRequestedBy)
        return item
    }
}
