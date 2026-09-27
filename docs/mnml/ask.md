# Ask — a chat about your tabs

Dia / Comet / Atlas-style chat, in mnml's own way. Decided with the user 2026-09-27;
built the same day on branch `ask` (steps 1–6 below all done, plus Settings › AI).

Beyond the first plan: three modes (Sidebar, Floating, Full Page) and Open in New
Tab; ⇧⌘E opens a chat tab about no page; the tab's own chip can be left out; the
floating card springs to the corner it's thrown at; busy Gemini (503) retries,
then Flash-Lite; mentions share a 400k-character budget per question; a
mentioned tab out of the window is lent to it, unseen, while it's read.

Not kept across relaunch: attachments, single-tab mentions, Replace's pins, a
blank tab's chat (it's in history).

## Decisions

| | |
|---|---|
| Backend | Gemini API, **free tier** (AI Studio key). Claude Pro can't be used by third-party apps (Anthropic, Feb 2026); Gemini AI Pro has no API. Free tier may be used for training — Settings says so plainly. |
| Model | `gemini-flash-latest`, picker for `gemini-flash-lite-latest` (aliases, no version churn) |
| Place | Right panel, page shrinks beside it (resizable). Can undock to a card floating over the page (draggable, place remembered) |
| Shortcut | ⌘E toggles (free in mnml) |
| Context | Current tab. Selection if any (focus) + page text; PDF tab = the PDF itself; 📷 chip adds a screenshot of the visible page |
| Add more | `@` in the input → open tabs **and tab groups** (a group = one chip, all its tabs); drop / paste / + for images and PDFs |
| Sleeping tab mentioned | Woken quietly in the background, read, left to sleep again |
| Private tabs | Never context, never mentionable |
| Answers | Streamed, markdown (paragraphs, lists, headings, code, tables). Copy on every reply; **Replace selection** writes it back into the box you highlighted (Gmail, Outlook…) |
| Chats | **Per tab.** Each tab has its own chat; switching tabs switches the chat. **Open/closed is per tab too**: ⌘E opens it for this tab only; a tab you switch to shows the panel only if you left it open there (page resizes once on the switch). Split view: the chat of the pane last clicked. The tab is always the context; @ adds other tabs/groups/files to that chat. Survives the tab's navigation and relaunch (keyed by tab id). New chat = fresh chat on this tab, old one to history. Closing the tab sends its chat to history. History list (search, delete) reopens a chat onto the current tab. Saved locally forever |

## Design (from Dia, recordings 2026-09-27 8.10 PM and 8.12 PM)

**Panel (sidebar mode).** Right column ≈ 300 pt, same ground as mnml's column (window material/tint, not the page); the page keeps its rounded inset beside it. Header row, icons only: new chat (square-pencil) left; right: mode button (sidebar icon + chevron → menu *Sidebar / Floating*) and ×. mnml adds a history button (clock) beside new chat — Dia's recordings show no history entry point.

**Empty state.** Centered: small tilted dark card ("@ Mention Tabs", sample question with underlined tab names), dismissable ×; under it "Mention tabs to add context" / muted "Type @ to mention a tab". Shown until dismissed once.

**Composer** (rounded box at the bottom). Row of context chips on top: favicon + title (truncated) + domain; selection chip = text icon + first words + "Selected Text", **live**: it appears, changes and goes as you highlight on the page — before or while the panel is open (a selection made before ⌘E shows at once). Focusing the composer doesn't clear it; emptying the selection on the page does. Built as a user script in every frame (cross-site frames too, own content world) sending `selectionchange`, debounced ~150 ms, to Swift; text fields' own selections included, password fields never; file chip = icon + name + "PDF"/"Image". × on a chip on hover. Placeholder "Ask a question about this page…", after the first reply "Ask another question…". Bottom row: + (files) left; right: camera (screenshot), send = accent circle with ↑, becomes ■ stop while answering. Mic skipped.

**@ menu.** Pops up above the composer, input turns into "@ Type to filter". Sections: GROUPS (dot in group colour), TABS (favicon, 5 then "View more"), then "All open tabs (n)" and "All open ⟨site⟩ tabs (n)" for the current site, FILES "Upload file from computer". Arrow keys + Return, blue highlight row.

**Thread.** User message: right-aligned bubble in the accent (dark teal/space colour) with its context above it as a small fanned stack of chips (tilted cards); hover shows time, copy, edit. Assistant: no bubble, full-width text, markdown (bold, italic, bullets, headings, tables). "…" while waiting, then streams. Under a finished reply: copy + **Replace selection** (mnml's; Dia has 👍👎 — skipped). Scrolls; composer stays pinned.

**Floating mode.** Same content in a card ≈ 210 × 380 pt, rounded 12, darker grey, soft shadow, over the whole window (may cover the column). Header: new chat left, dock-back + × right. Drag by the header anywhere, resize from edges; place and size remembered. Starts bottom-right.

**Accent.** Send button, user bubble and highlights take the current space's colour (Dia: teal in one space, green in another).

## Build

Fresh from `main` on branch `ask`. ChatGPT's modal `TabChat.swift` (uncommitted, `../search-browser-under`) is dropped.
Each step is installed into mnml Test (`./build.sh release test`) for the user to feel before the next.

1. **Panel + current tab + streaming.** `Ask.swift` (Gemini SSE client, context from page, key in Keychain like `LockKey.swift`), `AskPanel.swift` (panel, composer, markdown blocks). Trailing room in `ContentView.window_` beside `stage`, same one-resize-per-slide as the column. per-tab `chatOpen` on Tab, restored with the session (`asking` on Browser is taken). ⌘E in `Shortcuts.swift`. Settings › AI: key, model, free-tier note.
2. **Live selection chip + Replace.** Selection user script (see Composer) feeding the chip as you highlight; at send, remember the field/range in the page; Replace = refocus, restore range, `execCommand('insertText')` (keeps page undo). Disabled if the tab moved on.
3. **@ mentions + groups + sleeping tabs.** Popover over the input, tabs and groups, filtered as typed; chips; `Tab.wake()` for asleep ones.
4. **Files, PDF, screenshot.** Drop/paste/picker → inline data (≤ 20 MB a request). PDF tab: bytes from the URL with the page's cookies (or the file). 📷 = `takeSnapshot`.
5. **History.** Chat per tab id in memory, restored with the session; one JSON per chat in Application Support/mnml/Chats (attachments beside it). Title = first question. List, search by title, delete, Clear All in Settings.
6. **Float mode.** Undock button; card over the page, drag to place.

Checks left behind: SSE parsing and markdown block splitting (`Tests/mnmlTests/AskTests.swift`).

Not now: agent actions (clicking/filling for you), cross-tab auto-search, voice.
