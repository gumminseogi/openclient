# Paired 20,000-message load benchmark — 2026-11-01

This comparison measures native whole-action timings for the latest load improvements against the immediately preceding deduplicated version. It does not use the older October 31 measurements as the before values.

## Results

**Both complete native UI cases and the paired validator passed.** Independent recalculation from the native JSONL phases, UI checkpoints and raw HTTP logs reproduced the durations and counters below. This is **one fixed-order before/after observation**, not a median or an isolated estimate of the patch's causal gain.

All durations are seconds. Reduction is `(before - after) / before × 100`.

| Metric | Before | After | Observed time reduction |
|---|---:|---:|---:|
| First selection: full canonical publication | 55.805 | 29.019 | 48.0% |
| Same-process revisit: full canonical publication | 47.203 | 30.102 | 36.2% |
| Bottom refresh: native method completion | 135.731 | 36.299 | 73.3% |
| First selection: native reveal callback | 19.218 | 11.466 | 40.3% |
| Same-process revisit: native reveal callback | 16.620 | 9.394 | 43.5% |
| Bottom refresh: full canonical publication | 65.295 | 33.212 | 49.1% |

The first three rows are the primary loading/refresh measurements. Reveal is a native callback, not proof of a presented frame. First selection and revisit end at full canonical publication; refresh completion also includes post-publication work. Its post-canonical interval was **70.436s → 3.087s**.

| Verified work / response-body counter | Before | After |
|---|---:|---:|
| Redundant full disk decodes during first selection | 1 | 0 |
| Warm-memory shortcut during first selection | 0 | 1 |
| Message-detail GETs, entire measured case | 32 | 0 |
| Detail response bytes, entire measured case | 920,564 | 0 |
| Message-detail GETs, refresh action window | 20 | 0 |
| Complete full-history bodies | 3 | 3 |
| Full-history response-body bytes | 1,615,823,226 | 1,615,823,226 |
| All case app GET response-body bytes, including local preview | 1,616,749,393 | 1,615,827,721 |

The changed paths were exercised, but **full-history transfer volume is unchanged**. First/revisit action windows each contain zero detail GETs in both sources; the baseline's 12 prefetch GETs started between those windows. The remaining 20 occurred in refresh. Case-wide totals retain all 32 rather than summing only action windows. Preview `/_lab/reference` is included in the case-wide app GET total; lab control/polling is excluded.

### Environment variation and limits of attribution

| Separate, untimed or pre-selection observation | Before | After |
|---|---:|---:|
| Native startup cache publication | 34.978s | 21.810s |
| Cache-seed HTTP phase, native seed proof | 107.221s | 39.216s |

These stages also changed substantially before the measured warm shortcut. They demonstrate material host/order variation. **The observed 48.0%, 36.2% and 73.3% reductions must not be presented as isolated code-only gains or expected physical-phone improvements.** No startup-based correction or normalization was applied. The fixture shares CPU/memory with the simulator, which differs from a phone connected to a separate server.

Actual device: **iPhone 18 Pro Max simulator, iOS 27.0, arm64**; host allocation **7 GiB RAM, 3 vCPUs**. Both native UI summaries passed; the patched initial-hydration regression suite passed 4/4. The 20 fixture contracts and both production-cache seed/readback cases passed. No typing/keyboard, streaming-FPS or thermal result is claimed.

### Retained evidence

Final GitHub artifact **13091137833**, **1,881,043 bytes**, SHA-256 `53645c33ab9ce4a67261a25ffda050f14effaaeeb2eb86bbf4710f193308515f`. The independent audit verified exact source revisions, the same simulator ID, three unique complete responses per version, all six 20,000-message canonical publications, real route/visible-content checkpoints, and the warm shortcut / redundant decode markers. All native phase durations, comparison percentages and request-window counters were recomputed.

A separate evidence archive, `OpenClient_load_benchmark_2026-11-01.zip` (**78,894,522 bytes**), retains this original ZIP unchanged, the three earlier available original ZIPs, recovered job logs, separately labeled partial observations, `VERIFIED_RESULTS.json`, checksums and provenance. Archive SHA-256: `e78d8c0a4c725fe38720ce75a8a27b4cd9be4efa4b5075c16a4898964796181c`. Earlier failed attempts contribute no values to the primary comparison.

## Reproduction

- [Workflow run 41322530435](https://github.com/gumminseogi/openclient/actions/runs/41322530435).
- Harness checkout: `fc073403672472ba18dc871eb1cfbb6118e3bb89`.
- Before: `37fa58b3ae9957b6e5d95dc9919841b3eaa58421`.
- After product source: `ff8da901f4885b09016329499940538d2b0b2ad9`, also present unchanged in the harness checkout. The benchmark commit changes only instrumentation, fixture validation and the workflow.
- One iPhone simulator on one macOS runner, grouping OFF, tool and reasoning display ON, Debug configuration and normal simulator signing.
- One fixed-order pair: before, then after. This is a single observed comparison, not a median or a statistically established improvement. Fixed order does not remove cache, thermal, scheduling or host contention effects.

## Workload and validation

One completed synthetic session contains **20,000 messages, 72,500 parts and 35,000 tool records across 13 tool types**. The canonical JSON body is exactly **538,607,742 bytes**. No model calls, artificial network delay or external preview resources are used. The fixture and simulator share the runner.

Both versions use the same harness and a production-written, second-repository-verified cache containing the full history and a known stale todo list. Initial message and todo freshness timestamps are seeded 600 seconds in the past and verified stale. The known todo list makes the warm-memory shortcut eligible; chats with unknown todos retain the old disk path and are not represented by this workload.

Normal startup must publish all 20,000 cached messages before selection. Startup cache publication is measured separately. The three measured actions are first selection, same-process revisit and bottom overscroll refresh. The final comparison uses an explicit, identical **loading-only** policy for both sources: actual UI navigation, visible transcript content, native full canonical publication and complete HTTP bodies remain required. Keyboard input and typing responsiveness are not tested by this policy. Both sources already contain initial-request deduplication, so each must make **one canonical request per action and receive three complete full-history bodies**.

The before case must demonstrate its redundant disk decode during first selection. The after case must demonstrate the warm-memory skip marker. Failed tests, missing native phases, incomplete bodies and invalid request windows remain failures.

## Metric definitions and limits

- Reveal is a native transcript callback, not proof of a presented frame. Canonical publication is recorded separately and means the full typed response has been reconciled into native message state.
- Bottom-refresh duration ends when its native method completes, including work after canonical publication. It is not just HTTP download time.
- Cache-seeding preparation and total XCTest time are excluded. The startup interval is native startup metadata to full cache publication; it is not a stopwatch of the entire launch.
- Input timestamps occur when automation attempts input and do not identify earliest input readiness.
- Detail GET counts and response-body bytes use request-start ID windows `(before, after]`. App-body totals exclude diagnostic `/_lab/` endpoints. These are fixture body counts, not compressed wire traffic or cellular billing; ongoing SSE started outside a window is not included in those window totals.
- Negative time reductions mean regressions. Different actions may change in different directions; there is no combined percentage unless it is explicitly derived from a defined sequence.
- This completed-history benchmark does not establish physical iPhone 15 Pro performance, streaming scroll FPS, keyboard smoothness or thermal improvements.

## Excluded attempts and retained evidence

Run `41305534668` failed before producing a pair: the before case reached its visible checkpoint but XCTest lost keyboard focus while attempting input before full canonical loading; the after case was skipped. The later 20-minute test allowance is not an app-loading measurement. Artifact creation also failed with `ENOTFOUND`; the decoded job log is retained separately. The controlled rerun keeps product code and dataset fixed, moves input checks after canonical completion for both sources, sets the same software-keyboard policy, and retains core evidence in the job log in addition to artifact upload/retry. The first attempt contributes no timing to this comparison.

Run `41309513030`, harness `facafdd7df3d7f88813c5b92f731d83d3b4fa654`, failed both strict-input cases after each had published the complete first canonical response. Baseline failed software-keyboard readiness; patched failed the accessibility-value token assertion and later hit the XCTest allowance. The patched native delegate did observe the first token, so this is not proof that app input was dropped. Neither case reached revisit or refresh. Their original artifact is retained unchanged: 20,104,578 bytes, SHA-256 `440f7f494368e90b49b87de487e017d4e4c270ea0f119ad7a3074b5fa660d863`.

For transparency only, partial first-selection native observations were 31.532s → 12.833s for the reveal callback and 69.008s → 29.405s for canonical publication. Each received one 538,607,742-byte body. Baseline repeated one full disk decode and made 12 detail GETs (336,117 bytes); patched recorded one warm-memory skip, no redundant disk decode and no detail GETs. Startup also varied 38.365s → 21.969s before the changed selection path, demonstrating substantial fixed-order/environment variance. These failed-case observations do not establish a complete three-action comparison or isolate the patch's causal speedup.

Run `41315378415`, harness `63652744e0a7930ffa3f8dff86e775fa0a1baca6`, used the explicit loading-only policy. Both first-open actions published 20,000 messages and received the complete 538,607,742-byte body, then failed the UI driver’s back navigation before revisit/refresh. Both failure screenshots and accessibility trees showed the native `BackButton`; the driver had attempted edge swipes only. The final harness uses that observed native button for both sources while retaining route-unmount/session-row checks. This failed navigation run remains separate: original ZIP 43,374,891 bytes, SHA-256 `1177ab2d73b65de8febbe4eade2688d2ac2fc0dbce4c14904aac559f729de1aa`. Its partial reveal times were 18.203s → 11.539s and canonical times 77.851s → 26.597s; startup varied 31.842s → 20.100s. These are excluded from the final complete comparison.

Run `41318769270`, harness `16880df422b450f1e1ae5f5524332a2a037e7f0c`, completed all three patched actions and all patched validation. Baseline completed first-open canonical publication (52.927s), successfully tapped Back into the session list, then exhausted the driver’s 30-second overall polling budget before attempting the second Back button labeled `Projects`. The screenshot/accessibility tree confirms this intermediate state. There is no baseline revisit/refresh time from this attempt. Patched first/revisit canonical observations were 39.953s / 41.466s, and refresh method completion was 70.213s (canonical 62.878s); startup was 27.901s before and 34.916s after. The final harness changes only the same navigation polling budget to 180 seconds for both sources, outside all measured native actions; the three-tap limit and route proofs remain. Original ZIP: 13,306,939 bytes, SHA-256 `983d2a266dad84dc55587a1130883462aaa44f7a79e00dd4ae2a5e6445ec9b12`. These incomplete-pair observations are separate from the final comparison.
