# App Store creative assets

Dedicated artwork for the **Header** and **Search Results** placements in App Store Connect.

- `en-US/header-3840x1646.png`: selected static header — white background with “Big Ideas / Now in your hands”.
- `en-US/search-results-3840x2560.mp4`: selected Search Results creative — the approved 16-second product film with polished device transitions.
- `en-US/search-results-3840x2560.png`: earlier static search-results alternative.
- `pt-BR/` and `it/`: localized headers and Search Results films, plus the earlier static alternatives; captured app content remains English.

Image exports are opaque sRGB PNGs; the selected film is H.264 at 30 fps. These are separate from the ten-image screenshot gallery.

Regenerate from the repository root:

```sh
swift scripts/render-app-store-creatives.swift
```

Use `--header-only` to regenerate only the static headers. The selected search film is rendered with `swift scripts/render-search-product-film.swift` (add `--locale=it` or `--locale=pt-BR` for translations), then copied from `fastlane/app-previews/product-film/<locale>/search-results.mp4` to `fastlane/creatives/<locale>/search-results-3840x2560.mp4`.

The selected film uses an existing real iPhone session-list capture. Upload each file to its corresponding placement, then use ASC Preview to check the final presentation before submitting.

## App Store Connect placement workflow

Creative assets use the Asset Library API, separately from Fastlane's screenshot gallery:

1. Read `GET /v1/apps/{id}/assetLibrary` and `GET /v1/appAssetLibraryRefData`.
2. Reserve `appAssetLibraryImages` or `appAssetLibraryVideos` with category `CREATIVE_ASSETS` and the `assetLibrary` relationship.
3. Upload the binary parts using the returned upload operations, then commit with `uploaded: true`.
4. Wait for processing and verify the returned `specId` against the reference data.
5. Read the draft version localization's `placements?include=image,video` and retain the existing assignments for rollback.
6. Replace only the matching placement with `POST /v1/appAssetLibraryPlacements`, using `image` or `video`, `appStoreVersionLocalization`, and `DEFAULT_PROFILE`.
7. Use `PRODUCT_PAGE_HEADER_ASSET` for the static header and `APP_STORE_SEARCH_RESULTS_ASSET` for the film. Re-read both relationships to verify the assigned assets.

The film's preview frame is `00:00:11:24`, showing the composed end card rather than the blank opening. Updating an editable draft does not submit it for App Review.

Specifications: https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications
