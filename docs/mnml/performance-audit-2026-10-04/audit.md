# Performance and resource audit — 4 October 2026

## Scope and environment

The audit covers app-side Swift/SwiftUI/AppKit work, WebKit lifecycle and injected JavaScript, extensions/native ports, downloads, storage, history/search, bookmarks and imports, previews, media, startup, and background work. Changes are isolated in `codex/performance-audit-2026-10-04`, based on `91c0897fcbd8d576ec4d3bd73de0ee348f29e0ef`. No dependencies were added.

Static review and regression fixtures establish the changes below. Only address suggestions have a before/after timing measurement. This audit does not establish whole-app CPU, battery, memory, startup-time, or frame-rate improvements; WebKit's page processes and arbitrary sites need longer representative profiling for those claims.

All tests use explicit `MNML_PROBE` worlds. The packaged app is built in this worktree; the installed browser, its profile, and the main checkout are not used for testing. Runtime measurements use `MNML_MEASURE=1`, which preserves production throttling and App Nap.

## Applied changes

| Area | Finding and change | Evidence |
| --- | --- | --- |
| Address suggestions | Each keystroke formatted and matched all tabs, allocated filtered arrays, and sorted all matches. Keep only the newest three or six candidates, skip candidates that cannot displace them, and format an address only when its title does not match. Preserve recency, ties, fuzzy matching, and background-tab laziness. | Reference-ranking test covers case/Unicode/substring/fuzzy queries and tied timestamps; 1,000-tab release measurement below. |
| Tab groups | Both tab layouts repeatedly scanned all tabs for every group's members and linearly searched groups. Share an indexed pass for membership and preserve row order; index group visibility counts too. | 500-tab, 80-group reference comparison, including pins and unknown group IDs. |
| WebKit layout | Stage updates reassigned an unchanged page frame, requesting unnecessary WebKit layout. Skip equal frames while preserving inspector-docking behavior. | Stage frame-assignment and existing stage/inspector tests. |
| Window lifetime | NSEvent monitors and traffic-light controller registries retained callbacks after a window retired. Remove monitors, hooks, notification observers, and retained controllers on retirement; make the unused-key callback's browser reference weak. | Window callback/subscription release tests and content-view tests. |
| Tab wake/recovery | Stage retries and delayed load verification could survive navigation, Stop, sleep, or close, load an old URL, or rebuild a discarded page. Bind retries and replies to a load generation and view identity; Stop accesses only an existing view. | Close/rest/Stop/new-navigation cancellation tests with real WebKit views. |
| Automatic sleep | Repeated sleep sweeps could overlap form checks and snapshots for one tab, and a callback could apply to a replaced view. Coalesce requests, verify view/address identity at both continuations, and cancel requests on browser retirement. Use a set for idle membership. | Overlapping request and discarded-view regression test. |
| Find on Page | Next/Previous cleared and rebuilt every match highlight. Keep all-match ranges and update the current highlight; rebuild when the DOM/match set changes or highlight registrations/styles have been replaced. | Standalone real WebKit harness: 70 checks, including clear-call counters proving Next leaves all-match highlights intact and DOM edits rebuild them. |
| Extension tab events | Reconciliation repeatedly performed array membership and position searches. Use ID sets and a position map for tab additions, removals, and moves. | Existing extension integration tests and source review. |
| Extension teardown | Unload left error-observer tokens and side-panel pages behind; orphaned native WebSocket ports could retain receive tasks, delegates, and handlers. Remove observers, close affected panels, and cancel/clear socket resources idempotently. | Existing native/extension lifecycle tests; source ownership review. Live third-party service-worker/socket behavior needs a longer extension-specific soak. |
| Extension popups | Size polling could enqueue overlapping JavaScript calls and apply old results to a replacement popup. Allow one request at a time, weakly capture the view/popover, and invalidate the token and delegates on close. | Existing popup/window tests and source review. |
| Content blocking | Controllers awaiting compilation were strongly retained; concurrent compile requests could duplicate work. Keep weak waiting controllers and one compilation in flight. | Weak-controller release regression test. |
| Floating video | Hidden controls still queried the page; slow replies could accumulate and retain/update a retired floater. Query only visible controls, allow one request at a time, invalidate late replies, preserve displayed values after failed reads, and suppress equal redraws. | In-flight/hidden-control regression and existing floating-video tests. |
| Autoscroll | A stationary pointer maintained a requestAnimationFrame loop; scrolling speed depended on display refresh rate. Start frames only outside the dead zone and scale movement by elapsed time with a delay cap. | JavaScriptCore fixture checks stationary/stop behavior and 60/120 Hz equivalence. |
| Download progress | Every byte-progress KVO event queued another full aggregate scan and metadata read. Coalesce pending refreshes and read current progress once on the main queue. | Burst coalescing test and seven isolated real WebKit download lifecycle tests. |
| Queued storage | Superseded snapshots still paid their full JSON encoding cost before being rejected. Check currency before encoding and again before writing; preserve write ordering and quit durability. | Stale-encoding suppression and racing immediate-write tests. |
| History | Recent pages sorted/formatted the whole store to show eight results; unchanged imports republished it. Select only the latest eight using cached page text and skip identical imported values. A debounced last visit could be lost on immediate quit; explicitly flush it before draining the disk queue. | 3,000-entry reference comparison, invalid URL/removal checks, publication counts, latest-title flush test, and standalone URL-identity regressions. |
| Bookmarks | Every visible row rebuilt the folder list and recursively tested candidate subtrees. Share the list per outline pass and use subtree ID sets for folders. Menu reconstruction retained obsolete child snapshots. Release obsolete menu mappings. | Move-target reference test and existing import/bookmark behavior checks. |
| Bookmark HTML import | Identical regular expressions were compiled for each bookmark. Reuse immutable patterns across imports. | Mixed-case, markup, attribute, and entity parser regression. |
| Icons/import handles | Per-host ephemeral favicon sessions were not invalidated after their work. Failed SQLite opens can return an allocated handle that was not closed. Invalidate sessions and close failed-open handles. | Source resource-lifetime review and existing icon/import tests. |
| Automated quit | Scripted isolated probes could stop at the Quit confirmation. Allow them to terminate unattended, while the installed browser and daily-use Test app retain confirmation. | Packaged-app smoke check, recorded in `validation.json`. |

## Measured result

Release-mode fixture: 1,000 lazy tabs, 500 changes to the typed query, cycling empty/title/address/no-match queries. The same machine and fixture were used before and after the open-page suggestion change. The original search implementation was measured before replacement; the behavior test was corrected afterwards to exempt the legitimately warm active tab, without changing the timed fixture.

| Statistic | Original implementation | Updated implementation |
| --- | ---: | ---: |
| Median | 4.213 ms | 0.862 ms |
| 95th percentile | 5.386 ms | 5.779 ms |

Median time fell about 79.5% (4.9× faster). A final confirmation run measured 0.860 ms median and 5.617 ms at the 95th percentile. The 95th percentile did not improve. Queries with no matching title or address still require scanning the full tab collection; this result supports the common-case optimization, not a claim about every query or overall app responsiveness.

## Validation and reproduction

The release XCTest suite is run in two isolated processes by `Tests/run-performance-tests.sh`: 154 general tests (153 passed, one opt-in measurement skipped), then seven download lifecycle tests (all passed). The measurement test passed separately with `MNML_PERFORMANCE_MEASURE=1`. The standalone find harness passed 70/70 checks, extension-file checks passed 5/5, and history URL-identity regressions passed.

An early broad run and the final combined test process encountered download progress timeouts. The cause of the cross-suite failures was not established. An untouched source archive at the base commit passed all seven download tests when run alone, as did the updated release build. Process isolation preserves coverage and avoids this AppKit/WebKit cross-suite interaction; it is not proof that the original combined test suite is stable. The new highlight instrumentation also required the standalone NSApplication event loop, and reads CSS highlight state in the app's isolated script world.

```sh
# Each runner exits without interacting with the daily-use browser.
Tests/run-performance-tests.sh -c release --disable-sandbox
Tests/run-page-find-tests.sh
sh Tests/run-extension-files-tests.sh
sh Tests/HistoryRegression/run.sh

MNML_PROBE=performance-search MNML_PERFORMANCE_MEASURE=1 \
  swift test -c release --filter BrowserSearchPerformanceTests

# Package without installing or opening the daily-use app.
MNML_SIGN_IDENTITY=- ./build.sh release app
```

For this audit, SwiftPM scratch/cache/config/security paths were redirected to `.build-audit` and temporary module caches. Packaging ran the normal `build.sh release app` steps against that same release build with a temporary Swift command wrapper. See `validation.json` for the final artifact and unattended runtime result.

## Remaining measurement targets

- `Chat.history()` in `Ask.swift` reads and decodes every saved chat on the main actor when the history UI opens. `Chat.load()` also decodes synchronously. A metadata index or asynchronous loading is warranted if large saved-chat collections produce a measured pause; it needs UI loading/error behavior and persistence design beyond these changes.
- Startup still synchronously reads session, windows, history, bookmarks, and other profile metadata. Preserving first-frame/session correctness matters here; measure representative large profiles before moving their initialization across actors.
- History caps the saved file at 2,000 visits, but the in-memory visit dictionary can grow during a long process lifetime. An in-memory retention policy changes available history/search behavior and should be designed explicitly, then measured in a multi-day workload.
- Bookmark rows still each expose their destination menus. Sharing the folder list removes repeated tree traversal; a very large folder collection can still produce many destination items. Lazy menu creation would need a separate behavior/layout change.
- AppKit/SwiftUI still observes broad browser state. Body invalidation and the opt-in page-under-chrome rendering path need Instruments traces on representative scrolling/video sites before introducing observation or compositor changes.
- Per-tab memory checks can query a shared WebKit process more than once, and tab-switcher candidates still use some linear lookups. These are bounded or periodic paths; measure them against the larger page-process costs before adding persistent indices.
- No long-duration third-party extension, video, multi-window, or real-site battery/memory soak was performed. Lower allocation/work counts and ownership tests do not quantify RSS or energy savings.

Build artifacts and local logs are not source-controlled. The validation above records the original audit before integration with main.

## Integration review — 4 October 2026

Reviewed audit commit `aa30162` against main `529154c`, including the newer Antigravity chat and connection features. No merge-blocking defect was found in the lifecycle, data, or UI changes. The `Browser.closeAll()` conflict was resolved by retaining both chat cancellation and window monitor, light-controller, and pending-sleep cleanup.

The combined release suite discovered 274 general tests: 270 passed, four opt-in checks were skipped, and none failed. All seven download lifecycle tests passed in a separate process. The real WebKit Find on Page harness passed 70/70 checks, extension-file checks passed 5/5, and history URL-identity regressions passed.

The combined code was packaged locally as 1.0.4 build `202610041741`; strict signature verification and plist validation passed. A hidden named-profile runtime check loaded and evaluated six local pages, closed their tabs, created and retired five windows, and completed native quit without a modal or foreground activation. The daily-use app was not replaced during this review. These checks establish integration behavior; the whole-app resource and real-site profiling limitations above still apply.
