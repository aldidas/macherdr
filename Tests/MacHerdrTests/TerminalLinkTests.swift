import XCTest
@testable import MacHerdr

@MainActor
final class TerminalLinkTests: XCTestCase {
    private let oauthURL =
        "https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        + "&response_type=code&scope=org%3Acreate_api_key+user%3Aprofile+user%3Ainference"
        + "&state=kFEEXox9ojVpHg4_Tsac7TrEySFD-rB8l9lGuuZDyMI"

    /// Lays `text` out the way herdr hands it over: hard rows of `columns`
    /// cells, the last one partial.
    private func rows(_ text: String, columns: Int) -> [String] {
        var rows: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            rows.append(String(rest.prefix(columns)))
            rest = rest.dropFirst(columns)
        }
        return rows
    }

    func testLinkSplitAcrossFullRowsIsJoinedWithoutBreaks() {
        let columns = 60
        let lines = ["Browser didn't open? Use the url below to sign in:"]
            + rows(oauthURL, columns: columns)
            + ["", "Paste code here if prompted >"]
        for row in 1...(lines.count - 3) {
            let link = LineBreakTerminalView.link(in: lines, row: row, column: 10, columns: columns)
            XCTAssertEqual(link?.text, oauthURL, "row \(row)")
        }
    }

    func testCopiedTextIsTheExactPrintedURL() {
        let columns = 40
        let lines = rows(oauthURL, columns: columns)
        let link = LineBreakTerminalView.link(in: lines, row: 0, column: 0, columns: columns)
        // Percent escapes and `+` stay as printed: the copy is what was shown.
        XCTAssertEqual(link?.text, oauthURL)
        XCTAssertFalse(link?.text.contains("\n") ?? true)
    }

    func testPointerOffTheLinkFindsNothing() {
        let lines = ["see https://example.com/a for details"]
        XCTAssertNil(LineBreakTerminalView.link(in: lines, row: 0, column: 0, columns: 80))
        XCTAssertNotNil(LineBreakTerminalView.link(in: lines, row: 0, column: 6, columns: 80))
    }

    func testShortRowEndsTheLink() {
        // A row that does not reach the right edge is a real line end.
        let lines = ["https://example.com/one", "two"]
        let link = LineBreakTerminalView.link(in: lines, row: 0, column: 3, columns: 80)
        XCTAssertEqual(link?.text, "https://example.com/one")
    }

    func testLinkAmongManyJoinedFullRowsIsFound() {
        // TUI borders and padding fill rows edge to edge, so the whole screen
        // joins into one string; only the word under the pointer matters.
        let columns = 40
        let filler = String(repeating: "─", count: columns)
        let linkRow = "see https://example.com/x " + String(repeating: " ", count: columns - 26)
        let lines = Array(repeating: filler, count: 30) + [linkRow] + Array(repeating: filler, count: 30)
        let link = LineBreakTerminalView.link(in: lines, row: 30, column: 8, columns: columns)
        XCTAssertEqual(link?.text, "https://example.com/x")
        XCTAssertNil(LineBreakTerminalView.link(in: lines, row: 30, column: 1, columns: columns))
        XCTAssertNil(LineBreakTerminalView.link(in: lines, row: 5, column: 3, columns: columns))
    }

    func testBareWordsAreNotLinks() {
        let lines = ["open README.md now"]
        XCTAssertNil(LineBreakTerminalView.link(in: lines, row: 0, column: 7, columns: 80))
    }

    func testURLWrapperStillReturnsTheOpenableURL() {
        let columns = 50
        let lines = rows(oauthURL, columns: columns)
        let url = LineBreakTerminalView.url(in: lines, row: 1, column: 5, columns: columns)
        XCTAssertNotNil(url)
        XCTAssertNotNil(URL(string: url ?? ""))
    }
}
