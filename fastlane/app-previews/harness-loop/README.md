# “What if iOS had an AI Harness?” — creative video prototype

Silent 12-second loop at 30 fps, with dedicated header and search-results framing.

1. A blue chat bubble eases in with the question.
2. The question holds for reading, then scrolls upward.
3. A 3D Thinking capsule arrives, with a breathing cyan light.
4. The capsule fades back into the floating gradient background; the background completes one full motion cycle for a continuous loop.

The purple, cyan, indigo and orange background follows `ConnectionSheetBackdrop`. The offline SceneKit capsule adapts the geometry and materials from `GlassThinkingPill.swift`; this is rendered marketing artwork, not a screen recording.

```sh
swift scripts/render-app-store-loop.swift --preview
swift scripts/render-app-store-loop.swift
```

Requires the locally installed `ffmpeg`. Full-size exports:

- `en-US/header-loop.mp4`: 3840 × 1646
- `en-US/search-results-loop.mp4`: 3840 × 2560

H.264, opaque YUV 4:2:0, no audio, fast-start MP4. English concept copy for this first design pass.
