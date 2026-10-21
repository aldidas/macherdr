import HerdrKit
import SwiftUI

/// Tabs of the selected space, mirroring herdr's TUI tab strip.
struct SpaceTabBar: View {
    @ObservedObject var model: AppModel
    let space: SpaceRef
    // Re-render when the terminal theme (and so Theme.tabStripBackground) changes.
    @AppStorage(TerminalThemeSetting.key) private var terminalThemeName = ""
    @AppStorage(Theme.windowBackgroundKey) private var windowBackgroundMode = Theme.defaultWindowBackgroundMode
    @AppStorage(Theme.backgroundImagePathKey) private var backgroundImagePath = ""
    @AppStorage(Theme.backgroundOverlayKey) private var backgroundOverlay = Theme.defaultBackgroundOverlay
    @AppStorage(Theme.translucentWindowKey) private var translucentWindow = false
    @State private var renameText = ""
    @State private var draggingTabID: String?
    @State private var tabDrop: (id: String, after: Bool)?

    /// Widest a tab grows; tabs shrink evenly (and truncate) when the strip runs out of room.
    private static let tabWidth: CGFloat = 190

    var body: some View {
        let tabs = model.tabs(in: space)
        let active = model.activeTabID(in: space)
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(tabs) { tab in
                    tabCell(tab, selected: tab.tabID == active, canClose: tabs.count > 1)
                }
            }
            .padding(3)
            .frame(maxWidth: Self.tabWidth * CGFloat(tabs.count) + 6)
            .background(Theme.tabStripBackground, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
            Button {
                model.newTab(in: space)
            } label: {
                TitlebarIconLabel(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help("New Tab")
            Spacer(minLength: 0)
        }
        .onChange(of: model.tabToRename) { _, tab in
            if let tab { renameText = tab.customLabel ?? tab.label }
        }
        .alert("Rename Tab", isPresented: Binding(
            get: { model.tabToRename != nil },
            set: { if !$0 { model.tabToRename = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) { model.tabToRename = nil }
        }
    }

    private func tabCell(_ tab: TabInfo, selected: Bool, canClose: Bool) -> some View {
        HStack(spacing: 6) {
            StatusRing(status: AgentStatus(wire: tab.agentStatusRaw), size: 9)
            Text(tab.customLabel ?? tab.label)
                .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                .lineLimit(1)
            // Reserves the close button's slot; the real button sits above the drag host.
            if canClose { Color.clear.frame(width: 9, height: 9) }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: Self.tabWidth)
        .frame(height: 30)
        .selectedTabGlass(selected)
        .opacity(draggingTabID == tab.tabID ? 0.4 : 1)
        .overlay(alignment: (tabDrop?.after ?? false) ? .trailing : .leading) {
            if tabDrop?.id == tab.tabID {
                Capsule().fill(Theme.accent).frame(width: 2, height: 18)
                    .transaction { $0.animation = nil }
            }
        }
        // AppKit host: click selects, double-click renames, a few points of movement
        // start a drag (SwiftUI gestures and .onDrag fight over mouseDown on macOS).
        .overlay {
            SidebarRowDragHost(
                entryID: tab.tabID,
                pasteboardType: SidebarRowDragNSView.tabPasteboardType,
                menuItems: menuItems(for: tab, canClose: canClose),
                onClick: { model.selectTab(tab, deviceID: space.deviceID) },
                onDoubleClick: { model.tabToRename = tab },
                allowsDrag: canClose,
                horizontal: true,
                onDragStart: { draggingTabID = $0 },
                onDragEnd: {
                    draggingTabID = nil
                    tabDrop = nil
                },
                onDropHover: { after in tabDrop = (tab.tabID, after) },
                onHoverExit: { if tabDrop?.id == tab.tabID { tabDrop = nil } },
                onDrop: { sourceID, after in
                    draggingTabID = nil
                    tabDrop = nil
                    guard sourceID != tab.tabID else { return }
                    model.moveTab(sourceID, onto: tab.tabID, in: space, placeAfter: after)
                }
            )
        }
        .overlay(alignment: .trailing) {
            if canClose {
                Button {
                    model.requestCloseTab(tab, deviceID: space.deviceID)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textGhost)
                        .frame(width: 20, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .help("Close Tab")
            }
        }
    }

    private func menuItems(for tab: TabInfo, canClose: Bool) -> [SidebarContextMenuItem] {
        var items: [SidebarContextMenuItem] = [
            .item(title: String(localized: "Rename Tab…"), action: { model.tabToRename = tab }),
        ]
        if canClose {
            items.append(.separator)
            items.append(.destructive(title: String(localized: "Close Tab"), action: {
                model.requestCloseTab(tab, deviceID: space.deviceID)
            }))
        }
        return items
    }

    private func commitRename() {
        guard let tab = model.tabToRename else { return }
        let label = renameText.trimmingCharacters(in: .whitespaces)
        model.tabToRename = nil
        guard !label.isEmpty, let device = model.device(space.deviceID) else { return }
        let service = model.service(for: device)
        Task { @MainActor in
            do { try await service.renameTab(tabID: tab.tabID, label: label) } catch {
                model.actionError = error.localizedDescription
            }
        }
    }
}

extension View {
    /// Liquid Glass slab around the (already clipped) terminal on macOS 26+: the
    /// terminal stays opaque inside a few points of glass rim. Before that, the
    /// plain margin to the right and bottom.
    @ViewBuilder
    func terminalPanelGlass(leadingMargin: Bool = false) -> some View {
        let inset = DetailMetrics.glassInset
        let margin = DetailMetrics.terminalMargin
        if #available(macOS 26, *) {
            padding(inset)
                .glassEffect(
                    .regular.tint(Theme.terminalBackground.opacity(0.9)),
                    in: RoundedRectangle(
                        cornerRadius: DetailMetrics.terminalCornerRadius + inset,
                        style: .continuous
                    )
                )
                .padding(.leading, leadingMargin ? margin - inset : 0)
                .padding(.trailing, margin - inset)
                .padding(.bottom, margin - inset)
        } else {
            padding(.leading, leadingMargin ? margin : 0)
                .padding(.trailing, margin)
                .padding(.bottom, margin)
        }
    }

    /// Highlight for the selected titlebar tab: a Liquid Glass capsule on
    /// macOS 26+, a flat wash before that.
    @ViewBuilder
    func selectedTabGlass(_ selected: Bool) -> some View {
        if #available(macOS 26, *) {
            if selected {
                glassEffect(.regular.interactive(), in: .capsule)
            } else {
                self
            }
        } else {
            background(selected ? Theme.itemWashSelected : Color.clear, in: Capsule())
        }
    }
}
