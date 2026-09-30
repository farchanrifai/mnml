# Upstream sync 8

Worktree: `/Users/farchan/.codex/worktrees/upstream-sync-8/search-browser`
Branch: `codex/upstream-sync-8`
Base: `10f01fc`; upstream: `1ec28a0` (115 commits after the last sync).

## Scope and resolution

A real upstream merge is pending. Selected upstream changes were replayed in chronological order into mnml's files, with conflicting hunks adapted to its models. The main checkout and installed main app were not rebuilt or changed.

Included:

- Form mutation throttling and cheaper scroll-time sign-in scanning; tab-width reuse; fullscreen chrome restoration for either mnml split pane; live playback-rate and floating-video ancestor fixes.
- Download pause, resume, failure details and retry; background file import with cancellation, progress and safe quit cleanup.
- Find case/whole-word options, counts, highlighting and bounded page scans; Ctrl-Tab still closes Find.
- Tab site-search chips and learned OpenSearch descriptions with hostname validation.
- Pinned rows, pin display conversion and Clear; their state travels through pins, sessions, parked Spaces and window reconciliation.
- Fresh-window startup preserving pins; Arc folders mapped to mnml groups and Arc cached icons adopted asynchronously.
- Native page/service-worker notifications, per-origin choices and removal controls; geolocation with Allow once/Always allow.
- Conditional passkeys and updated credential methods; URL-sensitive history identities, favicon refresh/appearance and bookmark import preservation.
- Extension popup ownership/sizing, background and offscreen messages, scripting, manifest matching, native worker sockets and rollback/file integrity fixes.
- Pointer selection in the existing Ctrl-Tab switcher.

Preserved: mnml's Ask/providers/BYOK, saved chats, splits, groups, memory profiles, Space appearance/popover/transitions, navigation boundaries, shortcuts, browser chrome, and build/distribution setup. The AI source files and Split/Space transition implementation have no changes from the base.

Skipped by request: upstream AI, its bundled engine/Intel packaging, upstream Split View replacement, and extension screen recording/pill. Tooling for those features was removed too. Python tests coupled to upstream's Split model were not imported; the tests below exercise our model instead.

The existing mnml UI wins where implementations differ: its drag gestures, tinted pin styling and cached parked groups remain. New controls reuse the existing settings pages and sidebar components. Find keeps its capsule; permission prompts keep mnml's card. The updater keeps mnml's disabled public feed, with its state-aware menu available only for a configured feed.

New switches retain upstream defaults: site search, pinned rows and fresh-window startup off; site notification requests on. Geolocation always asks per origin. Visible mnml Test is excluded from the hidden-probe screen watchdog. No provider fallback or AI migration was introduced.

## Verification

- Debug and signed Release builds succeeded; only mnml Test was assembled.
- `MNML_PROBE=sync8-unit swift test`: 62 tests passed, including downloads and import lifecycle checks and mnml's existing Ask, PiP, groups, Space appearance and shortcuts tests.
- `MNML_PROBE=sync8-adapt swift test --filter UpstreamSyncTests`: 2 adaptation tests passed (pin tiers/session backward compatibility and stationary-pointer behavior).
- `./test-find`: 62/62 page-engine checks passed.
- `sh Tests/HistoryRegression/run.sh`: URL identity regressions passed.
- `sh Tests/run-extension-files-tests.sh`: all file replacement/preservation checks passed.
- Live local-fixture checks are in `Tests/upstream_sync_smoke.py`, using an explicitly named world and the existing bench transport. They exercise case/whole-word Find, site chips/encoding/Esc, pins, switcher geometry/shared click handling geolocation's test-only permission response and native notification test delivery. All live assertions passed.

Installed mnml Test build `202609290804` was signature-verified and opened with its existing profile. `Tests/find-tab-shortcut-check.py` passed there: Control-Tab closes Find and reaches tab navigation, then restores the original tab.

Static pictures establish layout, not animation/playback performance. Screen-recorded playback, YouTube/PiP handoffs, actual passkey sign-ins and OS notification delivery still need hands-on QA. macOS computer-use capture returned ScreenCaptureKit error -3811. Dry permission checks do not request actual location or post OS notifications.

## Delivery boundary

Use mnml Test for user testing. Do not rebuild/install the main app or fast-forward main without the user's request/acceptance. The merge should remain reviewable in this worktree until that acceptance; do not push main as part of test delivery.

## Excluded upstream commits

- `18ac5ab` Split View: two tabs side by side, off unless turned on
- `2b22dd0` AI add-on, first part: keys and requests (off, nothing calls it yet)
- `e1fa4c8` With Split View off, a tab switch no longer rebuilds the page
- `ff02162` Split View never unpins a tab, and a pair goes into a group whole
- `1004cc9` Split View's pairs: a list of pages with an axis, kept when the switch is off
- `b6c51bb` AI add-on, second part: what of a page goes to the model (off, nothing calls it yet)
- `d576aa2` Split View's stage: one AppKit view for one page or two, grey, with a divider of its own
- `fd33667` AI add-on, third part: sign in with OpenRouter (off, nothing calls it yet)
- `9b2af7a` Split View in the row: the pair stacked in the column, one cross, the live grey on the focused page
- `f0f0cc3` AI add-on: Summarize Page and Ask About This Page…, the panel, Settings › AI
- `cefb554` AI: text in the colour of its background left out, clutter before the cut, a word when a page writes for an AI
- `8c9c3bc` Split View: in and out — page edges, Open in Split View, ⌥⌘N with open tabs to bring in, the divider's menu
- `4d882fa` Split View with the rest: pins split as a copy, float, find, the link bubble, Close Other Tabs, moves
- `4459c1c` AI add-on: On this Mac — the engine, engine.sh, and running it
- `96d15f4` Split View: a page of the pair asks over its own half, and the other goes on working
- `3fdda78` Split View moves: pages glide into their halves, grow back, swap and even out as pictures
- `ecfad1e` AI add-on: tighter checks from the pre-release pass
- `e5596f1` Split View polish: whose page is whose, a pane's question marked in the row, keys follow focus, a hidden test suite
- `08a937d` Split View: an extension can't move typing from one page of the pair to the other
- `c9cf1ab` Split View: say why the keys may pick the focused page — a page can't ask for them
- `e47f23c` The Apple Silicon feed can offer the AI engine: build.sh writes its block, publish.sh puts it beside the app
- `b1587f8` Split View: the ⌃Tab switcher shows a pair as one card, both pages side by side
- `5547082` Split View: a peeked link can be kept beside the page it came from
- `313c731` The recording pill: an extension recording says so, with Stop
- `30c7509` The recording pill's dot is red, its one colour
- `c0d57c9` Extensions can record the screen: the broker, the channel and the shim (work in progress)
- `2e198d4` Recorders: test runs keep Search's question; websites get the pretend devices too
- `46b4b7b` Recorders: the pill shows what the broker sees; a refusal holds for the session
- `686cf03` Recorders: every screen recording through Search's question; offscreen recorders (phase 2)
- `605ecff` Recorders: the extension's button counts for a minute; a tab sharing its screen gets the pill
- `a352b40` Recorders: a site's Stop ends its screen share only, not its call

## Notification integration follow-up

- Site popup and tab-sleep protection now use the same per-origin notification permissions as Settings and WebKit. Private tabs cannot save notification choices or qualify for notification sleep protection. Disabling site notifications removes that sleep exemption.
- Legacy host choices migrate to the standard HTTPS origin only; existing origin choices win, and Ask/Remove cannot resurrect an old choice. Other schemes and ports ask separately.
- Notification clicks search current and parked Space tabs and constrain matches to the originating website data store when known, using mnml's existing select/window/PiP handling.
- Focused NotificationIntegrationTests and PiPSpaceTests passed (2 tests); actual OS notification clicks during video/PiP remain manual QA.
