# Plan: the page under the sidebar and top bar (Safari 26 bleed)

## Where it ended up (2026-09-26, on the Mac)

Working in mnml Test; the notes further down are the plan and the attempts
before it, kept for the reasons things were dropped.

- **Column:** SwiftUI's `.backgroundExtensionEffect()` on the page, with the
  column's width as leading safe area (`Bleed` in `Stage.swift`). The page is
  placed beside the column; a mirrored copy of its edge fills the strip under
  it, live. A gradient in the window's ground over that copy keeps the colour
  to `Bleed.reach` (84 pt) from the page's edge.
- **Top strip and bookmarks bar:** WebKit's public `obscuredContentInsets`
  (fill off) lets the page scroll up beneath; `TopGlass` in `Under.swift`
  blurs it with Core Animation's private backdrop layer (radius 20) under a
  90 % tint of the ground. Liquid Glass where that layer isn't.
- **The double page** — a copy of the page painted over its own top-left
  quarter, whatever did the extending — was the binary's recorded SDK:
  SwiftPM stamps it with the deployment target (14.0), so macOS 26+ kept
  mnml on the old behaviour. `build.sh` now writes the real SDK in with
  `vtool` (the minimum stays 14). Every other app-wide macOS 26 behaviour
  comes with it: look for changes anywhere.
- **Dropped on the way:** WebKit's inset fill (one flat colour), a
  `CAReplicatorLayer` (a web view copies as nothing), AppKit's
  `NSBackgroundExtensionView` (upside-down copy that scrolled the wrong way,
  and the double page), a portal layer of our own (scrambled WebKit tiles),
  an `NSSplitViewController` rewrite (worked, but SwiftUI's modifier does
  the same inside mnml's own window), and for the top bar the window
  materials, SwiftUI's glass and a Core Image background filter (none of
  them blur a web view) and AppKit's Liquid Glass (too light).
- Probes for each are in `docs/mnml/scratch/`.

**Goal:** the page's colours bleed live into the sidebar and the top bar, as in
Safari 26 (and like YouTube's ambient mode), while the bars keep the native Mac
material. Page content must never be hidden behind a bar.

**How Safari does it:** the page runs *under* the bars. WebKit is told which
strip is covered, keeps the page's layout clear of it, and fills that strip
with colours continued from the page's edge; the bar's material blurs whatever
is beneath it, live.

Tried and dropped (2026-09-26): tinting the whole bar in the page's
theme-color (it flipped light/dark against the setting), and a sampled glow
(snapshots of the page's edge a few times a second, blurred over the bar — read
as a smear, and wasn't live).

## What it should look like (no screenshots available)

- Safari 26 on macOS, sidebar on the left, YouTube open (dark page). The
  sidebar is still the Mac's see-through material everywhere. Near the page,
  the page's colours show through faintly — as you scroll, the sidebar's
  colour shifts with what is next to it (darker beside the dark header,
  warmer beside a bright thumbnail or the playing video). The user calls it
  "like YouTube's ambient mode": a soft bleed, not a colour change.
- It updates live with scrolling and video, every frame — this is why the
  sampled-glow attempt failed: at ~6 updates a second it trailed, and even
  toned down (14 %, last fifth of the bar) it read as a smear.
- The bar's text and icons follow the app's own Light / Dark / System
  setting (Settings › General), never the page. A first attempt that made the
  bar take the page's colour flipped the window between light and dark on
  every tab switch; the user rejected it.
- The native material must stay. The bleed is the page seen through it, not
  a replacement for it.

## Current state

- `Sources/mnml/App.swift` → `window_`: a `ZStack`. `stage` (the page) is
  drawn first; `SideBar` and `TabBar` are drawn over it. The page is kept out
  from under them with `.padding(.leading/.top, roomed…)` and
  `.offset(chrome…)`; `room` / `make(room:after:)` resize the page once per
  sidebar show/hide, not every animation frame. A comment there notes the page
  was kept beside the chrome on purpose, to save a compositing pass.
- `Sources/mnml/Design.swift` → `Frosted`: `NSVisualEffectView`, `.sidebar`
  material, `.behindWindow` blending (blurs the desktop only). Used by
  `Side.swift` (column background) and `TabBar.swift` (strip background) when
  `prefs.frostedSidebar` is on (Settings › Tabs › Mac window material).
- `Sources/mnml/Stage.swift` → `StageView` hosts the page's web view and sets
  `wanted.frame = bounds`.

## APIs (checked on macOS 26 / 27)

- `WKWebView.obscuredContentInsets` — **public** on macOS 26+: the area of the
  web view covered by other content.
- `-[WKWebView _setUsesAutomaticContentInsetBackgroundFill:]` — SPI, macOS 26+:
  fills the covered strip with the page's edge colours.
- `_setAutomaticallyAdjustsContentInsets:`, `_setTopContentInset:` also exist.

## Steps

1. **Prove the insets alone.** In a scratch app, a bare `WKWebView` on YouTube:
   set `obscuredContentInsets = NSEdgeInsets(top: 0, left: 220, bottom: 0,
   right: 0)` and turn on the automatic fill. Confirm the page lays out right of
   220 pt and the strip is filled with edge colours. Also try `top`. **If WebKit
   ignores the left inset, stop and report** — only the top bar is possible.
2. **Page under the bars.** In `window_`, drop the leading/top padding that
   keeps the stage beside the column / under the strip, so the page is full
   size; pass the chrome size down to the stage.
3. **Tell WebKit.** Where the web view is hosted, set `obscuredContentInsets`
   to the column width or strip height and turn on the fill; update on resize,
   show/hide, fold. In split view (`SplitStage`) only the leftmost pane gets
   the left inset.
4. **Bars blur the page.** Switch the bars' material to `.withinWindow`
   blending (the page beneath instead of the desktop). Compare with
   `.behindWindow` and choose.
5. **Smooth show/hide.** The page used to be resized once per show/hide
   (`room`). With insets: size the page once and animate only the inset, if
   WebKit animates it smoothly; otherwise set it at the end of the slide.
6. **Things that assume the page starts at the column's edge** — check each:
   - picture-in-picture start/end rectangles (`SystemPiP.swift`: the flipped
     start rect; `StageView.park`)
   - mnml's floating window (`Float.swift`)
   - peek (`Peek.swift`)
   - find bar and link bubble positions
   - the folded / hidden column (`Fold.swift`), which already floats over the page
   - tab hover previews (`TabPreview.swift`, placed from the column's edge)
   - full screen and immersed video (`active.immersed`)
   - `renewGState` position updates (`StageView.placed`)
7. **Setting.** Under the existing Mac window material switch or a separate
   one, on by default. Off must give exactly today's layout.

## Risks

- Sites wider than the window may lay out under the column despite the inset —
  test Google Sheets, YouTube, and a page wider than the window.
- The compositing cost the original author avoided — check 4K YouTube
  scrolling and GPU use in Activity Monitor.
- The fill is SPI; without it the strip shows the page's plain background.

## Working

- **mnml only builds on a Mac** (AppKit, WebKit, SwiftUI; `swift build` /
  `./build.sh`). A session without macOS can't compile, run or look at it:
  work on a branch (e.g. `page-under-chrome`), keep each step small and
  self-contained, and leave building and trying to the user, who builds
  experiments into "mnml Test" with `./build.sh release test` (the main app
  is for real work). Step 1 (the scratch app) has to run on the Mac too —
  write it as a small standalone Swift file the user can run with `swiftc`.
- Say plainly what couldn't be verified. The user judges every change by
  feel; commit to `main` only once they've tried it.
- Match the surrounding code: comments explain *why*, in plain sentences, in
  the voice of the file (see `SystemPiP.swift`, `Stage.swift`).

## Progress (branch `claude/safari-style-window-sidebar-feto94`)

Written without a Mac: nothing below has been built or run.

- **Step 1:** `docs/mnml/scratch/InsetProbe.swift`, run with
  `swiftc -parse-as-library docs/mnml/scratch/InsetProbe.swift -o /tmp/probe && /tmp/probe`.
  Run it first: if the left inset is ignored, the column half comes out.
- **Steps 2–5:** `Sources/mnml/Under.swift` holds the WebKit calls (asked by
  name, so any SDK builds) and `Browser.pageUnder`. Settings › Tabs › Page
  under the sidebar (`tabs.under`), off by default, and only with the Mac
  window material on. The stage keeps no room beside the chrome; `Page` /
  `WebStage` / `StageView.under` carry the covered strip to the web view.
  The inset follows `roomed`, not `chrome`, so it changes once a slide, as
  the page's size did: going away uncovers at once, arriving covers once the
  slide is over.
- **Split view keeps today's layout.** Its pages sit on cards with a margin
  and a ground colour of their own, so they never meet the column; a left
  inset for the leftmost card would only add a strip of fill beside a gap.
- **Blending:** `.withinWindow` when the page is under.
  `defaults write com.farchan.mnml.test under.behindWindow -bool YES` puts
  back `.behindWindow` for comparing; remove the key once chosen.
- **Step 6, checked:** find bar, account list, link bubble (and where it
  moves to dodge the pointer), history disc and list, the failure and
  floating messages are kept clear of the chrome. The floating window
  clears the inset and keeps the width the page showed. Peek and the split
  drop layer already pad by the chrome. Picture-in-picture, `park` and
  `placed()` measure the web view itself, which no longer moves: no change.
  Fold, tab previews, immersed video: chrome is zero or floats as before.
- **Bookmarks bar** wears the material too with the page under, rather than
  an opaque band inside see-through chrome.
- **Tab previews** (switcher, hover cards, split picker) leave the covered
  strip out: `WKSnapshotConfiguration.rect` is the part of the page that
  shows. The picture a sleeping tab keeps stays whole, since it is laid over
  the whole web view as the `cover` when the tab wakes.
- **The switch is hidden** where WebKit can't be told (before macOS 26).
- **Checked here:** every changed file parses (tree-sitter's Swift grammar;
  `App.swift` has the same three grammar quirks it had before). Not
  type-checked or built: no Swift toolchain can be fetched in this session.

## To try on the Mac

1. The probe (above). Left inset honoured? Fill visible? Page width right?
2. `./build.sh release test`, fix anything that doesn't compile.
3. Settings › Tabs › Page under the sidebar on. YouTube in the sidebar
   layout, then the strip layout, with and without the bookmarks bar.
4. Hide and show the column (and fold it): content moves clear once the
   slide is over, and is uncovered at once going away.
5. Find (⌘F), a login field's accounts, hovering a link (bubble in the
   page's corner, not under the column), swipe back, a failed load.
6. Float a video, bring it back; picture-in-picture in and out; full screen.
7. The tab switcher's previews: no strip of fill on their left.
8. Waking a sleeping tab: its picture lines up with the page.
9. Google Sheets and a page wider than the window: nothing under the column.
10. `defaults write com.farchan.mnml.test under.behindWindow -bool YES`,
    compare, choose; then the key comes out.
