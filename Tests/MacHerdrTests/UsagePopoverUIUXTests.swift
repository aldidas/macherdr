import AppKit
import HerdrKit
import SwiftUI
import XCTest
@testable import MacHerdr

@MainActor
final class UsagePopoverUIUXTests: XCTestCase {
    func testPopoverShowsABarPerWindowAndTheContextFill() throws {
        let usage = try XCTUnwrap(AgentUsage(tokens: [
            "claude_ctx": "context 47% · cache 99.8%",
            "claude_usage": "5h 7% 3h21m · 7d 2% 6d18h",
        ]))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "UsagePopover \(UUID().uuidString)"
        let info = TitlebarInfo(
            agentKind: "claude",
            title: "claude",
            spaceName: "herdrm",
            device: .local,
            status: .working,
            cwd: nil,
            usage: usage
        )
        window.contentView = NSHostingView(rootView: UsagePopover(info: info, showsDevice: false))
        window.orderFrontRegardless()
        defer { window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let names = AccessibilityProbe.elements(in: window).compactMap(\.name)
        XCTAssertTrue(names.contains { $0.contains("5 hours") && $0.contains("7%") && $0.contains("3h21m") }, "\(names)")
        XCTAssertTrue(names.contains { $0.contains("7 days") && $0.contains("2%") }, "\(names)")
        XCTAssertTrue(names.contains { $0.contains("Context") && $0.contains("47%") }, "\(names)")
    }
}
