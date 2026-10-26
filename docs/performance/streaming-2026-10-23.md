# Streaming transcript performance — 2026-10-23

Investigation of [issue #26](https://github.com/ntoporcov/openclient/issues/26).

## Changes

- Reduce canonical V1 events in order, projecting the selected message array once per batch. Reuse that projection during publication and submission reconciliation.
- Index complete-inventory reconciliation by message ID, retaining full-envelope equality and duplicate-ID behavior.
- Cache grouped presentation by independent user-turn segments. Keep compaction associations and answers to earlier/queued prompts together; invalidate changed history, details, streaming state, and display preferences.
- Cache prepared display snapshots across viewport-only changes, including bottom overscroll. Canonical streaming continues normally.
- Leave the 3D pill unchanged to isolate transcript improvements.

## Method

Signed Debug builds with Xcode 27.1. Devices: iPhone 18 Pro Max and iPad Pro 13-inch (M5) on iOS 27.0, iPhone Duo on iOS 27.1.

The deterministic localhost V1 HTTP/SSE replay uses 160 historical envelopes, 240 tools, and 600 deltas at 20 Hz. The app uses its real transport, reducers, stores, and UI. Before/after matrices exercise grouping on/off and the existing 3D/fallback renderer. This replay is distinct from the real local V2 service smoke test.

Time Profiler, existing signposts, and process CPU/RSS samples were collected. Simulator Animation Hitches explicitly reports unsupported. These are simulator workload measurements, not older-iPhone GPU or frame-hitch measurements.

## Results

| Measurement | Before | After |
|---|---:|---:|
| Coordinator: 2,000 messages, 16 deltas × 10 batches | 91.42 ms | 36.09 ms |
| Complete-inventory matching: legacy/indexed algorithm pair | 438.26 ms | 2.33 ms |
| Pro Max grouped + 3D snapshot p95 | 9.55 ms | 4.94 ms |
| iPad grouped + 3D snapshot p95 | 7.79 ms | 4.44 ms |
| Duo grouped + 3D snapshot p95 | 6.74 ms | 5.85 ms |

The coordinator benchmark improved 60.5%; each measurement includes ten batches, not one frame. The inventory algorithm comparison is about 188× faster, not an app-wide speedup. Both microbenchmarks use ten measurements.

Grouped fallback accumulated snapshot interval duration decreased 55–59% across devices. Ungrouped accumulated duration decreased 28–38%, while per-call means increased 6–21%. The cache removes cheap geometry-only calls from the signpost population, so per-call distributions are not like-for-like comparisons. Counts, totals, and CPU must be considered together.

The unchanged 3D renderer's after-run A/B pairs showed 58–62 MB additional peak resident memory and 3.36–4.24 additional CPU percentage points relative to fallback. Single-run noise, coalescing, and cache warmth prevent precise causal attribution. Older physical-device GPU, thermal, and hitch costs remain unmeasured.

## Correctness and limitations

- 807 regression executions passed across the three devices before the final cross-parent refinement; that refinement's dedicated regression passed afterward.
- All six final grouped performance cases passed.
- Six additional grouped/ungrouped checks verified the exact 600-delta canonical string and all rendered tokens, including revisiting historical rows.
- A dedicated owned session on the real local OpenCode V2 service completed successfully; its final assistant marker was visually confirmed above the composer. Its history is not equivalent to the tool-heavy replay, so it is functional verification, not a comparable V2 timing result.
- Recording starts are not synchronized by a ready handshake. Coalescing and trace coverage differ; Duo's 3D baseline has notably less coverage. One stalled recorder was excluded. Initial group-off CPU results have additional recorder-finalization noise.
- Software-keyboard resizing and Duo unfolding were not verified. One Duo long-answer capture had its tail partly behind the translucent composer; no matched baseline establishes whether this is new.
- Full-string correctness uses a separate deep-copied replay fixture and longer drain window. It does not establish real-time 20 Hz visible-text latency.

## Artifacts

Local artifacts are under `~/Library/Application Support/OpenCode-v2-stable/tmp/opencode/`:

- `transcript-baseline-20261023/`: baseline source, signed apps, traces, benchmark results, workload and profiling hooks.
- `transcript-after-20261023/RESULTS.md`: detailed findings and caveats.
- `transcript-after-20261023/before-after.json`: counts, totals, distributions, CPU/RSS, and accepted-run provenance.
- `transcript-after-20261023/after-handoff.tar.gz`: portable reports, scripts, hooks, and source verification metadata.

Profiling hooks and synthetic service fixtures were isolated from shipping source. Temporary listeners were stopped, and preexisting service sessions were not modified.
