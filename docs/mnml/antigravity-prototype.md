# Antigravity chat prototype

Developed on `codex/antigravity-chat`, based on main `91c0897` (2026-10-03).
With the user's authorization, the normal `/Applications/mnml.app` was rebuilt
from this worktree and installed as **1.0.4 (202610041721)**. The installed
executable matches the signed build, and strict signature verification passed.
Antigravity and its lifecycle controls are available in normal mnml; only the
benchmark commands and synthetic inactivity aging are restricted to Test.

Personal Gmail, Calendar, Drive and Notion search is now available through
Settings > Connections. See [the setup guide](connections.md). Retrieval reuses
the chat-only worker through structured search/read exchanges; it does not
enable inherited CLI tools or change global CLI permissions.

Choose **Antigravity** in the chat's provider picker or Settings > AI. The official
`agy` CLI must be installed in `~/.local/bin`, `/opt/homebrew/bin`, or
`/usr/local/bin`; sign in by running `agy` in Terminal. mnml uses that login and
never reads or copies OAuth credentials. The connection shares Antigravity quota;
it does not fall back to an API key. Review Antigravity's credit-overage setting
if you want to stay within the subscription allowance.

Verified installed models: `gemini-3.8-flash-low` and `gemini-3.1-pro-low`.
The custom model field accepts other slugs listed by `agy models`.

Automatic lookup, account-qualified `@` choices, editable account labels,
per-space multiple-account eligibility, and optional reviewed writes are included
in this installed build.
See [Personal account connections](connections.md) for setup and validation.

## Behavior

- Page/selection context, mentions, local history and streamed answers reuse Ask.
- Each chat runs in a dedicated mnml workspace. After a successful answer, its
  CLI stays warm for follow-ups; the chat header shows **Live**, whose hover
  text and menu report measured process RAM and idle time. An unchanged page,
  selection, mentions and files
  are not injected again on warm follow-ups; only the new question is sent.
- At most two resident Antigravity CLIs across all browser windows, including
  idle sessions. A new request evicts the least recently used idle process. If
  both are answering, further requests wait in a cancellable FIFO queue before
  extracting context or spawning a CLI.
- After three minutes of inactivity, a top-right app-level toast identifies the tab,
  space, measured RAM, idle time and 60-second countdown. It is mnml UI, never
  a macOS notification, and remains visible while viewing another mnml space.
  **Go to Tab** switches to the owner space and tab; **Keep Live** gives the
  session another inactivity window; **Kill Process** ends its runtime. Go to
  Tab also resets inactivity. At countdown expiry, the process ends automatically.
  Ending a runtime preserves the local conversation and its history.
- Stop and closing a tab cancel the request. Switching tabs or hiding the chat
  panel lets its answer continue. Closing a window cancels its chats. Quit stops
each CLI process group (including helpers in that group), and waits for the front ends to exit.
- The custom `mnml-chat` agent allows only `finish`, with customizations and MCP
  inheritance disabled. In CLI 1.2.15 an empty tools array exposes defaults;
  `[finish]` blocked a live disposable file-write capability probe. Unexpected
  tool events also fail the request; this is defense in depth, not the primary
  enforcement mechanism. Recheck tool restrictions after CLI updates.
- Text/CSV files must be UTF-8. Images, screenshots and PDFs are unsupported in
  this prototype, including PDF pages and mentions. Use an API provider for them.
- A fresh process receives local conversation history within Ask's existing
  bounds. A warm process retains its native conversation. Removing, re-adding
  or changing supplied context starts a fresh process with the latest sources
  and bounded local history, so an old page snapshot cannot silently remain
  current. After expiry, eviction or Kill Process, the next message also starts
  fresh from local history. Other Antigravity/Gemini chats are never imported.
- Antigravity reserves the bounded history allowance before clipping source
  text, so ordinary history growth does not change an unchanged large-page
  snapshot. When local history itself is trimmed, native state is rebuilt to
  match those bounds.
- Antigravity itself retains its generated conversations under its own policies.
  Deleting mnml's local chat history does not delete Antigravity history.

## Warm-session implementation measurements, 2026-10-03

Signed Release mnml Test 1.0.4 (build **202610031404**), Antigravity CLI 1.2.15,
`gemini-3.8-flash-low`, on the same Apple M5 / 24 GiB Mac. Two fresh test profiles
passed the complete warm-session and context assertions. These are individual
synthetic runs, not a general latency or quota guarantee.
The implementation, including the atomic watchdog fix, was first installed in
the normal mnml app as **1.0.4 (202610032155)**. Installation and relaunch
succeeded without a dialog or blocker. Strict signature verification passed,
and the built and installed executables both have SHA-256
`a571ef7ed467512c2a5fd2ad45270c7b2ed3e0a52fa591e9d9a5e884b457d06c`.
Earlier, signed Test build **202610031441** was ready, while replacing installed
Test build **202610031426** was safely refused because its standard Quit
confirmation was open while the Mac was locked. That was a Test-copy
installation limitation, not a blocker for the subsequent authorized main-app
installation.
The later top-right toast update is installed as **1.0.4 (202610032241)** after
a normal Quit confirmation saved the session. Its strict signature passed and
the built/installed SHA-256 is
`44884da3ded7a343e74ed76a976d59cc1ac55f396ef9d77761b2dfacf9a04ae2`.
An isolated native capture, `build/antigravity-toast-top/toast.png`, verified the
card at the top right with all three controls visible. The single synthetic
request and its disposable app/CLI processes were cleaned up.
The live measurements below used build 202610031404; the lifecycle implementation
was verified by the 155 tests described next, and the later alignment change
was checked visually.

**155 distinct tests passed:** 148 regression checks and the seven WebKit
download tests run separately. The 13 focused Antigravity checks are included
in that total, including the regression for a completed turn's stale watchdog:
it cannot terminate a newer warm follow-up because request identity is checked
atomically when marking the runtime stopped. The download fixtures were kept
separate because their combined execution has been intermittent.

| Fixture and turn | stdin bytes sent | Reported input tokens | Cache-read tokens | CLI turn time |
| --- | ---: | ---: | ---: | ---: |
| Small page, first answer | 1,179 | 2,572 | 0 | 4.46 s |
| Small page, same-process follow-up | 99 | 2,666 | 0 | 1.48 s |
| 900-record page, first answer | 90,580 | 19,617 | 0 | 5.14 s |
| 900-record page, same-process follow-up | 112 | 3,374 | 16,337 | 2.71 s |
| 900-record conversation, page chip removed | 1,229 | 2,576 | 0 | 9.76 s |
| Page re-added after changing its total | 90,929 | 19,709 | 0 | 5.45 s |

The large-page follow-up kept the same PID despite page trimming and history
growth. It sent only the new question and showed actual provider cache reads,
unlike the earlier 500-record control below. Cache behavior therefore varies
with the request; keeping a CLI alive does not guarantee cache hits. The small
page still reported its earlier context as input, while answering faster.
Subscription allowance is based on agent work, so these token counters do not
establish an exact percentage of quota saved. A page omitted explicitly is
removed from native state, rather than left in a warm process's earlier context.

One warm worker used about **208–222 MiB RSS**; two warm workers reached
**443 MiB combined RSS**. The default run never sampled more than two CLI front
ends, including during idle eviction and replacement. The two-worker settling
phase added 0.02 sampled CLI CPU seconds.
After the final cancellation settled, samples contained zero CLI processes;
the first cancellation sample can still contain a process being stopped.
No owned CLI helpers remained after cleanup. App baseline peak RSS was
114–124 MiB and baseline physical footprint 76–92 MiB. Native window captures
and space animations raised app RSS independently; these figures exclude
WebKit XPC processes and are not whole-browser memory or energy measurements.

The default run verified idle LRU eviction, the two-worker limit, cancelling a
queued third chat without spawning it, incremental answers, active cancellation,
and closing an idle worker's tab. Both runs verified the other-space warning,
Keep Live without changing PID, Go to Tab's exact space/tab and inactivity reset,
expiry with the conversation preserved, a correct follow-up after restarting,
and Kill Process preserving local turns.

A separate test used the **real clock**, with no timestamp adjustment. The same
PID remained alive past two minutes and until the inactivity deadline, using
about 222 MiB RSS. At idle **181.85 seconds**, the warning showed **59 seconds**
remaining while another mnml space was active. Expiry was observed at
**241.41 seconds** with two-second polling; the CLI was gone and both local turns
remained. Exactly one request start/result was recorded throughout that idle
test, followed by `sessionEnd` with reason `idleTimeout`.

Native window renders visibly verified the warning in another space, with the
owner's tab/space, measured RAM, countdown and all three actions. The focused
countdown image shows **Ending in 23s**. An immediate capture can precede the
warning's entry animation; the runner now lets it paint and records state after
capture. Earlier immediate captures did not show the warning even though their
file timestamps preceded expiry. They are retained as
`toast-before-warning-paint.png` for diagnostics and are not treated as visual
verification.

Evidence: `build/antigravity-warm-default-final`,
`build/antigravity-warm-followups-final`,
`build/antigravity-toast-focused/toast-countdown.png` and `state.json`, plus
`build/antigravity-warm-real-idle/summary.json` and
`real-toast-other-space.png`. The final profiles' generic Quit confirmations
were handled only for these disposable test processes; normal mnml was untouched
during the measurements, before the separately authorized installation above.

## Earlier short-lived prototype measurements, 2026-10-03

The measurements in this section predate warm sessions. In that version every
request exited on completion; zero idle CLI memory is historical behavior.

Release mnml Test 1.0.4 (build 202610031016), main baseline `91c0897`,
Antigravity CLI 1.2.15, `gemini-3.8-flash-low`, Apple M5 / 24 GiB,
macOS 27.2. Three independent synthetic-page runs:

| Run | App baseline peak RSS | Single CLI peak RSS | Two CLIs peak RSS | Single completion | Both parallel completions |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 128 MiB | 201 MiB | 399 MiB | 5.40 s | 6.92 s |
| 2 | 106 MiB | 221 MiB | 413 MiB | 6.42 s | 5.36 s |
| 3, final build | 114 MiB | 213 MiB | 387 MiB | 5.15 s | 5.65 s |

Run 3 sampled CLI CPU time was 0.41 CPU seconds for one short answer and
0.82 CPU seconds for both concurrent answers. App CPU time was 0.95 and
0.07 CPU seconds respectively; the first chat includes initial UI work.
These are process-time totals, not CPU percentages. First text for the short
answers across runs appeared in 4.08–6.60 seconds.

All three runs returned the correct independent RED/42, BLUE/17 and GREEN/63
contexts. Run 3 observed partial text while the request was still working,
cancelled a queued third request without launching it, and stopped both active
requests without a failed-answer placeholder. A separate live check then closed
one active chat's tab and quit the app with another request active. No observed
CLI processes remained afterward. Two CLI front ends can briefly have additional
helpers: the final run saw a short-lived `sw_vers` child with zero sampled RSS.

The final baseline physical footprint snapshot was 65 MiB for the app process.
App RSS reached 187–201 MiB around the native UI screenshot/cancellation phases;
that includes UI rendering work and is not isolated AI transport overhead. All
last idle samples contained zero CLI processes. The first idle sample can still
include a process completing cancellation. WebKit XPC processes are excluded.

135 regression tests passed with `MNML_PROBE=agy-unit` and
`--skip DownloadLifecycleTests`, including the 12 Ask/Antigravity checks and 20
fast CLI exits. The full combined suite is not green: WebKit download fixtures
intermittently time out or omit resume data. All seven download tests passed
when run separately; this prototype does not change the download implementation.
The sampler self-check and `git diff --check` passed.

Local evidence is in `build/antigravity-qa-run1`, `run2`, and `run3` (each with
the full `antigravity-qa-` prefix): summaries, samples, metadata, footprint
snapshot and native chat render. Run 3 also includes `lifecycle.json`. The
internal native window capture visibly showed the chosen provider and correct
answer; OS screen capture through CUA failed with ScreenCaptureKit error -3811,
so interactive picker clicks remain a manual check.

## Context size and quota

The warm-session policy trades idle RAM for faster follow-ups, with a two-process
limit and inactivity expiry. Keeping a process alive does not by itself prove a
quota benefit: a provider may still process its earlier context on each turn.
For follow-ups about an answer already given, remove the page chip with its ×
button. This restarts with bounded local history and excludes the old source. The
conversation remains available, while the page is omitted. Add the page back
through @ for questions that require fresh source details. To work on a selected
passage, retain the Selected Text chip and omit the full page; explicitly added
tabs and files still go with the request until their own chips are removed.
The composer now explains page omission and labels the conversation-only state.
Page context stays included by default; there is no automatic relevance guess or
lossy summary. Existing model budgets and trim indicators still apply.

A CLI 1.2.15 / Flash-low control experiment used the same 500-record synthetic
page and two short questions (total 42, then total plus one). All returned the
correct answer. Per-turn uncached input and measured follow-up latency:

| Strategy | Follow-up input tokens | Cache-read tokens | Follow-up latency | Idle CLI memory |
| --- | ---: | ---: | ---: | ---: |
| New process, full page replay | 14,302 | 0 | 4.15 s | 0 |
| New process, native conversation resume | 14,492 | 0 | 6.09 s | 0 |
| Same process kept warm | 14,409 | 0 | 1.66 s | 207 MiB RSS |
| New process, conversation only | 2,289 | 0 | 4.65 s | 0 |

The last strategy reduced input tokens by 84% in this fixture. This is not an
84% subscription-quota claim: Google bases quota on agent work and does not
publish an exact input-token-to-allowance conversion. Latency is from one
control run and varies. Native resume and a warm session did not show a cache
benefit on this account/model. Warm sessions are now implemented for their
responsiveness benefit, with explicit RAM visibility and automatic expiry.
Persisted native conversation resume is not used after process termination.

The app-level run on the built mnml Test 1.0.4 (202610031041) confirmed this
workflow: full-page follow-up **14,606 input tokens**, conversation-only
follow-up **2,575** (82% fewer), with the expected answers 43 and 44. Re-adding
the page after changing its total to 73 returned 73. Every settle/idle phase
had zero CLI processes and zero sampled CLI RSS; no helpers remained. Active
CLI RSS was about 193–224 MiB. It does not depend strongly on page omission:
this strategy saves model input while retaining the same short-lived process
memory policy. App RSS and WebKit overhead remain separate.

The 135 regression tests passed again, plus the runnable follow-up assertions,
sampler self-check, and both visibly verified native context hints. Evidence:
`build/antigravity-balance-ui/summary.json`, `requests.jsonl`, `resources.jsonl`,
`page-followup.png`, and `conversation-followup.png`. This was tested from
`build/mnml Test.app`: replacing `/Applications/mnml Test.app` was blocked by
an open alert in that application's existing session. The original page-chip
omission control already exists in the installed prototype; the added guidance
was tested in the built copy. That earlier installation blocker has since been
resolved through the normal Quit confirmation, and warm-session build
202610031426 was installed as mnml Test. These earlier measurements did not
change the normal app. The later authorized installation of final source into
`/Applications/mnml.app` is described in the warm-session section above; Git
changes remain uncommitted with no branch merge.

Native-session `result.usage` is cumulative across turns. The resume/warm rows
above subtract the first result from the second; a separate per-step audit
confirmed this accounting. Do not interpret the second result as an additional
28,000-token request. Evidence: `build/antigravity-balance/comparison.json`,
`audit.json`, and `focused.json`.

Repeat the app-level comparison by adding `--followups` to the measurement
runner below, using a fresh profile/output directory. It asserts reuse of the
same PID for an unchanged-page follow-up, fresh PIDs after page omission and
changed page content, and correct answers throughout. The current fixture has
900 records and exceeds the page context reservation, so it also checks that
growing local history does not change the clipped source and restart a warm
process. The historical control above used 500 records. It then exercises the
other-space toast, Keep Live, Go to Tab, expiry, rebuilding a conversation and
Kill Process. These live runs consume synthetic-test subscription usage.

Sources: [headless session accounting](https://antigravity.google/docs/cli/headless/#read-the-results)
and [quota policy](https://antigravity.google/docs/plans).

## Repeatable measurement

Use a **Release** build on this Mac. Run in a separate `agy-qa` profile, not your
normal session. The runner sends only three generated fixture pages and records
one answer, a warm follow-up, two concurrent answers, idle eviction, the
cross-space toast actions, expiry and closing a warm chat's tab, followed by incremental-streaming and
queued/active cancellation checks. It asserts the two-process cap and verifies
zero owned CLI helpers after explicit cleanup. It consumes subscription quota.
The test-only `ai-sessions age` hook advances a session's idle timestamp through
the production expiry path; production timeouts remain three minutes plus one.

```sh
mkdir -p "$PWD/build/antigravity-qa"
defaults write com.farchan.mnml.test.agy-qa bench -bool true
defaults write com.farchan.mnml.test.agy-qa welcomed -bool true
MNML_PROBE=agy-qa MNML_MEASURE=1 \
MNML_AI_METRICS="$PWD/build/antigravity-qa/requests.jsonl" \
"$PWD/build/mnml Test.app/Contents/MacOS/mnml" \
  > "$PWD/build/antigravity-qa/app.log" 2>&1 &
prototype_pid=$!
# Once the bench socket is ready:
./bench --world agy-qa windows front 1
python3 scripts/measure-antigravity.py --pid "$prototype_pid" \
  --world agy-qa --out "$PWD/build/antigravity-qa"
```

Use a fresh output directory per run; `MNML_AI_METRICS` must match its
`requests.jsonl` path. The runner leaves original tabs alone and closes its own
fixture tabs. Keep the window foreground for representative UI behavior; log
foreground state separately if comparing responsiveness. The test profile may
need its welcome panel dismissed before visual QA.

Artifacts:

- `resources.jsonl`: sampled process IDs, parents, groups, RSS and cumulative CPU
  time, every 250 ms. Tracks app descendants, CLI process groups and observed
  helpers after reparenting. Uses executable names, never command arguments.
- `requests.jsonl`: request/chat IDs, CLI PID, warm state, input byte counts,
  time to first text, completion status and per-request token usage. Native
  cumulative usage is converted to deltas. Session termination is separate
  from request completion. Contains no prompts, page contents or answers.
- `summary.json`: phase peaks, warm PID/context checks, toast/expiry actions,
  queue/cancellation results and any remaining CLI helpers. Answers here concern
  only generated fixtures.
- `toast-other-space.png` and `toast-countdown.png`: native window renders of
  the app-level warning while its owner tab is in another mnml space.
- `baseline-vmmap.txt`: native physical-footprint snapshot or permission error.
- `app.log`: native app/CLI diagnostic output; treat as local diagnostic data.

RSS sums double-count shared pages and are **not** physical footprint. WebKit XPC
processes cannot be reliably attributed by parent PID and are excluded from the
CLI-overhead totals. CPU time is not battery/energy usage. A one-run synthetic
measurement does not predict heavy pages or attachments. Use Activity Monitor or
Instruments for total browser footprint/energy, and repeat identical scenarios
before making performance claims. Sampling can miss very short-lived helpers.

Checks:

```sh
MNML_PROBE=agy-unit swift test -c release --filter 'AntigravityTests|AskTests'
python3 scripts/measure-antigravity.py --self-test
```

Streaming/cancellation tests use a local fake executable; they don't consume
subscription quota. Live measurements validate the real installed runtime.

Sources: [headless CLI](https://antigravity.google/docs/cli/headless/),
[custom agents](https://antigravity.google/docs/subagents/),
[subscription quotas](https://antigravity.google/docs/plans).
