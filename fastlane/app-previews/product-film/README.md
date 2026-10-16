# OpenClient — In your hands

A silent, 16-second search-placement product film on a white background.

- **0–3.45 s:** “Big ideas.” Oversized type settles into place.
- **3.15–6.2 s:** “Now in your hands.”
- **6–9 s:** A silver device presentation reveals an existing OpenClient session-list capture. Screen, frame, and shadow dissolve as one composited object with a gentle rise.
- **8.8–14.35 s:** “Your OpenCode. Anywhere.” Product and typography settle into the final composition.
- **14–16 s:** The device subtly recedes and dissolves into white, matching the opening for a seamless loop.

Output: `en-US/search-results.mp4`, 3840 × 2560, H.264, 30 fps, no audio.
This is a creative concept, not an uploaded App Store asset.

```sh
swift scripts/render-search-product-film.swift --preview --stills
swift scripts/render-search-product-film.swift
```

`--preview` exports 1920 × 1280. `--stills` exports six storyboard frames, including the device's entrance and exit.
`--locale=it` and `--locale=pt-BR` select localized advertising copy; the existing app photograph remains in English.

The device surround is drawn offline. The screen is the existing, unmodified
`fastlane/screenshots/en_US/iPhone-18-Pro-Max-07-sessions.png` capture.
