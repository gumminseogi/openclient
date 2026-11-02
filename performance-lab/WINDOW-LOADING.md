# Legacy window-loading experiment

`openclient-window-loading.yml` compares product revision `e35444a66c150cc8dbb887de9b2c0f3d23cb4837` against the reviewed window-loading branch. Both include the earlier warm-cache and initial-load deduplication fixes. The harness is copied from the patched revision into the baseline checkout; instrumentation is CI-only.

One Xcode 27 job first compiles the patched app, runs selected native regressions and completes an unmeasured 64-message UI preflight. It then measures **baseline → patched → patched → baseline**, using one simulator and one compiled binary per variant. Every observation uninstalls the previous app, writes a fresh stale cache through the production repository, reads it back through a second repository, then restores the validated cache while the app is stopped. The baseline binary also runs the same three-action 64-message canary before its giant observation. Both binaries are reused for the remaining observations; the preflight is kept separate from the measured ABBA results. The extreme fixture has 20,000 messages and a 538,607,742-byte full JSON response; it includes mixed tool results, reasoning and a unique latest-answer sentinel.

The benchmark models a legacy 1.x endpoint with newest-N `limit` semantics and no `X-Next-Cursor`. It waits for normal connection and actual startup cache publication, enters the project and session through native navigation, verifies that the latest sentinel is visible, leaves the route using the native Back button, revisits, then performs the actual bottom overscroll refresh.

| Action | Baseline | Patched, uninterrupted SSE |
|---|---|---|
| Startup cache publication | 20,000 messages | 400-message preview |
| First session selection | One 20,000-message GET | One 400-message GET |
| Same-process revisit | One 20,000-message GET | Native cache-reuse phase and zero message GETs |
| Manual bottom refresh | One 20,000-message GET | One 400-message GET |

The full retained archive stays on disk in both versions. The patched seed verifies both its full archive and bounded preview. Each action requires the exact requested limit, body size, count and request-ID window; all other app traffic remains in the raw logs. Outside-window startup preloads are reported separately instead of silently discarded.

Compare **latest-content visibility and HTTP/cache readiness**, not equal full-history synchronization. Native callback times and UI observation times remain separate. Startup-to-visible is reported separately from selection. The UI observation includes XCTest/Accessibility overhead, and reveal callbacks do not prove a presented frame. Keyboard responsiveness, physical iPhone heat and FPS are outside this experiment.

The bounded path requires a healthy stream with uninterrupted continuity. After a suspend, reconnect or dropped event, product correctness may require an unbounded full inventory to recover old edits/deletions or a gap larger than 400 messages. Selected native regression tests cover that fallback, event/HTTP races, cache retention and cumulative older-page loading separately. The giant healthy-SSE benchmark does not claim to measure those fallback cases.

The workflow runs XcodeGen 2.44.1 before building, checks new source registration, uses normal simulator signing, and preserves native JSONL phases, fixture requests, seed proof, UI attachments and xcresult summaries. `validate-window-results.py` rejects missing or contradictory evidence. `compare-window-results.py` reports both counterbalanced pairs and medians of paired differences/ratios; two observations per variant are descriptive, not a confidence interval. A readable payload-free evidence export is also printed in the workflow log if artifact upload fails.
