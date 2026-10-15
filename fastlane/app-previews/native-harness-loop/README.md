# Native simulator harness loop

This version records the real iOS views in OpenClient's DEBUG screenshot scene:

- `MessageBubble` (including `ChatBubbleBackground` and native Liquid Glass)
- `GlassThinkingPill` (the production RealityKit renderer)
- `ConnectionSheetBackdrop` (the actual connection-screen gradients)

SwiftUI springs handle entry and fading. A UIKit hosting-surface transform scrolls the entire chat bubble together, keeping its native glass and text synchronized. The gradient reverses every six seconds.

The header keeps the pill centered and cycles through Thinking, Working, Needs Input, and Ready. Search results show the question bubble scrolling away before the thinking pill appears.

Header placement compensates for the production pill camera's horizontal offset (+22 stage points) and sits 20 stage points below center to leave more space under App Store navigation controls.

Build normally with signing enabled, then capture on the landscape iPad Pro 13-inch simulator:

```sh
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 xcodebuild -quiet \
  -project OpenCodeIOSClient.xcodeproj -scheme OpenCodeIOSClient \
  -destination 'platform=iOS Simulator,id=<iPad-UDID>' \
  -derivedDataPath .derived-data-native-loop build

python3 scripts/capture-native-harness-loop.py <iPad-UDID> \
  .derived-data-native-loop/Build/Products/Debug-iphonesimulator/OpenClient.app

python3 scripts/capture-native-harness-loop.py <iPad-UDID> \
  .derived-data-native-loop/Build/Products/Debug-iphonesimulator/OpenClient.app --header
```

The host records the simulator display, detects the fixture's off-crop sync cues, and cuts one complete loop. FFmpeg only crops, scales, and encodes the captured pixels. It does not draw the UI. The 2752-pixel-wide native capture is scaled to the ASC export width.

Outputs in `en-US/`:

- `header-native-loop.mp4` — 3840 × 1646
- `search-results-native-loop.mp4` — 3840 × 2560
- `*-poster.png` — question-bubble poster frames
- `simulator-recording.mov` — original capture, including launch/warmup

The first prototype's offline SceneKit approximation remains separately under `harness-loop/` for comparison.
