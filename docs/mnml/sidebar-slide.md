# The sidebar slide — what's in use, and the other one

How the page moves when the column of tabs shows or hides (⌘S, ⇧⌘S). Three
ways have been built; the user chose the per-frame slide (2026-09-27).

## In use: per-frame slide (`3f0e8ff`, branch `column-slide`)

The page's left padding is the column's width as it animates (`chrome.width` in
`ContentView.window_`, App.swift), so the page is resized on every frame of the
slide. The chat panel on the right works the same way (`browser.askRoom`).

- Smooth both ways, no jump.
- Hiding the column shows a dark strip at the page's right edge for ~8 frames
  (mnml's ground, value 27 in dark mode): WebKit paints the new width late.
  Not fixed by: the stage layer's colour, a page-coloured strip under the page,
  a colour sampled from the page with JS, setting `underPageBackgroundColor`.
  Next ideas: log stage/web view frames per frame, or the picture slide below.
- Parts of some pages shake as they reflow. Accepted for now.
- With the page under the chrome (Under.swift) this doesn't apply: the page
  keeps the window's size and is told what's covered (`covered`, `roomed`).

## Before it: resized once (main before `3f0e8ff`)

`make(room:after:)` alone: chrome going away gives the page its room at once;
chrome arriving slides over the page at its old size, resized once after
0.42 s. No shaking, no gap, but sites re-centre in one jump. Still the code for
the strip's height and for the page under the chrome.

## Tried: a picture over the page (`d249ef0`, ChatGPT, on `command-bar`)

`make(room:)` resized once at the start and put a bitmap of the page
(`cacheDisplay`) over it, stretched from the old width to the new one with the
column's spring, faded out after 0.2 s once WebKit caught up. Details and the
first checkpoint: `sidebar-slide-handoff.md`, `sidebar-transition-checkpoint-1.patch`.
It ran in the everyday mnml built 2026-09-27 18:56.

To switch back to it: take `make(room:after:)`, `resize(to:ticket:transaction:)`,
the three `slideCover` states and the cover `Image` in `window_` from `d249ef0`
(or `git show 6390051:Sources/mnml/App.swift`), and set the stage's leading
padding back to `beside.width` with `.offset(x: under ? 0 : chrome.width - roomed.width, …)`.
