# Handoff: the page bleeding into the sidebar (2026-09-26)

For whoever picks this up next (Codex or Claude). Read
`docs/mnml/page-under-chrome.md` first: it has the goal, what the user wants
it to look like, and the code map. This note is what was learned on the Mac
after that plan was written, and where to look next.

## The ask, in one line

In mnml (a macOS browser, AppKit + SwiftUI + WKWebView), the page's colours
should show **live** through the see-through sidebar column and top bar, like
Safari 26 or YouTube's ambient mode, **without hiding any page content** under
them, and **keeping the native Mac material** (`NSVisualEffectView`) on top.
The bar's text follows the app's own Light/Dark setting, never the page.

Already rejected by the user: tinting the bar in the page's theme-color
(flipped light/dark), and a sampled snapshot glow (not live, read as a smear).

## Where things are

- Worktree `../search-browser-under`, branch `page-under-chrome`, tracking
  `origin/claude/safari-style-window-sidebar-feto94` (written in a cloud
  session without a Mac). `main` is untouched.
- The branch **compiles** (`swift build`, no errors), but has **not** been
  built into the test app or tried by the user.
- Uncommitted in the worktree: probe fixes (launch crash, scriptable
  arguments, WebKit readout) and `docs/mnml/scratch/shot.sh`.
- Machine: macOS 27.2.

## Probe

`docs/mnml/scratch/InsetProbe.swift`: a bare window, a full-size WKWebView,
a 220 pt `.sidebar` material column on the left and a 52 pt bar on top, both
over the page.

```sh
swiftc -parse-as-library docs/mnml/scratch/InsetProbe.swift -o docs/mnml/scratch/probe
docs/mnml/scratch/shot.sh yt 0          # YouTube -> yt.png, yt.log
docs/mnml/scratch/shot.sh apple 2 scroll
```

Arguments: site index (0 YouTube, 1 Sheets, 2 apple.com, 3 a red→blue
gradient test page), then any of `nofill`, `behind` (`.behindWindow`
blending), `noleft` (no left inset), `scroll` (`scrollTo(0,500)` after load).
Six seconds after load it prints the page's viewport, then a readout of
WebKit's fill state and the web view's subview tree (with layer colours).
Screenshots: `screencapture -l <windowID>` on the largest `probe` window
(`shot.sh` does it). The checkboxes in the window don't reflect the
arguments; clicking them works if you have a way to click.

## Findings

1. **All the calls exist**: `setObscuredContentInsets:`,
   `_setUsesAutomaticContentInsetBackgroundFill:`,
   `_setAutomaticallyAdjustsContentInsets:`, `_setTopContentInset:`. The
   WebKit feature `ContentInsetBackgroundFillEnabled` is on by default.
2. **The insets hold for layout.** With L220/T52 the page reports
   `innerWidth` 1060 and `innerHeight` 768 (window 1280×820) and lays out right
   of the column and below the bar. Nothing scrolls under the bar either.
3. **`.withinWindow` material does blur the web view.** With `noleft`,
   YouTube's thumbnails show blurred through the column: that is the look the
   user wants, but only because the content is really under the column.
4. **WebKit's fill is solid colour, not the page.** It adds
   `WKColorExtensionView`s as subviews of the WKWebView over the covered
   strips:
   - left strip (0,0,220,820): `#1e1e1e` (system dark window background) on
     every site tried. It only takes a page colour from fixed-position content
     touching that edge (`_sampledLeftFixedPositionContentColor`, nil
     everywhere tried).
   - top strip (220,0,1060,52): the sampled page-top colour (white on
     apple.com, `#0f0f0f` on YouTube). Solid, changes only when that colour
     does.
   So the insets + fill give "today's layout with a coloured strip", never a
   live bleed.
5. **WebKit also has macOS 26 scroll pockets.** On apple.com the web view
   carries an `NSScrollPocket` (0,0,1280,52) with `PocketBlur` → `PortalView`
   and `LuminanceAdjustment` → `PortalView`, and a `BackdropView` in its
   `WKFlippedView`. A portal shows another layer's content live. This is
   probably how Safari does its top edge.

Related WKWebView selectors present (from `class_copyMethodList`):
`_topScrollPocket`, `_copyTopScrollPocket`, `registerPocketContainer:onEdge:`,
`unregisterPocketContainer:onEdge:`, `_updateHiddenScrollPocketEdges`,
`_setPrefersSolidColorHardScrollPocket:`, `_addReasonToHideTopScrollPocket:`,
`_fixedContainerEdges`, `_containerForFixedColorExtension`,
`_obscuredInsetsForFixedColorExtension`, `_hasVisibleColorExtensionView:`,
`_setShouldSuppressTopColorExtensionView:`,
`_setObscuredContentInsets:immediate:`, `_sampledPageTopColor`,
`_sampled{Top,Left,Right,Bottom}FixedPositionContentColor`,
`scrollViewDrawsMagicPocket`.

## Leads not yet tried

- **A left scroll pocket.** `registerPocketContainer:onEdge:` suggests
  pockets can be asked for on other edges. If WebKit (or AppKit's
  `NSScrollPocket`) can put a live pocket on the left inset, that may be
  exactly the bleed. Find what calls it and with what container.
- **A portal of the page's edge.** The pocket uses a `PortalView` to show
  live content elsewhere. If a portal (private `_NSPortalView` / `CAPortalLayer`
  or similar) of the page's leftmost few dozen points can sit under the
  column, stretched and blurred, that is a live bleed with nothing hidden.
- **A second `CALayerHost` of the web content.** WKWebView shows the web
  process's layers through a `CALayerHost` with a context id. A second host
  with the same id would be a live copy of the page to scale and blur under
  the column. Check whether that's allowed on current macOS and what it costs.
- **What Safari 26 actually does.** Inspect Safari's view hierarchy (e.g.
  Accessibility Inspector, or `lldb` attached to Safari if SIP allows) with
  the sidebar open on YouTube: is the page under the sidebar, what views sit
  between them, is there a pocket on the left? The user's description is
  from Safari 26; confirm the left side even bleeds there.

## Rules for this work

- Page content must never be hidden under the chrome. The native material
  stays; the bleed is seen through it.
- The effect has to be live (scrolling, video), every frame.
- Try things in the probe first. Anything for the real app goes on this
  branch, built into the test copy with `./build.sh release test`
  ("mnml Test"); the user judges by feel. Nothing goes to `main` until they
  have tried it, and commit only when they say.
- Private WebKit/AppKit calls are fine (mnml isn't on the App Store) but ask
  for them by name with `responds(to:)` so any SDK builds, as `Under.swift`
  does.
- Match the code's voice: comments say *why*, in plain sentences.
- In this shell `log` is a zsh builtin; use `/usr/bin/log`.
