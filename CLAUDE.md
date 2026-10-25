# MacHerdr (formerly herdrm)

Native macOS console for [herdr](https://herdr.dev) (the terminal workspace manager for
coding agents). Sidebar lists Spaces (herdr workspaces) and Agents; the bottom-left
footer switches devices (Local + remote herdr hosts over SSH); the right pane is a pure
embedded terminal running `herdr agent attach` — no chat composer.

Design canvas (waku-style sidebar, light/dark): `design/` — published as the
"Herdr for Mac" artifact. `design/canvas.json` notes carry the design tokens and specs.

## Layout

- `Packages/HerdrKit` — SPM library (macOS + iOS): NDJSON-over-Unix-socket RPC
  (`SocketRPC`), models, `Device`/`DeviceStore` (persisted to
  `~/Library/Application Support/HerdrM/devices.json`). macOS-only files are
  `#if os(macOS)`-gated: `SSHTunnel` (OpenSSH forward), `HerdrService` facade,
  `ShellEnvironment`, `LocalServer`, `DeviceFileService`, `SSHCredentialStore`.
- `Sources/MacHerdr` — macOS SwiftUI app (XcodeGen `project.yml`). The terminal is
  libghostty (`GhosttyTerminal` product of Lakr233/libghostty-spm, Metal): each
  pane is a host-managed `InMemoryTerminalSession` fed by `TerminalProcess`, a
  local `forkpty` byte pump. `LineBreakTerminalView` subclasses ghostty's
  `AppTerminalView` and keeps MacHerdr's own behavior (light-mode ANSI adapter,
  ⌘-editing-key readline chords via `session.sendInput`, agent-aware paste).
- Editor drawer (⌘E, per herdr tab, local only): `EditorDrawerRegistry` / `NvimClient` in
  HerdrKit, `DrawerSplit` / `EditorDrawerStack` in `Sources/MacHerdr/EditorDrawerView.swift`.
  nvim runs with `--listen $TMPDIR/macherdr-nvim-*.sock`; ⌘K files go over that socket.
- `design/` — design canvas working files (`*.dc.html` artboards + `canvas.json`).

## Build & test

```sh
make build      # xcodegen + xcodebuild → build/Build/Products/Debug/MacHerdr.app
make run
make kit-test   # HerdrKit integration tests (need a running local herdr)
HERDRM_E2E_SSH_TARGET=vincent@10.10.10.87 make kit-test   # + remote SSH E2E
```

xcodebuild needs `-skipPackagePluginValidation`; the Makefile passes it. Building
against Xcode 27 needs the Metal toolchain component (libghostty compiles a Metal
shader): `xcodebuild -downloadComponent MetalToolchain` once.

## Release

None. This is a personal fork with no releases; the upstream release workflow was removed.
Upstream (missuo/herdrm) shipped via a tag-triggered CI pipeline, which this fork does not use.

## herdr protocol notes (0.9.0, private protocol 22; verified against the live socket)

- Requests are NDJSON `{"id","method","params"}` on `~/.config/herdr/herdr.sock`;
  `params` must be present even when empty (`{}`), or the server rejects the request.
- `tab.create` returns the new pane as `result.root_pane.pane_id`.
- `events.subscribe` takes `{"subscriptions":[{"type":"pane.updated"},…]}`.
  `pane.agent_status_changed` is pane-scoped and must be subscribed with `pane_id`;
  status transitions do not emit `pane.updated`. MacHerdr appends one scoped status
  subscription for every known pane and re-subscribes when pane topology changes.
  `pane.scroll_changed` / `pane.output_matched` are scoped too.
- Terminal attach: agents use `herdr agent attach <pane_id> --takeover`; bare shells use
  `herdr terminal attach <terminal_id> --takeover` (takes the pane over from other attached
  clients). Remote devices run it through `ssh -tt` with PATH prepended
  (`sshd` exec is not a login shell; herdr lives in `/opt/homebrew/bin` on macOS hosts).
- `pane.layout {pane_id}` returns cell rects + flat `splits` (direction right|down, ratio, rect); the tree is
  rebuilt in `HerdrKit/PaneLayout.swift` (`SplitTree`). `layout.set_split_ratio {tab_id,path:[bool],ratio}` sets an
  absolute ratio (`path` []=root, false=first child, true=second; `split_not_found` when the child is a leaf);
  `pane.focus {pane_id}` / `tab.focus {tab_id}` focus by id (`pane.resize`/`pane.focus_direction` are directional
  only). Split ids encode the path (`split_1_0` = first child of the root). The Sidebar/tab bar/split view use these:
  `SpaceTabBar` (tabs from `session.tabs`), `AppModel.activeLayout` + frame placement in `ContentView.attachedTerminal`.
- herdr keybindings: panes attach one at a time, so herdr's TUI never sees `prefix+key` chords. `HerdrKeyRouter`
  (an `NSEvent` local monitor) reads `[keys]` from `~/.config/herdr/config.toml` (`HerdrKit/HerdrKeymap.swift`,
  defaults from the docs, prefix state machine `KeyPrefixMachine`) and runs `AppModel.perform(_:index:)`. Direct
  chords like `ctrl+1..9` work without the prefix; prefix twice sends the literal key; remote devices use the local
  config. Unsupported actions (copy/resize mode, detach) are swallowed after the prefix.
- Git branch/ahead per space comes from `GitStatusProvider` (reads `.git/HEAD`, `git rev-list` for ahead); local
  devices only.
- Agent status buckets sort Blocked > Done > Working > Idle (matches Heeler).

Reference repos: `~/Projects/herdr` (server source), `~/Projects/Heeler` (iOS client,
same domain model), `~/Projects/waku` (sidebar design reference).
