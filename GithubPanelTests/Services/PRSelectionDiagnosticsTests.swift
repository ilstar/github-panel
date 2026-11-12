import XCTest
@testable import GithubPanel

@MainActor
final class PRSelectionDiagnosticsTests: XCTestCase {
    func testDisabledDiagnosticsCreateNoFile() {
        let trace = PRSelectionDiagnostics(enabled: false)
        XCTAssertFalse(trace.isEnabled)
        XCTAssertNil(trace.logURL)
    }

    func testTraceCorrelatesSelectionAndRowUpdatesWithoutWritingPRIdentifiers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let trace = PRSelectionDiagnostics(enabled: true, directory: directory)
        let window = UUID()
        let instance = UUID()
        let first = "private-org/private-repo#123"
        let second = "private-org/private-repo#456"
        trace.selection("select-click", window: window, selectedID: second, previousID: first,
                        visibleIDs: [first, second, second], grouped: true)
        trace.row("row-update", window: window, rowID: second, instance: instance,
                  selected: true, hovering: false)
        trace.row("row-update", window: window, rowID: first, instance: UUID(),
                  selected: false, hovering: true)
        trace.stop()

        let text = try String(contentsOf: XCTUnwrap(trace.logURL), encoding: .utf8)
        XCTAssertFalse(text.contains(first))
        XCTAssertFalse(text.contains(second))
        let entries = try events(text)
        XCTAssertEqual(entries.first?["event"] as? String, "session-start")
        XCTAssertNotNil(entries.first?["macOS"])
        let selection = try XCTUnwrap(entries.first { $0["event"] as? String == "select-click" })
        let row = try XCTUnwrap(entries.first { $0["event"] as? String == "row-update" })
        XCTAssertEqual(selection["selected"] as? Int, row["row"] as? Int)
        XCTAssertEqual(selection["window"] as? String, row["window"] as? String)
        XCTAssertEqual(selection["duplicateCount"] as? Int, 1)
        XCTAssertEqual(selection["grouped"] as? Bool, true)
        XCTAssertEqual(row["instance"] as? String, instance.uuidString)
        XCTAssertEqual(row["selected"] as? Bool, true)
        XCTAssertEqual(row["hovering"] as? Bool, false)
        XCTAssertEqual(entries.last?["row"] as? Int, selection["previous"] as? Int)
        XCTAssertEqual(entries.last?["hovering"] as? Bool, true)
    }

    func testTraceStopsAtTheSizeLimitAndCanBeReadWithoutClosingIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let trace = PRSelectionDiagnostics(enabled: true, directory: directory, byteLimit: 1024)
        let url = try XCTUnwrap(trace.logURL)
        let window = UUID()
        for _ in 0..<20 {
            trace.selection("selection-observed", window: window, selectedID: "row",
                            visibleIDs: ["row"], grouped: false)
        }
        XCTAssertFalse(trace.isEnabled)
        let data = try Data(contentsOf: url)
        XCTAssertLessThanOrEqual(data.count, 1024)
        let entries = try events(String(decoding: data, as: UTF8.self))
        XCTAssertEqual(entries.last?["event"] as? String, "size-limit-reached")
    }

    private func events(_ text: String) throws -> [[String: Any]] {
        try text.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }
}
