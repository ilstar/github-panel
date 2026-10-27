import XCTest
@testable import GithubPanel

final class MarkdownSpacingTests: XCTestCase {
    private let em: CGFloat = 13

    func testBodyTextGetsRoomyLineSpacingThatScalesWithTheTextSize() {
        XCTAssertEqual(MarkdownView.lineSpacing(em: 13), 7)
        XCTAssertEqual(MarkdownView.lineSpacing(em: 20), 11)
    }

    func testBulletsAreSolidDotsAboutTwoFifthsOfAnEm() {
        XCTAssertEqual(MarkdownView.bulletDiameter(em: 13), 5.5)
        XCTAssertEqual(MarkdownView.bulletDiameter(em: 20), 8.5)
    }

    func testListMarkersTakeAColumnAbout2EmWide() {
        XCTAssertEqual(MarkdownView.markerColumnWidth(em: 13), 29)
        XCTAssertEqual(MarkdownView.markerColumnWidth(em: 16), 35)
    }

    func testListItemsSitCloserThanParagraphsAndHeadingsStartASection() {
        let item = MarkdownBlock.listItem(marker: "•", indent: 0, text: "One")
        let task = MarkdownBlock.task(index: 0, checked: false, indent: 0, text: "Do")
        let paragraph = MarkdownBlock.paragraph("Text")
        let heading = MarkdownBlock.heading(level: 2, text: "Summary")

        let betweenItems = MarkdownView.spacing(before: item, after: item, em: em)
        let betweenParagraphs = MarkdownView.spacing(before: paragraph, after: paragraph, em: em)
        XCTAssertEqual(betweenItems, 10)
        XCTAssertEqual(MarkdownView.spacing(before: task, after: item, em: em), betweenItems)
        XCTAssertEqual(betweenParagraphs, 14)
        XCTAssertLessThan(betweenItems, betweenParagraphs)
        XCTAssertEqual(MarkdownView.spacing(before: heading, after: paragraph, em: em), 23)
        XCTAssertEqual(MarkdownView.spacing(before: item, after: heading, em: em), 12)
    }
}
