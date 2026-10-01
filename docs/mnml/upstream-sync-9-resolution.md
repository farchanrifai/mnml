# Upstream sync 9 integration

User authorized merging the upstream-sync branches into main on 2 October 2026.
Sync7 and sync8 are already ancestors of main; sync9's pending source changes
were preserved in `06677ad` and integrated with the Arc feature commits.

Included: batched Clear undo, closed-group restoration, panel-first Cmd-W,
native-messaging permission filtering, extension-menu deduplication, per-site
automatic video Float opt-out, and sidebar shadow transitions.

Integration keeps Archive above Peek in Cmd-W handling. Clear undo restores
nonadjacent split pairs and pairs with retained pins using stable identities,
without replacing any split created since Clear.

Validation: `MNML_PROBE=sync9-main-integration-20261002 swift test` passed all
120 tests, zero failures. New checks exercise Clear/pinned split restoration
and Archive/Settings close precedence over Peek. `git diff --check` passed.
Earlier sync9 live Clear, Close Group and Cmd-W smoke checks passed; video/PiP
and sidebar-shadow visual QA remain outstanding and were not rerun here.
Archive hands-on review remains deferred. No installed apps or the active
webkit-performance worktree were changed; no push is included.
