# Avoid redundant cache restoration and tool-detail reads

This change removes two repeat reads observed in the legacy OpenCode chat-loading path. It builds on the initial-load request deduplication patch used by the 20,000/50,000-message stress run.

## Warm local-cache restoration

`hydrateChatFromLocalCache` previously loaded and decoded the complete persisted transcript even when the directory store already held messages. The later `appliedMessages` guard then rejected the disk messages. When legacy memory already contains both messages and a known todo list, the function now marks local hydration complete and returns before the disk read.

An empty todo list is a loaded list. An unknown todo list still takes the disk path. The shortcut preserves selection, navigation, directory and cancellation checks and does not advance message/todo freshness. Cold cache reads and v2's presentation-only disk-cache behavior keep their previous path.

## Reusing accepted HTTP tool details

The legacy list-message and single-message endpoints both return full message envelopes with info and parts. In the upstream [v1.1.41 message implementation](https://github.com/anomalyco/opencode/blob/v1.1.41/packages/opencode/src/session/message-v2.ts), `stream` calls the same `get` used by the single-message endpoint, including all stored parts. A fresh accepted list response can supply the same completed tool details that the refresh path would otherwise retrieve again one message at a time.

Reuse is restricted to completed assistant messages with terminal tool parts, with exact equality to the current transcript and the same connection/scope. Running, missing or concurrently changed messages continue through the detail-fetch path. Arbitrary old in-memory or persisted history is not evidence of a fresh detail response.

## Scope of this change

This does not replace the legacy full-history request with a recent-message limit. The legacy transcript contract provides messages and an older cursor, but no reliable no-change revision or deletion inventory. A live SSE connection alone also does not establish continuity after a dropped decode or reconnect. A simple recent-page cap can leave a gap after many unseen messages and miss changes to older history.

The full-history transfer remains a separate synchronization change requiring explicit catch-up, deletion/revert handling and fallback semantics. This patch must not be reported as reducing the 539 MB / 1.35 GB canonical body to a bounded page.

## Validation

The dedicated `OpenClient load improvement regressions` workflow builds the actual iOS app with normal simulator signing and runs the local-cache integration/repository, chat store and shared initial-load facade suites. It retains the readable XCTest summary and build log on both success and failure.

[Native regression run 41294061307](https://github.com/gumminseogi/openclient/actions/runs/41294061307) passed for source revision `ff8da901f4885b09016329499940538d2b0b2ad9`: **177 passed, 0 failed, 0 skipped**, after a successful iOS app/test build. The artifact source-revision file matches that commit. All seven added methods are present as passed cases in the test log:

- Warm memory skips the disk read without advancing freshness; empty and nonempty loaded todo lists are covered.
- Unknown todos still hydrate without replacing memory messages.
- Invalid navigation, directory, selection and cancellation do not mark hydration complete.
- V2 keeps its original hydration behavior.
- A fresh completed tool envelope avoids its detail GET; running, changed and unproven entries still fetch.
- A detail response cannot overwrite a live change or removal; unloaded messages and unrelated edits remain valid.
- Connection replacement stops the old detail refresh.

Raw evidence artifact: `13078482563`, 119,738 bytes, SHA-256 `6ccf8c92d5f9b6f48aa3849d62fbde6a93cbdfbbb6a884786d752b723dc7f2a1`. It contains the readable XCTest summary and build/test logs.

No new whole-action performance comparison has been measured yet; request/read-count regressions do not establish a latency percentage on a physical iPhone.
