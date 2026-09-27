# Handoff: upstream sync 7 (several windows and the rest of 1.0.4)

For whoever carries this out (ChatGPT/Codex). Written 2026-09-28 by Claude, after
sync 6 and a first attempt at this one, which was aborted so you start clean.

## Where things stand

- `main` = `95b62a6`, pushed to `origin` (farchanrifai/mnml). The everyday
  `/Applications/mnml.app` is built from it.
- `upstream` = driceroland/Search, `upstream/main` = `29278d4`, 52 commits ahead of
  what mnml has. Sync 6 took everything up to `96a966c^`; this sync starts at
  `96a966c` "Several windows (1)".
- Trial merge: ~70 conflict hunks in ~30 files, plus four upstream edits to files
  mnml rewrote (git reports modify/delete), which must be ported by hand.

## Do it in a worktree, not on main

```sh
git fetch upstream
git worktree add -b upstream-sync-7 ../search-browser-sync7 main
cd ../search-browser-sync7
git merge --no-ff --no-commit upstream/main
```

Resolve, build, test there. Main is touched only after the user has used the
result in mnml Test and said so:

```sh
./build.sh release test          # installs "mnml Test" beside the real one; data kept apart
# user tests …
cd ../search-browser && git merge --ff-only upstream-sync-7 && git push origin main
./build.sh release install       # the everyday app — only when the user says
git worktree remove ../search-browser-sync7 && git branch -d upstream-sync-7
```

Commit the merge on the branch once it builds; small follow-up fix commits on the
branch are fine. Never force-push main. Commit messages end with a
`Co-Authored-By:` line naming you.

## Upstream merge rules (the user's, for every sync)

Who wins:

1. **mnml's look and features win.** Where a conflict touches a feature,
   especially anything UI, keep mnml's version.
2. **Upstream wins only where its code is genuinely cleaner** for the same
   behaviour — same result, better code. Not "different behaviour, arguably better".
3. **Bug fixes are decided on merit.** Where both sides fixed the same thing,
   compare the two, keep the better, and say which and why in the merge summary.
4. **Fixes mnml applied early from upstream PRs** (e.g. #287, #269, #271, #264,
   #290, #278, #296, #293, #285): if upstream merged a different version, take
   upstream's.
5. **Features upstream added that mnml doesn't have:** take them, unless listed
   below as skipped. Upstream ships new features off by default behind a switch;
   in mnml new behaviour is simply on unless the user asked otherwise — but for a
   switch upstream adds, keeping upstream's default is fine; don't invent new
   defaults silently, list them.
6. **Features that touch keys** are mirrored into mnml's own `Command.all`
   (Shortcuts.swift), never routed around it. Upstream's "page gets its
   shortcuts first" (`pageFirst`, Refs #147) is left out at every sync; keep its
   `ContentView.keyHook` only if the bench needs it.

How to merge:

- Merge `upstream/main` (a real merge, not cherry-picks), on a branch
  `upstream-sync-N` (here in a worktree), fast-forwarded into `main` only after the
  user has tried it in mnml Test and said so.
- **CHANGELOG.md and ROADMAP.md stay as upstream's**: take both sides of their
  conflicts, don't rebrand them. mnml's own list is `MNML-ROADMAP.md` (local).
- **Rebrand new code**: user-facing "Search" → "mnml", `SEARCH_*` env → `MNML_*`,
  `com.officecommun.search…` → `com.farchan.mnml…`. Keep upstream's internal
  identifiers where renaming would only cause conflicts next time (e.g. the
  `officeX` message handler names, `__search…` shim globals).
- The repo's sources live in `Sources/mnml/`; upstream's are `Sources/Search/`.
  A new upstream file lands in `Sources/Search/` → move it to `Sources/mnml/`.
  A modify/delete conflict on `Sources/Search/X.swift` means mnml rewrote X:
  port upstream's diff by hand, then `git rm` the `Sources/Search/` copy.
- **After resolving, diff every conflicted file against pre-merge `main`**, not
  just the conflict hunks. Auto-merged regions have silently dropped mnml code
  before (sync 3: SideRow padding; sync 6: the session reader).
- **Summarise every conflict** with the choice made and why, in the merge commit
  and to the user.
- **Upstream's `Carried` drag modifier** exists but mnml's column and strip use
  their own group-aware drags (Side.swift, TabBar.swift); restore anything upstream
  deletes that those drags still use.
- **Updater**: mnml's `Updater.feed` is optional (nil unless `MNML_FEED`); any
  upstream code assuming a non-optional feed needs `guard let feed`. Upstream's
  signed-feed check is keyed to Office Commun's certificate — mnml keeps its own
  plain fetch until the user has an appcast.
- `Metrics.helm` must match the Helm HStack spacing.
- Upstream's bench `press CODE CHARS MODS` is the one kept.
- Don't sync unprompted; the user asks when upstream has something worth it.

How to hand back:

- Build into **mnml Test** (`./build.sh release test`), not the everyday app; the
  user works in `/Applications/mnml.app`. Install the everyday app only when told.
- Commit only when the user says it works; push when they say so.
- Say plainly what couldn't be verified (gestures, full screen, hover, sign-ins)
  instead of claiming it works; the user tests every build by feel.

## Things mnml has its own way — do not take upstream's

- **Tab groups.** mnml has Dia-style groups (`Groups.swift`, `GroupViews.swift`,
  `TabGroup` with `colour`, `open`, `peek`, `pinned`; `Browser.groups`,
  `tab.group`). Upstream's groups (`usesTabGroups`, `tabGroups`, `groupID`,
  `editingGroupID`, `TabGroup.collapsed`, `TabGroup.number`, `GroupHeading`,
  `arrangeGroupedTabs`, `visibleTabs(in:)`, extension `chrome.tabGroups` support)
  were dropped in sync 6. Drop them again wherever they come back — including Arc
  import's "folders come over as tab groups" (skip that part of `ImportArc`).
  Extensions see every tab in group -1 (`tabs.groups` → -1, `tabGroups.query` → []).
- **Session entries.** NEVER take upstream's hand-written
  `extension Session.Entry { init(from decoder:) }`. It reads only upstream's keys
  and silently drops mnml's `group`, `split`, `chat`, `asking` — tab groups, splits
  and chats vanish on the next launch. Keep the synthesised decoder. Keep upstream's
  lenient `Session.Shape` decoder. Add upstream's new `pinID: UUID?` field to
  `Session.Entry` (pins shared across windows need it); do not add `groupID`.
- **Session writing.** mnml's `Browser.session(_:active:groups:)` builds entries
  with split/chat/asking/group. Several windows adds `windows.json` and per-window
  saving (`Browsers.save`, `record(of:rows:)`): every path that writes a row must go
  through mnml's entry builder, or chats/splits/groups are lost for extra windows.
- **Keys.** mnml routes keys through its own `Command` list (`Shortcuts.swift`,
  `browser.shortcuts`, per-command website-first/prompt conflict setting). Upstream's
  `pageFirst`, `ShortcutStore.shared`, `.shortcut("id")` menu modifiers, extension
  shortcuts inside ShortcutStore (`adopt`, `keepsFromExtensions`) are not used.
  New upstream key commands are added to mnml's `Command.all` instead (as done for
  `view.reloadOrigin` ⌥⌘R and `history.clearData` ⇧⌘⌫), and menus use `item("id")`.
  ⌘N / New Window for several windows → add `file.newWindow` to `Command.all`.
  mnml's own keys always beat an extension's (`App.take`), and extension command
  keys are edited in Settings › Shortcuts › Extensions (`ExtensionKeys`).
- **⌃Tab switcher.** mnml's `TabSwitcher.swift` and its routing in `ContentView`
  (`watchKeys`) stay; upstream's "switcher always on" and `switchTabs(backwards:)`
  / `tabSwitcher.step(row:…)` are not taken. mnml's pref `mruSwitcher` stays.
- **History swipe.** mnml has its own (hold a back/forward swipe to pick a page,
  `PageView.hold`). Upstream merged its version of #191 (`PageView.openList`). Keep
  mnml's; don't end up with two.
- **New tabs at the top**, **pin home** (`PinnedHome.swift`, `goHome`, `editLetter`),
  **sidebar on the left only** (upstream `sidePosition` pref may exist but has no UI
  and must stay `.left`), **no `navigationLeft`**, **no Check for Updates menu**
  (mnml's updater is off: `Updater.feed` is nil unless `MNML_FEED`).
- **Window id** is `Window("mnml", id: Store.world.map { "search (\($0))" } ?? "search")`
  (upstream #202). With several windows upstream uses `Browsers.sceneID`; keep that
  value.

## mnml features that several windows must keep working

All of these live on `Browser` (per window) and must stay per window:

- The AI chat: `chats`, `chatting`, `askTyping`, `askFocused`, `askFocusTick`,
  `askRoom`, `askMode(for:)`, `toggleAsk`, `newChatTab`, `askInNewTab` (`Ask.swift`,
  `AskPanel.swift`). ⌘E / ⇧⌘E act on the window in front.
- Extension side panels docked on the right: `docked` + `SidePanels` (`SidePanel.swift`).
  `SidePanels.webViewDidClose` and `ExtensionShims.openPanel` use
  `Extensions.shared.browser` / `owner.browser` — with several windows, resolve
  the window that owns the tab (`Browsers.all.first { $0.docked[tab] != nil }`,
  or upstream's `owner.browser(of:)`), and open a panel in the window in front.
- Splits (`Split.swift`), groups, command bar (`opening`), notifications (`Notify.swift`),
  page under the chrome (`Under.swift`, `pageUnder`, `covered`, `sliding`), the
  per-frame sidebar slide (`docs/mnml/sidebar-slide.md`), the floating chat card.
- Single-window statics used by mnml code: `Browser.front` (now `Browsers.front`),
  `Links.window` (a window, now one of several), `Extensions.shared.browser`.
  Replace each use with the window-aware upstream equivalent.
- The website→extension bridge in `ExtensionShims` (`external`,
  `search-external.js`, `__searchExternal`, the carrier before `if (inContent) return;`)
  — Claude for Chrome signs in through it. Keep it exactly where it is.
- `Links.applicationWillTerminate` pauses media and clears now-playing (Droppy
  relaunch workaround) — keep it, over every window: `Browsers.all`.

## Decisions already made in the aborted attempt (reuse them)

- **New upstream files**: take them (`AddressCommands`, `ImportArc`, `ImportRecord`,
  `Keyword`, `Pins`, `Scripting`, `WhatsNew`, `Windows`), then strip group bits.
- **Four rewritten files** git calls modify/delete (`Sources/Search/Find.swift`,
  `Shortcuts.swift`, `ShortcutsPage.swift`, `Side.swift`): `git rm` the
  `Sources/Search/` copy, then port `git diff 96a966c^ upstream/main -- Sources/Search/<file>`
  into mnml's `Sources/mnml/<file>` by hand — only what fits mnml (e.g. Side's
  windows-aware bits; no right-side column, no upstream groups).
- `CHANGELOG.md`, `bench`: both sides. `Bench.swift` verb list: union of both.
- `ExtensionShims.swift`: mnml's (no groups).
- `History.swift` `Suggestion.id`: both —
  `kind.isCommand ? "command " + key : (tab?.uuidString ?? key)`, plus upstream's
  `static func command(_:)`.
- `Links.swift` terminate: mnml's media pause over `Browsers.all` + upstream's
  `Browsers.flush()` (replaces `Links.flush?()`).
- `Peek.swift` help text: mnml's (⌘O). `Swipe.swift`: mnml's.
- `Spaces.swift` switch: upstream's `Browsers.front` / `usesFiles` lines, without
  `tabGroups = …`.
- `SiteCard.swift`: git misaligns it. Take mnml's file, then add upstream's
  `sound` row after `zoom` and its `Sound` view (`Autoplay.allowed/set`), and
  upstream's `(browser.window ?? Links.window)` field lookup.
- `Float.swift` (includes the user's own PR #229, docking): take upstream's for
  #1–#3 (`stopGlide`, `benchScreens`/`dockable`, `Float.docked`); #4 both lines
  (mnml's scroll save + upstream's landing reset); #5 combine mnml's scroll
  restore with upstream's frame-by-frame landing (restore the scroll inside `put()`).
- `Prefs.swift`: mnml's block plus upstream's `lazyTabs` (one `showsReading`,
  one `mruSwitcher` — check for duplicates the auto-merge leaves).
- `Session.swift`: mnml's fields + `pinID`; mnml's comment, no Entry decoder.
- `Settings.swift`: mnml's rows (new tabs top/bottom, command bar, tint, material,
  page under, sleep text). Add upstream's new rows only for features kept
  (lazy tabs, site shortcuts/keywords, address commands, What's new, downloads
  button); no tab groups row, no sidebar position.
- `Stage.swift`: upstream's comment in #1; mnml's `.padding(under)` in #2.
- Still open when aborted: `App.swift` (11), `Browser.swift` (22), `Tab.swift` (6),
  `TabBar.swift` (3). Expect several windows' scene/window code in App and
  per-window state moved out of Browser; keep mnml's key routing, menus
  (`item("id")`), panels, slides and layout.

## Upstream features in this range (take unless noted)

Several windows (⌘N, Move to Window, drag a tab out, windows.json, pins same in
every window, extensions see every window, private windows refused to
extensions) · ⌘F focuses find (#172) · extensions with "tabs" see every tab ·
Dock icon dark/tinted (#337) · site keywords (`yt cats`, #188) · lazy background
tabs (#196) · Put to Sleep in the tab menu (#310) · blocked ads leave no gaps
(#159) · ⌘Return keeps a peek (#326) · Dock brings a window back (#367) ·
bookmarks: folders known, placement, drag above/below/into, ⇧⌘B card, search
(#370) · local pages survive wake/reload (#366) · AppleScript read tabs (#232) ·
pins fill rows evenly (#240) · address bar commands (#212) · ⌘Return in the field
opens a new tab (#311) · window movable between presses (#286) · full-screen
buttons are macOS's (#241 — check against mnml's own full-screen lights, keep
mnml's if they differ) · floating video size and docking (#257, #229) · Bring
Things Over in File and Settings, Arc import (no groups) · What's new card ·
downloads button can stay · Play Sound by Itself · full-screen video doesn't
float on app switch (#372) · unpin redraw fix. Skip: "⌃Tab switcher always on",
"no New tabs at the top", groups from Arc.

## Checks before handing back

1. `swift build -c release` clean; `swift test` passes (25+ tests).
2. The extension shim's JavaScript parses:
   ```sh
   python3 - <<'EOF'
   import re,subprocess
   s=open('Sources/mnml/ExtensionShims.swift').read()
   for n in ['script','external']:
       js=re.search(r'nonisolated static let '+n+r' = #"""\n(.*?)\n\s*"""#', s, re.S).group(1)
       open('/tmp/'+n+'.js','w').write(js)
       print(n, subprocess.run(['node','--check','/tmp/'+n+'.js']).returncode == 0)
   EOF
   ```
3. `./build.sh release test`, then in mnml Test (the user tests by feel; list these
   for them): tab groups, splits and chats survive quit/reopen; ⌘N opens a second
   window with its own tabs, ⌘E chat and extension side panel work in it; ⌃Tab,
   ⌘1–9, ⌘←/→; the sidebar slide and "page under the chrome"; Claude for Chrome
   signs in and its panel docks; bookmarks folders; Move to Space / Move to Window.
4. A scripted test world, if needed: `defaults write com.farchan.mnml.test.NAME
   bench -bool true && MNML_PROBE=NAME ./fresh.sh again`, then `./bench --world NAME …`
   (see `skill/search-bench/SKILL.md`). Never quit `/Applications/mnml.app`
   by name — same bundle id; quit only processes with `MNML_PROBE` in their env.

## Known things not to chase

- A dark strip at the page's right edge for ~8 frames when the column hides
  (accepted; `docs/mnml/sidebar-slide.md`).
- Droppy's media widget relaunching mnml on quit (user's third-party app).
