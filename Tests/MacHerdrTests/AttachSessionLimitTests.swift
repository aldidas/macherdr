import HerdrKit
import XCTest
@testable import MacHerdr

/// Kept-alive attaches are capped at the most recently viewed panes: each one
/// holds a ghostty surface with full-window framebuffers whether shown or not.
@MainActor
final class AttachSessionLimitTests: XCTestCase {
    private func select(_ model: AppModel, _ index: Int) {
        model.selectedPane = PaneRef(deviceID: Device.local.id, paneID: "pane-\(index)")
    }

    private func keptPaneIDs(_ model: AppModel) -> Set<String> {
        Set(model.attachSessions.map(\.ref.paneID))
    }

    func testOnlyTheMostRecentlyViewedPanesStayMounted() throws {
        let model = try SidebarHarness.fakeModel(spaces: 1, agents: 10, terminals: 0, agentTokens: nil)
        for index in 0..<10 { select(model, index) }

        let limit = AppModel.keptAliveAttachLimit
        XCTAssertEqual(model.attachSessions.count, limit)
        XCTAssertEqual(keptPaneIDs(model), Set(((10 - limit)..<10).map { "pane-\($0)" }))
    }

    func testRevisitingAPaneKeepsItOverOlderOnes() throws {
        let model = try SidebarHarness.fakeModel(spaces: 1, agents: 10, terminals: 0, agentTokens: nil)
        let limit = AppModel.keptAliveAttachLimit
        for index in 0..<limit { select(model, index) }
        select(model, 0)  // pane-0 is now the most recent; pane-1 the oldest
        select(model, limit)

        XCTAssertEqual(model.attachSessions.count, limit)
        XCTAssertTrue(keptPaneIDs(model).contains("pane-0"))
        XCTAssertFalse(keptPaneIDs(model).contains("pane-1"))
    }

    func testTheSelectedPaneIsNeverEvicted() throws {
        let model = try SidebarHarness.fakeModel(spaces: 1, agents: 10, terminals: 0, agentTokens: nil)
        for index in 0..<10 {
            select(model, index)
            XCTAssertTrue(keptPaneIDs(model).contains("pane-\(index)"), "pane-\(index)")
        }
    }
}
