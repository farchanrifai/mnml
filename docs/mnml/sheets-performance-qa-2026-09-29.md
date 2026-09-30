# Google Sheets tab-count QA — 29 September 2026

## Result

No repeatable production UI stall was established in the tested workload. The final traced 40-tab repeat maintained foreground focus throughout and had no diagnostic responses over 250 ms. One earlier settling response took 410 ms and remains unexplained; it did not repeat under native sampling. Do not treat this as complete clearance for large working spreadsheets, recording, or animation smoothness.

No production source change, rebuild, install, commit, or main-app modification was made for this task. The existing upstream/performance changes remain uncommitted.

## Workload and method

Installed **mnml Test 1.0.4 / 202609291118**, macOS 27.2, 24 GiB MacBook Pro, signed-in isolated Test `copy` profile. Launched with `MNML_MEASURE=1` so background scheduling and App Nap retain production behavior. The profile had nine original tabs, eight restored/unloaded; the active page was Wikipedia. Retained the default **Balanced** memory profile and automatic sleeping.

Opened **10, 20, and 40 additional normal tabs** through the existing external-link route. These are ordinary saved tabs subject to sleeping, rather than sleep-exempt bench tabs. Mix: 60% Google Sheets, 20% Google Drive, 20% Wikipedia. At the largest level: 24 Sheet copies, eight Drive copies, eight normal pages, **49 total tabs**. Copies used the existing signed-in untitled Sheet and Drive folder. No cells, formulas, titles, files, shares, or account permissions were edited.

Checked Sheets grid, toolbar, canvas presence and login state without extracting cell contents. Each Sheet opened a real editor. This is repetition of one untitled Sheet, not 24 distinct large documents; cell count and formula complexity were not assessed.

Exercised 20 selections per level, eight Ask shortcuts (page width verified open/closed), 12 sidebar changes, and 21 characters typed into the command bar without submitting. Measured selection command response and typing-to-run-loop-rest times. Monitored native socket responsiveness roughly 10 Hz. These are response proxies, **not input-to-display, page-ready-on-every-switch, or animation completion times**.

## Valid foreground interaction results

| Added / total tabs | Sheets / Drive / pages added | Selection max | Typing/run-loop max | App physical footprint before interactions | App + known WebContent RSS |
|---|---|---|---|---|---|
| 10 / 19 | 6 / 2 / 2 | 6.7 ms | 31.8 ms | 172.3M | 4.85 GiB |
| 20 / 29 | 12 / 4 / 4 | 7.0 ms | 25.7 ms | 194.7M | 4.35 GiB |
| 40 / 49 | 24 / 8 / 8 | 25.1 ms | 32.2 ms | 295.8M | 5.66 GiB |

The 10/20 rows come from run 2, the 40 row from run 4. Their interaction phases had no recorded focus recovery. The final 40-tab repeat ran native `sample` at 5 ms intervals for 110 seconds, which adds profiling overhead. Native diagnostic max during that repeat: selection phase 140.3 ms, Ask 41.2 ms, sidebar 73.8 ms, typing 54.1 ms, settling 220.4 ms. No >250 ms responses in the final run.

An earlier 40-tab run had brief foreground recoveries during idle/selection and one settling response of **410.3 ms out of 605**. Its selection timings are not used as the primary foreground result. No snapshot/picture UI captures were used during timing. `vmmap` measurements were labeled instrumentation and excluded from response statistics.

## Memory, background CPU and sleep

Final repeat: app physical footprint **73.6 MB before load → 295.8 MB at 40 added tabs → 266.0 MB after settling → 125.3 MB after closing all QA tabs and waiting 20 seconds**. This is residual warmed app state, not enough evidence to call a leak. The preceding 40-tab run ended at 129.9 MB; short runs do not show continuing app-memory accumulation, but no multi-hour leak clearance is claimed.

The earlier 40-tab run's known app + WebContent RSS was 5.44 GiB before settling and 6.06 GiB afterward, while fewer processes remained loaded. RSS varies with compression/residency and is not physical footprint or a leak metric. **These totals exclude the GPU/network processes, unassigned WebContent, compressed page footprint, and complete browser coalition accounting.** They show why app-only memory substantially understates page costs. Other user apps remained running; system swap use was already high when checked, with about 33% system free memory. No clean-system comparison or forced memory-pressure test was performed.

After the settling period, normal automatic policy had **20 sleeping/unloaded tabs of 49**, leaving 29 loaded (eight were originally unloaded). Thus 12 added tabs had been put to sleep. Balanced has a 20 eligible-background-tab cap, protects tabs left less than a minute ago, and skips active/loading/unsaved/media/notification tabs; its cap is not an instantaneous global count of WebContent processes.

An untouched background Sheet was explicitly put to sleep using the existing normal sleep method and successfully reopened with grid, toolbar and canvas present, without a login prompt. This verifies untouched-document recovery; **preservation of an actively edited or unsynchronized Sheet was not tested**.

Interval CPU measurements from the prior run, in ten samples with 49 total/29 loaded tabs, showed aggregate background Sheet CPU median about **10.4% of one core**, max 27.2%. Other background pages also consumed CPU. Background work exists; this does not establish that mnml's injected scripts are responsible or that background Sheets are fully suspended.

## Investigation of the settling outlier

A follow-up native sample covered tab interactions and the automatic-sleep period. It did **not** reproduce the >250 ms delay or establish a slow sleep/discard path. About **1,920 of 16,523 main-thread samples (~11.6%)** were in `ASAuthorizationWebBrowserPublicKeyCredentialManager.authorizationStateForPlatformCredentials` / TCC synchronous IPC. `Bench.probe` reads this permission on each call; the high-rate diagnostic monitor therefore adds non-production work. The 410 ms event was not sampled directly, so its cause cannot be asserted from the later sample.

Use lightweight `tabs` requests for future high-rate latency polling, with separate low-rate focus checks. Do not cache or alter live passkey permission checks in production based on this diagnostic workload. The sample remains at `/tmp/mnml-sheets-qa/run4/sleep-sample.txt` (3.7 MB); no raw document content is in the retained result JSON.

## Harness errors and cleanup

Initial run lost foreground and could not obtain the address-field editor; excluded from primary results. Run 2 hit a transient JavaScript result error during a page load after the 20-tab checkpoint; its completed 10/20 interaction phases remain useful. Added load-query retries for subsequent runs. One measurement process exited after cleanup without a new crash report; the final supervised repeat was still running at completion (`appExitAtCompletion: null`). Its cause was not established and no crash fix is claimed.

Every completed run closed only its recorded QA-created tabs. Final run verified **nine original tabs retained, zero created tabs remaining**, original tab selected and sidebar setting restored. No keys or main settings changed. After QA, quit the measurement process through the normal confirmation and reopened mnml Test normally; its original tabs and Ask panel were visible in the accessibility tree. A repeat harness and raw result summaries are retained under `qa-2026-09-29/sheets/`.

## Remaining validation

- Several distinct large Sheets with formulas, charts, filters and real edits, including unsynchronized edits during sleep/recovery.
- Actual visual tab/Ask/sidebar animation timings and a screen-recording session.
- Full process-coalition physical footprint and a longer mixed-site soak.
- A temporal trace if the isolated settling outlier recurs with lightweight monitoring.
