import AppKit
import HerdrKit
import SwiftUI
import StickySectionHeaders

struct SidebarView: View {
    @ObservedObject var model: AppModel
    // Re-render when the terminal theme (and so Theme.contentBackground) changes.
    @AppStorage(TerminalThemeSetting.key) private var terminalThemeName = ""
    @AppStorage(Theme.windowBackgroundKey) private var windowBackgroundMode = Theme.defaultWindowBackgroundMode
    @AppStorage(Theme.backgroundImagePathKey) private var backgroundImagePath = ""
    @AppStorage(Theme.backgroundOverlayKey) private var backgroundOverlay = Theme.defaultBackgroundOverlay
    @Binding var collapsed: Bool
    var width: CGFloat = SidebarWidth.defaultWidth
    @State private var draggingSpaceID: String?
    @State private var spaceDrop: (id: String, after: Bool)?
    @State private var draggingAgentID: String?
    @State private var agentDrop: (id: String, after: Bool)?
    @State private var spacesExpanded = true
    @State private var agentsExpanded = true
    @AppStorage("sidebar.spacesFraction") private var splitFraction: Double = 0.5

    var body: some View {
        VStack(spacing: 0) {
            // Titlebar strip: traffic lights, then the collapse toggle, with the
            // actions menu on the right.
            HStack(spacing: 0) {
                Spacer().frame(width: TitlebarMetrics.trafficLightClearance - 10)
                TitlebarIconButton(systemName: "sidebar.left", help: "Hide Sidebar (⌘B)") {
                    collapsed = true
                }
                Spacer()
                TitlebarActionsMenu(model: model)
            }
            .padding(.horizontal, 10)
            .frame(height: TitlebarMetrics.height)
            .windowTitlebarInteraction()

            Spacer().frame(height: 8)

            Spacer().frame(height: 4)

            splitSections
            Spacer(minLength: 0)
            footer
        }
        .frame(width: width)
        .background(Theme.sidebarBackground.ignoresSafeArea())
    }

    // MARK: - Spaces / Agents split

    /// Minimum height of either pane while it is expanded.
    private static let minPaneHeight: CGFloat = 96
    private static let dividerHeight: CGFloat = 9
    private static let collapsedPaneHeight: CGFloat = 36

    /// Spaces and Agents sit in two independently scrolling panes separated by
    /// a draggable divider. The split is a fraction of the available height,
    /// persisted across launches; the default is the vertical centre.
    private var splitSections: some View {
        GeometryReader { geo in
            let total = geo.size.height
            let bothOpen = spacesExpanded && agentsExpanded
            let spacesHeight = paneHeight(total: total, bothOpen: bothOpen)
            VStack(spacing: 0) {
                pane { spacesPane }
                    .frame(height: spacesHeight)
                if bothOpen {
                    splitDivider(total: total)
                }
                pane { agentsPane }
                    .frame(maxHeight: .infinity)
            }
            .coordinateSpace(name: "sidebarSplit")
        }
    }

    private func paneHeight(total: CGFloat, bothOpen: Bool) -> CGFloat {
        if bothOpen {
            let lo = Self.minPaneHeight
            let usable = total - Self.dividerHeight
            let hi = max(lo, usable - Self.minPaneHeight)
            return min(max(usable * splitFraction, lo), hi)
        }
        if !spacesExpanded { return Self.collapsedPaneHeight }
        // Spaces open, Agents collapsed: Agents shrinks to its header.
        return max(0, total - Self.collapsedPaneHeight)
    }

    private func pane<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content()
                .padding(.horizontal, 10)
                .stickySectionHeaders()
        }
        .clipped()
    }

    private func splitDivider(total: CGFloat) -> some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .frame(height: Self.dividerHeight)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("sidebarSplit"))
                    .onChanged { value in
                        let usable = total - Self.dividerHeight
                        guard usable > 0 else { return }
                        // The pointer holds the divider's centre.
                        splitFraction = min(max((value.location.y - Self.dividerHeight / 2) / usable, 0.05), 0.95)
                    }
            )
            .accessibilityIdentifier("sidebar.splitDivider")
    }

    private var spacesPane: some View {
        VStack(spacing: 1) {
            StickySection(background: { Theme.sidebarHeaderBackground }) {
                groupHeader("Spaces", expanded: $spacesExpanded) {
                    EmptyView()
                }
                .accessibilityIdentifier("sidebar.section.spaces")
            } content: {
                if spacesExpanded {
                    allSpacesRow
                    ForEach(model.visibleSpaces) { entry in
                        SpaceRowView(
                            entry: entry,
                            model: model,
                            draggingSpaceID: $draggingSpaceID,
                            spaceDrop: $spaceDrop
                        )
                    }
                }
                Spacer().frame(height: 6)
            }

        }
    }

    private var agentsPane: some View {
        VStack(spacing: 1) {
            StickySection(background: { Theme.sidebarHeaderBackground }) {
                groupHeader("Agents", expanded: $agentsExpanded) {
                    Text("priority")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textGhost)
                    SidebarHeaderButton(systemName: "square.and.pencil", title: "New Agent") {
                        model.showNewAgent = true
                    }
                }
                .accessibilityIdentifier("sidebar.section.agents")
            } content: {
                if agentsExpanded {
                    if model.agentsInScope.isEmpty {
                        Text(emptyAgentsHint)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textGhost)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    ForEach(model.agentsInScope) { entry in
                        AgentRowView(
                            entry: entry,
                            model: model,
                            draggingAgentID: $draggingAgentID,
                            agentDrop: $agentDrop
                        )
                    }
                }
            }
        }
    }

    private var emptyAgentsHint: String {
        switch model.connection {
        case .connecting: return String(localized: "Connecting…")
        case .failed(let reason): return reason
        default: return String(localized: "No agents")
        }
    }

    // MARK: - Rows

    private func groupHeader<Trailing: View>(
        _ title: LocalizedStringKey,
        expanded: Binding<Bool>,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 5) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    // Over a background image the quiet grays lose contrast; step up one level.
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(backgroundImagePath.isEmpty ? Theme.textTertiary : Theme.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(backgroundImagePath.isEmpty ? Theme.textGhost : Theme.textTertiary)
                        .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .disclosureAccessibility(expanded: expanded.wrappedValue)

            trailing()
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
    }

    /// Everything the old `new … menu` strip offered, in one titlebar menu
    /// (also reachable via the app menu shortcuts).
    private var allSpacesRow: some View {
        let selected = model.selectedSpace == nil
        return Button {
            model.selectSpace(nil)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 11.5))
                    .foregroundStyle(selected ? Theme.textSecondary : Theme.textTertiary)
                Text("All Spaces")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                Spacer()
                SpaceAttentionGlyph(attention: model.scopeAttention)
                Text("\(model.scopeAgentCount)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textGhost)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle(selected: selected))
    }

    private struct AgentRowView: View {
    let entry: AppModel.AgentEntry
    @ObservedObject var model: AppModel
    @Binding var draggingAgentID: String?
    @Binding var agentDrop: (id: String, after: Bool)?
    @State private var hovered = false

    var body: some View {
        let agent = entry.agent
        let selected = !model.isFileManagerActive
            && model.selectedPane == entry.ref
            && model.selectedShellID == nil
        let unread = model.isUnread(entry)
        HStack(spacing: 7) {
            StatusRing(status: agent.status, unreadDone: unread)
            AgentKindBadge(kind: agent.agent, color: Theme.text)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if agent.status == .blocked {
                Text("needs input")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.warning)
                    .lineLimit(1)
            } else {
                Text("\(model.spaceName(deviceID: entry.device.id, workspaceID: agent.workspaceID)) · \(entry.title)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if model.showsRowDeviceBadges {
                DeviceChip(device: entry.device)
            }
        }
        .help(statsTooltip)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(minHeight: 28)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(selected || hovered ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
        )
        .onHover { hovered = $0 }
        .sidebarDragChrome(
            isDragging: draggingAgentID == entry.id,
            dropAfter: agentDrop?.after,
            isTarget: agentDrop?.id == entry.id
        )
        .overlay {
            AgentRowDragHost(
                entryID: entry.id,
                pluginActions: model.session(entry.device.id).pluginActions,
                onClick: { model.selectAgent(entry.ref) },
                onRename: { model.agentToRename = entry },
                onPluginAction: { model.runPluginAction($0, for: entry) },
                onGrazrAccounts: { model.grazrAccountsDevice = entry.device },
                onMenuOpen: { Task { await model.loadPluginActions(deviceID: entry.device.id) } },
                onClose: { model.requestClosePane(entry.ref, name: entry.title) },
                onDragStart: { draggingAgentID = $0 },
                onDragEnd: {
                    draggingAgentID = nil
                    agentDrop = nil
                },
                    onDropHover: { after in
                        agentDrop = sidebarDropTarget(
                            onto: entry.id, after: after, items: model.agentsInScope
                        )
                    },
                onHoverExit: {
                    if agentDrop?.id == entry.id { agentDrop = nil }
                },
                onDrop: { sourceID, after in
                    draggingAgentID = nil
                    agentDrop = nil
                    guard let source = model.agentsInScope.first(where: { $0.id == sourceID })
                    else { return }
                    model.moveAgent(source, onto: entry, placeAfter: after)
                }
            )
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.selectAgent(entry.ref) }
        .accessibilityLabel(accessibilityLabel(unread: unread))
    }

    private var statsTooltip: String {
        ([entry.title] + entry.agent.statsLines.map(\.text)).joined(separator: "\n")
    }

    private func accessibilityLabel(unread: Bool) -> String {
        var parts = [entry.title]
        switch entry.agent.status {
        case .working: parts.append(String(localized: "Working"))
        case .blocked: parts.append(String(localized: "Needs input"))
        case .done where unread: parts.append(String(localized: "Unread"))
        case .done: break
        case .idle, .unknown: break
        }
        if let account = entry.agent.statsLines.first(where: { $0.kind == .account }) {
            parts.append(account.text)
        }
        return parts.joined(separator: ", ")
    }
}

    // MARK: - Footer (device filter)

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                model.showDevicePanel.toggle()
            } label: {
                HStack(spacing: 6) {
                    if let device = model.filteredDevice {
                        DeviceIcon(osID: device.osID, isLocal: device.isLocal, size: 10)
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Text(model.filteredDevice?.name ?? "All Devices")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Circle()
                        .fill(connectionDotColor)
                        .frame(width: 6, height: 6)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Theme.textGhost)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 30)
                .selectedTabGlass(true)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .frame(height: 44)
    }

    private var connectionDotColor: Color {
        switch model.connection {
        case .connected: return Theme.success
        case .connecting: return Theme.warning
        case .failed: return Theme.danger
        case .idle: return Theme.textGhost
        }
    }
}

/// The small "new" button at the right end of a section header; same icon as
/// the matching New … action row above the list. `title` is the tooltip and
/// what VoiceOver reads (an icon alone is read by its symbol name).
struct SidebarHeaderButton: View {
    let systemName: String
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textGhost)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .focusEffectDisabled()
    }
}

/// Icon button that sits in the titlebar strip. On macOS 26+ it is a Liquid Glass
/// circle (like the Notes / Mail toolbars); earlier systems keep the flat hover wash.
struct TitlebarIconLabel: View {
    let systemName: String
    /// False when the caller applies the glass to an enclosing control (a `Menu`
    /// ignores glass drawn inside its label).
    var drawsGlass = true
    @State private var hovered = false

    var body: some View {
        if #available(macOS 26, *) {
            let icon = Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.text)
                .frame(width: 32, height: 32)
            if drawsGlass {
                icon.glassEffect(.regular.interactive(), in: .circle)
                    .contentShape(Circle())
            } else {
                // Plain-style menus only hit-test drawn pixels, so without this
                // clicks on the empty part of the circle miss the menu.
                icon.contentShape(Circle())
            }
        } else {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovered ? AnyShapeStyle(Theme.itemWash) : AnyShapeStyle(.clear))
                )
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}

struct TitlebarIconButton: View {
    let systemName: String
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TitlebarIconLabel(systemName: systemName)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(help)
    }
}

/// Custom device switcher popover, matching the DeviceSwitcher design artboard:
/// two-line device rows with OS icon, status dot, and a check on the current device.
struct DevicePopover: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("DEVICES")
                .font(.system(size: 10.5, weight: .medium))
                .kerning(0.3)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 9)
                .frame(height: 24, alignment: .leading)

            // aggregate view across every connected device
            Button {
                isPresented = false
                model.setDeviceFilter(nil)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 13))
                        .foregroundStyle(model.deviceFilter == nil ? Theme.text : Theme.textSecondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("All Devices")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.text)
                        Text(String(localized: "\(model.devices.count) devices · \(connectedCount) connected"))
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 0)
                    if model.deviceFilter == nil {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.text)
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 42)
                .contentShape(Rectangle())
            }
            .buttonStyle(SidebarRowButtonStyle(selected: model.deviceFilter == nil))

            ForEach(model.devices) { device in
                DevicePopoverRow(
                    device: device,
                    isActive: device.id == model.deviceFilter,
                    connection: model.session(device.id).connection
                ) {
                    isPresented = false
                    model.setDeviceFilter(device.id)
                }
                .contextMenu {
                    if !device.isLocal {
                        Button(String(localized: "Edit \(device.name)…")) {
                            isPresented = false
                            model.deviceToEdit = device
                        }
                        Button(String(localized: "Remove \(device.name)"), role: .destructive) {
                            isPresented = false
                            model.removeDevice(device)
                        }
                    }
                }
            }

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .padding(.vertical, 4)
                .padding(.horizontal, 6)

            actionRow(icon: "plus", label: "Add Device…") {
                isPresented = false
                model.showAddDevice = true
            }
        }
        .padding(5)
        .frame(width: 252)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
    }

    private var connectedCount: Int {
        model.devices.filter {
            if case .connected = model.session($0.id).connection { return true }
            return false
        }.count
    }

    private func actionRow(icon: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle())
    }
}

struct DevicePopoverRow: View {
    let device: Device
    let isActive: Bool
    let connection: ConnectionState
    let action: () -> Void
    @State private var hovered = false

    private var dotColor: Color {
        switch connection {
        case .connected: return Theme.success
        case .connecting: return Theme.warning
        case .failed: return Theme.danger
        case .idle: return Theme.textGhost
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                DeviceIcon(osID: device.osID, isLocal: device.isLocal, size: 13)
                    .foregroundStyle(isActive ? Theme.text : Theme.textSecondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(device.name)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.text)
                        Circle()
                            .fill(dotColor)
                            .frame(width: 6, height: 6)
                    }
                    Text(device.localizedSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.text)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovered || isActive ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
        )
        .onHover { hovered = $0 }
    }
}

/// `after A` and `before B` are the same gap. Always draw that gap on B's
/// top edge so the line does not jump when the pointer crosses the seam.
private func sidebarDropTarget<T: Identifiable>(
    onto id: T.ID, after: Bool, items: [T]
) -> (id: T.ID, after: Bool) {
    guard after,
          let index = items.firstIndex(where: { $0.id == id }),
          items.indices.contains(index + 1)
    else { return (id, after) }
    return (items[index + 1].id, false)
}

private extension View {
    func sidebarDragChrome(isDragging: Bool, dropAfter: Bool?, isTarget: Bool) -> some View {
        opacity(isDragging ? 0.4 : 1)
            .animation(.easeOut(duration: 0.15), value: isDragging)
            .overlay(alignment: (dropAfter ?? false) ? .bottom : .top) {
                if isTarget {
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(height: 2)
                        .transaction { $0.animation = nil }
                }
            }
    }

    /// Button trait plus expanded/collapsed so VoiceOver matches the chevron.
    /// macOS SwiftUI has no `accessibilityExpanded`; VoiceOver reads the value.
    func disclosureAccessibility(expanded: Bool) -> some View {
        self
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
    }
}

struct SidebarRowButtonStyle: ButtonStyle {
    var selected: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected || configuration.isPressed ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
            )
    }
}

/// Not a `Button`: on macOS, `Button` consumes mouseDown so SwiftUI `.onDrag`
/// never starts. Click and reorder go through `SpaceRowDragHost`.
private struct SpaceRowView: View {
    let entry: AppModel.SpaceEntry
    @ObservedObject var model: AppModel
    @Binding var draggingSpaceID: String?
    @Binding var spaceDrop: (id: String, after: Bool)?
    @State private var hovered = false

    var body: some View {
        let selected = model.selectedSpace == entry.ref
        let git = model.gitStatus(for: entry)
        let ring = model.attention(in: entry).ring
        HStack(alignment: .top, spacing: 8) {
            StatusRing(status: ring.status, unreadDone: ring.unreadDone)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.workspace.label)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                    .lineLimit(1)
                if let git {
                    Text(git.branch)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            if let git, git.ahead > 0 {
                Text("↑\(git.ahead)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            if model.showsRowDeviceBadges {
                DeviceChip(device: entry.device)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minHeight: 40)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(selected || hovered ? AnyShapeStyle(Theme.itemWashSelected) : AnyShapeStyle(.clear))
        )
        .overlay {
            if selected { RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.sidebarBorder, lineWidth: 1) }
        }
        .onHover { hovered = $0 }
        .sidebarDragChrome(
            isDragging: draggingSpaceID == entry.id,
            dropAfter: spaceDrop?.after,
            isTarget: spaceDrop?.id == entry.id
        )
        .overlay {
            SpaceRowDragHost(
                entryID: entry.id,
                label: entry.workspace.label,
                onClick: { model.selectSpace(entry.ref) },
                onRename: { model.spaceToRename = entry },
                onClose: { model.requestCloseSpace(entry) },
                onDragStart: { draggingSpaceID = $0 },
                onDragEnd: {
                    draggingSpaceID = nil
                    spaceDrop = nil
                },
                    onDropHover: { after in
                        spaceDrop = sidebarDropTarget(
                            onto: entry.id, after: after, items: model.visibleSpaces
                        )
                    },
                onHoverExit: {
                    if spaceDrop?.id == entry.id { spaceDrop = nil }
                },
                onDrop: { sourceID, after in
                    draggingSpaceID = nil
                    spaceDrop = nil
                    guard let source = model.visibleSpaces.first(where: { $0.id == sourceID })
                    else { return }
                    model.moveSpace(source, onto: entry, placeAfter: after)
                }
            )
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.selectSpace(entry.ref) }
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [entry.workspace.label]
        switch model.attention(in: entry) {
        case .blocked: parts.append(String(localized: "Needs input"))
        case .unreadDone: parts.append(String(localized: "Unread"))
        case .working: parts.append(String(localized: "Working"))
        case .none: break
        }
        return parts.joined(separator: ", ")
    }
}

/// The titlebar "…" menu; shown in the sidebar header, or beside the toggle
/// when the sidebar is collapsed.
struct TitlebarActionsMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Menu {
            Menu("New") {
                Button("Agent") { model.showNewAgent = true }
                Button("Terminal") { model.showNewTerminal = true }
                Button("Space") { model.newSpace() }
            }
            Divider()
            Button("Files") { model.openFileManager() }
            Button("Search") { model.showSearch = true }
        } label: {
            TitlebarIconLabel(systemName: "ellipsis", drawsGlass: false)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .modifier(TitlebarGlassMenu())
        .help("Menu")
        .accessibilityLabel("Menu")
    }
}

/// Liquid Glass circle around the whole menu control on macOS 26+.
private struct TitlebarGlassMenu: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular.interactive(), in: .circle)
        } else {
            content
        }
    }
}

struct SpinnerView: View {
    let color: Color
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.12, to: 1)
            .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}
