---
name: install-iphone
description: Build, install, and launch the OpenClient iOS app on a physical iPhone. Use when testing on-device, diagnosing iPhone install/launch failures, or refreshing the on-device debug build.
---

# OpenClient iPhone Install

Use this skill to build the app for a physical iOS device, install it on the configured iPhone, and launch it.

## Target iPhone

- Device name: `Nic iPhone`
- Device UDID source: `OPENCLIENT_IPHONE_UDID`
- App bundle ID: `com.ntoporcov.openclient`
- Fresh app path: `.derived-data-device/Build/Products/Debug-iphoneos/OpenClient.app`

Do not hardcode the UDID in commands or logs. Read it from the environment. If `OPENCLIENT_IPHONE_UDID` is missing, source `.opencode/.env` if it exists, then stop and ask the user to set it locally before installing if it is still missing.

Skip device discovery unless build, install, or launch fails.

Use this shell guard before install/launch commands:

```bash
[ -f .opencode/.env ] && set -a && . .opencode/.env && set +a
: "${OPENCLIENT_IPHONE_UDID:?Set OPENCLIENT_IPHONE_UDID to the target iPhone UDID}"
```

## Build

Build for iPhone using repo-local derived data so the install path is fresh and deterministic:

```bash
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 xcodebuild -quiet -project OpenCodeIOSClient.xcodeproj -scheme OpenCodeIOSClient -sdk iphoneos -derivedDataPath .derived-data-device build
```

Do not install from stale global DerivedData or old repo-local paths. The expected fresh install artifact is:

```bash
.derived-data-device/Build/Products/Debug-iphoneos/OpenClient.app
```

Important stale-path warning:

- Do not install from `DerivedData/Build/Products/...` unless that exact folder was the explicit `-derivedDataPath` for the build you just ran.
- A stale `OpenCodeIOSClient.app` may have the wrong bundle identifier after the app rename.
- Prefer `.derived-data-device/Build/Products/Debug-iphoneos/OpenClient.app` after the command above.

## Install On iPhone

Install the freshly built app:

```bash
[ -f .opencode/.env ] && set -a && . .opencode/.env && set +a; : "${OPENCLIENT_IPHONE_UDID:?Set OPENCLIENT_IPHONE_UDID to the target iPhone UDID}" && xcrun devicectl device install app --device "$OPENCLIENT_IPHONE_UDID" ".derived-data-device/Build/Products/Debug-iphoneos/OpenClient.app"
```

## Launch On iPhone

Launch the installed app:

```bash
[ -f .opencode/.env ] && set -a && . .opencode/.env && set +a; : "${OPENCLIENT_IPHONE_UDID:?Set OPENCLIENT_IPHONE_UDID to the target iPhone UDID}" && xcrun devicectl device process launch --device "$OPENCLIENT_IPHONE_UDID" com.ntoporcov.openclient
```

## Failure Handling

If `devicectl` hangs or times out, use the **Direct CoreDevice fallback** below before concluding that the iPhone is unavailable. Repeated `devicectl list devices` calls can hang even when direct CoreDevice installation works.

If install or launch fails because the iPhone is locked, unavailable, disconnected, or not paired, then verify device availability:

```bash
xcrun xcdevice list
```

Common fixes:

- Unlock Nic iPhone.
- Reconnect USB once.
- Ensure Developer Mode is enabled on the iPhone.
- If using wireless debugging, ensure the Mac and iPhone are on the same LAN.
- Verify `Connect via network` in Xcode Devices and Simulators.

If install succeeds but launch fails because the iPhone is locked or unavailable, say that the install may have succeeded and the app can be opened manually after unlocking.

## Direct CoreDevice Fallback

Validated on this machine on 2026-10-24: `devicectl` discovery timed out, but calling CoreDevice directly connected to the configured iPhone and installed the fresh build successfully.

The crucial sequence is **discover → select by configured UDID → explicitly connect → install**. A device initially reported as `Disconnected` is not sufficient evidence that installation is impossible. Calling `installApplication` before `connect` returned:

```text
com.apple.dt.CoreDeviceError Code=4000
RemoteServiceDiscovery connectivity is not available to the device
```

Calling `RemoteDevice.connect(targetQueue:completionHandler:)` first resolved that failure. Wait for its success callback before starting installation.

The bundled helper, `scripts/coredevice-install.swift` (relative to this skill), calls `/Library/Developer/PrivateFrameworks/CoreDevice.framework/CoreDevice` directly. It does not invoke `devicectl`. From the repository root:

```bash
workdir="$HOME/Library/Application Support/OpenCode-v2-stable/tmp/opencode"
mkdir -p "$workdir"
xcrun swiftc .opencode/skills/install-iphone/scripts/coredevice-install.swift \
  -F /Library/Developer/PrivateFrameworks -framework CoreDevice \
  -Xlinker -rpath -Xlinker /Library/Developer/PrivateFrameworks \
  -o "$workdir/coredevice-install"

# Validate framework symbols and result metadata without connecting or installing.
"$workdir/coredevice-install" --check

[ -f .opencode/.env ] && set -a && . .opencode/.env && set +a
: "${OPENCLIENT_IPHONE_UDID:?Set OPENCLIENT_IPHONE_UDID to the target iPhone UDID}"
"$workdir/coredevice-install" \
  "$PWD/.derived-data-device/Build/Products/Debug-iphoneos/OpenClient.app"
```

Run installation with a bounded tool timeout (180 seconds worked). Success requires the completion callback to print `INSTALL SUCCEEDED` and exit zero; discovery, connection, or returned `Progress` alone does not confirm installation.

Implementation notes for future Xcode/macOS changes:

- This is a private Swift ABI workaround, not a public SDK. Keep it in tooling, never the app target.
- The framework has no importable Swift module here. The helper binds the observed mangled symbols and opens the real installation-result metadata for the generic callback.
- `_typeByName("CoreDevice.AppInstallationResult")` returned `nil`. The working approach resolves its symbolic type reference through `swift_getTypeByMangledNameInContext`.
- The helper derives image offsets from `nm` rather than retaining the original hardcoded offsets. ABI/signature changes still require inspecting the new framework. Do not guess replacements if compilation or `--check` fails.
- The compiler currently warns about directly referencing the reserved Swift runtime symbol; a future compiler may reject it.
- This fallback installs only. It does not launch the app or verify UI behavior. Report installation separately and ask the user to open OpenClient manually when launch tooling remains unavailable.

## When Xcode Project Generation Is Needed

If build fails with bundle identifier validation errors, regenerate the project from `project.yml` using the local signing override, then rebuild:

```bash
INCLUDE_PROJECT_LOCAL_YAML=1 /Users/mininic/.local/bin/xcodegen generate
```

Known validation error strings include:

- `error: Unexpected app bundle identifier '$PRODUCT_BUNDLE_IDENTIFIER'. Regenerate the project from project.yml before building.`
- `error: Unexpected extension bundle identifier '$PRODUCT_BUNDLE_IDENTIFIER'. Regenerate the project from project.yml before building.`

## Final Report

Report:

- Whether the iPhone device build succeeded.
- Whether install on the configured iPhone succeeded.
- Whether launch on the configured iPhone succeeded.
- Any exact blocker if build/install/launch failed.
