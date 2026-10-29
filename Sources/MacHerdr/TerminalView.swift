import AppKit
import GhosttyTerminal
import GhosttyTheme
import HerdrKit
import SwiftUI
import UniformTypeIdentifiers

enum TerminalDefaults {
    static let fontNameKey = "terminal.fontName"   // "" = system monospaced
    static let fontSizeKey = "terminal.fontSize"
    static let thinStrokesKey = "terminal.thinStrokes"
    static let fontWeightKey = "terminal.fontWeight"
    static let lineSpacingKey = "terminal.lineSpacing"
    static let defaultFontSize: Double = 12.5
    /// `NSFont.Weight` rawValue; 0 is `.regular`. Only the system monospaced font
    /// has selectable weights — named families ship fixed faces and ignore this.
    static let defaultFontWeight: Double = 0
    static let defaultLineSpacing: Double = 1.0
    static let darkBackgroundHex = "#101012"
    static let darkForegroundHex = "#D6D6D6"
    static let lightBackgroundHex = "#FFFFFF"
    static let lightForegroundHex = "#3A3A3A"

    /// The 16-color ANSI palette used by Apple's Terminal.app (formerly
    /// `SwiftTerm.Color.terminalAppColors`, inlined with the renderer switch).
    static let darkPalette: [(red: Int, green: Int, blue: Int)] = [
        (0, 0, 0), (194, 54, 33), (37, 188, 36), (173, 173, 39),
        (73, 46, 225), (211, 56, 211), (51, 187, 200), (203, 204, 205),
        (129, 131, 131), (252, 57, 31), (49, 231, 34), (234, 236, 35),
        (88, 51, 255), (249, 53, 248), (20, 240, 240), (233, 235, 235),
    ]

    /// Per entry, keep whichever of the original and luminance-flipped color reads
    /// better on the light background: the flip rescues colors designed for dark
    /// backgrounds (white, the bright variants), but ANSI red/blue/magenta/black
    /// are already dark and would wash out to pastels.
    static let lightPalette: [(red: Int, green: Int, blue: Int)] = darkPalette.map { color in
        let flipped = LightTerminalANSIAdapter.lightRGB(
            red: color.red,
            green: color.green,
            blue: color.blue
        )
        let originalContrast = LightTerminalANSIAdapter.contrastOnWhite(
            red: color.red, green: color.green, blue: color.blue
        )
        let flippedContrast = LightTerminalANSIAdapter.contrastOnWhite(
            red: flipped.red, green: flipped.green, blue: flipped.blue
        )
        return originalContrast >= flippedContrast ? color : flipped
    }

    /// Bundled Nerd Font symbols (MIT, github.com/ryanoasis/nerd-fonts), used
    /// as a fallback for the icon glyphs agent TUIs draw.
    static let symbolFallbackFamily = "Symbols Nerd Font Mono"

    /// Registers the bundled symbols font for this process. Call once at launch.
    static func registerBundledFonts() {
        guard let url = Bundle.main.url(forResource: "SymbolsNerdFontMono-Regular", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    static func font(name: String, size: Double, weight: Double = defaultFontWeight) -> NSFont {
        let base: NSFont
        if !name.isEmpty, let custom = NSFont(name: name, size: size) {
            base = custom
        } else {
            base = NSFont.monospacedSystemFont(ofSize: size, weight: NSFont.Weight(weight))
        }
        return withSymbolFallback(base, size: size)
    }

    /// Nerd Font icons live in Unicode's Private Use Area, which CoreText's
    /// default cascade never resolves — agent TUIs like pi's powerfooter came
    /// out as tofu boxes unless the user's chosen terminal font happened to be
    /// a patched Nerd Font. A cascade entry pointing at the bundled symbols
    /// font resolves PUA glyphs for every terminal font; the system cascade
    /// still runs after it, so emoji and CJK fallback stay untouched.
    private static func withSymbolFallback(_ base: NSFont, size: Double) -> NSFont {
        let fallback = NSFontDescriptor(fontAttributes: [.family: symbolFallbackFamily])
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: [fallback]])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    private static let familiesLock = NSLock()
    private static var cachedMonospacedFamilies: [String]?
    /// Drops the cache when fonts are installed or removed while running.
    private static let fontSetObserver = NotificationCenter.default.addObserver(
        forName: NSFont.fontSetChangedNotification, object: nil, queue: nil
    ) { _ in
        familiesLock.lock()
        cachedMonospacedFamilies = nil
        familiesLock.unlock()
    }

    /// Fixed-pitch font families available on this Mac, for the settings picker.
    /// Cached: probing every installed family takes tens to hundreds of ms, and
    /// the settings view re-inits on every AppModel change.
    static func monospacedFamilies() -> [String] {
        _ = fontSetObserver
        familiesLock.lock()
        defer { familiesLock.unlock() }
        if let cachedMonospacedFamilies { return cachedMonospacedFamilies }
        let families = NSFontManager.shared.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch
        }.sorted()
        cachedMonospacedFamilies = families
        return families
    }

    /// Resolves a family name (e.g. a Ghostty `font-family`) to a family
    /// installed on this Mac that the picker stores, case-insensitively. Ghostty
    /// also accepts a PostScript/full name, so an exact-family miss falls back to
    /// resolving the name through `NSFont` and mapping to its family. nil when
    /// nothing matches.
    static func resolveFamily(_ requested: String) -> String? {
        let trimmed = requested.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let families = monospacedFamilies()
        if let exact = families.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return exact
        }
        if let font = NSFont(name: trimmed, size: 12), let family = font.familyName {
            return families.first(where: { $0.caseInsensitiveCompare(family) == .orderedSame }) ?? family
        }
        return nil
    }
}

/// The process-wide Ghostty app object: every terminal surface shares it, so
/// appearance settings land once here instead of per view. Ghostty owns the
/// light/dark switch itself — the theme below carries both palettes and the
/// view forwards the effective appearance.
@MainActor
enum GhosttyRuntime {
    static let controller = TerminalController(
        configSource: .none,
        theme: makeTheme(named: TerminalThemeSetting.currentName)
    )

    /// Hot-swaps the Ghostty theme ("" = built-in palettes); the controller
    /// dedupes, so this runs from every view update.
    static func applyTheme(named name: String) {
        controller.setTheme(makeTheme(named: name))
    }

    /// Font settings are hot-applied; surfaces pick the change up without a
    /// rebuild, so this runs from every view update — the controller dedupes.
    static func applyFontSettings(
        fontName: String, fontSize: Double, fontWeight: Double, lineSpacing: Double, copyOnSelect: Bool
    ) {
        controller.setTerminalConfiguration(
            fontConfiguration(
                fontName: fontName, fontSize: fontSize, fontWeight: fontWeight,
                lineSpacing: lineSpacing, copyOnSelect: copyOnSelect
            )
        )
    }

    private static func fontConfiguration(
        fontName: String,
        fontSize: Double,
        fontWeight: Double,
        lineSpacing: Double,
        copyOnSelect: Bool
    ) -> TerminalConfiguration {
        TerminalConfiguration { builder in
            builder.withFontSize(Float(fontSize))
            // "clipboard" writes the system pasteboard on mouse release, like
            // herdr's copy_on_select. Plain "true" would target only the
            // selection clipboard, which libghostty-spm advertises and drops.
            builder.withCustom("copy-on-select", copyOnSelect ? "clipboard" : "false")
            builder.withCursorStyle(.block)
            builder.withCursorStyleBlink(true)
            // The controller's base config is TerminalConfiguration.default,
            // which enables font-thicken — counter it; fake bold at terminal
            // sizes is what the "thin strokes" default exists to avoid.
            builder.withFontThicken(false)
            // Option-as-Meta: matches what the SwiftTerm embed did, and the
            // readline chords below (⌥⌫ → ESC DEL etc.) assume it.
            builder.withCustom("macos-option-as-alt", "true")
            // MacHerdr owns copy only while Ghostty has a local selection. With
            // no local selection, Command-C must reach a mouse-aware pane app.
            builder.withCustom("keybind", "super+c=unbind")
            // Agent TUI copy actions use OSC 52. Keep writes enabled explicitly
            // rather than depending on Ghostty's default clipboard policy.
            builder.withCustom("clipboard-write", "allow")
            // Shift is MacHerdr's unconditional local-selection escape hatch.
            // Plain TUI gestures have Shift removed before reaching Ghostty,
            // so disabling application shift capture cannot affect them.
            builder.withCustom("mouse-shift-capture", "never")
            if !fontName.isEmpty {
                builder.withFontFamily(fontName)
            } else {
                builder.withFontFamily("SF Mono")
                if let face = fontFaceName(forWeight: fontWeight) {
                    // Weight selection only exists for the system font; named
                    // families ship fixed faces and ignore the picker.
                    builder.withCustom("font-style", face)
                }
            }
            // Nerd Font icons live in Unicode's Private Use Area, which
            // CoreText's default cascade never resolves. A second font-family
            // entry would be Ghostty's fallback list, but Ghostty then derives
            // cell metrics from the symbols font (square advance == line height),
            // wrecking the grid — so the PUA ranges are codepoint-mapped instead.
            builder.withCustom("font-codepoint-map", "U+E000-U+F8FF=\(TerminalDefaults.symbolFallbackFamily)")
            builder.withCustom("font-codepoint-map", "U+F0000-U+FFFFD=\(TerminalDefaults.symbolFallbackFamily)")
            builder.withCustom("font-codepoint-map", "U+100000-U+10FFFD=\(TerminalDefaults.symbolFallbackFamily)")
            if lineSpacing != TerminalDefaults.defaultLineSpacing {
                let percent = Int(((lineSpacing - 1.0) * 100).rounded())
                builder.withCustom("adjust-cell-height", "\(percent)%")
            }
        }
    }

    /// `NSFont.Weight` rawValue → SF Mono face name (Ghostty's `font-style`).
    private static func fontFaceName(forWeight weight: Double) -> String? {
        switch weight {
        case ..<(-0.3): return "Light"
        case ..<0.15: return nil
        case ..<0.27: return "Medium"
        case ..<0.35: return "Semibold"
        case ..<0.5: return "Bold"
        default: return "Heavy"
        }
    }

    private static func makeTheme(named name: String) -> TerminalTheme {
        if let definition = TerminalThemeSetting.definition(named: name) {
            return definition.toTerminalTheme()
        }
        let dark = TerminalConfiguration { builder in
            builder.withBackground(TerminalDefaults.darkBackgroundHex)
            builder.withForeground(TerminalDefaults.darkForegroundHex)
            for (index, color) in TerminalDefaults.darkPalette.enumerated() {
                builder.withPalette(index, color: hex(color))
            }
        }
        let light = TerminalConfiguration { builder in
            builder.withBackground(TerminalDefaults.lightBackgroundHex)
            builder.withForeground(TerminalDefaults.lightForegroundHex)
            for (index, color) in TerminalDefaults.lightPalette.enumerated() {
                builder.withPalette(index, color: hex(color))
            }
        }
        return TerminalTheme(light: light, dark: dark)
    }

    private static func hex(_ color: (red: Int, green: Int, blue: Int)) -> String {
        String(format: "#%02X%02X%02X", color.red, color.green, color.blue)
    }
}

/// The child's complete environment: TERM/COLORTERM/LANG plus the few user
/// variables terminal programs expect, with the command's own variables
/// winning. Matches what `Terminal.getEnvironmentVariables` produced for the
/// SwiftTerm embed — the child deliberately does NOT inherit the app's sparse
/// launch environment; HerdrService supplies PATH & friends itself.
private func terminalEnvironment(_ commandEnvironment: [String: String]) -> [String] {
    var environment = ["TERM=xterm-256color", "COLORTERM=truecolor", "LANG=en_US.UTF-8"]
    let launch = ProcessInfo.processInfo.environment
    for key in ["LOGNAME", "USER", "DISPLAY", "LC_TYPE", "HOME"] {
        if let value = launch[key] {
            environment.append("\(key)=\(value)")
        }
    }
    for (key, value) in commandEnvironment {
        environment.removeAll { $0.hasPrefix("\(key)=") }
        environment.append("\(key)=\(value)")
    }
    return environment
}

/// Owns the local PTY child and the host-managed Ghostty session that renders
/// it: process output flows through the light-theme ANSI adapter into the
/// surface, and bytes the surface produces (keyboard input, DA/OSC replies)
/// are written to the PTY verbatim.
final class TerminalProcessHost {
    let session: InMemoryTerminalSession
    let process = TerminalProcess()
    /// Guards `lightAdapter`: written on the main thread (theme switch), read on
    /// the process's IO queue.
    private let adapterLock = NSLock()
    private var lightAdapter: LightTerminalANSIAdapter?
    private let viewportBox = ViewportBox()

    /// The last grid Ghostty reported, for mapping a click to a cell.
    var viewport: InMemoryTerminalViewport? { viewportBox.value }

    /// Called on the main queue with the child's real exit status.
    var onExit: ((Int32?) -> Void)?

    init() {
        let process = self.process
        let viewportBox = self.viewportBox
        session = InMemoryTerminalSession(
            write: { data in process.write(data) },
            resize: { viewport in
                viewportBox.value = viewport
                process.resize(
                    columns: viewport.columns,
                    rows: viewport.rows,
                    widthPixels: viewport.widthPixels,
                    heightPixels: viewport.heightPixels
                )
            },
            // Only grid changes reach the PTY; pixel-only updates would just
            // re-report the same winsize.
            suppressesPixelOnlyResizes: true
        )
        process.onOutput = { [weak self] data in self?.receiveOutput(data) }
        process.onExit = { [weak self] code in self?.onExit?(code) }
    }

    func start(command: TerminalCommand) {
        process.start(
            executable: command.executable,
            args: command.args,
            environment: terminalEnvironment(command.environment)
        )
    }

    func terminate() {
        process.terminate()
    }

    /// The light theme rewrites program-emitted colors for contrast on white.
    /// Switching themes installs a fresh adapter so a partial SGR retained at a
    /// chunk boundary cannot prepend stale bytes to the other theme's output.
    func setLightColorsEnabled(_ enabled: Bool) {
        adapterLock.lock()
        lightAdapter = enabled ? LightTerminalANSIAdapter() : nil
        adapterLock.unlock()
    }

    private func receiveOutput(_ data: Data) {
        adapterLock.lock()
        var adapter = lightAdapter
        let bytes = [UInt8](data)
        let transformed = adapter?.transform(bytes[...])
        if adapter != nil { lightAdapter = adapter }
        adapterLock.unlock()

        if let transformed {
            if !transformed.isEmpty {
                session.receive(Data(transformed))
            }
        } else {
            session.receive(data)
        }
    }
}

/// Lock-guarded because the resize callback's thread is Ghostty's choice.
private final class ViewportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: InMemoryTerminalViewport?

    var value: InMemoryTerminalViewport? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

private struct ClipboardFile: Sendable {
    let localURL: URL
    let removeAfterUpload: Bool
}

private struct PendingAttachmentPaste: Sendable {
    let files: [ClipboardFile]
    let pathSyntax: AgentAttachmentPathSyntax
    /// Text appended after the last path — a drop adds a space (cmux-style)
    /// so the user can keep typing the prompt without inserting one.
    var suffix: String = ""
}

private enum ClipboardFileError: LocalizedError {
    case unsupportedItem
    case imageEncodingFailed
    case transferUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedItem: return String(localized: "Remote paste supports files and folders, not special files.")
        case .imageEncodingFailed: return String(localized: "The clipboard image could not be encoded as PNG.")
        case .transferUnavailable: return String(localized: "The remote file transfer service is unavailable.")
        }
    }
}

/// The terminal view: Ghostty's `AppTerminalView` plus MacHerdr's local behavior.
///
/// Keyboard: Shift+Return sends ESC CR so agent TUIs insert a line break instead
/// of submitting (legacy encoding sends a bare `\r` for both, so the modifier
/// never reaches the TUI), and the ⌘/⌥ text-editing chords send readline bytes —
/// Ghostty / VS Code / iTerm Natural Text Editing. Both go through the session's
/// raw input path, bypassing key translation, and stay local while an IME
/// composition is open.
///
/// Mouse: one side owns each complete gesture, decided by `MouseGestureRouter`.
/// Under Ghostty's negotiated mouse capture a click reaches the TUI and a drag
/// becomes a local selection; Shift and repeated clicks stay local from the
/// press. Turning Mouse Reporting off keeps every gesture local.
///
/// IME: Ghostty implements `NSTextInputClient` itself and renders the marked
/// text in the grid; the only hook needed here is keeping ⌘/⌃ chords off the
/// PTY while `hasMarkedText()`.
final class LineBreakTerminalView: AppTerminalView {
    /// When false, mouse button events always stay local even if the TUI
    /// requested mouse reporting (Shift bypasses it either way).
    var mouseReportingEnabled = true
    /// Mirrors the Copy-on-select setting: a finished selection is copied and a
    /// "Copied" notice shown, like herdr's copy_on_select.
    var copyOnSelectEnabled = true
    private var selectionCopyTracker = SelectionCopyTracker()
    private var copiedToast: CopiedToast?
    var appliedDarkAppearance: Bool?
    /// The live surface, captured by the coordinator's lifecycle delegate —
    /// `AppTerminalView.surface` is internal, so selection queries come in here.
    weak var attachedSurface: TerminalSurface?
    weak var processHost: TerminalProcessHost?
    /// Ghostty's grid as its resize delegate last reported it. The session's
    /// `viewport` (from the PTY resize callback) carries columns, rows and the
    /// surface size but no cell size, so this is where cell pixels come from.
    var gridMetrics: TerminalGridMetrics?

    /// Routes each press, drag and release so a gesture cannot split between
    /// the TUI and Ghostty's local selection.
    private var gestureRouter = MouseGestureRouter()
    /// A captured press held back until the gesture shows itself as a click or
    /// a drag; replayed at its original point either way.
    private var heldPress: NSEvent?
    /// A locally handled Command-C must consume its matching release too;
    /// kitty report-events applications otherwise receive a release-only key.
    private var locallyConsumedCopyKeyCode: UInt16?

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        hideLinkPopup()
        locallyConsumedCopyKeyCode = nil
        if hasMarkedText() {
            // Command/Control chords must stay with the IME until composition
            // ends; other keys still reach Ghostty so preedit can update.
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers.contains(.command) || modifiers.contains(.control) { return }
            super.keyDown(with: event)
            return
        }
        if let payload = Self.ptyBytes(forMacEditingKey: event) {
            processHost?.session.sendInput(Data(payload.utf8))
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if locallyConsumedCopyKeyCode == event.keyCode {
            locallyConsumedCopyKeyCode = nil
            return
        }
        super.keyUp(with: event)
    }

    /// Mac Delete is Backspace (keyCode 51). ⌥⌘ arrows move split focus and
    /// are left alone; ⌘A/⌘E/⌘W and the other app chords never match here.
    private static func ptyBytes(forMacEditingKey event: NSEvent) -> String? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let commandOnly = modifiers.contains(.command)
            && modifiers.isDisjoint(with: [.option, .control])
        let optionOnly = modifiers.contains(.option)
            && modifiers.isDisjoint(with: [.command, .control])

        if commandOnly {
            switch event.keyCode {
            case 51:  return "\u{15}"  // ⌘⌫ → ^U
            case 123: return "\u{01}"  // ⌘← → ^A
            case 124: return "\u{05}"  // ⌘→ → ^E
            case 117: return "\u{0b}"  // ⌘⌦ → ^K
            default: break
            }
        }
        if optionOnly {
            switch event.keyCode {
            case 51:  return "\u{1b}\u{7f}"  // ⌥⌫ → ESC DEL
            case 123: return "\u{1b}b"       // ⌥← → ESC b
            case 124: return "\u{1b}f"       // ⌥→ → ESC f
            case 117: return "\u{1b}d"       // ⌥⌦ → ESC d
            default: break
            }
        }
        if event.keyCode == 36 || event.keyCode == 76,  // Return, keypad Enter
           modifiers.contains(.shift),
           modifiers.isDisjoint(with: [.command, .control, .option]) {
            return "\u{1b}\r"
        }
        return nil
    }

    // MARK: Mouse

    private func isSelectionGesture(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift)
    }

    /// Shift is what tells Ghostty (`mouse-shift-capture = never`) to keep a
    /// captured gesture local; plain TUI gestures have it removed.
    private func event(_ event: NSEvent, for route: MouseGestureRouter.Route) -> NSEvent {
        guard isMouseCaptured else { return event }
        return route == .local
            ? event.addingShiftModifier()
            : event.removingShiftModifier()
    }

    private func perform(_ actions: [MouseGestureRouter.Action], with event: NSEvent) {
        for action in actions {
            switch action {
            case .press(let route):
                super.mouseDown(with: self.event(heldPress ?? event, for: route))
            case .drag(let route):
                super.mouseDragged(with: self.event(event, for: route))
            case .release(let route):
                super.mouseUp(with: self.event(event, for: route))
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        hideLinkPopup()
        pendingLinkClick = nil
        if isMouseCaptured, mouseReportingEnabled,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask)
               .subtracting([.capsLock, .function]) == .command,
           let url = hoveredLink ?? linkURL(at: event) {
            // A captured ⌘-click would reach the TUI, and fullscreen Claude
            // Code opens links itself — with `open` on its own host, which for
            // a remote device is the remote Mac. The whole gesture stays here.
            pendingLinkClick = url
            return
        }
        // Ghostty focuses on the press; a held-back press must still do that.
        window?.makeFirstResponder(self)
        heldPress = event
        let actions = gestureRouter.press(
            at: event.locationInWindow,
            clickCount: event.clickCount,
            shift: isSelectionGesture(event),
            captured: isMouseCaptured,
            reportingEnabled: mouseReportingEnabled
        )
        perform(actions, with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard pendingLinkClick == nil else { return }
        perform(gestureRouter.drag(to: event.locationInWindow), with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if let url = pendingLinkClick {
            pendingLinkClick = nil
            Self.openClickedLink(url)
            return
        }
        defer { heldPress = nil }
        perform(gestureRouter.release(), with: event)
        // Ghostty finalizes the selection while handling the release.
        DispatchQueue.main.async { [weak self] in self?.announceSelectionCopy() }
    }

    /// Copy-on-select feedback. Ghostty copies on release by itself; copying
    /// here too makes the clipboard write certain, and the notice says so.
    private func announceSelectionCopy() {
        guard copyOnSelectEnabled else { return }
        let selection = attachedSurface?.hasSelection() == true ? attachedSurface?.readSelection() : nil
        guard selectionCopyTracker.shouldAnnounce(selection: selection), copyLocalSelection() else { return }
        showCopiedToast()
    }

    private func showCopiedToast() {
        copiedToast?.removeFromSuperview()
        let toast = CopiedToast()
        toast.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: centerXAnchor),
            toast.topAnchor.constraint(equalTo: topAnchor, constant: 14),
        ])
        copiedToast = toast
        toast.dismiss(after: 1.4) { [weak self, weak toast] in
            if self?.copiedToast === toast { self?.copiedToast = nil }
        }
    }

    // MARK: Links under mouse capture

    /// The link Ghostty reports under a ⌘-hovering pointer (URL match or
    /// OSC 8 target). Ghostty may not report it while a TUI captures the
    /// mouse, so `linkURL(at:)` backs it up from the screen text.
    var hoveredLink: String?
    /// A ⌘-click taken locally: its drag and release must not reach the TUI.
    private var pendingLinkClick: String?

    /// Ghostty's default window padding, in points.
    private static let gridPadding: CGFloat = 2

    /// The URL printed under the click, reading the clicked row plus the rows
    /// it soft-wraps into (a long URL fills its row edge to edge).
    private func linkURL(at event: NSEvent) -> String? {
        linkHit(atWindowPoint: event.locationInWindow)?.link.url
    }

    /// The cell grid under a window point, and the link printed there.
    private func linkHit(atWindowPoint windowPoint: NSPoint) -> (link: TerminalLink, rowRect: NSRect)? {
        guard let viewport = processHost?.viewport, viewport.columns > 0, viewport.rows > 0,
              let cell = cellSizePixels(viewport),
              let text = processHost?.session.readViewportText()
        else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        let cellWidth = cell.width / scale
        let cellHeight = cell.height / scale
        let point = convert(windowPoint, from: nil)
        let fromTop = isFlipped ? point.y : bounds.height - point.y
        let column = Int(((point.x - Self.gridPadding) / cellWidth).rounded(.down))
        let row = Int(((fromTop - Self.gridPadding) / cellHeight).rounded(.down))
        let lines = text.components(separatedBy: "\n")
        guard let link = Self.link(in: lines, row: row, column: column, columns: Int(viewport.columns))
        else { return nil }
        let rowTop = Self.gridPadding + CGFloat(row) * cellHeight
        let rowRect = NSRect(
            x: 0,
            y: isFlipped ? rowTop : bounds.height - rowTop - cellHeight,
            width: bounds.width,
            height: cellHeight
        )
        return (link, rowRect)
    }

    /// Cell size in backing pixels. Ghostty's resize delegate reports it with
    /// the grid; the PTY resize callback that fills `viewport` does not (its
    /// cell fields stay 0), so without the delegate value the cell is derived
    /// from the surface size and the grid, minus Ghostty's padding.
    private func cellSizePixels(_ viewport: InMemoryTerminalViewport) -> (width: CGFloat, height: CGFloat)? {
        if let metrics = gridMetrics, metrics.cellWidthPixels > 0, metrics.cellHeightPixels > 0 {
            return (CGFloat(metrics.cellWidthPixels), CGFloat(metrics.cellHeightPixels))
        }
        if viewport.cellWidthPixels > 0, viewport.cellHeightPixels > 0 {
            return (CGFloat(viewport.cellWidthPixels), CGFloat(viewport.cellHeightPixels))
        }
        guard viewport.widthPixels > 0, viewport.heightPixels > 0 else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        let padding = Self.gridPadding * 2 * scale
        let width = (CGFloat(viewport.widthPixels) - padding) / CGFloat(viewport.columns)
        let height = (CGFloat(viewport.heightPixels) - padding) / CGFloat(viewport.rows)
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }

    static func url(in lines: [String], row: Int, column: Int, columns: Int) -> String? {
        link(in: lines, row: row, column: column, columns: columns)?.url
    }

    /// The link printed at a cell: `text` exactly as shown (rows rejoined, no
    /// line breaks) for copying, `url` normalized for opening.
    static func link(in lines: [String], row: Int, column: Int, columns: Int) -> TerminalLink? {
        guard lines.indices.contains(row), column >= 0 else { return nil }
        let isFull = { (line: String) in displayWidth(line) >= columns }
        var first = row
        while first > 0, isFull(lines[first - 1]) { first -= 1 }
        var last = row
        while last + 1 < lines.count, isFull(lines[last]) { last += 1 }

        var joined = ""
        var clickOffset: Int?
        for index in first...last {
            if index == row {
                var width = 0
                var offset = joined.utf16.count
                for character in lines[index] {
                    let next = width + cellWidth(character)
                    if column < next { clickOffset = offset; break }
                    width = next
                    offset += character.utf16.count
                }
            }
            joined += lines[index]
        }
        guard let clickOffset else { return nil }
        // A link never spans whitespace, so scan only the word under the
        // pointer. Full-width TUI rows (borders, padding) join a whole screen
        // into `joined`, and scanning all of it ran on every hover pause.
        let utf16 = joined as NSString
        var start = clickOffset
        while start > 0, !Self.isLinkBoundary(utf16.character(at: start - 1)) { start -= 1 }
        var end = clickOffset
        while end < utf16.length, !Self.isLinkBoundary(utf16.character(at: end)) { end += 1 }
        let range = NSRange(location: start, length: end - start)
        let word = utf16.substring(with: range)
        guard word.contains("://") || word.contains("mailto:"),
              let detector = linkDetector
        else { return nil }
        for match in detector.matches(in: joined, range: range)
        where NSLocationInRange(clickOffset, match.range) {
            // Bare words the detector promotes (README.md, foo.io) are not links.
            let matched = (joined as NSString).substring(with: match.range)
            guard matched.contains("://") || matched.hasPrefix("mailto:"),
                  let url = match.url
            else { return nil }
            return TerminalLink(text: matched, url: url.absoluteString)
        }
        return nil
    }

    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    private static func isLinkBoundary(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0xA0
    }

    private static func displayWidth(_ line: String) -> Int {
        line.reduce(0) { $0 + cellWidth($1) }
    }

    /// Terminal cell width: East Asian wide and emoji-presentation characters
    /// take two cells.
    private static func cellWidth(_ character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 1 }
        if scalar.properties.isEmojiPresentation { return 2 }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }

    // MARK: Link copy popup

    // Resting the pointer on a link offers a Copy button. herdr redraws its
    // pane row by row, so a link that wraps reaches Ghostty as separate lines
    // and a dragged selection copies it with a break at every row. The button
    // copies the link rejoined from its full-width rows instead.

    private var linkPopup: LinkCopyPopup?
    private var linkHoverTimer: Timer?
    private var linkHoverPoint: NSPoint?
    /// How long the pointer rests before the button appears, and how long it
    /// may stray off the link before it goes.
    private static let linkHoverDelay: TimeInterval = 0.35

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        // AppTerminalView routes drags through here too.
        guard NSEvent.pressedMouseButtons == 0 else {
            hideLinkPopup()
            return
        }
        if let popup = linkPopup, popup.frame.contains(convert(event.locationInWindow, from: nil)) {
            linkHoverTimer?.invalidate()
            return
        }
        linkHoverPoint = event.locationInWindow
        linkHoverTimer?.invalidate()
        linkHoverTimer = Timer.scheduledTimer(withTimeInterval: Self.linkHoverDelay, repeats: false) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.updateLinkPopup() }
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard NSEvent.pressedMouseButtons == 0 else { return }
        hideLinkPopup()
    }

    override func scrollWheel(with event: NSEvent) {
        hideLinkPopup()
        super.scrollWheel(with: event)
    }

    override func setSurfaceVisible(_ visible: Bool) {
        super.setSurfaceVisible(visible)
        if !visible { hideLinkPopup() }
        guard visible != acceptsDrops else { return }
        acceptsDrops = visible
        updateDragRegistration()
    }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { hideLinkPopup() }
        super.setFrameSize(newSize)
    }

    private func updateLinkPopup() {
        guard let point = linkHoverPoint,
              window?.isKeyWindow == true || window?.isMainWindow == true,
              let hit = linkHit(atWindowPoint: point)
        else {
            hideLinkPopup()
            return
        }
        if let popup = linkPopup, popup.link == hit.link { return }
        showLinkPopup(for: hit.link, rowRect: hit.rowRect, pointerX: convert(point, from: nil).x)
    }

    private func showLinkPopup(for link: TerminalLink, rowRect: NSRect, pointerX: CGFloat) {
        hideLinkPopup()
        let popup = LinkCopyPopup(link: link) { [weak self] link in
            self?.copyLink(link)
        }
        let size = popup.fittingSize
        // Above the hovered row, or below it at the top edge; clear of the
        // pointer so the link stays readable.
        let above = isFlipped ? rowRect.minY - size.height - 2 : rowRect.maxY + 2
        let below = isFlipped ? rowRect.maxY + 2 : rowRect.minY - size.height - 2
        let fitsAbove = isFlipped ? above >= 0 : above + size.height <= bounds.height
        let x = min(max(pointerX - size.width / 2, 4), max(bounds.width - size.width - 4, 4))
        popup.frame = NSRect(origin: NSPoint(x: x, y: fitsAbove ? above : below), size: size)
        addSubview(popup)
        linkPopup = popup
    }

    private func hideLinkPopup() {
        linkHoverTimer?.invalidate()
        linkHoverTimer = nil
        linkPopup?.removeFromSuperview()
        linkPopup = nil
    }

    private func copyLink(_ link: TerminalLink) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(link.text, forType: .string)
        linkPopup?.showCopied { [weak self] in self?.hideLinkPopup() }
    }

    // MARK: Accessibility

    // Dictation tools (Typeless and the like) paste with ⌘V and then look for
    // a focused text area to confirm the insert landed. Without an
    // accessibility role the terminal reads as "no text field", and the tool
    // leaves its copy-this-text panel up. Same shape as Ghostty.app's surface.

    private var accessibilityTextCache: (text: String, time: TimeInterval)?

    private var accessibilityText: String {
        let now = ProcessInfo.processInfo.systemUptime
        // One viewport read serves the burst of attribute queries a tool makes
        // per poll. Kept short: an autocomplete overlay reads the text before
        // the cursor on every keystroke, and a stale read misses the last key.
        if let cache = accessibilityTextCache, now - cache.time < 0.05 { return cache.text }
        let text = processHost?.session.readViewportText() ?? ""
        accessibilityTextCache = (text, now)
        return text
    }

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

    override func accessibilityHelp() -> String? { String(localized: "Terminal content area") }

    override func accessibilityValue() -> Any? { accessibilityText }

    override func accessibilityNumberOfCharacters() -> Int {
        (accessibilityText as NSString).length
    }

    override func accessibilityVisibleCharacterRange() -> NSRange {
        NSRange(location: 0, length: accessibilityNumberOfCharacters())
    }

    override func accessibilitySelectedText() -> String? {
        attachedSurface?.readSelection() ?? ""
    }

    /// The insertion point is the terminal cursor's cell in the viewport text,
    /// so the text before it ends with what is being typed on the prompt line.
    /// Without a cursor (no surface yet) it sits at the end of the text.
    override func accessibilitySelectedTextRange() -> NSRange {
        guard let cursor = cursorCell() else {
            return NSRange(location: accessibilityNumberOfCharacters(), length: 0)
        }
        return NSRange(location: TerminalCaretGrid.offset(of: cursor.cell, in: accessibilityText), length: 0)
    }

    /// `AXBoundsForRange`: the cells of `range` in screen coordinates, placed
    /// from the cursor's own cell, the one position ghostty reports (for IME).
    /// A zero-length range is a zero-width caret box at that cell.
    override func accessibilityFrame(for range: NSRange) -> NSRect {
        guard let window, let cursor = cursorCell() else { return .zero }
        let text = accessibilityText
        let start = TerminalCaretGrid.cell(at: range.location, in: text)
        let end = TerminalCaretGrid.cell(at: NSMaxRange(range), in: text)
        let cellWidth = cursor.rect.width
        let cellHeight = cursor.rect.height
        // A later row is lower: a smaller y in AppKit's default space.
        var rect = cursor.rect.offsetBy(
            dx: CGFloat(start.column - cursor.cell.column) * cellWidth,
            dy: CGFloat(start.row - cursor.cell.row) * cellHeight * (isFlipped ? 1 : -1)
        )
        rect.size.width = end.row == start.row ? CGFloat(end.column - start.column) * cellWidth : cellWidth
        return window.convertToScreen(convert(rect, to: nil))
    }

    /// The cursor's cell and that cell's rect in view space. The position comes
    /// from ghostty's IME point (via `firstRect`), which is zero-width while
    /// nothing is selected; the cell size from the viewport.
    private func cursorCell() -> (cell: TerminalCaretGrid.Cell, rect: NSRect)? {
        guard attachedSurface != nil, let window, let viewport = processHost?.viewport,
              let size = TerminalCaretGrid.cellSize(
                  columns: Int(viewport.columns),
                  rows: Int(viewport.rows),
                  widthPixels: CGFloat(viewport.widthPixels),
                  heightPixels: CGFloat(viewport.heightPixels),
                  cellWidthPixels: CGFloat(viewport.cellWidthPixels),
                  cellHeightPixels: CGFloat(viewport.cellHeightPixels),
                  scale: window.backingScaleFactor,
                  padding: Self.gridPadding
              )
        else { return nil }
        let cellWidth = size.width
        let cellHeight = size.height
        let screenRect = firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        guard screenRect != .zero else { return nil }
        // `firstRect` puts the rect's minY on the cursor cell's bottom edge.
        let point = convert(window.convertFromScreen(screenRect), from: nil)
        let bottomFromTop = isFlipped ? point.minY : bounds.height - point.minY
        guard let cell = TerminalCaretGrid.cursorCell(
            x: point.minX,
            bottomFromTop: bottomFromTop,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            padding: Self.gridPadding
        ) else { return nil }
        let top = Self.gridPadding + CGFloat(cell.row) * cellHeight
        let rect = NSRect(
            x: Self.gridPadding + CGFloat(cell.column) * cellWidth,
            y: isFlipped ? top : bounds.height - top - cellHeight,
            width: cellWidth,
            height: cellHeight
        )
        return (cell, rect)
    }

    override func accessibilityString(for range: NSRange) -> String? {
        let text = accessibilityText as NSString
        guard NSMaxRange(range) <= text.length else { return nil }
        return text.substring(with: range)
    }

    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        accessibilityString(for: range).map { NSAttributedString(string: $0) }
    }

    override func accessibilityLine(for index: Int) -> Int {
        let text = accessibilityText as NSString
        let end = min(max(index, 0), text.length)
        return text.substring(to: end).reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
    }

    // MARK: Context menu

    // The right mouse button always opens the context menu and never reaches
    // the TUI. Link items key off the selected text; while mouse reporting is
    // active, Shift-double-click selects a whole URL locally.
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func rightMouseUp(with event: NSEvent) {
        NSMenu.popUpContextMenu(contextMenu(), with: event, for: self)
    }

    override func menu(for _: NSEvent) -> NSMenu? {
        contextMenu()
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        if attachedSurface?.hasSelection() == true,
           let selection = attachedSurface?.readSelection(),
           !selection.isEmpty {
            menu.addItem(makeItem(String(localized: "Copy"), #selector(copySelectionFromMenu(_:))))
            if let url = Self.firstURL(in: selection) {
                menu.addItem(.separator())
                let open = makeItem(String(localized: "Open Link"), #selector(openLinkFromMenu(_:)))
                open.representedObject = url
                menu.addItem(open)
                let copyLink = makeItem(String(localized: "Copy Link Address"), #selector(copyLinkFromMenu(_:)))
                copyLink.representedObject = url
                menu.addItem(copyLink)
            }
            menu.addItem(.separator())
        }
        menu.addItem(makeItem(String(localized: "Paste"), #selector(performPaste(_:))))
        menu.addItem(makeItem(String(localized: "Select All"), #selector(selectAll(_:))))
        return menu
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openLinkFromMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    /// ⌘-click on a link Ghostty matched (URL regex or OSC 8). Ghostty reports
    /// the click unhandled unless the host takes it — its own fallback opener
    /// refuses OSC 8 targets on macOS — so this is the only path that opens
    /// anything. The URL is producer-controlled terminal output and the
    /// wrapper does not distinguish OSC 8 from regex matches, so only web and
    /// mail schemes are opened.
    static func openClickedLink(_ string: String) {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme)
        else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func copyLinkFromMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc private func copySelectionFromMenu(_: Any?) {
        copyLocalSelection()
    }

    @discardableResult
    private func copyLocalSelection() -> Bool {
        guard let selection = attachedSurface?.readSelection(), !selection.isEmpty else {
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(selection, forType: .string)
    }

    static func firstURL(in text: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector?.firstMatch(in: text, range: range),
              let url = match.url,
              url.scheme == "http" || url.scheme == "https"
        else { return nil }
        return url
    }

    // MARK: Drag and drop

    // Files and folders dropped from Finder become paths the program can read:
    // local paths on this Mac, or copies uploaded into the remote device's
    // attachment cache — the same pipeline as pasting copied files.
    // Dropped text (from an editor or a browser) pastes as text.

    //
    // Only the terminal on screen takes drops. Kept-alive attaches stay in the
    // window at zero opacity, and AppKit picks a drag destination from the
    // view tree without regard to SwiftUI's opacity or hit testing — so a
    // hidden terminal stacked above the visible one would swallow the drop.

    /// Mirrors `setSurfaceVisible`: false while kept alive behind another view.
    private var acceptsDrops = true

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hideLinkPopup() }
        updateDragRegistration()
    }

    private func updateDragRegistration() {
        if window != nil, acceptsDrops {
            registerForDraggedTypes([.fileURL, .string])
        } else {
            unregisterDraggedTypes()
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pasteboard = sender.draggingPasteboard
        if Self.fileURLs(in: pasteboard)?.isEmpty == false { return .copy }
        return Self.hasText(in: pasteboard) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        if let fileURLs = Self.fileURLs(in: pasteboard), !fileURLs.isEmpty {
            window?.makeFirstResponder(self)
            dropFiles(fileURLs)
            return true
        }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            return false
        }
        window?.makeFirstResponder(self)
        paste(text: text)
        return true
    }

    /// Unlike a paste, a drop always delivers paths: the dragged files are not
    /// on the general pasteboard, so the native-clipboard route cannot carry
    /// them, and a plain shell (no attachment capabilities) wants paths too.
    private func dropFiles(_ fileURLs: [URL]) {
        let pathSyntax: AgentAttachmentPathSyntax
        if case .devicePaths(let syntax) = AgentAttachmentDeliveryPolicy.action(
            capabilities: attachmentCapabilities,
            deviceKind: attachmentDeviceKind,
            source: .files(allImages: fileURLs.allSatisfy(Self.isImageFile))
        ) {
            pathSyntax = syntax
        } else {
            pathSyntax = .shellQuoted
        }
        if case .local = attachmentDeviceKind {
            sendPastedText(
                fileURLs.map { pathSyntax.format($0.path) }.joined(separator: " ") + Self.dropSuffix
            )
            return
        }
        do {
            enqueuePathPaste(
                try Self.clipboardFiles(from: fileURLs), pathSyntax: pathSyntax, suffix: Self.dropSuffix
            )
        } catch {
            reportAttachmentError(error)
        }
    }

    /// Dropped paths end with a space, like cmux, so the prompt can continue
    /// straight after them. Clipboard path pastes stay verbatim.
    private static let dropSuffix = " "

    // MARK: Paste and attachments

    var attachmentCapabilities: AgentAttachmentCapabilities?
    var attachmentDeviceKind: Device.Kind = .local
    var attachmentService: HerdrService?
    var onAttachmentError: ((String) -> Void)?
    var onAttachmentUploadingChanged: ((Bool) -> Void)?
    /// Fired when this terminal takes keyboard focus (a click in a split pane).
    var onFocused: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onFocused?() }
        return result
    }
    private var pendingUploads: [PendingAttachmentPaste] = []
    private var uploadTask: Task<Void, Never>?

    deinit {
        uploadTask?.cancel()
    }

    // ⌘C/⌘V are intercepted here because the app has no Edit menu. Copy stays
    // local only when Ghostty owns a selection; otherwise the physical key is
    // sent to the TUI now that its global copy binding is unbound above.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              window?.firstResponder === self
        else {
            return super.performKeyEquivalent(with: event)
        }
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad])
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "c" {
            if attachedSurface?.hasSelection() == true {
                locallyConsumedCopyKeyCode = event.keyCode
                copyLocalSelection()
            } else {
                keyDown(with: event)
            }
            return true
        }
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "v" {
            handlePaste()
            return true
        }
        // Ghostty consumes its default bindings before AppKit reaches the menu.
        // Give MacHerdr's commands priority over those standalone-terminal actions.
        // ⌘+ ⌘− ⌘0 stay with ghostty's font-size bindings; the menu's preview zoom
        // shares those keys and only applies when the preview has focus.
        let fontSizeKey = modifiers.subtracting(.shift) == .command
            && ["=", "+", "-", "0"].contains(event.charactersIgnoringModifiers ?? "")
        if modifiers.contains(.command), !fontSizeKey,
           NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // `AppTerminalView`'s own `paste(_:)` is internal and cannot be overridden,
    // so the attachment flow is reached through ⌘V (performKeyEquivalent) and
    // this context-menu action. The app has no Edit menu, so those are the only
    // two paste entry points.
    @objc private func performPaste(_: Any?) {
        handlePaste()
    }

    private func handlePaste() {
        let pasteboard = NSPasteboard.general
        if let fileURLs = Self.fileURLs(in: pasteboard), !fileURLs.isEmpty {
            let action = AgentAttachmentDeliveryPolicy.action(
                capabilities: attachmentCapabilities,
                deviceKind: attachmentDeviceKind,
                source: .files(allImages: fileURLs.allSatisfy(Self.isImageFile))
            )
            handleFilePaste(action: action, fileURLs: fileURLs)
            return
        }

        guard Self.containsImageData(in: pasteboard) else {
            pastePasteboardText()
            return
        }

        let action = AgentAttachmentDeliveryPolicy.action(
            capabilities: attachmentCapabilities,
            deviceKind: attachmentDeviceKind,
            source: .imageData
        )
        switch action {
        case .unsupported:
            pastePasteboardText()
        case .nativeClipboard:
            forwardNativeClipboardPaste()
        case .devicePaths(let pathSyntax):
            do {
                guard let files = try Self.clipboardFiles(in: pasteboard) else {
                    pastePasteboardText()
                    return
                }
                enqueuePathPaste(files, pathSyntax: pathSyntax)
            } catch {
                reportAttachmentError(error)
            }
        }
    }

    private func pastePasteboardText() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        paste(text: text)
    }

    private func handleFilePaste(
        action: AgentAttachmentDeliveryAction,
        fileURLs: [URL]
    ) {
        switch action {
        case .unsupported:
            pastePasteboardText()
        case .nativeClipboard:
            forwardNativeClipboardPaste()
        case .devicePaths(let pathSyntax):
            if case .local = attachmentDeviceKind {
                sendPastedText(fileURLs.map { pathSyntax.format($0.path) }.joined(separator: " "))
                return
            }
            do {
                let files = try Self.clipboardFiles(from: fileURLs)
                enqueuePathPaste(files, pathSyntax: pathSyntax)
            } catch {
                reportAttachmentError(error)
            }
        }
    }

    /// Ask the remote program to paste from its own clipboard with a literal
    /// ^V byte — the "native clipboard" delivery path.
    private func forwardNativeClipboardPaste() {
        processHost?.session.sendInput(Data([0x16]))
    }

    private func enqueuePathPaste(
        _ files: [ClipboardFile],
        pathSyntax: AgentAttachmentPathSyntax,
        suffix: String = ""
    ) {
        guard let attachmentService else {
            discardTemporaries(in: files)
            reportAttachmentError(ClipboardFileError.transferUnavailable)
            return
        }
        pendingUploads.append(
            PendingAttachmentPaste(files: files, pathSyntax: pathSyntax, suffix: suffix)
        )
        guard uploadTask == nil else { return }
        onAttachmentUploadingChanged?(true)
        uploadTask = Task { [weak self] in
            await self?.drainPathPastes(using: attachmentService)
        }
    }

    /// Materializes one paste at a time so paths reach the agent in paste order.
    @MainActor
    private func drainPathPastes(using service: HerdrService) async {
        while !pendingUploads.isEmpty {
            let paste = pendingUploads.removeFirst()
            let files = paste.files
            defer { discardTemporaries(in: files) }
            do {
                var devicePaths: [String] = []
                for file in files {
                    try Task.checkCancellation()
                    devicePaths.append(try await service.stageAttachment(from: file.localURL))
                }
                try Task.checkCancellation()
                sendPastedText(
                    devicePaths.map(paste.pathSyntax.format).joined(separator: " ") + paste.suffix
                )
            } catch is CancellationError {
                break
            } catch {
                reportAttachmentError(error)
            }
        }
        pendingUploads.forEach { discardTemporaries(in: $0.files) }
        pendingUploads.removeAll()
        uploadTask = nil
        onAttachmentUploadingChanged?(false)
    }

    private func discardTemporaries(in files: [ClipboardFile]) {
        for file in files where file.removeAfterUpload {
            try? FileManager.default.removeItem(at: file.localURL)
        }
    }

    /// Ghostty's text path wraps the payload in bracketed-paste markers when
    /// the program asked for them.
    private func sendPastedText(_ text: String) {
        paste(text: text)
    }

    private func reportAttachmentError(_ error: Error) {
        onAttachmentError?(error.localizedDescription)
    }

    private static func clipboardFiles(in pasteboard: NSPasteboard) throws -> [ClipboardFile]? {
        if let fileURLs = fileURLs(in: pasteboard), !fileURLs.isEmpty {
            return try clipboardFiles(from: fileURLs)
        }

        guard !hasText(in: pasteboard),
              let image = pasteboard.readObjects(
                  forClasses: [NSImage.self],
                  options: nil
              )?.first as? NSImage
        else {
            return nil
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw ClipboardFileError.imageEncodingFailed
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdrm-clipboard", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let localURL = directory.appendingPathComponent("\(UUID().uuidString.lowercased()).png")
        try png.write(to: localURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: localURL.path
        )
        return [ClipboardFile(localURL: localURL, removeAfterUpload: true)]
    }

    private static func clipboardFiles(from fileURLs: [URL]) throws -> [ClipboardFile] {
        try fileURLs.map { url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            guard values.isRegularFile == true || values.isDirectory == true else {
                throw ClipboardFileError.unsupportedItem
            }
            return ClipboardFile(localURL: url, removeAfterUpload: false)
        }
    }

    private static func fileURLs(in pasteboard: NSPasteboard) -> [URL]? {
        pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
    }

    private static func containsImageData(in pasteboard: NSPasteboard) -> Bool {
        !hasText(in: pasteboard)
            && pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    private static func isImageFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.contentTypeKey]),
              let contentType = values.contentType
        else { return false }
        return contentType.conforms(to: .image)
    }

    /// Keynote, Excel and Preview attach a TIFF snapshot to copied text, so a
    /// pasteboard only counts as an image when it carries no text at all.
    private static func hasText(in pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSString.self], options: nil)
    }
}

private extension NSEvent {
    func addingShiftModifier() -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: locationInWindow,
            modifierFlags: modifierFlags.union(.shift),
            timestamp: timestamp,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: clickCount,
            pressure: pressure
        ) ?? self
    }

    func removingShiftModifier() -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: locationInWindow,
            modifierFlags: modifierFlags.subtracting(.shift),
            timestamp: timestamp,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: clickCount,
            pressure: pressure
        ) ?? self
    }
}

/// Puts the keyboard in a specific terminal, one runloop pass later so it lands after
/// AppKit has finished its own first-responder bookkeeping for the current event.
func focusTerminal(_ view: LineBreakTerminalView?) {
    DispatchQueue.main.async {
        guard let view, let window = view.window else { return }
        window.makeFirstResponder(view)
    }
}

/// Hands the keyboard back to whichever terminal is left after a split closes. The
/// shell view that held first responder is gone by then, and AppKit falls back to the
/// window itself, which reads as a dead keyboard until the user clicks.
///
/// `preferred` is the selected agent's attach view. It matters now that kept-alive
/// attaches stay in the hierarchy while hidden: a blind depth-first search could land
/// on an invisible terminal and strand the keyboard there, so the visible selected one
/// is focused instead.
func focusRemainingTerminal(preferring preferred: LineBreakTerminalView? = nil) {
    DispatchQueue.main.async {
        guard let window = NSApp.keyWindow else { return }
        // Only fill a focus vacuum. If the shell died on its own while the user was
        // typing in the sidebar filter or in Search, that field is still first
        // responder and yanking the keyboard into a live agent session is worse than
        // doing nothing.
        guard window.firstResponder === window else { return }
        guard let terminal = preferred ?? window.contentView?.firstTerminalDescendant()
        else { return }
        window.makeFirstResponder(terminal)
    }
}

private extension NSView {
    func firstTerminalDescendant() -> LineBreakTerminalView? {
        if let terminal = self as? LineBreakTerminalView { return terminal }
        for subview in subviews {
            if let found = subview.firstTerminalDescendant() { return found }
        }
        return nil
    }
}

/// Embeds a Ghostty terminal running a direct agent or ordinary-terminal attach
/// (locally or over SSH).
struct AttachTerminalView: NSViewRepresentable {
    let device: Device
    let target: TerminalAttachTarget
    /// Registry identity (the `AttachedEntry.id`), so the view stays addressable for
    /// focus while kept alive in the background. nil when not tracked.
    var sessionID: String? = nil
    /// The device's herdr server version, so attach picks a matching CLI binary.
    var serverVersion: String?
    /// nil when the server or active manifest does not advertise attachment support.
    let attachmentCapabilities: AgentAttachmentCapabilities?
    var fontName: String = ""
    var fontSize: Double = TerminalDefaults.defaultFontSize
    /// No longer maps to anything: Ghostty's renderer has no font-smoothing
    /// toggle. The setting stays so existing preferences keep syncing.
    var thinStrokes: Bool = true
    var fontWeight: Double = TerminalDefaults.defaultFontWeight
    var lineSpacing: Double = TerminalDefaults.defaultLineSpacing
    /// From SwiftUI's environment so theme switches re-render immediately.
    var dark: Bool = false
    var themeName: String = ""
    /// When false, mouse drags always select text locally even if the TUI
    /// requested mouse reporting (Shift+drag bypasses it either way).
    var mouseReporting: Bool = true
    /// Copies a local selection to the clipboard on mouse release.
    var copyOnSelect: Bool = true
    /// False while kept alive behind another view: Ghostty then stops drawing
    /// frames for it (output is still parsed), so busy background agents do
    /// not cost full-window Metal renders.
    var isVisible: Bool = true
    var onAttachmentError: (String) -> Void = { _ in }
    var onAttachmentUploadingChanged: (Bool) -> Void = { _ in }
    var onFocused: () -> Void = {}
    /// False for panes mounted only to fill a split: they must not grab the
    /// keyboard (and, through `onFocused`, the selection) when created.
    var focusOnCreate: Bool = true
    /// Called on the main queue when the attach process exits: the pane was taken
    /// over by another client, the SSH connection dropped, or herdr went away. A
    /// dead session otherwise keeps its last frame and silently eats every
    /// keystroke, which reads as a freeze.
    var onExit: ((Int32?) -> Void)? = nil
    /// Delivers the created view so a focus tracker can observe its window's
    /// first responder without retaining the terminal itself.
    var onViewReady: ((LineBreakTerminalView) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LineBreakTerminalView {
        let host = TerminalProcessHost()
        let view = LineBreakTerminalView(frame: .zero)
        view.processHost = host
        configurePasteHandling(view)
        context.coordinator.view = view
        context.coordinator.host = host
        context.coordinator.sessionID = sessionID
        context.coordinator.onExit = onExit
        host.onExit = { [weak coordinator = context.coordinator] code in
            coordinator?.processDidExit(code)
        }
        view.delegate = context.coordinator
        view.controller = GhosttyRuntime.controller
        view.onFocused = onFocused
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(host.session))
        configureAppearance(view)
        view.setSurfaceVisible(isVisible)

        let service = HerdrService(device: device)
        view.attachmentService = service
        let command = service.attachCommand(target: target, serverVersion: serverVersion)
        context.coordinator.authorizationID = command.authorizationID
        context.coordinator.scheduleAuthorizationCleanup()
        host.start(command: command)
        if let sessionID {
            AttachViewRegistry.register(view, for: sessionID)
        }
        // SwiftUI throws this view away and builds a new one whenever the selected
        // agent changes (the `.id("attach-…")` in ContentView), and a fresh NSView is
        // never first responder — so keystrokes went nowhere until the user clicked.
        // The hop to the next runloop pass is required: while `makeNSView` runs the
        // view has no `window` yet.
        let focusOnCreate = self.focusOnCreate
        DispatchQueue.main.async { [weak view] in
            guard focusOnCreate, let view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
        onViewReady?(view)
        return view
    }

    func updateNSView(_ nsView: LineBreakTerminalView, context: Context) {
        configurePasteHandling(nsView)
        nsView.onFocused = onFocused
        context.coordinator.onExit = onExit
        configureAppearance(nsView)
        nsView.setSurfaceVisible(isVisible)
    }

    /// Re-applied on update because capabilities can arrive after the terminal
    /// view is created, without changing its identity.
    private func configurePasteHandling(_ view: LineBreakTerminalView) {
        view.attachmentCapabilities = attachmentCapabilities
        view.attachmentDeviceKind = device.kind
        view.onAttachmentError = onAttachmentError
        view.onAttachmentUploadingChanged = onAttachmentUploadingChanged
    }

    static func dismantleNSView(_ nsView: LineBreakTerminalView, coordinator: Coordinator) {
        // A view being torn down must not report its own teardown as an exit.
        coordinator.onExit = nil
        if let sessionID = coordinator.sessionID {
            AttachViewRegistry.unregister(sessionID)
        }
        coordinator.host?.terminate()
    }

    private func configureAppearance(_ view: LineBreakTerminalView) {
        applyTerminalAppearance(
            view,
            fontName: fontName,
            fontSize: fontSize,
            thinStrokes: thinStrokes,
            fontWeight: fontWeight,
            lineSpacing: lineSpacing,
            dark: dark,
            themeName: themeName,
            mouseReporting: mouseReporting,
            copyOnSelect: copyOnSelect
        )
    }

    final class Coordinator: NSObject, TerminalSurfaceLifecycleDelegate, TerminalSurfaceOpenURLDelegate,
        TerminalSurfaceHoverLinkDelegate, TerminalSurfaceGridResizeDelegate {
        func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
            LineBreakTerminalView.openClickedLink(url)
        }

        /// Cell size for mapping a pointer to a cell (links under mouse capture).
        func terminalDidResize(_ size: TerminalGridMetrics) {
            view?.gridMetrics = size
        }

        func terminalDidUpdateHoverLink(_ url: String?) {
            view?.hoveredLink = url
        }

        /// Written on the main actor; read from `deinit`, which is nonisolated.
        nonisolated(unsafe) var authorizationID: UUID?
        var sessionID: String?
        var onExit: ((Int32?) -> Void)?
        weak var view: LineBreakTerminalView?
        var host: TerminalProcessHost?

        deinit {
            if let authorizationID {
                try? SSHCredentialStore.removeAuthorization(authorizationID)
            }
        }

        func scheduleAuthorizationCleanup() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                self?.discardAuthorization()
            }
        }

        private func discardAuthorization() {
            guard let authorizationID else { return }
            try? SSHCredentialStore.removeAuthorization(authorizationID)
            self.authorizationID = nil
        }

        func terminalDidAttachSurface(_ surface: TerminalSurface) {
            view?.attachedSurface = surface
        }

        func terminalDidDetachSurface() {
            view?.attachedSurface = nil
        }

        func processDidExit(_ code: Int32?) {
            discardAuthorization()
            let callback = onExit
            onExit = nil  // report once
            callback?(code)
        }
    }
}

@MainActor
func applyTerminalAppearance(
    _ view: LineBreakTerminalView,
    fontName: String, fontSize: Double, thinStrokes _: Bool,
    fontWeight: Double, lineSpacing: Double, dark: Bool, themeName: String,
    mouseReporting: Bool, copyOnSelect: Bool
) {
    GhosttyRuntime.applyTheme(named: themeName)
    GhosttyRuntime.applyFontSettings(
        fontName: fontName,
        fontSize: fontSize,
        fontWeight: fontWeight,
        lineSpacing: lineSpacing,
        copyOnSelect: copyOnSelect
    )
    view.mouseReportingEnabled = mouseReporting
    view.copyOnSelectEnabled = copyOnSelect
    // Colors are theme-only; keep the rest above this early return.
    // A chosen theme decides light vs dark by its own background, not the app's.
    let terminalDark = TerminalThemeSetting.definition(named: themeName)?.isDark ?? dark
    guard view.appliedDarkAppearance != terminalDark else { return }
    view.appliedDarkAppearance = terminalDark
    view.processHost?.setLightColorsEnabled(!terminalDark)
}

/// A kept-alive agent/terminal attach, registered by its `AttachedEntry.id`. Unlike a
/// standalone shell, an attached pane's view stays in the hierarchy (hidden) when
/// deselected so its content survives a switch away and back; the registry lets focus
/// commands and the split focus tracker resolve the currently selected entry's view.
///
/// Lock-guarded rather than actor-isolated: register/unregister run on the main thread
/// (make/dismantleNSView), but `liveViews` is also read from `SplitFocusTracker`'s KVO
/// callbacks, which are nonisolated even though AppKit delivers them on the main thread.
enum AttachViewRegistry {
    private struct WeakView { weak var view: LineBreakTerminalView? }
    private static let lock = NSLock()
    private static var views: [String: WeakView] = [:]

    static func register(_ view: LineBreakTerminalView, for id: String) {
        lock.lock()
        views[id] = WeakView(view: view)
        lock.unlock()
    }

    static func unregister(_ id: String) {
        lock.lock()
        views[id] = nil
        lock.unlock()
    }

    static func view(for id: String) -> LineBreakTerminalView? {
        lock.lock()
        defer { lock.unlock() }
        return views[id]?.view
    }

    /// Every live attach view. Only the selected one is visible/focusable, so "the
    /// responder is inside any of these" is equivalent to "the agent side has focus".
    static var liveViews: [LineBreakTerminalView] {
        lock.lock()
        defer { lock.unlock() }
        return views.values.compactMap { $0.view }
    }

    static func focus(_ id: String) {
        DispatchQueue.main.async {
            guard let view = view(for: id), let window = view.window else { return }
            window.makeFirstResponder(view)
        }
    }
}

/// A standalone local or SSH login shell, or the local login shell beside an
/// agent attach. Standalone views stay alive while deselected, so re-selecting
/// one uses the registry to restore keyboard focus.
@MainActor
enum ShellViewRegistry {
    private struct WeakView { weak var view: LineBreakTerminalView? }
    private static var views: [UUID: WeakView] = [:]

    static func register(_ view: LineBreakTerminalView, for id: UUID) {
        views[id] = WeakView(view: view)
    }

    static func unregister(_ id: UUID) {
        views[id] = nil
    }

    static func focus(_ id: UUID) {
        DispatchQueue.main.async {
            guard let view = views[id]?.view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
    }
}

struct ShellTerminalView: NSViewRepresentable {
    /// Session identity for the registry; nil for the ⌘D split shell.
    var sessionID: UUID?
    var device: Device = .local
    var fontName: String = ""
    var fontSize: Double = TerminalDefaults.defaultFontSize
    var thinStrokes: Bool = true
    var fontWeight: Double = TerminalDefaults.defaultFontWeight
    var lineSpacing: Double = TerminalDefaults.defaultLineSpacing
    var dark: Bool = false
    var themeName: String = ""
    var mouseReporting: Bool = true
    var copyOnSelect: Bool = true
    /// See `AttachTerminalView.isVisible`.
    var isVisible: Bool = true
    var onAttachmentError: (String) -> Void = { _ in }
    var onAttachmentUploadingChanged: (Bool) -> Void = { _ in }
    var onExit: ((Int32?) -> Void)? = nil
    /// Delivers the created view so a focus tracker can observe its window's
    /// first responder without retaining the terminal itself.
    var onViewReady: ((LineBreakTerminalView) -> Void)? = nil
    /// Replaces the default login shell (the editor drawer runs nvim here). Read once,
    /// when the view is created.
    var command: TerminalCommand? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LineBreakTerminalView {
        let host = TerminalProcessHost()
        let view = LineBreakTerminalView(frame: .zero)
        view.processHost = host
        // A shell has no agent manifest: pastes go through as text, while
        // dropped files still upload to a remote device.
        view.attachmentDeviceKind = device.kind
        view.attachmentService = HerdrService(device: device, autoStartLocalServer: false)
        view.onAttachmentError = onAttachmentError
        view.onAttachmentUploadingChanged = onAttachmentUploadingChanged
        context.coordinator.view = view
        context.coordinator.host = host
        context.coordinator.onExit = onExit
        context.coordinator.sessionID = sessionID
        host.onExit = { [weak coordinator = context.coordinator] code in
            coordinator?.processDidExit(code)
        }
        view.delegate = context.coordinator
        view.controller = GhosttyRuntime.controller
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(host.session))
        applyTerminalAppearance(
            view,
            fontName: fontName,
            fontSize: fontSize,
            thinStrokes: thinStrokes,
            fontWeight: fontWeight,
            lineSpacing: lineSpacing,
            dark: dark,
            themeName: themeName,
            mouseReporting: mouseReporting,
            copyOnSelect: copyOnSelect
        )

        let launch = command ?? HerdrService(device: device, autoStartLocalServer: false)
            .terminalCommand()
        context.coordinator.authorizationID = launch.authorizationID
        context.coordinator.scheduleAuthorizationCleanup()
        host.start(command: launch)
        if let sessionID {
            ShellViewRegistry.register(view, for: sessionID)
        }
        // Opening a shell hands it the keyboard: `makeNSView` runs once per shell
        // (the `.id` is stable across theme changes), so this never steals focus
        // back afterwards. The hop to the next runloop pass is required — the
        // view has no `window` yet while this runs.
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
        onViewReady?(view)
        return view
    }

    func updateNSView(_ nsView: LineBreakTerminalView, context: Context) {
        context.coordinator.onExit = onExit
        nsView.onAttachmentError = onAttachmentError
        nsView.onAttachmentUploadingChanged = onAttachmentUploadingChanged
        nsView.setSurfaceVisible(isVisible)
        applyTerminalAppearance(
            nsView,
            fontName: fontName,
            fontSize: fontSize,
            thinStrokes: thinStrokes,
            fontWeight: fontWeight,
            lineSpacing: lineSpacing,
            dark: dark,
            themeName: themeName,
            mouseReporting: mouseReporting,
            copyOnSelect: copyOnSelect
        )
    }

    static func dismantleNSView(_ nsView: LineBreakTerminalView, coordinator: Coordinator) {
        coordinator.onExit = nil
        coordinator.discardAuthorization()
        if let sessionID = coordinator.sessionID {
            ShellViewRegistry.unregister(sessionID)
        }
        // terminate() sends SIGHUP and escalates to SIGKILL — see
        // TerminalProcess.terminate for why SIGTERM is not enough.
        coordinator.host?.terminate()
    }

    final class Coordinator: NSObject, TerminalSurfaceLifecycleDelegate, TerminalSurfaceOpenURLDelegate,
        TerminalSurfaceHoverLinkDelegate, TerminalSurfaceGridResizeDelegate {
        func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
            LineBreakTerminalView.openClickedLink(url)
        }

        /// Cell size for mapping a pointer to a cell (links under mouse capture).
        func terminalDidResize(_ size: TerminalGridMetrics) {
            view?.gridMetrics = size
        }

        func terminalDidUpdateHoverLink(_ url: String?) {
            view?.hoveredLink = url
        }

        var onExit: ((Int32?) -> Void)?
        var sessionID: UUID?
        /// Written on the main actor; read from `deinit`, which is nonisolated.
        nonisolated(unsafe) var authorizationID: UUID?
        weak var view: LineBreakTerminalView?
        var host: TerminalProcessHost?

        deinit {
            if let authorizationID {
                try? SSHCredentialStore.removeAuthorization(authorizationID)
            }
        }

        func scheduleAuthorizationCleanup() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                self?.discardAuthorization()
            }
        }

        func discardAuthorization() {
            guard let authorizationID else { return }
            try? SSHCredentialStore.removeAuthorization(authorizationID)
            self.authorizationID = nil
        }

        func terminalDidAttachSurface(_ surface: TerminalSurface) {
            view?.attachedSurface = surface
        }

        func terminalDidDetachSurface() {
            view?.attachedSurface = nil
        }

        func processDidExit(_ code: Int32?) {
            discardAuthorization()
            let callback = onExit
            onExit = nil  // report once
            callback?(code)
        }
    }
}

// MARK: - Link copy popup

/// A link printed in the terminal: `text` exactly as shown, rows rejoined,
/// and `url` normalized for opening.
struct TerminalLink: Equatable {
    let text: String
    let url: String
}

/// The small Copy button shown over a link the pointer rests on.
/// Transient "Copied" notice shown after a mouse selection is copied. Ignores
/// the mouse so it never gets between the pointer and the terminal.
final class CopiedToast: NSVisualEffectView {
    init() {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor

        let icon = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .systemGreen
        let label = NSTextField(labelWithString: String(localized: "Copied to clipboard"))
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .labelColor
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(String(localized: "Copied to clipboard"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        super.updateLayer()
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    /// Fades out after `delay` seconds, then removes itself and calls `done`.
    func dismiss(after delay: TimeInterval, done: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.superview != nil else { return done() }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                self.animator().alphaValue = 0
            }, completionHandler: {
                self.removeFromSuperview()
                done()
            })
        }
    }
}

final class LinkCopyPopup: NSVisualEffectView {
    let link: TerminalLink
    private let onCopy: (TerminalLink) -> Void
    private let button: NSButton

    init(link: TerminalLink, onCopy: @escaping (TerminalLink) -> Void) {
        self.link = link
        self.onCopy = onCopy
        button = NSButton(title: String(localized: "Copy"), target: nil, action: nil)
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor

        button.isBordered = false
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        button.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.contentTintColor = .labelColor
        button.toolTip = link.text
        button.target = self
        button.action = #selector(copyClicked)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            button.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        setAccessibilityLabel(String(localized: "Copy"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // The terminal under the button must not see the click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateLayer() {
        super.updateLayer()
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    @objc private func copyClicked() {
        onCopy(link)
    }

    /// Confirms the copy in place, then lets the owner close the popup.
    func showCopied(then done: @escaping () -> Void) {
        button.title = String(localized: "Copied")
        button.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        button.isEnabled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: done)
    }
}
