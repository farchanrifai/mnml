# Upstream sync 11

Branch `upstream-sync-11`, from `main` (862556d). Upstream range `35aa051..caf91e5` (111 commits after 59c1b4e, which came over earlier). The user picked clean fixes first; features that are off by default are next.

Replayed by patch with paths mapped to `Sources/mnml` / `Tests/mnmlTests`. CHANGELOG/ROADMAP/NOTES/ideas and the Python e2e tests (`Tests/*.py`) were left alone. Each commit names its upstream hash. 48 picks.

Included:
- **Passwords and sign-in:** username-first sign-ins, password-only sign-ins, reading a password only once it's picked, no suggestions in search or title fields, Remove All…, selectable usernames, security keys without a user handle, async POST sign-ins (popup gesture), quiet launchWebAuthFlow, Affinity's panel sign-in, Claude in Chrome sign-in (the groups part left out).
- **Extensions:** AdBlock's background starts, update checks while open, popup width with scrollbars, Stylus and Vimium C.
- **Pages:** text replacements, 10./192.168. over https, the blocker matching whole domains, sandboxed-frame links, video files playing, local text files, typed local paths, local pages opening files in other folders, about:blank documents, cross-site tracking off keeping framed cookies, closed tabs stopping the camera and mic, paused video giving the media keys back, floating-video crop (9e0fa28), one click opening one tab.
- **Chrome:** bookmarks with no name, bookmarks never replacing a pin, a pin moved to another space staying there, the folded column scrolling to the current tab, non-Latin shortcuts, the sideways swipe following the Mac's setting, a swipe back closing a small window, WebStage sizing, a waking tab not pushing the column, a top-strip tab drag not moving the window, ⇧⌘W Close Window, the passkey entitlement check on first run.
- **Tests:** deterministic download fixtures (DownloadLifecycleTests pass here now), the file-access test skip.

Adapted:
- Bench: kept mnml's command list, adding only the commands each pick brings (`marks`, `textcheck`, `openmark`, `passwords`, `layouts`, `magnify`, `wheel`, `nowplaying`).
- Bookmarks views keep mnml's Button wrappers and accessibility, with upstream's unnamed rows.
- 6f40bd2 (non-Latin keys) is ported onto mnml's key routing: `shortcutCharacters`/`shortcutKey` in App.swift and KeyCombo.
- 564455d: `Swiping` takes the page's `under` insets; Page keeps the Reduce Motion animations.
- `Ask.sure` takes both mnml's `cancelled:` and upstream's `returnCancels:`.
- 0b769a3: popup gesture hooks merged into mnml's Tab; upstream's `Extensions.pages` re-install is left out (mnml has no shared extension-page controller), and so is its test.
- b02bec7: `openClicked` returns the tab, so Group links still groups.
- 5cc21d7: ⇧⌘W goes in mnml's command list (Settings › Shortcuts), not a hard-coded key.
- 7b4d8cf: `heard(on)` sits beside SystemPiP.prepare in the ears watch.
- 17c1acf: `loadGeneration` still counts only real pages.
- TabCaptureTests turns the mock camera/mic on itself, because upstream's `Web.configuration` hook (ExtensionCapture) isn't in mnml.
- Tests that set SEARCH_PROBE now set MNML_PROBE, including older ones (they had shared the "test" world).

Left out (didn't fit, or needed unported upstream work):
- fab5b9e: find bar in upstream's Split View.
- 21143e8: native host ending when its output closes. It's written around `Process`, and mnml launches hosts with posix_spawn for 1Password's tree check (10b3698). Worth porting by hand.
- ca55c12: import folder pick and bounded reads. Needs upstream's import rework (extension-only profiles, folder override).
- 27b15f6: extension worker restarts. Needs upstream's ExtensionCapture, native-port registry and panel pages.
- ed54f64: one-move exit from video full screen. It's built on cards, upstream's Split View and the side panel.
- f30e7a4, ff749f4, f830308: floating video reworks. They clash with mnml's system-PiP-first path.
- 281b5a7: small windows alone, closed windows freed, Dock names (13 conflicts with mnml's window and link handling).
- cab7355: pin sleep. mnml already sleeps pins after 2 h.
- 00375c7: extensions on private tabs. It's built on upstream extension groups, worker recovery and new-tab pages.
- d37af47: a fresh start keeping tab groups. That's upstream's groups in Session; never take upstream's `Session.Entry` decoding.
- fbc9c61, 3f4ca7d, f482254, b10d539: the page as a card. mnml has its own page frame.
- The tab groups half of 5f1038c.
- Features (next round): sleep policy, PDF export, copy links, Home page, pins going home or staying on their site, tabs closing themselves, dark pages, sites kept awake, 120 Hz, engine suggestions, Open With, reload from origin, the refused pop-up notice, pins in every space, ⌘T over the page, the switcher's keys and small windows, the extension side panel, and the sidebar/strip UI tweaks.

Validation: `swift build` and `swift build --build-tests` pass. `swift test` runs 331 tests (DownloadLifecycleTests included) with 0 failures and 5 skipped. No hands-on QA yet.
