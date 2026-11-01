import XCTest
@testable import GithubPanel

final class MentionsTests: XCTestCase {
    func testFindsTheMentionBeforeTheCursor() {
        XCTAssertEqual(MentionQuery.active(in: "cc @octo", caret: 8),
                       MentionQuery(range: NSRange(location: 3, length: 5), text: "octo"))
        XCTAssertEqual(MentionQuery.active(in: "@", caret: 1),
                       MentionQuery(range: NSRange(location: 0, length: 1), text: ""))
        XCTAssertEqual(MentionQuery.active(in: "Thanks\n(@mona-lisa_2", caret: 20)?.text, "mona-lisa_2")
    }

    func testCoversTheRestOfTheWordAfterTheCursor() {
        XCTAssertEqual(MentionQuery.active(in: "@octocat rocks", caret: 3),
                       MentionQuery(range: NSRange(location: 0, length: 8), text: "oc"))
    }

    func testIgnoresAnAtInsideAWordOrPath() {
        XCTAssertNil(MentionQuery.active(in: "me@example", caret: 10))
        XCTAssertNil(MentionQuery.active(in: "`@types", caret: 7))
        XCTAssertNil(MentionQuery.active(in: "node_modules/@types", caret: 19))
        XCTAssertNil(MentionQuery.active(in: "@@octo", caret: 6))
    }

    func testEndsAtSpacesAndPunctuation() {
        XCTAssertNil(MentionQuery.active(in: "@octo cat", caret: 9))
        XCTAssertNil(MentionQuery.active(in: "@octo, hi", caret: 6))
        XCTAssertNil(MentionQuery.active(in: "no mention", caret: 10))
    }

    func testSkipsWordsLongerThanALogin() {
        let login = String(repeating: "a", count: MentionQuery.maxLength)
        XCTAssertNotNil(MentionQuery.active(in: "@" + login, caret: login.count + 1))
        XCTAssertNil(MentionQuery.active(in: "@a" + login, caret: login.count + 2))
    }

    func testMatchesNamesInOtherScriptsAndCountsUTF16() {
        let text = "👋 @José"
        let query = MentionQuery.active(in: text, caret: (text as NSString).length)
        XCTAssertEqual(query?.text, "José")
        XCTAssertEqual(query?.range, NSRange(location: 3, length: 5))
    }

    func testCompletionAddsASpaceUnlessOneFollows() throws {
        let typed = try XCTUnwrap(MentionQuery.active(in: "cc @oc", caret: 6))
        let atEnd = typed.completion(for: "octocat", in: "cc @oc")
        XCTAssertEqual(atEnd.replacement, "@octocat ")
        XCTAssertEqual(atEnd.caret, 12)

        let middle = try XCTUnwrap(MentionQuery.active(in: "@oc please", caret: 3))
        let beforeSpace = middle.completion(for: "octocat", in: "@oc please")
        XCTAssertEqual(beforeSpace.replacement, "@octocat")
        XCTAssertEqual(beforeSpace.caret, 9)
    }

    func testMergedPutsRepositoryPeopleFirstOnceAndCapsTheList() {
        let repository = [MentionCandidate(login: "hubot", name: "Hubot")]
        let everyone = [MentionCandidate(login: "HUBOT", name: nil)]
            + (1...20).map { MentionCandidate(login: "user\($0)") }

        let merged = MentionCandidate.merged(repository: repository, everyone: everyone)

        XCTAssertEqual(merged.count, MentionCandidate.limit)
        XCTAssertEqual(merged.first, MentionCandidate(login: "hubot", name: "Hubot"))
        XCTAssertEqual(merged[1].login, "user1")
    }
}
