import Foundation
import HerdrKit
import SwiftUI

enum ConnectionState: Equatable {
    case idle
    case connecting
    case connected(version: String)
    case failed(String)
}

/// Agent kinds offered by the picker. Local manifests are filtered through the
/// login-shell search PATH; remote manifests stay server-owned.
enum AgentCatalogState: Equatable {
    case loading
    case loaded(kinds: [String], paths: [String: String] = [:])
    case failed(String)

    var kinds: [String] {
        guard case .loaded(let kinds, _) = self else { return [] }
        return kinds
    }

    var paths: [String: String] {
        guard case .loaded(_, let paths) = self else { return [:] }
        return paths
    }
}

/// Global pane identity: pane ids like "w1:p1" collide across devices.
struct PaneRef: Hashable {
    let deviceID: UUID
    let paneID: String
}

struct SpaceRef: Hashable {
    let deviceID: UUID
    let workspaceID: String
}

/// Live state for one device's herdr session.
struct DeviceSessionState {
    var connection: ConnectionState = .idle
    var agents: [AgentInfo] = []
    var workspaces: [WorkspaceInfo] = []
    var tabs: [TabInfo] = []
    var panes: [PaneInfo] = []
    var agentCatalog: AgentCatalogState = .loading
    var attachmentCapabilities = AgentAttachmentCapabilityRegistry()
    /// The agent row's context menu, grouped per plugin. Empty until loaded,
    /// or when the device runs no plugin with actions.
    var pluginActions: [PluginActionGroup] = []
}

struct SSHAuthenticationRequest: Identifiable {
    let deviceID: UUID
    let target: String

    var id: UUID { deviceID }
}

/// vertical = panes side by side with a vertical divider (iTerm2's convention).
enum SplitAxis { case vertical, horizontal }

/// Identifies one of the two panes in the ⌘D split. Used for focus tracking and
/// keyboard-driven resize.
enum SplitSide { case agent, shell }

/// A standalone local or SSH shell shown as its own sidebar entry — app-owned,
/// outside any herdr space (unlike the persistent herdr terminals under
/// TERMINALS) and not the ⌘D split.
struct ShellSession: Identifiable, Equatable {
    let id: UUID
    var title: String
    let device: Device
}

/// Per-kind CLI path overrides persisted in user defaults. Empty means automatic
/// lookup on the login-shell search PATH. Invalid paths hide that kind until
/// the user fixes or clears the field — they never silently fall back.
enum AgentBinaryOverrides {
    static let defaultsKey = "agent.binaryOverrides"

    static func load(defaults: UserDefaults = .standard) -> [String: String] {
        (defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:])
            .reduce(into: [:]) { result, entry in
                let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { result[entry.key] = value }
            }
    }

    static func save(_ overrides: [String: String], defaults: UserDefaults = .standard) {
        let trimmed = overrides.reduce(into: [String: String]()) { result, entry in
            let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { result[entry.key] = value }
        }
        if trimmed.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else {
            defaults.set(trimmed, forKey: defaultsKey)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [Device]
    /// All devices stay connected in parallel; this only filters the sidebar.
    @Published var deviceFilter: UUID? {
        didSet {
            // Persisted so a relaunch restores the last selection (nil = All
            // Devices, which removes the key). Every reset path — removing the
            // filtered device, a notification jump to another device — goes
            // through this property, so the stored value can never go stale.
            UserDefaults.standard.set(deviceFilter?.uuidString, forKey: Self.deviceFilterKey)
        }
    }
    private static let deviceFilterKey = "device.filter"
    @Published var sessions: [UUID: DeviceSessionState] = [:]
    @Published var selectedSpace: SpaceRef?
    @Published var selectedPane: PaneRef? {
        didSet {
            // Leaving a finished agent marks it viewed. Staying on it while
            // the turn ends must not swallow the unread flag.
            if let old = oldValue, old != selectedPane {
                unreadAgents.remove(AgentUnreadKey(deviceID: old.deviceID, paneID: old.paneID))
            }
            noteSelectedAttachSession()
            if let pane = selectedPane, let space = spaceRef(of: pane) { lastPaneBySpace[space] = pane }
            if let pane = selectedPane, pane != oldValue {
                snapPaneViewportToBottom(pane)
            }
            if selectedPane != oldValue { Task { @MainActor in await refreshActiveLayout() } }
        }
    }

    /// herdr keeps a server-side viewport per pane that MacHerdr never scrolls
    /// (ghostty owns the scrollback here), yet statusline plugins such as
    /// herdr-agent-quota refuse to update a pane while that viewport is
    /// scrolled up — a stale offset silently freezes the sidebar stats lines.
    /// Showing a pane in MacHerdr means the user is at the live bottom, so snap
    /// herdr's viewport there too. Best effort: a failure changes nothing.
    private func snapPaneViewportToBottom(_ pane: PaneRef) {
        guard let device = device(pane.deviceID) else { return }
        let service = service(for: device)
        Task {
            try? await service.scrollToBottom(paneID: pane.paneID)
        }
    }

    /// Kept-alive attaches: recently viewed agents/terminals stay mounted (hidden)
    /// so switching back preserves their scrollback and running state instead of
    /// re-attaching. Evicted when the pane closes, or when it falls out of the
    /// `keptAliveAttachLimit` most recently viewed.
    @Published var attachSessions: [AttachedEntry] = []

    /// Hidden attaches kept mounted. Each one is a ghostty surface holding two
    /// full-window Metal framebuffers (~28 MB on a large Retina window) whether
    /// shown or not, so an unbounded list grew with every pane ever opened.
    static let keptAliveAttachLimit = 6
    private var attachLastViewed: [PaneRef: UInt64] = [:]
    private var attachViewClock: UInt64 = 0

    /// Branch/ahead per space, local devices only (remote shows none). Keyed by `SpaceEntry.id`.
    @Published private(set) var gitStatuses: [String: GitStatus] = [:]
    private let gitStatusProvider = GitStatusProvider()
    let repoFiles = RepoFiles()
    @Published var editorDrawers = EditorDrawerRegistry()
    /// Markdown/HTML previews, one per tab, sharing the nvim drawer's slot.
    @Published var previews: [EditorDrawerKey: PreviewSession] = [:]

    struct ActiveLayout: Equatable {
        let tabID: String
        let deviceID: UUID
        let tree: SplitTree
        let zoomed: Bool
        let focusedPaneID: String
    }

    /// Layout of the tab the selected pane lives in, nil for single-pane tabs
    /// or when herdr's data cannot be reconciled (the view then shows the
    /// selected pane alone, exactly as before).
    @Published private(set) var activeLayout: ActiveLayout?

    /// Fetches `pane.layout` for the selected pane's tab and makes sure every
    /// pane in it has a kept-alive attach, so the split can show them all.
    func refreshActiveLayout() async {
        let token = layoutGate.begin()
        guard let selected = selectedPane, let device = device(selected.deviceID) else {
            activeLayout = nil
            return
        }
        let service = service(for: device)
        do {
            let layout = try await service.paneLayout(paneID: selected.paneID)
            // A newer request started, or the user moved on mid-flight: drop this reply.
            guard layoutGate.isCurrent(token), selectedPane == selected else { return }
            guard layout.panes.count > 1, let tree = SplitTree.build(from: layout) else {
                activeLayout = nil
                return
            }
            // A zoomed tab shows one pane; do not take the hidden ones over.
            if !layout.zoomed {
                let refs = tree.paneIDs.map { PaneRef(deviceID: device.id, paneID: $0) }
                for ref in refs { ensureAttached(ref) }
                trimAttachSessions(protecting: Set(refs))
            }
            let next = ActiveLayout(
                tabID: layout.tabID, deviceID: device.id, tree: tree,
                zoomed: layout.zoomed, focusedPaneID: layout.focusedPaneID
            )
            if activeLayout != next { activeLayout = next }
        } catch {
            guard layoutGate.isCurrent(token), selectedPane == selected else { return }
            activeLayout = nil
        }
    }

    private var layoutGate = LatestOnlyGate()

    /// The entry a pane currently resolves to: an agent while herdr detects one,
    /// otherwise an ordinary terminal.
    private func currentAttachedEntry(for ref: PaneRef) -> AttachedEntry? {
        guard let device = device(ref.deviceID) else { return nil }
        let state = session(ref.deviceID)
        if let agent = state.agents.first(where: { $0.paneID == ref.paneID }) {
            return .agent(agentEntry(device: device, agent: agent))
        }
        return terminalEntries(for: device).first { $0.pane.paneID == ref.paneID }.map { .terminal($0) }
    }

    private func ensureAttached(_ ref: PaneRef) {
        markAttachViewed(ref)
        if let entry = currentAttachedEntry(for: ref), !attachSessions.contains(where: { $0.id == entry.id }) {
            attachSessions.append(entry)
        }
    }

    private func markAttachViewed(_ ref: PaneRef) {
        attachViewClock += 1
        attachLastViewed[ref] = attachViewClock
    }

    /// Unmounts the least recently viewed attaches beyond `keptAliveAttachLimit`.
    /// Panes on screen — the selection, the visible split, and `protecting` (a
    /// split whose layout is not published yet) — are never evicted. Switching
    /// back to an evicted pane re-attaches it; herdr redraws the screen.
    private func trimAttachSessions(protecting extra: Set<PaneRef> = []) {
        let live = Set(attachSessions.map(\.ref))
        attachLastViewed = attachLastViewed.filter { live.contains($0.key) }
        let excess = attachSessions.count - Self.keptAliveAttachLimit
        guard excess > 0 else { return }
        var onScreen = extra
        if let selectedPane { onScreen.insert(selectedPane) }
        if let layout = activeLayout {
            onScreen.formUnion(layout.tree.paneIDs.map { PaneRef(deviceID: layout.deviceID, paneID: $0) })
        }
        let evicted = Set(
            attachSessions.map(\.ref)
                .filter { !onScreen.contains($0) }
                .sorted { (attachLastViewed[$0] ?? 0) < (attachLastViewed[$1] ?? 0) }
                .prefix(excess)
        )
        guard !evicted.isEmpty else { return }
        attachSessions.removeAll { evicted.contains($0.ref) }
        for ref in evicted { attachLastViewed[ref] = nil }
    }

    /// A pane flips between agent and terminal when its agent exits (or one starts in
    /// a shell). The entry id embeds the kind, so the kept-alive entry goes stale and
    /// the selection matches no child — a blank pane. Swap each stale entry in place
    /// for the one the pane resolves to now, so the terminal re-attaches as a prompt.
    private func reconcileAttachSessions(deviceID: UUID) {
        for index in attachSessions.indices where attachSessions[index].device.id == deviceID {
            let stale = attachSessions[index]
            guard let current = currentAttachedEntry(for: stale.ref), current.id != stale.id else { continue }
            attachSessions[index] = current
        }
    }

    /// A click inside a split pane: keyboard + herdr focus move there.
    func focusLayoutPane(_ paneID: String) {
        guard let layout = activeLayout, selectedPane?.paneID != paneID else { return }
        selectedPane = PaneRef(deviceID: layout.deviceID, paneID: paneID)
        guard let device = device(layout.deviceID) else { return }
        let service = service(for: device)
        Task { @MainActor in try? await service.focusPane(paneID: paneID) }
    }

    func commitSplitRatio(divider: SplitDivider, ratio: Double) {
        guard let layout = activeLayout, let device = device(layout.deviceID) else { return }
        let service = service(for: device)
        let clamped = min(max(ratio, 0.05), 0.95)
        Task { @MainActor in
            do { try await service.setSplitRatio(tabID: layout.tabID, path: divider.path, ratio: clamped) }
            catch { actionError = error.localizedDescription }
            await refreshActiveLayout()
        }
    }

    func gitStatus(for entry: SpaceEntry) -> GitStatus? { gitStatuses[entry.id] }

    func refreshGitStatuses(deviceID: UUID) {
        guard let device = device(deviceID), device.isLocal else { return }
        let state = session(deviceID)
        let candidates: [(workspaceID: String, cwd: String?)] =
            state.agents.map { ($0.workspaceID, $0.cwd) } + state.panes.map { ($0.workspaceID, $0.cwd) }
        let spaces = state.workspaces
        Task { @MainActor in
            var updates: [String: GitStatus] = [:]
            var staleKeys: [String] = []
            for workspace in spaces {
                let key = SpaceEntry(device: device, workspace: workspace).id
                guard let directory = WorkspaceDirectory.resolve(
                    workspaceID: workspace.workspaceID, candidates: candidates
                ), let status = await gitStatusProvider.status(forDirectory: directory)
                else { staleKeys.append(key); continue }
                updates[key] = status
            }
            for key in staleKeys { gitStatuses[key] = nil }
            for (key, status) in updates where gitStatuses[key] != status { gitStatuses[key] = status }
        }
    }

    /// Keeps the selected pane's attach alive so switching back preserves its content.
    /// Runs synchronously inside the `selectedPane` assignment, so the kept-alive entry
    /// is in `attachSessions` in the same update the selection lands in — a separate
    /// onAppear/onChange would leave a one-frame window with no view for the new pane.
    private func noteSelectedAttachSession() {
        guard let entry = selectedAttachedEntry else { return }
        markAttachViewed(entry.ref)
        if !attachSessions.contains(where: { $0.id == entry.id }) {
            attachSessions.append(entry)
        }
        trimAttachSessions()
    }
    /// Finished agents the user has not opened since they flipped to `done`.
    @Published private(set) var unreadAgents: Set<AgentUnreadKey> = []

    @Published var showAddDevice = false
    @Published var showNewAgent = false
    @Published var showNewTerminal = false
    @Published var showSearch = false
    @Published var isFileManagerActive = false
    @Published var shellSplitAxis: SplitAxis?
    /// Set by `reveal` when a jump lands while the ⌘D split is open, and consumed once the
    /// main window is key again. Only an actual jump sets it: dismissing the search with
    /// Escape never calls `reveal`, and the sidebar assigns `selectedPane` directly.
    @Published var pendingSplitAgentFocus = false
    /// The pane that currently holds the keyboard within the ⌘D split. Reset to
    /// the agent side whenever the split closes so reopening it is predictable.
    @Published var activeSplitSide: SplitSide = .agent
    /// Persisted divider ratio for the ⌘D split, shared with the resize commands.
    /// Deliberately not `@AppStorage`: that publishes only from inside a View, so the
    /// menu commands would write UserDefaults without ever redrawing the split.
    @Published var splitRatio: Double =
        UserDefaults.standard.object(forKey: AppModel.splitRatioKey) as? Double ?? 0.5
    {
        didSet { UserDefaults.standard.set(splitRatio, forKey: AppModel.splitRatioKey) }
    }
    static let splitRatioKey = "terminal.splitRatio"
    /// Live terminal views of the ⌘D split, used by menu commands to move focus.
    /// The agent side is resolved from the attach registry by the current selection
    /// (kept-alive attach views persist across switches, so a stored ref would go
    /// stale); the shell side stays a weak ref since the split shell is a single view.
    var splitAgentView: LineBreakTerminalView? {
        selectedAttachedEntry.flatMap { AttachViewRegistry.view(for: $0.id) }
    }
    weak var splitShellView: LineBreakTerminalView?
    /// Standalone terminals. Their views stay alive while deselected —
    /// unlike agents, a local shell has no server side to reattach to.
    @Published var shellSessions: [ShellSession] = []
    @Published var selectedShellID: UUID?
    /// In-window device panel (NSPopover crashes in ViewBridge on macOS 26+ betas).
    @Published var showDevicePanel = false
    @Published var deviceToEdit: Device?
    @Published var sshAuthenticationRequest: SSHAuthenticationRequest?
    @Published var spaceToRename: SpaceEntry?
    @Published var agentToRename: AgentEntry?
    @Published var terminalToRename: TerminalEntry?
    /// The device whose grazr accounts window is open.
    @Published var grazrAccountsDevice: Device?
    /// The install's tailcat client public key ("nodekey:…") for hosts' allow
    /// lists. Loaded on demand, so users without tailcat devices never create one.
    @Published var tailcatClientPublicKey: String?
    /// Transient action failures: shown as an alert, never by tearing down sessions.
    @Published var actionError: String?

    /// A pending destructive close, confirmed via alert before running.
    struct CloseRequest {
        let title: String
        let message: String
        let perform: () -> Void
    }
    @Published var closeRequest: CloseRequest?

    private let store = DeviceStore()
    private var services: [UUID: HerdrService] = [:]
    private var sessionTasks: [UUID: Task<Void, Never>] = [:]
    private var refreshDebounces: [UUID: Task<Void, Never>] = [:]
    private var refreshDebounceTokens: [UUID: UUID] = [:]
    private var refreshDebouncePending: Set<UUID> = []
    private var snapshotRefreshTasks: [UUID: Task<Bool, Never>] = [:]
    private var snapshotRefreshTokens: [UUID: UUID] = [:]
    private var refreshRequested: Set<UUID> = []
    private var statusGenerations: [UUID: UInt64] = [:]
    private var previousStatuses: [UUID: [String: AgentStatus]] = [:]

    init() {
        let loaded = DeviceStore().load()
        devices = loaded
        // Restore the device filter only if that device still exists;
        // otherwise fall back to All Devices.
        if let raw = UserDefaults.standard.string(forKey: Self.deviceFilterKey),
           let id = UUID(uuidString: raw),
           loaded.contains(where: { $0.id == id }) {
            deviceFilter = id
        }
    }

    // MARK: - Derived state

    func device(_ id: UUID) -> Device? {
        devices.first { $0.id == id }
    }

    func session(_ id: UUID) -> DeviceSessionState {
        sessions[id] ?? DeviceSessionState()
    }

    /// The herdr version the device's server reported on its last successful
    /// ping; the terminal attach uses it to pick a protocol-matching CLI binary.
    func serverVersion(deviceID: UUID) -> String? {
        if case .connected(let version) = session(deviceID).connection { return version }
        return nil
    }

    /// Resolved from the live agent list, not the kept-alive attach entry: an
    /// agent started here is attached before herdr has detected its kind, and
    /// that entry's snapshot would keep it kindless (plain-text paste) forever.
    /// The live record wins even while its kind is nil, so an agent restarted
    /// in the same pane does not inherit the previous agent's paste policy.
    func attachmentCapabilities(for entry: AgentEntry) -> AgentAttachmentCapabilities? {
        let session = session(entry.device.id)
        let agentKind = session.agents.first { $0.paneID == entry.agent.paneID }?.agentKindRaw
        return session.attachmentCapabilities.capabilities(for: agentKind)
    }

    var filteredDevice: Device? {
        deviceFilter.flatMap(device)
    }

    private var devicesInScope: [Device] {
        if let filtered = filteredDevice { return [filtered] }
        return devices
    }

    /// Aggregate connection state for the current scope (footer dot, hints).
    var connection: ConnectionState {
        let states = devicesInScope.map { session($0.id).connection }
        if let failed = states.first(where: { if case .failed = $0 { return true }; return false }) {
            return failed
        }
        if states.contains(.connecting) { return .connecting }
        if !states.isEmpty, states.allSatisfy({ if case .connected = $0 { return true }; return false }) {
            return .connected(version: "")
        }
        return states.isEmpty ? .idle : .connecting
    }

    struct AgentEntry: Identifiable {
        let device: Device
        let agent: AgentInfo
        let tabLabel: String?

        var id: String { "\(device.id.uuidString)-\(agent.paneID)" }
        var ref: PaneRef { PaneRef(deviceID: device.id, paneID: agent.paneID) }
        var title: String { agent.title(tabLabel: tabLabel) }
    }

    func agentEntry(device: Device, agent: AgentInfo) -> AgentEntry {
        AgentEntry(
            device: device,
            agent: agent,
            tabLabel: session(device.id).tabs.first { $0.tabID == agent.tabID }?.customLabel
        )
    }

    struct TerminalEntry: Identifiable {
        let device: Device
        let pane: PaneInfo
        let tab: TabInfo?
        let terminalID: String

        var id: String { "\(device.id.uuidString)-\(pane.paneID)" }
        var ref: PaneRef { PaneRef(deviceID: device.id, paneID: pane.paneID) }
        var tabID: String? { pane.tabID ?? tab?.tabID }

        var title: String {
            // User tab labels must win or `tab.rename` is invisible behind OSC.
            if let label = tab?.customLabel {
                return label
            }
            if let terminalTitle = pane.terminalTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
               !terminalTitle.isEmpty {
                return terminalTitle
            }
            if let cwd = pane.cwd, !cwd.isEmpty {
                let basename = URL(fileURLWithPath: cwd).lastPathComponent
                if !basename.isEmpty { return basename }
            }
            return String(localized: "Terminal")
        }
    }

    enum AttachedEntry: Identifiable {
        case agent(AgentEntry)
        case terminal(TerminalEntry)

        var id: String {
            switch self {
            case .agent(let entry): return "agent-\(entry.id)"
            case .terminal(let entry): return "terminal-\(entry.id)"
            }
        }

        var device: Device {
            switch self {
            case .agent(let entry): return entry.device
            case .terminal(let entry): return entry.device
            }
        }

        var ref: PaneRef {
            switch self {
            case .agent(let entry): return entry.ref
            case .terminal(let entry): return entry.ref
            }
        }

        var workspaceID: String {
            switch self {
            case .agent(let entry): return entry.agent.workspaceID
            case .terminal(let entry): return entry.pane.workspaceID
            }
        }

        var attachTarget: TerminalAttachTarget {
            switch self {
            case .agent(let entry): return .agent(paneID: entry.agent.paneID)
            case .terminal(let entry): return .terminal(terminalID: entry.terminalID)
            }
        }
    }

    struct SpaceEntry: Identifiable {
        let device: Device
        let workspace: WorkspaceInfo

        var id: String { "\(device.id.uuidString)-\(workspace.workspaceID)" }
        var ref: SpaceRef { SpaceRef(deviceID: device.id, workspaceID: workspace.workspaceID) }
    }

    var visibleSpaces: [SpaceEntry] {
        devicesInScope.flatMap { device in
            session(device.id).workspaces.map { SpaceEntry(device: device, workspace: $0) }
        }
    }

    /// Agents across the scope, filtered by selected space, in herdr tab order
    /// (device → workspace → snapshot array) so sidebar drag matches the TUI.
    var visibleAgents: [AgentEntry] {
        guard let space = selectedSpace else { return agentsInScope }
        return agentsInScope.filter {
            $0.device.id == space.deviceID && $0.agent.workspaceID == space.workspaceID
        }
    }

    /// Every agent on the devices in scope, whatever space is selected — what
    /// the sidebar's Agents section lists.
    var agentsInScope: [AgentEntry] {
        let entries = devicesInScope.flatMap { device in
            session(device.id).agents.map { agentEntry(device: device, agent: $0) }
        }
        let deviceRank = Dictionary(uniqueKeysWithValues: devicesInScope.enumerated().map { ($1.id, $0) })
        return entries.sorted { lhs, rhs in
            let d0 = deviceRank[lhs.device.id] ?? Int.max
            let d1 = deviceRank[rhs.device.id] ?? Int.max
            if d0 != d1 { return d0 < d1 }
            let w0 = workspaceRank(deviceID: lhs.device.id, workspaceID: lhs.agent.workspaceID)
            let w1 = workspaceRank(deviceID: rhs.device.id, workspaceID: rhs.agent.workspaceID)
            if w0 != w1 { return w0 < w1 }
            return tabRank(deviceID: lhs.device.id, tabID: lhs.agent.tabID)
                < tabRank(deviceID: rhs.device.id, tabID: rhs.agent.tabID)
        }
    }

    func terminalEntries(for device: Device) -> [TerminalEntry] {
        let state = session(device.id)
        let tabsByID = Dictionary(uniqueKeysWithValues: state.tabs.map { ($0.tabID, $0) })
        return state.panes.compactMap { pane in
            guard let terminalID = pane.terminalID else { return nil }
            return TerminalEntry(
                device: device,
                pane: pane,
                tab: pane.tabID.flatMap { tabsByID[$0] },
                terminalID: terminalID
            )
        }
    }

    var visibleTerminals: [TerminalEntry] {
        var entries = devicesInScope.flatMap { terminalEntries(for: $0) }
        if let space = selectedSpace {
            entries = entries.filter {
                $0.device.id == space.deviceID && $0.pane.workspaceID == space.workspaceID
            }
        }
        let deviceRank = Dictionary(uniqueKeysWithValues: devicesInScope.enumerated().map { ($1.id, $0) })
        return entries.sorted { lhs, rhs in
            let d0 = deviceRank[lhs.device.id] ?? Int.max
            let d1 = deviceRank[rhs.device.id] ?? Int.max
            if d0 != d1 { return d0 < d1 }
            let w0 = workspaceRank(deviceID: lhs.device.id, workspaceID: lhs.pane.workspaceID)
            let w1 = workspaceRank(deviceID: rhs.device.id, workspaceID: rhs.pane.workspaceID)
            if w0 != w1 { return w0 < w1 }
            return tabRank(deviceID: lhs.device.id, tabID: lhs.tabID)
                < tabRank(deviceID: rhs.device.id, tabID: rhs.tabID)
        }
    }

    func isUnread(_ entry: AgentEntry) -> Bool {
        unreadAgents.contains(AgentUnreadKey(deviceID: entry.device.id, paneID: entry.agent.paneID))
    }

    func attention(in entry: SpaceEntry) -> SpaceAttention {
        let agents = session(entry.device.id).agents.filter {
            $0.workspaceID == entry.workspace.workspaceID
        }
        return SpaceAttention.rollup(agents.map {
            (
                status: $0.status,
                unreadDone: unreadAgents.contains(
                    AgentUnreadKey(deviceID: entry.device.id, paneID: $0.paneID)
                )
            )
        })
    }

    var scopeAttention: SpaceAttention {
        SpaceAttention.rollup(devicesInScope.flatMap { device in
            session(device.id).agents.map {
                (
                    status: $0.status,
                    unreadDone: unreadAgents.contains(
                        AgentUnreadKey(deviceID: device.id, paneID: $0.paneID)
                    )
                )
            }
        })
    }

    private func workspaceRank(deviceID: UUID, workspaceID: String) -> Int {
        session(deviceID).workspaces.firstIndex { $0.workspaceID == workspaceID } ?? Int.max
    }

    private func tabRank(deviceID: UUID, tabID: String?) -> Int {
        guard let tabID else { return Int.max }
        return session(deviceID).tabs.firstIndex { $0.tabID == tabID } ?? Int.max
    }

    private func orderedTabIDs(deviceID: UUID, workspaceID: String) -> [String] {
        session(deviceID).tabs
            .filter { $0.workspaceID == workspaceID }
            .map(\.tabID)
    }

    var scopeAgentCount: Int {
        devicesInScope.reduce(0) { $0 + session($1.id).agents.count }
    }

    var selectedEntry: AgentEntry? {
        guard let selected = selectedPane, let device = device(selected.deviceID) else { return nil }
        guard let agent = session(selected.deviceID).agents.first(where: { $0.paneID == selected.paneID })
        else { return nil }
        return agentEntry(device: device, agent: agent)
    }

    var selectedTerminalEntry: TerminalEntry? {
        guard let selected = selectedPane, let device = device(selected.deviceID) else { return nil }
        return terminalEntries(for: device).first { $0.pane.paneID == selected.paneID }
    }

    var selectedAttachedEntry: AttachedEntry? {
        if let selectedEntry { return .agent(selectedEntry) }
        if let selectedTerminalEntry { return .terminal(selectedTerminalEntry) }
        return nil
    }

    private var firstVisiblePaneRef: PaneRef? {
        visibleAgents.first?.ref ?? visibleTerminals.first?.ref
    }

    func agentCount(in entry: SpaceEntry) -> Int {
        session(entry.device.id).agents.filter { $0.workspaceID == entry.workspace.workspaceID }.count
    }

    func spaceName(deviceID: UUID, workspaceID: String) -> String {
        session(deviceID).workspaces.first { $0.workspaceID == workspaceID }?.label ?? workspaceID
    }

    /// Show device badges only when more than one device is configured.
    var showsDeviceBadges: Bool {
        devices.count > 1
    }

    /// Badges on sidebar/titlebar rows are scoped by the device filter: with a
    /// single device selected every row belongs to it, so the badge says
    /// nothing. ⌘K search and the New Agent/Space device pickers stay on
    /// `showsDeviceBadges` — search crosses all devices regardless of the
    /// filter, and the pickers must stay reachable while filtered.
    var showsRowDeviceBadges: Bool {
        devices.count > 1 && deviceFilter == nil
    }

    // MARK: - Selection

    func selectSpace(_ ref: SpaceRef?) {
        isFileManagerActive = false
        selectedSpace = ref
        selectedShellID = nil
        if let entry = selectedAttachedEntry {
            if ref == nil { return }
            if entry.device.id == ref!.deviceID && entry.workspaceID == ref!.workspaceID { return }
        }
        if let ref, let landing = landingPane(in: ref) {
            let wasRemembered = lastPaneBySpace[ref] == landing
            selectedPane = landing
            if !wasRemembered { landOnFocusedPane(of: landing) }
            return
        }
        selectedPane = preferredVisibleAgent()?.ref ?? firstVisiblePaneRef
    }

    /// Where the user last was in each space, so switching back returns there
    /// instead of the first tab's first pane.
    private var lastPaneBySpace: [SpaceRef: PaneRef] = [:]

    private func spaceRef(of pane: PaneRef) -> SpaceRef? {
        let state = session(pane.deviceID)
        let workspaceID = state.agents.first { $0.paneID == pane.paneID }?.workspaceID
            ?? state.panes.first { $0.paneID == pane.paneID }?.workspaceID
        return workspaceID.map { SpaceRef(deviceID: pane.deviceID, workspaceID: $0) }
    }

    /// The remembered pane, else a pane in herdr's active tab for the space.
    private func landingPane(in space: SpaceRef) -> PaneRef? {
        let state = session(space.deviceID)
        let agents = state.agents.filter { $0.workspaceID == space.workspaceID }
        let terminals = state.panes.filter { $0.workspaceID == space.workspaceID }
        let paneID = SpaceLanding.paneToSelect(
            remembered: lastPaneBySpace[space]?.paneID,
            existingPaneIDs: Set(agents.map(\.paneID) + terminals.map(\.paneID)),
            activeTabID: state.workspaces.first { $0.workspaceID == space.workspaceID }?.activeTabID,
            agentPanes: agents.map { ($0.paneID, $0.tabID) },
            terminalPanes: terminals.map { ($0.paneID, $0.tabID) }
        )
        return paneID.map { PaneRef(deviceID: space.deviceID, paneID: $0) }
    }

    /// herdr remembers which pane has focus inside a tab, but only `pane.layout`
    /// says so. Move the selection there unless the user has already moved on.
    private func landOnFocusedPane(of landing: PaneRef) {
        guard let device = device(landing.deviceID) else { return }
        let service = service(for: device)
        Task { @MainActor in
            guard let layout = try? await service.paneLayout(paneID: landing.paneID),
                  selectedPane == landing,
                  layout.focusedPaneID != landing.paneID,
                  layout.panes.contains(where: { $0.paneID == layout.focusedPaneID })
            else { return }
            let state = session(landing.deviceID)
            guard state.agents.contains(where: { $0.paneID == layout.focusedPaneID })
                || state.panes.contains(where: { $0.paneID == layout.focusedPaneID })
            else { return }
            selectedPane = PaneRef(deviceID: landing.deviceID, paneID: layout.focusedPaneID)
        }
    }

    func setDeviceFilter(_ id: UUID?) {
        deviceFilter = id
        if let id, let space = selectedSpace, space.deviceID != id {
            selectedSpace = nil
        }
        if let id, let selected = selectedPane, selected.deviceID != id {
            selectedPane = preferredVisibleAgent()?.ref ?? firstVisiblePaneRef
        }
    }

    /// When jumping into a space, land on whoever still needs a look — not
    /// merely the first tab.
    private func preferredVisibleAgent() -> AgentEntry? {
        let agents = visibleAgents
        if let blocked = agents.first(where: { $0.agent.status == .blocked }) { return blocked }
        if let unread = agents.first(where: { $0.agent.status == .done && isUnread($0) }) {
            return unread
        }
        if let working = agents.first(where: { $0.agent.status == .working }) { return working }
        return agents.first
    }

    /// Jump target used by the search sheet and by notification clicks.
    func reveal(_ ref: PaneRef) {
        isFileManagerActive = false
        if let filter = deviceFilter, filter != ref.deviceID {
            deviceFilter = nil
        }
        selectedSpace = nil
        selectedPane = ref
        selectedShellID = nil
        // Only the search sheet needs the deferred request: its dismissal restores the
        // parent window's previous responder after the view tree has asked for focus.
        // `showSearch` is still true here — SearchView calls this before dismissing.
        //
        // Notification clicks deliberately do NOT arm it. With the app already frontmost
        // there may be no key-window transition at all, so nothing would consume the flag
        // and a later unrelated activation would cash it in, pulling the keyboard out of
        // the shell. Those clicks get focus from the recreated attach and from the
        // entry-change request instead.
        if shellSplitAxis != nil, showSearch { pendingSplitAgentFocus = true }
    }

    // MARK: - Shell terminals

    func openFileManager() {
        isFileManagerActive = true
        selectedShellID = nil
    }

    func selectAgent(_ ref: PaneRef) {
        isFileManagerActive = false
        selectedPane = ref
        selectedShellID = nil
    }

    // MARK: - Tabs

    func tabs(in space: SpaceRef) -> [TabInfo] {
        session(space.deviceID).tabs.filter { $0.workspaceID == space.workspaceID }
    }

    /// The space whose tab bar is shown: the selected pane's space (the sidebar
    /// lists agents from every space, so the pane can be outside the selected
    /// space), else the explicit space selection.
    var tabBarSpace: SpaceRef? {
        if let pane = selectedPane {
            let state = session(pane.deviceID)
            let workspaceID = state.agents.first { $0.paneID == pane.paneID }?.workspaceID
                ?? state.panes.first { $0.paneID == pane.paneID }?.workspaceID
            if let workspaceID { return SpaceRef(deviceID: pane.deviceID, workspaceID: workspaceID) }
        }
        return selectedSpace
    }

    func activeTabID(in space: SpaceRef) -> String? {
        let state = session(space.deviceID)
        let selectedTab: String? = selectedPane.flatMap { pane in
            guard pane.deviceID == space.deviceID else { return nil }
            return state.agents.first { $0.paneID == pane.paneID }?.tabID
                ?? state.panes.first { $0.paneID == pane.paneID }?.tabID
        }
        return TabSelection.activeTabID(
            selectedPaneTabID: selectedTab,
            workspaceActiveTabID: state.workspaces.first { $0.workspaceID == space.workspaceID }?.activeTabID,
            tabIDs: tabs(in: space).map(\.tabID)
        )
    }

    func selectTab(_ tab: TabInfo, deviceID: UUID) {
        let state = session(deviceID)
        if let paneID = TabSelection.paneToSelect(
            tabID: tab.tabID,
            agentPanes: state.agents.map { ($0.paneID, $0.tabID) },
            terminalPanes: state.panes.map { ($0.paneID, $0.tabID) }
        ) {
            selectAgent(PaneRef(deviceID: deviceID, paneID: paneID))
        }
        guard let device = device(deviceID) else { return }
        let service = service(for: device)
        Task { @MainActor in
            do { try await service.focusTab(tabID: tab.tabID) } catch {
                actionError = error.localizedDescription
            }
        }
    }

    func newTab(in space: SpaceRef) {
        guard let device = device(space.deviceID) else { return }
        let service = service(for: device)
        Task { @MainActor in
            do {
                let paneID = try await service.createTab(workspaceID: space.workspaceID, cwd: nil, label: nil)
                _ = await refreshImmediately(space.deviceID)
                selectAgent(PaneRef(deviceID: space.deviceID, paneID: paneID))
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    // MARK: - File search (⌘K)

    /// Where ⌘K looks for files: the selected pane's cwd, else the space's. Local
    /// devices only — git runs on this Mac.
    var fileSearchTarget: (space: SpaceRef, directory: String)? {
        guard editorDrawerContext != nil, let space = tabBarSpace,
              device(space.deviceID)?.isLocal == true
        else { return nil }
        let state = session(space.deviceID)
        let selectedCwd = selectedPane.flatMap { ref in
            state.agents.first { $0.paneID == ref.paneID }?.cwd
                ?? state.panes.first { $0.paneID == ref.paneID }?.cwd
        }
        let candidates: [(workspaceID: String, cwd: String?)] =
            state.agents.map { ($0.workspaceID, $0.cwd) } + state.panes.map { ($0.workspaceID, $0.cwd) }
        guard let directory = [selectedCwd, WorkspaceDirectory.resolve(
            workspaceID: space.workspaceID, candidates: candidates
        )].compactMap({ $0 }).first(where: { !$0.isEmpty })
        else { return nil }
        return (space, directory)
    }

    /// The tab the selected pane lives in, for local devices only.
    var selectedTabKey: EditorDrawerKey? {
        guard let ref = selectedPane, device(ref.deviceID)?.isLocal == true else { return nil }
        let state = session(ref.deviceID)
        let tabID: String? = state.agents.first { $0.paneID == ref.paneID }?.tabID
            ?? state.panes.first { $0.paneID == ref.paneID }?.tabID
        return tabID.map { EditorDrawerKey(deviceID: ref.deviceID, tabID: $0) }
    }

    /// The tab whose drawer the user can currently see and type into: an attached herdr
    /// pane is selected and neither a standalone shell nor the file manager covers it.
    /// Everything that shows, focuses, or opens into a drawer is gated on this, so a
    /// drawer is never given the keyboard while invisible.
    var editorDrawerContext: EditorDrawerKey? {
        guard selectedShellID == nil, !isFileManagerActive, selectedAttachedEntry != nil
        else { return nil }
        return selectedTabKey
    }

    /// The preview to draw right now; while it shows, the nvim drawer stays hidden.
    var visiblePreview: PreviewSession? {
        guard let key = editorDrawerContext, let preview = previews[key], preview.isVisible
        else { return nil }
        return preview
    }

    /// The drawer to draw right now.
    var visibleEditorDrawerID: UUID? {
        guard visiblePreview == nil, let key = editorDrawerContext,
              let session = editorDrawers.session(for: key), session.isVisible
        else { return nil }
        return session.id
    }

    /// ⌘E: hide the tab's drawer if it is showing, else show it (starting plain
    /// nvim in the pane's directory when the tab has none).
    func toggleEditorDrawer() {
        guard let key = editorDrawerContext, let target = fileSearchTarget else { return }
        if previews[key]?.isVisible == true {
            closePreview()
            return
        }
        if let session = editorDrawers.session(for: key), session.isVisible {
            editorDrawers.hide(key)
            if let entry = selectedAttachedEntry { AttachViewRegistry.focus(entry.id) }
            return
        }
        let shown = editorDrawers.show(
            key, directory: target.directory, initialFile: nil, socketDirectory: NSTemporaryDirectory()
        )
        ShellViewRegistry.focus(shown.session.id)
    }

    /// Opens `path` in the tab's drawer: a fresh nvim when there is none, otherwise
    /// the running one over its RPC socket. `space` is kept for the caller's sake;
    /// the drawer follows the selected pane's tab.
    func openFile(path: String, in space: SpaceRef, directory: String) {
        guard let key = editorDrawerContext else { return }
        if PreviewSession.handles(path) {
            openPreview(path: path, key: key)
            return
        }
        previews[key]?.isVisible = false
        guard let existing = editorDrawers.session(for: key) else {
            launchDrawer(key: key, directory: directory, file: path)
            return
        }
        editorDrawers.show(key, directory: existing.directory, initialFile: nil, socketDirectory: NSTemporaryDirectory())
        Task { @MainActor in
            guard let binary = await NvimClient.resolveBinary() else {
                actionError = String(localized: "nvim was not found in your shell PATH.")
                return
            }
            // The socket may not exist yet (drawer just started) and a busy nvim answers
            // late; the session is only dropped when its process exits
            // (`editorDrawerExited`), never because an RPC failed.
            switch await NvimClient.openFileWhenReady(
                binary: binary, socketPath: existing.socketPath, path: path
            ) {
            case .opened:
                ShellViewRegistry.focus(existing.id)
            case .unreachable:
                actionError = String(localized: "nvim did not respond. It may be busy or still starting.")
            case .rejected(let message):
                // Alive but refused (e.g. unsaved buffer with 'nohidden'): keep it.
                actionError = String(localized: "nvim could not open the file: \(message)")
            }
        }
    }

    /// A split is zoomed — herdr's own pane zoom, or a zoomed preview — so the app shows
    /// only that split and the sidebar steps aside.
    var isSplitZoomed: Bool {
        if visiblePreview?.isZoomed == true { return true }
        if !isFileManagerActive, localZoomKey != nil, localZoomKey == currentZoomKey { return true }
        return selectedShellID == nil && !isFileManagerActive && selectedAttachedEntry != nil
            && activeLayout?.zoomed == true
    }

    /// App-side zoom for a terminal herdr cannot zoom (a single-pane tab or a standalone
    /// shell): it only hides the sidebar. Keyed on the selection, so switching away
    /// and back to another terminal never inherits it.
    @Published private var localZoomKey: String?

    private var currentZoomKey: String? {
        if let shell = selectedShellID { return "shell-\(shell)" }
        return selectedPane.map { "pane-\($0.deviceID)-\($0.paneID)" }
    }

    private func toggleLocalZoom() {
        guard !isFileManagerActive, let key = currentZoomKey else { return }
        localZoomKey = localZoomKey == key ? nil : key
    }

    /// The preview holds the keyboard, so the terminal beside it dims.
    @Published var previewHasKeyboard = false

    var dimsTerminalForPreview: Bool { visiblePreview != nil && previewHasKeyboard }

    func togglePreviewZoom() {
        guard let key = editorDrawerContext, previews[key]?.isVisible == true else { return }
        previews[key]?.isZoomed.toggle()
    }

    /// Hides the visible preview and returns the keyboard to the herdr pane.
    func closePreview() {
        guard let key = editorDrawerContext else { return }
        previews[key]?.isVisible = false
        previews[key]?.isZoomed = false
        previewHasKeyboard = false
        if let entry = selectedAttachedEntry { AttachViewRegistry.focus(entry.id) }
    }

    /// A link inside the preview pointed at another local markdown/HTML file.
    func navigatePreview(to path: String) {
        guard let key = editorDrawerContext else { return }
        previews[key]?.path = path
    }

    /// ⌘K on a markdown/HTML file: render it in the drawer slot instead of nvim.
    private func openPreview(path: String, key: EditorDrawerKey) {
        if var existing = previews[key] {
            existing.path = path
            existing.isVisible = true
            previews[key] = existing
        } else {
            previews[key] = PreviewSession(key: key, path: path, isVisible: true)
        }
        if let entry = selectedAttachedEntry { AttachViewRegistry.focus(entry.id) }
    }

    private func launchDrawer(key: EditorDrawerKey, directory: String, file: String?) {
        let shown = editorDrawers.show(
            key, directory: directory, initialFile: file, socketDirectory: NSTemporaryDirectory()
        )
        ShellViewRegistry.focus(shown.session.id)
    }

    private func discardDrawer(id: UUID) {
        guard let removed = editorDrawers.remove(id: id) else { return }
        try? FileManager.default.removeItem(atPath: removed.socketPath)
    }

    /// The drawer's nvim ended (`:q`, crash, or missing binary).
    func editorDrawerExited(_ id: UUID, code: Int32?) {
        discardDrawer(id: id)
        if code == 127 {
            actionError = String(localized: "nvim was not found in your shell PATH.")
        }
    }

    // MARK: - herdr keybindings

    /// Set by a rename-tab key or a double-click; `SpaceTabBar` shows the dialog.
    @Published var tabToRename: TabInfo?
    /// Installed by the view that owns the sidebar state.
    var toggleSidebarHandler: (() -> Void)?

    /// Runs one herdr action (from a prefix chord or a direct chord) against
    /// the current selection.
    func perform(_ action: HerdrAction, index: Int?) {
        let space = tabBarSpace
        switch action {
        case .switchTab:
            guard let space, let index, index >= 1 else { return }
            let tabs = tabs(in: space)
            if index <= tabs.count { selectTab(tabs[index - 1], deviceID: space.deviceID) }
        case .nextTab, .previousTab:
            guard let space else { return }
            let tabs = tabs(in: space)
            guard tabs.count > 1 else { return }
            let current = activeTabID(in: space).flatMap { id in tabs.firstIndex { $0.tabID == id } } ?? 0
            let step = action == .nextTab ? 1 : tabs.count - 1
            selectTab(tabs[(current + step) % tabs.count], deviceID: space.deviceID)
        case .newTab:
            if let space { newTab(in: space) }
        case .renameTab:
            if let space, let id = activeTabID(in: space) {
                tabToRename = tabs(in: space).first { $0.tabID == id }
            }
        case .closeTab:
            if let space, let id = activeTabID(in: space), tabs(in: space).count > 1,
               let tab = tabs(in: space).first(where: { $0.tabID == id }) {
                requestCloseTab(tab, deviceID: space.deviceID)
            }
        case .workspacePicker, .goto:
            // The ⌘K search sheet lists spaces, agents and terminals across devices.
            showSearch = true
        case .newWorkspace:
            newSpace()
        case .renameWorkspace:
            spaceToRename = visibleSpaces.first { $0.ref == space }
        case .closeWorkspace:
            if let entry = visibleSpaces.first(where: { $0.ref == space }) { requestCloseSpace(entry) }
        case .switchWorkspace:
            let spaces = visibleSpaces
            if let index, index >= 1, index <= spaces.count { selectSpace(spaces[index - 1].ref) }
        case .nextWorkspace, .previousWorkspace:
            let spaces = visibleSpaces
            guard spaces.count > 1 else { return }
            let current = spaces.firstIndex { $0.ref == space } ?? 0
            let step = action == .nextWorkspace ? 1 : spaces.count - 1
            selectSpace(spaces[(current + step) % spaces.count].ref)
        case .focusPaneLeft: focusNeighbor("left")
        case .focusPaneRight: focusNeighbor("right")
        case .focusPaneUp: focusNeighbor("up")
        case .focusPaneDown: focusNeighbor("down")
        case .cyclePaneNext, .cyclePanePrevious:
            guard let layout = activeLayout, let selected = selectedPane,
                  let at = layout.tree.paneIDs.firstIndex(of: selected.paneID) else { return }
            let ids = layout.tree.paneIDs
            let step = action == .cyclePaneNext ? 1 : ids.count - 1
            focusLayoutPane(ids[(at + step) % ids.count])
        case .zoom:
            if visiblePreview != nil, PreviewZoom.previewHasFocus || PreviewFinder.shared.isVisible {
                togglePreviewZoom() // the focused split is the preview, not a herdr pane
                return
            }
            if selectedShellID != nil || activeLayout == nil {
                toggleLocalZoom() // nothing for herdr to zoom: single pane or app-owned shell
                return
            }
            guard let selected = selectedPane, let device = device(selected.deviceID) else { return }
            let service = service(for: device)
            Task { @MainActor in
                do { try await service.zoomPane(paneID: selected.paneID) } catch {
                    actionError = error.localizedDescription
                }
                await refreshActiveLayout()
            }
        case .closePane:
            guard let selected = selectedPane, let entry = selectedAttachedEntry else { return }
            switch entry {
            case .agent(let agent): requestClosePane(selected, name: agent.title)
            case .terminal(let terminal): requestClosePane(selected, name: terminal.title)
            }
        case .splitVertical: splitSelected(direction: "right")
        case .splitHorizontal: splitSelected(direction: "down")
        case .toggleSidebar: toggleSidebarHandler?()
        }
    }

    private func focusNeighbor(_ direction: String) {
        guard let selected = selectedPane, let device = device(selected.deviceID) else { return }
        let service = service(for: device)
        Task { @MainActor in
            guard selectedPane == selected,
                  let focused = try? await service.focusPane(paneID: selected.paneID, direction: direction)
            else { return }
            // herdr already moved its own focus; only the selection follows.
            selectedPane = PaneRef(deviceID: selected.deviceID, paneID: focused)
        }
    }

    private func splitSelected(direction: String) {
        guard let selected = selectedPane, let device = device(selected.deviceID) else { return }
        let service = service(for: device)
        Task { @MainActor in
            do {
                let created = try await service.splitPane(paneID: selected.paneID, direction: direction)
                _ = await refreshImmediately(selected.deviceID)
                if let created { selectedPane = PaneRef(deviceID: selected.deviceID, paneID: created) }
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    func requestCloseTab(_ tab: TabInfo, deviceID: UUID) {
        closeRequest = CloseRequest(
            title: String(localized: "Close tab \"\(tab.customLabel ?? tab.label)\"?"),
            message: String(localized: "Every pane in the tab and whatever is running inside will be terminated.")
        ) { [weak self] in
            self?.closeTab(tab, deviceID: deviceID)
        }
    }

    private func closeTab(_ tab: TabInfo, deviceID: UUID) {
        guard let device = device(deviceID) else { return }
        let service = service(for: device)
        Task { @MainActor in
            do {
                try await service.closeTab(tabID: tab.tabID)
                _ = await refreshImmediately(deviceID)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    var selectedShell: ShellSession? {
        selectedShellID.flatMap { id in shellSessions.first { $0.id == id } }
    }

    /// Every click opens another terminal, like New Agent opens another agent.
    func newShellSession(on device: Device) {
        let n = shellSessions.count + 1
        let session = ShellSession(
            id: UUID(),
            title: String(localized: "Terminal \(n)"),
            device: device
        )
        shellSessions.append(session)
        selectShell(session.id)
    }

    func selectShell(_ id: UUID) {
        isFileManagerActive = false
        selectedShellID = id
        ShellViewRegistry.focus(id)
    }

    func closeShellSession(_ id: UUID) {
        shellSessions.removeAll { $0.id == id }
        if selectedShellID == id {
            selectedShellID = shellSessions.last?.id
            if let remaining = selectedShellID { ShellViewRegistry.focus(remaining) }
        }
    }

    // MARK: - Lifecycle

    func start() {
        EditorDrawerRegistry.removeStaleSockets(in: NSTemporaryDirectory())
        NotificationManager.shared.setup(model: self)
        // Finder-launched apps have launchd's PATH. Capture the login +
        // interactive shell environment on a background thread once; New Agent
        // lookup, herdr spawn, and terminal attach all read the same snapshot.
        Task.detached(priority: .utility) {
            _ = await ShellEnvironment.ensure()
        }
        for device in devices {
            startSession(device)
            probeOSIfNeeded(device)
        }
        // Surface any herdr named sessions running now (issue #81).
        refreshNamedSessions()
    }

    func service(for device: Device) -> HerdrService {
        if let service = services[device.id] { return service }
        // Only the built-in Local device (no socket override) may auto-start a
        // herdr server. A named-session device points at an existing session's
        // socket; that server is the user's to run, and auto-start would spawn a
        // default-session server on the wrong socket.
        let service = HerdrService(
            device: device,
            autoStartLocalServer: device.isLocal && device.socketPath == nil
        )
        services[device.id] = service
        return service
    }

    /// Merges live herdr named sessions in as extra Local devices (issue #81)
    /// and drops ones whose session went away. Discovered, never persisted:
    /// named sessions come and go, unlike user-added SSH/tailcat devices.
    func refreshNamedSessions() {
        let discovered = HerdrSessionDiscovery.namedSessions()
            .map(HerdrSessionDiscovery.device(for:))
        let discoveredIDs = Set(discovered.map(\.id))
        // Named-session devices already present, by id.
        let existingIDs = Set(devices.filter(\.isNamedSession).map(\.id))

        for device in discovered where !existingIDs.contains(device.id) {
            devices.append(device)
            startSession(device)
            probeOSIfNeeded(device)
        }
        // Remove named-session devices whose session is gone.
        for device in devices where device.isNamedSession && !discoveredIDs.contains(device.id) {
            stopSession(device.id)
            attachSessions.removeAll { $0.device.id == device.id }
            devices.removeAll { $0.id == device.id }
            if deviceFilter == device.id { deviceFilter = nil }
            if selectedSpace?.deviceID == device.id { selectedSpace = nil }
            if selectedPane?.deviceID == device.id {
                selectedPane = preferredVisibleAgent()?.ref ?? firstVisiblePaneRef
            }
        }
    }

    /// Runs one device's session: connect, snapshot, event stream, and reconnect
    /// with exponential backoff (1s → 30s) whenever the connection drops.
    private func startSession(_ device: Device) {
        sessionTasks[device.id]?.cancel()
        if sessions[device.id] == nil { sessions[device.id] = DeviceSessionState() }
        let service = service(for: device)
        sessionTasks[device.id] = Task { [weak self] in
            var backoff: Double = 1
            while !Task.isCancelled {
                guard let self else { return }
                self.sessions[device.id]?.connection = .connecting
                do {
                    let pong = try await service.connect()
                    self.sessions[device.id]?.connection = .connected(version: pong.version)
                    backoff = 1
                    // Prefer the tunnel's platform sniff (Windows vs Unix) so attach
                    // can switch to HERDR_SOCKET_PATH before the async OS icon probe.
                    if let platform = await service.sshRemotePlatform(),
                       let index = self.devices.firstIndex(where: { $0.id == device.id }) {
                        let osID: String?
                        switch platform {
                        case .windows: osID = "windows"
                        case .unix: osID = self.devices[index].osID
                        }
                        if let osID, self.devices[index].osID != osID {
                            self.devices[index].osID = osID
                            self.store.save(self.devices)
                        }
                    }
                    // retried on every successful connect until it sticks (a fresh
                    // device's first probes can fail before its host key is known)
                    if let current = self.device(device.id) {
                        self.probeOSIfNeeded(current)
                    }
                    await self.refresh(device.id)
                    await self.loadAgentCatalog(deviceID: device.id, using: service)
                    await self.loadPluginActions(deviceID: device.id)
                    eventSubscriptions: while !Task.isCancelled {
                        let subscribedPaneIDs = self.statusSubscriptionPaneIDs(device.id)
                        let stream = try await service.events(statusPaneIDs: subscribedPaneIDs)
                        var needsResubscribe = false
                        var resubscribeDelay: UInt64 = 100_000_000
                        for try await event in stream {
                            guard !Task.isCancelled else { return }
                            if event.kind == HerdrEvent.agentStatusChangedKind {
                                if self.applyAgentStatusEvent(event, deviceID: device.id) {
                                    self.scheduleRefresh(device.id)
                                } else {
                                    _ = await self.refreshImmediately(device.id)
                                }
                            } else if event.kind == HerdrEvent.subscriptionStartedKind
                                || Self.paneTopologyEventKinds.contains(event.kind) {
                                if !(await self.refreshImmediately(device.id)) {
                                    needsResubscribe = true
                                    resubscribeDelay = 500_000_000
                                    break
                                }
                            } else {
                                self.scheduleRefresh(device.id)
                            }

                            if event.kind == HerdrEvent.subscriptionStartedKind
                                || Self.paneTopologyEventKinds.contains(event.kind) {
                                let currentPaneIDs = self.statusSubscriptionPaneIDs(device.id)
                                if currentPaneIDs != subscribedPaneIDs {
                                    needsResubscribe = true
                                    break
                                }
                            }
                        }
                        if needsResubscribe {
                            try? await Task.sleep(nanoseconds: resubscribeDelay)
                            continue eventSubscriptions
                        }
                        guard !Task.isCancelled else { return }
                        throw HerdrError.connectionFailed("event stream ended")
                    }
                } catch {
                    self.sessions[device.id]?.connection = .failed(error.localizedDescription)
                    // The catalog's initial state is .loading; when connect()
                    // itself fails the load never runs, and without this the
                    // New Agent panel spins on "Checking agents…" forever
                    // while the only hint is the footer indicator (#69).
                    if case .loading = self.sessions[device.id]?.agentCatalog ?? .loading {
                        self.sessions[device.id]?.agentCatalog = .failed(
                            self.actionErrorMessage(error, device: device)
                        )
                    }
                    if let target = device.sshTarget, Self.isSSHAuthenticationFailure(error) {
                        self.sshAuthenticationRequest = SSHAuthenticationRequest(
                            deviceID: device.id,
                            target: target
                        )
                        return
                    }
                }
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                backoff = min(backoff * 2, 30)
            }
        }
    }

    /// Locally, keeps only advertised CLIs whose binaries are on the login-shell
    /// search PATH (or a Settings override). SSH hosts keep their server-owned
    /// catalog; `agent.start` validates in the target pane instead. Manifests
    /// also feed the attachment-capability registry (paste path vs upload).
    /// Plugins come and go without a reconnect, so the context menu also
    /// reloads this each time it opens, for the next time.
    func loadPluginActions(deviceID: UUID) async {
        guard let service = services[deviceID] else { return }
        // An older server without plugin RPCs keeps an empty menu section.
        guard let actions = try? await service.pluginActions() else { return }
        sessions[deviceID]?.pluginActions = PluginActionGroup.menu(actions)
    }

    private func loadAgentCatalog(deviceID: UUID, using service: HerdrService) async {
        sessions[deviceID]?.agentCatalog = .loading
        do {
            let manifests = try await service.agentManifests()
            sessions[deviceID]?.attachmentCapabilities =
                AgentAttachmentCapabilityRegistry(manifests: manifests)
            let advertised = manifests.map(\.agent)
            if device(deviceID)?.isLocal == true {
                // Herdr supports OMP through its lifecycle extension, so it has
                // no screen-detection manifest in server.agent_manifests.
                let found = await service.installedAgents(
                    from: advertised,
                    includingIntegrationKinds: ["omp"],
                    overrides: AgentBinaryOverrides.load()
                )
                sessions[deviceID]?.agentCatalog = .loaded(
                    kinds: found.map(\.kind),
                    paths: Dictionary(uniqueKeysWithValues: found.map { ($0.kind, $0.path) })
                )
            } else {
                sessions[deviceID]?.agentCatalog = .loaded(kinds: advertised)
            }
        } catch {
            sessions[deviceID]?.agentCatalog = .failed(error.localizedDescription)
        }
    }

    func reloadAgentCatalog(deviceID: UUID) {
        guard let device = device(deviceID) else { return }
        let service = service(for: device)
        Task { await loadAgentCatalog(deviceID: deviceID, using: service) }
    }

    /// Tears down every live tunnel. Awaited from the app's terminate hook — `stopSession`
    /// fires its disconnect in a detached `Task`, which never runs when the process is exiting.
    func shutdownAllSessions() async {
        let live = services
        services.removeAll()
        sessionTasks.values.forEach { $0.cancel() }
        sessionTasks.removeAll()
        for service in live.values {
            await service.disconnect()
        }
    }

    private func stopSession(_ id: UUID) {
        let service = detachSession(id)
        Task { await service?.disconnect() }
    }

    /// Cancels a device's session and drops its state, returning the service
    /// still to be disconnected. Callers that must order the disconnect before a
    /// restart await it themselves instead of firing it detached.
    private func detachSession(_ id: UUID) -> HerdrService? {
        sessionTasks[id]?.cancel()
        sessionTasks[id] = nil
        refreshDebounces[id]?.cancel()
        refreshDebounces[id] = nil
        refreshDebounceTokens[id] = nil
        refreshDebouncePending.remove(id)
        snapshotRefreshTasks[id]?.cancel()
        snapshotRefreshTasks[id] = nil
        snapshotRefreshTokens[id] = nil
        refreshRequested.remove(id)
        statusGenerations[id] = nil
        previousStatuses[id] = nil
        let service = services[id]
        services[id] = nil
        sessions[id] = nil
        return service
    }

    func addDevice(name: String, sshTarget: String) {
        let device = Device(name: name, kind: .ssh(target: sshTarget))
        devices.append(device)
        store.save(devices)
        startSession(device)
        probeOSIfNeeded(device)
        setDeviceFilter(device.id)
    }

    /// Adds a tailcat-tunnel device. The token is a bearer credential and goes
    /// straight to the Keychain — devices.json never sees it.
    func addTailcatDevice(name: String, token: String) {
        let device = Device(name: name, kind: .tailcat)
        do {
            try TailcatCredentialStore.setToken(token, for: device.id)
        } catch {
            actionError = error.localizedDescription
            return
        }
        devices.append(device)
        store.save(devices)
        startSession(device)
        setDeviceFilter(device.id)
    }

    /// Loads the tailcat client public key, generating the key on first use.
    func loadTailcatClientPublicKey() {
        guard tailcatClientPublicKey == nil else { return }
        do {
            tailcatClientPublicKey = try TailcatClientKeyStore.publicKey()
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Replaces the tailcat client key and reconnects every tailcat device so
    /// its bridge comes back up with the new identity.
    func regenerateTailcatClientKey() {
        do {
            tailcatClientPublicKey = try TailcatClientKeyStore.regenerate()
        } catch {
            actionError = error.localizedDescription
            return
        }
        let ids = devices.filter(\.isTailcat).map(\.id)
        let stale = ids.compactMap { detachSession($0) }
        Task { [weak self] in
            // A live bridge is reused as-is by ensureUp, so it must be gone
            // before the new sessions connect — await the teardown rather than
            // let stopSession's detached disconnect race the restart.
            for service in stale { await service.disconnect() }
            for id in ids { await TailcatBridgeManager.shared.tearDown(deviceID: id) }
            guard let self else { return }
            for id in ids {
                if let device = self.device(id) { self.startSession(device) }
            }
        }
    }

    func saveSSHPassword(_ password: String, for request: SSHAuthenticationRequest) {
        guard !password.isEmpty,
              let device = device(request.deviceID),
              device.sshTarget == request.target
        else { return }
        do {
            try SSHCredentialStore.setPassword(password, for: device.id)
            sshAuthenticationRequest = nil
            stopSession(device.id)
            startSession(device)
            probeOSIfNeeded(device)
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Leaves the device disconnected but recoverable; the reconnect loop stopped at the prompt.
    func cancelSSHAuthentication(for request: SSHAuthenticationRequest) {
        sshAuthenticationRequest = nil
        sessions[request.deviceID]?.connection =
            .failed(String(localized: "Authentication cancelled — choose Reconnect to try again"))
    }

    var hasReconnectableDevice: Bool {
        devicesInScope.contains { isFailed($0.id) }
    }

    func reconnectFailedDevices() {
        for device in devicesInScope where isFailed(device.id) {
            stopSession(device.id)
            startSession(device)
            probeOSIfNeeded(device)
        }
        // Reconnect is also the natural moment to pick up a named session that
        // started (or dropped) since launch (issue #81).
        refreshNamedSessions()
    }

    private func isFailed(_ deviceID: UUID) -> Bool {
        if case .failed = session(deviceID).connection { return true }
        return false
    }

    /// Renames a device and/or updates its SSH target (e.g. after an IP change).
    func updateDevice(_ id: UUID, name: String, sshTarget: String) {
        guard let index = devices.firstIndex(where: { $0.id == id }), !devices[index].isLocal else { return }
        let targetChanged = devices[index].sshTarget != sshTarget
        devices[index].name = name
        if targetChanged {
            removeSSHPassword(for: id)
            devices[index].kind = .ssh(target: sshTarget)
            devices[index].osID = nil
            stopSession(id)
            startSession(devices[index])
            probeOSIfNeeded(devices[index])
        }
        store.save(devices)
    }

    func removeDevice(_ device: Device) {
        guard !device.isLocal else { return }
        removeSSHPassword(for: device.id)
        TailcatCredentialStore.removeToken(for: device.id)
        if sshAuthenticationRequest?.deviceID == device.id { sshAuthenticationRequest = nil }
        stopSession(device.id)
        attachSessions.removeAll { $0.device.id == device.id }
        devices.removeAll { $0.id == device.id }
        store.save(devices)
        if deviceFilter == device.id { deviceFilter = nil }
        if selectedSpace?.deviceID == device.id { selectedSpace = nil }
        if selectedPane?.deviceID == device.id {
            selectedPane = preferredVisibleAgent()?.ref ?? firstVisiblePaneRef
        }
    }

    // MARK: - Refresh

    @discardableResult
    func refresh(_ deviceID: UUID) async -> Bool {
        refreshRequested.insert(deviceID)
        if let task = snapshotRefreshTasks[deviceID] {
            return await task.value
        }
        let token = UUID()
        snapshotRefreshTokens[deviceID] = token
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            var latestSucceeded = false
            while !Task.isCancelled, self.refreshRequested.remove(deviceID) != nil {
                latestSucceeded = await self.performRefresh(deviceID)
            }
            if self.snapshotRefreshTokens[deviceID] == token {
                self.snapshotRefreshTokens[deviceID] = nil
                self.snapshotRefreshTasks[deviceID] = nil
            }
            return latestSucceeded
        }
        snapshotRefreshTasks[deviceID] = task
        return await task.value
    }

    private func performRefresh(_ deviceID: UUID) async -> Bool {
        guard let device = device(deviceID), let service = services[deviceID] else {
            return false
        }
        let statusGeneration = statusGenerations[deviceID, default: 0]
        do {
            let snapshot = try await service.snapshot()
            guard services[deviceID] === service, sessions[deviceID] != nil else {
                return false
            }
            guard statusGenerations[deviceID, default: 0] == statusGeneration else {
                // A direct status event overtook this request on the separate
                // event connection. Discard the older snapshot and let the
                // refresh drain fetch one after that event.
                refreshRequested.insert(deviceID)
                return true
            }
            unreadAgents = AgentUnread.applying(
                previous: previousStatuses[deviceID] ?? [:],
                agents: snapshot.agents,
                unread: unreadAgents,
                deviceID: device.id
            )
            notifyTransitions(
                device: device,
                from: previousStatuses[deviceID] ?? [:],
                to: snapshot.agents,
                workspaces: snapshot.workspaces,
                tabs: snapshot.tabs ?? []
            )
            previousStatuses[deviceID] = Dictionary(
                uniqueKeysWithValues: snapshot.agents.map { ($0.paneID, $0.status) }
            )
            sessions[deviceID]?.agents = snapshot.agents
            sessions[deviceID]?.workspaces = snapshot.workspaces
            sessions[deviceID]?.tabs = TabReorder.ordered(
                snapshot.tabs ?? [],
                workspaces: snapshot.workspaces
            )
            sessions[deviceID]?.panes = snapshot.ordinaryTerminalPanes
            refreshGitStatuses(deviceID: deviceID)
            if selectedPane?.deviceID == deviceID { Task { @MainActor in await refreshActiveLayout() } }
            reconcileAttachSessions(deviceID: deviceID)
            // A snapshot without a tab list (older herdr) says nothing about tabs;
            // reconciling against an empty set would tear every drawer down.
            if let tabs = snapshot.tabs {
                for removed in editorDrawers.reconcile(deviceID: deviceID, liveTabIDs: Set(tabs.map(\.tabID))) {
                    try? FileManager.default.removeItem(atPath: removed.socketPath)
                }
                let live = Set(tabs.map(\.tabID))
                previews = previews.filter { $0.key.deviceID != deviceID || live.contains($0.key.tabID) }
            }
            let paneIDs = Set((snapshot.panes ?? []).map(\.paneID))
                .union(snapshot.agents.map(\.paneID))
            // Drop kept-alive attaches whose pane is gone (closed). A pane only taken
            // over by another client still exists, so it stays — its Reconnect overlay
            // needs the kept-alive child to rebuild the attach.
            attachSessions.removeAll { $0.device.id == deviceID && !paneIDs.contains($0.ref.paneID) }
            if let selected = selectedPane, selected.deviceID == deviceID,
               !paneIDs.contains(selected.paneID) {
                selectedPane = nil
            }
            if let space = selectedSpace, space.deviceID == deviceID,
               !snapshot.workspaces.contains(where: { $0.workspaceID == space.workspaceID }) {
                selectedSpace = nil
            }
            if selectedPane == nil {
                if let focusedPaneID = snapshot.focusedPaneID,
                   paneIDs.contains(focusedPaneID),
                   deviceFilter == nil || deviceFilter == deviceID {
                    let focused = PaneRef(deviceID: deviceID, paneID: focusedPaneID)
                    if selectedSpace == nil
                        || selectedAttachedEntry.map({
                            $0.ref == focused && $0.workspaceID == selectedSpace?.workspaceID
                        }) == true {
                        selectedPane = focused
                    }
                }
                if selectedPane == nil {
                    selectedPane = preferredVisibleAgent()?.ref ?? firstVisiblePaneRef
                }
            }
            return true
        } catch {
            // A snapshot is one request on an otherwise live session. The
            // event/connect loop owns connection health and will mark the
            // device failed if the transport itself is gone.
            return false
        }
    }

    private func scheduleRefresh(_ deviceID: UUID) {
        // Coalesce from the leading edge instead of resetting the timer for
        // every event. A busy pane can emit continuously; a trailing debounce
        // would never fire until output stopped, hiding the working state.
        guard refreshDebounces[deviceID] == nil else {
            refreshDebouncePending.insert(deviceID)
            return
        }
        let token = UUID()
        refreshDebounceTokens[deviceID] = token
        refreshDebounces[deviceID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self, !Task.isCancelled,
                  self.refreshDebounceTokens[deviceID] == token
            else { return }
            await self.refresh(deviceID)
            if self.refreshDebounceTokens[deviceID] == token {
                let needsTrailing = self.refreshDebouncePending.remove(deviceID) != nil
                self.refreshDebounceTokens[deviceID] = nil
                self.refreshDebounces[deviceID] = nil
                if needsTrailing {
                    self.scheduleRefresh(deviceID)
                }
            }
        }
    }

    private func refreshImmediately(_ deviceID: UUID) async -> Bool {
        refreshDebounces[deviceID]?.cancel()
        refreshDebounces[deviceID] = nil
        refreshDebounceTokens[deviceID] = nil
        refreshDebouncePending.remove(deviceID)
        return await refresh(deviceID)
    }

    @discardableResult
    private func applyAgentStatusEvent(_ event: HerdrEvent, deviceID: UUID) -> Bool {
        guard let paneID = event.payload["data"]?["pane_id"]?.stringValue,
              let statusRaw = event.payload["data"]?["agent_status"]?.stringValue,
              let device = device(deviceID),
              var state = sessions[deviceID],
              let index = state.agents.firstIndex(where: { $0.paneID == paneID })
        else { return false }

        let status = AgentStatus(wire: statusRaw)
        guard state.agents[index].status != status else { return true }
        let previous = previousStatuses[deviceID] ?? [:]
        state.agents[index] = state.agents[index].updatingStatus(status)
        unreadAgents = AgentUnread.applying(
            previous: previous,
            agents: state.agents,
            unread: unreadAgents,
            deviceID: deviceID
        )
        notifyTransitions(
            device: device,
            from: previous,
            to: state.agents,
            workspaces: state.workspaces,
            tabs: state.tabs
        )
        var nextStatuses = previous
        nextStatuses[paneID] = status
        previousStatuses[deviceID] = nextStatuses
        statusGenerations[deviceID, default: 0] &+= 1
        sessions[deviceID] = state
        return true
    }

    private func statusSubscriptionPaneIDs(_ deviceID: UUID) -> [String] {
        Array(Set(
            session(deviceID).agents.map(\.paneID)
                + session(deviceID).panes.map(\.paneID)
        )).sorted()
    }

    private static let paneTopologyEventKinds: Set<String> = [
        "pane.created",
        "pane.closed",
        "pane.moved",
        "pane.agent_detected",
    ]

    /// Notifies when an agent newly becomes blocked (needs input) or done (finished
    /// while unwatched). Initial snapshots don't notify — only real transitions do.
    private func notifyTransitions(
        device: Device,
        from previous: [String: AgentStatus],
        to agents: [AgentInfo],
        workspaces: [WorkspaceInfo],
        tabs: [TabInfo]
    ) {
        guard !previous.isEmpty else { return }
        for agent in agents {
            guard let old = previous[agent.paneID], old != agent.status else { continue }
            guard agent.status == .blocked || agent.status == .done else { continue }
            let tabLabel = tabs.first { $0.tabID == agent.tabID }?.customLabel
            NotificationManager.shared.post(
                agent: agent,
                title: agent.title(tabLabel: tabLabel),
                status: agent.status,
                deviceID: device.id,
                deviceName: device.name,
                spaceName: workspaces.first { $0.workspaceID == agent.workspaceID }?.label ?? agent.workspaceID
            )
        }
    }

    /// Sniffs the device OS once (for the OS brand icon) and persists it.
    private func probeOSIfNeeded(_ device: Device) {
        guard device.osID == nil, let target = device.sshTarget else { return }
        Task {
            guard let os = try? await SSHTunnel.probeOS(
                target: target,
                credentialID: device.id
            ) else { return }
            if let index = self.devices.firstIndex(where: { $0.id == device.id }) {
                self.devices[index].osID = os
                self.store.save(self.devices)
            }
        }
    }

    private static func isSSHAuthenticationFailure(_ error: Error) -> Bool {
        guard let herdrError = error as? HerdrError,
              case .tunnelFailed(let reason) = herdrError
        else { return false }
        return [
            "permission denied",
            "authentication failed",
            "too many authentication failures",
            "no supported authentication methods",
        ].contains { reason.localizedCaseInsensitiveContains($0) }
    }

    private func removeSSHPassword(for deviceID: UUID) {
        do {
            try SSHCredentialStore.removePassword(for: deviceID)
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// An action fired while the device session is down surfaces the bare
    /// "connection failed: not connected", which points at nothing. The
    /// reconnect loop already knows why the device is unreachable — say that
    /// instead. (#21)
    func actionErrorMessage(_ error: Error, device: Device) -> String {
        guard let herdrError = error as? HerdrError,
              case .connectionFailed(let reason) = herdrError,
              reason == "not connected"
        else { return error.localizedDescription }
        switch session(device.id).connection {
        case .connecting:
            return String(localized: "Still connecting to \(device.name) — try again in a moment.")
        case .failed(let reason):
            return String(localized: "\(device.name) is unreachable: \(reason)")
        case .idle:
            return String(localized: "\(device.name) isn't connected.")
        case .connected:
            return String(localized: "\(device.name) just reconnected — try again.")
        }
    }

    /// A fresh pane for New Agent: a new tab in the chosen space, or in herdr's
    /// focused one. herdr closes a space with its last pane, so a device can be
    /// left with no space at all, and `tab.create` then fails with
    /// `workspace_not_found`. In that case a space is created (in the home
    /// folder on this Mac) and the agent starts in its first pane.
    private func newAgentPane(
        service: HerdrService,
        device: Device,
        workspaceID: String?,
        kind: String
    ) async throws -> String {
        do {
            return try await service.createTab(workspaceID: workspaceID, cwd: nil, label: kind)
        } catch HerdrError.rpc(let code, _) where code == "workspace_not_found" && workspaceID == nil {
            let created = try await service.createWorkspace(
                label: nil,
                cwd: device.isLocal ? NSHomeDirectory() : nil
            )
            if let rootPaneID = created.rootPaneID { return rootPaneID }
            return try await service.createTab(workspaceID: created.workspaceID, cwd: nil, label: kind)
        }
    }

    // MARK: - Closing

    func requestCloseSpace(_ entry: SpaceEntry) {
        closeRequest = CloseRequest(
            title: String(localized: "Close space \"\(entry.workspace.label)\" on \(entry.device.name)?"),
            message: String(localized: "All terminals and agents in this space will be closed.")
        ) { [weak self] in
            guard let self else { return }
            Task {
                do {
                    try await self.service(for: entry.device)
                        .closeWorkspace(workspaceID: entry.workspace.workspaceID)
                    if self.selectedSpace == entry.ref { self.selectedSpace = nil }
                    await self.refresh(entry.device.id)
                } catch {
                    self.actionError = self.actionErrorMessage(error, device: entry.device)
                }
            }
        }
    }

    func requestClosePane(_ ref: PaneRef, name: String) {
        guard let device = device(ref.deviceID) else { return }
        let message: String
        if let space = spaceClosedWithPane(ref) {
            message = String(localized: "It is the last pane in the space \"\(space)\", so herdr closes the space too. Whatever is running inside it will be terminated.")
        } else {
            message = String(localized: "The pane and whatever is running inside it will be terminated.")
        }
        closeRequest = CloseRequest(
            title: String(localized: "Close \"\(name)\"?"),
            message: message
        ) { [weak self] in
            guard let self else { return }
            Task {
                do {
                    try await self.service(for: device).closePane(paneID: ref.paneID)
                    if self.selectedPane == ref { self.selectedPane = nil }
                    await self.refresh(device.id)
                } catch {
                    self.actionError = self.actionErrorMessage(error, device: device)
                }
            }
        }
    }

    /// The label of the space that closing `ref` would empty, or nil when the
    /// space keeps other panes. herdr removes a space together with its last pane.
    private func spaceClosedWithPane(_ ref: PaneRef) -> String? {
        let state = session(ref.deviceID)
        let workspaceID = state.agents.first { $0.paneID == ref.paneID }?.workspaceID
            ?? state.panes.first { $0.paneID == ref.paneID }?.workspaceID
        guard let workspaceID else { return nil }
        let paneCount = state.agents.filter { $0.workspaceID == workspaceID }.count
            + state.panes.filter { $0.workspaceID == workspaceID }.count
        guard paneCount <= 1 else { return nil }
        return state.workspaces.first { $0.workspaceID == workspaceID }?.label
    }

    // MARK: - Actions

    func renameSpace(_ entry: SpaceEntry, label: String) {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label != entry.workspace.label else { return }
        Task {
            do {
                try await service(for: entry.device).renameWorkspace(
                    workspaceID: entry.workspace.workspaceID,
                    label: label
                )
                await refresh(entry.device.id)
            } catch {
                actionError = actionErrorMessage(error, device: entry.device)
            }
        }
    }

    /// Runs a plugin action on the agent's device, as if picked in herdr itself.
    /// herdr's own toasts never reach this window, so the command's last line
    /// comes back as a notification, or as an alert when it failed.
    func runPluginAction(_ action: PluginAction, for entry: AgentEntry) {
        runPluginAction(
            action,
            on: entry.device,
            target: PluginInvocationTarget(
                workspaceID: entry.agent.workspaceID,
                tabID: entry.agent.tabID,
                paneID: entry.agent.paneID
            )
        )
    }

    /// `target` is the agent the action was picked for, nil from a window
    /// that has none. `onFinish` runs once the command is done, either way.
    func runPluginAction(
        _ action: PluginAction,
        on device: Device,
        target: PluginInvocationTarget?,
        onFinish: (() -> Void)? = nil
    ) {
        let service = service(for: device)
        Task {
            defer { onFinish?() }
            do {
                let logID = try await service.invokePluginAction(action, target: target)
                // grazr's swap takes well under a second; give slow ones a while.
                for _ in 0..<60 {
                    try await Task.sleep(nanoseconds: 250_000_000)
                    guard let log = try await service.pluginCommandLog(pluginID: action.pluginID, logID: logID),
                          log.isFinished
                    else { continue }
                    if log.succeeded {
                        NotificationManager.shared.postPluginResult(
                            title: action.title,
                            body: log.summary ?? String(localized: "Done"),
                            deviceName: device.name
                        )
                    } else {
                        actionError = log.summary.map { "\(action.title): \($0)" }
                            ?? String(localized: "\(action.title) failed")
                    }
                    break
                }
                await refresh(device.id)
            } catch {
                actionError = actionErrorMessage(error, device: device)
            }
        }
    }

    func renameAgent(_ entry: AgentEntry, name: String) {
        renameTabLabel(device: entry.device, tabID: entry.agent.tabID, current: entry.title, name: name)
    }

    func renameTerminal(_ entry: TerminalEntry, name: String) {
        guard let tabID = entry.tabID else { return }
        renameTabLabel(device: entry.device, tabID: tabID, current: entry.title, name: name)
    }

    private func renameTabLabel(device: Device, tabID: String, current: String, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != current else { return }
        Task {
            do {
                try await service(for: device).renameTab(tabID: tabID, label: name)
                await refresh(device.id)
            } catch {
                actionError = actionErrorMessage(error, device: device)
            }
        }
    }

    /// Reorders a Space by dropping it on another Space of the same device.
    /// Cross-device drops are ignored; herdr remains the source of truth after refresh.
    func moveSpace(_ source: SpaceEntry, onto target: SpaceEntry, placeAfter: Bool) {
        guard source.device.id == target.device.id else { return }
        let orderedIDs = session(source.device.id).workspaces.map(\.workspaceID)
        guard let plan = WorkspaceReorder.plan(
            moving: source.workspace.workspaceID,
            onto: target.workspace.workspaceID,
            placeAfter: placeAfter,
            orderedIDs: orderedIDs
        ) else { return }

        if let current = sessions[source.device.id]?.workspaces {
            withAnimation(.easeInOut(duration: 0.2)) {
                sessions[source.device.id]?.workspaces = WorkspaceReorder.applying(
                    current,
                    id: \.workspaceID,
                    plan: plan
                )
            }
        }

        Task {
            do {
                try await service(for: source.device).moveWorkspaceBlock(
                    workspaceIDs: plan.workspaceIDs,
                    beforeWorkspaceID: plan.beforeWorkspaceID
                )
                await refresh(source.device.id)
            } catch {
                await refresh(source.device.id)
                actionError = actionErrorMessage(error, device: source.device)
            }
        }
    }

    /// Reorders an agent tab by dropping it on another agent in the same space.
    /// Cross-space and cross-device drops are ignored (`tab.move` is in-workspace).
    func moveAgent(_ source: AgentEntry, onto target: AgentEntry, placeAfter: Bool) {
        guard source.device.id == target.device.id,
              source.agent.workspaceID == target.agent.workspaceID
        else { return }
        moveTab(
            device: source.device,
            workspaceID: source.agent.workspaceID,
            moving: source.agent.tabID,
            onto: target.agent.tabID,
            placeAfter: placeAfter
        )
    }

    /// Reorders a tab in its space's tab strip (same workspace, same device).
    func moveTab(_ tabID: String, onto targetID: String, in space: SpaceRef, placeAfter: Bool) {
        guard let device = device(space.deviceID) else { return }
        moveTab(
            device: device,
            workspaceID: space.workspaceID,
            moving: tabID,
            onto: targetID,
            placeAfter: placeAfter
        )
    }

    private func moveTab(
        device: Device,
        workspaceID: String,
        moving: String,
        onto: String,
        placeAfter: Bool
    ) {
        let orderedIDs = orderedTabIDs(deviceID: device.id, workspaceID: workspaceID)
        guard let insertIndex = TabReorder.insertIndex(
            moving: moving,
            onto: onto,
            placeAfter: placeAfter,
            orderedIDs: orderedIDs
        ) else { return }
        guard let plan = WorkspaceReorder.plan(
            moving: moving,
            onto: onto,
            placeAfter: placeAfter,
            orderedIDs: orderedIDs
        ) else { return }

        if let current = sessions[device.id]?.tabs {
            let scoped = current.filter { $0.workspaceID == workspaceID }
            let reordered = WorkspaceReorder.applying(scoped, id: \.tabID, plan: plan)
            withAnimation(.easeInOut(duration: 0.2)) {
                sessions[device.id]?.tabs = Self.replacingTabs(
                    current,
                    workspaceID: workspaceID,
                    with: reordered
                )
            }
        }

        Task {
            do {
                try await service(for: device).moveTab(tabID: moving, insertIndex: insertIndex)
                await refresh(device.id)
            } catch {
                await refresh(device.id)
                actionError = actionErrorMessage(error, device: device)
            }
        }
    }

    private static func replacingTabs(
        _ tabs: [TabInfo],
        workspaceID: String,
        with reordered: [TabInfo]
    ) -> [TabInfo] {
        var result: [TabInfo] = []
        var inserted = false
        for tab in tabs {
            if tab.workspaceID == workspaceID {
                if !inserted {
                    result.append(contentsOf: reordered)
                    inserted = true
                }
            } else {
                result.append(tab)
            }
        }
        if !inserted { result.append(contentsOf: reordered) }
        return result
    }

    /// New Space, as in herdr itself: a fresh workspace with a shell, created at
    /// once on the filtered (else first) device and selected. No sheets; this Mac
    /// roots it in the home folder, remote hosts let herdr pick.
    func newSpace() {
        guard let device = deviceFilter.flatMap(device(_:)) ?? devices.first else { return }
        Task {
            do {
                let created = try await service(for: device).createWorkspace(
                    label: nil,
                    cwd: device.isLocal ? NSHomeDirectory() : nil
                )
                await refresh(device.id)
                selectSpace(SpaceRef(deviceID: device.id, workspaceID: created.workspaceID))
            } catch {
                actionError = actionErrorMessage(error, device: device)
            }
        }
    }

    /// Creates a persistent shell tab on the selected Herdr device. Local and
    /// remote terminals use the same server-owned lifecycle and can be detached
    /// and reattached without killing the shell process.
    func startNewTerminal(device: Device, workspaceID: String) {
        Task {
            do {
                let paneID = try await service(for: device).createTab(
                    workspaceID: workspaceID,
                    cwd: nil,
                    label: nil
                )
                await refresh(device.id)
                isFileManagerActive = false
                selectedSpace = SpaceRef(deviceID: device.id, workspaceID: workspaceID)
                selectedPane = PaneRef(deviceID: device.id, paneID: paneID)
                selectedShellID = nil
            } catch {
                actionError = actionErrorMessage(error, device: device)
            }
        }
    }

    /// New Agent: a fresh tab in the space plus agent.start. Agent names are
    /// session-global in herdr, so collisions retry with a unique suffix.
    /// `bypass` appends the kind's skip-permissions flag when one is known.
    func startNewAgent(
        device: Device,
        kind: String,
        workspaceID: String?,
        bypass: Bool
    ) {
        let args = bypass ? (HerdrService.bypassFlags(for: kind) ?? []) : []
        Task {
            let service = service(for: device)
            var createdPane: String?
            do {
                let pane = try await newAgentPane(
                    service: service, device: device, workspaceID: workspaceID, kind: kind
                )
                createdPane = pane
                do {
                    try await service.startAgent(
                        name: kind,
                        kind: kind,
                        paneID: pane,
                        args: args,
                        waitForShell: true
                    )
                } catch HerdrError.rpc(let code, _) where code == "agent_name_taken" {
                    let suffix = String(UUID().uuidString.prefix(4)).lowercased()
                    try await service.startAgent(
                        name: "\(kind)-\(suffix)",
                        kind: kind,
                        paneID: pane,
                        args: args,
                        waitForShell: true
                    )
                }
                await refresh(device.id)
                isFileManagerActive = false
                selectedPane = PaneRef(deviceID: device.id, paneID: pane)
            } catch {
                if let createdPane {
                    try? await service.closePane(paneID: createdPane)
                }
                actionError = actionErrorMessage(error, device: device)
            }
        }
    }
}
