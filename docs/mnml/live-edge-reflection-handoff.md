# Live page-edge reflection under mnml's sidebar

Status: experimental, uncommitted on the `page-under-chrome` worktree. Built and
installed only as `/Applications/mnml Test.app`; the main app was not replaced.
Read [the original handoff](page-under-handoff.md) and
[the page-under plan](page-under-chrome.md) for the earlier attempts and the
rest of the chrome layout.

## Checked later the same day: the reflection doesn't appear

Measured, not judged by eye, on macOS 27.2:

- The user's recording of mnml Test (`Screen Recording 2026-09-26 at
  10.14.04 AM.mov`, page under sidebar on, `tabs.under = 1` in
  `com.farchan.mnml.test.copy`, build includes `CAReplicatorLayer`): the
  column's average colour is `#232526` in every half-second frame for 8 s,
  while the page beside it goes from a bright thumbnail to dark comments.
- `ReplicaProbe` (the reflected version), sampled at x=100 pt (column) and
  x=330 pt (page) over four frames: the page alternates `#0000f5` /
  `#ea3323`, the column stays `#282a2b` (with `inset`) and `#282b2d`
  (without). With the sidebar material removed, the strip is `#1e1e1e`,
  WebKit's plain grey fill: the second instance draws nothing.

So a `CAReplicatorLayer` over a `WKWebView` doesn't copy the page: WebKit
draws it in another process and the web view only hosts that content (see
WebKit bug 231148 below). The tuning section doesn't apply until something
actually puts the page's pixels in the strip. Leads still open: a portal of
the page's edge (the `PortalView` inside WebKit's `NSScrollPocket`) and a
left pocket via `registerPocketContainer:onEdge:`; see
[page-under-handoff.md](page-under-handoff.md). To measure rather than
eyeball, sample a crop's average colour with
`ffmpeg -i shot.png -vf "crop=w:h:x:y,scale=1:1,format=rgb24" -f rawvideo - | xxd -p`.

## What it does

The visible webpage remains clear of the sidebar. WebKit's
`obscuredContentInsets` gives the page a left inset equal to the sidebar's
width. A `CAReplicatorLayer` then reflects the *adjacent visible edge* of the
same `WKWebView` into that covered strip. The existing native
`NSVisualEffectView` sidebar, in `.withinWindow` blending mode, blurs the
reflection. There is no second web view, snapshot timer, page theme tint, or
page content hidden behind the sidebar.

The layout and material were already on this branch:

- [App.swift](../../Sources/mnml/App.swift) lays the stage across the window
  when `browser.pageUnder` is on and passes its covered width to `Page`.
- [Under.swift](../../Sources/mnml/Under.swift) applies the WebKit inset and
  automatic background fill. The fill alone was solid gray on the left; it
  remains the fallback beneath the reflection.
- [Side.swift](../../Sources/mnml/Side.swift) keeps the native sidebar material
  and selects in-window blending; [Design.swift](../../Sources/mnml/Design.swift)
  defines the `Frosted` `NSVisualEffectView`.

The new part is [Stage.swift](../../Sources/mnml/Stage.swift): `StageView`
creates a `CAReplicatorLayer` as its backing layer. `reflectPageEdge()` uses
one instance normally and two only when the left covered inset is nonzero.
It recalculates the transform when the inset or stage size changes, so sidebar
resizing keeps the reflection aligned.

## Why the transform is `2 * L - W`

Let `L` be the covered left width and `W` the stage width. Core Animation
applies `instanceTransform` relative to the *center* of the replicator layer.
The horizontal reflection uses `a = -1` and translation `tx = 2L - W`, giving
the resulting mapping `x' = 2L - x`:

| Source pixel | Reflected position |
| --- | --- |
| `x = L` (page edge) | `x' = L` (sidebar boundary) |
| `x = 2L` | `x' = 0` (window edge) |
| `x > 2L` | `x' < 0` (offscreen) |

Only the page's first `L` points can appear in the sidebar. The reflected
instance does not paint over the visible page. A simple translation was tried
first and rejected because its second instance could overlap and distort the
visible page. A small Core Animation pixel test confirmed the reflected
mapping before the app change.

`instanceDelay` is left at its zero default; there is no deliberate lag.
Keep `instanceCount` at two, not a chain of repeated copies.

## Evidence and remaining verification

- [ReplicaProbe.swift](scratch/ReplicaProbe.swift) is the isolated AppKit /
  WebKit probe. The user confirmed that its first, translated version changed
  red/blue live with an animated webpage. The final *reflected* version and
  real video were **not** visually confirmed in this session.
- `swift build`, `./build.sh release test`, and `swift test` succeeded on
  2026-09-26. The suite ran 19 tests with 0 failures. The installed test app
  was launched and remained running. These checks do not prove the live video
  effect or its performance.
- Screen capture failed in this session (`screencapture` could not create an
  image and the capture service reported an audio/video failure), so the next
  person must inspect mnml Test directly. Do not treat the first probe's
  confirmation as confirmation of the final transform.
- The top bar still uses the branch's WebKit fill; this change reflects only
  the sidebar's left edge. Split view remains on its previous layout.

To reproduce the standalone probe from this worktree:

```sh
swiftc -parse-as-library docs/mnml/scratch/ReplicaProbe.swift -o /tmp/mnml-replica-probe
/tmp/mnml-replica-probe inset
```

The `inset` argument makes it use mnml's full-window web view and 220-point
WebKit inset. Without `inset`, it places the page physically beside the
sidebar. The scratch probe's 220-point width is illustrative; mnml uses the
actual `under.left` width.

## Tuning, in order

1. **Judge the real effect first.** In mnml Test, enable Settings > Tabs >
   Mac window material and Page under sidebar. On YouTube, scroll between a
   bright playing video and dark comments. Check that the sidebar edge changes
   promptly, the page is not doubled or covered, and the text remains legible.
   Repeat while resizing the sidebar and window.
2. **Strength:** the current reflected instance is full alpha before the
   native material processes it. To weaken the bleed without dimming the real
   page, try `replica.instanceAlphaOffset` in `reflectPageEdge()`; for two
   instances, a negative offset makes only the second one less opaque.
   Start with a small adjustment and compare bright/dark video frames. This
   knob is documented by Core Animation but **has not been tried here**.
3. **Material:** keep `.withinWindow` for the sidebar to sample the page in
   this window. `.behindWindow` samples the desktop instead and is useful
   only as an A/B diagnostic (`under.behindWindow` in test settings). The
   existing `.sidebar` material in `Frosted` supplies the native blur and
   appearance; avoid adding a second glass or custom blur layer on top.
4. **Geometry:** do not adjust `2 * L - W` to change strength. It encodes the
   exact mirror boundary. `L` must match the WebKit covered inset and sidebar
   width; `W` must be recalculated after resizing. If a *narrower* influence
   band is needed, mask or fade the reflected instance under the sidebar
   separately, then check that the visible page stays untouched.
5. **Timing:** leave `instanceDelay` at zero. A snapshot loop or nonzero delay
   would reintroduce the lag the user rejected.

Before considering the main app, test scrolling and video playback, tab
switching, sidebar hide/fold and resize, bookmarks bar, fullscreen/PiP, a
wide page such as Sheets, light/dark appearance, reduced transparency, and
4K-video GPU/energy cost. If the reflected version fails any of these,
disable Page under sidebar in the test copy and keep the result on this
worktree. Do not commit or install into the main app without user approval.

## References

- [User's Safari recording](</Users/farchan/Library/Mobile Documents/com~apple~CloudDocs/Macbook Pro/Screenshot/Screen Recording 2026-09-26 at 1.26.37 AM.mov>)
  is the visual target: the response is subtle near the sidebar/page boundary
  as the video and comments move, not a full-width colour wash.
- [Apple: Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
  describes mirroring adjacent content under sidebars without placing content
  there. This is the visual model, **not** a claim that Safari uses this exact
  implementation.
- [Apple: `NSBackgroundExtensionView`](https://developer.apple.com/documentation/appkit/nsbackgroundextensionview)
  is the native background-extension API. An earlier probe extended a native
  view but did not extend live `WKWebView` content on this Mac, which motivated
  the layer experiment.
- [Apple: `CAReplicatorLayer`](https://developer.apple.com/documentation/quartzcore/careplicatorlayer),
  [`instanceTransform`](https://developer.apple.com/documentation/quartzcore/careplicatorlayer/instancetransform),
  and [`instanceAlphaOffset`](https://developer.apple.com/documentation/quartzcore/careplicatorlayer/instancealphaoffset)
  document the copy, center-relative transform, and optional strength knob.
- [Apple: `NSVisualEffectView` blending](https://developer.apple.com/documentation/appkit/nsvisualeffectview)
  distinguishes in-window from behind-window sampling.
- [WebKit bug 231148](https://bugs.webkit.org/show_bug.cgi?id=231148)
  records the difficulty of duplicating WebKit's remote layer tree, especially
  video. The present in-tree replicator probe is narrower than a second
  independent view; video still needs direct verification.
