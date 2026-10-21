import HerdrKit
import SwiftUI

/// What is left of the sidebar when it is collapsed, as in herdr's TUI: a
/// narrow strip of numbered status rings. Spaces on top, then every agent in
/// scope (as the sidebar's Agents section lists them). Clicking a row selects it without expanding.
struct SidebarRail: View {
    // Re-render when the terminal theme (and so Theme.contentBackground) changes.
    @AppStorage(TerminalThemeSetting.key) private var terminalThemeName = ""
    @AppStorage(Theme.windowBackgroundKey) private var windowBackgroundMode = Theme.defaultWindowBackgroundMode
    @AppStorage(Theme.backgroundImagePathKey) private var backgroundImagePath = ""
    @AppStorage(Theme.backgroundOverlayKey) private var backgroundOverlay = Theme.defaultBackgroundOverlay
    @AppStorage(Theme.translucentWindowKey) private var translucentWindow = false
    static let width: CGFloat = 36

    @ObservedObject var model: AppModel
    @Binding var collapsed: Bool
    @AppStorage("sidebar.spacesFraction") private var splitFraction: Double = 0.5

    private static let dividerHeight: CGFloat = 9

    private func pane<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 2) { content() }
                .padding(.horizontal, 4)
        }
        .clipped()
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: TitlebarMetrics.height + 12)
                .windowTitlebarInteraction()
            // Same split as the expanded sidebar: Spaces above, Agents below,
            // divided at the shared persisted fraction.
            GeometryReader { geo in
                let usable = max(0, geo.size.height - Self.dividerHeight)
                let lo: CGFloat = 96
                let hi = max(lo, usable - lo)
                let spacesHeight = min(max(usable * splitFraction, lo), hi)
                VStack(spacing: 0) {
                    pane {
                        ForEach(Array(model.visibleSpaces.enumerated()), id: \.element.id) { index, entry in
                            spaceRow(index: index, entry: entry)
                        }
                    }
                    .frame(height: spacesHeight)
                    Rectangle()
                        .fill(Theme.hairline)
                        .frame(height: 1)
                        .padding(.horizontal, 4)
                        .frame(height: Self.dividerHeight)
                    pane {
                        ForEach(Array(model.agentsInScope.enumerated()), id: \.element.id) { index, entry in
                            agentRow(index: index, entry: entry)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
        }
        .frame(width: Self.width)
        .background(Theme.sidebarBackground.ignoresSafeArea())
        .accessibilityIdentifier("sidebar.rail")
    }

    private func spaceRow(index: Int, entry: AppModel.SpaceEntry) -> some View {
        let ring = model.attention(in: entry).ring
        return railRow(
            number: index + 1,
            selected: model.selectedSpace == entry.ref,
            help: entry.workspace.label,
            id: "sidebar.rail.space.\(index + 1)"
        ) {
            StatusRing(status: ring.status, unreadDone: ring.unreadDone, size: 10)
        } action: {
            model.selectSpace(entry.ref)
        }
    }

    private func agentRow(index: Int, entry: AppModel.AgentEntry) -> some View {
        let selected = !model.isFileManagerActive
            && model.selectedPane == entry.ref
            && model.selectedShellID == nil
        return railRow(
            number: index + 1,
            selected: selected,
            help: entry.title,
            id: "sidebar.rail.agent.\(index + 1)"
        ) {
            StatusRing(status: entry.agent.status, unreadDone: model.isUnread(entry), size: 10)
        } action: {
            model.selectAgent(entry.ref)
        }
    }

    private func railRow<Ring: View>(
        number: Int,
        selected: Bool,
        help: String,
        id: String,
        @ViewBuilder ring: () -> Ring,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text("\(number)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(selected ? Theme.text : Theme.textTertiary)
                    .frame(minWidth: 9, alignment: .trailing)
                ring()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityIdentifier(id)
        .accessibilityLabel(help)
    }
}
