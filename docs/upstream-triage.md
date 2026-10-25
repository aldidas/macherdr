# Upstream triage

This fork stays minimal: herdr's basic TUI layout and functionality, made macOS-native.
Upstream (`missuo/herdrm`) is adopted selectively by cherry-pick, not merged wholesale
(see `.claude/skills/upstream-check`). This file records what was decided so already
reviewed commits stop showing up as new.

**Last reviewed upstream commit:** `ffbbaba` (v0.6.21), 2026-10-25.
Only commits after it need review.

## Taken (cherry-picked with `-x`, upstream hash in each commit message)

- `55d0d19` New Agent creates a space when the device has none
- `722ba85` Tell herdr attach the terminal draws Kitty graphics
- `5cfabed` SSH socket tunnel gets its own connection, never a ControlMaster
- `173939e`, `c499c71` Stop and reap tunnels orphaned by a killed app
- `5686ee6` Quit on SIGTERM without deadlocking the main queue
- `55ff118` Return confirms the close dialog
- `cc78427` Socket client reads a reply the server sent before closing
- `1962010` Link hover/⌘-click cell size from Ghostty's grid delegate (adapted by hand; find-bar line dropped)

## Skipped on purpose (extra UI/config beyond the herdr layout, or features not used)

- Machine stats (meters, details panel, stats ssh session): `40f6ec2`, `84695dd`, `fc58043`,
  `de19fae`, `ab8f8ae`
- grazr accounts (switch, re-auth, dial, clock, refresh): everything touching `Grazr*`
- Custom launch arguments and YOLO mode: `620fb84`
- tailcat device fixes: `2e52786`, `81ef2ec`, `f845955`, `3dfa6fc`
- ⌘F find bar `547ad6f` (new feature, 390 lines)
- Pane keyboard commands `efd26f3` and split-ratio scoping `1fd81af` (built on upstream's `TabLayout`, which the fork lacks)
- v0.6.16–0.6.17 features: Claude history rail, sidebar pane tree/group-by-space, ⌘D herdr split, cmd-click file paths (`d8ac6d7`, `ac53abe`), jump-to-bottom and history scrolling, Recent agents, `6e67efb`, more grazr/stats
- `fd92031` local Release version stamping, `0ba0ee5` CI release notes, changelog commits
- v0.6.18–0.6.21: Project panel, image thumbnails, Files batch transfer, host-full stats, grazr, sidebar contrast fixes (`d67a874`, `3d4553e`), new icon, CI/docs
- Deferred, not rejected: `eaca250` (installed agent CLIs on SSH devices) and `25f14b5` (new-item sheets keep their space); both conflict and need hand porting

Revisit a skipped item only if the user asks for it; it stays available in `upstream/main`.
