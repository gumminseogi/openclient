#!/usr/bin/env bash
# Same-host native A/B experiment. Standard simulator signing remains enabled.
set -euo pipefail
destination=$1
results=$2
device_id=${destination##*id=}
baseline=1cbcf2a6da9b579e7fc35038b5a8218de63ca010
bundle=com.ntoporcov.openclient
build_root="$RUNNER_TEMP/openclient-responsiveness-builds"
mkdir -p "$results" "$build_root"
fixture_pid=''
cleanup() {
  if [[ -n "$fixture_pid" ]]; then
    kill "$fixture_pid" 2>/dev/null || true
    wait "$fixture_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

python3 - "$results/provenance.json" "$baseline" <<'PY'
import json, platform, subprocess, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    'baseline_sha': sys.argv[2], 'candidate_sha': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    'host': platform.platform(), 'order': ['baseline','candidate','candidate','baseline','baseline','candidate'],
    'pairing': 'Same runner, same explicit simulator UDID. Each pair has both grouping settings. Restore identical app-private cache and restart the owned synthetic fixture before each case.',
    'scope': 'Native Debug callback gaps and sampled main-queue delays, not rendered FPS or real iPhone/input/heat measurements.'
}, indent=2)+'\n')
PY

# Both builds receive exactly the same instrumentation and native UI harness.
cat performance-lab/performance_probe.swift >> OpenCodeIOSClient/Diagnostics/OpenClientPerformanceDiagnostics.swift
python3 - <<'PY'
from pathlib import Path
p=Path('OpenCodeIOSClient/Diagnostics/OpenClientPerformanceDiagnostics.swift')
s=p.read_text()
old='    func startIfEnabled() {\n        guard Self.isEnabled else { return }'
assert s.count(old)==1
p.write_text(s.replace(old, '    func startIfEnabled() {\n        Task { @MainActor in OpenClientLabPerformanceProbe.startIfEnabled() }\n        guard Self.isEnabled else { return }'))
PY
cat performance-lab/long_transcript_ui.swift performance-lab/responsiveness_ui.swift >> OpenCodeIOSClientUITests/ToolGroupingUITests.swift

build_variant() {
  local variant=$1
  xcodebuild build-for-testing -project OpenCodeIOSClient.xcodeproj -scheme OpenCodeIOSClient \
    -configuration Debug -destination "$destination" -parallel-testing-enabled NO \
    -derivedDataPath "$build_root/$variant" DEVELOPMENT_TEAM= \
    2>&1 | tee "$results/build-$variant.log"
}
test_run_file() {
  find "$build_root/$1/Build/Products" -maxdepth 1 -name '*.xctestrun' -print -quit
}
build_variant candidate
candidate_run=$(test_run_file candidate)
[[ -n "$candidate_run" ]] || { echo 'Candidate test product missing' >&2; exit 1; }
xcodebuild test-without-building -xctestrun "$candidate_run" -destination "$destination" \
  -parallel-testing-enabled NO -resultBundlePath "$results/microbenchmark.xcresult" \
  '-only-testing:OpenCodeIOSClientTests/ChatStoreTests/testLegacyIdleEchoDoesNotRepeatCanonicalReconciliation' \
  '-only-testing:OpenCodeIOSClientTests/ChatStoreTests/testReducedProjectionPreservesCanonicalToolTranscriptAndPreviousSnapshot' \
  '-only-testing:OpenCodeIOSClientTests/ChatStoreTests/testMeasureReducedProjectionAvoidsRenormalizingLongToolTranscript' \
  2>&1 | tee "$results/microbenchmark.log"

xcrun xcresulttool get test-results summary --path "$results/microbenchmark.xcresult" > "$results/microbenchmark-summary.json"
xcrun xcresulttool export attachments --path "$results/microbenchmark.xcresult" --output-path "$results/microbenchmark-attachments"

# Restore exact prior production sources, preserving identical test-only overlays.
for path in OpenCodeIOSClient/Stores/ChatStore.swift \
  OpenCodeIOSClient/ViewModels/AppViewModel/AppViewModel+Events.swift \
  OpenCodeIOSClientTests/ChatStoreTests.swift; do
  git show "$baseline:$path" > "$path"
done
build_variant baseline
baseline_run=$(test_run_file baseline)
[[ -n "$baseline_run" ]] || { echo 'Baseline test product missing' >&2; exit 1; }

start_fixture() {
  cleanup
  fixture_pid=''
  local output=$1
  python3 -u performance-lab/lab.py serve --port 14097 --password ci-fixture-only \
    --log "$output/requests.jsonl" > "$output/fixture.log" 2>&1 &
  fixture_pid=$!
  python3 - <<'PY'
import base64, json, time, urllib.request
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
req=urllib.request.Request('http://127.0.0.1:14097/_lab/status',headers={
    'Authorization':'Basic '+base64.b64encode(b'opencode:ci-fixture-only').decode()})
for _ in range(100):
    try:
        with opener.open(req, timeout=1) as r:
            data=json.load(r)
            assert data['synthetic'] and data['sessions']['ses_2000']==2000
        break
    except OSError:
        time.sleep(.1)
else:
    raise SystemExit('Owned fixture did not start')
PY
}
export_case() {
  local output=$1
  local container
  container=$(xcrun simctl get_app_container "$device_id" "$bundle" data 2>/dev/null || true)
  if [[ -n "$container" && -d "$container/Documents/OpenClientPerformanceLab" ]]; then
    ditto "$container/Documents/OpenClientPerformanceLab" "$output/probes"
  fi
  if [[ -d "$output/ui.xcresult" ]]; then
    xcrun xcresulttool get test-results summary --path "$output/ui.xcresult" > "$output/summary.json" || true
    xcrun xcresulttool export attachments --path "$output/ui.xcresult" --output-path "$output/attachments" || true
  fi
}
run_case() {
  local variant=$1 trial=$2 grouped=$3 warmup=$4
  local output="$results/$trial-$variant-g$grouped"
  local run_file container code=0
  mkdir -p "$output"
  container=$(xcrun simctl get_app_container "$device_id" "$bundle" data 2>/dev/null || true)
  xcrun simctl terminate "$device_id" "$bundle" 2>/dev/null || true
  if [[ "$warmup" != 1 ]]; then
    [[ -n "$container" && -d "$build_root/cache-snapshot" ]] || { echo 'No validated warm cache snapshot' >&2; exit 1; }
    # Only the synthetic app's private cache/probe folders are replaced.
    rm -rf "$container/Library/Application Support"
    ditto "$build_root/cache-snapshot" "$container/Library/Application Support"
  fi
  if [[ -n "$container" ]]; then rm -rf "$container/Documents/OpenClientPerformanceLab"; fi
  start_fixture "$output"
  if [[ "$variant" == baseline ]]; then run_file=$baseline_run; else run_file=$candidate_run; fi
  export TEST_RUNNER_OPENCLIENT_LAB_UI_URL=http://127.0.0.1:14097
  export TEST_RUNNER_OPENCLIENT_LAB_UI_PASSWORD=ci-fixture-only
  export TEST_RUNNER_OPENCLIENT_LAB_UI_VARIANT=$variant
  export TEST_RUNNER_OPENCLIENT_LAB_UI_TRIAL=$trial
  export TEST_RUNNER_OPENCLIENT_LAB_UI_GROUPED=$grouped
  export TEST_RUNNER_OPENCLIENT_LAB_UI_WARMUP_ONLY=$warmup
  set +e
  xcodebuild test-without-building -xctestrun "$run_file" -destination "$destination" \
    -parallel-testing-enabled NO -resultBundlePath "$output/ui.xcresult" \
    '-only-testing:OpenCodeIOSClientUITests/ToolGroupingUITests/testNativeResponsivenessLab' \
    2>&1 | tee "$output/xcodebuild.log"
  code=${PIPESTATUS[0]}
  set -e
  export_case "$output"
  cleanup
  fixture_pid=''
  return "$code"
}

# One real, unmeasured pagination pass. No test endpoint returns extra history.
run_case baseline warmup 1 1
container=$(xcrun simctl get_app_container "$device_id" "$bundle" data)
[[ -d "$container/Library/Application Support" ]] || { echo 'App-private cache missing after warmup' >&2; exit 1; }
ditto "$container/Library/Application Support" "$build_root/cache-snapshot"
find "$build_root/cache-snapshot" -type f -exec ls -l {} \; > "$results/cache-snapshot-files.txt"

# Balanced three pairs. Counterbalance grouping order across pairs as well.
variants=(baseline candidate candidate baseline baseline candidate)
for index in 0 1 2 3 4 5; do
  pair=$((index / 2 + 1))
  if [[ $pair == 2 ]]; then groups=(0 1); else groups=(1 0); fi
  for grouped in "${groups[@]}"; do
    run_case "${variants[$index]}" "pair$pair" "$grouped" 0
  done
done
xcrun xcresulttool get test-results summary --path "$results/microbenchmark.xcresult" > "$results/microbenchmark-summary.json"
xcrun xcresulttool export attachments --path "$results/microbenchmark.xcresult" --output-path "$results/microbenchmark-attachments"
python3 performance-lab/analyze_responsiveness.py "$results" --output "$results/responsiveness-summary.json"
