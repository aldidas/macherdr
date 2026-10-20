import AppKit
import HerdrKit
import SwiftUI

extension View {
    /// The New Agent / New Terminal / New Space sheets, opened by the model's
    /// flags. Separate from `RootView` so tests can attach them to a sidebar
    /// with fake data, without starting a session.
    func newItemSheets(model: AppModel) -> some View {
        modifier(NewItemSheets(model: model))
    }
}

private struct NewItemSheets: ViewModifier {
    @ObservedObject var model: AppModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $model.showNewAgent) { NewAgentSheet(model: model) }
            .sheet(isPresented: $model.showNewTerminal) { NewTerminalSheet(model: model) }
    }
}

struct RootView: View {
    // Owned by AppDelegate so it outlives the window — see AppDelegate in MacHerdrApp.swift.
    @ObservedObject var model: AppModel
    // Deliberately not persisted: the app always launches with the sidebar visible.
    @State private var sidebarCollapsed = false
    @AppStorage(Theme.backgroundImagePathKey) private var backgroundImagePath = ""
    @AppStorage(Theme.backgroundOverlayKey) private var backgroundOverlay = Theme.defaultBackgroundOverlay

    /// Drawn through an overlay on a clear view so the image's pixel size never
    /// feeds into the window's layout.
    @ViewBuilder private var backgroundImageLayer: some View {
        if let image = Theme.backgroundImage {
            Color.clear
                .overlay {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            SidebarSplit(
                collapsed: sidebarCollapsed || model.isSplitZoomed,
                collapsedWidth: model.isSplitZoomed ? 0 : SidebarRail.width
            ) { width in
                if sidebarCollapsed {
                    SidebarRail(model: model, collapsed: $sidebarCollapsed)
                } else {
                    SidebarView(model: model, collapsed: $sidebarCollapsed, width: width)
                }
            } detail: {
                DetailView(model: model, sidebarCollapsed: $sidebarCollapsed, sidebarHidden: model.isSplitZoomed)
            }

            // In-window device panel; NSPopover throws in ViewBridge on macOS 26+ betas.
            if model.showDevicePanel {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { model.showDevicePanel = false }
                DevicePopover(model: model, isPresented: $model.showDevicePanel)
                    .padding(.leading, 10)
                    .padding(.bottom, 46)
                    .transition(.scale(scale: 0.96, anchor: .bottomLeading).combined(with: .opacity))
                    .background(
                        Button("") { model.showDevicePanel = false }
                            .keyboardShortcut(.cancelAction)
                            .hidden()
                    )
            }
        }
        .background { backgroundImageLayer }
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: model.showDevicePanel)
        .herdrKeybindings(model: model)
        .onAppear { model.toggleSidebarHandler = { sidebarCollapsed.toggle() } }
        .background(
            Button("") { sidebarCollapsed.toggle() }
                .keyboardShortcut("b", modifiers: .command)
                .hidden()
        )
        .background(
            Button("") { model.showSearch = true }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        )
        .focusedSceneValue(\.appModel, model)
        .focusedSceneValue(\.splitAxis, model.shellSplitAxis)
        .sheet(isPresented: $model.showSearch) { SearchSheet(model: model) }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 980, minHeight: 620)
        .onAppear { model.start() }
        .sheet(isPresented: $model.showAddDevice) { AddDeviceSheet(model: model) }
        .newItemSheets(model: model)
        .sheet(item: $model.spaceToRename) { entry in RenameSpaceSheet(model: model, entry: entry) }
        .sheet(item: $model.agentToRename) { entry in RenameAgentSheet(model: model, entry: entry) }
        .sheet(item: $model.terminalToRename) { entry in RenameTerminalSheet(model: model, entry: entry) }
        .sheet(item: $model.deviceToEdit) { device in EditDeviceSheet(model: model, device: device) }
        .sheet(item: $model.grazrAccountsDevice) { device in GrazrAccountsSheet(model: model, device: device) }
        .sheet(item: $model.sshAuthenticationRequest) { request in
            SSHAuthenticationSheet(model: model, request: request)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.actionError != nil },
                set: { if !$0 { model.actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
        .alert(
            model.closeRequest?.title ?? "",
            isPresented: Binding(
                get: { model.closeRequest != nil },
                set: { if !$0 { model.closeRequest = nil } }
            )
        ) {
            // Destructive buttons get no Return binding by default, which left this
            // dialog with no default button: Return did nothing and the pointer was the
            // only way out. The dialog only opens from an explicit close action, and
            // Escape still cancels, so Return confirming is the expected Mac behaviour.
            Button("Close", role: .destructive) {
                model.closeRequest?.perform()
                model.closeRequest = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.closeRequest?.message ?? "")
        }
    }
}

/// Titlebar metrics. The system draws the traffic lights centered in a 28pt
/// strip; `TitlebarLayout` stretches the window's titlebar to `height` and
/// re-centers them, so the sidebar toggle and the title strip share one centerline.
enum TitlebarMetrics {
    static let height: CGFloat = 52
    /// Left edge of the close button (the system default is 7pt).
    static let trafficLightLeading: CGFloat = 16
    static let trafficLightClearance: CGFloat = 78 + (trafficLightLeading - 7)
}

/// Resizes the window's titlebar container to `TitlebarMetrics.height` and
/// vertically centers the close/minimize/zoom buttons in it. Idempotent: AppKit
/// re-lays the buttons out on resize and fullscreen changes, so callers
/// reapply on those events.
@MainActor
enum TitlebarLayout {
    static func apply(to window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let titlebar = close.superview,
              let container = titlebar.superview
        else { return }
        let target = TitlebarMetrics.height
        if abs(container.frame.height - target) > 0.5 {
            var frame = container.frame
            frame.size.height = target
            frame.origin.y = window.frame.height - target
            container.frame = frame
        }
        if abs(titlebar.frame.height - target) > 0.5 || titlebar.frame.origin.y != 0 {
            titlebar.frame = NSRect(x: titlebar.frame.origin.x, y: 0, width: titlebar.frame.width, height: target)
        }
        let shift = TitlebarMetrics.trafficLightLeading - close.frame.origin.x
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type) else { continue }
            let y = (titlebar.bounds.height - button.frame.height) / 2
            if abs(button.frame.origin.y - y) > 0.5 || abs(shift) > 0.5 {
                button.setFrameOrigin(NSPoint(x: button.frame.origin.x + shift, y: y))
            }
        }
    }
}

private struct WindowTitlebarInteraction: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView {
        WindowTitlebarInteractionView()
    }

    func updateNSView(_ view: NSView, context _: Context) {
        let appearance = Theme.chromeAppearance
        DispatchQueue.main.async { [weak view] in
            view?.window?.appearance = appearance
        }
    }
}

private final class WindowTitlebarInteractionView: NSView {
    private static let fillRestoreFrames =
        NSMapTable<NSWindow, NSValue>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private var rememberFrameWorkItem: DispatchWorkItem?

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rememberFrameWorkItem?.cancel()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        Self.rememberNonFilledFrame(of: window)
        // The titlebar container exists but is not laid out yet while the view
        // is being moved into the window; apply on the next runloop pass.
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            TitlebarLayout.apply(to: window)
        }
        // AppKit re-lays the titlebar out mid-resize; correct it as it happens.
        if let titlebar = window.standardWindowButton(.closeButton)?.superview {
            for view in [titlebar, titlebar.superview].compactMap({ $0 }) {
                view.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(titlebarNeedsLayout(_:)),
                    name: NSView.frameDidChangeNotification,
                    object: view
                )
            }
        }
        for name in [
            NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didChangeScreenNotification,
        ] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(titlebarNeedsLayout(_:)),
                name: name,
                object: window
            )
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowFrameDidChange(_:)),
            name: NSWindow.didMoveNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowFrameDidChange(_:)),
            name: NSWindow.didResizeNotification,
            object: window
        )
    }

    deinit {
        rememberFrameWorkItem?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func titlebarNeedsLayout(_ notification: Notification) {
        guard let window = (notification.object as? NSWindow) ?? (notification.object as? NSView)?.window else { return }
        // Synchronously: a deferred pass lets AppKit's default button position
        // draw for a frame during live resize, which shows as jumping buttons.
        TitlebarLayout.apply(to: window)
    }

    @objc private func windowFrameDidChange(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        rememberFrameWorkItem?.cancel()
        let item = DispatchWorkItem { [weak window] in
            guard let window else { return }
            Self.rememberNonFilledFrame(of: window)
        }
        rememberFrameWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        guard event.clickCount == 2 else {
            window.performDrag(with: event)
            return
        }
        guard !window.styleMask.contains(.fullScreen) else { return }

        let action = UserDefaults.standard
            .string(forKey: "AppleActionOnDoubleClick")?
            .lowercased()
        switch action {
        case "fill":
            Self.toggleFill(window)
        case nil:
            if #available(macOS 15.0, *) {
                Self.toggleFill(window)
            } else {
                Self.fillRestoreFrames.removeObject(forKey: window)
                window.performZoom(nil)
            }
        case "minimize":
            Self.fillRestoreFrames.removeObject(forKey: window)
            window.performMiniaturize(nil)
        case "none":
            break
        default:
            Self.fillRestoreFrames.removeObject(forKey: window)
            window.performZoom(nil)
        }
    }

    private static func toggleFill(_ window: NSWindow) {
        guard let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else {
            return
        }
        if framesApproximatelyEqual(window.frame, visibleFrame) {
            let previous = fillRestoreFrames.object(forKey: window)?.rectValue
                ?? fallbackRestoreFrame(in: visibleFrame)
            fillRestoreFrames.removeObject(forKey: window)
            let restored = constrainedRestoreFrame(previous, for: window)
            window.setFrame(restored, display: true, animate: true)
        } else {
            fillRestoreFrames.setObject(NSValue(rect: window.frame), forKey: window)
            window.setFrame(visibleFrame, display: true, animate: true)
        }
    }

    private static func rememberNonFilledFrame(of window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen),
              let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame,
              !framesApproximatelyEqual(window.frame, visibleFrame)
        else { return }
        fillRestoreFrames.setObject(NSValue(rect: window.frame), forKey: window)
    }

    private static func fallbackRestoreFrame(in visibleFrame: NSRect) -> NSRect {
        visibleFrame.insetBy(
            dx: visibleFrame.width * 0.1,
            dy: visibleFrame.height * 0.1
        )
    }

    private static func framesApproximatelyEqual(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 1
            && abs(lhs.minY - rhs.minY) < 1
            && abs(lhs.width - rhs.width) < 1
            && abs(lhs.height - rhs.height) < 1
    }

    private static func constrainedRestoreFrame(_ frame: NSRect, for window: NSWindow) -> NSRect {
        let intersectingScreen = NSScreen.screens
            .map { screen in
                let intersection = frame.intersection(screen.visibleFrame)
                let area = intersection.isNull ? 0 : intersection.width * intersection.height
                return (screen, area)
            }
            .max { $0.1 < $1.1 }
        let screen = if let intersectingScreen, intersectingScreen.1 > 0 {
            intersectingScreen.0
        } else {
            window.screen ?? NSScreen.main
        }
        guard let screen else { return frame }
        return window.constrainFrameRect(frame, to: screen)
    }
}

private struct WindowTitlebarInteractionModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(WindowTitlebarInteraction())
    }
}

extension View {
    func windowTitlebarInteraction() -> some View {
        modifier(WindowTitlebarInteractionModifier())
    }
}

enum DetailMetrics {
    /// Gap right of and below the terminal; equals the gap between the titlebar
    /// tab strip and the terminal (titlebar 52pt, strip 36pt).
    static let terminalMargin: CGFloat = 8
    static let terminalCornerRadius: CGFloat = 10
    /// Glass rim around the terminal on macOS 26+; the outer slab radius is concentric.
    static let glassInset: CGFloat = 1.5
}

struct DetailView: View {
    @ObservedObject var model: AppModel
    @Binding var sidebarCollapsed: Bool
    /// A zoomed split hides the sidebar altogether, rail included.
    var sidebarHidden = false
    @State private var hasOpenedFileManager = false
    @State private var showUsage = false

    var body: some View {
        VStack(spacing: 0) {
            // No background of its own: the view's background below already paints
            // this surface, and a second translucent layer would hide the image.
            titlebar
                .zIndex(1)
            detailContent
                .clipShape(RoundedRectangle(cornerRadius: DetailMetrics.terminalCornerRadius, style: .continuous))
                .terminalPanelGlass(leadingMargin: sidebarHidden)
                // Losing the selected agent tears the SplitContainer down without
                // resetting the axis, which would leave the same phantom split.
                //
                // Load-bearing beyond that: this is the ONLY thing that clears the axis
                // when the agent goes away. `dismantleNSView` nils the coordinator's
                // onExit before killing the shell, so the shell's own onExit never fires
                // on teardown. Remove this and "split open with no agent selected"
                // becomes reachable, which is a state a deferred focus request can be
                // armed into with nothing left in the tree to consume it.
                .onChange(of: model.selectedAttachedEntry?.id) { _, id in
                    if id == nil {
                        model.shellSplitAxis = nil
                        // The placeholder tore every kept-alive attach down along with
                        // the SplitContainer. Empty the session list and per-entry state
                        // so a later selection doesn't resurrect them all at once.
                        model.attachSessions = []
                        endedAttach = [:]
                        attachRetry = [:]
                    }
                }
                .onChange(of: model.isFileManagerActive) { _, active in
                    if active { hasOpenedFileManager = true }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.contentBackground.ignoresSafeArea())
        .overlay(alignment: .topTrailing) { usagePanel }
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: showUsage)
        .onChange(of: model.selectedAttachedEntry?.id) { _, _ in showUsage = false }
    }

    /// Details and usage of the selected agent or terminal, shown by the titlebar info button.
    private var selectedInfo: TitlebarInfo? {
        guard model.selectedShellID == nil, !model.isFileManagerActive,
              let attached = model.selectedAttachedEntry
        else { return nil }
        switch attached {
        case .agent(let entry):
            let agent = entry.agent
            return TitlebarInfo(
                agentKind: agent.agent,
                title: entry.title,
                spaceName: model.spaceName(deviceID: entry.device.id, workspaceID: agent.workspaceID),
                device: entry.device,
                status: agent.status,
                cwd: agent.cwd,
                usage: agent.usage
            )
        case .terminal(let entry):
            return TitlebarInfo(
                agentKind: nil,
                title: entry.title,
                spaceName: model.spaceName(deviceID: entry.device.id, workspaceID: entry.pane.workspaceID),
                device: entry.device,
                status: nil,
                cwd: entry.pane.cwd,
                usage: nil
            )
        }
    }

    /// Trailing titlebar button, identical with or without the tab strip.
    @ViewBuilder
    private var infoButton: some View {
        if let info = selectedInfo {
            Button { showUsage.toggle() } label: {
                HStack(spacing: 6) {
                    if info.status == .blocked { statusGlyph(.blocked) }
                    if let kind = info.agentKind {
                        AgentKindBadge(kind: kind)
                    } else {
                        Image(systemName: "terminal")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textGhost)
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .selectedTabGlass(true)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Info & Usage")
            .accessibilityIdentifier("titlebar.usage")
        }
    }

    @ViewBuilder
    private var usagePanel: some View {
        if showUsage, let info = selectedInfo {
            ZStack(alignment: .topTrailing) {
                Color.black.opacity(0.001)
                    .onTapGesture { showUsage = false }
                UsagePopover(info: info, showsDevice: model.showsRowDeviceBadges)
                    .padding(.top, TitlebarMetrics.height + 6)
                    .padding(.trailing, 12)
                    .transition(.scale(scale: 0.96, anchor: .topTrailing).combined(with: .opacity))
                    .background(
                        Button("") { showUsage = false }
                            .keyboardShortcut(.cancelAction)
                            .hidden()
                    )
            }
        }
    }

    private var detailContent: some View {
        ZStack {
            terminal
                .clipped()
                .opacity(model.isFileManagerActive ? 0 : 1)
                .allowsHitTesting(!model.isFileManagerActive)
            if hasOpenedFileManager {
                DeviceFilesView(model: model)
                    .opacity(model.isFileManagerActive ? 1 : 0)
                    .allowsHitTesting(model.isFileManagerActive)
            }
        }
        .onAppear {
            if model.isFileManagerActive { hasOpenedFileManager = true }
        }
    }

    // MARK: - Titlebar strip (TitlebarMetrics.height)

    /// The space whose tabs the titlebar shows, if any.
    private var titlebarTabSpace: SpaceRef? {
        guard let space = tabbedSpace, !(hideSingleTabBar && model.tabs(in: space).count == 1)
        else { return nil }
        return space
    }

    /// The space whose tabs apply to the current selection, regardless of the hide-single-tab option.
    private var tabbedSpace: SpaceRef? {
        guard let space = model.tabBarSpace, model.selectedShellID == nil, !model.isFileManagerActive,
              !model.tabs(in: space).isEmpty
        else { return nil }
        return space
    }

    private var titlebar: some View {
        HStack(spacing: 8) {
            if sidebarHidden {
                // No rail: only the traffic lights need clearing.
                Spacer().frame(width: TitlebarMetrics.trafficLightClearance - 10 - 8)
            } else if sidebarCollapsed {
                // The rail sits under the traffic lights, so only the rest needs clearing.
                // Subtract the strip's leading padding (10) and the HStack spacing (8) too,
                // so the toggle lands at the same x as the expanded sidebar's toggle.
                Spacer().frame(width: TitlebarMetrics.trafficLightClearance - SidebarRail.width - 10 - 8)
                TitlebarIconButton(systemName: "sidebar.left", help: "Show Sidebar (⌘B)") {
                    sidebarCollapsed = false
                }
                TitlebarActionsMenu(model: model)
            }
            if let space = titlebarTabSpace {
                compactTitle
                SpaceTabBar(model: model, space: space)
                infoButton
            } else {
            Group {
                if model.isFileManagerActive {
                    Group {
                        Image(systemName: "folder")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                        Text("Files")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.text)
                    }
                    .allowsHitTesting(false)
                    Spacer()
                } else if let shell = model.selectedShell {
                    Group {
                        Image(systemName: "terminal")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                        Text(shell.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.text)
                        Text(shell.device.name)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .allowsHitTesting(false)
                    Spacer()
                } else if let attached = model.selectedAttachedEntry {
                    switch attached {
                    case .agent(let entry):
                        let agent = entry.agent
                        // Only the info button takes clicks; the rest stays inert so
                        // the strip keeps dragging the window (see the Group below).
                        statusGlyph(agent.status).allowsHitTesting(false)
                        Text(entry.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .layoutPriority(1)
                            .help((agent.cwd as NSString?)?.abbreviatingWithTildeInPath ?? "")
                            .allowsHitTesting(false)
                        newTabButton
                        Spacer(minLength: 12)
                        infoButton
                    case .terminal(let entry):
                        Image(systemName: "terminal")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .allowsHitTesting(false)
                        Text(entry.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .layoutPriority(1)
                            .help((entry.pane.cwd as NSString?)?.abbreviatingWithTildeInPath ?? "")
                            .allowsHitTesting(false)
                        newTabButton
                        Spacer(minLength: 12)
                        infoButton
                    }
                } else {
                    Text("No terminal selected")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .allowsHitTesting(false)
                    Spacer()
                }
            }
            }
        }
        .padding(.leading, sidebarCollapsed ? 10 : 14)
        .padding(.trailing, 12)
        .frame(height: TitlebarMetrics.height)
        .windowTitlebarInteraction()
    }

    /// "New tab" beside the title while the tab strip is hidden for a lone tab.
    @ViewBuilder
    private var newTabButton: some View {
        if let space = tabbedSpace {
            Button { model.newTab(in: space) } label: {
                TitlebarIconLabel(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help("New Tab")
        }
    }

    /// Name-only title shown beside the titlebar tabs; the rest moves to the tooltip.
    @ViewBuilder
    private var compactTitle: some View {
        if let attached = model.selectedAttachedEntry {
            HStack(spacing: 6) {
                switch attached {
                case .agent(let entry):
                    statusGlyph(entry.agent.status)
                    Text(entry.title)
                        .help("\(model.spaceName(deviceID: entry.device.id, workspaceID: entry.agent.workspaceID)) · \(entry.device.name)")
                case .terminal(let entry):
                    Image(systemName: "terminal")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Text(entry.title)
                        .help("\(model.spaceName(deviceID: entry.device.id, workspaceID: entry.pane.workspaceID)) · \(entry.device.name)")
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .frame(maxWidth: 160, alignment: .leading)
        }
    }

    @ViewBuilder
    private func statusGlyph(_ status: AgentStatus) -> some View {
        switch status {
        case .working:
            EmptyView()
        case .blocked:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.warning)
        case .done:
            EmptyView()
        case .idle, .unknown:
            EmptyView()
        }
    }

    // MARK: - Terminal

    @AppStorage(TerminalDefaults.fontNameKey) private var terminalFontName = ""
    @AppStorage(TerminalDefaults.fontSizeKey) private var terminalFontSize = TerminalDefaults.defaultFontSize
    @AppStorage(TerminalDefaults.thinStrokesKey) private var terminalThinStrokes = true
    @AppStorage(TerminalDefaults.fontWeightKey) private var terminalFontWeight = TerminalDefaults.defaultFontWeight
    @AppStorage(TerminalDefaults.lineSpacingKey) private var terminalLineSpacing = TerminalDefaults.defaultLineSpacing
    @AppStorage(TerminalThemeSetting.key) private var terminalThemeName = ""
    @AppStorage(Theme.windowBackgroundKey) private var windowBackgroundMode = Theme.defaultWindowBackgroundMode
    @AppStorage(Theme.backgroundImagePathKey) private var backgroundImagePath = ""
    @AppStorage(Theme.backgroundOverlayKey) private var backgroundOverlay = Theme.defaultBackgroundOverlay
    @AppStorage("terminal.mouseReporting") private var terminalMouseReporting = true
    @AppStorage("terminal.copyOnSelect") private var terminalCopyOnSelect = true
    @AppStorage("tabs.hideWhenSingle") private var hideSingleTabBar = true
    @AppStorage("editorDrawerRatio") private var editorDrawerRatio = EditorDrawerLayout.defaultRatio
    @Environment(\.colorScheme) private var colorScheme
    /// Per-entry attach state, keyed by `AttachedEntry.id`. `endedAttach` holds the exit
    /// code of a dead attach (nil code = no status, e.g. killed by a signal); a present
    /// key drives that entry's reconnect overlay. `attachRetry` is a generation the
    /// Reconnect button bumps to rebuild just that one terminal. Per-entry so one dead
    /// terminal's overlay never covers another and Reconnect rebuilds only its own.
    @State private var endedAttach: [String: Int32?] = [:]
    @State private var attachRetry: [String: Int] = [:]
    @State private var uploadingAttachment = false
    @State private var splitTracker = SplitFocusTracker()

    @ViewBuilder
    private var terminal: some View {
        VStack(spacing: 0) {
            DrawerSplit(
                isOpen: model.visibleEditorDrawerID != nil || model.visiblePreview != nil,
                isZoomed: model.visiblePreview?.isZoomed == true,
                ratio: $editorDrawerRatio
            ) {
                terminalStack
                    .overlay {
                        Rectangle()
                            .fill(Theme.terminalBackground.opacity(model.dimsTerminalForPreview ? 0.6 : 0))
                            .animation(.easeInOut(duration: 0.15), value: model.dimsTerminalForPreview)
                            .allowsHitTesting(false)
                    }
            } drawer: {
                ZStack {
                    EditorDrawerStack(model: model)
                    PreviewDrawerStack(model: model)
                }
            }
        }
    }

    @ViewBuilder
    private var terminalStack: some View {
        ZStack {
            attachedTerminal
            // Standalone shells stay in the hierarchy while deselected: unlike a
            // herdr pane, an app-owned shell has no server side to reattach to,
            // so tearing the view down would kill whatever is running in it.
            ForEach(model.shellSessions) { session in
                ShellTerminalView(
                    sessionID: session.id,
                    device: session.device,
                    fontName: terminalFontName,
                    fontSize: terminalFontSize,
                    thinStrokes: terminalThinStrokes,
                    fontWeight: terminalFontWeight,
                    lineSpacing: terminalLineSpacing,
                    dark: colorScheme == .dark,
                    themeName: terminalThemeName,
                    mouseReporting: terminalMouseReporting,
                    copyOnSelect: terminalCopyOnSelect,
                    isVisible: model.selectedShellID == session.id && !model.isFileManagerActive,
                    onAttachmentError: { model.actionError = $0 },
                    onAttachmentUploadingChanged: { uploadingAttachment = $0 },
                    onExit: { _ in model.closeShellSession(session.id) }
                )
                    .id("shell-\(session.id)")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    // Solid backdrop inside the opacity compositing group so
                    // glyph AA on Ghostty's non-opaque Metal layer stays crisp
                    // (see attachChild) instead of rendering pale.
                    .background(Theme.terminalBackground)
                    .opacity(model.selectedShellID == session.id ? 1 : 0)
                    .allowsHitTesting(model.selectedShellID == session.id)
            }
        }
        .background(Theme.terminalBackground)
        .overlay(alignment: .bottomTrailing) {
            // The attach side shows its own; this covers standalone shells.
            if uploadingAttachment, model.selectedShellID != nil { uploadIndicator }
        }
    }

    @ViewBuilder
    private var attachedTerminal: some View {
        if let entry = model.selectedAttachedEntry {
            SplitContainer(
                axis: model.shellSplitAxis,
                activeSide: model.activeSplitSide,
                ratio: $model.splitRatio
            ) {
                // One structural position holding every kept-alive attach. Each child
                // keeps a stable identity and is toggled by opacity, so switching the
                // selection — or opening/closing the split — never tears a terminal
                // down: its content survives the round trip. Do not key this on the
                // selection; that rebuild-on-switch is exactly what this removes.
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        ForEach(model.attachSessions) { session in
                            let frame = placement(for: session, in: proxy.size)
                            attachChild(session, isSelected: session.id == entry.id, placed: frame != nil)
                                .frame(
                                    width: frame?.width ?? proxy.size.width,
                                    height: frame?.height ?? proxy.size.height
                                )
                                .offset(x: frame?.minX ?? 0, y: frame?.minY ?? 0)
                        }
                        if let layout = splitLayout {
                            SplitDividersOverlay(layout: layout, size: proxy.size) { divider, ratio in
                                model.commitSplitRatio(divider: divider, ratio: ratio)
                            }
                        }
                    }
                    .coordinateSpace(name: "terminalArea")
                }
            } second: {
                ShellTerminalView(
                    fontName: terminalFontName,
                    fontSize: terminalFontSize,
                    thinStrokes: terminalThinStrokes,
                    fontWeight: terminalFontWeight,
                    lineSpacing: terminalLineSpacing,
                    dark: colorScheme == .dark,
                    themeName: terminalThemeName,
                    mouseReporting: terminalMouseReporting,
                    copyOnSelect: terminalCopyOnSelect,
                    isVisible: model.selectedShellID == nil && !model.isFileManagerActive,
                    onExit: { _ in model.shellSplitAxis = nil },
                    onViewReady: {
                        splitTracker.shellView = $0
                        model.splitShellView = $0
                    }
                )
                    // Deliberately not keyed on colorScheme like the attach above:
                    // a new id tears the view down and kills the shell with whatever
                    // was running in it, and unlike a herdr pane a local shell has no
                    // server-side state to reattach to. updateNSView re-themes it.
                    .id("shell")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.terminalBackground)
            .overlay(alignment: .bottomTrailing) {
                if uploadingAttachment { uploadIndicator }
            }
            .onAppear {
                // Single source of truth: the tracker writes straight into the model
                // instead of holding its own copy for a second onChange to mirror.
                splitTracker.onSideChanged = { model.activeSplitSide = $0 }
                splitTracker.isAgentView = { view in
                    AttachViewRegistry.liveViews.contains { $0 === view }
                }
                splitTracker.start()
            }
            .onChange(of: entry.id) { _, newID in
                uploadingAttachment = false
                // A re-selected kept-alive view does not self-focus (makeNSView ran once
                // at creation), so hand it the keyboard explicitly — matching how every
                // selection used to focus the freshly built terminal.
                AttachViewRegistry.focus(newID)
            }
            // Keyed on the window becoming key rather than on a delay: that is the event
            // that follows the sheet's responder restore. Filtered to the terminal's own
            // window and consumed no matter which window it was, so a pending request can
            // never survive to a later, unrelated activation — coming back from ⌘Tab or
            // closing Settings would otherwise yank the keyboard into a live pane.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                guard model.pendingSplitAgentFocus else { return }
                model.pendingSplitAgentFocus = false
                guard let window = note.object as? NSWindow,
                      window === model.splitAgentView?.window
                else { return }
                focusTerminal(model.splitAgentView)
            }
            // Splitting moves the keyboard to the shell, so closing the split has to
            // hand it back — by ⌘W or by the shell exiting on its own. Reset the
            // tracked side to the agent so the next split starts predictably.
            .onChange(of: model.shellSplitAxis) { _, axis in
                if axis == nil {
                    model.activeSplitSide = .agent
                    model.pendingSplitAgentFocus = false
                    focusRemainingTerminal(preferring: model.splitAgentView)
                }
            }
        } else {
            // The .onReceive below only exists on the branch above, so a request armed
            // while no pane is selected would have no consumer and would be cashed in by
            // some later activation. Revealing a pane that has since gone away lands here.
            VStack(spacing: 10) {
                Image(systemName: "terminal")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Theme.textGhost)
                Text(placeholderText)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                if showsStartAgentShortcut {
                    Button("New Agent…") {
                        model.showNewAgent = true
                    }
                    .controlSize(.small)
                } else if model.hasReconnectableDevice {
                    Button("Reconnect") {
                        model.reconnectFailedDevices()
                    }
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.terminalBackground)
            .onAppear { model.pendingSplitAgentFocus = false }
        }
    }

    /// The layout to draw, or nil when only the selected pane shows (single
    /// pane, zoomed, or data that could not be reconciled).
    private var splitLayout: AppModel.ActiveLayout? {
        guard let layout = model.activeLayout, !layout.zoomed,
              let selected = model.selectedPane,
              layout.deviceID == selected.deviceID,
              layout.tree.contains(paneID: selected.paneID)
        else { return nil }
        return layout
    }

    /// Pixel frame of an attach child inside the terminal area, or nil when it
    /// is not part of the visible arrangement (then the old rule applies:
    /// full-size, visible only if it is the selected pane).
    private func placement(for session: AppModel.AttachedEntry, in size: CGSize) -> CGRect? {
        guard let layout = splitLayout, session.ref.deviceID == layout.deviceID,
              let unit = layout.tree.frames()[session.ref.paneID]
        else { return nil }
        return CGRect(
            x: unit.x * size.width, y: unit.y * size.height,
            width: unit.width * size.width, height: unit.height * size.height
        )
    }

    /// One kept-alive attach. Stays in the hierarchy while deselected (opacity 0, no hit
    /// testing) so its content survives; the selected one is visible and interactive.
    @ViewBuilder
    private func attachChild(_ session: AppModel.AttachedEntry, isSelected: Bool, placed: Bool) -> some View {
        let attachmentCapabilities: AgentAttachmentCapabilities? = {
            guard case .agent(let agentEntry) = session else { return nil }
            return model.attachmentCapabilities(for: agentEntry)
        }()
        ZStack {
            AttachTerminalView(
                device: session.device,
                target: session.attachTarget,
                sessionID: session.id,
                serverVersion: model.serverVersion(deviceID: session.device.id),
                attachmentCapabilities: attachmentCapabilities,
                fontName: terminalFontName,
                fontSize: terminalFontSize,
                thinStrokes: terminalThinStrokes,
                fontWeight: terminalFontWeight,
                lineSpacing: terminalLineSpacing,
                dark: colorScheme == .dark,
                    themeName: terminalThemeName,
                mouseReporting: terminalMouseReporting,
                copyOnSelect: terminalCopyOnSelect,
                // A selected shell or the file manager covers the attach side.
                isVisible: (isSelected || placed) && model.selectedShellID == nil && !model.isFileManagerActive,
                onAttachmentError: { model.actionError = $0 },
                onAttachmentUploadingChanged: { uploadingAttachment = $0 },
                onFocused: { model.focusLayoutPane(session.ref.paneID) },
                focusOnCreate: isSelected,
                onExit: { code in endedAttach[session.id] = code }
            )
                // Keyed on the retry generation only — NOT colorScheme. A theme toggle
                // must re-theme live via updateNSView (as the split shell already does);
                // rebuilding here would tear down every kept-alive terminal at once and
                // throw away the very content this keeps alive.
                .id("attach-\(session.id)-\(attachRetry[session.id] ?? 0)")
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            if isSelected, endedAttach[session.id] != nil {
                attachEndedOverlay(session)
            }
        }
        // Ghostty's Metal layer is non-opaque (clear background), and the
        // `.opacity` below forces SwiftUI to composite this child offscreen —
        // where glyph anti-aliasing falls back to a transparent backdrop and
        // renders pale (worst on dense CJK strokes). A solid backdrop inside
        // the compositing group gives the text an opaque background to blend
        // against, matching the pre-keep-alive single-view rendering.
        .background(Theme.terminalBackground)
        .opacity(isSelected || placed ? 1 : 0)
        .allowsHitTesting(isSelected || placed)
        .overlay {
            // In a split every pane keeps a neutral border; focus shows by
            // dimming the others, not by a coloured outline.
            if placed {
                ZStack {
                    Rectangle().fill(Theme.terminalBackground.opacity(isSelected ? 0 : 0.6))
                    Rectangle().strokeBorder(Theme.hairline, lineWidth: 1)
                }
                .animation(.easeInOut(duration: 0.15), value: isSelected)
                .allowsHitTesting(false)
            }
        }
    }

    /// ssh exits 255 for transport failures; everything else is the far end closing
    /// (takeover by another client, the pane going away, herdr stopping).
    private func attachEndedOverlay(_ entry: AppModel.AttachedEntry) -> some View {
        let dropped = (endedAttach[entry.id] ?? nil) == 255
        return VStack(spacing: 10) {
            Image(systemName: dropped ? "bolt.horizontal.circle" : "rectangle.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.textGhost)
            Text(dropped ? String(localized: "Connection to \(entry.device.name) dropped") : String(localized: "Terminal session ended"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
            Text(dropped
                ? String(localized: "The SSH connection behind this terminal went away.")
                : String(localized: "Another client took this pane over, or the attach closed."))
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
            Button("Reconnect") {
                endedAttach[entry.id] = nil
                attachRetry[entry.id, default: 0] += 1
            }
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.terminalBackground.opacity(0.94))
    }

    private var uploadIndicator: some View {
        HStack(spacing: 6) {
            Text("Uploading…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(.trailing, 20)
        .padding(.bottom, 18)
    }

    private var showsStartAgentShortcut: Bool {
        if case .connected = model.connection { return true }
        return false
    }

    private var placeholderText: String {
        switch model.connection {
        case .connecting: return String(localized: "Connecting…")
        case .failed(let reason): return reason
        default:
            if model.selectedSpace != nil
                && model.visibleAgents.isEmpty
                && model.visibleTerminals.isEmpty {
                return String(localized: "No agents or terminals in this space yet")
            }
            return String(localized: "Select an agent or terminal, or start a new one")
        }
    }

}

struct AddDeviceSheet: View {
    enum Transport: String, CaseIterable {
        case ssh
        case tailcat
    }

    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var target = ""
    @State private var transport: Transport = .ssh
    @State private var token = ""

    private var canAdd: Bool {
        switch transport {
        case .ssh: return !target.trimmingCharacters(in: .whitespaces).isEmpty
        case .tailcat: return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "desktopcomputer",
                title: String(localized: "Add Device"),
                subtitle: transport == .ssh
                    ? String(localized: "Uses OpenSSH config, agent, Tailscale SSH, or password")
                    : String(localized: "WireGuard tunnel to a herdr behind NAT — no VPN, no account")
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $transport) {
                    Text(String(localized: "SSH")).tag(Transport.ssh)
                    Text(String(localized: "Tailcat")).tag(Transport.tailcat)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Spacer().frame(height: 4)
                SheetSectionLabel("NAME")
                TextField("mac-studio", text: $name)
                    .textFieldStyle(.roundedBorder)
                Spacer().frame(height: 8)
                if transport == .ssh {
                    SheetSectionLabel("SSH TARGET")
                    TextField("vincent@10.10.10.87", text: $target)
                        .textFieldStyle(.roundedBorder)
                    Text("user@host, a ~/.ssh/config alias, or user@host:port for a custom port.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    SheetSectionLabel("TAILCAT TOKEN")
                    TextField("tcpGFwWCD…", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    Text("On the remote Mac: `herdr plugin install lbr77/herdr-plugin-tailcat`, then `herdr plugin action invoke herdr.tailcat.token` and paste the token here. The WireGuard tunnel is built in — no external tool. The token is stored in the Keychain. Standalone shells and the Files workspace need SSH.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer().frame(height: 8)
                    SheetSectionLabel("CLIENT PUBLIC KEY")
                    TailcatClientKeyRow(publicKey: model.tailcatClientPublicKey)
                    Text("If the host uses an allow list, add this key to it so only this Mac can connect: one key per line in `allow.list` under `herdr plugin config-dir herdr.tailcat`, then `herdr plugin action invoke herdr.tailcat.restart`.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .onAppear { model.loadTailcatClientPublicKey() }
                }
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Device") {
                    let trimmedName = name.trimmingCharacters(in: .whitespaces)
                    switch transport {
                    case .ssh:
                        let trimmedTarget = target.trimmingCharacters(in: .whitespaces)
                        model.addDevice(
                            name: trimmedName.isEmpty ? trimmedTarget : trimmedName,
                            sshTarget: trimmedTarget
                        )
                    case .tailcat:
                        model.addTailcatDevice(
                            name: trimmedName.isEmpty ? String(localized: "Tailcat Device") : trimmedName,
                            token: token.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 400)
    }
}

/// The tailcat client public key as selectable text with a Copy button.
/// Shared by the Add Device sheet and the Tailcat settings tab.
struct TailcatClientKeyRow: View {
    let publicKey: String?
    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(publicKey ?? "—")
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                // A nodekey is wider than the sheet; wrap rather than truncate
                // so the whole key stays visible and selectable.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? String(localized: "Copied") : String(localized: "Copy")) {
                guard let publicKey else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(publicKey, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    copied = false
                }
            }
            .controlSize(.small)
            .disabled(publicKey == nil)
        }
    }
}

struct SSHAuthenticationSheet: View {
    @ObservedObject var model: AppModel
    let request: SSHAuthenticationRequest
    @State private var password = ""
    @FocusState private var passwordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "key.fill",
                title: String(localized: "SSH Authentication"),
                subtitle: request.target
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                SheetSectionLabel("PASSWORD")
                SecureField("SSH password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($passwordFocused)
                Label(String(localized: "Saved in your macOS login Keychain"), systemImage: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") {
                    model.cancelSSHAuthentication(for: request)
                }
                .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    model.saveSSHPassword(password, for: request)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 400)
        .onAppear { passwordFocused = true }
    }
}

/// Shared chrome for the app's sheets: icon-badge header, hairline sections, footer actions.
struct SheetHeader: View {
    let systemImage: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(Theme.accentWash, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
        }
        .padding(16)
    }
}

struct SheetSectionLabel: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .kerning(0.4)
            .foregroundStyle(Theme.textTertiary)
    }
}

struct NewTerminalSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var deviceID = Device.local.id
    @State private var workspaceID = ""

    private var chosenDevice: Device {
        model.device(deviceID) ?? .local
    }

    private var spaces: [WorkspaceInfo] {
        model.session(deviceID).workspaces
    }

    private var isStandalone: Bool { workspaceID.isEmpty }

    private var spaceLabel: String {
        spaces.first { $0.workspaceID == workspaceID }?.label ?? String(localized: "a Herdr space")
    }

    private var subtitle: String {
        if isStandalone {
            return chosenDevice.isLocal
                ? String(localized: "Start a login shell on this Mac")
                : String(localized: "Connect to \(chosenDevice.name) over SSH")
        }
        return String(localized: "Creates a persistent shell in \(spaceLabel) on \(chosenDevice.name)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "terminal",
                title: String(localized: "New Terminal"),
                subtitle: subtitle
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                if model.showsDeviceBadges {
                    SheetSectionLabel("DEVICE")
                    Picker("", selection: $deviceID) {
                        ForEach(model.devices) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: deviceID) { _, _ in
                        workspaceID = spaces.first?.workspaceID ?? ""
                    }

                    Spacer().frame(height: 8)
                }

                SheetSectionLabel("SPACE")
                // A herdr space gives a persistent, reattachable server-owned
                // shell; Standalone is an app-owned process (plain login shell
                // or ssh) that needs no herdr on the device at all.
                Picker("", selection: $workspaceID) {
                    ForEach(spaces) { workspace in
                        Text(workspace.label).tag(workspace.workspaceID)
                    }
                    Text("Standalone (not in a space)").tag("")
                }
                .labelsHidden()
                .fixedSize()
                if isStandalone {
                    Text("Runs in this app only; closing MacHerdr ends the shell.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open Terminal") {
                    if isStandalone {
                        model.newShellSession(on: chosenDevice)
                    } else {
                        model.startNewTerminal(device: chosenDevice, workspaceID: workspaceID)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 420)
        .onAppear {
            deviceID = model.selectedSpace?.deviceID
                ?? model.selectedAttachedEntry?.device.id
                ?? model.deviceFilter
                ?? model.devices.first?.id
                ?? Device.local.id
            let preferredSpace = model.selectedSpace?.deviceID == deviceID
                ? model.selectedSpace?.workspaceID
                : model.selectedAttachedEntry.flatMap {
                    $0.device.id == deviceID ? $0.workspaceID : nil
                }
            workspaceID = preferredSpace.flatMap { preferred in
                spaces.contains { $0.workspaceID == preferred } ? preferred : nil
            } ?? spaces.first?.workspaceID ?? ""
        }
    }
}

struct NewAgentSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var deviceID = Device.local.id
    @State private var kind = ""
    @State private var workspaceID: String = ""
    @AppStorage("agent.bypassDefault") private var bypass = true

    private var chosenDevice: Device {
        model.device(deviceID) ?? .local
    }

    private var session: DeviceSessionState {
        model.session(deviceID)
    }

    private var kinds: [String] {
        session.agentCatalog.kinds
    }

    private var bypassFlags: [String]? {
        HerdrService.bypassFlags(for: kind)
    }

    private var spaceLabel: String {
        if workspaceID.isEmpty, session.workspaces.isEmpty, case .connected = session.connection {
            return chosenDevice.isLocal
                ? String(localized: "a new space in your home folder")
                : String(localized: "a new space")
        }
        if workspaceID.isEmpty { return String(localized: "the focused space") }
        return session.workspaces.first { $0.workspaceID == workspaceID }?.label ?? workspaceID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "sparkles",
                title: String(localized: "New Agent"),
                subtitle: String(localized: "Starts in \(spaceLabel), attached to its live terminal")
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                if model.showsDeviceBadges {
                    SheetSectionLabel("DEVICE")
                    Picker("", selection: $deviceID) {
                        ForEach(model.devices) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: deviceID) { _, _ in
                        workspaceID = ""
                        if !kinds.contains(kind) { kind = kinds.first ?? "" }
                    }

                    Spacer().frame(height: 8)
                }

                SheetSectionLabel("AGENT")
                Group {
                    switch session.agentCatalog {
                    case .loading:
                        HStack(spacing: 8) {
                            Text(String(localized: "Checking agents on \(chosenDevice.name)…"))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                    case .failed(let message):
                        VStack(alignment: .leading, spacing: 8) {
                            Text(chosenDevice.isLocal
                                ? String(localized: "Couldn’t check installed agent CLIs.")
                                : String(localized: "Couldn’t load this server’s agent catalog."))
                                .foregroundStyle(Theme.textSecondary)
                            Text(message)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(2)
                            Button("Retry") { model.reloadAgentCatalog(deviceID: deviceID) }
                                .controlSize(.small)
                        }
                        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                    case .loaded(let loadedKinds, _) where loadedKinds.isEmpty:
                        Text(chosenDevice.isLocal
                            ? String(localized: "No supported agent CLI was found on this Mac. Install one, or set a binary path in Settings → Agents.")
                            : String(localized: "This server advertises no agent manifests."))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                    case .loaded(let loadedKinds, let paths):
                        ScrollView {
                            LazyVGrid(
                                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                                spacing: 8
                            ) {
                                ForEach(loadedKinds, id: \.self) { name in
                                    kindCell(name, path: paths[name])
                                }
                            }
                            .padding(1)
                        }
                        .frame(maxHeight: 236)
                    }
                }

                Spacer().frame(height: 8)

                SheetSectionLabel("SPACE")
                Picker("", selection: $workspaceID) {
                    Text("Focused space").tag("")
                    ForEach(session.workspaces) { workspace in
                        Text(workspace.label).tag(workspace.workspaceID)
                    }
                }
                .labelsHidden()
                .fixedSize()

                // shown only for agents with a verified bypass flag
                if let flags = bypassFlags {
                    Spacer().frame(height: 8)

                    SheetSectionLabel("OPTIONS")
                    Toggle(isOn: $bypass) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Bypass permissions")
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.text)
                            Text(flags.joined(separator: " "))
                                .font(.system(size: 10.5).monospaced())
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Agent") {
                    model.startNewAgent(
                        device: chosenDevice,
                        kind: kind,
                        workspaceID: workspaceID.isEmpty ? nil : workspaceID,
                        bypass: bypass && bypassFlags != nil
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!kinds.contains(kind))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 480)
        .onAppear {
            deviceID = model.selectedSpace?.deviceID
                ?? model.deviceFilter
                ?? model.devices.first?.id
                ?? Device.local.id
            workspaceID = model.selectedSpace?.deviceID == deviceID
                ? (model.selectedSpace?.workspaceID ?? "")
                : ""
            if !kinds.contains(kind) { kind = kinds.first ?? "" }
        }
        .onChange(of: kinds) { _, newKinds in
            if !newKinds.contains(kind) { kind = newKinds.first ?? "" }
        }
    }

    private func kindCell(_ name: String, path: String?) -> some View {
        let selected = kind == name
        return Button {
            kind = name
        } label: {
            VStack(spacing: 6) {
                Group {
                    if let resource = BrandIconLoader.agentIcon(for: name) {
                        BrandIcon(resource: resource, size: 20)
                    } else {
                        Image(systemName: "terminal")
                            .font(.system(size: 16))
                    }
                }
                .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                Text(name)
                    .font(.system(size: 11, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Theme.text : Theme.textSecondary)
                    .lineLimit(1)
            }
            .help(path ?? "")
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(selected ? AnyShapeStyle(Theme.accentWash) : AnyShapeStyle(Theme.itemWash))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(selected ? Theme.accent : .clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }
}

struct RenameSpaceSheet: View {
    @ObservedObject var model: AppModel
    let entry: AppModel.SpaceEntry
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "pencil",
                title: String(localized: "Rename Space"),
                subtitle: String(localized: "Rename \(entry.workspace.label) on \(entry.device.name)")
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                SheetSectionLabel("NAME")
                TextField("Space name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    model.renameSpace(entry, label: name)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty || trimmedName == entry.workspace.label)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 400)
        .onAppear { name = entry.workspace.label }
    }
}

struct RenameAgentSheet: View {
    @ObservedObject var model: AppModel
    let entry: AppModel.AgentEntry
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "pencil",
                title: String(localized: "Rename Agent"),
                subtitle: String(localized: "Rename \(entry.title) on \(entry.device.name)")
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                SheetSectionLabel("NAME")
                TextField("Agent name", text: $name)
                    .textFieldStyle(.roundedBorder)
                Text("Chinese, spaces, and punctuation are allowed.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    model.renameAgent(entry, name: name)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty || trimmedName == entry.title)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 400)
        .onAppear { name = entry.title }
    }
}

struct RenameTerminalSheet: View {
    @ObservedObject var model: AppModel
    let entry: AppModel.TerminalEntry
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "pencil",
                title: String(localized: "Rename Terminal"),
                subtitle: String(localized: "Rename \(entry.title) on \(entry.device.name)")
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                SheetSectionLabel("NAME")
                TextField("Terminal name", text: $name)
                    .textFieldStyle(.roundedBorder)
                Text("Chinese, spaces, and punctuation are allowed.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    model.renameTerminal(entry, name: name)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty || trimmedName == entry.title)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 400)
        .onAppear { name = entry.title }
    }
}

struct EditDeviceSheet: View {
    @ObservedObject var model: AppModel
    let device: Device
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var target = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                systemImage: "pencil",
                title: String(localized: "Edit Device"),
                subtitle: String(localized: "Changing the SSH target reconnects the device")
            )
            Rectangle().fill(Theme.hairline).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                SheetSectionLabel("NAME")
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                Spacer().frame(height: 8)
                SheetSectionLabel("SSH TARGET")
                TextField("SSH target", text: $target)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(16)

            Rectangle().fill(Theme.hairline).frame(height: 1)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let trimmedName = name.trimmingCharacters(in: .whitespaces)
                    let trimmedTarget = target.trimmingCharacters(in: .whitespaces)
                    model.updateDevice(
                        device.id,
                        name: trimmedName.isEmpty ? trimmedTarget : trimmedName,
                        sshTarget: trimmedTarget
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(target.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 400)
        .onAppear {
            name = device.name
            target = device.sshTarget ?? ""
        }
    }
}


/// Draggable dividers for a herdr split tree. Dragging previews locally and
/// commits one absolute ratio on release (`layout.set_split_ratio`), after
/// which the refreshed layout replaces the preview.
private struct SplitDividersOverlay: View {
    let layout: AppModel.ActiveLayout
    let size: CGSize
    let onCommit: (SplitDivider, Double) -> Void
    @State private var dragging: (id: String, ratio: Double)?

    var body: some View {
        ForEach(layout.tree.dividers(), id: \.id) { divider in
            let current = dragging?.id == divider.id ? (dragging?.ratio ?? divider.ratio) : divider.ratio
            let rect = dividerRect(divider, ratio: current)
            Rectangle()
                .fill(Theme.hairline)
                .frame(width: rect.width, height: rect.height)
                .overlay(
                    Color.clear
                        .frame(width: divider.direction == .right ? 9 : nil,
                               height: divider.direction == .down ? 9 : nil)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(coordinateSpace: .named("terminalArea"))
                                .onChanged { value in
                                    dragging = (divider.id, ratio(for: value.location, in: divider))
                                }
                                .onEnded { value in
                                    let final = ratio(for: value.location, in: divider)
                                    dragging = nil
                                    onCommit(divider, final)
                                }
                        )
                        .onHover { inside in
                            if inside {
                                (divider.direction == .right ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                )
                .offset(x: rect.minX, y: rect.minY)
        }
    }

    private func dividerRect(_ divider: SplitDivider, ratio: Double) -> CGRect {
        let r = divider.region
        switch divider.direction {
        case .right:
            let x = (r.x + r.width * ratio) * size.width
            return CGRect(x: x, y: r.y * size.height, width: 1, height: r.height * size.height)
        case .down:
            let y = (r.y + r.height * ratio) * size.height
            return CGRect(x: r.x * size.width, y: y, width: r.width * size.width, height: 1)
        }
    }

    private func ratio(for point: CGPoint, in divider: SplitDivider) -> Double {
        let r = divider.region
        switch divider.direction {
        case .right: return min(max((point.x / size.width - r.x) / r.width, 0.05), 0.95)
        case .down: return min(max((point.y / size.height - r.y) / r.height, 0.05), 0.95)
        }
    }
}
