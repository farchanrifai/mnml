# Arc features implementation checkpoint

## Location and boundaries

- Worktree: `/Users/farchan/.codex/worktrees/arc-features/search-browser`.
- Promotion to the main checkout was authorized by the user on 2 October 2026. The normal `/Applications/mnml.app` remains unchanged.
- Branch: `codex/arc-features`. Approved Peek checkpoint: `10103dc`.
- Command-bar actions, routing, Archive and final refinements are complete and included in the main promotion. The approved roadmap is `arc-features-roadmap.md`.
- Final automated suite: 99 tests passed, zero failures. Final Archive hands-on review is deferred at the user's request.
- Latest installed test build: `202610011615`. Final signed bundle: `build/mnml Test.app`, build `202610011628`, with last-use and keyboard fixes. Compilation and signature verification passed; it is ready for later installation.

## Milestone 1: Peek and pinned splits

Implemented for review:

- Attached preview header with editable address, navigation, reload, close, tab promotion, and split promotion.
- Smaller preview (88% width, 86% height), live backdrop blur using the existing backdrop implementation, native compositor zoom/pop with a 180 ms fade, Reduce Motion/Transparency support, and immediate promotion without retaining a competing web-view host.
- Pinned outbound-site previews, Shift-click, and link context-menu entry.
- Shared unsent-edit protection for dismissal, switching tabs/Spaces, and closing the origin tab.
- Preview page targeting for navigation, find, zoom, print, reader, media pause, and inspector.
- Live `Tab`/web-view transfer on promotion, preserving the source website data store (including private browsing).
- Explicit nonadjacent split pairing, persistent tab identities, legacy-session compatibility, last-use timestamps, and duplicate-ID protection.
- Model checks for pinned promotion, the same live web view/data store, saved pair identity, closing the companion, and replacing the opposite pane.

Validation:

- `MNML_PROBE=arc-unit swift test`: 73 tests passed, zero failures.
- `git diff --check`: passed.
- Build `202609302232` was installed and opened. User reports the animation is almost there and requests smoother motion. The next build, `202609302303`, uses a critically damped 0.38-second spring, a smaller 0.96 starting scale, and shared backdrop/panel timing. Release compilation and signature verification passed after re-signing the bundle. Build `202609302303` is now installed and opened in mnml Test; the installed signature was verified. Live motion review remains pending. See `/tmp/mnml-peek-smooth-build.log`.
- Computer-use capture failed with `SCStreamErrorDomain Code=-3811`; live animation/visual quality is not verified by the agent.
- The user reviewed the first test build and answered **Needs refinement before continuing**. The user requested zoom/pop motion, blur behind the panel, and a slightly smaller preview; these refinements are installed for a second review. The attached Find bar and editable-field shortcut handling also target Peek. The user’s second visual review remains pending. Do not proceed to milestone 2 until Peek has been refined and reviewed.

## Next action

Implementation is complete and the user authorized promotion to main on 2 October 2026. Install the final test bundle and perform the deferred Archive review when ready; that review remains outstanding. No push or normal-app replacement is included.

## October 1 animation correction

- User clarified that smooth means no stutter, while remaining quick; the slower spring did not meet that requirement.
- Opening zoom now uses Core Animation on a native host's sublayer transform, with a fixed WebKit viewport; SwiftUI no longer scales the live page on each frame. Popup and backdrop fades use 180 ms ease-out; Reduce Motion skips the zoom. Closing fades the existing host before the page is closed, and promotion remains immediate.
- Existing full suite: 73 passed. The four Peek model checks also passed after adding a native-host viewport check. Live frame pacing still needs user review because agent screen capture is unavailable.
- Installed and opened mnml Test build `202610010014`; installed bundle signature verified. User visual review pending.

## October 1 closing refinement from recording

- Reviewed the supplied 7.69-second recording, including both closes frame by frame. The outgoing preview becomes blurred before removal, consistent with the departing panel dropping beneath the backdrop during SwiftUI removal.
- Explicit panel/backdrop stacking now keeps the panel above the blur. Closing retains the same panel and live page while a native 140 ms shrink/fade and backdrop fade run, then removes it without a second SwiftUI exit transition. Opening is unchanged.
- Repeated dismissal and tab/split promotion are blocked during close. Window teardown clears closing state.
- 75 tests passed; final targeted Peek checks (5) passed after synchronizing child animation durations. Native-host checks cover fixed viewport, live-page retention during closing, and promotion guards. Signature verified after installation.
- Build `202610010023` installed and opened as mnml Test. Live closing motion still requires user review; later milestones remain on hold.

## October 1 closing response adjustment

- User approved the closing motion but reported a delayed feel. The 140 ms ease-in curve has a gentle start; changed both the native exit group and backdrop fade to ease-out so the visual response is stronger immediately.
- Opening, duration, dismissal lifecycle, and form protection are unchanged. This is a curve-only adjustment; release compilation, signature validation, and user motion review are the applicable checks.
- Release build `202610010027` installed and opened in mnml Test; installed signature verified. Closing response remains pending user review.

## October 1 unified close clock

- User observed that unblurring and panel disappearance still happened separately. Replaced the SwiftUI backdrop exit and native panel exit with one native container opacity animation. The panel shrink shares its exact start time, 140 ms duration, and ease-out curve.
- The native container hosts the backdrop below the fixed-size preview panel; its completion removes Peek without another transition. Completion is tied to the preview identity, so an older closing callback cannot remove a later preview. Reduce Motion remains immediate.
- Full suite: 75 passed. Final native-host/Peek checks: 5 passed, including common-host containment, retained viewport, one completion, and repeated-close protection. Opening keeps the existing 180 ms zoom/pop.
- Build `202610010039` is installed and opened in mnml Test; the installed signature is verified. Live review and later milestones remain pending.

## October 1 stuck-close regression fix

- User reported that Peek could no longer close in build `202610010039`. The native `PeekSurface` wrapper retained the browser as an ordinary reference, so SwiftUI could skip its update when only `peekClosing` changed. The native animation and completion never started.
- Added `@ObservedObject` to the wrapper's browser. No duration or animation changes.
- Reproduced failure with a mounted `NSHostingView<PeekLayer>` test that invokes `Browser.closePeek` and awaits native completion; it failed before the fix and passed afterward. All six Peek checks passed. This covers the state-to-native-view connection omitted by the previous direct native-view test.
- Build `202610010044` is installed and opened in mnml Test; installed signature verified. Mounted dismissal is tested; live motion review remains pending.

## October 1 blur polish

- User confirmed the animation is fixed and requested weaker blur plus coverage of the uncovered top strip shown in the supplied screenshot.
- Backdrop radius reduced from 12 to 6; ground tint from 0.12 to 0.08 and black dimming from 0.06 to 0.04. The backdrop's native hosting view now has empty `safeAreaRegions`, so it fills the entire overlay rather than adding its own top title-bar inset.
- Animation and dismissal code are unchanged. This visual adjustment is validated by release compilation/signature and remains pending user review; agent capture is unavailable. Later milestones remain on hold until Peek review is complete.
- Build `202610010049` installed and opened as mnml Test; installed signature verified. Please review the weaker blur and top coverage in the same window configuration.

## October 1 milestone 1 acceptance

- User approved Peek: “ok cool. all good. commit and procedd to next step”. Milestone 1 is accepted in mnml Test build `202610010049`. Commit the isolated worktree changes, then implement command-bar actions as milestone 2. Main and the normal app remain unchanged.

## October 1 milestone 2: command-bar actions

- Approved Peek milestone committed as `10103dc` on the isolated `codex/arc-features` branch. Milestone 2 changes remain uncommitted pending review.
- Extended existing `AddressCommand`, `Suggestion`, Omnibox, and shortcut registry. Actions, current-window/current-Space tabs, history, explicit URL, and web search share a ranked list. URL intent stays first; exact matches beat prefixes and word matches; exact actions win ties. Return takes the selected or first result; search remains available. Empty input and Cmd-K retain recent-tab behavior.
- Added applicable pin/unpin, split picker/separate, Open Peek as Tab/Split Peek, and named Space move/switch actions. Operations revalidate availability. Move reuses existing sign-in/form protection and leaves the current Space selected. Action icons, Space names, and configured shortcuts appear in rows; split actions are configurable in Shortcuts.
- Added default-on Command bar actions setting. Existing inline exact commands remain independently opt-in. Search/tab row identities are distinct and Space actions use stable destination IDs, including same-named Spaces.
- Escape puts away a command bar over Peek first; Command-Return in its field does not prematurely promote Peek. Focus returns to the preview after command-bar dismissal.
- Routing settings and Archive commands will be wired when their real panels ship in milestones 3 and 4; no placeholders are shown.
- Full suite passed (85 tests); final focused command-bar checks passed (10), including ranking, URL/search choice, first-tab switching without duplication, pin/private applicability, split picker/separation, live Peek promotion, Space move/switch, disabled preferences, and empty/recent-tab lists. `git diff --check` passed.
- Build `202610010112` installed and opened in mnml Test; installed signature verified. Keyboard and visual review in the running mnml Test app remain pending because screen capture is unavailable. Do not proceed to routing before milestone 2 review.

## October 1 milestone 2 acceptance and routing

- User approved command-bar actions: “ok i think its working good”. Milestone 2 accepted in mnml Test build `202610010112`; proceed to external-link routing.
- Added local domain rules in Settings → Links, with enabled state, subdomain scope, stable destination Space IDs, editing and deletion. Spaces off suspends routing.
- Incoming web URLs match whole normalized domains before choosing the destination or Little window. Matching arrivals always create new tabs after a synchronous Space switch, using the destination website data store. Typed/restored/internal URLs bypass routing. Deleted Spaces remove their rules.
- Launch-time and live arrivals share a queued path; Peek draft checks and closing complete before delivery. Cancelling its form prompt cancels that arrival and permits later queued links. Installed test copies accept real external events; hidden probes remain isolated.
- Routing settings is now a command-bar action with a configurable shortcut. Final full suite passed: 90 tests, zero failures in a fresh probe namespace. Existing UpstreamSync pin checks fail when reusing an old probe namespace because they retain saved pins; they pass in a clean namespace. `git diff --check` passed. Release build `202610011025` compiled and its bundle signature verified. After the user quit mnml Test, build `202610011025` was installed and opened; installed version and bundle signature verified. Live routing review remains pending. Review Settings → Links, external app delivery to a Space with separate accounts, unmatched Little-window fallback, and launch-time/burst arrivals before proceeding to Auto Archive.

## October 1 routing UI refinement

- User confirmed routing works and requested editor polish before continuing. Existing-rule editing now replaces its own card, headed “Edit Rule” with the saved domain; new rules use “New Rule”.
- Reused settings rows and dividers for aligned domain, destination, scope and enabled controls. Save Changes and Add Rule distinguish the two operations; validation errors appear inside the editor. Cancel restores the saved row without writing the draft.
- Routing behavior is unchanged. Release build `202610011407` compiled and its bundle signature verified; `git diff --check` passed. After the user quit mnml Test, build `202610011407` was installed and opened; installed version and signature verified. Test-app visual review remains pending; Auto Archive remains gated on this refinement.

## October 1 compact routing editor

- User requested less space and simpler spacing after reviewing the editor screenshot. Replaced full-width settings rows and separators with one compact form: labelled domain and destination fields share a row, labelled checkboxes share the next, and Cancel/Save sit together at the bottom right. Helper explanations remain as tooltips. Existing rules still edit in place with an Edit Rule heading.
- Routing logic unchanged. Build `202610011425` compiled and its bundle signature verified; `git diff --check` passed. After the user confirmed quitting, build `202610011425` was installed and opened; installed version and signature verified. User visual review remains pending.

## October 1 routing acceptance and Auto Archive

- User approved routing and its compact editor: “Ok cool, lets proceed to next step”. Milestone 3 accepted in build `202610011425`.
- Auto Archive is off initially, with 24 hours, 7 days (initial enabled choice), and 30 days. Checks run shortly after launch, on wake and every five minutes. Manual archiving explicitly permits the current tab; automatic archiving protects every window’s visible tabs. Both protect pins, groups, split members, private/temporary pages, calls/media, downloads, forms and dialogs.
- Local atomic archive metadata is committed before removing a tab. Durable retired tab IDs filter stale sessions following an interrupted archive, even after an entry is deleted or the Archive cleared. Archive restoration records its new tab ID before opening, commits the destination window session before deleting the archive entry, reuses pending restored IDs on retry, and reconciles durable restorations at launch. Unreadable archive files are preserved and block writes.
- Searchable Archive panel includes original Space, date, restore, delete and confirmed Clear. Restoring with an unavailable or suspended original Space uses the current Space with an explanation. No routing, snapshots or cookies are copied. Archive actions are available in command suggestions and configurable shortcuts; context menus offer manual Archive Tab. Recently Closed remains separate.
- Full regression suite passed: 97 tests, zero failures. Seven focused Archive checks cover failed storage, cutoff boundaries, exclusions, Recently Closed separation, stale-session filtering, interrupted restore recovery, stable retry identity, deleted-Space fallback, corrupt-file preservation and failed deletion. A live WebKit integration check injects protected, unavailable and clean form-monitor outcomes and verifies each result through actual asynchronous page checks. Legacy source IDs are checkpointed before archival. `git diff --check` passed. Release build `202610011550` compiled and its bundle signature verified; after the user confirmed quitting, it was installed and opened in mnml Test; installed version and signature verified. User review remains pending. Live review should cover manual archive/restore, original and missing Spaces, protected form/media pages, panel search and Clear confirmation, and restart persistence. Screen capture remains unavailable; no live visual claim or normal-app promotion.

## October 1 additional inactivity periods

- User clarified frequency means inactivity periods. Added 1 hour, 12 hours, 3 days and 14 days alongside 24 hours, 7 days and 30 days. The Settings picker and cutoff use one shared list; seven days remains the initial choice. Existing day-based selections migrate without changing the selected period. The periodic check remains every five minutes.
- All eight Archive checks passed, including migration, hourly cutoff values, invalid-value fallback, and the existing safety/recovery checks. `git diff --check` passed. Release build `202610011615` compiled and its bundle signature verified. Build `202610011615` installed and opened in mnml Test; installed version and signature verified. Final Archive review is the remaining roadmap gate.

## October 1 final implementation pass

- User deferred hands-on testing and asked to finish remaining items. All four milestones are implemented; Archive review is deferred, not marked as accepted.
- Closed a last-use bookkeeping gap: leaving a Space, leaving a visible split, separating it, and saving on quit now refresh both visible members before persistence. This avoids treating a just-viewed tab as old enough to archive. Tabs being renamed are protected. Escape dismisses Archive before any underlying Peek.
- Final regression checks passed: 99 tests, zero failures; `git diff --check` passed. Final test bundle `202610011628` compiled and its signature verified, without closing the running app because the user deferred hands-on testing. It is ready for later installation. Remaining review later: Archive search/restore/delete/Clear; restart persistence; protected media/forms/downloads across windows; original/deleted Space restoration; inactivity menu. No normal-app promotion, merge or push.

## October 2 main promotion

- User explicitly requested bringing the Arc features to main. Commit the remaining implementation and fast-forward main from the shared base, preserving the original saved roadmap outside the checkout.
- Peek, command actions and routing were accepted in mnml Test. Archive hands-on review remains deferred; auto archive stays disabled initially.
- Final feature sources passed 99 automated checks and release/signature validation. Promotion includes source and documentation only; no push or replacement of the normal installed app.
