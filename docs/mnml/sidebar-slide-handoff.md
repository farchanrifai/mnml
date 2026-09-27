# Handoff: the page jumping when the sidebar shows or hides (2026-09-27)

For whoever picks this up next (ChatGPT/Codex or Claude). Work on branch
`command-bar` in the worktree `../search-browser-under` (it is stacked on
`page-under-chrome`; nothing of either is merged to `main` yet).

## The problem

When the column (sidebar) is shown or hidden (⌘S, `Browser.toggleFold` in
`Fold.swift`, animated with `Motion.glide`), the page ends up at its new
width in one jump: a site like YouTube re-centres its layout at once and the
video visibly shifts by about half the column's width.

User's recording: `~/Library/Mobile Documents/com~apple~CloudDocs/Macbook Pro/Screenshot/Screen Recording 2026-09-27 at 1.39.34 AM.mov`
(page under the sidebar off; YouTube Shorts).

## Why it happens (by design today)

`App.swift` → `ContentView`: `room` / `roomed` / `make(room:after:)`. The
page (the stage) is laid out to its new size **once per slide**, not on
every frame — the original author found a page resized every frame
"juddered along its right edge and overshot the window with the spring".

- Column arriving: the page slides with it at its old width (its right edge
  runs off the window), then gives up the room after 0.42 s → jump.
- Column leaving: the page gets its room at once (jump first), then slides.

With **page under the sidebar** on (`Browser.pageUnder`, Settings › Tabs),
the stage is the window's size and the column's width is given to the page
as leading safe area in `covered` (`App.swift`), used by `Bleed` in
`Stage.swift` (SwiftUI's `.backgroundExtensionEffect()` + `.safeAreaPadding`).
That strip under the column is filled with a **mirrored** copy of the page's
edge; a gradient in the window's ground (also in `Page`, `Stage.swift`)
keeps the colour to `Bleed.reach` (84 pt) from the edge.

## Tried and reverted: resize the page on every frame (page-under only)

`covered.leading` was switched from `roomed.width` to `chrome.width` so the
safe area followed the slide. Result (user's recording
`Screen Recording 2026-09-27 at 1.46.19 AM.mov`): while the column hides,
its rows fade and its see-through panel slides away out of step with the
page's safe area, so the **bare mirrored copy** of the page is exposed —
backwards "Big Buck BUNNY", the YouTube logo mirrored, ghosted copies — and
the ground gradient, being part of the resizing page, lagged too. Reverted;
`covered` follows `roomed` again.

Lesson: anything that lets the covered strip and the column move
separately exposes the mirror. Don't animate the safe area on its own.

## Original proposal: a snapshot cross-fade over the resize

This was intended to work with page-under on or off without touching the mirror.

1. Just before the stage's size changes for the slide (in `make(room:)`, or
   where `room` is set), take a snapshot of the page as shown:
   `WKWebView.takeSnapshot(with:)` (see how `Tab.swift` snapshots for the
   sleeping-tab `cover` and the tab previews — `WKSnapshotConfiguration.rect`
   is the part of the page that shows).
2. Put it over the page, the size it was, moving with the slide as the page
   did (the `Page` view already lays `tab.cover` over the page — reuse or
   mirror that path).
3. Let the web view take its new size underneath.
4. When WebKit has drawn the new layout (next frame or two after the
   resize; `PageView.unpainted` / `holdForFirstFrame` in `Tab.swift` may
   help), fade the snapshot out over ~0.15 s.

Watch for: a snapshot takes a moment (async) — if it isn't back when the
resize should happen, resize anyway rather than hold the slide; video keeps
playing under a still picture for that instant (short enough?); dark/light;
split view (`SplitStage`, has its own layout — leave it alone unless it
also jumps); a slide interrupted by another toggle (`roomTicket`).

Alternative if the cross-fade feels wrong: keep one animation for both the
column and the page's covered strip (so the mirror is never exposed) — needs
the column's hide/show transition (`SideBar` in `App.swift` `window_`,
`.transition(.move(edge: .leading))`, plus `Fold.swift`) reworked to move
exactly with the page. Riskier.

## Follow-up experiments (2026-09-27, uncommitted)

The snapshot proposal was tried in `mnml Test` on the Big Buck Bunny YouTube
page. `WKWebView.takeSnapshot` took 1.52 s, and 1.39 s with
`WKSnapshotConfiguration.afterScreenUpdates = false`. Both exceed the 0.42 s
slide. A 0.12 s timeout meant the old one-step resize still showed; waiting
for the image would stall the sidebar. The snapshot code was removed.

The shared-edge alternative was tried next. A persistent sidebar was offset
by the page's `roomed.width`, and the leading safe area was animated to the
same target. In a slowed test slide, the sidebar had nearly left while the
mirrored strip still occupied hundreds of pixels. Matching target values did
not make SwiftUI's presentation of the two effects stay together.

Finally, both edges were driven explicitly from one 60 Hz width value with
animations disabled on each update. The mirror stayed covered in the midpoint
frame, but the YouTube video went black while WebKit was resized repeatedly.
That experiment was removed too. App code and the installed test copy were
restored to the baseline before the next experiment. No commit was made.

`NSView.cacheDisplay(in:to:)` on the active web view then captured the full
YouTube page, including the video picture, in 0.075 s. A synchronous cache
and short crossfade around the existing one-step resize were tried in
`mnml Test`. The user's `10.08.11 AM.mov` recording shows that the page still
holds its old position while the sidebar moves, then re-centres near the end.
Safari's `1.59.29 AM.mov` instead moves the content through the transition.

The current uncommitted `App.swift` experiment resizes WebKit once at the
start and covers it with a cached picture during the sidebar's spring. The
user's 10.45.22 AM recording showed two readable copies of YouTube during the 0.22 s fade. Shortening it to 0.10 s
exposed a blank WebKit video surface in the 10.49.56 AM recording while the
rest of the page stayed drawn. The 11.01.54 AM recording showed a second page
in the strip uncovered by the sidebar: moving the cached image only half the
sidebar width left that strip exposed. The cached image now moves its leading
edge the full sidebar width and changes width with it, while WebKit resizes
once underneath. It stays opaque for 0.20 s, then fades over 0.10 s.
**This geometry still needs visual review** with a playing video, quick reversals, and page-under off. If it
looks wrong, remove it; `takeSnapshot` and per-frame WebKit resizing have
already failed.

## How to work here (the user's rules)

- Build experiments into the test copy: `./build.sh release test` →
  `/Applications/mnml Test.app` (own settings: `com.farchan.mnml.test.copy`;
  page under the sidebar is on there). The main app is for real use; only
  build it (`./build.sh release install`) when the user asks.
- The user judges by feel, from screen recordings in the folder above.
  Extract frames with ffmpeg (filenames have a narrow no-break space before
  AM/PM — glob them). A region's average colour per frame:
  `ffmpeg -i x.mov -vf "fps=10,crop=w:h:x:y,scale=1:1,format=rgb24" -f rawvideo - | xxd -p`.
- Commit only when the user says; don't merge to `main`.
- Comments explain *why*, in plain sentences, in the voice of the file.
- `build.sh` stamps the binary with the real SDK (`vtool`); SwiftPM alone
  writes 14.0 and macOS then keeps mnml on old behaviour (this is what made
  the page-under bleed draw a double page). Probes built with `swiftc` don't
  have the problem, so a probe can look fine where mnml isn't.
- Don't leave copies of mnml Test registered with Launch Services (a copy
  with the same bundle id made macOS refuse notification permission):
  `lsregister -u <copy>` and delete it; check with
  `lsregister -dump | grep 'mnml Test.app'`.
- In this shell `log` is a zsh builtin: use `/usr/bin/log`.

## Related docs

- `docs/mnml/page-under-chrome.md` — how the page-under bleed ended up.
- `MNML-ROADMAP.md` (local, main repo) — roadmap; update it.
