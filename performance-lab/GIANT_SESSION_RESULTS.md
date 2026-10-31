# Giant single-session stress test — 2026-10-31

This run increases the completed history in **one session** to 20,000 and 50,000 messages. It measures the native app's session-selection and bottom-refresh paths, rather than a small helper benchmark. The 20,000-message iPhone and iPad cases passed; they still needed roughly two minutes to finish a bottom refresh.

Both 50,000-message caches were successfully prepared, persisted and read back. Their measured UI cases did not pass end to end. The iPhone grouping-OFF case completed all three canonical publications but failed XCTest keyboard-focus verification after refresh. The other cases had incomplete transport or a disagreement between native input observation and the UI test's token check. Partial measurements are retained below and are not counted as passed cases.

## Reproduction and scope

- [Workflow run 41189897773](https://github.com/gumminseogi/openclient/actions/runs/41189897773).
- Test/harness checkout: `244270cd611bf53e54f95e223371f7a3db2a8e29`, branch `giant-session-lab`.
- Upstream source pin: `4dedc814bd38d3daa5a53bff01d75209f2865502` (OpenClient 1.0.28).
- Product code includes the earlier initial-load request deduplication patch, revision `362ae32e06128f9dee5cfcc71b4d727a0c72267a`. This run changes the fixture/harness, not the product implementation. It measures only the patched app; it is not a new baseline-versus-patch comparison.
- Separate macOS runners, each reporting **7 GiB RAM and 3 CPU cores**, Xcode 27.1, Debug iOS simulators. The fixture and simulator share each runner. These are not physical iPhone 15 Pro timings.
- One measured case per grouping/device/size; no median or run-to-run variance estimate.
- Completed synthetic history, no model calls or artificial per-action network delay. This does not reproduce a live model stream, scroll FPS, thermal behavior, or website-preview lifecycle.
- Each case restores the production-persisted cache while the app is terminated. The cache is marked stale. Normal app startup must publish the full cache before measured session selection. Then the case performs first selection, same-process revisit, and bottom overscroll refresh, checking native state and typed-input checkpoints.
- Cache-seeding setup and total XCTest duration are excluded from the action timings. Startup cache publication is recorded separately. Selection timings therefore do not include cold-launch cache hydration.

The fixture contains bash, read, grep, glob, list, write, edit, apply_patch, task, todowrite, webfetch, websearch and openclient_execute_tool records. These are synthetic records; none of those tools are executed by the fixture.

| One session | Message parts | Tool records | Reasoning parts | Full JSON body bytes |
|---|---:|---:|---:|---:|
| 20,000 messages | 72,500 | 35,000 | 17,500 | 538,607,742 |
| 50,000 messages | 181,250 | 87,500 | 43,750 | 1,346,532,031 |

The fixture streams the same JSON array to avoid constructing an additional giant temporary byte buffer on the server. The app still receives the full history. Because fixture transport changed from the preceding 5,000-message experiment, differences from that older run must not be presented as an app optimization effect.

## Timing definitions

All action timings use native monotonic timestamps from selection/refresh start. “Reveal” is the transcript reveal callback; it does not prove the first frame was presented. “Canonical” means the full typed response has been reconciled and published into native message state. “Refresh complete” is the bottom-refresh method completion, including work after canonical publication. It is not just HTTP download time or a guarantee that all frames are smooth.

Typed input is checked when automation attempts it. Its timestamp is not the earliest possible moment that the user could type. A failed keyboard-focus automation check is not evidence of an app crash.

## Fully validated 20,000-message cases

Seconds, rounded to three decimals. Each row passed native state/count, complete-response and typed-input validation for all three actions.

| Simulator | Grouping | First reveal | First canonical | Revisit reveal | Revisit canonical | Refresh canonical | Refresh complete |
|---|---|---:|---:|---:|---:|---:|---:|
| iPhone | ON | 18.830 | 86.983 | 11.751 | 85.969 | 55.489 | 125.005 |
| iPhone | OFF | 22.933 | 85.717 | 17.101 | 72.524 | 75.377 | 137.278 |
| iPad | ON | 19.176 | 83.982 | 14.168 | 71.397 | 60.335 | 116.208 |
| iPad | OFF | 19.999 | 77.758 | 18.071 | 49.019 | 53.484 | 113.960 |

Startup cache publication, measured from native startup metadata before selection, took 29.924/36.741 seconds on iPhone (ON/OFF) and 27.997/24.917 seconds on iPad. These intervals include startup scheduling and are separate from the selection times above.

Each of the three actions made **one** canonical history request and received **all 20,000 messages**: three complete bodies of 538,607,742 bytes, or **1,615,823,226 body bytes per grouping case**. Thus the earlier duplicate-request fix is functioning here, but a revisit or refresh still transfers the whole retained history. These are uncompressed fixture body counts, not a measurement of cellular billing or production compression.

Grouping OFF did not remove that transfer or the long refresh. There is not enough sampling to rank ON versus OFF performance. The earlier reported scrolling benefit from disabling grouping is a different workload.

Canonical publication also did not finish the refresh: the remaining aggregate interval was about 56–70 seconds across these four cases. This includes subsequent refresh work and scheduling; it cannot be attributed to a single function without profiling.

## 50,000-message iPhone: partial results, failed UI validation

The production cache seed and second-repository readback both verified 50,000 messages and a 1,346,532,031-byte body. Normal measured startup then published 50,000 cached messages in both grouping cases. The failure was after preparation, not a demonstrated persistent-cache size limit.

### Grouping ON

- First selection reached the reveal callback at 22.341 seconds and recorded an initial typed token at 74.484 seconds.
- The canonical request started at 15.096 seconds. Its server record ended after 64.765 seconds with status 200 but only **one completed body byte**, the array-opening bracket. Status 200 is not evidence of a complete response.
- No typed-page return or canonical publication appeared in the local native probe through selection +382.582 seconds. The test failed waiting for canonical publication; revisit and refresh were not reached.
- The request was no longer in the server's in-flight list at failure. The terminal transport error was not instrumented, so timeout, cancellation and a broken connection cannot be distinguished. A JSON-decoder hang is not established by this evidence.

### Grouping OFF

All three full canonical bodies completed and were published. The following are observed native phase measurements, **not a passed end-to-end case**.

| Action | Reveal | Canonical | Refresh method complete |
|---|---:|---:|---:|
| First selection | 16.553 | 127.188 | — |
| Same-process revisit | 18.147 | 155.388 | — |
| Bottom refresh | — | 105.516 | 202.957 |

First/revisit post-canonical input checks completed. The final refresh input check failed with `Neither element nor any descendant has keyboard focus`, so usable typed-input completion after refresh was not verified. The native 202.957-second method timestamp is preserved without marking the case successful.

The typed-page-return to canonical-publication intervals were approximately 34.300, 35.066 and 47.879 seconds. Refresh publication to method completion added another 97.441 seconds. These are aggregate phase bounds, not isolated CPU profiles.

No crash report or useful exported blocking stack was present. Empty hang exports do not prove that no hang occurred. The host's memory/CPU limits and the co-located giant fixture can affect these results; app RSS and the exact terminal transport cause were not captured.

## 50,000-message iPad

The cache seed and second-repository readback verified all 50,000 messages. Normal measured startup also published 50,000 messages for both groups, at 40.004 seconds (ON) and 59.811 seconds (OFF) from native startup metadata. Both UI cases failed during the first selection, so there are no revisit or refresh measurements.

| Grouping | First reveal callback | First canonical publication | Completed canonical body bytes | UI case |
|---|---:|---:|---:|---|
| ON | 21.585 s | 155.321 s | 1,346,532,031 | Failed input verification; later test allowance exceeded |
| OFF | 31.852 s | Not observed | 0 | Failed input verification; later test allowance exceeded |

In both cases the native input delegate recorded text containing the expected token (ON at 64.197 seconds, OFF at 99.593 seconds), but XCTest's accessibility-value check failed with `A unique plain token must survive typing`. This is a disagreement between observations, not proof that all input was dropped. No post-canonical typed-input checkpoint completed.

ON received the complete body and published 50,000 messages despite that failed UI check. OFF's canonical server record ended after 87.357 seconds with status 200 but zero completed body bytes, with no native typed-page return or canonical publication. Its terminal transport cause was not instrumented.

Both cases later exceeded the 1,200-second XCTest execution allowance. That limit is **not a 20-minute app-loading measurement**. The recorded native phases above are the available partial timings.

## Evidence

The raw ZIP artifacts preserve native JSONL probes, complete/partial HTTP request records, XCTest summaries, setup/readback proof, stage classification, host information and available native UI evidence. `FINAL_RESULTS.json` in the result archive separates validated metrics from partial cases and includes the artifact SHA-256 values.

The original ZIPs are available from the workflow artifacts. The consolidated archive supplied with these results is `OpenClient_giant_session_results_2026-10-31.zip` (65,807,097 bytes; SHA-256 `4acd072220bf8ada5ec7a6507998fb13210aae2dc53d7d5fd44658bbc655b7c8`). It contains all four original ZIPs without rewriting their contents, provenance, derived phase records and independent audits.

All four native jobs passed their four initial-load deduplication regression tests and cache preparation/readback. Both 20,000-message jobs passed the measured UI cases; both 50,000-message jobs failed UI validation. The independent fixture job passed its 19 contract tests. These outcomes are preserved in the workflow conclusion and raw records.
