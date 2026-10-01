# mnml: Peek, Commands, Routing, and Auto Archive

Agreed roadmap — 30 September 2026. Status: milestone 1 approved by the user on 1 October 2026 in mnml Test build `202610010049`. Milestone 2 approved by the user on 1 October 2026 in mnml Test build `202610010112`. Milestone 3 approved by the user on 1 October 2026 after reviewing routing and the compact editor in build `202610011425`. All four milestones are implemented; the user authorized bringing them to main on 2 October 2026. Final Archive hands-on review is deferred at the user’s request; all 99 automated checks pass. Handoff is saved and final signed mnml Test bundle `202610011628` is ready for later installation.

## Summary

Deliver four milestones in order: **integrated Peek and pinned splits → command-bar actions → Air Traffic Control → Auto Archive**.

Each milestone gets a release build in **mnml Test**, automated checks, and hands-on review before promotion. Peek’s acceptance depends on its visible behavior, not compilation alone. The user authorized source promotion to `main` on 2 October 2026 with Archive hands-on review deferred. Preserve unrelated work; replacing the normal app and pushing require separate authorization.

## 1. Integrated Peek and Peek → Split

### Experience

- Keep Peek as an inset overlay within the browser’s content area. Leave the original page’s layout and scroll position stable underneath.
- Replace detached buttons with one attached header: back/forward, reload, editable address, Close, Open as Tab, and Split.
- Use mnml’s existing surfaces and corner treatment, restrained dimming, and a short zoom/pop transition (user revision after first review). Respect Reduce Motion.
- Size the preview to 88% of the content area’s width and 86% of its height, retaining at least an 8-point inset in narrow windows. Blur the page behind it. Header stays attached during resizing and sidebar transitions.
- Keep Shift-click and add **Open in Peek** to link context menus. Normal outbound clicks from pinned tabs also open Peek. Use the pinned home’s registrable domain as its site boundary; subdomains count as the same site. Preserve Command-click and other explicit new-tab gestures.
- Links inside Peek navigate within Peek; never stack previews.

### Interaction and safety

- While Peek is focused, address, navigation, reload, find, and page commands target its page. Editing its address navigates Peek, without triggering Space routing.
- Escape, Close, and clicking the backdrop dismiss it. Confirm before discarding unsent form edits; Cancel leaves Peek open and focused.
- Page fullscreen exits before Escape dismisses Peek. Preserve normal editable-field shortcuts.
- Keep the existing Command-Return promotion shortcut outside editable fields. Split is available through the header and command bar.
- Dismissal restores focus to the original page. Switching tabs or Spaces uses the same unsaved-edit protection.
- Open as Tab and Split transfer the existing `Tab` and web view: no reload, duplicated history, or lost form/scroll state.

### Pinned splits

- Extend Split to pair pinned and unpinned tabs without moving pins out of their sidebar section.
- Replace adjacency-dependent pairing with explicit pair membership. Persist pair references using stable session tab identities; continue reading existing adjacency-based sessions.
- Original page appears left, preview right, initially at equal widths. Focus moves to the preview.
- From an existing split, Peek’s Split action replaces the pane opposite the originating page; the displaced tab remains open.
- Closing the unpinned member leaves the pin intact. Closing a pinned member separates the pair and retains existing pinned-tab close behavior.
- Pairing belongs to the current window and Space; moving either member elsewhere separates it. Missing restored members degrade to ordinary tabs.
- Tab switching and previews recognize pairs even when sidebar entries are separated.

**Milestone gate:** review opening, dismissal, navigation, resizing, and promotion in the running app before building the next feature.

## 2. Command-Bar Actions

- Extend the existing command bar and suggestion list; reuse current browser operations and shortcut definitions.
- Use the chosen **Arc-style mixed list**: actions, tabs, destinations, and search results appear together; Return executes the selected result, or the first result when no explicit selection exists.
- Preserve URL intent: valid URLs stay ahead of actions. For other input, rank exact matches before prefixes, then word matches; exact action matches win ties. Always retain a web-search choice.
- Show action icons, destination Space names, and configured shortcuts. Empty input keeps the existing recent-tab experience.
- Enable action suggestions by default in the command bar, with a Settings switch. Keep ordinary inline address-field commands governed by their existing preference.
- Include existing address commands plus:
  - Pin/unpin current tab.
  - Split current page, using the existing tab picker; separate current split.
  - Open Peek as Tab; Split Peek.
  - Move current tab to a named Space; switch to a named Space.
  - Open routing settings.
  - Open Archive, archive current eligible tab, and restore the most recently archived tab once Archive ships.
- Only suggest applicable actions. Destructive clearing of the archive stays in its panel.
- Reuse existing cross-Space move protection when sign-ins change. Moving a tab leaves the user in the current Space; switching Space is a separate action.

**Milestone gate:** complete the action set using keyboard alone and verify that normal URL entry and searches remain predictable.

## 3. Air Traffic Control

- Apply routing exclusively to **external HTTP/HTTPS links arriving from other apps**.
- Add a Links settings section with domain, include-subdomains switch, destination Space, enable/disable, edit, and delete controls.
- Normalize hostnames and match domain boundaries, never arbitrary URL substrings. Default new rules to including subdomains.
- Prefer an exact-host rule over a parent-domain rule; among parent rules, the most specific domain wins. Prevent duplicate enabled rules with identical matching scope.
- Matching links open directly with the destination Space’s sign-ins and bring that Space forward. Do not load them in the current Space first.
- Unmatched links retain current behavior, including the Little-window preference. Existing internal navigation, typed addresses, and restored tabs bypass routing.
- Open a new tab for each arrival; do not introduce deduplication in this release.
- Persist rules locally using stable Space IDs. Renaming a Space preserves rules; deleting it removes its rules. Disabling Spaces suspends routing.
- Route before external links choose between the main browser and a Little window. Preserve handling for files and non-web schemes.

**Milestone gate:** verify delivery from another app, including a destination with different signed-in accounts.

## 4. Auto Archive

### Policy

- Disabled initially. One global setting offers **1 hour, 12 hours, 24 hours, 3 days, 7 days, 14 days, or 30 days**; seven days is the initial enabled choice.
- Archive only loose unpinned HTTP/HTTPS tabs. Exclude grouped tabs, split members, private tabs, test tabs, extension pages, and temporary Peek/Little pages.
- Protect visible pages in every window, unsent edits, active calls/media, loading pages, ongoing downloads, and pages awaiting a dialog.
- Reuse existing sleep-protection checks where applicable, but keep archiving distinct from sleeping.
- Persist last-use time across restarts. Existing sessions without that value begin their countdown when first opened by the upgraded version.
- Check shortly after launch, on wake, and every five minutes while running. Revalidate eligibility immediately before removal. Uncertain protection checks skip the tab.

### Storage and restoration

- Save URL, title, custom name, origin Space, archive time, and stable entry identity locally. Store metadata only—no page snapshot, cookies, or offline content.
- Keep entries until explicitly deleted or cleared.
- Provide a searchable Archive panel with title/URL search, original Space, archive date, restore, delete, and confirmed Clear Archive.
- Restore into the original Space and activate the restored tab. If that Space no longer exists, restore into the current Space with a brief explanation. Routing does not override restoration.
- Remove an archive entry only after restoration is durably recorded.
- Persist the archive entry successfully before removing an open tab. Failed writes leave the tab open; recover interrupted operations without losing tabs or duplicating archive records.
- Manual Archive Tab uses the same eligibility rules, except an explicit manual action may archive the current visible tab. Keep recently closed tabs and Command-Shift-T separate from Archive.

**Milestone gate:** prove safe restart, interrupted-write recovery, and restoration before enabling it in the normal app.

## Validation and Defaults

- Add focused runnable checks for pair persistence/migration, command ranking, domain matching, archive eligibility, and interrupted archive/restore operations. Use the existing test and bench infrastructure.
- Exercise pinned/unpinned splits, missing pair members, multiple windows, private Peek, form protection, fullscreen, and keyboard focus.
- Verify routing with exact hosts, subdomains, lookalike domains, renamed/deleted Spaces, disabled Spaces, and separate sign-ins.
- Verify archive cutoff boundaries, restart/wake behavior, sleeping tabs, protected activities, failed storage, and deleted origin Spaces.
- Visually review Peek in light/dark appearances, narrow windows, sidebar movement, Reduce Motion, scrolling, and video playback. Reject flashes, detached controls, focus jumps, and reloads during promotion.
- Use one isolated implementation worktree and the separate mnml Test app. No new dependencies, cloud storage, service integrations, or AI ranking are needed.
- Styling dimensions and timing above are starting specifications; adjust them during milestone-one visual review before treating Peek as approved.
