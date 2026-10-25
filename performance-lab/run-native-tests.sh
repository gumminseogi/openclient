#!/usr/bin/env bash
# CI runner for existing production XCTest code; no substitute Swift implementation.
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo 'Usage: run-native-tests.sh SOURCE_CHECKOUT XCODEBUILD_DESTINATION OUTPUT_DIR' >&2
  echo 'Example destination: platform=iOS Simulator,id=SIMULATOR_UDID' >&2
  exit 2
fi
repo=$1
destination=$2
mkdir -p "$3"
output=$(cd "$3" && pwd)
if [[ -e "$output/environment.json" || -e "$output/tests.xcresult" ]]; then
  echo 'Output already contains native test results; use a new output directory.' >&2
  exit 2
fi
command -v python3 >/dev/null || { echo 'python3 is required for environment.json' >&2; exit 2; }
minimum_sdk=${MIN_IOS_SDK:-17}
checkout_sha=''
working_tree=''
xcode_version=''
sdk_version=''
xcodebuild_started=false
preflight_error=''
tests=(
  'ChatStoreTests/testLegacyIdleEchoDoesNotRepeatCanonicalReconciliation'
  ForegroundChatRefreshTests
  V2TranscriptPerformanceTests
  OpenCodeLocalCacheRepositoryTests
  'ChatStoreTests/testCanonicalCacheDeduplicatesMessageAndPartIDs'
  'ChatStoreTests/testTranscriptActivityGroupingCrossesMessagesButPreservesTextAndUserBoundaries'
  'ChatStoreTests/testLargeStreamingActivityGroupPreservesSourcesAndPreviousSnapshot'
  'ChatStoreTests/testMeasureLargeStreamingActivityGrouping'
  'ChatStoreTests/testGroupedWindowCountsRowsRatherThanToolMessages'
  'ChatStoreTests/testGroupedWindowCompletesActivitySharingBoundaryMessageWithAnswer'
  'ChatStoreTests/testGroupedWindowSkipsInvisibleHistoryAndCompletesOverlappingGroups'
  'TranscriptContinuityTests/testLongThreadOpeningIncludesEarlierTurnsAndKeepsPaginationBounded'
  'TranscriptContinuityTests/testHostingCellsSurviveCanonicalContentCaptionAndChunkReplacement'
  'TranscriptContinuityTests/testBatchCoalescesLatestPresentationAndRejectsDuplicateIDs'
  'TranscriptContinuityTests/testHistoryPrependDuringDraggingAnchorsMessageWithoutWaitingForGestureToEnd'
  'TranscriptContinuityTests/testScrolledHistoryAnchorAndPinnedTailWithHeightChanges'
)
write_environment() {
  local status=$?
  trap - EXIT
  python3 - "$output/environment.json" "$repo" "$destination" "$minimum_sdk" \
    "$checkout_sha" "$working_tree" "$xcode_version" "$sdk_version" \
    "$xcodebuild_started" "$preflight_error" "$status" "${tests[@]}" <<'PY'
import json
import platform
from pathlib import Path
import sys

(path, checkout, destination, minimum_sdk, sha, working_tree, xcode, sdk,
 started, error, status, *tests) = sys.argv[1:]
Path(path).write_text(json.dumps({
    'host': platform.platform(), 'source_checkout': checkout,
    'checkout_sha': sha or None,
    'audit_baseline_sha': '6b3054a18e731f342a3b98009c259191f5e67f51',
    'working_tree_status': working_tree.splitlines(),
    'xcode_version': xcode or None, 'ios_simulator_sdk': sdk or None,
    'minimum_ios_sdk': minimum_sdk, 'destination': destination,
    'configuration': 'Debug', 'test_identifiers': tests,
    'xcodebuild_started': started == 'true',
    'preflight_error': error or None, 'exit_status': int(status),
    'result_bundle': str(Path(path).parent / 'tests.xcresult'),
    'measurement_scope': 'Existing app XCTest on an iOS simulator; Debug measurements do not establish iPhone frame rate or Release performance.',
}, indent=2) + '\n')
PY
  exit "$status"
}
trap write_environment EXIT
fail() {
  preflight_error=$1
  printf 'Preflight failed: %s\n' "$1" >&2
  exit 2
}

[[ $(uname -s) == Darwin ]] || fail 'macOS and full Xcode are required. No iOS tests ran.'
for required in git xcodebuild xcrun; do
  command -v "$required" >/dev/null || fail "Missing command: $required"
done
[[ $minimum_sdk =~ ^[0-9]+$ ]] || fail 'MIN_IOS_SDK must be a major version number, e.g. 27.'
repo=$(cd "$repo" && pwd) || fail 'Source checkout directory does not exist.'
[[ -f "$repo/OpenCodeIOSClient.xcodeproj/project.pbxproj" ]] || fail 'A complete OpenClient checkout is required.'
checkout_sha=$(git -C "$repo" rev-parse --verify HEAD) || fail 'Source checkout has no Git HEAD.'
working_tree=$(git -C "$repo" status --short)
xcode_version=$(xcodebuild -version 2>&1) || fail 'Full Xcode is not selected or ready.'
sdk_version=$(xcrun --sdk iphonesimulator --show-sdk-version 2>&1) || fail 'The iOS simulator SDK is unavailable.'
sdk_major=${sdk_version%%.*}
[[ $sdk_major =~ ^[0-9]+$ ]] || fail 'Could not read the iOS simulator SDK version.'
(( sdk_major >= minimum_sdk )) || fail "iOS SDK $minimum_sdk or newer is required; selected SDK is $sdk_version."
[[ $destination == *'platform=iOS Simulator'* ]] || fail 'Supply an explicit iOS Simulator destination.'
[[ ! -e "$output/tests.xcresult" ]] || fail 'Output already contains tests.xcresult; use a new output directory.'
for test in "${tests[@]}"; do
  file="$repo/OpenCodeIOSClientTests/${test%%/*}.swift"
  [[ -f "$file" ]] || fail "Existing test file is missing: $file"
  grep -Eq "class[[:space:]]+${test%%/*}[[:space:]]*:" "$file" || fail "Existing test class is missing: ${test%%/*}"
  if [[ $test == */* ]]; then
    grep -Fq "func ${test#*/}(" "$file" || fail "Existing test method is missing: $test"
  fi
done

args=(test -project "$repo/OpenCodeIOSClient.xcodeproj" -scheme OpenCodeIOSClient
  -configuration Debug -destination "$destination" -parallel-testing-enabled NO
  -derivedDataPath "$output/DerivedData" -resultBundlePath "$output/tests.xcresult"
  DEVELOPMENT_TEAM=)
for test in "${tests[@]}"; do args+=("-only-testing:OpenCodeIOSClientTests/$test"); done
printf 'xcodebuild' > "$output/command.txt"
printf ' %q' "${args[@]}" >> "$output/command.txt"
printf '\n' >> "$output/command.txt"
printf 'Checkout: %s\nOutput: %s\n' "$checkout_sha" "$output"
# Remove the original author's team, retaining normal simulator signing for Keychain tests.
xcodebuild_started=true
set +e
xcodebuild "${args[@]}" 2>&1 | tee "$output/xcodebuild.log"
status=${PIPESTATUS[0]}
set -e
exit "$status"
