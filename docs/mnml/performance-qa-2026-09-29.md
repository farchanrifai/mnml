# mnml Test performance QA — 29 September 2026

## Scope and verdict

Release 1.0.4, build 202609291019, macOS 27.2, 24 GiB MacBook Pro. Tested the installed mnml Test executable in an isolated `perf-sync8-qa` profile, with `MNML_MEASURE=1` preserving production WebKit inactive scheduling and App Nap behavior. Also read-only sampled the existing Test profile with extensions. Main source and installed main app were unchanged. No production code fixes were made during this audit.

**No runaway app-memory growth reproduced in the short tab-lifecycle test. A native extension-host retain cycle is confirmed. Playback is not cleared: synthetic video dropped frames, but foreground focus and screen-recording behavior could not be validated.** This is a short local QA run, not a multi-hour soak or complete all-site clearance.

## Memory

Six cycles opened, loaded, selected, and closed 12 local fixture tabs each (72 tabs total). Each document had roughly 1,500 rows and 75 sign-in inputs. The app physical footprint after each closure/settle was **48.8, 62.3, 48.7, 48.9, 48.2, 49.0 MB**. Baseline was 36.1 MB; peak during these cycles was 76.4 MB. Growth settled rather than continuing per cycle. Resident memory fluctuated with compression and is not the leak verdict.

With an active fixture, additional Spaces, and warmed Ask UI, physical footprint reached 68.4 MB. Later with video and sidebar churn it reached 123.8 MB (peak 170.0 MB); one separately measured video WebContent process used 175.7 MB. **After the second playback/layout pass, closing all three disposable fixture tabs and waiting eight seconds still left 151.9 MB physical footprint (peak 197.2 MB).** That is retained memory requiring a longer settle and allocation-generation check; this run cannot distinguish graphics/snapshot caches from additional leaks. It prevents giving the whole video/UI scenario a memory pass. The native picture captures themselves allocate image buffers and may contribute. These are separate process measurements, not the total browser coalition or a like-for-like baseline comparison. Process IDs returned zero for many initial lifecycle snapshots, so those WebContent totals are incomplete. No forced memory-pressure or aggressive-purge test was performed.

### Confirmed native extension-host cycle

`leaks` on the existing Test profile reported **353 leaked allocations / 45,040 bytes**. Four unreachable `HostPipe` roots account for about 10 KB; a SwiftUI ContextMenuResponder/AppKitMenuDelegate cycle accounts for about 34 KB. The byte count alone is far too small to establish a cause for severe lag.

In `Sources/mnml/ExtensionNative.swift`, `pipe.onMessage` captures the port (lines 89–90), while the port message/disconnect handlers capture the pipe (lines 96–122). `HostPipe.stop()` and `finish()` do not break all of those ownership links. The leak report explicitly identifies the pipe → port → handler → pipe cycle, after connections are no longer rooted in the live-host registry. Cleanup should release both directions on disconnect/exit, and then be validated with repeated extension worker reconnects. No extension reinstallation or credential prompts were triggered for this audit.

The isolated profile without installed extensions reported **38 allocations / 1,328 bytes**, mainly small graphics collection leaks and an 80-byte local event-observer pair. Framework menu/graphics findings need generation testing before attributing ownership or severity to mnml.

## Responsiveness

A 10 Hz test-socket request measured how quickly the app's main-thread handling answered while actual test controls changed UI. These are response proxies, **not input-to-display or animation-completion times**. The press helper's fixed 400 ms reply delay is not included in these response samples.

Final repeat, without heavy tracing:

| Scenario | Samples | p95 response | Maximum |
| --- | ---: | ---: | ---: |
| Idle video | 96 | 0.74 ms | 1.46 ms |
| 20 Ask toggles during video | 73 | 21.74 ms | 92.12 ms |
| 30 tab-sidebar layout toggles during video | 39 | 52.53 ms | 94.78 ms |
| 40 Space switches | 264 | 23.67 ms | 74.35 ms |
| Final idle | 96 | 1.51 ms | 1.99 ms |

No response above 250 ms occurred in those five final interactive phases. Another warm pass reached 112 ms during Ask toggling. A first Ask pass had a 2.81-second outlier while Instruments was finalizing; it did not repeat, and cannot be attributed confidently to Ask. Initial page load plus capture had a 487 ms outlier; that phase includes measurement setup.

The tab-cycle response outliers around 0.7–1.3 seconds coincide with `vmmap` captures that suspend the target, so they are **not counted as app hangs**. Idle CPU samples predominantly showed the main thread waiting in the event loop, not a persistent busy loop. DOM mutation stress used 40 text changes every 16 ms; app responses in that phase topped out at 30 ms, though page-frame counters from that first run were invalid and discarded.

## Playback and recording

A local muted looping H.264 1280×720 60 fps fixture was decoded in WebKit, with explicit `getVideoPlaybackQuality()` counters. In the final repeat:

| Scenario | Reported frames | Dropped | Dropped fraction |
| --- | ---: | ---: | ---: |
| Idle video | 721 | 64 | 8.88% |
| Ask toggles | 480 | 40 | 8.33% |
| Sidebar toggles | 228 | 20 | 8.77% |

This is a failed playback indicator in this setup, not proof of a regression caused by the upstream sync or a particular animation. JavaScript frame intervals were also irregular. The window was present and `document.hidden` was false, but foreground/occlusion state could not be reliably verified. Other applications and unrelated WebContent processes were running; some used substantial CPU. No same-workload baseline build comparison was run.

Computer-use capture repeatedly failed with ScreenCaptureKit error **-3811**. Foreground confirmation was requested but had not arrived before measurements ended. Actual screen-recording load, YouTube playback, cross-Space PiP, and visually judged smoothness therefore remain pending; this audit does not claim those passed.

## Tooling and next checks

A 10-second Animation Hitches capture of the existing idle Test session took over a minute to finalize, using about 5 GiB resident memory and one CPU core. It was not used to judge interaction timing. Its exported hitch table had no rows, which clears neither animations nor playback. Raw trace, samples, leak reports, and rerunnable local test scripts are under `/tmp/mnml-perf-qa` (temporary; save elsewhere before cleanup if needed). Lightweight structured measurements are retained beside this report in `qa-2026-09-29/`.

Recommended next work:

1. Fix extension native-host disconnect ownership and test repeated reconnects with leak generation checks.
2. Reproduce playback in a confirmed foreground window, then compare the same local video with and without real screen recording. Measure app, WebContent, GPU, and WindowServer separately.
3. Record actual Ask/Space animations once macOS capture works; main-thread responses alone cannot establish visual smoothness.
4. Run a longer mixed-site soak (Google Sheets/Drive, YouTube, extensions), including normal tab sleep and recovery. Test scripts' bench tabs are exempt from automatic sleep.

Cleanup closed all disposable QA tabs and the isolated process exited. The harness's 15-second exit wait timed out before exit completed; final process-list verification showed it gone. The existing Test session remained running. QA report files remain uncommitted.

## Implemented follow-up — build 202609291118

### Native host fix

- Port/host message and disconnect callbacks now use weak references; the registry exit callback captures only the host identity.
- Stop/EOF/exit cleanup is idempotent, releases callbacks and buffers, fails pending/late reads, closes pipes on stop, and invalidates the worker heartbeat on exit.
- The child reaper survives a released one-shot caller until child exit, then clears its handler and cancels itself, so it can still reap the process.
- Register callbacks before spawning; failed launches clean up the registered connection too.

Three focused lifecycle checks passed: 20 repeated echo-host connections with callback delivery/deallocation, pending/late read cancellation, and natural exit. Full regression suite: **68 tests passed**. These exercise the host lifecycle with a local shell fixture; they do not validate real password-manager unlock or pairing.

A native `leaks` scan of the restarted installed Test profile, with its existing 1Password extension loaded, found **one 32-byte allocation and no HostPipe roots**, down from the earlier 353 allocations / 45,040 bytes. No extension was reinstalled and no credential entry was performed.

### Corrected measurement and disposition

The existing `windows front` test control can now actually activate a window **only in explicit MNML_MEASURE runs**. Probe output includes app-active, window-key, and occlusion visibility flags. Ordinary hidden probes retain their behavior.

A fresh measurement profile repeated four load/video/Ask/sidebar/close cycles **without screenshots**, preserving production WebKit scheduling and App Nap. Closed app footprints were **72.0, 72.7, 72.8, 73.1 MB**, settling at **72.9 MB** after another 30 seconds. The earlier 152 MB retention did not reproduce. No tab-memory policy or production cache purge was changed.

Only **cycles 2 and 3** maintained app-active, key-window and visible-window state through every measured phase; both reported **zero dropped frames** in idle, Ask toggling, and sidebar toggling. Cycles 1 and 4 lost foreground or paused/hidden playback and are excluded. This overturns any interpretation of the earlier ~9% figure as a confirmed production renderer bug. No rendering/frame-rate change was made without a reliable regression.

Across the repeated control requests, Ask response max was 60.94 ms and sidebar max 16.51 ms; no >250 ms responses occurred. These remain main-thread response proxies, not measured visual animation-completion times. The aggregate includes invalid-focus phases, so it cannot independently establish foreground animation smoothness.

Recording remains **unvalidated**: the window recording attempt returned exit 1 and zero output bytes while its page was hidden/paused. A follow-up full-display attempt was abandoned before capture because the foreground precondition failed. No recording-specific fix is claimed. Real YouTube/PiP switching and a mixed-site soak remain manual follow-up work.

Installed only mnml Test. Main build remains 202609281507. Source changes and reports remain uncommitted.
