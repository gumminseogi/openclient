# Legacy window loading

This experiment measures how soon the latest answer appears and when chat actions finish in a long, cached session. The change loads the newest 400 messages first and reuses a canonical window while SSE continuity holds. The baseline already includes the earlier cache-decode and tool-detail improvements; this is an incremental comparison, not a comparison with unmodified upstream.

## Observed results

**One complete A1/B1 pair and one additional patched observation are valid. The attempted ABBA experiment did not complete:** A2 failed during project connection, before selecting a session. The overall benchmark workflow correctly failed its complete-ABBA gate. No four-observation aggregate or median is reported.

The fixture contains 20,000 messages with mixed tool output. Its full JSON response is **538,607,742 bytes**; the newest 400 messages are **10,829,745 bytes**. All three completed giant observations passed the UI test and independent evidence revalidation.

Times are seconds. Each cell gives **latest answer visibly observed / action ready observed** by XCTest, measured from the UI action's start. Readiness requires the canonical HTTP or cache-reuse phase; refresh also requires the real refresh method to finish. Refresh does not measure new answer visibility because the existing answer remains on screen.

| Action | A1 baseline | B1 patched, paired with A1 | B2 patched, additional observation |
|---|---:|---:|---:|
| First session open | 26.45 / 56.55 | 18.21 / 18.23 | 16.22 / 16.24 |
| Same-process revisit | 27.14 / 62.74 | 21.77 / 21.81 | 8.24 / 8.26 |
| Bottom overscroll refresh | — / 86.61 | — / 7.65 | — / 4.82 |

Cold-process launch → first latest-answer visibility was **74.36s / 42.08s / 36.98s** for A1/B1/B2. This includes startup work before selection and is separate from the first-open action interval.

In the valid A1/B1 pair, visible first-open time decreased **31.15%**, visible revisit time **19.76%**, and observed refresh completion **91.17%**. The patched revisit's 8.24–21.77s spread is substantial; these data do not establish consistent three-second opening or parity with OpenCode web.

### Transcript traffic

These are completed message-list response bodies inside the measured action windows, not cellular wire bytes. B1 and B2 have identical transcript counts and sizes.

| Action | A1 GETs / body bytes | Each patched observation GETs / body bytes |
|---|---:|---:|
| First session open | 1 / 538,607,742 | 1 / 10,829,745 |
| Same-process revisit | 1 / 538,607,742 | 0 / 0 |
| Bottom overscroll refresh | 1 / 538,607,742 | 1 / 10,829,745 |
| Total | 3 / 1,615,823,226 | 2 / 21,659,490 |

Measured transcript bodies decreased **98.6595%**. There were no message-detail GETs or additional message-list GETs outside those windows. Other app response bodies were retained separately: 4,638 bytes for A1, 4,031 for B1 and 4,032 for B2. Unmeasured cache preparation still downloads and verifies the full archive once per observation; it is setup traffic, not a claim about normal per-view app traffic.

### Native timings and remaining display delay

Native intervals start in the app's selection/refresh handler, whereas the UI intervals above start before the tap or gesture. They are supporting measurements, not first-frame or keyboard-readiness guarantees.

| Native interval | A1 | B1 | B2 |
|---|---:|---:|---:|
| Selection → canonical publication | 55.92 | 12.44 | 10.93 |
| Revisit → canonical/cache-ready publication | 61.46 | 0.88 | 0.27 |
| Actual bottom-refresh method duration | 73.35 | 1.62 | 0.83 |

The trace includes native pre-reveal waiting as well as XCTest observation overhead. In B1/B2 revisits, cache readiness occurred at +0.88/+0.27s, but the app's reveal began at +14.56/+6.77s and completed at +14.82/+6.99s. Main-queue heartbeat enqueue delays of 2.7–7.2s occurred before reveal; UI observation added another 5.87/0.81s after completion. These traces do not apportion intrinsic app work versus work induced by the observer.

The pinned [reveal coordinator](https://github.com/gumminseogi/openclient/blob/e35444a66c150cc8dbb887de9b2c0f3d23cb4837/OpenCodeIOSClient/Views/Chat/ChatView.swift) keeps the collection hidden while layout samples, tail positioning and any opening history fill settle. Its fade is about 0.2s. The trace locates remaining delay before that reveal, but no sampled CPU profile was collected, so it does not identify the exact expensive function or prove that Markdown, self-sizing, or one layout call is the cause.

### Failed fourth observation

A2 displayed the app's server-timeout error and reported `connected_actual: false` at +19.73s. The UI test eventually stopped after 332.69s waiting for a successful connection. This is **not a measured 332-second transcript load**: A2 made no message-list request, opened no SSE stream and never selected the session.

The health, project-list and current-project requests returned HTTP 200 with fast server handling. The existing project-bootstrap path has a ten-second timeout. Scheduling delays are visible, but the precise cause of that connection failure remains unproven. A2 is retained as a failed observation and is neither replaced with zero nor included in an aggregate.

## Method

- One synthetic 20,000-message, mixed-tool session served by the cursorless legacy 1.x fixture. No model calls or artificial response delay. Tool grouping is off.
- Same macOS 27.0.1 arm64 host, iPhone 18 Pro Max simulator on iOS 27.0, Xcode 27.1 (27A9275), Debug builds. Attempted order: baseline, patched, patched, baseline. Each variant is built once; each observation receives a fresh cache written through the production repository and checked through a second repository instance. The retained full archive remains on disk.
- Each observation opens the session, returns through the real navigation hierarchy and reopens it, then performs the bottom overscroll refresh. Healthy, uninterrupted SSE is a prerequisite.
- XCTest/Accessibility records latest-answer visibility and observes canonical readiness. Refresh completion additionally requires the real refresh method to finish. Native callbacks, request IDs and exact response sizes provide separate supporting evidence.
- The fixture intentionally rejects the first startup-phase telemetry upload with HTTP 503 to verify retry recovery. UI observations include telemetry polling/retry overhead; native timestamps are recorded before upload and reported separately.
- The baseline loads the full 20,000-message inventory. The patched path loads a 400-message window, reuses it on a healthy revisit, and refreshes that window. These are comparable recent-content tasks with different inventory scope; their completion times are **not equal full-history synchronization times**.

## Provenance and validation

| Item | Revision / evidence |
|---|---|
| Baseline | `e35444a66c150cc8dbb887de9b2c0f3d23cb4837` |
| Measured benchmark source | `0839789bd1b1362fa72cefde2a310d82eef9d6b4` — [run 41391288252](https://github.com/gumminseogi/openclient/actions/runs/41391288252), three valid giant observations; complete-ABBA gate failed on A2 |
| Final product | `1ba01f9e4ffe4f5e60f96d44c60d7be017a3600b` on `legacy-window-loading-product` |
| Product native validation | [Run 41388365469](https://github.com/gumminseogi/openclient/actions/runs/41388365469), source `792e230e38048548650031a293755fda03476920`: **559/559 passed, 0 failures, 0 skips, all 13 selected suites executed** |
| Small-route preflight | [Run 41388988557](https://github.com/gumminseogi/openclient/actions/runs/41388988557), source `56838cf45f6c70638b9f8d25b4e5eae9d25a40bd`: **555 native tests and all three 64-message UI actions passed**; copied artifacts revalidated |
| Current-run validation | 34 Python contract tests; 555 native regressions; six cache-preparation tests; both 64-message UI canaries and A1/B1/B2 giant UI cases passed. A2 giant UI case failed before selection. All successful measurement dictionaries were independently recomputed exactly. |
| Raw benchmark artifact | ID `13119119716`, SHA-256 `7edc936bf95d3ea515cc8937b97c5e6baaa854046943b7b6dacf68f7636eb829` |

The final product's app and test code is byte-identical to the native-validated product source. Comparing the benchmark with the final product found one differing production Swift file, `AppViewModel+LocalCache.swift`: offline archive expansion and mode-transition guards, independently covered by the 559-test run. The steady online path is unchanged. Benchmark timings must retain the benchmark revision as their provenance.

The preflight revalidation permits repeated genuine, idempotent cache-ready callbacks and uses the earliest callback for native readiness. It changes validator interpretation only. No 20,000-message measurements were produced by that revalidation.

## Interpretation limits

- Only one complete pair and an additional patched observation are available. Preserve individual samples; do not infer an ABBA median, confidence interval or universal speedup.
- After suspension, reconnect or a dropped transcript event, the legacy safety path can still fetch the complete inventory to recover missed edits and deletions. Native tests cover this behavior; the giant-session timing of that fallback is outside this benchmark.
- UI timings include XCTest/Accessibility overhead. Native publication callbacks do not establish when a frame was presented. This experiment measures neither scrolling FPS nor keyboard responsiveness, thermals, battery use or a physical iPhone.
- Response-body bytes exclude protocol overhead and compression effects; they are not cellular wire-byte measurements. Preserve smaller preload requests and other app traffic separately from the action-window transcript totals.
