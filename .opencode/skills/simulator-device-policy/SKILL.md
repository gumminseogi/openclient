---
name: simulator-device-policy
description: Enforce the project's Xcode and simulator device policy for every iOS Simulator build, test, UI test, screenshot, preview, install, launch, or manual verification. Use whenever xcodes, Xcode selection, any simulator, simctl, xcodebuild iphonesimulator destination, or simulated-device workflow is involved.
---

# Simulator Device Policy

Use only these three simulator classes for all simulator work in this project:

- The newest available 6.9-inch iPhone Pro Max on the latest installed stable, non-beta iOS runtime.
- The newest available 13-inch iPad Pro on the latest installed stable, non-beta iOS runtime.
- The newest available iPhone Duo on the latest installed stable, non-beta iOS runtime with Duo support.

Every simulator validation must cover all three classes unless the user explicitly requests a subset. Never substitute a smaller iPhone, iPhone Air, iPad Air, iPad mini, generic simulator, currently booted simulator, or an older device merely because it is already available or booted.

This policy applies to all simulator usage, including builds, unit tests, UI tests, screenshots, app installation and launch, accessibility inspection, performance checks, and manual interaction.

## Verify The Selected Xcode First

Assume Xcode is already selected on this machine. Before simulator work, verify the selection without changing it:

```bash
xcode-select -p
xcodebuild -version
```

Do not run `xcodes select` unless explicitly asked: it prompts for an administrator password even when the correct Xcode is already selected. Use the selected stable Xcode; if verification shows a prerelease or an invalid developer directory, report the mismatch.

Do not set `DEVELOPER_DIR` or call `sudo xcode-select` to bypass the selected toolchain. Do not start an Xcode installation unless explicitly requested.

## Resolve The Current Devices

After selecting Xcode, do not permanently assume model names or UDIDs. Inspect the devices available to that Xcode:

```bash
xcrun simctl list devices available
```

Select devices using these rules:

1. Choose the latest installed public-release iOS runtime supported by the selected stable Xcode for each required device class. Prefer a common runtime when supported. Apple's iOS 27.1 Duo runtime supports only Duo, so use the latest stable Pro Max/iPad runtime alongside it. Exclude beta and release-candidate runtimes.
2. For iPhone, choose the newest `iPhone ... Pro Max` model with a 6.9-inch display.
3. For iPad, choose the newest `iPad Pro 13-inch (...)` model.
4. For Duo, choose the newest available `iPhone Duo` model. UI validation must cover folded and unfolded layouts and transitions between them where simulator controls support this; report unavailable transition controls as a coverage limitation.
5. Use names with `OS=latest` for `xcodebuild` only when `latest` resolves to the selected stable runtime. Otherwise specify its exact version.
6. Use the resolved UDIDs for `simctl` commands to avoid ambiguity across runtimes.

## Xcodebuild Destinations

Pass explicit destinations. Do not rely on `-sdk iphonesimulator` alone, `platform=iOS Simulator` alone, a generic destination, or Xcode's default device.

For work that supports a destination matrix, use all three resolved destinations:

```bash
xcodebuild \
  -project OpenCodeIOSClient.xcodeproj \
  -scheme OpenCodeIOSClient \
  -destination 'platform=iOS Simulator,name=<resolved-iPhone-Pro-Max>,OS=<resolved-stable-iOS-version>' \
  -destination 'platform=iOS Simulator,name=<resolved-iPad-Pro-13-inch>,OS=<resolved-stable-iOS-version>' \
  -destination 'platform=iOS Simulator,name=<resolved-iPhone-Duo>,OS=<resolved-stable-iOS-version>' \
  test
```

Replace the placeholders with the discovered model names and stable runtime version. If a command can target only one device at a time, run it once for each resolved device.

## Boot, Install, And Launch

Use the resolved UDID, not `booted`, because another simulator may already be running:

```bash
xcrun simctl boot <resolved-udid>
xcrun simctl install <resolved-udid> <app-path>
xcrun simctl launch <resolved-udid> com.ntoporcov.openclient
```

Repeat device-specific operations for all three required devices. It is acceptable to leave these simulators booted when the workflow benefits from it.

## Existing Commands And Automation

When a repository command, script, lane, or test configuration chooses a disallowed simulator:

- Override its destination when the tool supports an override.
- Otherwise update the project automation to follow this policy if doing so is within the user's requested scope.
- Do not silently run the disallowed destination.
- If the destination cannot be overridden or updated, stop and report the exact blocker.

## Availability Failure

If any required simulator class is unavailable on a supported stable runtime, do not substitute another form factor or use a beta runtime. Report which stable runtime or device is missing and ask the user to install the required simulator runtime or device support.

## Final Report

State which iOS runtime and exact Pro Max, iPad Pro, and Duo models were used. Report results for each tested device separately, including folded/unfolded and transition coverage for Duo.
