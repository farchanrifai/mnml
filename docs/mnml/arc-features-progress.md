# Arc features implementation checkpoint

## Location and boundaries

- Worktree: `/Users/farchan/.codex/worktrees/arc-features/search-browser`.
- Main checkout and the normal `/Applications/mnml.app` remain unchanged.
- Work is uncommitted. The approved roadmap is `arc-features-roadmap.md`.

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

Incorporate the user's concrete Peek feedback. Retest changed behavior and update mnml Test. Then follow the remaining roadmap in order: commands, routing, archive.

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
